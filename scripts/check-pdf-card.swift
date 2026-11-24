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
        let wrapped = "A decomposed cafe\u{301} has a soft\r\nline break.\r\n\r\nThis paragraph remains separate."
        let preview = SelectionPreviewText(wrapped)
        precondition(preview.displayed == "A decomposed cafe\u{301} has a soft line break.\r\n\r\nThis paragraph remains separate.")
        let visibleRange = (preview.displayed as NSString).range(of: "soft line break.")
        precondition(preview.originalText(for: visibleRange) == "soft\r\nline break.")
        let wholePreview = NSRange(location: 0, length: preview.displayed.utf16.count)
        precondition(preview.originalText(for: wholePreview)?.utf8.elementsEqual(wrapped.utf8) == true)
        let chinese = SelectionPreviewText("这是同一段中的原文\n继续显示在下一行。")
        precondition(chinese.displayed == "这是同一段中的原文继续显示在下一行。")
        let indexText = chinese.displayed as NSString
        precondition(chinese.originalText(for: indexText.range(of: "原文继续")) == "原文\n继续")
        precondition(chinese.originalText(for: indexText.range(of: "原文")) == "原文")
        precondition(chinese.originalText(for: indexText.range(of: "继续")) == "继续")
        for protected in [
            "The display starts here\nx = y + z\nwhere the symbols first appear.",
            "The resulting function is\nf(x)\nwhere the notation follows the text.",
            "The formula spans\n\\begin{aligned}\ncontains free variable names\nwith deliberate structure\n\\end{aligned}",
            "This one ends here.\nAnother starts here.\n    Indented paragraph.",
            "Text appears beforehand\n1. Step after paragraph\n2. Another step",
            "The dashed line ends multi-\nline despite a continuation.",
            "Prose here\n```txt\nplain words split\nlike source code\n```",
            "This line contains Unicode breaks\u{85}the first one is NEL\u{2028}the next is LS",
            "A genuine paragraph separator\u{2029}marks the next paragraph."
        ] {
            precondition(SelectionPreviewText(protected).displayed.utf8.elementsEqual(protected.utf8))
        }
        let longSelection = String(repeating: wrapped + "\r\n\r\n", count: 840)
        let longPreview = await Task.detached { SelectionPreviewText.prepare(longSelection) }.value
        guard let longPreview else { throw Failure("Missing prepared selection preview") }
        let longRange = NSRange(location: 0, length: longPreview.displayed.utf16.count)
        precondition(longPreview.originalText(for: longRange)?.utf8.elementsEqual(longSelection.utf8) == true)
        let cancelledPreview = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            return SelectionPreviewText.prepare(longSelection)
        }
        cancelledPreview.cancel()
        let cancelledResult = await cancelledPreview.value
        precondition(cancelledResult == nil)
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
        let contents = saved.noteContents()
        precondition(contents.quotations.map(\.text) == [evidence.text])
        precondition(contents.exportWarning == nil)
        var legacyMaterial = evidence
        legacyMaterial.verifiedExcerpts = nil
        try store.record(session: "legacy", requestID: "fixture", material: legacyMaterial)
        let legacySource = ResearchAnswerSource(session: "legacy", answer: answer, store: reopened, includePositions: false)
        let legacyContents = legacySource.noteContents()
        precondition(legacyContents.quotations.isEmpty && legacySource.sourcePresentation?.objects == nil)
        precondition(legacyContents.exportWarning?.contains("没有可核验的文字摘录") == true)

        var copied = try ResearchMaterial.selection("WPS copy — 原文\r\n第二行  ", source: "WPS", title: "Copy fixture")
        copied.scope = "用户确认使用 · 出处未独立核验"
        copied.verifiedExcerpts = nil
        let copySnapshots = directory.appendingPathComponent("copy-sources")
        let copyStore = ResearchProvenanceStore(root: copySnapshots)
        try copyStore.savePendingSelection(copied, for: "copy")
        let persisted = try FileManager.default.contentsOfDirectory(at: copySnapshots, includingPropertiesForKeys: nil)
        struct LegacySelection: Decodable { let text: String }
        precondition(persisted.count == 1)
        let copyBytes = try Data(contentsOf: persisted[0])
        precondition((try? JSONDecoder().decode(LegacySelection.self, from: copyBytes)) == nil,
                     "Rolling back must not interpret a copied selection as a verified excerpt.")
        let restoredCopy = ResearchProvenanceStore(root: copySnapshots).pendingSelection("copy")
        precondition(restoredCopy == copied && restoredCopy?.text.utf8.elementsEqual(copied.text.utf8) == true)
        let copyPayload = ResearchSourceMaterial(key: "inline:copy", title: copied.title, text: copied.text,
            source: copied.source, scope: copied.scope, url: nil, pageLabel: nil, pageIndex: nil)
        let copyContext = ResearchReplyContext(question: question, questionId: "copy", requestId: "copy", time: nil, material: copyPayload)
        let copyAnswer = ResearchChatMessage(id: "copy", role: "assistant", text: "Response", originalPrompt: nil, reply: copyContext)
        try copyStore.record(session: "test", requestID: "copy", material: copied)
        let copySource = ResearchAnswerSource(session: "test", answer: copyAnswer, store: copyStore)
        precondition(copySource.directTarget == nil && copySource.noteContents().quotations.isEmpty)

        var partialCaption = evidence
        partialCaption.verifiedExcerpts = [.init(kind: .caption,
            range: NSRange(location: 0, length: evidence.text.utf16.count), title: evidence.title, page: 2, partial: true)]
        try store.record(session: "partial-caption", requestID: "fixture", material: partialCaption)
        let captionSource = ResearchAnswerSource(session: "partial-caption", answer: answer, store: reopened, includePositions: false)
        precondition(captionSource.local?.verifiedExcerpts == nil && captionSource.sourcePresentation?.canOpen == true)
        precondition(captionSource.sourcePresentation?.warning?.contains("可能不完整") == true)
        let captionNote = captionSource.noteContents()
        precondition(captionNote.quotations.map(\.text) == [evidence.text])
        precondition(captionNote.exportWarning?.contains("可能不完整") == true)
        let captionMarkdown = captionSource.markdown(interpretation: "待核对", supplement: "", savedAt: Date())
        precondition(captionMarkdown.contains("局部摘录") && captionMarkdown.contains(evidence.text))
        let relocated = directory.appendingPathComponent("same-caption.pdf")
        try FileManager.default.copyItem(at: file, to: relocated)
        try store.relink(session: "partial-caption", reply: reply, file: relocated)
        let relocatedSource = ResearchAnswerSource(session: "partial-caption", answer: answer, store: reopened, includePositions: false)
        precondition(relocatedSource.local?.file?.originalPath == relocated.path)
        precondition(relocatedSource.sourcePresentation?.warning == captionSource.sourcePresentation?.warning)
        precondition(relocatedSource.noteContents().quotations.map(\.text) == [evidence.text])
        guard case .pdf(let reference, let recovered, let first) = saved.directTarget else { throw Failure("Lost source target") }
        precondition(first == 2 && recovered == positions)
        let bytes = reference.verifiedPDFData(at: file)
        precondition(bytes != nil)
        let outside = ResearchPDFSourcePosition(page: 2, bounds: CGRect(x: -90, y: -90, width: 12, height: 7))
        do {
            _ = try ResearchPDFEvidenceReader.prepare(data: bytes!, filename: file.lastPathComponent,
                                                      positions: [anchor, outside], firstPage: 2, requireMappedPositions: true)
            throw Failure("Incomplete review overlay was accepted")
        } catch is ResearchMaterialError {}
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
        var grouped = evidence
        let context = ResearchPDFSourcePosition(page: 1, bounds: CGRect(x: 40, y: 560, width: 300, height: 18))
        grouped.backgroundPositions = [context]
        grouped.backgroundFile = reference
        grouped.objectLabels = ["式 (5)", "Fig. 1"]
        grouped.sourceGroups = [
            .init(role: .object, title: "目标摘录", range: 0..<positions.count),
            .init(role: .context, title: "辅助依据", range: 0..<1),
        ]
        try store.record(session: "grouped", requestID: "fixture", material: grouped)
        let groupedHistory = ResearchAnswerSource(session: "grouped", answer: answer, store: reopened, includePositions: false)
        precondition(groupedHistory.sourcePresentation?.objects == "式 (5) · Fig. 1")
        precondition(groupedHistory.sourcePresentation?.page == "摘录页 2")
        precondition(groupedHistory.local?.sourceGroups == nil && groupedHistory.local?.positionDigest != nil)
        let navigation = groupedHistory.pdfNavigation(for: reference, background: false)
        precondition(navigation.positions == positions && navigation.targets.map(\.title) == ["目标摘录", "辅助依据"])
        precondition(navigation.targets.map(\.positions) == [positions, [context]])
        precondition(groupedHistory.pdfNavigation(for: reference, background: true).targets.first?.positions == [context])
        let unrelated = try ResearchFileReference.capture(list)
        precondition(groupedHistory.pdfNavigation(for: unrelated, background: false).targets.isEmpty)
        precondition(saved.pdfNavigation(for: reference, background: false).targets.isEmpty)
        let prepared = try ResearchPDFEvidenceReader.prepare(data: bytes!, filename: file.lastPathComponent,
            positions: positions, firstPage: 2,
            targets: navigation.targets + [.init(title: "错误的完整图注", positions: [anchor, outside])])
        precondition(prepared.targetNames == ["目标摘录", "辅助依据"])
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
            ResearchAnswerActions.openOriginal(groupedHistory, in: window)
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
            func navigationMenu(_ view: NSView) -> NSPopUpButton? {
                if let menu = view as? NSPopUpButton { return menu }
                return view.subviews.compactMap { navigationMenu($0) }.first
            }
            let menu = navigationMenu(sheet.contentView!)!
            precondition(menu.itemTitles == ["目标摘录", "辅助依据"])
            menu.selectItem(at: 1)
            menu.sendAction(menu.action, to: menu.target)
            while viewer.currentPage !== viewer.document?.page(at: 0) {
                if ContinuousClock.now > deadline { throw Failure("The supporting target must navigate to its own page") }
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(viewer.currentPage!.annotations.contains { $0.type == "Square" })
            precondition(viewer.document?.page(at: 1)?.annotations.isEmpty == true)
            window.endSheet(sheet)

            // Use the production comparison view, checking the reopened PDF, physical page,
            // highlight and the candidate text against an independently located selection.
            let review = DSHPetCommandClient.PDFLayoutReview(
                evidence: ResearchPDFReviewRequired(reason: "请核对本页候选顺序。", pages: [2], materials: [evidence]),
                reference: reference)
            var accepted = false
            let comparison = NSHostingController(rootView: ResearchPDFReviewView(review: review) { accepted = $0 })
            let comparisonWindow = NSWindow(contentViewController: comparison)
            comparisonWindow.setContentSize(NSSize(width: 720, height: 460))
            window.beginSheet(comparisonWindow, completionHandler: nil)
            let reviewDeadline = ContinuousClock.now.advanced(by: .seconds(12))
            // PDFKit exposes page 1 as soon as it loads the document. The
            // reader reveals and highlights the requested page on appearance.
            while true {
                guard !accepted else { throw Failure("Review silently accepted its candidate") }
                let compared = reader(comparison.view)
                if let document = compared?.document, let page = compared?.currentPage,
                   document.index(for: page) == 1, page.annotations.contains(where: { $0.type == "Square" }) { break }
                if ContinuousClock.now > reviewDeadline {
                    let page = compared?.currentPage.flatMap { compared?.document?.index(for: $0) }
                    throw Failure("Review did not reveal and highlight the fingerprinted PDF page (current index: \(String(describing: page)))")
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            try await save(comparison.view, to: directory.appendingPathComponent("review.png"))
            window.endSheet(comparisonWindow)
            window.orderOut(nil)
        }
        precondition(reference.matches(file), "Source PDF changed during verification")
        print("PDF card, metadata, source snapshot and read-only PDF page verified.")
    }
}
