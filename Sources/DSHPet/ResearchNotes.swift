import AppKit
import PDFKit

struct ResearchAnswerSource {
    private static let captionNotice = "图注边界未能核实，已取得的摘录可能不完整。请打开原页核对。"

    let session: String
    let answer: ResearchChatMessage
    let local: ResearchProvenanceStore.LocalReference?
    private let store: ResearchProvenanceStore

    init(session: String, answer: ResearchChatMessage, store: ResearchProvenanceStore = .live, includePositions: Bool = true) {
        self.session = session
        self.answer = answer
        self.store = store
        local = answer.reply.flatMap { store.read(session: session, reply: $0, includePositions: includePositions) }
    }

    var material: ResearchSourceMaterial? { answer.reply?.material }

    // Read the validated sidecar only when an action needs its contents.
    private var completeSnapshot: ResearchProvenanceStore.LocalReference? {
        guard let local, let reply = answer.reply else { return nil }
        if local.positionDigest != nil, local.pdfPositions == nil,
           local.backgroundPositions == nil, local.verifiedExcerpts == nil {
            return store.read(session: session, reply: reply) ?? local
        }
        return local
    }

    var historicalObject: ResearchPDFObjectID? {
        guard local?.objectLabels == nil, let question = answer.reply?.question,
              local?.file != nil else { return nil }
        if case .anchors = ResearchPDFAddress.parse(question) { return nil }
        if case .quotation = ResearchPDFAddress.parse(question) { return nil }
        let ids = ResearchPDFObjectID.addresses(in: question)
        return ids.count == 1 ? ids[0] : nil
    }

    /// A legacy answer may reopen only positions already represented in the old captured
    /// excerpts. Newly resolved crop bounds are never attributed to the old request.
    func historicalObjectPositions(at url: URL, object: ResearchPDFObjectID, stored: [ResearchPDFSourcePosition]) -> [ResearchPDFSourcePosition] {
        guard object.kind != .equation, !stored.isEmpty, let material,
              let index = try? ResearchPDFIndex.read(url, title: material.title, progress: { _ in }),
              let target = try? index.objectEvidence([object], question: answer.reply?.question ?? ""),
              index.reference.fingerprint == local?.file?.fingerprint,
              let positions = target.material.pdfPositions, !positions.isEmpty else { return [] }
        return positions.first(where: { $0.blockRange != nil }).map { primary in
            stored.filter { saved in
                saved.page == primary.page && positions.contains { place in
                    guard place.page == saved.page, place.blockRange != nil,
                          let first = place.sourceRange, let second = saved.sourceRange else { return false }
                    return NSIntersectionRange(first, second).length == first.length &&
                        place.bounds.intersects(saved.bounds)
                }
            }
        } ?? []
    }

    var webURL: URL? {
        (local?.web ?? material?.url).flatMap(URL.init(string:)).flatMap(ResearchSourceLocation.webURL)
    }

    var zoteroURL: URL? { local?.zotero?.url ?? material.flatMap(ResearchSourceLocation.zoteroURL) }

    private var zoteroPhysicalPage: Int? {
        zoteroURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
            .first { $0.name == "page" }?.value.flatMap(Int.init)
    }

    private var zoteroPageLabel: String? { local?.zotero?.pageLabel ?? material?.pageLabel }

    var directTarget: ResearchDirectSource? {
        guard answer.role == "assistant", let reply = answer.reply, reply.requestId != nil else { return nil }
        if let zoteroURL { return .zotero(zoteroURL) }
        if let webURL { return .webpage(webURL) }
        if let file = local?.file { return .locatedFile(file, positions: local?.pdfPositions, pages: local?.pdfPages) }
        return backgroundTarget
    }

