import AppKit
import CoreText
import PDFKit

/// Companion to check-long-pdf.py. All documents, socket, preferences and provenance
/// belong to this test. No GUI window, account or running Harness is required.
@main
struct LongPDFCheck {
    static func makeFixture(_ url: URL, pages: Int, blankLast: Bool = false, scanOnly: Bool = false) throws {
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(url as CFURL, mediaBox: &paper, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        func draw(_ line: String, y: CGFloat, in ctx: CGContext, font: CTFont) {
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)] as [NSAttributedString.Key: Any]
            let item = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            ctx.textPosition = CGPoint(x: 32, y: y)
            CTLineDraw(item, ctx)
        }
        for n in 1...pages {
            pdf.beginPDFPage(nil)
            if n == pages && blankLast {
                pdf.endPDFPage()
                continue
            }
            if n == 37 || scanOnly {
                let bitmap = CGContext(data: nil, width: 900, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                bitmap.setFillColor(gray: 1, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: 900, height: 120))
                draw("SCAN BEACON 9375", y: 32, in: bitmap, font: CTFontCreateWithName("Helvetica-Bold" as CFString, 58, nil))
                pdf.draw(bitmap.makeImage()!, in: CGRect(x: 38, y: 490, width: 500, height: 67))
            } else {
                draw("PAGE_\(n)_START", y: 738, in: pdf, font: font)
                for row in 0..<15 {
                    draw("Record \(n).\(row): blue sample volumes were collected in the controlled baseline.",
                         y: CGFloat(711 - 22 * row), in: pdf, font: font)
                }
                let marker = [1: "OPENING THISTLE", 24: "MIDPOINT LARCH", 45: "UNIQUE HYPERION", 52: "FINAL QUARTZ"]
                draw(marker[n] ?? "STANDARD RECORD", y: 340, in: pdf, font: font)
                draw("PAGE_\(n)_END", y: 302, in: pdf, font: font)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    @MainActor static func wait(_ name: String, _ test: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(65))
        while !test() {
            if ContinuousClock.now > end { throw ResearchMaterialError.message("Timeout: " + name) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = folder.appendingPathComponent("fixture.pdf")
        let socket = folder.appendingPathComponent("wire.sock").path
        let referenceRoot = folder.appendingPathComponent("sources")
        let store = ResearchProvenanceStore(root: referenceRoot)
        try makeFixture(file, pages: 52)
        // Replace an open fixture during its first page progress callback. A stale index
        // must never enter the cache, even though the original PDF handle remains readable.
        let changing = folder.appendingPathComponent("changing-during-index.pdf")
        try makeFixture(changing, pages: 2)
        do {
            _ = try ResearchPDFIndex.read(changing, title: "changing") { status in
                if status.contains("第 1 /") { try! Data("replaced during indexing".utf8).write(to: changing, options: .atomic) }
            }
            fatalError("File changed during indexing but a stale corpus was returned")
        } catch {
            precondition(error.localizedDescription.contains("变化"), error.localizedDescription)
        }
        try makeFixture(changing, pages: 3)
        let fresh = try ResearchPDFIndex.read(changing, title: "changing") { _ in }
        let reused = try ResearchPDFIndex.read(changing, title: "changing") { _ in }
        precondition(fresh === reused && reused.pages.count == 3)
        try makeFixture(changing, pages: 1)
        let changed = try ResearchPDFIndex.read(changing, title: "changing") { _ in }
        precondition(changed !== reused && changed.pages.count == 1 && changed.reference.fingerprint != reused.reference.fingerprint)
        let before = try ResearchFileReference.capture(file)
        let suite = "LongPDFCheck." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: prefs, provenanceStore: store)
        let target = HarnessInstance(protocolVersion: 1, instanceId: "pdf-check", kind: .desktop,
            profile: "desktop", pid: getpid(), startedAt: 1, webURL: nil,
            statusSocketPath: socket + "-status", commandSocketPath: socket, targetId: "pdf-check")
        precondition(client.configure(instance: target))
        client.start()
        defer { client.stop() }
        try await wait("handshake") { client.selectedWorkspace != nil && client.materialTransportAvailable }
        client.refreshModelCatalog()
        if client.modelSelectionAvailable {
            try await wait("catalog") { client.modelCatalog != nil && client.selectedResearchModel != nil }
        }
        for question in ["不要结合 PDF，只解释这一句", "仅翻译选区", "what is the meaning of “paper”?"] {
            precondition(!ResearchMaterial.requestsFileBackground(question, filename: file.lastPathComponent))
        }
        let captured = try ResearchMaterial.selection("LARCH: fresh preview", source: "TextEdit", title: "Synthetic excerpts")
        for withFile in [true, false] {
            let scope = try ResearchDocumentScope.resolve(question: "翻译选区中作者的原话", mode: .ask,
                selection: captured, hasFile: withFile, filename: withFile ? "fixture.pdf" : nil, captureFailed: false)
            precondition(scope == .selection)
        }
        let firstRead = client.beginSelectionTranslation(previewOnly: true)!
        client.finishSelectionTranslation(firstRead, result: .success(captured))
        precondition(client.appMaterial == captured && client.sessionID == nil && !client.hasPendingSubmission)
        client.loadFixedMaterial(file)
        try await wait("index") { !client.loadingResearchFile }
        precondition(client.appMaterial == captured && client.sessionID == nil)
        client.draft = "只解释本次选区"
        client.submitResearch()
        try await wait("explicit selection only") { !client.hasPendingSubmission && client.conversationMessages.last?.reply?.material?.text == captured.text }
        client.draft = "结合文件第24页解释这段"
        client.submitResearch()
        try await wait("mixed source snapshot") { !client.hasPendingSubmission && client.conversationMessages.last?.reply?.material?.source == "选区与会话文件" }
        let combined = client.conversationMessages.last!.reply!.material!
        precondition(combined.text.contains(captured.text) && combined.text.contains("MIDPOINT LARCH") &&
            combined.text.contains("fixture.pdf") && !combined.text.contains("FINAL QUARTZ") && combined.pageIndex == nil)
        let ref = store.read(session: client.sessionID!, reply: client.conversationMessages.last!.reply!)
        precondition(ref?.backgroundFile?.fingerprint == before.fingerprint && ref?.backgroundPages == "24" && ref?.file == nil)
        let outdated = client.beginSelectionTranslation(previewOnly: true)!
        let replacement = client.beginSelectionTranslation(previewOnly: true)!
        client.finishSelectionTranslation(replacement, result: .failure(SelectionCaptureError.empty))
        client.finishSelectionTranslation(outdated, result: .success(captured))
        client.draft = "解释当前选区"
        client.submitResearch()
        precondition(client.appMaterial == nil && client.lastError?.contains("未取得选区") == true && client.hasAssociatedFile)
        client.removeResearchSelection()
        client.draft = ""
        precondition(client.fixedMaterial?.pdfIndex?.canRequestOCR == true && client.fixedMaterial?.pdfIndex?.pages[36].text.isEmpty == true)
        do {
            _ = try client.fixedMaterial!.pdfIndex!.retrieve("第1、37页有什么？")
            fatalError("Missing page in explicit multipage request accepted")
        } catch { precondition(error.localizedDescription.contains("第 37 页")) }
        client.recognizePDFScans()
        try await wait("on-demand OCR") { !client.loadingResearchFile }
        guard let index = client.fixedMaterial?.pdfIndex else { throw ResearchMaterialError.message(client.materialError ?? "Missing index") }
        precondition(index.pages.count == 52 && index.pages[36].ocr && index.pages[36].text.contains("9375"), index.status)
        let unrelated = client.beginSelectionTranslation(previewOnly: true)!
        client.finishSelectionTranslation(unrelated, result: .success(captured))
        // Verify the prepared range at the real client transport boundary on two synthetic routes.
        let subscription = client.selectedResearchModel!
        let alternative = ResearchModelSelection(provider: "deepseek-account", model: "fixture-paid", reasoningEffort: nil)
        let rangeQuery = "翻译从 OPENING THISTLE 到 PAGE_1_END 的内容。"
        let verifiedRange = try client.fixedMaterial!.pdfIndex!.prepare(rangeQuery)
        precondition(verifiedRange.count == 1)
        var packets: [String] = []
        for route in [subscription, alternative] {
            if route != client.selectedResearchModel {
                client.selectResearchModel(route)
                try await wait("explicit provider selection") { client.selectedResearchModel == route && !client.modelSwitching }
            }
            let count = client.conversationMessages.count
            client.draft = rangeQuery
            client.submitResearch()
            try await wait("range on " + route.provider) {
                (client.conversationMessages.count == count + 1 && !client.hasPendingSubmission) || client.lastError != nil
            }
            if let error = client.lastError { throw ResearchMaterialError.message(error) }
            let sent = client.conversationMessages.last!.reply!.material!
            precondition(sent.text == verifiedRange[0].text)
            precondition(sent.text.contains("OPENING THISTLE") && sent.text.contains("PAGE_1_END") &&
                         !sent.text.contains("PAGE_1_START") && !sent.text.contains("LARCH"))
            precondition(store.read(session: client.sessionID!, reply: client.conversationMessages.last!.reply!)?.file?.fingerprint == before.fingerprint)
            packets.append(sent.text)
        }
        precondition(packets[0] == packets[1])
        client.selectResearchModel(subscription)
        try await wait("restore explicit subscription") { client.selectedResearchModel == subscription && !client.modelSwitching }
        client.removeResearchSelection()
        let all = try index.segments()
        precondition(all.count > 4 && all.allSatisfy { $0.text.utf16.count <= 7_200 })
        for page in index.pages {
            let contiguous = all.map(\.text).joined(separator: "\n")
            precondition(contiguous.contains(page.number == 37 ? "9375" : "PAGE_\(page.number)_END"))
        }
        for (question, marker) in [("What is on page 1?", "OPENING THISTLE"), ("第24页中有什么？", "MIDPOINT LARCH"),
                                   ("最后一页是什么？", "FINAL QUARTZ"), ("第1、24、52页有哪些标记？", "MIDPOINT LARCH"), ("HYPERION", "UNIQUE HYPERION"),
                                   ("请告诉我第37页的内容", "9375")] {
            let count = client.conversationMessages.count
            client.draft = question
            client.submitResearch()
            try await wait("question " + question) { client.conversationMessages.count > count && !client.hasPendingSubmission }
            let answer = client.conversationMessages.last!
            precondition(answer.reply?.material?.text.contains(marker) == true, "Wrong wire evidence: " + question)
            if question.contains("、") {
                for token in ["OPENING THISTLE", "MIDPOINT LARCH", "FINAL QUARTZ"] {
                    precondition(answer.reply!.material!.text.contains(token))
                }
            }
            precondition(answer.reply!.material!.text.utf16.count <= 12_000)
            precondition(store.read(session: client.sessionID!, reply: answer.reply!)?.file?.fingerprint == before.fingerprint)
        }
        precondition(ResearchPDFIndex.wholeTask("不要翻译全文，只翻译第24页", mode: .ask) == nil)
        client.draft = ""
        let countBeforePreview = client.conversationMessages.count
        precondition(client.fixedMaterial!.text.isEmpty)
        func approve(_ allow: Bool) async throws {
            try await wait("batch plan") { client.pdfBatchApproval != nil }
            client.resolvePDFApproval(client.pdfBatchApproval!.id, allow: allow)
        }
        client.submitResearch(.translate)
        try await approve(false)
        try await wait("cancel before first call") { !client.pdfRequestRunning }
        precondition(client.conversationMessages.count == countBeforePreview)
        for (question, additional) in [("请翻译全文", 0), ("请分析整篇 PDF", 1)] {
            let count = client.conversationMessages.count
            client.draft = question
            client.submitResearch()
            try await approve(true)
            try await wait(question) { !client.pdfRequestRunning }
            precondition(client.pdfRequestStatus?.contains("已完成 \(all.count)/\(all.count) 段") == true,
                         client.pdfRequestStatus ?? "missing progress")
            let answers = client.conversationMessages.dropFirst(count)
            precondition(answers.count == all.count + additional)
            for (answer, chunk) in zip(answers, all) {
                precondition(answer.reply?.material?.text == chunk.text)
            }
        }
        let count = client.conversationMessages.count
        client.draft = "请分析全文。FAIL_SEGMENT"
        client.submitResearch()
        try await approve(true)
        try await wait("reject") { !client.pdfRequestRunning }
        precondition(client.pdfRequestStatus?.contains("已完成 1/") == true && client.conversationMessages.count == count + 1)
        client.draft = "请翻译全文。CANCEL_SEGMENT"
        client.submitResearch()
        try await approve(true)
        try await wait("cancel one admitted part") { client.conversationRunning }
        client.stopPDFWork()
        try await wait("cancel") { !client.pdfRequestRunning }
        precondition(client.pdfRequestStatus?.contains("已停止") == true)
        precondition(before.matches(file))
        let blank = folder.appendingPathComponent("blank.pdf")
        try makeFixture(blank, pages: 2, blankLast: true)
        let incomplete = try ResearchFileMaterial.load(blank).pdfIndex!
        do { _ = try incomplete.segments(); fatalError("Unreadable page silently skipped") }
        catch { precondition(error.localizedDescription.contains("第 2 页")) }
        client.refreshResearch()
        try await wait("idle after cancel") { !client.conversationRunning }
        try Data("replaced synthetic file".utf8).write(to: file, options: .atomic)
        client.draft = "第52页，请用旧缓存吗？"
        client.submitResearch()
        try await wait("replacement") { !client.pdfRequestRunning && !client.loadingResearchFile }
        precondition(client.materialError?.contains("无法读取") == true && client.fixedMaterial == nil)
        precondition(client.lastError?.contains("本次未发送") == true)
        client.loadFixedMaterial(blank)
        client.stopPDFWork()
        try await Task.sleep(for: .milliseconds(250))
        precondition(!client.loadingResearchFile && client.fixedMaterial == nil)
        let scanned = folder.appendingPathComponent("scanned.pdf")
        try makeFixture(scanned, pages: 1, scanOnly: true)
        client.loadFixedMaterial(scanned)
        try await wait("all-image import") { !client.loadingResearchFile }
        precondition(client.fixedMaterial?.text == "" && !client.hasSendableResearchMaterial)
        let priorReplies = client.conversationMessages.count
        client.draft = "请解释第1页"
        client.submitResearch()
        precondition(client.lastError?.contains("尚无可发送的正文") == true && client.conversationMessages.count == priorReplies)
        client.recognizePDFScans()
        try await wait("all-image OCR") { !client.loadingResearchFile }
        precondition(client.fixedMaterial?.text.isEmpty == true && client.fixedMaterial?.pdfIndex?.pages.first?.text.contains("9375") == true && client.hasSendableResearchMaterial)
        let blankOnly = folder.appendingPathComponent("all-blank.pdf")
        try makeFixture(blankOnly, pages: 1, blankLast: true)
        client.loadFixedMaterial(blankOnly, recognizeScans: true)
        try await wait("unreadable after OCR") { !client.loadingResearchFile }
        precondition(client.fixedMaterial?.text == "" && !client.hasSendableResearchMaterial)
        // Exercise the same file chooser, send, history and restore paths as the installed app.
        let text = folder.appendingPathComponent("linked-paper.md")
        try Data("SESSION A ONLY".utf8).write(to: text)
        let firstID = client.sessionID!
        let row = ResearchHistoryRow(sessionId: firstID, workspaceId: client.selectedWorkspaceID!,
                                     title: "A", archived: false, updatedAt: 1, running: false, blank: false, materials: [])
        precondition(client.beginResearchFileChoice())
        client.finishResearchFileChoice(text)
        try await wait("choose immediately usable") { client.fixedMaterial?.text == "SESSION A ONLY" }
        client.draft = ""
        let selected = try ResearchMaterial.selection("ONCE: sample in another window", source: "TextEdit", title: "Synthetic selection")
        let request = client.beginSelectionTranslation()!
        client.finishSelectionTranslation(request, result: .success(selected))
        try await wait("only this selection reaches the wire") {
            !client.hasPendingSubmission && client.conversationMessages.last?.reply?.material?.text == selected.text
        }
        precondition(client.displayedResearchMaterial?.text == selected.text && client.fixedMaterial?.text == "SESSION A ONLY")
        client.removeResearchFile()
        precondition(!client.hasAssociatedFile && client.displayedResearchMaterial == selected)
        client.loadFixedMaterial(text)
        try await wait("replace file without replacing selection") { !client.loadingResearchFile }
        precondition(client.appMaterial == selected && client.fixedMaterial?.text == "SESSION A ONLY")
        let readback = DSHPetCommandClient(defaults: prefs, provenanceStore: store)
        readback.applyWorkspaces(client.workspaces)
        try await wait("restore after app initialization") { readback.fixedMaterial?.text == "SESSION A ONLY" }
        precondition(client.beginResearchFileChoice())
        client.startNewSession()
        client.finishResearchFileChoice(text)
        precondition(!client.hasAssociatedFile && client.displayedResearchMaterial == nil)
        precondition(client.selectResearchSession(row))
        try await wait("return to A") { client.fixedMaterial?.text == "SESSION A ONLY" }
        try Data("SESSION A NEW VERSION".utf8).write(to: text, options: .atomic)
        client.draft = "请说明当前材料"
        let countBeforeChange = client.conversationMessages.count
        client.submitResearch()
        try await wait("refresh changed file") { !client.loadingResearchFile }
        precondition(client.fixedMaterial?.text == "SESSION A NEW VERSION",
                     "Updated preview: \(String(describing: client.fixedMaterial?.text)), status: \(client.materialError ?? "-"), send: \(client.lastError ?? "-")")
        precondition(client.draft == "请说明当前材料" && client.materialError?.contains("新版本") == true)
        precondition(client.conversationMessages.count == countBeforeChange)
        client.submitResearch()
        try await wait("send updated file") { client.conversationMessages.last?.reply?.material?.text == "SESSION A NEW VERSION" }
        try FileManager.default.removeItem(at: text)
        client.draft = "找不到时不能发送旧材料"
        client.submitResearch()
        try await wait("missing file") { !client.loadingResearchFile && client.fixedMaterial == nil }
        precondition(client.materialError?.contains("linked-paper.md") == true && client.hasAssociatedFile)
        client.removeResearchMaterial()
        let cleared = DSHPetCommandClient(defaults: prefs, provenanceStore: store)
        cleared.applyWorkspaces(client.workspaces)
        precondition(cleared.displayedResearchMaterial == nil && !cleared.hasAssociatedFile)
        print("PASS chooser auto-link, draft migration, new-session isolation, stale chooser, return/relaunch, changed and missing files, detachment.")
        print("PASS 52-page native import, local Vision OCR on 37, front/middle/end and keyword question wire evidence, all ordered translation/analysis parts and final synthesis, reply provenance, reject/cancel/unreadable page and changed file.")
    }
}
