import AppKit
import SwiftUI
import WebKit

/// The system WebKit view stays alive while the message snapshot changes.
/// Only the display is parsed as Markdown. The bridge and clipboard keep the
/// original strings (including backslashes and control characters).
struct ResearchTranscript: NSViewRepresentable {
    let messages: [ResearchChatMessage]
    let historyRevision: Int
    let stream: ResearchChatMessage?
    let sessionID: String?
    let jump: Int
    let busy: String?
    let presentation: ResearchWindowPresentation

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        presentation.performReadingAction = { [weak coordinator] in coordinator?.performReadingAction($0) }
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("Transcript/index.html"),
              FileManager.default.fileExists(atPath: path.path) else {
            let text = NSTextView.scrollableTextView()
            if let document = text.documentView as? NSTextView { document.isEditable = false }
            return text
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.setAccessibilityIdentifier("research-companion.transcript")
        context.coordinator.attach(web, page: path)
        return web
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let native = view as? NSScrollView, let document = native.documentView as? NSTextView {
            let plainRows = messages.map(\.text) + (stream.map { [$0.text] } ?? [])
            let value = "排版资源未加载，此处显示原文。\n\n" + plainRows.joined(separator: "\n\n")
            if document.string != value { document.string = value }
            return
        }
        context.coordinator.update(messages, historyRevision: historyRevision, stream: stream,
                                   sessionID: sessionID, jump: jump, busy: busy ?? "")
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private struct Snapshot {
            let messages: [ResearchChatMessage]
            let historyRevision: Int
            let stream: ResearchChatMessage?
            let session: String
            let jump: Int
            let busy: String

            static func id(_ row: ResearchChatMessage) -> String { "\(row.role):\(row.id)" }

            private func wire(_ row: ResearchChatMessage, streaming: Bool) -> [String: Any] {
                var values: [String: Any] = ["id": Self.id(row), "role": row.role, "text": row.text,
                    "original": row.originalPrompt ?? "", "streaming": streaming]
                if !streaming, row.role == "assistant", row.reply?.material != nil,
                   let source = ResearchAnswerSource(session: session, answer: row).sourcePresentation {
                    // Display metadata only. Native retains the URL and file identity.
                    values["sourceDisplay"] = source.display
                    values["sourceTitle"] = source.title
                    if let page = source.page { values["sourcePage"] = page }
                    values["sourceDetails"] = source.details
                    values["canOpenSource"] = source.canOpen
                }
                return values
            }

            /// The scroll token and busy line can change without any new text.
            /// Revisit the history array only when the command client changes it.
            func update(after earlier: Snapshot?) -> [String: Any]? {
                let reset = earlier?.session != session
                let historyChanged = reset || earlier?.historyRevision != historyRevision
                let streamChanged = reset || earlier?.stream != stream
                guard historyChanged || streamChanged || earlier?.jump != jump || earlier?.busy != busy else { return nil }

                var rows: [[String: Any]] = []
                if historyChanged {
                    let previousRows = reset ? [] : earlier?.messages ?? []
                    let previous = Dictionary(previousRows.map { (Self.id($0), $0) },
                                              uniquingKeysWith: { _, latest in latest })
                    rows = messages.compactMap { row in
                        previous[Self.id(row)] != row ? wire(row, streaming: false) : nil
                    }
                }
                if streamChanged, let stream { rows.append(wire(stream, streaming: true)) }

                var data: [String: Any] = ["session": session, "jump": jump, "busy": busy, "rows": rows]
                let activeID = stream.map(Self.id)
                if historyChanged || earlier?.stream.map(Self.id) != activeID {
                    data["order"] = messages.map(Self.id) + (activeID.map { [$0] } ?? [])
                }
                return data
            }

            func rawText(for id: String) -> String? {
                if let stream, Self.id(stream) == id { return stream.text }
                guard let row = messages.first(where: { Self.id($0) == id }) else { return nil }
                return row.originalPrompt ?? row.text
            }

            func answer(for id: String) -> ResearchChatMessage? {
                messages.first { $0.role == "assistant" && Self.id($0) == id }
            }
        }

        private weak var web: WKWebView?
        private var page: URL?
        private var ready = false
        private var inFlight = false
        private var contentGeneration = 0
        private var request: Snapshot?
        private var applied: Snapshot?
        private var delivering: Snapshot?
        private var readingRequest: (token: String, session: String, action: ResearchReadingAction, expires: TimeInterval)?
        private var lastReadingAction: (action: ResearchReadingAction, time: TimeInterval)?

        private func readingWindow(_ web: WKWebView) -> NSWindow? {
            guard NSApp.isActive, let window = web.window, window.isKeyWindow, window.isVisible,
                  window.attachedSheet == nil else { return nil }
            return window
        }

        private func hasReadingFocus(_ web: WKWebView, in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder as? NSView else { return false }
            return responder === web || responder.isDescendant(of: web)
        }

        func performReadingAction(_ action: ResearchReadingAction) {
            guard ready, let web, let window = readingWindow(web), let current = request,
                  current.session == applied?.session else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let lastReadingAction, lastReadingAction.action == action, now - lastReadingAction.time < 0.7 { return }
            lastReadingAction = (action, now)
            let token = UUID().uuidString
            readingRequest = (token, current.session, action, now + 2)
            web.callAsyncJavaScript("window.ResearchTranscript.readingCommand(action, session, token, focused);",
                                    arguments: ["action": action.rawValue, "session": current.session,
                                                "token": token, "focused": hasReadingFocus(web, in: window)],
                                    in: nil, in: .page, completionHandler: nil)
        }

        private func consumeReadingRequest(_ token: String, body: [String: Any]) -> Bool {
            guard let request = readingRequest, request.token == token else { return false }
            readingRequest = nil
            guard request.expires >= ProcessInfo.processInfo.systemUptime,
                  request.session == body["session"] as? String,
                  request.session == self.request?.session,
                  let web, let window = readingWindow(web), hasReadingFocus(web, in: window) else { return false }
            switch request.action {
            case .saveSelection:
                return body["noteID"] is String && (
                    body["readingWholeAnswer"] as? Bool == true || !(body["selection"] as? String ?? "").isEmpty
                )
            case .openSource:
                return body["directSourceID"] is String
            }
        }
        private var savingNote = false
        private var latestNoteSave: String?
        private var savedNote: (id: String, result: ResearchNoteStorage.Saved)?

        func attach(_ web: WKWebView, page: URL) {
            self.web = web
            self.page = page
            web.configuration.userContentController.add(self, name: "researchTranscript")
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        func detach() {
            contentGeneration &+= 1
            readingRequest = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "researchTranscript")
            web?.navigationDelegate = nil
            web = nil
        }

        func update(_ messages: [ResearchChatMessage], historyRevision: Int, stream: ResearchChatMessage?,
                    sessionID: String?, jump: Int, busy: String) {
            let session = sessionID ?? ""
            if request?.session != session {
                latestNoteSave = nil
                savedNote = nil
            }
            request = Snapshot(messages: messages, historyRevision: historyRevision, stream: stream,
                               session: session, jump: jump, busy: busy)
            applyIfReady()
        }

        private func applyIfReady() {
            guard ready, !inFlight, let web, let request, let patch = request.update(after: applied) else { return }
            inFlight = true
            delivering = request
            let generation = contentGeneration
            web.callAsyncJavaScript("window.ResearchTranscript.update(patch);", arguments: ["patch": patch],
                                    in: nil, in: .page) { [weak self] result in
                guard let self, self.contentGeneration == generation else { return }
                self.inFlight = false
                self.delivering = nil
                if case .success = result {
                    self.applied = request
                    self.applyIfReady()
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The sole document is our sealed app resource. External links
            // are opened by the native app only on explicit user click.
            decisionHandler(navigationAction.targetFrame?.isMainFrame == true
                            && navigationAction.request.url?.standardizedFileURL == page?.standardizedFileURL
                            ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            contentGeneration &+= 1
            ready = false
            applied = nil
            delivering = nil
            inFlight = false
            readingRequest = nil
            if let page { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === web,
                  message.frameInfo.request.url?.standardizedFileURL == page?.standardizedFileURL,
                  let body = message.body as? [String: Any] else { return }
            let keyboardToken = body["readingToken"] as? String
            if let keyboardToken, !consumeReadingRequest(keyboardToken, body: body) { return }
            if body["ready"] as? Bool == true {
                ready = true
                applyIfReady()
            } else if let id = body["copyID"] as? String, let session = body["session"] as? String {
                for snapshot in [delivering, applied].compactMap({ $0 }) where snapshot.session == session {
                    if let raw = snapshot.rawText(for: id) { copy(raw); break }
                }
            } else if let id = body["directSourceID"] as? String,
                      let session = body["session"] as? String,
                      let current = request, current.session == session,
                      let row = current.answer(for: id), let window = web?.window,
                      window.attachedSheet == nil {
                // Resolve from the current answer's stored capture. HTML sends an ID, never a URL or path.
                ResearchAnswerActions.openOriginal(ResearchAnswerSource(session: session, answer: row), in: window) { [weak self] in
                    guard let self, self.request?.session == session else { return false }
                    guard keyboardToken != nil else { return true }
                    guard let web = self.web, let window = self.readingWindow(web) else { return false }
                    return self.hasReadingFocus(web, in: window)
                }
            } else if let session = body["session"] as? String,
                      let id = (body["sourceID"] ?? body["noteID"]) as? String,
                      let current = request, current.session == session,
                      let row = current.answer(for: id), let window = web?.window,
                      window.attachedSheet == nil {
                let source = ResearchAnswerSource(session: session, answer: row)
                if body["sourceID"] != nil {
                    ResearchAnswerActions.showSource(source, in: window)
                } else {
                    let selection = body["selection"] as? String ?? ""
                    guard !savingNote, selection.utf16.count <= 240_000 else { return }
                    let mode = ResearchNoteActions.Mode(rawValue: body["noteMode"] as? String ?? "quick")
                    guard let mode else { return }
                    savingNote = true
                    let saveID = UUID().uuidString
                    latestNoteSave = saveID
                    savedNote = nil
                    showNoteFeedback("", in: session)
                    Task { @MainActor in
                        defer { savingNote = false }
                        guard request?.session == session, latestNoteSave == saveID, window.attachedSheet == nil else { return }
                        do {
                            let result = try await ResearchNoteActions.save(source, selected: selection.isEmpty ? nil : selection,
                                                                            mode: mode, in: window)
                            guard let result, request?.session == session, latestNoteSave == saveID else { return }
                            savedNote = (saveID, result)
                            showNoteFeedback(result.status, in: session, revealID: saveID)
                        } catch {
                            guard request?.session == session, latestNoteSave == saveID else { return }
                            showNoteFeedback("笔记未保存。\(error.localizedDescription)", in: session)
                        }
                    }
                }
            } else if let id = body["noteRevealID"] as? String, let session = body["session"] as? String {
                revealSavedNote(id, in: session)
            } else if let tex = body["copyTeX"] as? String, tex.utf8.count <= 32_000 {
                copy(tex)
            } else if let value = body["openLink"] as? String, let url = URL(string: value),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                NSWorkspace.shared.open(url)
            }
        }

        private func showNoteFeedback(_ text: String, in session: String, revealID: String = "") {
            web?.callAsyncJavaScript("window.ResearchTranscript.noteSaved(text, session, revealID);",
                                     arguments: ["text": text, "session": session, "revealID": revealID],
                                     in: nil, in: .page, completionHandler: nil)
        }

        private func revealSavedNote(_ id: String, in session: String) {
            guard request?.session == session, let savedNote, savedNote.id == id,
                  let window = web?.window, window.isKeyWindow, NSApp.isActive else { return }
            let result = savedNote.result
            Task { [weak self, weak window] in
                let target = await Task.detached { Result { try result.revealTarget() } }.value
                guard let self, let window, self.web?.window === window, self.request?.session == session,
                      self.savedNote?.id == id, window.isKeyWindow, window.attachedSheet == nil, NSApp.isActive else { return }
                switch target {
                case .success(let url):
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    self.savedNote = nil
                    self.showNoteFeedback(error.localizedDescription, in: session)
                }
            }
        }

        private func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
