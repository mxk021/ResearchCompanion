import AppKit
import CoreText
import PDFKit
import ScreenCaptureKit
import SwiftUI

/// Build with the app's Swift sources (excluding DSHPetMain). Takes a temporary
/// directory. Pass --render to exercise an AppKit window and save its card and reader.
@main
struct PDFCardCheck {
    static func fixture(_ url: URL, referencesOnly: Bool = false) throws {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let properties = [kCGPDFContextAuthor: "Fixture Printer", kCGPDFContextCreator: "Fixture Printer"] as CFDictionary
        let ctx = CGContext(url as CFURL, mediaBox: &media, properties)!
        func line(_ value: String, at y: CGFloat, size: CGFloat = 12, x: CGFloat = 40) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let text = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
        ctx.beginPDFPage(nil)
        line("Optical Measurement Reports", at: 750, size: 22)
        if referencesOnly {
            line("References", at: 700, size: 15)
            line("An Unrelated Article", at: 650, size: 24)
            line("Alan Turing", at: 620)
            line("https://doi.org/10.5555/reference", at: 600)
        } else {
            line("Calibrating Optical Measurements", at: 690, size: 21)
            line("Ada Lovelace1, Alan Turing2 and Jane Doe1,2,*", at: 662)
            line("https://doi.org/10.5555/calibration", at: 641, size: 10)
            line("Abstract", at: 595, size: 14)
            line("A private abstract should never appear in the material card.", at: 567)
            for row in 0..<7 {
                line("Controlled synthetic observations in an optical laboratory.", at: CGFloat(528 - 24 * row))
            }
            line("For a prior experiment see https://doi.org/10.5555/wrong.", at: 270)
        }
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        line("Optical Measurement Reports", at: 750, size: 22)
        line("Selected evidence: the final verified signal is narrow.", at: 605)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    @MainActor static func save(_ view: NSView, to url: URL) async throws {
        // Only enumerate our own synthetic windows. This also captures PDFKit's tiled layers.
        if #available(macOS 14.4, *), let window = view.window,
           let content = try? await SCShareableContent.currentProcess,
           let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
            let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
            let config = SCStreamConfiguration()
            config.width = Int(ownWindow.frame.width * 2)
            config.height = Int(ownWindow.frame.height * 2)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try data.write(to: url)
                return
            }
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("Empty view") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure("Empty image") }
        try data.write(to: url)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = directory.appendingPathComponent("synthetic.pdf")
        let list = directory.appendingPathComponent("references.pdf")
        try fixture(file)
        try fixture(list, referencesOnly: true)
        let document = PDFDocument(url: file)!
        let listMeta = ResearchPDFMetadata.read(PDFDocument(url: list)!)
        precondition(listMeta == ResearchPDFMetadata(), "Reference or running header leaked into the card")
        let material = try ResearchFileMaterial.load(file)
        let index = material.pdfIndex!
        let meta = index.metadata
        precondition(meta.title == "Calibrating Optical Measurements" && meta.authors == ["Ada Lovelace", "Alan Turing", "Jane Doe"])
        precondition(meta.authorDisplay == "Ada Lovelace et al." && meta.link?.absoluteString == "https://doi.org/10.5555/calibration")
        precondition(material.text.isEmpty && index.cardStatus.contains("全文索引"))
        let question = "翻译从 Selected evidence 到 final verified signal 的内容。"
        let evidence = try index.retrieve(question)
        precondition(evidence.text == "Selected evidence: the final verified signal")
        guard let positions = evidence.pdfPositions, let anchor = positions.first else { throw Failure("Missing PDF evidence location") }
        precondition(positions.allSatisfy { $0.page == 2 })
        let page = document.page(at: 1)!
        let expected = page.selection(for: (page.string! as NSString).range(of: evidence.text))!.bounds(for: page)
        let mark = ResearchPDFEvidenceReader.targetRect(for: anchor, on: page)!
        precondition(abs(mark.minX - expected.minX) < 2 && abs(mark.maxX - expected.maxX) < 2,
                     "The highlight should end at the anchor inside the original line")
        let source = ResearchSourceMaterial(key: "fixture", title: evidence.title, text: evidence.text, source: evidence.source,
                                            scope: evidence.scope, url: nil, pageLabel: nil, pageIndex: nil)
        let reply = ResearchReplyContext(question: question, questionId: "fixture", requestId: "fixture", time: nil, material: source)
        let store = ResearchProvenanceStore(root: directory.appendingPathComponent("sources"))
        try store.record(session: "test", requestID: "fixture", material: evidence)
        let answer = ResearchChatMessage(id: "reply", role: "assistant", text: "Verified", originalPrompt: nil, reply: reply)
        let reopened = ResearchProvenanceStore(root: directory.appendingPathComponent("sources"))
        let saved = ResearchAnswerSource(session: "test", answer: answer, store: reopened)
        guard case .pdf(let reference, let recovered, let first) = saved.directTarget else { throw Failure("Lost source target") }
        precondition(first == 2 && recovered == positions)
        let bytes = reference.verifiedPDFData(at: file)
        precondition(bytes != nil)
        precondition(saved.markdown(interpretation: "$x^2$", supplement: "", savedAt: Date()).contains(evidence.text.components(separatedBy: "\n").last!))
        guard case .pdf(_, let legacy, let oldPage) = ResearchDirectSource.locatedFile(reference, positions: nil, pages: "2–4、9") else {
            throw Failure("Lost legacy page")
        }
        precondition(legacy.isEmpty && oldPage == 2)
        // Loading a conversation should never decode all line rectangles just to label its sources.
        var bulk = evidence
        bulk.pdfPositions = Array(repeating: anchor, count: 750)
        try store.record(session: "many-lines", requestID: "fixture", material: bulk)
        let lightweight = reopened.read(session: "many-lines", reply: reply, includePositions: false)
        precondition(lightweight?.pdfPages == "2" && lightweight?.positionDigest != nil && lightweight?.pdfPositions == nil)
        precondition(reopened.read(session: "many-lines", reply: reply)?.pdfPositions?.count == 750)
        if CommandLine.arguments.contains("--render") {
            let _ = NSApplication.shared
            let suite = "ResearchPDFCardCheck." + UUID().uuidString
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let client = DSHPetCommandClient(defaults: prefs, provenanceStore: store)
            client.loadFixedMaterial(file)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while client.loadingResearchFile {
                if ContinuousClock.now > deadline { throw Failure("Card did not finish loading") }
                try await Task.sleep(for: .milliseconds(20))
            }
            let size = CGSize(width: 430, height: 150)
            let host = NSHostingController(rootView: ResearchMaterialCard(command: client, availableSize: size).padding(8))
            let window = NSWindow(contentViewController: host)
            window.title = "Research Companion"
            window.setContentSize(size)
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
            try await save(host.view, to: directory.appendingPathComponent("card.png"))
            let history = ResearchAnswerSource(session: "test", answer: answer, store: reopened, includePositions: false)
            precondition(history.local?.pdfPositions == nil && history.local?.positionDigest != nil)
            ResearchAnswerActions.openOriginal(history, in: window)
            while window.attachedSheet == nil {
                if ContinuousClock.now > deadline { throw Failure("Source window did not open") }
                try await Task.sleep(for: .milliseconds(20))
            }
            let sheet = window.attachedSheet!
            try await Task.sleep(for: .milliseconds(450))
            func reader(_ view: NSView) -> PDFView? {
                if let pdf = view as? PDFView { return pdf }
                return view.subviews.compactMap { reader($0) }.first
            }
            let viewer = reader(sheet.contentView!)!
            precondition(viewer.currentPage === viewer.document?.page(at: 1), "Reader landed on the wrong PDF page")
            precondition(viewer.currentPage!.annotations.contains { $0.type == "Square" })
            try await save(sheet.contentView!, to: directory.appendingPathComponent("reader.png"))
            window.endSheet(sheet)
            window.orderOut(nil)
        }
        precondition(reference.matches(file), "Source PDF changed during verification")
        print("PDF card, metadata, source snapshot and read-only PDF page verified.")
    }
}
