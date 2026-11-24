import AppKit
import ApplicationServices
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A captured selection, an indexed attachment, or the evidence prepared for one request.
struct ResearchMaterial: Equatable, Sendable {
    static let selectionServiceSource = "系统服务"
    static let maximumLength = 24_000
    static let localSelectionLimit = 1_048_576
    static let oversizeMessage = "已完整保留本机选区。单次材料上限为 24,000 个 UTF‑16 字符，请缩小选区后再发送。"
    var id = UUID()
    let source: String
    let title: String
    var text: String
    var scope: String
    var url: String?
    var page: String?
    var fileReference: ResearchFileReference? = nil
    var localWebURL: String? = nil
    var zoteroLocation: ResearchZoteroLocation? = nil
    var selectionIsComplete = false
    var pdfIndex: ResearchPDFIndex? = nil
    var pdfPages: String? = nil
    var backgroundFile: ResearchFileReference? = nil
    var backgroundPages: String? = nil
    var pdfPositions: [ResearchPDFSourcePosition]? = nil
    var backgroundPositions: [ResearchPDFSourcePosition]? = nil
    var objectLabels: [String]? = nil
    var sourceGroups: [ResearchPDFSourceGroup]? = nil
    var documentImages: [Data] = []
    var verifiedExcerpts: [ResearchVerifiedExcerpt]? = nil
    var evidenceChecks: [ResearchPDFEvidenceCheck]? = nil

    var fields: [String: String] {
        var value = ["source": source, "title": title, "text": text, "scope": scope]
        if let url { value["url"] = url }
        if let page { value["page"] = page }
        return value
    }

    static func bounded(_ source: String, limit: Int = maximumLength) -> String {
        if source.utf16.count <= limit { return source }
        var end = source.startIndex
        var length = 0
        while end < source.endIndex {
            let next = source.index(after: end)
            length += source[end..<next].utf16.count
            if length > limit { break }
            end = next
        }
        return String(source[..<end])
    }

