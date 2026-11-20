import AppKit

struct ResearchAnswerSource {
    let session: String
    let answer: ResearchChatMessage
    let local: ResearchProvenanceStore.LocalReference?

    init(session: String, answer: ResearchChatMessage, store: ResearchProvenanceStore = .live) {
        self.session = session
        self.answer = answer
        local = answer.reply.flatMap { store.read(session: session, reply: $0) }
    }

    var material: ResearchSourceMaterial? { answer.reply?.material }

    var webURL: URL? {
        (local?.web ?? material?.url).flatMap(URL.init(string:)).flatMap(ResearchSourceLocation.webURL)
    }

    var zoteroURL: URL? { material.flatMap(ResearchSourceLocation.zoteroURL) }

    var directTarget: ResearchDirectSource? {
        guard answer.role == "assistant", let reply = answer.reply, reply.requestId != nil else { return nil }
        if let zoteroURL { return .zotero(zoteroURL) }
        if let webURL { return .webpage(webURL) }
        if let file = local?.file { return .file(file) }
        return nil
    }

    var sourcePresentation: ResearchSourcePresentation? {
        guard let material else { return nil }
        let title = material.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let target = directTarget
        let name: String
        switch target {
        case .webpage(let url):
            name = title.isEmpty || ["浏览器选区", "Safari选区", "Safari 选区"].contains(title)
                ? (url.host ?? "网页") : title
        case .file(let file):
            name = title.isEmpty ? URL(fileURLWithPath: file.originalPath).lastPathComponent : title
        default:
            name = title.isEmpty ? "材料" : title
        }
        // The visible page comes from the validated Zotero route, never from
        // an untyped display label or a page mentioned in the answer.
        let pdfPage: Int?
        if case .zotero(let url) = target {
            pdfPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "page" }?.value.flatMap(Int.init)
        } else {
            pdfPage = nil
        }
        let page = pdfPage.map { "PDF 文件第 \($0) 页" } ?? local?.pdfPages.map { "摘录页 \($0)" }
        let label = pdfPage == nil ? nil : material.pageLabel?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let readerLabel = label.flatMap { value in
            value.isEmpty ? nil : "阅读器页标签 \(value)"
        }
        let display = [name, page].compactMap { $0 }.joined(separator: " · ")
        let website: String?
        if case .webpage(let link) = target, link.host != name { website = link.host } else { website = nil }
        let details = [display, readerLabel, website, target?.help].compactMap { $0 }.joined(separator: " · ")
        return ResearchSourcePresentation(title: name, page: page, display: display, details: details, canOpen: target != nil)
    }

    var descriptionLines: [String] {
        guard let material else { return ["此回答没有已记录的材料。旧会话可能缺少来源信息。"] }
        return [
            webURL?.absoluteString ?? zoteroURL?.absoluteString ?? local?.file?.originalPath ?? material.source,
            material.scope,
            material.pageIndex.map { "PDF 第 \($0 + 1) 页（文件位置）" },
            material.pageLabel.map { "页面标签 \($0)" },
            local?.backgroundFile.map { "会话背景文件 " + $0.originalPath },
            local?.backgroundPages.map { "背景文件摘录页 " + $0 },
        ].compactMap { $0 }
    }

    func markdown(interpretation: String, supplement: String, savedAt: Date) -> String {
        func quote(_ text: String) -> String {
            text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        let iso = ISO8601DateFormatter()
        var sections = ["# 科研笔记\n\n保存时间 \(iso.string(from: savedAt))"]
        if let reply = answer.reply {
            var questionLines = [quote(reply.question)]
            if let time = reply.time { questionLines.append("提问时间 \(iso.string(from: Date(timeIntervalSince1970: time / 1000)))") }
            sections.append("## 问题与上下文\n\n" + questionLines.joined(separator: "\n\n"))
        }
        sections.append("## AI 解释\n\n" + interpretation)
        var details = descriptionLines
        if let material {
            details.insert(material.title, at: 0)
            details.append(material.text)
        }
        sections.append("## 材料来源与原文摘录\n\n" + details.map(quote).joined(separator: "\n>\n"))
        if !supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## 用户补充\n\n" + supplement)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}

struct ResearchSourcePresentation {
    let title: String
    let page: String?
    let display: String
    let details: String
    let canOpen: Bool
}

enum ResearchDirectSource: Sendable {
    case zotero(URL)
    case webpage(URL)
    case file(ResearchFileReference)

    var help: String {
        switch self {
        case .zotero(let url):
            url.query == nil ? "打开当时的 Zotero 附件" : "定位到当时的 Zotero PDF 页"
        case .webpage:
            "打开保存的网址。网站不可达时由浏览器提示。"
        case .file:
            "打开当时的本机文件"
        }
    }

    var openFailure: String {
        switch self {
        case .zotero: "无法打开该 Zotero 附件。请检查 Zotero 是否可用，或打开「来源」核对摘录。"
        case .webpage: "无法在浏览器打开保存的网址。可在「来源」核对网址和摘录。"
        case .file: "无法打开该本机文件。可在「来源」核对路径或重新定位。"
        }
    }

    func resolve() async -> URL? {
        switch self {
        case .zotero(let url), .webpage(let url): return url
        case .file(let reference): return await Task.detached { reference.resolve() }.value
        }
    }
}

@MainActor
enum ResearchAnswerActions {
    static func openOriginal(_ source: ResearchAnswerSource, in window: NSWindow,
                             ifCurrent: @escaping () -> Bool = { true }) {
        guard let target = source.directTarget else { return }
        Task { [weak window] in
            let url = await target.resolve()
            guard ifCurrent(), let window, window.isVisible, window.attachedSheet == nil else { return }
            guard let url else {
                // A missing or changed file keeps its original excerpt and offers re-linking.
                presentSource(source, file: nil, in: window)
                return
            }
            do {
                _ = try await NSWorkspace.shared.open(url, configuration: .init())
            } catch {
                if window.isVisible, window.attachedSheet == nil {
                    showError(target.openFailure, in: window)
                }
            }
        }
    }

    static func showSource(_ source: ResearchAnswerSource, in window: NSWindow) {
        let reference = source.local?.file
        Task { [weak window] in
            let resolved = await Task.detached { reference?.resolve() }.value
            guard let window, window.isVisible, window.attachedSheet == nil else { return }
            presentSource(source, file: resolved, in: window)
        }
    }

    private static func presentSource(_ source: ResearchAnswerSource, file: URL?, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = source.material?.title ?? "这条回答的材料"
        var lines = source.descriptionLines
        if let expected = source.local?.file?.originalPath {
            if let file, file.path != expected { lines.append("文件已移动。已找到内容一致的文件：\(file.path)") }
            if file == nil { lines.append("原文件已移动、移除或变更。可选取内容一致的文件重新定位。") }
        } else if source.zoteroURL == nil && source.webURL == nil && source.material != nil {
            lines.append("没有可用的来源定位。仍可复制当时发送的摘录。")
        }
        alert.informativeText = lines.joined(separator: "\n")
        if let excerpt = source.material?.text {
            let preview = NSTextView.scrollableTextView()
            preview.frame = NSRect(x: 0, y: 0, width: 410, height: 120)
            if let text = preview.documentView as? NSTextView {
                text.string = excerpt
                text.isEditable = false
                text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                text.textContainerInset = NSSize(width: 6, height: 5)
            }
            alert.accessoryView = preview
        }
        let canRelink = source.local?.file != nil && file == nil
        if canRelink { alert.addButton(withTitle: "重新定位…") }
        if source.material != nil { alert.addButton(withTitle: "复制摘录") }
        alert.addButton(withTitle: "关闭").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                if canRelink, response == .alertFirstButtonReturn {
                    relink(source, in: window)
                } else if let text = source.material?.text,
                          response == (canRelink ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    private static func relink(_ source: ResearchAnswerSource, in window: NSWindow) {
        guard let reply = source.answer.reply else { return }
        let panel = NSOpenPanel()
        panel.message = "请选择与原始材料内容一致的文件。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let session = source.session
                    try await Task.detached { try ResearchProvenanceStore.live.relink(session: session, reply: reply, file: url) }.value
                    showSource(ResearchAnswerSource(session: session, answer: source.answer), in: window)
                } catch { showError(error.localizedDescription, in: window) }
            }
        }
    }

    private static func showError(_ text: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
}
