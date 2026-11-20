import SwiftUI

enum ResearchHistoryStatus: String, CaseIterable {
    case active, archived, all

    var label: String {
        switch self {
        case .active: "正常"
        case .archived: "已归档"
        case .all: "全部"
        }
    }
}

struct ResearchHistoryQuery: Equatable {
    var title = ""
    var material = ""
    var status = ResearchHistoryStatus.active
}

struct ResearchHistoryRow: Decodable, Identifiable {
    struct Material: Decodable {
        let title: String
        let source: String?
    }

    let sessionId: String
    let workspaceId: String
    let title: String
    let archived: Bool
    let updatedAt: TimeInterval
    let running: Bool
    let blank: Bool
    let materials: [Material]

    var id: String { sessionId }
    var date: Date { Date(timeIntervalSince1970: updatedAt / 1_000) }
}

struct ResearchHistoryPage: Decodable {
    let stale: Bool?
    let unchanged: Bool?
    let revision: String?
    let matches: [ResearchHistoryRow]?
    let unreadable: Int?
    let scanned: Int?
    let totalToScan: Int?
    let nextOffset: Int?
}

struct ResearchHistoryView: View {
    @ObservedObject var command: DSHPetCommandClient
    let onSelect: (ResearchHistoryRow) -> Void
    @State private var query = ResearchHistoryQuery()
    @State private var rows: [ResearchHistoryRow] = []
    @State private var loading = false
    @State private var scanned = 0
    @State private var totalToScan: Int?
    @State private var unreadable = 0
    @State private var error: String?
    @State private var refreshRevision = 0
    @State private var completedRevision: String?
    @State private var removalTarget: ResearchHistoryRow?
    @State private var confirmingRetry = false