    static func hasReadableText(_ text: String) -> Bool {
        var total = 0
        var bad = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 0 { return false }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            total += 1
            if scalar == "\u{fffd}" || scalar.properties.generalCategory == .privateUse ||
                CharacterSet.controlCharacters.contains(scalar) { bad += 1 }
        }
        return total > 0 && bad * 10 < total
    }

    static func selection(_ original: String, source: String, title: String, url: String? = nil) throws -> Self {
        guard original.utf16.count <= localSelectionLimit else { throw SelectionCaptureError.tooLarge }
        guard hasReadableText(original) else { throw ResearchMaterialError.message("没有可读取的选中文字。") }
        return Self(source: source, title: title, text: original,
                    scope: "当前选区 · \(original.utf16.count) 个 UTF‑16 字符", url: url, selectionIsComplete: true,
                    verifiedExcerpts: [.init(kind: .selection, range: NSRange(location: 0, length: original.utf16.count),
                                             title: title, doi: ResearchVerifiedExcerpt.doi(from: url.flatMap(URL.init(string:))))])
    }

    /// Only combine excerpts on an explicit reference to the associated document.
    static func requestsFileBackground(_ question: String, filename: String?) -> Bool {
        let ignore = #"(?:不要|不用|无需|不必|忽略|不参考|不结合)[^，。；;,.]{0,14}(?:文件|论文|文献|附件|PDF)|(?:只|仅)[^，。；;,.]{0,8}(?:选区|所选|选中)|\b(?:ignore|without|do not (?:use|reference))\b[^,.;]{0,26}\b(?:paper|file|document|pdf)|\b(?:only (?:the )?(?:selection|selected text)|(?:selection|selected text) only)\b"#
        if question.range(of: ignore, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if let filename, question.localizedCaseInsensitiveContains(filename) { return true }
        let reference = #"(?:会话文件|当前文件|附件中|本文中|论文中|(?:结合|参照|参考|对照|查看|依据|根据|比较)[^，。；;,.]{0,10}(?:论文|本文|文献|文件|附件|PDF)|(?:第\s*)?\d+\s*页|末页|最后一页|中间页|\b(?:attached|uploaded)\s+(?:file|paper|document|PDF)\b|\b(?:in|from|using|against|to) the (?:paper|file|document|PDF)\b|\b(?:page[s]?\s+\d+|(?:last|first|middle|final) page)\b)"#
        return question.range(of: reference, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func addingBackground(_ file: Self, question: String) throws -> Self {
        let searchText = String(text.prefix(1_200))
        let background: Self
        if let index = file.pdfIndex {
            background = try index.retrieve(question, backgroundKeywords: searchText)
        } else {
            background = try file.relevantText(question: question, selection: searchText)
        }
        return try withBackgroundEvidence(background)
    }

    func withBackgroundEvidence(_ background: Self, reviewedOrder: Bool = false) throws -> Self {
        let location = [source, title, page.map { "页标签 " + $0 }].compactMap { $0 }.joined(separator: " · ")
        let range = background.pdfPages.map { " · PDF 文件页 " + $0 } ?? ""
        let selectionHeading = "【本次选区 · " + location + "】\n"
        let backgroundHeading = "\n\n【会话文件摘录 · " + background.source + " · " + background.title + range + "】\n"
        let prefix = selectionHeading + text + backgroundHeading
        let body = prefix + background.text
        guard body.utf16.count <= Self.maximumLength else {
            throw ResearchMaterialError.message("完整选区与相关文件摘录合计超出单次材料上限。请缩小选区或单独提问。")
        }
        let origin = reviewedOrder ? "经用户对照采用的候选顺序。 " : ""
        let scope = Self.bounded(origin + "主要来源为" + source + "选区；另附会话文件「" + background.title + "」" + range + "的相关摘录。", limit: 512)
        let excerpts = (verifiedExcerpts ?? []).map { $0.shifted(by: selectionHeading.utf16.count) }
            + (background.verifiedExcerpts ?? []).map { $0.shifted(by: prefix.utf16.count, kind: .context) }
        return Self(id: id, source: "选区与会话文件", title: title, text: body, scope: scope, url: url, page: page,
                    fileReference: fileReference, localWebURL: localWebURL, zoteroLocation: zoteroLocation,
                    pdfPages: pdfPages, backgroundFile: background.fileReference,
                    backgroundPages: background.pdfPages, pdfPositions: pdfPositions, backgroundPositions: background.pdfPositions,
                    verifiedExcerpts: excerpts.isEmpty ? nil : excerpts, evidenceChecks: background.evidenceChecks)
    }

    private func relevantText(question: String, selection: String) throws -> Self {
        let words = ResearchPDFIndex.searchTerms(question + " " + selection)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let parts = try lines.flatMap { try ResearchPDFIndex.split($0, limit: 1_200) }
        var ranked: [(index: Int, score: Int)] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let score = words.intersection(ResearchPDFIndex.searchTerms(part)).count
            if score > 0 { ranked.append((index, score)) }
        }
        ranked.sort { left, right in
            if left.score == right.score { return left.index < right.index }
            return left.score > right.score
        }
        guard !ranked.isEmpty else { throw ResearchMaterialError.message("在会话文件的已读范围内没有找到相关段落。请指定关键词或移除选区后单独询问文件。") }
        let separator = "\n[…]\n"
        var excerpt = ""
        var excerpts: [ResearchVerifiedExcerpt] = []
        for position in ranked.prefix(3).map(\.index).sorted() {
            if !excerpt.isEmpty { excerpt += separator }
            let part = parts[position]
            excerpts.append(.init(kind: .body, range: NSRange(location: excerpt.utf16.count, length: part.utf16.count), title: title))
            excerpt += part
        }
        return Self(source: source, title: title, text: excerpt, scope: "相关文件段落", fileReference: fileReference,
                    verifiedExcerpts: excerpts)
    }


}

enum ResearchMaterialError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

/// Reuse a verified index while reading the same file revision in this process.
/// No document contents are persisted or reused for a different path or OCR mode.
final class ResearchPDFLoadCache: @unchecked Sendable {
    final class Entry {
        let material: ResearchMaterial
        let reference: ResearchFileReference
        let stamp: ResearchFileReference.FileStamp
        let recognizeScans: Bool

        init(material: ResearchMaterial, reference: ResearchFileReference,
             stamp: ResearchFileReference.FileStamp, recognizeScans: Bool) {
            self.material = material
            self.reference = reference
            self.stamp = stamp
            self.recognizeScans = recognizeScans
        }
    }

    private let entries: NSCache<NSString, Entry> = {
        let value = NSCache<NSString, Entry>()
        value.countLimit = 2
        return value
    }()

    func existing(at url: URL, recognizeScans: Bool) throws -> Entry? {
        guard let entry = entries.object(forKey: url.path as NSString),
              entry.recognizeScans == recognizeScans else { return nil }
        try Task.checkCancellation()
        guard (try? ResearchFileReference.fileStamp(url)) == entry.stamp else {
            entries.removeObject(forKey: url.path as NSString)
            return nil
        }
        return entry
    }

    func remember(at url: URL, material: ResearchMaterial, reference: ResearchFileReference,
                  stamp: ResearchFileReference.FileStamp, recognizeScans: Bool) {
        guard let index = material.pdfIndex, index.pages.count <= 160, stamp.size <= 32 * 1_048_576 else { return }
        entries.setObject(Entry(material: material, reference: reference, stamp: stamp, recognizeScans: recognizeScans),
                          forKey: url.path as NSString)
    }
}

enum ResearchFileMaterial {
    private static let maximumTextBytes = 1_048_576

    static func load(_ url: URL, recognizeScans: Bool = false, progress: @Sendable (String) -> Void = { _ in }) throws -> ResearchMaterial {
        guard url.isFileURL else { throw ResearchMaterialError.message("请选择本机文件。") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try ResearchFileReference.fileStamp(url).size
        let title = String(url.lastPathComponent.prefix(300))
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return try ResearchPDFIndex.read(url, title: title, recognizeScans: recognizeScans, progress: progress).preview
        }
        guard ["txt", "text", "md", "markdown"].contains(ext) else {
            throw ResearchMaterialError.message("支持 PDF、纯文本及 Markdown 文件。")
        }
        guard size <= maximumTextBytes else {
            throw ResearchMaterialError.message("文本超过 1 MiB，未读取。请另存所需片段。")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumTextBytes + 1) ?? Data()
        guard data.count <= maximumTextBytes else {
            throw ResearchMaterialError.message("文本超过 1 MiB，未读取。")
        }
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
        guard let original = String(data: data, encoding: encoding) else {
            throw ResearchMaterialError.message("无法解码纯文本；支持 UTF‑8 或带 BOM 的 UTF‑16。")
        }
        let text = ResearchMaterial.bounded(original)
        guard ResearchMaterial.hasReadableText(text) else {
            throw ResearchMaterialError.message("读取范围内没有可用文字，或文本编码异常。")
        }
        let kind = ["md", "markdown"].contains(ext) ? "Markdown 文件" : "纯文本文件"
        let total = original.utf16.count
        let shown = text.utf16.count
        let scope = shown < total ? "仅带入前 \(shown) / \(total) 个 UTF‑16 字符。" : "全文 · \(shown) 个 UTF‑16 字符"
        return ResearchMaterial(source: kind, title: title, text: text, scope: scope,
                                fileReference: try ResearchFileReference.capture(url),
                                verifiedExcerpts: [.init(kind: .body, range: NSRange(location: 0, length: shown),
                                                         title: title, partial: shown < total)])
    }


}

struct ResearchMaterialCard: View {
    @ObservedObject var command: DSHPetCommandClient
    let availableSize: CGSize
    @State private var fileDetails = false
    @State private var dragOver = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("选取文字") {
                    if !NSApp.sendAction(#selector(AppDelegate.selectResearchTextFromPanel(_:)), to: NSApp.delegate, from: nil) {
                        command.rejectResearchSelection("未能启动选区读取，请回到原应用重新选取。")
                    }
                }
                .help("预览原应用当前高亮的文字。")
                .disabled(command.pdfRequestRunning || command.choosingResearchFile || command.retirementInProgress)
                Button("选择文件…") { chooseFile() }
                    .disabled(command.choosingResearchFile || command.pdfRequestRunning || command.retirementInProgress || command.selectedWorkspaceID == nil)
                Spacer(minLength: 2)
                if command.loadingResearchFile || command.pdfRequestRunning {
                    Button("停止") { command.stopPDFWork() }
                }
                if command.hasAssociatedFile || command.displayedResearchMaterial != nil {
                    Toggle("带入材料", isOn: $command.includePaperContext)
                        .toggleStyle(.switch).controlSize(.mini).fixedSize()
                }
            }.controlSize(.small)
            if command.capturingSelection {
                HStack {
                    Text("正在读取本次选区…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { NSApp.sendAction(#selector(AppDelegate.cancelResearchTextFromPanel(_:)), to: NSApp.delegate, from: nil) }
                        .controlSize(.small)
                }
            }
            if let selected = command.availableResearchSelection {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("选区 · " + selected.source)
                            .font(.caption.weight(.semibold)).fixedSize()
                        Text([selected.title, selected.page.map { "页标签 " + $0 }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help([selected.title, selected.localWebURL ?? selected.url, selected.page.map { "页标签 " + $0 }]
                                .compactMap { $0 }.joined(separator: "\n"))
                        Spacer(minLength: 3)
                        Button {
                            let clipboard = NSPasteboard.general
                            clipboard.clearContents()
                            clipboard.setString(selected.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("复制完整选区").help("复制完整选区")
                        Button { command.removeResearchSelection() } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("移除选区").help("移除选区，保留会话文件")
                    }
                    .buttonStyle(.borderless)
                    if let address = selected.url {
                        Text(address)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .accessibilityLabel("网页出处 " + address)
                            .help(address)
                    }
                    SelectionExcerptCard(material: selected, availableSize: availableSize).equatable()
                    if selected.text.utf16.count > ResearchMaterial.maximumLength {
                        Text(ResearchMaterial.oversizeMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = command.selectionError {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    if command.clipboardCopyRevision != nil || (command.hasSelectionFailure && command.appMaterial != nil) {
                        HStack {
                            if command.clipboardCopyRevision != nil {
                                Button("粘贴选区") { command.pasteResearchSelection() }
                            }
                            if command.hasSelectionFailure && command.appMaterial != nil {
                                Button("使用上次选区") { command.dismissResearchSelectionError() }
                            }
                        }.controlSize(.small)
                    }
                }
            }
            if command.hasAssociatedFile || command.associatedPDFName != nil {
                if let name = command.associatedPDFName {
                    let index = command.fixedMaterial?.pdfIndex
                    HStack(alignment: .top, spacing: 5) {
                        ResearchPDFCardContent(metadata: index?.metadata ?? ResearchPDFMetadata(), filename: name,
                                               status: pdfStatus(index), statusDetail: command.materialError ?? index?.status)
                        fileMenu
                    }
                } else {
                    HStack(spacing: 5) {
                        Button { fileDetails.toggle() } label: {
                            Image(systemName: fileDetails ? "chevron.down" : "chevron.right").frame(width: 12)
                        }
                        .accessibilityLabel(fileDetails ? "收起文件详情" : "查看文件详情").help("会话文件详情")
                        Text(command.fixedMaterial?.title ?? "会话文件").font(.caption.weight(.medium))
                            .lineLimit(1).truncationMode(.middle).help(command.fixedMaterial?.title ?? "")
                        Spacer(minLength: 2)
                        if let file = command.fixedMaterial {
                            Text(file.source).font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        fileMenu
                    }.buttonStyle(.borderless)
                    if fileDetails, let file = command.fixedMaterial, file.pdfIndex == nil {
                        Text(file.scope).font(.caption).textSelection(.enabled)
                        HStack {
                            if !file.text.isEmpty { Text("已读摘录预览").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("打开完整文件") { command.openAssociatedFile() }.buttonStyle(.link)
                        }
                        if !file.text.isEmpty {
                            ScrollView { Text(file.text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(height: min(76, availableSize.height * 0.1))
                                .accessibilityLabel("已读取的文件摘录")
                        }
                    }
                }
            }
            if !command.capturingSelection, !command.hasSelectionFailure, !command.pdfRequestRunning,
               command.submissionStatus != .submitting, !command.conversationRunning {
                let next = command.researchMaterialSummary(.ask)
                Text(next).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).help(next)
            }
            if command.associatedPDFName == nil, let error = command.materialError {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
        }
        .onChange(of: command.fixedMaterial?.fileReference?.fingerprint) { _, _ in fileDetails = false }
        .onChange(of: command.sessionID) { _, _ in fileDetails = false }
        .padding(8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor.opacity(dragOver ? 0.8 : 0), lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL else {
                command.noteMaterialMessage("请一次拖入一个本机文件。")
                return false
            }
            guard command.selectedWorkspaceID != nil, !command.pdfRequestRunning, !command.retirementInProgress else {
                command.noteMaterialMessage("请等科研工作区就绪并完成当前任务，再拖入文件。")
                return false
            }
            command.loadFixedMaterial(url)
            return true
        } isTargeted: { dragOver = $0 }
    }

    private func pdfStatus(_ index: ResearchPDFIndex?) -> String {
        command.materialError ?? index?.cardStatus ?? (command.loadingResearchFile ? "正在读取…" : "尚无可用原文")
    }

    private var fileMenu: some View {
        Menu {
            if let index = command.fixedMaterial?.pdfIndex {
                Button("打开完整文件") { command.openAssociatedFile() }
                if index.canRequestOCR {
                    Button("本机 OCR 识别缺字页") { command.recognizePDFScans() }
                }
                Button("翻译整篇 PDF") { command.submitWholePDF(.translation) }
                    .disabled(!command.canUseAssociatedFile)
                Button("分析整篇 PDF") { command.submitWholePDF(.analysis) }
                    .disabled(!command.canUseAssociatedFile)
                Divider()
            }
            Button("移除会话文件") { command.removeResearchFile() }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().disabled(command.pdfRequestRunning)
        .accessibilityLabel("会话文件操作").help("会话文件操作")
    }

    private func chooseFile() {
        guard command.beginResearchFileChoice() else { return }
        let panel = NSOpenPanel()
        panel.message = "选择一个 PDF、纯文本或 Markdown 文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        guard let parent = NSApp.keyWindow else {
            panel.begin { response in
                command.finishResearchFileChoice(response == .OK ? panel.url : nil)
            }
            return
        }
        panel.beginSheetModal(for: parent) { response in
            command.finishResearchFileChoice(response == .OK ? panel.url : nil)
        }
    }
}

/// The attached PDF card only consumes bibliographic metadata and reading state.
struct ResearchPDFCardContent: View {
    let metadata: ResearchPDFMetadata
    let filename: String
    let status: String
    let statusDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metadata.title ?? filename)
                .font(.callout.weight(.semibold)).lineLimit(2)
                .help(metadata.title.map { $0 + "\n" + filename } ?? filename)
            if let author = metadata.authorDisplay {
                Text(author).lineLimit(1).help(metadata.authors.joined(separator: "、"))
            }
            if let url = metadata.link {
                Link(destination: url) {
                    Text(url.host == "doi.org" ? "DOI  " + String(url.path.dropFirst()) : url.absoluteString)
                        .lineLimit(1).truncationMode(.middle)
                }.help(url.absoluteString)
            }
            Text(status).foregroundStyle(.secondary).lineLimit(2).help(statusDetail ?? status)
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// Recompute the height when the selection or window size changes. Other
/// command updates, including streamed replies, do not reflow this sample.
private struct SelectionExcerptCard: View, Equatable {
    let material: ResearchMaterial
    let availableSize: CGSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.material.id == rhs.material.id && lhs.availableSize == rhs.availableSize
    }

    var body: some View {
        let row = max(18, Int((availableSize.width - 64) / 12))
        let preview = SelectionPreviewText(String(material.text.prefix(1_000)))
        let lines = preview.displayed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let estimate = lines.reduce(0) { $0 + max(1, ($1.count + row - 1) / row) }
        let maximum = min(160, max(76, availableSize.height * 0.16))
        return SelectionExcerptView(material: material)
            .frame(height: min(maximum, CGFloat(estimate) * 19 + 7))
    }
}

/// The preview can reflow line breaks while native selection still copies the captured original.
private struct SelectionExcerptView: NSViewRepresentable {
    let material: ResearchMaterial

    final class Coordinator {
        var selection: UUID?
        var worker: Task<SelectionPreviewText?, Never>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ExcerptTextView()
        view.isRichText = false
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.drawsBackground = false
        view.textColor = .labelColor
        view.font = .systemFont(ofSize: 13)
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.setAccessibilityLabel("本次选区原文")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let id = material.id
        guard coordinator.selection != id, let view = scroll.documentView as? ExcerptTextView else { return }
        coordinator.selection = id
        coordinator.worker?.cancel()
        coordinator.worker = nil
        let text = material.text
        if text.utf16.count <= ResearchMaterial.maximumLength {
            view.showPreview(SelectionPreviewText(text))
            return
        }

        // An oversized selection remains available for copying. Prepare its
        // display without holding the main actor or showing the previous text.
        view.showPreview(nil)
        let worker = Task.detached(priority: .userInitiated) { SelectionPreviewText.prepare(text) }
        coordinator.worker = worker
        Task { @MainActor [weak coordinator, weak view] in
            guard let preview = await worker.value, !worker.isCancelled,
                  let coordinator, coordinator.selection == id else { return }
            coordinator.worker = nil
            view?.showPreview(preview)
        }
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.selection = nil
        coordinator.worker?.cancel()
        coordinator.worker = nil
    }

    private final class ExcerptTextView: NSTextView {
        private var preview: SelectionPreviewText?

        func showPreview(_ preview: SelectionPreviewText?) {
            self.preview = preview
            string = preview?.displayed ?? ""
            scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

        override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            guard type == .string, let preview else { return false }
            let originals = selectedRanges.compactMap { preview.originalText(for: $0.rangeValue) }
            return !originals.isEmpty && pasteboard.setString(originals.joined(separator: "\n"), forType: .string)
        }
    }
}