    var backgroundTarget: ResearchDirectSource? {
        guard let file = local?.backgroundFile else { return nil }
        return .locatedFile(file, positions: local?.backgroundPositions, pages: local?.backgroundPages)
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
        case .pdf(let file, _, _) where local?.file == nil:
            name = URL(fileURLWithPath: file.originalPath).lastPathComponent
        case .file(let file), .pdf(let file, _, _):
            name = title.isEmpty ? URL(fileURLWithPath: file.originalPath).lastPathComponent : title
        default:
            name = title.isEmpty ? "材料" : title
        }
        // The visible page comes from the validated Zotero route, never from
        // an untyped display label or a page mentioned in the answer.
        let pdfPage = zoteroPhysicalPage
        let page: String?
        if let pdfPage { page = "PDF 文件第 \(pdfPage) 页" }
        else if case .pdf = target, local?.file == nil { page = local?.backgroundPages.map { "背景 PDF 摘录页 " + $0 } }
        else { page = local?.pdfPages.map { "摘录页 " + $0 } }
        let label = pdfPage == nil ? nil : zoteroPageLabel?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let readerLabel = label.flatMap { value in
            value.isEmpty ? nil : "阅读器页标签 \(value)"
        }
        let labels = local?.objectLabels ?? []
        let object = labels.isEmpty ? nil : labels.joined(separator: " · ")
        let display = [object, name, page].compactMap { $0 }.joined(separator: " · ")
        let website: String?
        if case .webpage(let link) = target, link.host != name { website = link.host } else { website = nil }
        let warning = evidenceWarning
        let details = [display, readerLabel, website, target?.help, warning].compactMap { $0 }.joined(separator: " · ")
        return ResearchSourcePresentation(title: name, page: page, objects: object,
                                          display: display, details: details, warning: warning, canOpen: target != nil)
    }

    private var evidenceWarning: String? {
        if let gaps = local?.evidenceChecks?.filter({ $0.status != .verified }), !gaps.isEmpty {
            return "未完整核验 " + gaps.map(\.target).joined(separator: "、")
        }
        return local?.hasPartialCaption == true ? Self.captionNotice : nil
    }

    var descriptionLines: [String] {
        guard let material else { return ["此回答没有已记录的材料。旧会话可能缺少来源信息。"] }
        let physicalPage = zoteroPhysicalPage.map { "PDF 第 \($0) 页（文件位置）" }
        let lines: [String?] = [
            webURL?.absoluteString ?? zoteroURL?.absoluteString ?? local?.file?.originalPath ?? material.source,
            material.scope,
            physicalPage,
            zoteroPageLabel.map { "页面标签 \($0)" },
            local?.pdfPages.map { "PDF 文件摘录页 " + $0 },
            local?.objectLabels.map { "主要目标 " + $0.joined(separator: "、") },
            evidenceWarning,
            local?.imageFingerprints.map { "本轮附带 \($0.count) 处原页裁图" },
            local?.backgroundFile.map { "辅助依据 " + $0.originalPath },
            local?.backgroundPages.map { "辅助依据文件页 " + $0 },
        ]
        return lines.compactMap { $0 }
    }

    var noteSourceTitle: String? { material.flatMap { Self.noteMetadata($0.title) } }

    private static func noteMetadata(_ value: String) -> String? {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.utf16.count <= 512,
              text.range(of: #"(?i)://|(?:^|\s)~?/\S|\b(?:token|password|key)=|\bBearer\s+|[\u0000-\u001f\u007f]"#,
                         options: .regularExpression) == nil else { return nil }
        return text
    }

    private static func markdownMetadata(_ text: String) -> String {
        String(text.flatMap { character in
            "\\`*_{}[]()#+-!|<>&".contains(character) ? ["\\", character] : [character]
        })
    }

    struct NoteContents: Sendable {
        struct Quotation: Sendable {
            let record: ResearchVerifiedExcerpt
            let text: String
        }
        let question: String?
        let hasMaterial: Bool
        let imageCount: Int
        let quotations: [Quotation]
        var incompleteEvidence = false

        var hasPartialCaption: Bool {
            quotations.contains { $0.record.kind == .caption && $0.record.partial == true }
        }

        var exportWarning: String? {
            if hasMaterial && quotations.isEmpty { return "此回答没有可核验的文字摘录。" }
            if hasPartialCaption { return "图注可能不完整。" }
            if incompleteEvidence { return "本轮材料仍有未核验的证据。" }
            return nil
        }
    }

    func noteContents() -> NoteContents {
        let question = answer.reply.flatMap { store.originalQuestion(in: $0, reference: local) }
        let excerpts = completeSnapshot?.verifiedExcerpts
        let quotations: [NoteContents.Quotation] = material.map { material in
            (excerpts ?? []).compactMap { record in
                record.text(in: material.text).map { .init(record: record, text: $0) }
            }
        } ?? []
        return NoteContents(question: question, hasMaterial: material != nil,
                            imageCount: local?.imageFingerprints?.count ?? 0, quotations: quotations,
                            incompleteEvidence: local?.evidenceChecks?.contains { $0.status != .verified } == true)
    }

    func markdown(interpretation: String, supplement: String, savedAt: Date,
                  contents: NoteContents? = nil) -> String {
        let contents = contents ?? noteContents()
        func quote(_ text: String) -> String {
            let longest = text.split(whereSeparator: { $0 != "~" }).map(\.count).max() ?? 0
            let fence = String(repeating: "~", count: max(3, longest + 1))
            return (["> " + fence + "text"] + text.components(separatedBy: "\n").map { "> " + $0 } + ["> " + fence])
                .joined(separator: "\n")
        }
        let iso = ISO8601DateFormatter()
        var sections = ["# 科研笔记\n\n保存时间 \(iso.string(from: savedAt))"]
        if let reply = answer.reply {
            var questionLines = [contents.question.map(quote) ?? "本次问题的原始内容未能核验。"]
            if let time = reply.time { questionLines.append("提问时间 \(iso.string(from: Date(timeIntervalSince1970: time / 1000)))") }
            sections.append("## 问题与上下文\n\n" + questionLines.joined(separator: "\n\n"))
        }
        sections.append("## AI 解释\n\n" + interpretation)
        var details: [String] = []
        if material != nil {
            let sourceTitle = noteSourceTitle.map(Self.markdownMetadata) ?? "材料"
            details.append("材料：\(sourceTitle)")
            if let pages = local?.pdfPages, pages.range(of: #"^[0-9–、,-]+$"#, options: .regularExpression) != nil {
                details.append("PDF 文件页：\(pages)")
            } else if let filePage = zoteroPhysicalPage {
                details.append("PDF 文件页：\(filePage)")
                if let label = zoteroPageLabel.flatMap(Self.noteMetadata) {
                    details.append("阅读器页标签：\(Self.markdownMetadata(label))")
                }
            }
            if let doi = ResearchVerifiedExcerpt.doi(from: webURL) { details.append("DOI：\(doi)") }
            if contents.hasPartialCaption { details.append(Self.captionNotice) }
            if let gaps = local?.evidenceChecks?.filter({ $0.status != .verified }), !gaps.isEmpty {
                let labels = gaps.compactMap { Self.noteMetadata($0.target) }.map(Self.markdownMetadata)
                if !labels.isEmpty { details.append("未完整核验的证据：" + labels.joined(separator: "、")) }
            }
            if contents.imageCount > 0 {
                details.append("此轮关联 \(contents.imageCount) 处原页裁图，Markdown 仅导出文字。原页可在会话的来源中打开。")
            }
            let quotations = contents.quotations.map { quotation -> String in
                let record = quotation.record
                var label = [record.kind.label, Self.markdownMetadata(Self.noteMetadata(record.title) ?? "材料")]
                if let page = record.page, page > 0 { label.append("PDF 文件第 \(page) 页") }
                if let doi = ResearchVerifiedExcerpt.validatedDOI(record.doi) { label.append("DOI " + doi) }
                if record.ocr == true { label.append("本机 OCR") }
                if record.partial == true { label.append("局部摘录") }
                return "### " + label.joined(separator: " · ") + "\n\n" + quote(quotation.text)
            }
            details += quotations.isEmpty ? ["此回答没有可独立核验的文字摘录。"] : quotations
        } else {
            details.append("此回答没有已记录的材料。")
        }
        sections.append("## 材料来源与原文摘录\n\n" + details.joined(separator: "\n\n"))
        if !supplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## 用户补充\n\n" + supplement)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}

struct ResearchSourcePresentation {
    let title: String
    let page: String?
    let objects: String?
    let display: String
    let details: String
    let warning: String?
    let canOpen: Bool
}

enum ResearchDirectSource: Sendable {
    case zotero(URL)
    case webpage(URL)
    case file(ResearchFileReference)
    case pdf(ResearchFileReference, positions: [ResearchPDFSourcePosition], firstPage: Int)

    static func locatedFile(_ file: ResearchFileReference, positions: [ResearchPDFSourcePosition]?, pages: String?) -> Self {
        guard URL(fileURLWithPath: file.originalPath).pathExtension.lowercased() == "pdf" else { return .file(file) }
        // Older snapshots carry only one-based page lists (e.g. 2–4、7).
        let first = positions?.first?.page ?? pages.flatMap { Int($0.prefix(while: \.isNumber)) }
        guard let first, first > 0 else { return .file(file) }
        return .pdf(file, positions: positions ?? [], firstPage: first)
    }

    var help: String {
        switch self {
        case .zotero(let url):
            url.query == nil ? "打开当时的 Zotero 附件" : "定位到当时的 Zotero PDF 页"
        case .webpage:
            "打开保存的网址。网站不可达时由浏览器提示。"
        case .pdf(_, let positions, _):
            positions.isEmpty ? "定位到当时的 PDF 原文" : "查看 PDF 中标记的原文位置"
        case .file:
            "打开当时的本机文件"
        }
    }

    var openFailure: String {
        switch self {
        case .zotero: "无法打开该 Zotero 附件。请检查 Zotero 是否可用，或打开「来源」核对摘录。"
        case .webpage: "无法在浏览器打开保存的网址。可在「来源」核对网址和摘录。"
        case .file, .pdf: "无法打开该本机文件。可在「来源」核对路径或重新定位。"
        }
    }

    func resolve() async -> URL? {
        switch self {
        case .zotero(let url), .webpage(let url): return url
        case .file(let reference), .pdf(let reference, _, _): return await Task.detached { reference.resolve() }.value
        }
    }
}

extension ResearchAnswerSource {
    func pdfNavigation(for file: ResearchFileReference, background: Bool) ->
        (positions: [ResearchPDFSourcePosition], targets: [ResearchPDFEvidenceReader.Target]) {
        guard let detail = completeSnapshot else { return ([], []) }
        // Both sets may point into one verified file, or to two independent sources.
        // Never project coordinates from a different PDF onto this document.
        let primary = detail.file?.fingerprint == file.fingerprint ? detail.pdfPositions ?? [] : []
        let supporting = detail.backgroundFile?.fingerprint == file.fingerprint ? detail.backgroundPositions ?? [] : []
        let groups = detail.sourceGroups ?? []
        let ordered = background ? groups.filter { $0.role == .context } + groups.filter { $0.role != .context } : groups
        let targets = ordered.compactMap { group -> ResearchPDFEvidenceReader.Target? in
            guard let positions = group.positions(in: primary, background: supporting) else { return nil }
            return .init(title: group.title, positions: positions)
        }
        return (background || detail.file == nil ? supporting : primary, targets)
    }
}

@MainActor
enum ResearchAnswerActions {
    private static var openingWebPages: Set<URL> = []

    static func openOriginal(_ source: ResearchAnswerSource, in window: NSWindow,
                             ifCurrent: @escaping () -> Bool = { true }) {
        guard let target = source.directTarget else { return }
        open(target, source: source, background: false, in: window, ifCurrent: ifCurrent)
    }

    private static func open(_ target: ResearchDirectSource, source: ResearchAnswerSource, background: Bool,
                             in window: NSWindow, ifCurrent: @escaping () -> Bool = { true },
                             showHistoricalExcerpts: Bool = false) {
        Task { [weak window] in
            if case .pdf(let reference, let positions, let page) = target {
                // Verify the very bytes the reader will display, including when the bookmark follows a move.
                let result = await Task.detached(priority: .userInitiated) { () throws -> ResearchPDFEvidenceReader.Prepared? in
                    guard let (url, data) = reference.verifiedPDF() else { return nil }
                    let navigation = source.pdfNavigation(for: reference, background: background)
                    let detail = navigation.positions.isEmpty ? positions : navigation.positions
                    if !background, !showHistoricalExcerpts, let historical = source.historicalObject {
                        let recovered = source.historicalObjectPositions(at: url, object: historical, stored: detail)
                        guard let first = recovered.first else { return nil }
                        return try ResearchPDFEvidenceReader.prepare(data: data, filename: url.lastPathComponent,
                                                                     positions: recovered, firstPage: first.page)
                    }
                    return try ResearchPDFEvidenceReader.prepare(data: data, filename: url.lastPathComponent,
                                                                 positions: detail, firstPage: page,
                                                                 targets: navigation.targets)
                }.result
                guard ifCurrent(), let window, window.isVisible, window.attachedSheet == nil else { return }
                switch result {
                case .success(let prepared?):
                    ResearchPDFEvidenceReader.present(prepared, in: window)
                case .success(nil):
                    if background { relink(source, background: true, in: window) }
                    else if !showHistoricalExcerpts, source.historicalObject != nil {
                        let original = await target.resolve()
                        guard ifCurrent(), window.isVisible, window.attachedSheet == nil else { return }
                        presentSource(source, file: original, in: window, historicalPrecisionMissing: original != nil)
                    } else { presentSource(source, file: nil, in: window) }
                case .failure(let error):
                    showError(error.localizedDescription, in: window)
                }
                return
            }
            let url = await target.resolve()
            guard ifCurrent(), let window, window.isVisible, window.attachedSheet == nil else { return }
            guard let url else {
                if background { relink(source, background: true, in: window) }
                else { presentSource(source, file: nil, in: window) }
                return
            }
            let isWebPage: Bool
            if case .webpage = target { isWebPage = true } else { isWebPage = false }
            guard !isWebPage || openingWebPages.insert(url).inserted else { return }
            defer { if isWebPage { openingWebPages.remove(url) } }
            let valid = { [weak window] in
                ifCurrent() && window?.isVisible == true && window?.attachedSheet == nil
            }
            if isWebPage, await ResearchBrowserNavigation.revealOpenPage(url, source: source.material?.source, ifCurrent: valid) { return }
            guard valid() else { return }
            do {
                _ = try await NSWorkspace.shared.open(url, configuration: .init())
            } catch {
                if valid() { showError(target.openFailure, in: window) }
            }
        }
    }

    static func showSource(_ source: ResearchAnswerSource, in window: NSWindow,
                           ifCurrent: @escaping () -> Bool = { true }) {
        let reference = source.local?.file
        Task { [weak window] in
            let resolved = await Task.detached { reference?.resolve() }.value
            guard ifCurrent(), let window, window.isVisible, window.attachedSheet == nil else { return }
            presentSource(source, file: resolved, in: window)
        }
    }

    private static func presentSource(_ source: ResearchAnswerSource, file: URL?, in window: NSWindow,
                                      historicalPrecisionMissing: Bool = false) {
        let alert = NSAlert()
        alert.messageText = source.material?.title ?? "这条回答的材料"
        var lines = source.descriptionLines
        if historicalPrecisionMissing { lines.append("历史快照没有可确认的目标原文位置。下方是当时记录的摘录。") }
        if let expected = source.local?.file?.originalPath {
            if let file, file.path != expected { lines.append("文件已移动。已找到内容一致的文件：\(file.path)") }
            if file == nil { lines.append("原文件已移动、移除或变更。可选取内容一致的文件重新定位。") }
        } else if source.directTarget == nil && source.material != nil {
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
        var actions: [@MainActor () -> Void] = []
        if canRelink {
            alert.addButton(withTitle: "重新定位…")
            actions.append { relink(source, in: window) }
        }
        if historicalPrecisionMissing, let target = source.directTarget {
            alert.addButton(withTitle: "查看历史摘录位置")
            actions.append { open(target, source: source, background: false, in: window, showHistoricalExcerpts: true) }
        }
        if let target = source.backgroundTarget {
            alert.addButton(withTitle: "打开辅助依据")
            actions.append { open(target, source: source, background: true, in: window) }
        }
        if let text = source.material?.text {
            alert.addButton(withTitle: "复制摘录")
            actions.append {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        alert.addButton(withTitle: "关闭").keyEquivalent = "\u{1b}"
        let choices = actions
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if choices.indices.contains(index) { Task { @MainActor in choices[index]() } }
        }
    }

    private static func relink(_ source: ResearchAnswerSource, background: Bool = false, in window: NSWindow) {
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
                    try await Task.detached { try ResearchProvenanceStore.live.relink(session: session, reply: reply, file: url, background: background) }.value
                    showSource(ResearchAnswerSource(session: session, answer: source.answer, includePositions: false), in: window)
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
