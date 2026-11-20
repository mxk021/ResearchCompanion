import AppKit
import ApplicationServices
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The exact excerpt displayed locally and passed to the bridge on an explicit send.
struct ResearchMaterial: Equatable, Sendable {
    static let maximumLength = 24_000
    static let localSelectionLimit = 1_048_576
    static let oversizeMessage = "已完整保留本机选区。单次材料上限为 24,000 个 UTF‑16 字符，请缩小选区后再发送。"
    var id = UUID()
    let source: String
    let title: String
    let text: String
    let scope: String
    var url: String?
    var page: String?
    var fileReference: ResearchFileReference? = nil
    var localWebURL: String? = nil
    var selectionIsComplete = false
    var pdfIndex: ResearchPDFIndex? = nil
    var pdfPages: String? = nil
    var backgroundFile: ResearchFileReference? = nil
    var backgroundPages: String? = nil

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
                    scope: "当前选区 · \(original.utf16.count) 个 UTF‑16 字符", url: url, selectionIsComplete: true)
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
        let location = [source, title, page.map { "页标签 " + $0 }].compactMap { $0 }.joined(separator: " · ")
        let range = background.pdfPages.map { " · PDF 文件页 " + $0 } ?? ""
        let body = "【本次选区 · " + location + "】\n" + text + "\n\n【会话文件摘录 · " + background.source + " · " + background.title + range + "】\n" + background.text
        guard body.utf16.count <= Self.maximumLength else {
            throw ResearchMaterialError.message("完整选区与相关文件摘录合计超出单次材料上限。请缩小选区或单独提问。")
        }
        let scope = Self.bounded("主要来源为" + source + "选区；另附会话文件「" + background.title + "」" + range + "的相关摘录。", limit: 512)
        return Self(id: id, source: "选区与会话文件", title: title, text: body, scope: scope, url: url,
                    fileReference: fileReference, localWebURL: localWebURL, backgroundFile: background.fileReference,
                    backgroundPages: background.pdfPages)
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
        let excerpt = ranked.prefix(3).map { $0.0 }.sorted().map { parts[$0] }.joined(separator: "\n[…]\n")
        return Self(source: source, title: title, text: excerpt, scope: "相关文件段落", fileReference: fileReference)
    }

    func withLocator(from capture: Self) -> Self? {
        func comparable(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").precomposedStringWithCanonicalMapping
        }
        guard selectionIsComplete, capture.selectionIsComplete,
              source == capture.source, comparable(text) == comparable(capture.text) else { return nil }
        return Self(source: source, title: capture.title, text: text, scope: scope,
                    url: capture.url, page: capture.page, fileReference: capture.fileReference,
                    localWebURL: capture.localWebURL, selectionIsComplete: true)
    }
}

enum ResearchMaterialError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

enum ResearchMaterialSource: Equatable {
    case none, zotero, appSelection, fixedFile
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
                                fileReference: try ResearchFileReference.capture(url))
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
                .help("重新获取原应用的选区，仅在此预览")
                .disabled(command.pdfRequestRunning || command.choosingResearchFile || command.retirementInProgress)
                Button("选择文件…") { chooseFile() }
                    .disabled(command.choosingResearchFile || command.pdfRequestRunning || command.retirementInProgress || command.selectedWorkspaceID == nil)
                Spacer(minLength: 2)
                if command.loadingResearchFile || command.pdfRequestRunning {
                    Button("停止") { command.stopPDFWork() }
                }
                if command.hasAssociatedFile || command.appMaterial != nil {
                    Toggle("带入材料", isOn: $command.includePaperContext)
                        .toggleStyle(.switch).controlSize(.mini).fixedSize()
                }
            }.controlSize(.small)
            if command.capturingSelection {
                HStack {
                    Text("正在读取本次选区…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { command.removeResearchSelection() }.controlSize(.small)
                }
            }
            if let selected = command.appMaterial {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("选区 · " + selected.source).font(.caption.weight(.semibold)).fixedSize()
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
                    SelectionExcerptView(material: selected)
                        .frame(height: selectionHeight(selected))
                    if selected.text.utf16.count > ResearchMaterial.maximumLength {
                        Text(ResearchMaterial.oversizeMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = command.selectionError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 2)
                    Button { command.removeResearchSelection() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("清除取词提示").help("清除取词提示")
                }
            }
            if command.hasAssociatedFile {
                HStack(spacing: 5) {
                    Button { fileDetails.toggle() } label: {
                        Image(systemName: fileDetails ? "chevron.down" : "chevron.right").frame(width: 12)
                    }
                    .accessibilityLabel(fileDetails ? "收起文件详情" : "查看文件详情").help("会话文件详情")
                    Text(command.fixedMaterial?.title ?? "会话文件").font(.caption.weight(.medium))
                        .lineLimit(1).truncationMode(.middle).help(command.fixedMaterial?.title ?? "")
                    Spacer(minLength: 2)
                    if let file = command.fixedMaterial {
                        Text(file.pdfIndex.map { "PDF · 已检查 \($0.pages.count) 页" } ?? file.source)
                            .font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    Menu {
                        if let index = command.fixedMaterial?.pdfIndex {
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
                }.buttonStyle(.borderless)
                if fileDetails, let file = command.fixedMaterial {
                    Text(file.pdfIndex?.status ?? file.scope).font(.caption).textSelection(.enabled)
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
            if let progress = command.pdfRequestStatus {
                Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            if let error = command.materialError ?? command.contextError {
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

    private func selectionHeight(_ selection: ResearchMaterial) -> CGFloat {
        let row = max(18, Int((availableSize.width - 64) / 12))
        let lines = selection.text.prefix(1_000).split(separator: "\n", omittingEmptySubsequences: false)
        let estimate = lines.reduce(0) { $0 + max(1, ($1.count + row - 1) / row) }
        let maximum = min(160, max(76, availableSize.height * 0.16))
        return min(maximum, CGFloat(estimate) * 19 + 7)
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

/// Native selectable text retains the complete local excerpt; only its viewport is bounded.
private struct SelectionExcerptView: NSViewRepresentable {
    let material: ResearchMaterial

    final class Coordinator { var rendered: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textColor = .labelColor
        view.font = .systemFont(ofSize: 13)
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.layoutManager?.allowsNonContiguousLayout = true
        view.setAccessibilityLabel("本次选区原文")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.rendered != material.id, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.rendered = material.id
        view.string = material.text
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
