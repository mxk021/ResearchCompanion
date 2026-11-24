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
    var didDisplay: ((String, ResearchChatMessage?, ResearchChatMessage?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

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
                                   sessionID: sessionID, jump: jump, didDisplay: didDisplay)
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

            static func id(_ row: ResearchChatMessage) -> String { "\(row.role):\(row.id)" }

            private func wire(_ row: ResearchChatMessage, streaming: Bool) -> [String: Any] {
                var values: [String: Any] = ["id": Self.id(row), "role": row.role, "text": row.text,
                    "original": row.originalPrompt ?? "", "streaming": streaming]
                if !streaming, row.role == "assistant", row.reply?.material != nil,
                   let source = ResearchAnswerSource(session: session, answer: row, includePositions: false).sourcePresentation {
                    // Display metadata only. Native retains the URL and file identity.
                    values["sourceDisplay"] = source.display
                    values["sourceTitle"] = source.title
                    if let page = source.page { values["sourcePage"] = page }
                    if let objects = source.objects { values["sourceObjects"] = objects }
                    values["sourceDetails"] = source.details
                    if let warning = source.warning { values["sourceWarning"] = warning }
                    values["canOpenSource"] = source.canOpen
                }
                return values
            }

            /// The scroll token can change without any new text.
            /// Revisit the history array only when the command client changes it.
            func update(after earlier: Snapshot?, appendStream: Bool) -> [String: Any]? {
                let reset = earlier?.session != session
                let historyChanged = reset || earlier?.historyRevision != historyRevision
                let streamChanged = reset || earlier?.stream != stream
                guard historyChanged || streamChanged || earlier?.jump != jump else { return nil }

                var rows: [[String: Any]] = []
                if historyChanged {
                    let previousRows = reset ? [] : earlier?.messages ?? []
                    let previous = Dictionary(previousRows.map { (Self.id($0), $0) },
                                              uniquingKeysWith: { _, latest in latest })
                    rows = messages.compactMap { row in
                        previous[Self.id(row)] != row ? wire(row, streaming: false) : nil
                    }
                }
                if streamChanged, let stream {
                    var row = wire(stream, streaming: true)
                    if appendStream, !reset, let previous = earlier?.stream, Self.id(previous) == Self.id(stream) {
                        let prefix = previous.text.utf8
                        let text = stream.text.utf8
                        if !prefix.isEmpty, prefix.count < text.count, text.starts(with: prefix) {
                            // Use a byte-exact prefix check. Swift String equality
                            // can treat distinct Unicode representations as equal.
                            row["appendAfterUTF16"] = previous.text.utf16.count
                            row["text"] = String(decoding: text.dropFirst(prefix.count), as: UTF8.self)
                        }
                    }
                    rows.append(row)
                }

                var data: [String: Any] = ["session": session, "jump": jump, "rows": rows]
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
        private var didDisplay: ((String, ResearchChatMessage?, ResearchChatMessage?) -> Void)?
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
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "researchTranscript")
            web?.navigationDelegate = nil
            web = nil
        }

        func update(_ messages: [ResearchChatMessage], historyRevision: Int, stream: ResearchChatMessage?,
                    sessionID: String?, jump: Int,
                    didDisplay: ((String, ResearchChatMessage?, ResearchChatMessage?) -> Void)? = nil) {
            self.didDisplay = didDisplay
            let session = sessionID ?? ""
            if request?.session != session {
                latestNoteSave = nil
                savedNote = nil
            }
            request = Snapshot(messages: messages, historyRevision: historyRevision, stream: stream,
                               session: session, jump: jump)
            applyIfReady()
        }

        private func applyIfReady(appendStream: Bool = true) {
            guard ready, !inFlight, let web, let request,
                  let patch = request.update(after: applied, appendStream: appendStream) else { return }
            let usesAppend = (patch["rows"] as? [[String: Any]])?.contains { $0["appendAfterUTF16"] != nil } == true
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
                    if NSApp.isActive, web.window?.isVisible == true, web.window?.isMiniaturized == false {
                        let finalAnswer = request.messages.last { $0.role == "assistant" }
                        self.didDisplay?(request.session, request.stream, finalAnswer)
                    }
                    self.applyIfReady()
                } else if usesAppend {
                    // A lost base must never stall a reply. Send the latest
                    // complete tail once, including any intervening update.
                    self.applyIfReady(appendStream: false)
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
            if let page { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === web,
                  message.frameInfo.request.url?.standardizedFileURL == page?.standardizedFileURL,
                  let body = message.body as? [String: Any] else { return }
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
                ResearchAnswerActions.openOriginal(ResearchAnswerSource(session: session, answer: row, includePositions: false), in: window) { [weak self] in
                    self?.request?.session == session && self?.request?.answer(for: id) == row
                }
            } else if let session = body["session"] as? String,
                      let id = (body["sourceID"] ?? body["noteID"]) as? String,
                      let current = request, current.session == session,
                      let row = current.answer(for: id), let window = web?.window,
                      window.attachedSheet == nil {
                let source = ResearchAnswerSource(session: session, answer: row, includePositions: false)
                if body["sourceID"] != nil {
                    ResearchAnswerActions.showSource(source, in: window) { [weak self] in
                        self?.request?.session == session && self?.request?.answer(for: id) == row
                    }
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
                        let isCurrent = { self.request?.session == session && self.latestNoteSave == saveID
                            && self.request?.answer(for: id) == row }
                        guard isCurrent(), window.attachedSheet == nil else { return }
                        do {
                            let result = try await ResearchNoteActions.save(source, selected: selection.isEmpty ? nil : selection,
                                                                            mode: mode, in: window, ifCurrent: isCurrent)
                            guard isCurrent() else { return }
                            guard let result else { showNoteFeedback("", in: session); return }
                            savedNote = (saveID, result.note)
                            let feedback = [result.note.status, result.warning].compactMap { $0 }.joined(separator: " · ")
                            showNoteFeedback(feedback, in: session, revealID: saveID)
                        } catch {
                            guard isCurrent() else { return }
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