    private struct LoadID: Equatable {
        let query: ResearchHistoryQuery
        let revision: Int
        let workspace: String?
        let available: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("科研会话").font(.headline)
                Spacer()
                if query != ResearchHistoryQuery() {
                    Button("清除筛选") { query = ResearchHistoryQuery() }
                }
                Button { refreshRevision &+= 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新读取 DSH 历史")
                .accessibilityLabel("刷新科研会话")
                .disabled(!command.researchHistoryAvailable)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 8) {
                TextField("查找会话标题", text: $query.title)
                TextField("材料标题或来源", text: $query.material)
            }
            .textFieldStyle(.roundedBorder)
            Picker("归档状态", selection: $query.status) {
                ForEach(ResearchHistoryStatus.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            if !rows.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in historyRow(row) }
                    }
                }
                .frame(minHeight: 90, maxHeight: 290)
            }
            historyStatus
            if let notice = command.retirementNotice {
                Text(notice).font(.caption).textSelection(.enabled)
            }
            if let pending = command.retirementTicket, !command.retirementInProgress {
                Button("重试未完成的删除（…\(pending.sessionId.suffix(8))）") { confirmingRetry = true }
            }
            if let warning = command.continuationWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .alert("永久删除这条科研会话？", isPresented: Binding(
            get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }
        ), presenting: removalTarget) { target in
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { command.retireResearchSession(target) }
        } message: { target in
            let route = command.onlineDeletionAvailable ? "优先仅停止本会话。如需重开 DSH，会再请你确认。" : "将短暂退出并重开 DSH。"
            Text("「\(target.title)」 · …\(target.id.suffix(8))\n" + route + " 删除后无法恢复。原始材料和独立笔记保留。")
        }
        .alert("继续上次确认的会话删除？", isPresented: $confirmingRetry) {
            Button("取消", role: .cancel) {}
            Button("重试", role: .destructive) { command.retireResearchSession(nil) }
        } message: { Text("只处理编号 …\(command.retirementTicket?.sessionId.suffix(8) ?? "") 的原目标，并重新核对当前状态。") }
        .alert("改用离线删除？", isPresented: Binding(
            get: { command.offlineDeletionOffer != nil }, set: { if !$0 { command.offlineDeletionOffer = nil } }
        ), presenting: command.offlineDeletionOffer) { plan in
            Button("取消", role: .cancel) {}
            Button("重开 DSH 并删除", role: .destructive) { command.retireResearchSession(nil, confirmedOffline: plan) }
        } message: { plan in
            Text("会话 …\(plan.sessionId.suffix(8))。\n" + (plan.reason ?? "在线删除条件未满足。") + " 将在核对其他任务后正常退出并重开 DSH。")
        }
        .onChange(of: command.retiredRevision) { _, _ in refreshRevision &+= 1 }
        .padding(12)
        .frame(width: 400)
        .task(id: LoadID(query: query, revision: refreshRevision, workspace: command.selectedWorkspaceID,
                         available: command.researchHistoryAvailable)) {
            await reload(checkChanges: false)
            // Native DSH archive/unarchive can change the registry without
            // updating task timestamps. Recheck only while this popover exists.
            while command.researchHistoryAvailable && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                await reload(checkChanges: true)
            }
        }
        .onChange(of: command.workspaces) { _, _ in refreshRevision &+= 1 }
        .onChange(of: command.tasks.map { "\($0.sessionID)\($0.updatedAt)\($0.title)" }) { _, _ in refreshRevision &+= 1 }
    }

    @ViewBuilder private var historyStatus: some View {
        if loading {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                if let totalToScan {
                    Text("正在检索科研工作区（\(scanned)/\(totalToScan)）")
                } else {
                    Text("正在读取科研会话…")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let error {
            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        } else if rows.isEmpty && unreadable == 0 {
            Text(query == ResearchHistoryQuery() ? "暂无正常科研会话" : "没有符合筛选条件的会话")
                .foregroundStyle(.secondary).font(.callout).padding(.vertical, 12)
        } else {
            Text("\(rows.count) 条会话" + (unreadable > 0 ? " · \(unreadable) 条会话的记录无法读取，筛选可能不完整" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func historyRow(_ row: ResearchHistoryRow) -> some View {
        HStack(spacing: 4) {
            selectRow(row)
            if command.researchDeletionAvailable {
                Menu {
                    Button("删除会话…", role: .destructive) { removalTarget = row }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("更多操作，" + row.title)
                .disabled(command.retirementInProgress)
            }
        }
        .contextMenu {
            if command.researchDeletionAvailable {
                Button("删除会话…", role: .destructive) { removalTarget = row }
                    .disabled(command.retirementInProgress)
            }
        }
    }

    private func selectRow(_ row: ResearchHistoryRow) -> some View {
        Button { onSelect(row) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(row.date.formatted(date: .numeric, time: .shortened))
                        Text("· \(row.id.suffix(8))")
                        if row.archived { Text("· 已归档") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    if let material = row.materials.first {
                        Text(material.source.map { "\(material.title) · \($0)" } ?? material.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if command.sessionID == row.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        .accessibilityLabel("当前会话")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resetResults() {
        rows = []
        error = nil
        unreadable = 0
        scanned = 0
        totalToScan = nil
        completedRevision = nil
    }

    @MainActor private func reload(checkChanges: Bool) async {
        let frozenQuery = query
        if !checkChanges { resetResults() }
        guard command.researchHistoryAvailable else {
            loading = false
            error = command.connection == .connected ? "当前科研桥不提供完整会话筛选。" : "DSH 未连接，无法读取科研历史。"
            return
        }
        loading = !checkChanges
        do {
            if !checkChanges { try await Task.sleep(for: .milliseconds(200)) }
            var offset = 0
            var revision = checkChanges ? completedRevision : nil
            var alreadyRestarted = false
            while true {
                let page = try await command.fetchResearchHistory(query: frozenQuery, offset: offset, revision: revision)
                try Task.checkCancellation()
                if page.unchanged == true { break }
                if offset == 0 { resetResults() }
                loading = true
                if page.stale == true {
                    guard !alreadyRestarted else {
                        error = "科研历史刚刚发生变化，请刷新后重试。"
                        break
                    }
                    offset = 0
                    revision = nil
                    alreadyRestarted = true
                    resetResults()
                    continue
                }
                guard let matches = page.matches, let pageRevision = page.revision,
                      let pageScanned = page.scanned, let pageTotal = page.totalToScan,
                      let pageUnreadable = page.unreadable else { throw DSHPetCommandError.malformed }
                rows.append(contentsOf: matches)
                unreadable += pageUnreadable
                scanned = pageScanned
                totalToScan = pageTotal
                guard let next = page.nextOffset else {
                    if unreadable == 0 { completedRevision = pageRevision }
                    break
                }
                guard next > offset else { throw DSHPetCommandError.malformed }
                offset = next
                revision = pageRevision
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "检索未完成。\(error.localizedDescription)"
        }
        if !Task.isCancelled { loading = false }
    }
}
