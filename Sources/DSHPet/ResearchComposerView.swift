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

    var body: some View {
        GeometryReader { size in content(availableSize: size.size) }
    }

    private func content(availableSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            ResearchMaterialCard(command: command, availableSize: availableSize)
            Divider()
            conversation
            if let error = command.conversationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxHeight: 58, alignment: .topLeading)
            }
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
        .onChange(of: presentation.revision) { _, _ in scrollRequest &+= 1 }
        .onChange(of: command.submissionStatus) { _, status in
            if status == .submitting { scrollRequest &+= 1 }
        }
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
        let busy = command.conversationRunning || command.sessionSnapshot?.taskRunning == true
            ? (command.busyMessage ?? "模型正在回复…") : nil
        return ResearchTranscript(messages: command.conversationMessages, historyRevision: command.conversationHistoryRevision,
                                  stream: command.conversationStream,
                                  sessionID: command.sessionID, jump: scrollRequest, busy: busy,
                                  presentation: presentation)
            .frame(minHeight: 90, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("翻译原文") { command.submitResearch(.translate) }
                    .disabled(!command.canUseResearchMaterial)
                Button("解释原文") { command.submitResearch(.explain) }
                    .disabled(!command.canUseResearchMaterial)
                Spacer()
            }
            .buttonStyle(.bordered).controlSize(.small)
            DSHPetTextView(text: $command.draft, command: command, selectedSkillPrefix: $command.selectedSkillPrefix,
                measuredHeight: Binding(get: { model.composerInputHeight }, set: { model.setComposerInputHeight($0) }),
                placeholder: "输入问题；Enter 发送，Shift+Enter 换行",
                onSubmit: { command.submitResearch() }, onEscape: { model.collapseComposer(reason: .textEscape) },
                focusRequest: model.composerFocusRequest)
                .frame(height: max(58, model.composerInputHeight))
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            HStack(alignment: .top) {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 5)
                if command.hasPendingSubmission && command.submissionStatus != .submitting {
                    Button("丢弃未确认") { command.discardPendingSubmission() }
                        .controlSize(.small)
                }
                Button { command.submitResearch() } label: {
                    Label("发送", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!command.canSend || !command.researchAvailable || command.conversationRunning)
                .accessibilityLabel("发送科研问题")
            }
        }
    }

    private var statusText: String {
        if command.connection != .connected { return "DSH 未连接。打开下方「连接设置」查看安装和启动步骤。" }
        if !command.researchAvailable { return "当前桥接不支持科研协议，消息尚未发送。" }
        return command.continuationWarning ?? command.lastError ?? command.submissionStatus.label
            ?? command.busyMessage ?? "同一 DSH 会话连续问答 · 沿用 DSH 访问权限"
    }

    private var footer: some View {
        HStack {
            Text(command.selectedWorkspaceTitle ?? "等待专属工作区").lineLimit(1)
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
