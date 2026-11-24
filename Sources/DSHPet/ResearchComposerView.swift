import AppKit
import SwiftUI

/// A full local conversation surface over the existing Agent and session.
struct ResearchComposerView: View {
    @ObservedObject var model: DSHPetModel
    @ObservedObject var command: DSHPetCommandClient
    @ObservedObject var presentation: ResearchWindowPresentation
    @State private var scrollRequest = 0
    @State private var historyPresented = false
    @State private var setupPresented = false

    private enum DocumentReview: Identifiable {
        case layout(DSHPetCommandClient.PDFLayoutReview)
        case range(DSHPetCommandClient.PDFRangeReview)

        var id: UUID {
            switch self {
            case .layout(let review): review.id
            case .range(let review): review.id
            }
        }
    }

    private var documentReview: DocumentReview? {
        if let review = command.pdfRangeReview { return .range(review) }
        return command.pdfLayoutReview.map(DocumentReview.layout)
    }

    var body: some View {
        GeometryReader { size in content(availableSize: size.size) }
    }

    private func content(availableSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            ResearchMaterialCard(command: command, availableSize: availableSize)
            Divider()
            conversation
            if let plan = command.pdfBatchApproval {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.description).font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("开始分段处理") { command.resolvePDFApproval(plan.id, allow: true) }
                        Button("取消") { command.resolvePDFApproval(plan.id, allow: false) }
                    }.controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: Binding(get: { documentReview }, set: { _ in })) { presentation in
            switch presentation {
            case .layout(let review):
                ResearchPDFReviewView(review: review) { command.resolveLayoutReview(review.id, accept: $0) }
                    .onDisappear { command.resolveLayoutReview(review.id, accept: false) }
            case .range(let review):
                rangePicker(review)
            }
        }
        .onChange(of: presentation.revision) { _, _ in scrollRequest &+= 1 }
        .onChange(of: command.submissionStatus) { _, status in
            if status == .submitting { scrollRequest &+= 1 }
        }
    }

    private func rangePicker(_ review: DSHPetCommandClient.PDFRangeReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择原文范围").font(.headline)
            Text(review.reason).font(.callout).foregroundStyle(.secondary)
            if let anchors = review.anchors {
                PDFRangeAnchorEditor(anchors: anchors) {
                    command.resolveRangeReview(review.id, choice: .edit($0))
                }
            }
            if review.truncated {
                Text("还有其他匹配位置。如未看到目标，可以取消并补充页码或章节。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !review.candidates.isEmpty { ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review.candidates, id: \.id) { candidate in
                        Button {
                            command.resolveRangeReview(review.id, choice: .candidate(candidate.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                let pages = candidate.startPage == candidate.endPage ?
                                    "文件第 \(candidate.startPage) 页" : "文件第 \(candidate.startPage)–\(candidate.endPage) 页"
                                Text([pages, candidate.section].compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline.weight(.semibold))
                                Text("起点 · " + candidate.startPreview).lineLimit(2)
                                Text("终点 · " + candidate.endPreview).lineLimit(2)
                            }
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                }.padding(2)
            } }
            HStack {
                Spacer()
                Button("取消，保留问题") { command.resolveRangeReview(review.id, choice: nil) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 490, height: 390)
        .onDisappear { command.resolveRangeReview(review.id, choice: nil) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ResearchModelPicker(command: command)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { historyPresented.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .fixedSize()
            .accessibilityLabel("科研会话历史")
            .help("按标题、材料和归档状态查找历史")
            .popover(isPresented: $historyPresented, arrowEdge: .bottom) {
                ResearchHistoryView(command: command) { row in
                    if command.selectResearchSession(row) { historyPresented = false }
                }
            }
            Button { command.refreshResearch() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新对话").accessibilityLabel("刷新对话")
            Button { model.startNewSession() } label: { Image(systemName: "square.and.pencil") }
                .disabled(command.hasPendingSubmission || command.conversationRunning || command.modelSwitching)
                .help("新建对话，保留原对话").accessibilityLabel("新建科研对话")
        }
        .buttonStyle(.plain)
    }

    private var conversation: some View {
        ResearchTranscript(messages: command.conversationMessages, historyRevision: command.conversationHistoryRevision,
                                  stream: command.conversationStream,
                                  sessionID: command.sessionID, jump: scrollRequest,
                                  didDisplay: command.transcriptDidDisplay)
            .frame(minHeight: 90, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            DSHPetTextView(text: $command.draft, command: command, selectedSkillPrefix: $command.selectedSkillPrefix,
                measuredHeight: Binding(get: { model.composerInputHeight }, set: { model.setComposerInputHeight($0) }),
                placeholder: "输入问题；Enter 发送，Shift+Enter 换行",
                onSubmit: { command.submitResearch() }, onEscape: { model.collapseComposer(reason: .textEscape) },
                focusRequest: model.composerFocusRequest)
                .frame(height: max(58, model.composerInputHeight))
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            HStack(alignment: .top) {
                if let statusText {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
                Spacer(minLength: 5)
                if command.hasPendingSubmission && command.submissionStatus != .submitting && !command.pdfRequestRunning {
                    Button("丢弃未确认") { command.discardPendingSubmission() }
                        .controlSize(.small)
                        .help("先核对历史。此操作只清除待核对状态，已被接收的请求仍可继续。")
                }
                Button { command.submitResearch() } label: {
                    Label("发送", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!command.canSend || !command.researchAvailable || command.conversationRunning || command.pdfRequestRunning)
                .accessibilityLabel("发送科研问题")
            }
        }
    }

    private var statusText: String? {
        if command.submissionStatus == .submitting { return "正在准备或提交请求…" }
        if command.hasPendingSubmission, command.submissionStatus == .unconfirmed || !command.pdfRequestRunning {
            return "提交结果未确认。请先刷新对话，核对后再继续。"
        }
        if command.connection != .connected { return "未连接 DSH。请使用「连接设置」。" }
        if !command.researchAvailable { return "当前连接不支持文档问答。" }
        if command.sessionSnapshot?.waitingForUser == true { return command.busyMessage }
        if command.conversationRunning {
            return command.conversationStream?.text.isEmpty == false ? "正在输出回答…" : "已提交 · 等待模型回复…"
        }
        if command.pdfRequestRunning { return command.pdfRequestStatus ?? "正在准备原文…" }
        if command.submissionStatus == .submitted { return "已提交" }
        return command.continuationWarning ?? command.lastError ?? command.pdfRequestStatus
            ?? command.submissionStatus.label ?? command.busyMessage
            ?? command.conversationError.map { "会话错误：\($0)" }
    }

    private var footer: some View {
        HStack {
            if let workspace = command.selectedWorkspaceTitle { Text(workspace).lineLimit(1) }
            Spacer()
            if command.connection == .connected {
                Button("打开 DSH") { model.openHarness() }.buttonStyle(.link)
            } else {
                Button("连接设置") { setupPresented = true }.buttonStyle(.link)
                    .popover(isPresented: $setupPresented) { ResearchSetupView() }
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.trailing, 8) // Space for the native resize grip outside links.
    }
}

private struct PDFRangeAnchorEditor: View {
    @State private var start: String
    @State private var end: String
    let apply: (ResearchPDFAnchors) -> Void

    init(anchors: ResearchPDFAnchors, apply: @escaping (ResearchPDFAnchors) -> Void) {
        _start = State(initialValue: anchors.start)
        _end = State(initialValue: anchors.end)
        self.apply = apply
    }

    private var correction: ResearchPDFAnchors {
        .init(start: start.trimmingCharacters(in: .whitespacesAndNewlines),
              end: end.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("起点原文", text: $start)
            TextField("终点原文", text: $end)
            Button("核验修正后的范围") { apply(correction) }
                .disabled(!correction.complete || correction.start.utf16.count > ResearchMaterial.maximumLength ||
                          correction.end.utf16.count > ResearchMaterial.maximumLength)
        }
    }
}
