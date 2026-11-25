import AppKit
import ApplicationServices

/// Run against the isolated socket from check-long-pdf.py. No desktop source, general pasteboard,
/// live library, existing session, or provider is involved.
@main struct SelectionCheck {
    private final class CountingPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
        private(set) var requests = 0

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requests += 1
            item.setData(Data([42]), forType: type)
        }
    }

    @MainActor static func wait(_ test: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !test() {
            guard ContinuousClock.now < deadline else { throw ResearchMaterialError.message("Selection fixture timed out") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func expect<Value>(_ failure: SelectionCaptureError, _ run: () throws -> Value) {
        do { _ = try run(); preconditionFailure("Expected capture to fail") }
        catch { precondition(error as? SelectionCaptureError == failure, error.localizedDescription) }
    }

    @MainActor static func checkServicePasteboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        expect(.empty) { try ResearchSelectionCapture.serviceSelectionText(from: board) }
        let selection = "Public fixture α\n  Keep this spacing."
        board.clearContents()
        precondition(board.setString(selection, forType: .string))
        let revision = board.changeCount
        let selected = try ResearchSelectionCapture.serviceSelectionText(from: board)
        precondition(selected == selection && board.changeCount == revision)
    }

    @MainActor static func checkClipboardRestoration() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func rawItems() -> [[String: Data]] {
            (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type.rawValue, $0) }
                })
            }
        }
        let urls = ["/nonexistent-research-fixture-one.pdf", "/nonexistent-research-fixture-two.pdf"]
        func file(_ path: String, finderMetadata: Bool = false) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            item.setData(Data([0, 1, 128, 255]), forType: .init("com.apple.icns"))
            if finderMetadata {
                item.setData(Data([0, 1, 2, 3]), forType: .init("com.apple.finder.noderef"))
            }
            return item
        }
        func filePaths() -> [String] {
            (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
                .compactMap { ($0 as? NSURL)?.path }
        }
        let text = NSPasteboardItem()
        text.setString("Unicode α, exact bytes.", forType: .string)
        text.setData(Data([0, 95, 255]), forType: .init("com.apple.WebKit.custom-pasteboard-data"))
        let image = NSPasteboardItem()
        image.setData(Data([137, 80, 78, 71, 13, 10]), forType: .png)
        let rich = NSPasteboardItem()
        let richType = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
        let content = NSAttributedString(string: "A rich-text note.")
        let nativeRTFD = try content.data(from: NSRange(location: 0, length: content.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        precondition(rich.setData(nativeRTFD, forType: richType))
        let mixedRich = NSPasteboardItem(), mixedImage = NSPasteboardItem()
        precondition(mixedRich.setData(nativeRTFD, forType: richType))
        precondition(mixedImage.setData(Data([137, 80, 78, 71, 13, 10]), forType: .png))
        let link = NSPasteboardItem()
        precondition(link.setString("https://example.org/paper.pdf", forType: .URL))
        precondition(link.setString("Paper title", forType: .init("public.url-name")))
        for original in [[], [text], [image], [rich], [link], [file(urls[0])], [file(urls[0], finderMetadata: true), file(urls[1])],
                         [mixedRich, file(urls[0], finderMetadata: true), mixedImage, file(urls[1])]] {
            board.clearContents()
            precondition(board.types?.isEmpty == true && board.pasteboardItems?.isEmpty == true)
            precondition(original.isEmpty || board.writeObjects(original))
            let before = rawItems()
            let references = filePaths()
            let snapshot = try ResearchClipboardSnapshot.capture(board)
            let restoration = try snapshot.prepareRestoration()
            precondition(snapshot.revision == board.changeCount)
            let copyRevision = board.clearContents()
            precondition(board.setString("Selection from the original document", forType: .string))
            precondition(restoration.apply(to: board, replacing: copyRevision) == .restored)
            precondition(rawItems() == before)
            precondition(filePaths() == references)
        }
        let original = try ResearchClipboardSnapshot.capture(board).prepareRestoration()
        let copyRevision = board.clearContents()
        precondition(board.setString("Selection", forType: .string))
        board.clearContents()
        precondition(board.setString("A later user copy", forType: .string))
        precondition(original.apply(to: board, replacing: copyRevision) == .newerWrite)
        precondition(board.string(forType: .string) == "A later user copy")
        let copied = try ResearchSelectionCapture.exactSelection("Known fresh note", source: "Fixture", title: "Original")
        let restored = try ResearchDocumentCopy.finish(.success(copied), restoring: .restored, requestID: UUID())
        let keptNewer = try ResearchDocumentCopy.finish(.success(copied), restoring: .newerWrite, requestID: UUID())
        let failedRestore = try ResearchDocumentCopy.finish(.success(copied), restoring: .failed, requestID: UUID())
        precondition(restored.material == copied && restored.clipboard.message == nil)
        precondition(keptNewer.material == copied && keptNewer.clipboard.message?.contains("现有内容保留") == true)
        precondition(failedRestore.material == copied && failedRestore.clipboard.message?.contains("无法确认原剪贴板已恢复") == true)
        expect(.copyUnverified) {
            try ResearchDocumentCopy.finish(.failure(SelectionCaptureError.copyUnverified), restoring: .restored, requestID: UUID()).material
        }

        // Independent WebKit v1 fixture: version, 8-bit origin, two empty collections.
        let web = NSPasteboardItem(), format = NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data")
        let webAddress = ResearchSelectionCapture.safariLocation("https://example.org/papers/current.pdf")
        let hiddenScheme = ResearchSelectionCapture.safariLocation("example.org/papers/current.pdf")
        precondition(webAddress?.components.url?.absoluteString == "https://example.org/papers/current.pdf")
        precondition(hiddenScheme?.components.scheme == nil && hiddenScheme?.components.host == "example.org")
        precondition(ResearchSelectionCapture.safariLocation("ftp://example.org/file.pdf") == nil)
        precondition(ResearchSelectionCapture.safariLocation("https://user:secret@example.org/file.pdf") == nil)
        for type in [NSPasteboard.PasteboardType.string, .html, .rtf] { web.setString("test", forType: type) }
        let origin = "https://example.org"
        var metadata = Data([1,0,0,0,19,0,0,0,1]) + Data(origin.utf8) + Data(repeating: 0, count: 16)
        web.setData(metadata, forType: format)
        precondition(ResearchDocumentCopy.matchesPDFOrigin(web, url: URL(string: "https://example.org:443/research.pdf")))
        precondition(!ResearchDocumentCopy.matchesPDFOrigin(web, url: URL(string: "https://example.org:8443/research.pdf")))
        precondition(!ResearchDocumentCopy.matchesPDFOrigin(web, url: URL(fileURLWithPath: "/synthetic/research.pdf")))
        precondition(!ResearchDocumentCopy.matchesPDFOrigin(web, url: URL(string: "https://example.net/research.pdf")))
        metadata[0] = 2
        web.setData(metadata, forType: format)
        precondition(!ResearchDocumentCopy.matchesPDFOrigin(web, url: URL(string: origin)))

        // An unsafe second item must prevent even an otherwise safe first item
        // from requesting its lazy data. Neither item may be fetched or replaced.
        for protected in ["com.apple.pasteboard.promised-file-url", "org.nspasteboard.ConcealedType", "org.example.opaque-fixture"] {
            let safeProvider = CountingPasteboardProvider(), protectedProvider = CountingPasteboardProvider()
            let first = NSPasteboardItem(), second = NSPasteboardItem()
            precondition(first.setDataProvider(safeProvider, forTypes: [.string]))
            precondition(second.setDataProvider(protectedProvider, forTypes: [.init(protected)]))
            board.clearContents()
            precondition(board.writeObjects([first, second]))
            let revision = board.changeCount
            do {
                _ = try ResearchClipboardSnapshot.capture(board)
                preconditionFailure("An unsafe pasteboard item was accepted")
            } catch let error as SelectionCaptureError {
                precondition(error == .clipboardNotRestorable)
                precondition(board.changeCount == revision && safeProvider.requests == 0 && protectedProvider.requests == 0)
            }
        }
    }

    @MainActor static func main() async throws {
        try checkClipboardRestoration()
        try checkServicePasteboard()
        // Exercise the exact foreground gate used by the AppKit handoff. A
        // third app and a different source window cannot trigger a return.
        let owner: pid_t = 11, source: pid_t = 12, unrelated: pid_t = 13
        let direct = ResearchSelectionHandoff.readingInChat
        let activating = ResearchSelectionHandoff.activatingSource
        let reading = ResearchSelectionHandoff.readingSource
        let safariService = ResearchSelectionHandoff.readingSafariService
        precondition(direct.permits(owner, owner: owner, source: source))
        precondition(!direct.permits(source, owner: owner, source: source))
        precondition(activating.permits(owner, owner: owner, source: source))
        precondition(activating.permits(source, owner: owner, source: source))
        precondition(reading.permits(source, owner: owner, source: source))
        precondition(!reading.permits(owner, owner: owner, source: source))
        precondition(safariService.permits(source, owner: owner, source: source))
        precondition(safariService.permits(owner, owner: owner, source: source))
        precondition(!safariService.shouldReturn(from: owner, source: source, sourceStillBound: true))
        for phase in [direct, activating, reading, safariService] {
            precondition(!phase.permits(unrelated, owner: owner, source: source))
            precondition(!phase.permits(nil, owner: owner, source: source))
            precondition(!phase.shouldReturn(from: unrelated, source: source, sourceStillBound: true))
            precondition(!phase.shouldReturn(from: source, source: source, sourceStillBound: false))
        }
        precondition(!direct.shouldReturn(from: source, source: source, sourceStillBound: true))
        precondition(activating.shouldReturn(from: source, source: source, sourceStillBound: true))
        precondition(reading.shouldReturn(from: source, source: source, sourceStillBound: true))
        precondition(safariService.shouldReturn(from: source, source: source, sourceStillBound: true))

        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let socket = folder.appendingPathComponent("wire.sock").path
        let suite = "SelectionCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, provenanceStore: .init(root: folder.appendingPathComponent("references")))
        let target = HarnessInstance(protocolVersion: 1, instanceId: "pdf-check", kind: .desktop, profile: "desktop",
            pid: getpid(), startedAt: 1, webURL: nil, statusSocketPath: socket + "-status", commandSocketPath: socket, targetId: "pdf-check")
        precondition(client.configure(instance: target))
        client.removeResearchSelection()
        client.start()
        defer { client.stop() }
        client.beginResearchPolling()
        try await wait { client.selectedWorkspace != nil && client.materialTransportAvailable && client.modelCatalog != nil }
        let store = ResearchProvenanceStore(root: folder.appendingPathComponent("references"))
        let link = URL(string: "https://example.org/public/fixture.pdf?local=stable#page=3")!
        let selections = ["  Case α\n 37 ± 0.2. ", "Second excerpt", "  Case α\n 37 ± 0.2. ", "  Case α\n 37 ± 0.2. "]
        var previousSelectionID: UUID?
        for text in selections {
            let read = client.beginResearchSelectionCapture()!
            let captured = try ResearchSelectionCapture.exactSelection(text, source: "Safari", title: "PDF fixture", webURL: link)
            client.finishResearchSelectionCapture(read, result: .success(captured))
            let restored = DSHPetCommandClient(defaults: defaults, provenanceStore: store)
            precondition(client.appMaterial == captured && restored.appMaterial == captured && restored.sessionID == nil)
            precondition(!client.hasPendingSubmission && restored.appMaterial?.localWebURL == link.absoluteString)
            precondition(restored.appMaterial?.url == "https://example.org/public/fixture.pdf")
            precondition(captured.id != previousSelectionID)
            previousSelectionID = captured.id
        }
        let cancelled = client.beginResearchSelectionCapture()!
        client.cancelResearchSelectionCapture()
        client.finishResearchSelectionCapture(cancelled, result: .failure(SelectionCaptureError.empty))
        precondition(client.appMaterial?.id == previousSelectionID && client.availableResearchSelection == nil && client.hasSelectionFailure)
        let warning = client.beginResearchSelectionCapture()!
        let retained = try ResearchSelectionCapture.exactSelection("Verified before clipboard recovery", source: "Safari", title: "PDF fixture")
        client.finishResearchSelectionCapture(warning, result: .success(retained), clipboard: .restoreFailed)
        precondition(client.appMaterial == retained && client.selectionError?.contains("已保存本次选区") == true)
        client.draft = "只翻译这个选区"
        precondition(client.researchMaterialSummary(.translate) == "将带入完整选区")
        precondition(DSHPetCommandClient(defaults: defaults, provenanceStore: store).appMaterial == retained)
        precondition(!client.hasPendingSubmission && !client.capturingSelection)

        let failedCopy = client.beginResearchSelectionCapture()!
        precondition(client.availableResearchSelection == nil && client.clipboardCopyRevision == nil)
        client.finishResearchSelectionCapture(failedCopy, result: .failure(SelectionCaptureError.wpsCopyUnverified))
        precondition(client.availableResearchSelection == nil && client.appMaterial == retained
                     && client.clipboardCopyRevision != nil)
        client.pasteResearchSelection()
        precondition(client.availableResearchSelection == nil && client.appMaterial == retained && client.hasSelectionFailure)
        client.submitResearch()
        precondition(client.lastError?.contains("本次未取得选区") == true && !client.hasPendingSubmission)
        client.dismissResearchSelectionError()
        precondition(client.availableResearchSelection == retained && client.clipboardCopyRevision == nil)

        let wpsText = "  WPS 原文 α\r\n保留边界。 "
        let wps = try ResearchSelectionCapture.clipboardSelection(wpsText, source: "WPS PDF", title: "原文")
        let expired = client.beginResearchSelectionCapture()!
        client.cancelResearchSelectionCapture()
        client.finishResearchSelectionCapture(expired, result: .success(wps))
        precondition(client.availableResearchSelection == nil && client.appMaterial == retained)
        let capturedWPS = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(capturedWPS, result: .success(wps))
        precondition(client.availableResearchSelection == wps && client.canUseResearchMaterial && !client.capturingSelection)
        precondition(wps.verifiedExcerpts == nil && wps.scope.contains("未独立核验") && wps.url == nil)
        precondition(client.appMaterial?.text.utf8.elementsEqual(wpsText.utf8) == true)
        let restoredWPS = DSHPetCommandClient(defaults: defaults, provenanceStore: store)
        precondition(restoredWPS.availableResearchSelection == wps && restoredWPS.appMaterial?.verifiedExcerpts == nil)
        client.finishResearchSelectionCapture(expired, result: .success(retained))
        precondition(client.availableResearchSelection == wps)
        let oldSession = client.beginResearchSelectionCapture()!
        client.startNewSession()
        client.finishResearchSelectionCapture(oldSession, result: .success(wps))
        precondition(client.availableResearchSelection == nil && client.appMaterial == nil)

        client.removeResearchSelection()
        precondition(DSHPetCommandClient(defaults: defaults, provenanceStore: store).appMaterial == nil)
        let deepseek = ResearchModelSelection(provider: "deepseek-account", model: "fixture-paid", reasoningEffort: nil)
        let catalog = ResearchModelCatalog(groups: [.init(id: deepseek.provider, name: "Paid", models: [
            .init(id: deepseek.model, name: "Paid", reasoning: nil)], error: nil)], defaultSelection: deepseek)
        precondition((try? catalog.translation(current: nil, explicit: nil, preferred: nil, hasHistory: false)) == nil)
        precondition((try? catalog.translation(current: deepseek, explicit: nil, preferred: nil, hasHistory: true)) == nil)
        precondition((try? catalog.translation(current: deepseek, explicit: deepseek, preferred: nil, hasHistory: true)) == deepseek)
        client.draft = "UNSENT PRIVATE DRAFT"
        client.includePaperContext = false

        let fake = try ResearchSelectionCapture.exactSelection("STALE excerpt", source: "旧窗口", title: "旧材料")
        let superseded = client.beginResearchSelectionCapture()!
        let fresh = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(superseded, result: .success(fake))
        precondition(client.displayedResearchMaterial == nil)
        client.finishResearchSelectionCapture(fresh, result: .failure(SelectionCaptureError.empty))
        precondition(!client.hasPendingSubmission && client.displayedResearchMaterial == nil && client.conversationMessages.isEmpty)
        let aborted = client.beginResearchSelectionCapture()!
        client.removeResearchSelection()
        client.finishResearchSelectionCapture(aborted, result: .success(fake))
        precondition(!client.hasPendingSubmission && client.displayedResearchMaterial == nil)

        precondition(ResearchSelectionCapture.mapError(.apiDisabled, trusted: false) == .permission)
        precondition(ResearchSelectionCapture.mapError(.apiDisabled, trusted: true) == .unsupported)
        precondition(ResearchSelectionCapture.mapError(.cannotComplete, trusted: true) == .timedOut)
        precondition(ResearchSelectionCapture.mapError(.invalidUIElement, trusted: true) == .sourceChanged)
        let selectionOwner = AXUIElementCreateApplication(getpid())
        let otherOwner = AXUIElementCreateApplication(getpid() + 1)
        let range = NSRange(location: 4, length: 1)
        let composed = ResearchSelectionCapture.NativeSelection(element: selectionOwner, text: "\u{e9}", characterRange: range)
        let decomposed = ResearchSelectionCapture.NativeSelection(element: selectionOwner, text: "e\u{301}", characterRange: range)
        precondition(composed.text == decomposed.text && !composed.agrees(with: decomposed))
        precondition(composed.agrees(with: composed))
        precondition(!composed.agrees(with: .init(element: selectionOwner, text: composed.text,
                                                    characterRange: NSRange(location: 9, length: 1))))
        precondition(!composed.agrees(with: .init(element: otherOwner, text: composed.text, characterRange: range)))
        expect(.empty) { try ResearchSelectionCapture.exactSelection(" \n ", source: "Editor", title: "T") }
        expect(.tooLarge) { try ResearchSelectionCapture.exactSelection(String(repeating: "z", count: ResearchMaterial.localSelectionLimit + 1), source: "Editor", title: "T") }
        // WPS representation fixtures use private in-memory items. This check
        // requires no source app, general clipboard, model call, or GUI permission.
        let rtfItem = NSPasteboardItem()
        rtfItem.setData(Data(#"{\rtf1\ansi Delta \u945?}"#.utf8), forType: .rtf)
        let richText = try ResearchDocumentCopy.text(from: rtfItem)
        precondition(richText == "Delta α")
        let htmlItem = NSPasteboardItem()
        htmlItem.setData(Data("<html><head><style>ignored</style></head><body><p>blue<span> β</span></p><p>α &amp; &#x3c3;</p><script>unrelated</script><img src=\"https://example.invalid/ignored\" /></body></html>".utf8), forType: .html)
        let htmlText = try ResearchDocumentCopy.text(from: htmlItem)
        precondition(htmlText?.trimmingCharacters(in: .whitespacesAndNewlines) == "blue β\nα & σ")
        htmlItem.setString("original plain", forType: .string)
        let plain = try ResearchDocumentCopy.text(from: htmlItem)
        precondition(plain == "original plain")

        let doctypeItem = NSPasteboardItem()
        doctypeItem.setData(Data(#"<!DOCTYPE html [<!ENTITY x SYSTEM "file:///not-a-resource">]><p>&x;</p>"#.utf8), forType: .html)
        do {
            _ = try ResearchDocumentCopy.text(from: doctypeItem)
            preconditionFailure("Untrusted document type must be rejected")
        } catch let failure as SelectionCaptureError {
            precondition(failure == .richTextUnavailable)
        }
        let id = UUID()
        let wrongZotero = try JSONSerialization.data(withJSONObject: ["ok": true, "liveSelection": ["text": "old", "title": "T", "requestId": UUID().uuidString]])
        expect(.sourceChanged) { try ResearchZoteroSelection.decode(wrongZotero, status: 200, requestID: id) }
        let cachedZotero = try JSONSerialization.data(withJSONObject: ["ok": true, "selection": ["text": "cache"], "fulltext": ["text": "whole document"]])
        expect(.zoteroBridge) { try ResearchZoteroSelection.decode(cachedZotero, status: 200, requestID: id) }
        let emptyZotero = try JSONSerialization.data(withJSONObject: ["ok": false, "error": "NO_SELECTION"])
        expect(.empty) { try ResearchZoteroSelection.decode(emptyZotero, status: 422, requestID: id) }
        let unverifiedZotero = try JSONSerialization.data(withJSONObject: ["ok": false, "error": "SELECTION_UNVERIFIED"])
        expect(.zoteroUnverified) { try ResearchZoteroSelection.decode(unverifiedZotero, status: 422, requestID: id) }
        let legacyZotero = try JSONSerialization.data(withJSONObject: ["ok": true, "liveSelection": [
            "text": "old bridge", "title": "T", "requestId": id.uuidString]])
        expect(.zoteroBridge) { try ResearchZoteroSelection.decode(legacyZotero, status: 200, requestID: id) }
        let location = try JSONSerialization.data(withJSONObject: ["ok": true, "liveSelection": [
            "text": "Exact source text", "title": "PDF fixture", "requestId": id.uuidString,
            "capture": ["method": "pdf-canvas", "tabID": "native-fixture", "attachmentID": 1, "attachmentKey": "ABCD1234"],
            "location": ["library": "groups/42", "attachmentKey": "ABCD1234", "pageIndex": 3, "pageLabel": "iv"]]])
        let withPage = try ResearchZoteroSelection.decode(location, status: 200, requestID: id)
        precondition(withPage.zoteroLocation?.url?.absoluteString == "zotero://open-pdf/groups/42/items/ABCD1234?page=4")
        precondition(withPage.fields["url"] == nil && withPage.page == "iv")
        let exactPDF = URL(string: "https://example.org/paper.pdf?edition=2#page=7")!
        precondition(ResearchBrowserNavigation.isExactPage(exactPDF.absoluteString, exactPDF))
        precondition(!ResearchBrowserNavigation.isExactPage("https://example.org/paper.pdf?edition=2#page=8", exactPDF))

        let longText = String(repeating: "字", count: 24_001)
        let preview = client.beginResearchSelectionCapture()!
        client.includePaperContext = true
        precondition(client.researchMaterialSummary(.ask).contains("等待本次选区"))
        client.finishResearchSelectionCapture(preview, result: .success(try ResearchSelectionCapture.exactSelection(longText, source: "Editor", title: "long")))
        precondition(client.appMaterial?.text == longText && client.sessionID == nil && !client.hasPendingSubmission)
        precondition(client.researchMaterialSummary(.translate).contains("超出带入上限"))
        client.submitResearch(.translate)
        precondition(client.sessionID == nil && client.lastError == ResearchMaterial.oversizeMessage)

        for source in ["Safari", "预览", "Zotero", "TextEdit", "系统服务"] {
            client.draft = "UNSENT PRIVATE DRAFT"
            let before = client.conversationMessages.count
            let request = client.beginResearchSelectionCapture()!
            let excerpt = source + " fresh\n  42"
            let captured: ResearchMaterial
            if source == "Zotero" {
                let bytes = try JSONSerialization.data(withJSONObject: ["ok": true, "liveSelection": ["requestId": request.id.uuidString,
                    "title": source + " fixture", "text": excerpt, "capture": [
                        "method": "pdf-canvas", "tabID": "fixture-tab", "attachmentID": 42, "attachmentKey": "ABCD1234"]]])
                captured = try ResearchZoteroSelection.decode(bytes, status: 200, requestID: request.id)
            } else {
                captured = try ResearchSelectionCapture.exactSelection(excerpt, source: source, title: source + " fixture")
            }
            client.finishResearchSelectionCapture(request, result: .success(captured))
            client.finishResearchSelectionCapture(request, result: .success(fake))
            precondition(client.appMaterial?.text == excerpt && client.draft == "UNSENT PRIVATE DRAFT")
            precondition(!client.hasPendingSubmission && client.conversationMessages.count == before)
            client.draft = ""
            client.submitResearch(.translate)
            try await wait { client.conversationMessages.count > before && !client.hasPendingSubmission }
            let reply = client.conversationMessages.last!.reply!
            precondition(reply.material?.text == excerpt && reply.requestId != nil)
            precondition(reply.material?.source == source && reply.question == "请将当前材料中的原文翻译成中文。")
            precondition(client.conversationMessages.count == before + 1 && client.draft.isEmpty)
        }
        let firstSession = client.sessionID
        let firstSelection = client.appMaterial
        precondition(firstSelection != nil && DSHPetCommandClient(defaults: defaults, provenanceStore: store).appMaterial == firstSelection)
        client.selectResearchModel(deepseek)
        try await wait { !client.modelSwitching && client.conversationSelection == deepseek }
        func submitAndCheck(_ source: String, provider: String) async throws {
            guard let request = client.beginResearchSelectionCapture() else { throw ResearchMaterialError.message("Expected capture") }
            let text = "Synthetic route check: " + source
            client.finishResearchSelectionCapture(request, result: .success(
                try ResearchSelectionCapture.exactSelection(text, source: source, title: "Route fixture")))
            client.submitResearch(.translate)
            try await wait { client.conversationMessages.last?.reply?.material?.text == text && !client.hasPendingSubmission }
            precondition(client.conversationSelection?.provider == provider)
        }
        try await submitAndCheck("Fixture explicit paid choice", provider: "deepseek-account")
        client.startNewSession()
        precondition(client.sessionID == nil && client.appMaterial == nil)
        try await submitAndCheck("Fresh scope", provider: "chatgpt")
        precondition(client.sessionID != firstSession)
        let explicit = client.beginResearchSelectionCapture()!
        let excerpt = "Synthetic selected text for explicit explanation"
        client.finishResearchSelectionCapture(explicit, result: .success(
            try ResearchSelectionCapture.exactSelection(excerpt, source: "Explicit mode fixture", title: "Mode fixture")))
        client.draft = "只解释选区"
        precondition(client.researchMaterialSummary(.explain).contains("完整选区"))
        precondition(client.researchMaterialSummary(.ask) == "将带入完整选区")
        client.includePaperContext = false
        precondition(client.researchMaterialSummary(.ask).contains("本轮只发送问题"))
        client.includePaperContext = true
        client.submitResearch(.explain)
        try await wait { client.conversationMessages.last?.reply?.question == "只解释选区" && !client.hasPendingSubmission }
        client.draft = "只用选区，指出这句话的主语。"
        client.submitResearch()
        try await wait {
            if case .failed = client.submissionStatus { return client.hasPendingSubmission }
            return false
        }
        let restored = DSHPetCommandClient(defaults: defaults, provenanceStore: .init(root: folder.appendingPathComponent("references")))
        precondition(restored.submissionStatus == .unconfirmed && restored.hasPendingSubmission && restored.targetSwitchBlocked)
        precondition(restored.appMaterial == client.appMaterial && restored.appMaterial?.text == excerpt)
        let pendingKey = "dsh-pet.command.pendingRequestID"
        guard let originalID = defaults.string(forKey: pendingKey) else {
            preconditionFailure("An incomplete bridge acknowledgement lost the saved request id.")
        }
        client.submitResearch()
        try await wait { client.conversationMessages.last?.reply?.requestId == originalID && !client.hasPendingSubmission }
        precondition(client.conversationMessages.last?.reply?.material?.text == excerpt && defaults.object(forKey: pendingKey) == nil)
        let copy = client.beginResearchSelectionCapture()!
        client.finishResearchSelectionCapture(copy, result: .success(wps))
        client.draft = ""
        client.submitResearch(.translate)
        try await wait { client.conversationMessages.last?.reply?.material?.source == "WPS PDF" && !client.hasPendingSubmission }
        precondition(Data(client.conversationMessages.last!.reply!.material!.text.utf8) == Data(wpsText.utf8))
        print("Verified WPS selection goes directly into the composer, preserves exact raw bytes and unverified provenance, and rejects stale completions and unchanged clipboard.")
        print("Verified explicit explanation mode, unconfirmed restore, and idempotent retry of the same request.")
        print("Verified explicit paid choice is local to one synthetic session; the next session used its subscription.")
        print("Passed five preview-only captures followed by explicit translation, stale/cancelled requests, draft isolation, trust diagnostics, Zotero response identity, byte limits and foreground handoff guards.")
    }
}
