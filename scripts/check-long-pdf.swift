import AppKit
import CoreText
import Darwin
import PDFKit

/// Companion to check-long-pdf.py. All documents, socket, preferences and provenance
/// belong to this test. No GUI window, account or running Harness is required.
@main
struct LongPDFCheck {
    static func makeFixture(_ url: URL, pages: Int, blankLast: Bool = false, scanOnly: Bool = false, grid: Bool = false) throws {
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(url as CFURL, mediaBox: &paper, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        func draw(_ line: String, x: CGFloat = 32, y: CGFloat, in ctx: CGContext, font: CTFont) {
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)] as [NSAttributedString.Key: Any]
            let item = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(item, ctx)
        }
        for n in 1...pages {
            pdf.beginPDFPage(nil)
            if n == pages && blankLast {
                pdf.endPDFPage()
                continue
            }
            if grid {
                let small = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
                for row in 0..<3 {
                    for (side, x) in [("West", 28), ("Center", 211), ("East", 410)] {
                        draw("\(side) observation \(row)", x: CGFloat(x), y: CGFloat(700 - row * 18), in: pdf, font: small)
                    }
                }
                draw("Below the grid the paragraph resumes its ordinary single-column reading order.",
                     y: 550, in: pdf, font: small)
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
        let previewSelection = try ResearchMaterial.selection("UNIQUE HYPERION", source: "Preview", title: "Independent PDF")
        let located = try await ResearchSourceLocation.locatePDFSelection(previewSelection, at: file)
        precondition(located.text == previewSelection.text && located.fileReference?.matches(file) == true)
        precondition(located.pdfPages == "45" && located.pdfPositions?.map(\.page) == [45])
        precondition(located.verifiedExcerpts?.first?.page == 45 && located.fields["url"] == nil)
        try store.savePendingSelection(located, for: "preview-fixture")
        let reopened = store.pendingSelection("preview-fixture")
        precondition(reopened?.pdfPositions == located.pdfPositions && reopened?.verifiedExcerpts == located.verifiedExcerpts)
        for text in ["blue sample volumes", "unique hyperion", "UNIQUE  HYPERION"] {
            let capture = try ResearchMaterial.selection(text, source: "Preview", title: "Independent PDF")
            let ambiguous = try await ResearchSourceLocation.locatePDFSelection(capture, at: file)
            precondition(ambiguous.fileReference == located.fileReference && ambiguous.text == text)
            precondition(ambiguous.pdfPositions == nil && ambiguous.pdfPages == nil)
        }
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
        if geteuid() != 0 {
            let denied = folder.appendingPathComponent("verified-access.txt")
            try Data("fixture".utf8).write(to: denied)
            let reference = try ResearchFileReference.capture(denied)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }
            let visibleStamp = try ResearchFileReference.fileStamp(denied)
            do {
                _ = try reference.verifiedStamp(at: denied, previous: visibleStamp)
                preconditionFailure("A matching stat did not prove read access.")
            } catch ResearchFileReference.VerificationError.unavailable {}
        }
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
        client.loadFixedMaterial(changing)
        try await wait("fresh attached document") { !client.loadingResearchFile }
        client.draft = "有什么要留意的？"
        client.submitResearch()
        try await wait("cold session provider default") {
            (client.conversationMessages.last?.reply?.question == "有什么要留意的？" && !client.hasPendingSubmission) || client.lastError != nil
        }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        precondition(client.conversationSelection?.reasoningEffort == "low")
        client.startNewSession()
        precondition(client.sessionID == nil && !client.hasAssociatedFile)
        for question in ["不要结合 PDF，只解释这一句", "仅翻译选区", "what is the meaning of “paper”?"] {
            precondition(!ResearchMaterial.requestsFileBackground(question, filename: file.lastPathComponent))
        }
        let captured = try ResearchMaterial.selection("LARCH: fresh preview", source: "TextEdit", title: "Synthetic excerpts")
        for withFile in [true, false] {
            let scope = try ResearchDocumentScope.resolve(question: "翻译选区中作者的原话", mode: .ask,
                selection: captured, hasFile: withFile, filename: withFile ? "fixture.pdf" : nil, captureFailed: false)
            precondition(scope == .selection)
        }
        let firstRead = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(firstRead, result: .success(captured))
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
        let outdated = client.beginResearchSelectionCapture()!
        let replacement = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(replacement, result: .failure(SelectionCaptureError.empty))
        client.finishResearchSelectionCapture(outdated, result: .success(captured))
        precondition(client.appMaterial == captured && client.availableResearchSelection == nil
            && client.selectionError?.contains("没有选区") == true
            && client.hasAssociatedFile && !client.hasPendingSubmission)
        // Reuse is explicit in the material card after a new capture fails.
        client.dismissResearchSelectionError()
        precondition(client.availableResearchSelection == captured)
        client.draft = "解释这段"
        client.submitResearch()
        try await wait("explicitly reuse selected text after capture failed") {
            !client.hasPendingSubmission && client.conversationMessages.last?.reply?.question == "解释这段"
        }
        precondition(client.conversationMessages.last?.reply?.material?.text == captured.text)
        client.removeResearchSelection()
        client.draft = ""
        precondition(client.fixedMaterial?.pdfIndex?.canRequestOCR == true && client.fixedMaterial?.pdfIndex?.pages[36].text.isEmpty == true)
        do {
            _ = try client.fixedMaterial!.pdfIndex!.retrieve("逐句翻译第1、37页的完整原文。")
            fatalError("A strict translation accepted an unreadable requested page")
        } catch { precondition(error.localizedDescription.contains("第 37 页")) }
        client.recognizePDFScans()
        try await wait("on-demand OCR") { !client.loadingResearchFile }
        guard let index = client.fixedMaterial?.pdfIndex else { throw ResearchMaterialError.message(client.materialError ?? "Missing index") }
        precondition(index.pages.count == 52 && index.pages[36].ocr && index.pages[36].text.contains("9375"), index.status)
        let unrelated = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(unrelated, result: .success(captured))
        // Verify the prepared range at the real client transport boundary on two synthetic routes.
        let subscription = client.selectedResearchModel!
        let alternative = ResearchModelSelection(provider: "deepseek-account", model: "fixture-paid", reasoningEffort: nil)
        let rangeQuery = "翻译从 OPENING THISTLE 到 PAGE_1_END 的内容。"
        let verifiedRange = try client.fixedMaterial!.pdfIndex!.prepare(rangeQuery)
        precondition(verifiedRange.count == 1)
        let originalBytes = try Data(contentsOf: file)
        for source in ["none", "failed", "opening"] {
            let stamp = try ResearchFileReference.fileStamp(file)
            if source == "none" {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_648_000_000)],
                                                      ofItemAtPath: file.path)
            } else if source == "failed" {
                try originalBytes.write(to: file, options: .atomic)
            }
            let nextStamp = try ResearchFileReference.fileStamp(file)
            if source != "opening" { precondition(stamp != nextStamp) }
            client.removeResearchSelection()
            if source != "none" {
                let token = client.beginResearchSelectionCapture()!
                if source == "failed" {
                    client.finishResearchSelectionCapture(token, result: .failure(SelectionCaptureError.empty))
                } else {
                    let opening = try ResearchMaterial.selection("OPENING THISTLE", source: "Preview", title: "Start")
                    client.finishResearchSelectionCapture(token, result: .success(opening))
                }
            }
            let n = client.conversationMessages.count
            client.draft = "所选文章的OPENING THISTLE到PAGE_1_END.这段内容翻译"
            client.submitResearch()
            try await wait("range with " + source) {
                (client.conversationMessages.count > n && !client.hasPendingSubmission) || client.lastError != nil
            }
            if let error = client.lastError { throw ResearchMaterialError.message(error) }
            let answer = client.conversationMessages.last!.reply!
            precondition(answer.material?.text == verifiedRange[0].text && client.fixedMaterial?.pdfIndex === index)
            precondition(store.read(session: client.sessionID!, reply: answer)?.file?.fingerprint == before.fingerprint)
        }
        let correctionQuestion = "请把从 OPENING THISTLE 到 ABSENT TERMINAL 的原文逐段翻译成中文。"
        client.removeResearchSelection()
        let beforeCorrection = client.conversationMessages.count
        client.draft = correctionQuestion
        client.submitResearch()
        try await wait("missing endpoint shows editable range") { client.pdfRangeReview?.anchors != nil }
        let review = client.pdfRangeReview!
        precondition(review.candidates.isEmpty && review.anchors?.end == "ABSENT TERMINAL")
        precondition(!client.hasPendingSubmission && client.conversationMessages.count == beforeCorrection)
        client.resolveRangeReview(UUID(), choice: .edit(.init(start: "OPENING THISTLE", end: "PAGE_1_END")))
        precondition(client.pdfRangeReview?.id == review.id)
        client.resolveRangeReview(review.id, choice: .edit(.init(start: "OPENING THISTLE", end: "PAGE_1_END")))
        try await wait("local user correction reaches wire") {
            client.conversationMessages.count == beforeCorrection + 2 && !client.hasPendingSubmission
        }
        let corrected = client.conversationMessages.last?.reply
        precondition(corrected?.question == correctionQuestion && corrected?.material?.text == verifiedRange[0].text)
        precondition(corrected?.material?.scope?.contains("用户修正并核验") == true)
        let unrelatedAgain = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(unrelatedAgain, result: .success(captured))
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
                (client.conversationMessages.count == count + 2 && !client.hasPendingSubmission) || client.lastError != nil
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
        let beforeInferred = client.conversationMessages.count
        client.draft = "开场是 OPENING THISTLE，收尾是 PAGE_1_END，两处之间都要译成中文。"
        client.submitResearch()
        try await wait("infer both verbatim boundaries") {
            (client.conversationMessages.count > beforeInferred && !client.hasPendingSubmission) || client.lastError != nil
        }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        precondition(client.conversationMessages.last!.reply!.material!.text == verifiedRange[0].text)
        let combinedQuestion = "结合论文解释这段"
        let priorCombined = client.conversationMessages.count
        client.draft = combinedQuestion
        client.submitResearch()
        try await wait("planned combined evidence") {
            (client.conversationMessages.count > priorCombined && !client.hasPendingSubmission) || client.lastError != nil
        }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        let mixedReply = client.conversationMessages.last!.reply!
        precondition(mixedReply.material!.text.contains(captured.text) && mixedReply.material!.text.contains("MIDPOINT LARCH"))
        precondition(store.read(session: client.sessionID!, reply: mixedReply)?.backgroundFile?.fingerprint == before.fingerprint)
        client.removeResearchSelection()
        // Ordinary reading and follow-up both use the indexed PDF and remain one visible exchange.
        func expectPair(after count: Int, question: String) {
            let pair = Array(client.conversationMessages.dropFirst(count))
            precondition(pair.count == 2, "Expected one visible question and answer: " + question)
            precondition(pair[0].role == "user" && pair[0].text == question && pair[0].originalPrompt == nil)
            precondition(pair[1].role == "assistant" && pair[1].reply?.question == question)
        }
        for question in ["请总结这篇论文的主要贡献。", "它有哪些局限？"] {
            let count = client.conversationMessages.count
            client.draft = question
            client.submitResearch()
            try await wait("one local exchange " + question) {
                (client.conversationMessages.count >= count + 2 && !client.hasPendingSubmission && !client.pdfRequestRunning)
                    || client.lastError != nil
            }
            if let error = client.lastError { throw ResearchMaterialError.message(error) }
            expectPair(after: count, question: question)
            let reply = client.conversationMessages.last!.reply!
            precondition(reply.material?.text.isEmpty == false)
            precondition(store.read(session: client.sessionID!, reply: reply)?.file?.fingerprint == before.fingerprint)
        }
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
        let beforeSemantic = client.conversationMessages.count
        let semanticQuestion = "为什么第1、52页分别使用不同代号？"
        client.draft = semanticQuestion
        client.submitResearch()
        try await wait("follow-up evidence on the same session and model") {
            (client.conversationMessages.count > beforeSemantic && !client.hasPendingSubmission) || client.lastError != nil
        }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        let semanticReply = client.conversationMessages.last!.reply!
        expectPair(after: beforeSemantic, question: semanticQuestion)
        precondition(semanticReply.material?.text.contains("OPENING THISTLE") == true &&
                     semanticReply.material?.text.contains("FINAL QUARTZ") == true)
        precondition(store.read(session: client.sessionID!, reply: semanticReply)?.file?.fingerprint == before.fingerprint)
        let absentQuote = "请翻译“NONEXISTENT FIXTURE MARK”。"
        client.draft = absentQuote
        let beforeMissing = client.conversationMessages.count
        client.submitResearch()
        try await wait("an absent explicit quote is not replaced with general evidence") { !client.pdfRequestRunning && client.lastError != nil }
        precondition(client.draft == absentQuote && client.conversationMessages.count == beforeMissing)
        precondition(ResearchPDFIndex.wholeTask("不要翻译全文，只翻译第24页", mode: .ask) == nil)
        client.draft = ""
        precondition(client.fixedMaterial!.text.isEmpty)
        let longRange = "请把从 OPENING THISTLE 到 PAGE_52_END 的原文逐段翻译成中文。"
        let exactParts = try index.prepare(longRange)
        precondition(exactParts.count > 1)
        try JSONEncoder().encode(exactParts.map(\.text)).write(to: folder.appendingPathComponent("expected-long-exact.json"))
        let beforeLong = client.conversationMessages.count
        client.draft = longRange
        client.submitResearch()
        try await wait("complete exact translation without approval") { !client.pdfRequestRunning && !client.hasPendingSubmission }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        expectPair(after: beforeLong, question: longRange)
        let translation = client.conversationMessages.last!
        let displayedTranslation = translation.text
        precondition(displayedTranslation == (1...exactParts.count).map { "Synthetic translation part \($0)." }.joined(separator: "\n\n"))
        precondition(store.read(session: client.sessionID!, reply: translation.reply!)?.file?.fingerprint == before.fingerprint)

        let beforeRetry = client.conversationMessages.count
        let rejectedQuestion = "请逐段分析从“OPENING THISTLE”到“PAGE_52_END”的完整原文。FAIL_SEGMENT"
        client.draft = rejectedQuestion
        client.submitResearch()
        try await wait("reject one background chunk") { !client.pdfRequestRunning }
        precondition(client.pdfRequestStatus?.contains("已处理 1/") == true && client.conversationMessages.count == beforeRetry)
        precondition(client.draft == rejectedQuestion)
        client.submitResearch()
        try await wait("retry incomplete background parts without resubmitting the first") { !client.pdfRequestRunning }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        expectPair(after: beforeRetry, question: rejectedQuestion)
        let cancelledRange = "CANCEL_SEGMENT 请把从 OPENING THISTLE 到 ABSENT BATCH TERMINAL 的原文逐段翻译成中文。"
        client.draft = cancelledRange
        client.submitResearch()
        try await wait("batch correction") { client.pdfRangeReview?.anchors?.end == "ABSENT BATCH TERMINAL" }
        client.resolveRangeReview(client.pdfRangeReview!.id, choice: .edit(.init(start: "OPENING THISTLE", end: "PAGE_52_END")))
        // The explicit part receipt is independent of the visible window's status polling.
        client.setResearchWindowForeground(true)
        client.beginResearchPolling()
        try await wait("cancel one admitted part") { client.conversationRunning }
        client.stopPDFWork()
        try await wait("cancel") { !client.pdfRequestRunning }
        client.stopResearchPolling()
        client.setResearchWindowForeground(false)
        precondition(client.pdfRequestStatus?.contains("已停止") == true && client.draft == cancelledRange)
        precondition(before.matches(file))
        let blank = folder.appendingPathComponent("blank.pdf")
        try makeFixture(blank, pages: 2, blankLast: true)
        let incomplete = try ResearchFileMaterial.load(blank).pdfIndex!
        do { _ = try incomplete.segments(); fatalError("Unreadable page silently skipped") }
        catch { precondition(error.localizedDescription.contains("第 2 页")) }
        client.refreshResearch()
        try await wait("idle after cancel") { !client.conversationRunning }
        try Data("replaced synthetic file".utf8).write(to: file, options: .atomic)
        let noPDFQuestion = "按前面的讨论，这篇论文在实验设计上还有什么局限？"
        let beforeUnverifiedPDF = client.conversationMessages.count
        client.draft = noPDFQuestion
        client.submitResearch()
        try await wait("a changed PDF continues the conversation without stale source material") {
            !client.hasPendingSubmission && client.conversationMessages.count == beforeUnverifiedPDF + 2
        }
        expectPair(after: beforeUnverifiedPDF, question: noPDFQuestion)
        let unverifiedReply = client.conversationMessages.last!.reply!
        precondition(unverifiedReply.material == nil && store.read(session: client.sessionID!, reply: unverifiedReply) == nil)
        client.draft = "请逐字引用第52页的完整原文。"
        client.submitResearch()
        try await wait("replacement") { !client.pdfRequestRunning && !client.loadingResearchFile }
        precondition(client.materialError?.contains("无法读取") == true && client.fixedMaterial == nil)
        precondition(client.lastError?.contains("本次未发送") == true)
        client.loadFixedMaterial(blank)
        client.stopPDFWork()
        try await Task.sleep(for: .milliseconds(250))
        precondition(!client.loadingResearchFile && client.fixedMaterial == nil)
        client.loadFixedMaterial(blank)
        try await wait("partially readable attachment") { !client.loadingResearchFile && client.fixedMaterial?.pdfIndex != nil }
        let partialQuestion = "请根据文件第 1–2 页已有的有效证据，总结实验结论，标出未能核验的页。只作简短总结。"
        client.draft = partialQuestion
        client.submitResearch()
        try await wait("verified excerpts reach the wire with omissions") {
            (!client.hasPendingSubmission && client.conversationMessages.last?.reply?.question.hasPrefix(partialQuestion) == true)
                || client.lastError != nil
        }
        if let error = client.lastError { throw ResearchMaterialError.message(error) }
        let partial = client.conversationMessages.last!.reply!
        precondition(partial.question == partialQuestion)
        precondition(partial.material?.scope?.contains("部分证据") == true && partial.material?.text.contains("PAGE_1_START") == true)
        precondition(partial.material?.text.contains("PAGE_2_START") == false)
        let storedPartial = store.read(session: client.sessionID!, reply: partial)
        precondition(storedPartial?.pdfPages == "1" && storedPartial?.evidenceChecks?.contains {
            $0.target.contains("第 2 页") && $0.status == .missing
        } == true)
        let beforeStrict = client.conversationMessages.count
        let strictPartial = "逐句翻译第1到2页的完整原文。"
        client.draft = strictPartial
        client.submitResearch()
        try await wait("no admission for partially verified translation") { !client.pdfRequestRunning && client.lastError != nil }
        precondition(client.lastError?.contains("第 2 页") == true && client.conversationMessages.count == beforeStrict)
        precondition(client.draft == strictPartial)
        print("PASS partial PDF wire evidence and durable gap, while exact translation retains its unsubmitted draft.")
        let scanned = folder.appendingPathComponent("scanned.pdf")
        try makeFixture(scanned, pages: 1, scanOnly: true)
        client.loadFixedMaterial(scanned)
        try await wait("all-image import") { !client.loadingResearchFile }
        precondition(client.fixedMaterial?.text == "" && !client.hasSendableResearchMaterial)
        let priorReplies = client.conversationMessages.count
        let scannedQuestion = "请解释第1页"
        client.draft = scannedQuestion
        client.submitResearch()
        try await wait("unreadable scan allows discussion without fabricated evidence") {
            !client.hasPendingSubmission && client.conversationMessages.count == priorReplies + 2
        }
        expectPair(after: priorReplies, question: scannedQuestion)
        precondition(client.conversationMessages.last?.reply?.material == nil)
        client.draft = "请逐字引用第1页。"
        client.submitResearch()
        precondition(client.lastError?.contains("尚无可发送的正文") == true && client.conversationMessages.count == priorReplies + 2)
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
        let request = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(request, result: .success(selected))
        precondition(!client.hasPendingSubmission && client.displayedResearchMaterial == selected)
        client.submitResearch(.translate)
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
        let originalText = try Data(contentsOf: text)
        try originalText.write(to: text, options: .atomic)
        client.draft = "文件替换七次也要保持一致"
        let countBeforeIdentical = client.conversationMessages.count
        client.submitResearch()
        client.submitResearch()
        try await wait("same text after replacing the inode") {
            client.conversationMessages.count == countBeforeIdentical + 2 && !client.hasPendingSubmission
        }
        precondition(client.conversationMessages.last?.reply?.material?.text == "SESSION A ONLY")
        let changedText = Data("SESSION A ELSE".utf8)
        precondition(changedText.count == originalText.count)
        let oldDate = try text.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try changedText.write(to: text)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: text.path)
        client.draft = "请说明当前材料"
        let countBeforeChange = client.conversationMessages.count
        client.submitResearch()
        try await wait("refresh changed file") { client.fixedMaterial?.text == "SESSION A ELSE" && !client.loadingResearchFile }
        precondition(client.lastError?.contains("内容已更新") == true,
                     "Updated preview: \(String(describing: client.fixedMaterial?.text)), status: \(client.materialError ?? "-"), send: \(client.lastError ?? "-")")
        precondition(client.draft == "请说明当前材料" && client.materialError?.contains("新版本") == true)
        precondition(client.conversationMessages.count == countBeforeChange)
        client.submitResearch()
        try await wait("send updated file") { client.conversationMessages.last?.reply?.material?.text == "SESSION A ELSE" }
        try FileManager.default.removeItem(at: text)
        client.draft = "找不到时不能发送旧材料"
        let countBeforeMissing = client.conversationMessages.count
        client.submitResearch()
        try await wait("missing file") { !client.hasPendingSubmission && client.lastError?.contains("无法读取") == true }
        precondition(client.hasAssociatedFile && client.draft == "找不到时不能发送旧材料")
        precondition(client.conversationMessages.count == countBeforeMissing && client.materialError?.contains("无法读取") == true)
        try changedText.write(to: text)
        client.submitResearch()
        try await wait("restored file sends exactly once") {
            client.conversationMessages.count == countBeforeMissing + 2 && !client.hasPendingSubmission
        }
        precondition(client.materialError == nil && client.conversationMessages.last?.reply?.material?.text == "SESSION A ELSE")
        client.removeResearchFile()
        let cleared = DSHPetCommandClient(defaults: prefs, provenanceStore: store)
        cleared.applyWorkspaces(client.workspaces)
        precondition(cleared.displayedResearchMaterial == selected && !cleared.hasAssociatedFile)
        client.removeResearchSelection()
        let gridURL = folder.appendingPathComponent("review-grid.pdf")
        try makeFixture(gridURL, pages: 1, grid: true)
        client.loadFixedMaterial(gridURL)
        try await wait("grid attached") { client.fixedMaterial?.pdfIndex != nil && !client.loadingResearchFile }
        let countBeforeCancelledFileCheck = client.conversationMessages.count
        client.draft = "取消本次文件核验"
        client.submitResearch()
        precondition(client.pdfRequestRunning)
        client.stopPDFWork()
        try await wait("cancel file verification") { !client.pdfRequestRunning && !client.hasPendingSubmission }
        precondition(client.conversationMessages.count == countBeforeCancelledFileCheck && client.draft == "取消本次文件核验")
        let initialCount = client.conversationMessages.count
        let question = "翻译从 West observation 0 到 East observation 2 的内容。"
        @MainActor func awaitReview(_ alternate: String? = nil, count: Int? = nil) async throws -> DSHPetCommandClient.PDFLayoutReview {
            client.draft = alternate ?? question
            client.submitResearch()
            try await wait("review before dispatch") { client.pdfLayoutReview != nil || !client.pdfRequestRunning }
            guard let review = client.pdfLayoutReview else {
                throw ResearchMaterialError.message("Missing review: " + (client.lastError ?? client.pdfRequestStatus ?? ""))
            }
            precondition(review.evidence.pages == [1] && client.conversationMessages.count == (count ?? initialCount))
            return review
        }
        let declined = try await awaitReview()
        client.resolveLayoutReview(declined.id, accept: false)
        try await wait("declined review returns draft") { !client.pdfRequestRunning }
        precondition(client.pdfLayoutReview == nil && client.draft == question && client.conversationMessages.count == initialCount)
        let detached = try await awaitReview()
        client.removeResearchFile()
        try await wait("detach cancels review") { !client.pdfRequestRunning && client.pdfLayoutReview == nil }
        client.resolveLayoutReview(detached.id, accept: true)
        precondition(client.draft == question && client.conversationMessages.count == initialCount)
        client.loadFixedMaterial(gridURL)
        try await wait("grid reattached") { client.fixedMaterial?.pdfIndex != nil && !client.loadingResearchFile }
        let current = try await awaitReview()
        client.resolveLayoutReview(declined.id, accept: true)
        precondition(client.pdfLayoutReview?.id == current.id)
        let reviewed = current.evidence.materials[0]
        precondition(current.evidence.materials.count == 1 && reviewed.pdfPositions?.isEmpty == false)
        client.resolveLayoutReview(current.id, accept: true)
        client.resolveLayoutReview(current.id, accept: true)
        try await wait("confirmed grid appears once") {
            !client.pdfRequestRunning && client.conversationMessages.count == initialCount + 2
        }
        let gridReply = client.conversationMessages.last!.reply!
        precondition(gridReply.material?.text == reviewed.text && gridReply.material?.scope == reviewed.scope)
        precondition(store.read(session: client.sessionID!, reply: gridReply)?.file?.fingerprint == current.reference.fingerprint)
        let selectedGridText = try ResearchMaterial.selection("My current excerpt about local measurements",
                                                               source: "TextEdit", title: "Grid selection")
        let gridSelection = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(gridSelection, result: .success(selectedGridText))
        let gridExcerpt = "结合选区解释论文第1页的观测"
        let cancelQuestion = gridExcerpt + "含义，必须完整核对该页原文。"
        let cancelledPlan = try await awaitReview(cancelQuestion, count: initialCount + 2)
        client.resolveLayoutReview(cancelledPlan.id, accept: false)
        try await wait("a declined local review returns the draft") { !client.pdfRequestRunning }
        precondition(client.draft == cancelQuestion && client.conversationMessages.count == initialCount + 2)
        let combinedGrid = try await awaitReview(gridExcerpt + "依据，必须完整核对该页原文。", count: initialCount + 2)
        let candidate = combinedGrid.evidence.materials[0]
        client.resolveLayoutReview(combinedGrid.id, accept: true)
        try await wait("approved combined evidence") {
            !client.pdfRequestRunning && client.conversationMessages.count == initialCount + 4
        }
        let combinedReply = client.conversationMessages.last!.reply!
        precondition(combinedReply.material?.text.contains(selectedGridText.text) == true &&
                     combinedReply.material?.text.contains(candidate.text) == true)
        let combinedSource = store.read(session: client.sessionID!, reply: combinedReply)
        precondition(combinedSource?.backgroundFile?.fingerprint == combinedGrid.reference.fingerprint &&
                     combinedSource?.backgroundPages == "1" && combinedSource?.backgroundPositions?.isEmpty == false)
        print("PASS cancelled, invalidated and stale layout reviews cannot transmit; exact accepted candidate reaches the socket and durable source once.")
        print("PASS empty/failed/short/unrelated selection, inferred ranges, strict selection, preserved draft and resumed chunks.")
        print("PASS chooser auto-link, draft migration, new-session isolation, stale chooser, return/relaunch, same-bytes metadata and inode changes, changed/missing/recovered files, cancellation and detachment.")
        print("PASS 52-page import, OCR on page 37, local summary and follow-up, exact range in one visible pair, background retry without resending the first chunk, and durable provenance.")
    }
}
