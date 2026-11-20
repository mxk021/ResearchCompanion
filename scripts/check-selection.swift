import AppKit
import ApplicationServices

/// Run against the isolated socket from check-long-pdf.py. No desktop source, general pasteboard,
/// live library, existing session, or provider is involved.
@main struct SelectionCheck {
    @MainActor static func wait(_ test: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !test() {
            guard ContinuousClock.now < deadline else { throw ResearchMaterialError.message("Selection fixture timed out") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func expect(_ failure: SelectionCaptureError, _ run: () throws -> ResearchMaterial) {
        do { _ = try run(); preconditionFailure("Expected capture to fail") }
        catch { precondition(error as? SelectionCaptureError == failure, error.localizedDescription) }
    }

    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let socket = folder.appendingPathComponent("wire.sock").path
        let suite = "SelectionCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, provenanceStore: .init(root: folder.appendingPathComponent("references")))
        let target = HarnessInstance(protocolVersion: 1, instanceId: "pdf-check", kind: .desktop, profile: "desktop",
            pid: getpid(), startedAt: 1, webURL: nil, statusSocketPath: socket + "-status", commandSocketPath: socket, targetId: "pdf-check")
        precondition(client.configure(instance: target))
        client.removeResearchMaterial()
        client.start()
        defer { client.stop() }
        try await wait { client.selectedWorkspace != nil && client.materialTransportAvailable }
        let deepseek = ResearchModelSelection(provider: "deepseek-account", model: "fixture-paid", reasoningEffort: nil)
        let catalog = ResearchModelCatalog(groups: [.init(id: deepseek.provider, name: "Paid", models: [
            .init(id: deepseek.model, name: "Paid", reasoning: nil)], error: nil)], defaultSelection: deepseek)
        precondition((try? catalog.translation(current: nil, explicit: nil, preferred: nil, hasHistory: false)) == nil)
        precondition((try? catalog.translation(current: deepseek, explicit: nil, preferred: nil, hasHistory: true)) == nil)
        precondition((try? catalog.translation(current: deepseek, explicit: deepseek, preferred: nil, hasHistory: true)) == deepseek)
        client.draft = "UNSENT PRIVATE DRAFT"
        client.includePaperContext = false

        let fake = try ResearchSelectionCapture.exactSelection("STALE excerpt", source: "旧窗口", title: "旧材料")
        let superseded = client.beginSelectionTranslation()!
        let fresh = client.beginSelectionTranslation()!
        client.finishSelectionTranslation(superseded, result: .success(fake))
        precondition(client.displayedResearchMaterial == nil)
        client.finishSelectionTranslation(fresh, result: .failure(SelectionCaptureError.empty))
        precondition(!client.hasPendingSubmission && client.displayedResearchMaterial == nil && client.conversationMessages.isEmpty)
        let aborted = client.beginSelectionTranslation()!
        client.removeResearchMaterial()
        client.finishSelectionTranslation(aborted, result: .success(fake))
        precondition(!client.hasPendingSubmission && client.displayedResearchMaterial == nil)

        precondition(ResearchSelectionCapture.mapError(.apiDisabled, trusted: false) == .permission)
        precondition(ResearchSelectionCapture.mapError(.apiDisabled, trusted: true) == .unsupported)
        precondition(ResearchSelectionCapture.mapError(.cannotComplete, trusted: true) == .timedOut)
        precondition(ResearchSelectionCapture.mapError(.invalidUIElement, trusted: true) == .sourceChanged)
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

        let longText = String(repeating: "字", count: 24_001)
        let preview = client.beginSelectionTranslation(previewOnly: true)!
        client.finishSelectionTranslation(preview, result: .success(try ResearchSelectionCapture.exactSelection(longText, source: "Editor", title: "long")))
        precondition(client.appMaterial?.text == longText && client.sessionID == nil && !client.hasPendingSubmission)
        client.submitResearch(.translate)
        precondition(client.sessionID == nil && client.lastError == ResearchMaterial.oversizeMessage)

        for source in ["Safari", "预览", "Zotero", "TextEdit", "系统服务"] {
            let before = client.conversationMessages.count
            let request = client.beginSelectionTranslation()!
            let excerpt = source + " fresh\n  42"
            let captured: ResearchMaterial
            if source == "Zotero" {
                let bytes = try JSONSerialization.data(withJSONObject: ["ok": true, "liveSelection": ["requestId": request.id.uuidString,
                    "title": source + " fixture", "text": excerpt]])
                captured = try ResearchZoteroSelection.decode(bytes, status: 200, requestID: request.id)
            } else {
                captured = try ResearchSelectionCapture.exactSelection(excerpt, source: source, title: source + " fixture")
            }
            client.finishSelectionTranslation(request, result: .success(captured))
            client.finishSelectionTranslation(request, result: .success(fake))
            try await wait { client.conversationMessages.count > before && !client.hasPendingSubmission }
            let reply = client.conversationMessages.last!.reply!
            precondition(reply.material?.text == excerpt && reply.requestId == "dsh-pet-" + request.id.uuidString.lowercased())
            precondition(reply.material?.source == source && reply.question == "请将本次选中的原文翻译成中文。")
            precondition(client.conversationMessages.count == before + 1 && client.draft == "UNSENT PRIVATE DRAFT")
        }
        let firstSession = client.sessionID
        client.selectResearchModel(deepseek)
        try await wait { !client.modelSwitching && client.conversationSelection == deepseek }
        func submitAndCheck(_ source: String, provider: String) async throws {
            guard let request = client.beginSelectionTranslation() else { throw ResearchMaterialError.message("Expected capture") }
            let text = "Synthetic route check: " + source
            client.finishSelectionTranslation(request, result: .success(
                try ResearchSelectionCapture.exactSelection(text, source: source, title: "Route fixture")))
            try await wait { client.conversationMessages.last?.reply?.material?.text == text && !client.hasPendingSubmission }
            precondition(client.conversationSelection?.provider == provider)
        }
        try await submitAndCheck("Fixture explicit paid choice", provider: "deepseek-account")
        client.startNewSession()
        precondition(client.sessionID == nil)
        try await submitAndCheck("Fresh scope", provider: "chatgpt")
        precondition(client.sessionID != firstSession)
        print("Verified explicit paid choice is local to one synthetic session; the next session used its subscription.")
        print("Passed five isolated selection submissions, stale/cancelled requests, draft isolation, trust diagnostics, Zotero response identity and byte limits.")
    }
}
