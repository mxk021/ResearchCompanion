import Foundation
import AppKit
import Darwin
import Network
import SwiftUI

enum DSHPetCommandConnection: Equatable {
    case disconnected
    case connecting
    case connected
}

enum DSHPetCandidateKind: Equatable {
    case file, skill
}

struct DSHPetInputCandidate: Equatable, Identifiable {
    let id: String
    let label: String
    let insertText: String
    let detail: String?
    let disabledReason: String?
}

struct DSHPetWorkspace: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let path: String
    let status: String
    let sessionIds: [String]
}

struct DSHPetImageLimits: Codable, Equatable {
    let maxImageBytes: Int
    let maxImagesPerMessage: Int
    let maxMessageImageBytes: Int
    let mediaTypes: [String]
}

struct DSHPetDraftImage: Codable, Equatable, Identifiable {
    let id: String
    let path: String
    let mediaType: String
    let name: String
    let bytes: Int
    var error: String?

    var fileURL: URL { URL(fileURLWithPath: path) }
}

enum DSHPetSubmissionStatus: Equatable {
    case idle
    case submitting
    case submitted
    case unconfirmed
    case failed(String)

    var label: String? {
        switch self {
        case .idle: return nil
        case .submitting: return "正在提交…"
        case .submitted: return "已提交"
        case .unconfirmed: return "提交结果未确认"
        case .failed(let message): return message
        }
    }
}

enum DSHPetCommandError: LocalizedError {
    case unavailable
    case timedOut
    case malformed
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "发送服务未连接，请确认 Research Companion 桥接插件已加载"
        case .timedOut: return "提交结果未确认"
        case .malformed: return "Research Companion 桥接插件返回了无法识别的结果"
        case .server(_, let message): return message
        }
    }
}

/// Each socket keeps its own framing state on the serial Network queue.
/// Completed packets are handed to the main actor once and never mutated there.
private final class DSHPetCommandFrames: @unchecked Sendable {
    struct Batch: @unchecked Sendable {
        let objects: [[String: Any]]
    }

    private var buffer = Data()
    private var scannedBytes = 0

    func append(_ data: Data?) -> Batch {
        if let data { buffer.append(data) }
        var objects: [[String: Any]] = []
        var start = buffer.startIndex
        var search = start + scannedBytes
        while let end = buffer[search...].firstIndex(of: 10) {
            if start != end,
               let object = try? JSONSerialization.jsonObject(with: Data(buffer[start..<end])) as? [String: Any] {
                objects.append(object)
            }
            start = end + 1
            search = start
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        scannedBytes = buffer.count
        return Batch(objects: objects)
    }
}

/// DSHPet-only client for the plugin's user-local command socket.
@MainActor
final class DSHPetCommandClient: ObservableObject {
    @Published private(set) var connection: DSHPetCommandConnection = .disconnected
    @Published private(set) var capabilitiesAvailable = false
    @Published private(set) var taskListAvailable = false
    @Published private(set) var imageAttachmentsAvailable = false
    @Published private(set) var imageLimits: DSHPetImageLimits?
    @Published private(set) var workspaces: [DSHPetWorkspace] = []
    @Published private(set) var tasks: [DSHPetTaskSummary] = []
    /// Presentation deck for the pet's status bubble.
    @Published private(set) var bubbleDeck = DSHPetBubbleDeck.empty
    @Published private(set) var selectedWorkspaceID: String?
    @Published private(set) var sessionID: String?
    @Published private(set) var sessionSnapshot: MoodBridgeSnapshot?
    @Published private(set) var focusedTaskID: String?
    @Published private(set) var submissionStatus: DSHPetSubmissionStatus = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var continuationWarning: String?
    @Published private(set) var candidateKind: DSHPetCandidateKind?
    @Published private(set) var candidates: [DSHPetInputCandidate] = []
    @Published private(set) var candidatesLoading = false
    @Published private(set) var candidatesError: String?
    @Published private(set) var taskPreview: String?
    @Published private(set) var taskPreviewStatus: String?
    @Published private(set) var taskOpenError: String?
    @Published private(set) var draftImages: [DSHPetDraftImage] = []
    @Published private(set) var researchAvailable = false
    @Published private(set) var researchDeletionAvailable = false
    @Published private(set) var onlineDeletionAvailable = false
    @Published var offlineDeletionOffer: ResearchRemovalPlan?
    @Published private(set) var retirementInProgress = false
    @Published private(set) var retirementNotice: String?
    @Published private(set) var retiredRevision = 0
    private let retirementTicketKey = "research-companion.offlineRemovalTicket.v1"
    var retirementTicket: ResearchRemovalPlan? {
        defaults.data(forKey: retirementTicketKey).flatMap { try? JSONDecoder().decode(ResearchRemovalPlan.self, from: $0) }
    }
    @Published private(set) var researchHistoryAvailable = false
    @Published private(set) var paperContext: ResearchPaperContext?
    @Published private(set) var contextError: String?
    @Published private(set) var materialSource: ResearchMaterialSource = .none
    @Published private(set) var materialError: String?
    @Published private(set) var fixedMaterial: ResearchMaterial?
    @Published private(set) var appMaterial: ResearchMaterial?
    @Published private(set) var materialTransportAvailable = false
    @Published private(set) var choosingResearchFile = false
    @Published private(set) var loadingResearchFile = false
    @Published private(set) var selectionError: String?
    @Published private(set) var capturingSelection = false
    private var captureRevision = 0
    private var selectionReadTask: Task<Void, Never>?
    private var materialRevision = 0
    @Published private(set) var pdfRequestRunning = false
    @Published private(set) var pdfRequestStatus: String?
    private var pdfTask: Task<Void, Never>?
    private let provenanceStore: ResearchProvenanceStore
    @Published private(set) var associatedPDFName: String?
    struct PDFBatchApproval: Identifiable {
        let id = UUID()
        let description: String
    }
    @Published private(set) var pdfBatchApproval: PDFBatchApproval?
    private var pdfApprovalContinuation: CheckedContinuation<Bool, Never>?
    private var fixedMaterialURL: URL?
    private var attachment: ResearchFileAttachment?
    private var fixedStamp: ResearchFileReference.FileStamp?
    private var fileChoiceBinding: Int?
    private var restoredAttachmentKey: String?
    private var materialReadTask: Task<Void, Never>?
    @Published private(set) var conversationMessages: [ResearchChatMessage] = [] {
        didSet { conversationHistoryRevision &+= 1 }
    }
    private(set) var conversationHistoryRevision = 0
    private var wireHistoryRevision: String?
    @Published private(set) var conversationStream: ResearchChatMessage?
    @Published private(set) var conversationError: String?
    @Published private(set) var conversationModel: String?
    @Published private(set) var conversationRunning = false
    @Published private(set) var modelSelectionAvailable = false
    @Published private(set) var modelCatalog: ResearchModelCatalog?
    @Published private(set) var modelCatalogLoading = false
    @Published private(set) var modelCatalogError: String?
    @Published private(set) var modelSwitching = false
    @Published private(set) var modelSwitchError: String?
    @Published private(set) var conversationSelection: ResearchModelSelection?
    private var modelSelectionRevision = 0
    private var streamRevision = -1
    @Published var includePaperContext = true
    private var researchPollingTask: Task<Void, Never>?
    private var researchRefreshInFlight = false
    private var researchRefreshQueued: ResearchRefresh = []
    private var researchWindowForeground = false
    private var lastConversationRead: TimeInterval = -.infinity
    private var lastStreamUpdate: TimeInterval = -.infinity
    private var submissionResearchMode = ResearchPromptMode.ask

    private struct ResearchRefresh: OptionSet {
        let rawValue: Int
        static let conversation = Self(rawValue: 1 << 0)
        static let material = Self(rawValue: 1 << 1)
        static let all: Self = [.conversation, .material]
    }

    var selectedResearchModel: ResearchModelSelection? {
        if sessionID != nil { return conversationSelection }
        return try? modelForTurn(translation: true)
    }

    var canSelectResearchModel: Bool {
        modelSelectionAvailable && !modelSwitching && !conversationRunning && !pdfRequestRunning
            && submissionStatus != .submitting && !hasPendingSubmission && selectedWorkspaceID != nil
    }

    @Published var selectedSkillPrefix: String? {
        didSet {
            if let selectedSkillPrefix { defaults.set(selectedSkillPrefix, forKey: Keys.selectedSkillPrefix) }
            else { defaults.removeObject(forKey: Keys.selectedSkillPrefix) }
        }
    }
    @Published var draft: String {
        didSet {
            guard draft != oldValue else { return }
            draftSaveTask?.cancel()
            draftSaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.flushDraftPersistence()
            }
            if let selectedSkillPrefix, !draft.hasPrefix(selectedSkillPrefix) { self.selectedSkillPrefix = nil }
        }
    }
    private var draftSaveTask: Task<Void, Never>?

    func flushDraftPersistence() {
        guard draftSaveTask != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        defaults.set(draft, forKey: Keys.draft)
    }

    var onAccepted: (() -> Void)?

    var showsComposerStatusLine: Bool {
        connection != .connected
            || !capabilitiesAvailable
            || workspaces.isEmpty
            || submissionStatus.label != nil
            || lastError != nil
            || busyMessage != nil
    }

    private enum Keys {
        static let workspaceID = "dsh-pet.command.workspaceID"
        static let sessionID = "dsh-pet.command.sessionID"
        static let draft = "dsh-pet.command.draft"
        static let selectedSkillPrefix = "dsh-pet.command.selectedSkillPrefix"
        static let requestID = "dsh-pet.command.pendingRequestID"
        static let requestText = "dsh-pet.command.pendingRequestText"
        static let taskReadMarkers = "dsh-pet.command.taskReadMarkers"
        static let draftImages = "dsh-pet.command.draftImages"
        static let requestSignature = "dsh-pet.command.pendingRequestSignature"
        static let pendingSessionID = "dsh-pet.command.pendingSessionID"
        static let targetBindingKey = "dsh-pet.command.targetBindingKey"
    }

    private struct TaskReadMarker: Codable {
        let updatedAt: TimeInterval
        let mood: String
    }

    private struct BubbleObservation: Equatable {
        let mood: String
        let updatedAt: TimeInterval
        let terminal: Bool
    }

    private let defaults: UserDefaults
    private var socketPath: String
    private var expectedInstanceID: String?
    private var targetInstance: HarnessInstance?
    private var persistedTargetBindingKey: String?
    private var sourceEnabled = false
    private let queue = DispatchQueue(label: "com.local.research-companion.command-client")
    private var connectionHandle: NWConnection?
    private var queuedPayloads: [(id: String, data: Data)] = []
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var started = false
    private var pendingRequestID: String?
    private var pendingRequestText: String?
    private var pendingRequestSignature: String?
    /// The Session id sent to createSession. Persisted before the request so a
    /// timeout retry reuses it instead of creating an orphan Session.
    private var pendingSessionID: String?
    private var promptMayHaveBeenSent = false
    private var reconnectTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var capabilitiesValidated = false
    private var fileCandidatesAvailable = false
    private var skillCandidatesAvailable = false
    private var taskPreviewAvailable = false
    private var candidateGeneration = 0
    private var candidateTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var taskOpenGeneration = 0
    private var sessionBindingGeneration = 0
    private var sessionCreationTask: Task<String, Error>?
    private var readMarkers: [String: TaskReadMarker] = [:]
    private static let readMarkerRetention: TimeInterval = 30 * 24 * 60 * 60
    private var hasReceivedTaskBaseline = false
    private var presentedActiveTaskIDs: Set<String>?
    private var bubbleOrder: [String] = []
    private var terminalHoldUntil: [String: TimeInterval] = [:]
    private var lastBubbleObservation: [String: BubbleObservation] = [:]
    private var bubbleHoldTask: Task<Void, Never>?
    private let now: () -> TimeInterval

    init(
        defaults: UserDefaults = .standard,
        socketPath: String = "",
        provenanceStore: ResearchProvenanceStore = .live,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.now = now
        self.provenanceStore = provenanceStore
        self.socketPath = socketPath
        persistedTargetBindingKey = defaults.string(forKey: Keys.targetBindingKey)
        selectedWorkspaceID = defaults.string(forKey: Keys.workspaceID)
        sessionID = defaults.string(forKey: Keys.sessionID)
        let restoredDraft = defaults.string(forKey: Keys.draft) ?? ""
        draft = restoredDraft
        let savedSkillPrefix = defaults.string(forKey: Keys.selectedSkillPrefix)
        selectedSkillPrefix = savedSkillPrefix.flatMap { restoredDraft.hasPrefix($0) ? $0 : nil }
        pendingRequestID = defaults.string(forKey: Keys.requestID)
        pendingRequestText = defaults.string(forKey: Keys.requestText)
        pendingRequestSignature = defaults.string(forKey: Keys.requestSignature)
        pendingSessionID = defaults.string(forKey: Keys.pendingSessionID)
        promptMayHaveBeenSent = pendingRequestID != nil
        if pendingRequestID != nil {
            // The App may have quit while a prompt was in flight. Keep the
            // explicit discard path available after relaunch.
            submissionStatus = .unconfirmed
        }
        if let data = defaults.data(forKey: Keys.taskReadMarkers),
           let markers = try? JSONDecoder().decode([String: TaskReadMarker].self, from: data) {
            readMarkers = markers
        }
    }

    var selectedWorkspace: DSHPetWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedWorkspaceTitle: String? { selectedWorkspace?.title }

    var hasWorkspace: Bool { selectedWorkspace != nil }

    /// Every ordinary Session projected by the bridge is a task-center
    /// candidate. The card list deliberately does not follow the composer's
    /// selected workspace: a task started from the Harness desktop or web UI
    /// must appear without first using the pet to pick a workspace.
    var taskCenterTasks: [DSHPetTaskSummary] { tasks }

    func workspaceTitle(for task: DSHPetTaskSummary) -> String? {
        workspaces.first { $0.id == task.workspaceID }?.title
    }

    /// Tasks that still need attention in any registered workspace. While the
    /// active-task panel is open, its opening snapshot remains visible so a
    /// result does not disappear immediately after the user reads it.
    var activeTasks: [DSHPetTaskSummary] {
        taskCenterTasks
            .filter { task in
                return isTaskActive(task) || (presentedActiveTaskIDs?.contains(task.id) == true)
            }
            .sorted(by: activeTaskPrecedes)
    }

    /// The five most recently updated, non-empty tasks which are not currently
    /// shown by the active-task classification (including its presentation
    /// snapshot).
    var recentTasks: [DSHPetTaskSummary] {
        let activeTaskIDs = Set(activeTasks.map(\.id))
        return Array(
            taskCenterTasks
                .filter { !$0.blank && !activeTaskIDs.contains($0.id) }
                .sorted(by: recentTaskPrecedes)
                .prefix(5)
        )
    }

    /// Task-center order: waiting for a user action, unread failures, unread
    /// completions, running work, then the remaining recent Sessions.
    var sortedTasks: [DSHPetTaskSummary] {
        taskCenterTasks.sorted(by: taskPrecedes)
    }

    var focusedTask: DSHPetTaskSummary? {
        guard let focusedTaskID else { return nil }
        return tasks.first { $0.id == focusedTaskID }
    }

    var unreadTaskCount: Int {
        activeTasks.reduce(into: 0) { count, task in
            if isTaskUnread(task) && (task.completed || task.failed) { count += 1 }
        }
    }

    var inputTargetTitle: String {
        guard let sessionID else { return "新建会话" }
        return tasks.first { $0.id == sessionID }?.title ?? "会话 \(sessionID.suffix(8))"
    }

    var canSend: Bool {
        guard connection == .connected,
              !choosingResearchFile, !loadingResearchFile, !pdfRequestRunning, !modelSwitching,
              capabilitiesAvailable,
              hasWorkspace,
              (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty),
              submissionStatus != .submitting else { return false }
        if !draftImages.isEmpty && !imageAttachmentsAvailable { return false }
        return !(sessionSnapshot?.taskRunning ?? false) && !conversationRunning
    }

    /// A source change is destructive to the local routing context while a
    /// draft or an unconfirmed request is present. The caller can use this to
    /// disable a target picker before invoking `configure`.
    var targetSwitchBlocked: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftImages.isEmpty
            || submissionStatus == .submitting
            || submissionStatus == .unconfirmed
            || pdfRequestRunning
            || pendingRequestID != nil
    }

    /// Whether a request may still be in flight or may already have reached
    /// Harness. The composer exposes an explicit discard action for this state.
    var hasPendingSubmission: Bool {
        pendingRequestID != nil || submissionStatus == .unconfirmed
    }

    var targetBindingKey: String? {
        targetInstance?.bindingKey ?? persistedTargetBindingKey
    }

    var attachmentLimitSummary: String? {
        guard let imageLimits else { return nil }
        return "最多 \(imageLimits.maxImagesPerMessage) 张，单张 \(Self.byteLabel(imageLimits.maxImageBytes))"
    }

    var busyMessage: String? {
        guard let snapshot = sessionSnapshot, snapshot.taskRunning else { return nil }
        if snapshot.message == "无法确认任务状态，暂不可发送" { return snapshot.message }
        if snapshot.waitingForUser { return "请在 Harness 中完成当前操作" }
        return "当前会话正在执行，请稍候"
    }

    func start() {
        guard !started else { return }
        started = true
        guard sourceEnabled else {
            connection = .disconnected
            return
        }
        connect()
    }

    /// Switch the command source. Every connection is revalidated against the
    /// selected descriptor before any business request is allowed through.
    @discardableResult
    func configure(instance: HarnessInstance?) -> Bool {
        let currentBinding = targetBindingKey
        let requestedBinding = instance?.bindingKey ?? currentBinding
        // A bridge reload changes instanceId, often in the same host PID.
        // The stable profile/home targetId is the conversation identity;
        // reloading that target must not silently discard its bound session.
        let changed = requestedBinding != currentBinding
        let canAdoptUnidentifiedTarget = targetInstance == nil
            && persistedTargetBindingKey == nil
            && instance != nil
            && pendingRequestID == nil
            && submissionStatus != .submitting
            && submissionStatus != .unconfirmed
        if changed && targetSwitchBlocked && !canAdoptUnidentifiedTarget {
            lastError = "请先处理当前草稿或未确认请求，再切换 Harness 来源"
            return false
        }

        let hadUnidentifiedHistory = persistedTargetBindingKey == nil
            && targetInstance == nil
            && instance != nil
            && (selectedWorkspaceID != nil || sessionID != nil || pendingRequestID != nil)
        invalidateConnection(clearPersistedPending: changed)
        if changed {
            clearTargetCaches()
        } else {
            // A restarted process may keep the same stable bindingKey but has
            // a new instanceId. Never replay old queued or in-flight requests.
            queuedPayloads.removeAll(keepingCapacity: false)
            failPending(with: DSHPetCommandError.unavailable)
            if submissionStatus == .submitting {
                submissionStatus = promptMayHaveBeenSent ? .unconfirmed : .failed("消息尚未发送，请在连接恢复后重试")
            }
        }

        if hadUnidentifiedHistory {
            selectedWorkspaceID = nil
            defaults.removeObject(forKey: Keys.workspaceID)
            continuationWarning = "Harness 来源已更新，请重新选择工作区"
        }

        sourceEnabled = instance != nil
        if let instance {
            targetInstance = instance
            persistedTargetBindingKey = instance.bindingKey
            defaults.set(instance.bindingKey, forKey: Keys.targetBindingKey)
            socketPath = instance.commandSocketPath
            expectedInstanceID = instance.instanceId
        } else {
            // Keep the last target identity for a later rediscovery, while the
            // disabled state prevents any stale socket from being used.
            socketPath = ""
            expectedInstanceID = nil
        }
        capabilitiesValidated = false
        resetCapabilityState()
        guard started, sourceEnabled else {
            connection = .disconnected
            return true
        }
        connect()
        return true
    }

    func stop() {
        flushDraftPersistence()
        removeResearchSelection()
        materialReadTask?.cancel()
        pdfTask?.cancel()
        stopResearchPolling()
        started = false
        invalidateConnection(clearPersistedPending: false)
        resetCapabilityState()
    }

    func addImageFromPasteboard(_ pasteboard: NSPasteboard = .general) {
        guard submissionStatus != .submitting else { return }
        guard imageAttachmentsAvailable else {
            lastError = "当前 Research Companion 桥接插件不支持图片附件"
            return
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            lastError = "剪贴板中没有可用图片"
            return
        }
        addDraftImage(data: png, mediaType: "image/png", name: "粘贴图片.png")
    }

    func makeRegionCaptureURL() -> URL? {
        guard submissionStatus != .submitting else { return nil }
        guard imageAttachmentsAvailable else {
            lastError = "当前 Research Companion 桥接插件不支持图片附件"
            return nil
        }
        do {
            let directory = try draftImageDirectory()
            return directory.appendingPathComponent("截屏-\(UUID().uuidString.lowercased()).png")
        } catch {
            lastError = errorMessage(error)
            return nil
        }
    }

    func acceptRegionCapture(at url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        addDraftImageFile(url: url, data: data, mediaType: "image/png", name: "框选截图.png")
    }

    func cancelRegionCapture(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func reportRegionCaptureFailure(_ message: String) {
        lastError = message.isEmpty ? "截图失败，请检查屏幕录制权限" : message
    }

    func removeDraftImage(_ id: String) {
        guard submissionStatus != .submitting else { return }
        guard let image = draftImages.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: image.fileURL)
        draftImages.removeAll { $0.id == id }
        invalidatePendingSubmission()
        persistDraftImages()
    }

    func retryFailedImages() {
        for index in draftImages.indices { draftImages[index].error = nil }
        persistDraftImages()
        submitDraft()
    }

    func refreshWorkspaces() {
        refreshWorkspaces(expectedGeneration: nil)
    }

    private func refreshWorkspaces(expectedGeneration: Int?) {
        // Opening the panel can race the transport handshake. A business
        // request is not admissible until capabilities have been validated;
        // the successful handshake below always refreshes workspaces itself.
        guard connection == .connected, capabilitiesValidated else { return }
        let generation = expectedGeneration ?? connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(action: "workspaces", expectedGeneration: generation)
                guard self.connectionGeneration == generation else { return }
                applyWorkspaces(decodeWorkspaces(response["workspaces"]))
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    /// Install a workspace projection received from the bridge. Keeping the
    /// current send target requires it to still exist; otherwise the pet must
    /// ask for a new one before sending.
    func applyWorkspaces(_ decoded: [DSHPetWorkspace]) {
        workspaces = decoded
        let selectedWorkspaceExists = selectedWorkspaceID.map { selected in
            decoded.contains(where: { $0.id == selected })
        } ?? false
        if selectedWorkspaceExists {
            restoreCurrentFileIfNeeded()
            refreshBubbleDeck()
            return
        }

        // A restored conversation must not become a new conversation merely
        // because its workspace is temporarily absent or filtered by the host.
        // Keep both identities for inspection and require an explicit new-session action.
        if sessionID != nil || pendingSessionID != nil || hasPendingSubmission {
            lastError = "原工作区暂不可用，已暂停发送并保留会话。请检查 DSH，或明确点击新建对话。"
            refreshBubbleDeck()
            return
        }

        // The selected workspace disappeared (or was never selected): the
        // bound Session cannot be a valid input target anymore. Clear the
        // Session and its subscription before optionally auto-selecting the
        // only remaining workspace.
        let hadTarget = selectedWorkspaceID != nil
            || sessionID != nil
            || sessionSnapshot != nil
            || hasPendingSubmission
        if hadTarget {
            selectedWorkspaceID = nil
            defaults.removeObject(forKey: Keys.workspaceID)
            presentedActiveTaskIDs = nil
            clearSessionBinding()
            clearFocusedTask()
            submissionStatus = .idle
            lastError = "当前工作区已不可用，已清除输入目标"
        }

        if decoded.count == 1, let only = decoded.first {
            selectWorkspace(only.id)
        } else {
            selectedWorkspaceID = nil
            defaults.removeObject(forKey: Keys.workspaceID)
        }
        refreshBubbleDeck()
    }

    func selectWorkspace(_ id: String) {
        guard submissionStatus != .submitting, !pdfRequestRunning else { return }
        guard workspaces.contains(where: { $0.id == id }) else { return }
        if selectedWorkspaceID != id {
            guard pendingRequestID == nil, submissionStatus != .unconfirmed else {
                lastError = "请先处理未确认的消息，再切换工作区"
                return
            }
            selectedWorkspaceID = id
            defaults.set(id, forKey: Keys.workspaceID)
            presentedActiveTaskIDs = nil
            clearSessionBinding()
            clearFocusedTask()
        }
    }

    /// Forget only DSHPet's current binding. Existing Harness sessions are
    /// never deleted or cancelled.
    /// Abandon the pending request and release the target/workspace guard.
    /// If the draft is still exactly the message that was submitted and has no
    /// attachments, it is cleared too; edited drafts are kept. The user chooses
    /// this after checking Harness, and a message that did arrive may be
    /// duplicated if it is sent again.
    func discardPendingSubmission() {
        guard submissionStatus != .submitting, hasPendingSubmission else { return }
        let submittedText = pendingRequestText
        invalidatePendingSubmission()
        if let submittedText,
           draft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedText,
           draftImages.isEmpty {
            draft = ""
        }
        submissionStatus = .idle
        lastError = nil
    }

    func startNewSession() {
        guard submissionStatus != .submitting, !modelSwitching, !pdfRequestRunning, !hasPendingSubmission else {
            continuationWarning = "请先等本轮操作完成，再新建会话"
            return
        }
        if let key = attachmentKey(session: nil) { defaults.removeObject(forKey: key) }
        clearSessionBinding()
        clearFocusedTask()
        submissionStatus = .idle
        lastError = nil
        continuationWarning = nil
        refreshWorkspaces()
    }

    func focusTask(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if focusedTaskID != id { taskOpenGeneration &+= 1 }
        focusedTaskID = id
        markTaskRead(task)
        continuationWarning = nil
        taskOpenError = nil
        refreshTaskPreview(task, retryEmpty: !task.taskRunning)
    }

    /// Acknowledge a terminal result from its trailing status button. Unlike
    /// opening the detail card, this removes the card from the frozen active
    /// presentation immediately and drops it from the bubble deck.
    func acknowledgeTask(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }),
              DSHPetBubbleDeckBuilder.isTerminal(task) else { return }
        readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
        presentedActiveTaskIDs?.remove(task.id)
        if focusedTaskID == task.id { clearFocusedTask() }
        persistReadMarkers()
        rebuildBubbleDeck(now: now())
    }

    func clearFocusedTask() {
        taskOpenGeneration &+= 1
        focusedTaskID = nil
        continuationWarning = nil
        taskOpenError = nil
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        taskPreview = nil
        taskPreviewStatus = nil
    }

    /// Freeze the active-task panel's visible membership until it closes.
    func beginActiveTaskPresentation() {
        guard presentedActiveTaskIDs == nil else { return }
        presentedActiveTaskIDs = Set(activeTasks.map(\.id))
    }

    /// Release the presentation snapshot. Read terminal tasks then migrate to
    /// `recentTasks` on the next classification pass.
    func endActiveTaskPresentation() {
        presentedActiveTaskIDs = nil
    }

    /// Select a task as the input target. A non-empty draft blocks switching
    /// to another Session (or another task workspace) so a pending message
    /// cannot be sent elsewhere.
    @discardableResult
    func continueTask(_ task: DSHPetTaskSummary) -> Bool {
        continueSession(task.sessionID, workspace: task.workspaceID, task: task)
    }

    private func continueSession(_ target: String, workspace: String, task: DSHPetTaskSummary?) -> Bool {
        guard submissionStatus != .submitting, !modelSwitching, !pdfRequestRunning else { return false }
        if hasPendingSubmission, target != sessionID {
            continuationWarning = "请先处理未确认的消息，再切换会话"
            return false
        }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty
        if workspace != selectedWorkspaceID {
            guard workspaces.contains(where: { $0.id == workspace }) else {
                continuationWarning = "该任务的工作区已不可用"
                return false
            }
            if pendingRequestID != nil || submissionStatus == .unconfirmed {
                continuationWarning = "请先处理未确认的消息，再切换工作区"
                return false
            }
            if hasDraft {
                continuationWarning = "请先处理当前草稿，再切换会话"
                return false
            }
            selectWorkspace(workspace)
        }
        if hasDraft, sessionID != target {
            continuationWarning = "请先处理当前草稿，再切换会话"
            return false
        }
        continuationWarning = nil
        focusedTaskID = target
        if let task { markTaskRead(task) }
        if sessionID == target { return true }

        flushDraftPersistence()
        sessionBindingGeneration &+= 1
        sessionCreationTask?.cancel()
        sessionCreationTask = nil
        dismissCandidates()
        if sessionID == nil, let key = attachmentKey(session: nil) { defaults.removeObject(forKey: key) }
        sessionID = target
        resetCurrentFile()
        restoreCurrentFileIfNeeded()
        defaults.set(target, forKey: Keys.sessionID)
        resetResearchConversation()
        // Task summaries retain terminal results for card history. The pet must
        // wait for the live Session subscription instead of animating that
        // historical result indefinitely.
        sessionSnapshot = nil
        subscribe(to: target)
        refreshResearch()
        return true
    }

    @discardableResult
    func selectResearchSession(_ row: ResearchHistoryRow) -> Bool {
        guard row.workspaceId == selectedWorkspaceID, !conversationRunning,
              !modelSwitching, !hasPendingSubmission else {
            continuationWarning = "请先等本轮操作完成，再切换会话"
            return false
        }
        return continueSession(row.sessionId, workspace: row.workspaceId, task: tasks.first { $0.id == row.id })
    }

    private func removalPlan(for id: String, in workspace: String, confirmed: Int64?, prepare: Bool, online: Bool = false) async throws -> ResearchRemovalPlan {
        let generation = connectionGeneration
        var fields: [String: Any] = ["workspaceId": workspace, "sessionId": id]
        if let confirmed { fields["createdAt"] = confirmed }
        let action = online ? (prepare ? "research-retirement-online-commit" : "research-retirement-online-plan")
                            : (prepare ? "research-retirement-prepare" : "research-retirement-plan")
        let response = try await request(action: action,
                                         fields: fields, timeout: 30, expectedGeneration: generation)
        guard generation == connectionGeneration, targetInstance?.kind == .desktop,
              let plan = ResearchProtocol.decode(ResearchRemovalPlan.self, from: response["retirement"]),
              plan.workspaceId == workspace, plan.sessionId == id, plan.matchesResearchWorkspace,
              confirmed == nil || confirmed == plan.createdAt else {
            throw ResearchRemovalError.unavailable("未能核实会话和工作区的归属。")
        }
        guard plan.ready else { throw ResearchRemovalError.unavailable(plan.reason ?? "DSH 仍在执行任务。") }
        return plan
    }

    func retireResearchSession(_ row: ResearchHistoryRow?, confirmedOffline: ResearchRemovalPlan? = nil) {
        guard !retirementInProgress else { return }
        if let confirmedOffline, let saved = retirementTicket,
           (saved.sessionId != confirmedOffline.sessionId || saved.workspaceId != confirmedOffline.workspaceId || saved.createdAt != confirmedOffline.createdAt) { return }
        let prior = confirmedOffline ?? retirementTicket
        guard row != nil ? researchDeletionAvailable : prior != nil else { return }
        guard let id = row?.sessionId ?? prior?.sessionId, let workspace = row?.workspaceId ?? prior?.workspaceId,
              row == nil || selectedWorkspaceID == workspace,
              prior == nil || (prior?.workspaceId == workspace && prior?.sessionId == id) else {
            retirementNotice = "请先处理先前未完成的删除。"; return
        }
        guard !modelSwitching, !pdfRequestRunning, !hasPendingSubmission, submissionStatus != .submitting,
              (id != sessionID || (draft.isEmpty && draftImages.isEmpty)) else {
            retirementNotice = "请先结束当前操作，并保存目标会话的草稿，再删除。"; return
        }
        let binding = targetBindingKey
        retirementInProgress = true
        retirementNotice = "正在核对会话归属及其他 DSH 任务…"
        Task {
            defer { retirementInProgress = false }
            var reopenWhenSafe = false
            do {
                let desktop = try ResearchSessionRemoval.runningDesktop()
                var finishedOnline = false
                var identity = prior
                if confirmedOffline == nil && (onlineDeletionAvailable || prior?.online != nil) {
                    guard desktop != nil, onlineDeletionAvailable else {
                        if let prior { offlineDeletionOffer = prior }
                        retirementNotice = "当前连接无法在线删除。需要确认后才能使用离线流程。"
                        return
                    }
                    var checked = try await removalPlan(for: id, in: workspace, confirmed: prior?.createdAt, prepare: false, online: true)
                    if checked.online == "available" {
                        defaults.set(try JSONEncoder().encode(checked), forKey: retirementTicketKey)
                        guard defaults.synchronize() else { throw ResearchRemovalError.unavailable("未能保存原目标的恢复票据。") }
                        retirementNotice = "正在等待目标会话停写并核对永久删除结果…"
                        checked = try await removalPlan(for: id, in: workspace, confirmed: checked.createdAt, prepare: true, online: true)
                    }
                    if checked.online == "offline-required" {
                        offlineDeletionOffer = checked
                        retirementNotice = checked.reason ?? "当前需要短暂重开 DSH 才能安全删除。"
                        return
                    }
                    guard checked.online == "deleted", checked.phase == "deleted" else {
                        throw ResearchRemovalError.unavailable("尚未核实目标会话的持久删除结果。")
                    }
                    identity = checked
                    finishedOnline = true
                }
                if !finishedOnline {
                    let plan: ResearchRemovalPlan
                    if let desktop {
                        var live = try await removalPlan(for: id, in: workspace, confirmed: identity?.createdAt, prepare: false)
                        if live.phase != "deleted" {
                            guard ResearchSessionRemoval.supportsOffline(live) else {
                                throw ResearchRemovalError.unavailable("此工作区没有可用的离线删除组件。DSH 继续运行。")
                            }
                            live = try await removalPlan(for: id, in: workspace, confirmed: live.createdAt, prepare: true)
                            defaults.set(try JSONEncoder().encode(live), forKey: retirementTicketKey)
                            guard defaults.synchronize() else { throw ResearchRemovalError.unavailable("无法保存恢复票据，已暂停删除。") }
                            retirementNotice = "正在等待 DSH 正常退出…"
                            try await ResearchSessionRemoval.quit(desktop)
                        }
                        plan = live
                    } else if let identity, identity.matchesResearchWorkspace {
                        plan = identity
                    } else { throw ResearchRemovalError.unavailable("请先打开已连接的正式 DSH。") }
                    if plan.phase != "deleted" {
                        retirementNotice = "正在核对所有写入者并删除指定会话…"
                        let receipt = try await Task.detached { try ResearchSessionRemoval.removeOffline(plan) }.value
                        if receipt.phase == "untouched" {
                            defaults.removeObject(forKey: retirementTicketKey)
                            reopenWhenSafe = true
                        }
                        guard receipt.phase == "deleted" else {
                            throw ResearchRemovalError.unavailable(receipt.message ?? "删除未完成，可重试同一会话。")
                        }
                        reopenWhenSafe = true
                    }
                }
                if let key = modelKey(target: binding, workspace: workspace, session: id) { defaults.removeObject(forKey: key) }
                try provenanceStore.remove(session: id)
                defaults.removeObject(forKey: ResearchFileAttachment.key(host: binding ?? "", workspace: workspace, session: id))
                if targetBindingKey == binding {
                    if readMarkers.removeValue(forKey: id) != nil { persistReadMarkers() }
                    lastBubbleObservation.removeValue(forKey: id)
                    terminalHoldUntil.removeValue(forKey: id)
                    bubbleOrder.removeAll { $0 == id }
                    presentedActiveTaskIDs?.remove(id)
                    tasks.removeAll { $0.sessionID == id && $0.workspaceID == workspace }
                    if focusedTaskID == id { clearFocusedTask() }
                    refreshBubbleDeck()
                }
                if selectedWorkspaceID == workspace, targetBindingKey == binding, sessionID == id {
                    clearSessionBinding()
                }
                defaults.removeObject(forKey: retirementTicketKey)
                offlineDeletionOffer = nil
                retiredRevision &+= 1
                if reopenWhenSafe {
                    retirementNotice = "指定会话已删除，正在重新打开 DSH…"
                    reopenWhenSafe = false
                    try await ResearchSessionRemoval.reopen()
                }
                retirementNotice = "指定会话已永久删除。"
            } catch {
                retirementNotice = error.localizedDescription
                if reopenWhenSafe {
                    do { try await ResearchSessionRemoval.reopen() }
                    catch { retirementNotice = (retirementNotice ?? "") + " 请手动重新打开 DSH。" }
                }
            }
        }
    }

    func fetchResearchHistory(query: ResearchHistoryQuery, offset: Int, revision: String?) async throws -> ResearchHistoryPage {
        guard researchHistoryAvailable, let workspace = selectedWorkspaceID else { throw DSHPetCommandError.unavailable }
        let generation = connectionGeneration
        var fields: [String: Any] = [
            "workspaceId": workspace, "historyTitle": String(decoding: query.title.utf16.prefix(1_024), as: UTF16.self),
            "historyMaterial": String(decoding: query.material.utf16.prefix(1_024), as: UTF16.self),
            "historyStatus": query.status.rawValue, "historyOffset": offset,
        ]
        if let revision { fields["historyRevision"] = revision }
        let response = try await request(action: "researchHistory", fields: fields, timeout: 12, expectedGeneration: generation)
        guard generation == connectionGeneration, selectedWorkspaceID == workspace, !Task.isCancelled else {
            throw CancellationError()
        }
        guard let page = ResearchProtocol.decode(ResearchHistoryPage.self, from: response),
              page.matches?.allSatisfy({ $0.workspaceId == workspace }) != false else {
            throw DSHPetCommandError.malformed
        }
        return page
    }

    /// Ask the Harness client half to focus this exact Session. The workspace
    /// membership check keeps a stale or forged task summary from selecting a
    /// Session outside the instance currently connected to Research Companion.
    func openTaskSession(_ task: DSHPetTaskSummary) {
        taskOpenGeneration &+= 1
        let openGeneration = taskOpenGeneration
        taskOpenError = nil
        guard connection == .connected, capabilitiesValidated else {
            taskOpenError = DSHPetCommandError.unavailable.errorDescription
            lastError = taskOpenError
            return
        }
        guard let workspace = workspaces.first(where: { $0.id == task.workspaceID }),
              workspace.sessionIds.contains(task.sessionID) else {
            taskOpenError = "该任务已不属于当前 Harness 工作区"
            lastError = taskOpenError
            return
        }
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await request(
                    action: "openSession",
                    fields: ["workspaceId": task.workspaceID, "sessionId": task.sessionID],
                    timeout: 12,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation, taskOpenGeneration == openGeneration else { return }
                lastError = nil
                taskOpenError = nil
                focusTask(task.id)
            } catch {
                guard self.connectionGeneration == generation, taskOpenGeneration == openGeneration else { return }
                if case DSHPetCommandError.timedOut = error {
                    taskOpenError = "打开会话超时，请确认 Harness 客户端已加载"
                } else {
                    taskOpenError = errorMessage(error)
                }
                lastError = taskOpenError
            }
        }
    }

    func updateCandidates(kind: DSHPetCandidateKind, query: String) {
        candidateGeneration &+= 1
        let generation = candidateGeneration
        candidateTask?.cancel()
        candidateKind = kind
        candidates = []
        candidatesError = nil
        guard connection == .connected, capabilitiesValidated else {
            candidatesLoading = false
            candidatesError = "请先连接 Harness"
            return
        }
        guard kind == .file ? fileCandidatesAvailable : skillCandidatesAvailable else {
            candidatesLoading = false
            candidatesError = "当前 Harness 不支持此功能"
            return
        }
        guard let workspaceID = selectedWorkspaceID, hasWorkspace else {
            candidatesLoading = false
            candidatesError = "请先选择工作区"
            return
        }
        let connectionGeneration = self.connectionGeneration
        let bindingGeneration = sessionBindingGeneration
        candidatesLoading = true
        candidateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await ensureSession(expectedGeneration: connectionGeneration)
                guard !Task.isCancelled, candidateGeneration == generation,
                      sessionBindingGeneration == bindingGeneration,
                      selectedWorkspaceID == workspaceID, sessionID == session else { return }
                var fields: [String: Any] = ["workspaceId": workspaceID, "sessionId": session]
                if kind == .file { fields["query"] = query }
                let response = try await request(
                    action: kind == .file ? "fileCandidates" : "skillCandidates",
                    fields: fields, timeout: 12, expectedGeneration: connectionGeneration
                )
                guard !Task.isCancelled, candidateGeneration == generation,
                      sessionBindingGeneration == bindingGeneration,
                      selectedWorkspaceID == workspaceID, sessionID == session else { return }
                candidates = try Self.decodeCandidates(response, kind: kind, query: query)
                candidatesLoading = false
            } catch {
                guard !Task.isCancelled, candidateGeneration == generation,
                      self.connectionGeneration == connectionGeneration,
                      sessionBindingGeneration == bindingGeneration else { return }
                candidatesLoading = false
                candidatesError = errorMessage(error)
            }
        }
    }

    func dismissCandidates() {
        candidateGeneration &+= 1
        candidateTask?.cancel()
        candidateTask = nil
        candidateKind = nil
        candidates = []
        candidatesLoading = false
        candidatesError = nil
    }

    static func decodeCandidates(_ response: [String: Any], kind: DSHPetCandidateKind, query: String) throws -> [DSHPetInputCandidate] {
        if kind == .file {
            guard let rows = response["candidates"] as? [[String: Any]] else { throw DSHPetCommandError.malformed }
            return rows.compactMap { row in
                guard let path = row["path"] as? String,
                      let type = row["kind"] as? String,
                      type == "file" || type == "directory" else { return nil }
                let fullPath = path + (type == "directory" && !path.hasSuffix("/") ? "/" : "")
                let invalid = fullPath.unicodeScalars.contains {
                    $0.value == 34 || $0.value < 32 || (0x7f...0x9f).contains($0.value)
                }
                let quoted = fullPath.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
                let insert = quoted ? "@\"\(fullPath)\"" : "@\(fullPath)"
                return DSHPetInputCandidate(id: "\(type):\(path)", label: fullPath,
                    insertText: insert, detail: type == "directory" ? "目录" : "文件",
                    disabledReason: invalid ? "此路径无法用 Harness 引用格式表示" : nil)
            }
        }
        guard let rows = response["skills"] as? [[String: Any]] else { throw DSHPetCommandError.malformed }
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                  query.isEmpty || name.localizedCaseInsensitiveContains(query) else { return nil }
            return DSHPetInputCandidate(id: name, label: name, insertText: "/\(name) ",
                detail: row["description"] as? String,
                disabledReason: row["conflict"] as? Bool == false ? nil : "无法确认是否与 Harness 命令同名")
        }
    }

    private func refreshTaskPreview(_ task: DSHPetTaskSummary, retryEmpty: Bool = false) {
        previewGeneration &+= 1
        let generation = previewGeneration
        previewTask?.cancel()
        taskPreview = nil
        guard taskPreviewAvailable else {
            taskPreviewStatus = "当前 Harness 不支持回复预览"
            return
        }
        taskPreviewStatus = "正在加载回复预览…"
        let connectionGeneration = self.connectionGeneration
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for attempt in 0...(retryEmpty ? 2 : 0) {
                    if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
                    let response = try await request(action: "taskPreview", fields: [
                        "workspaceId": task.workspaceID, "sessionId": task.sessionID,
                    ], timeout: 12, expectedGeneration: connectionGeneration)
                    guard !Task.isCancelled, previewGeneration == generation,
                          focusedTaskID == task.id, self.connectionGeneration == connectionGeneration else { return }
                    guard let status = response["status"] as? String else { throw DSHPetCommandError.malformed }
                    switch status {
                    case "available":
                        guard let text = response["text"] as? String, !text.isEmpty else { throw DSHPetCommandError.malformed }
                        taskPreview = text
                        taskPreviewStatus = nil
                        return
                    case "empty":
                        taskPreviewStatus = "暂无回复预览"
                        if attempt < (retryEmpty ? 2 : 0) { continue }
                    case "unsupported": taskPreviewStatus = "当前 Harness 不支持回复预览"
                    case "migration-required": taskPreviewStatus = "会话需要迁移，暂无法显示回复预览"
                    default: throw DSHPetCommandError.malformed
                    }
                    return
                }
            } catch {
                guard !Task.isCancelled, previewGeneration == generation,
                      focusedTaskID == task.id, self.connectionGeneration == connectionGeneration else { return }
                taskPreviewStatus = "回复预览加载失败：\(errorMessage(error))"
            }
        }
    }

    func refreshTasks() {
        guard taskListAvailable else { return }
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(action: "tasks", timeout: 12, expectedGeneration: generation)
                guard self.connectionGeneration == generation else { return }
                applyTasks(response["tasks"])
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    func submitDraft() { submitPreparedDraft(selection: nil) }

    /// A keyboard/service translation owns its source, question and attachments independently of the draft.
    private func submitPreparedDraft(selection: (id: UUID, material: ResearchMaterial)?, prepared: ResearchMaterial? = nil, questionOverride: String? = nil, pinned: ResearchModelSelection? = nil) {
        guard !retirementInProgress else { lastError = "请等待 DSH 完成会话删除并重连。"; return }
        guard !pdfRequestRunning else {
            lastError = "当前 PDF 任务正在运行，请稍候。"
            return
        }
        guard submissionStatus != .submitting, !modelSwitching else { return }
        guard !choosingResearchFile, !loadingResearchFile else {
            lastError = "请先完成文件选择并查看材料预览。"
            return
        }
        let originalDraft = draft
        let sourceURL = prepared == nil ? nil : fixedMaterialURL
        let sourceStamp = prepared == nil ? nil : fixedStamp
        let sourceRevision = materialRevision
        let text = selection == nil ? (questionOverride ?? draft.trimmingCharacters(in: .whitespacesAndNewlines)) : "请将本次选中的原文翻译成中文。"
        let submittedImages = selection == nil ? draftImages : []
        guard !text.isEmpty || !submittedImages.isEmpty else { return }
        guard selectedWorkspace != nil else {
            submissionStatus = .failed("请先选择工作区")
            return
        }
        if let busyMessage {
            submissionStatus = .failed(busyMessage)
            return
        }

        let researchMode: ResearchPromptMode = selection == nil ? submissionResearchMode : .translate
        let isTranslation = researchMode == .translate
        let guardedModel = isTranslation || researchAvailable
        let capturedModel: ResearchModelSelection?
        do { capturedModel = try pinned ?? modelForTurn(translation: guardedModel) }
        catch { lastError = error.localizedDescription; return }
        if isTranslation && (!researchAvailable || !submittedImages.isEmpty) {
            lastError = "当前连接或附件不支持已核验的翻译路由。"
            return
        }
        let useResearch = researchAvailable && submittedImages.isEmpty
        let supplied = selection?.material ?? prepared
        let chosen = supplied ?? (includePaperContext ? displayedResearchMaterial : nil)
        let legacyZotero = supplied == nil && appMaterial == nil && !hasAssociatedFile && materialSource == .zotero && paperContext?.key != nil
        if let chosen, !useResearch || (!legacyZotero && !materialTransportAvailable) || chosen.text.isEmpty
                || chosen.text.utf16.count > ResearchMaterial.maximumLength {
            lastError = "本次材料未准备好或超出科研桥的单次上限，消息未发送。"
            return
        }
        let includeContext = useResearch && chosen != nil
        let contextKey = supplied == nil && appMaterial == nil && !hasAssociatedFile
            && includeContext && materialSource == .zotero ? paperContext?.key : nil
        let inline = contextKey == nil ? chosen : nil
        let materialID = (contextKey ?? inline?.id.uuidString ?? "") + (prepared != nil ? (fixedMaterial?.id.uuidString ?? "") : "")
        let legacySignature = (selection == nil ? submissionSignature(text: text) : text) + (useResearch ? "|research:\(researchMode.rawValue):\(includeContext):\(materialID)" : "")
        let signature = legacySignature + (capturedModel.map { "|model:" + $0.signature } ?? "")
        let matchingPending = pendingRequestSignature == signature || pendingRequestSignature == legacySignature
        if pendingRequestID != nil, !matchingPending {
            lastError = "请先核对或丢弃未确认的消息，再发送不同内容"
            return
        }
        let submittedImageIDs = Set(submittedImages.map(\.id))
        let requestID: String
        if matchingPending, let pendingRequestID {
            requestID = pendingRequestID
        } else {
            requestID = "dsh-pet-\((selection?.id ?? UUID()).uuidString.lowercased())"
            pendingRequestID = requestID
            pendingRequestText = text
            pendingRequestSignature = signature
            promptMayHaveBeenSent = false
            defaults.set(requestID, forKey: Keys.requestID)
            defaults.set(text, forKey: Keys.requestText)
            defaults.set(signature, forKey: Keys.requestSignature)
        }

        submissionStatus = .submitting
        lastError = nil
        let generation = connectionGeneration
        let selectionRevision = captureRevision
        let binding = sessionBindingGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            var promptAttempted = false
            do {
                guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
                let encodedImages = try encodedDraftImages(submittedImages)
                guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
                let sessionID = try await ensureSession(expectedGeneration: generation)
                guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
                if selection != nil, captureRevision != selectionRevision {
                    if pendingRequestID == requestID { invalidatePendingSubmission() }
                    submissionStatus = .failed("取词请求已取消，本次翻译未发送。")
                    return
                }
                let workspaceID = try requireWorkspaceID()
                var admittedModel = capturedModel
                if guardedModel, let capturedModel {
                    guard binding == sessionBindingGeneration, self.sessionID == sessionID else { throw CancellationError() }
                    admittedModel = try await bindTranslation(capturedModel, session: sessionID, workspace: workspaceID, generation: generation)
                    guard binding == sessionBindingGeneration, self.sessionID == sessionID,
                          selectedWorkspaceID == workspaceID, selection == nil || selectionRevision == captureRevision else { throw CancellationError() }
                }
                if let inline {
                    let store = provenanceStore
                    try await Task.detached(priority: .userInitiated) {
                        try store.record(session: sessionID, requestID: requestID, material: inline)
                    }.value
                    guard generation == connectionGeneration, binding == sessionBindingGeneration, self.sessionID == sessionID,
                          workspaceID == selectedWorkspaceID, selection == nil || selectionRevision == captureRevision else { throw CancellationError() }
                }
                if prepared != nil {
                    guard let sourceURL, let sourceStamp, materialRevision == sourceRevision,
                          fixedMaterialURL == sourceURL, (try? ResearchFileReference.fileStamp(sourceURL)) == sourceStamp else {
                        throw ResearchMaterialError.message("发送前材料已变更，未发送旧版本。请重新读取后再提问。")
                    }
                }
                promptAttempted = promptMayHaveBeenSent || (connection == .connected && capabilitiesValidated && connectionHandle != nil)
                promptMayHaveBeenSent = promptAttempted
                var fields: [String: Any] = [
                    "workspaceId": workspaceID, "sessionId": sessionID,
                    "requestId": requestID, "text": text, "images": encodedImages,
                ]
                if let admittedModel { fields["selection"] = admittedModel.wire }
                if useResearch {
                    fields["mode"] = researchMode.rawValue
                    fields["includeContext"] = includeContext
                    if let contextKey { fields["contextKey"] = contextKey }
                    if let inline { fields["material"] = inline.fields }
                }
                let response = try await request(
                    action: useResearch ? "researchPrompt" : "prompt",
                    fields: fields,
                    timeout: 32,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation else { return }
                guard response["ok"] as? Bool != false,
                      response["accepted"] as? Bool == true else {
                    throw DSHPetCommandError.malformed
                }
                if modelSelectionAvailable,
                   let actual = ResearchProtocol.decode(ResearchModelSelection.self, from: response["selection"]),
                   self.sessionID == sessionID {
                    modelSelectionRevision &+= 1
                    conversationSelection = actual
                }
                if selection == nil && draft == originalDraft { draft = "" }
                if !submittedImageIDs.isEmpty { clearDraftImages(ids: submittedImageIDs) }
                pendingRequestID = nil
                pendingRequestText = nil
                pendingRequestSignature = nil
                promptMayHaveBeenSent = false
                defaults.removeObject(forKey: Keys.requestID)
                defaults.removeObject(forKey: Keys.requestText)
                defaults.removeObject(forKey: Keys.requestSignature)
                submissionStatus = .submitted
                await refreshResearchState()
                if let task = tasks.first(where: { $0.id == sessionID }) { markTaskRead(task) }
                if selection == nil, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftImages.isEmpty {
                    onAccepted?()
                }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard self.connectionGeneration == generation else { return }
                if submissionStatus == .submitted { submissionStatus = .idle }
            } catch {
                guard self.connectionGeneration == generation else { return }
                if !promptAttempted && !promptMayHaveBeenSent && pendingRequestID == requestID {
                    invalidatePendingSubmission()
                }
                switch error {
                case DSHPetCommandError.timedOut, DSHPetCommandError.unavailable:
                    submissionStatus = promptAttempted || promptMayHaveBeenSent
                        ? .unconfirmed : .failed("消息尚未发送，请在连接恢复后重试")
                case DSHPetCommandError.server:
                    // An explicit server rejection is definitive: do not keep
                    // the pending request ID guarding target/workspace changes.
                    submissionStatus = .failed(errorMessage(error))
                    invalidatePendingSubmission()
                default:
                    submissionStatus = .failed(errorMessage(error))
                }
                lastError = submissionStatus.label ?? errorMessage(error)
                if !submittedImageIDs.isEmpty {
                    let message = errorMessage(error)
                    for index in draftImages.indices where submittedImageIDs.contains(draftImages[index].id) {
                        draftImages[index].error = message
                    }
                    persistDraftImages()
                }
            }
        }
    }

    private func checkAttachedFileVersion() -> Bool {
        guard let url = fixedMaterialURL, let stamp = fixedStamp, let saved = attachment else { return true }
        guard (try? ResearchFileReference.fileStamp(url)) != stamp else { return true }
        loadSessionFile(url, recognizeScans: saved.recognizeScans, restoring: saved)
        lastError = "文件已变更或无法访问，本次未发送。请核对更新后的材料再提问。"
        return false
    }

    func submitResearch(_ mode: ResearchPromptMode = .ask) {
        guard !retirementInProgress else { lastError = "会话删除正在进行。"; return }
        guard researchAvailable else {
            lastError = "科研桥接尚未就绪，未发送消息"
            return
        }
        guard !pdfRequestRunning else { return }
        if includePaperContext, capturingSelection {
            lastError = "正在读取本次选区，请等原文出现后再发送。"
            return
        }
        guard !conversationRunning else {
            lastError = "当前会话正在执行，请稍候。"
            return
        }
        let scope: ResearchDocumentScope
        do {
            scope = includePaperContext ? try ResearchDocumentScope.resolve(question: draft, mode: mode,
                selection: appMaterial, hasFile: hasAssociatedFile, filename: associatedPDFName ?? fixedMaterial?.title,
                captureFailed: selectionError != nil) : .general
        } catch { lastError = error.localizedDescription; return }
        if scope == .selection || scope == .combined, let material = appMaterial,
           material.text.utf16.count > ResearchMaterial.maximumLength {
            lastError = ResearchMaterial.oversizeMessage
            return
        }
        if scope == .file || scope == .combined {
            guard !hasPendingSubmission else { lastError = "请先核对或丢弃未确认的文档请求。"; return }
            guard checkAttachedFileVersion() else { return }
            guard let file = fixedMaterial else {
                lastError = materialError ?? "请等文件读取完成，或重新选择可用的文件。"
                return
            }
            guard draftImages.isEmpty else { lastError = "请将文件问题和附图分开发送，以保留原文依据。"; return }
            if let index = file.pdfIndex, !index.hasReadableContent {
                lastError = "当前 PDF 尚无可发送的正文。" + index.status
                return
            }
            if scope == .combined, let selection = appMaterial {
                submitSelectionWithBackground(selection, file: file, mode: mode)
                return
            }
            let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = file.pdfIndex {
                guard !typed.isEmpty || mode != .ask else { return }
                let question = typed.isEmpty
                    ? (mode == .translate ? "请将整篇 PDF 翻译为中文。" : "请分析整篇 PDF 的主要论证与依据。")
                    : typed
                let action = ResearchPDFIndex.requestsLocation(question) ? nil : ResearchPDFIndex.wholeTask(question, mode: mode)
                startPDFRequest(index, question: question, mode: mode, whole: action, capturedDraft: draft)
                return
            }
            guard !typed.isEmpty || mode != .ask else { return }
            do {
                let model = try modelForDocument()
                submitPreparedDraft(selection: nil, prepared: file, questionOverride: documentInstruction(typed, mode: mode), pinned: model)
            } catch { lastError = error.localizedDescription }
            return
        }
        guard mode == .ask || canUseResearchMaterial else {
            lastError = "请先选择要带入的材料。"
            return
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if mode == .translate { draft = "请将当前材料中的原文翻译成中文。" }
            else if mode == .explain { draft = "请解释当前原文的概念、论证和必要背景，并区分原文与推断。" }
        }
        submissionResearchMode = mode
        submitDraft()
        submissionResearchMode = .ask
    }

    /// A document turn belongs to the selection displayed for this session,
    /// including a session created or configured by another DSH client.
    private func modelForDocument() throws -> ResearchModelSelection {
        guard let model = try modelForTurn(translation: true) else {
            throw ResearchMaterialError.message("请先选择本轮文档使用的模型。")
        }
        if sessionID != nil {
            guard conversationSelection == model else {
                throw ResearchMaterialError.message("请在模型菜单明确选择此会话要使用的模型。本次文档请求未发送。")
            }
        }
        return model
    }

    private func documentInstruction(_ question: String, mode: ResearchPromptMode) -> String {
        switch mode {
        case .ask: return question
        case .translate: return "请将所给原文翻译为中文。" + question
        case .explain: return "请解释所给原文。" + question
        }
    }

    private func submitSelectionWithBackground(_ selection: ResearchMaterial, file: ResearchMaterial, mode: ResearchPromptMode) {
        let question = draft
        let binding = sessionBindingGeneration
        let revision = materialRevision
        let selectedRevision = captureRevision
        let model: ResearchModelSelection?
        do { model = try modelForDocument() }
        catch { lastError = error.localizedDescription; return }
        let capturedFile = fixedMaterialURL
        let stamp = fixedStamp
        pdfRequestRunning = true
        pdfRequestStatus = "正在查找相关文件段落…"
        pdfTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pdfRequestRunning = false; pdfTask = nil }
            let retrieval = Task.detached(priority: .userInitiated) { try selection.addingBackground(file, question: question) }
            do {
                let combined = try await withTaskCancellationHandler { try await retrieval.value } onCancel: { retrieval.cancel() }
                try Task.checkCancellation()
                guard binding == sessionBindingGeneration, revision == materialRevision, selectedRevision == captureRevision,
                      draft == question, includePaperContext else { throw CancellationError() }
                guard let capturedFile, let stamp, (try? ResearchFileReference.fileStamp(capturedFile)) == stamp else {
                    throw ResearchMaterialError.message("会话文件发生变化。请重新读取后再发送。")
                }
                pdfRequestRunning = false
                pdfRequestStatus = nil
                submitPreparedDraft(selection: nil, prepared: combined, questionOverride: documentInstruction(question, mode: mode), pinned: model)
            } catch {
                if binding == sessionBindingGeneration, revision == materialRevision {
                    let message = error is CancellationError ? "材料或问题已变更或已取消，本次未发送。" : error.localizedDescription
                    pdfRequestStatus = message
                    lastError = message
                }
            }
        }
    }

    func resolvePDFApproval(_ id: UUID, allow: Bool) {
        guard pdfBatchApproval?.id == id else { return }
        pdfBatchApproval = nil
        let waiting = pdfApprovalContinuation
        pdfApprovalContinuation = nil
        waiting?.resume(returning: allow)
    }

    private func approvePDFBatch(count: Int, scope: String, model: ResearchModelSelection?) async throws {
        try Task.checkCancellation()
        guard let model else { throw ResearchMaterialError.message("无法核实分段请求的模型。") }
        let cost = model.isSubscription ? "使用现有订阅额度。" : "这些请求可能按所选账号的模型费率扣费。"
        let approval = PDFBatchApproval(description: "\(scope)，最多 \(count) 次模型请求 · \(model.provider) / \(model.model)；\(cost)")
        let allowed: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pdfApprovalContinuation = continuation
                pdfBatchApproval = approval
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolvePDFApproval(approval.id, allow: false) }
        }
        guard allowed else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func stopPDFWork() {
        if loadingResearchFile {
            materialRevision &+= 1
            materialReadTask?.cancel()
            materialReadTask = nil
            loadingResearchFile = false
            materialError = "已停止读取文件。"
        }
        if pdfRequestRunning {
            pdfTask?.cancel()
            pdfRequestStatus = "正在停止；已提交的分段仍可在会话中查看。"
        }
    }

    func submitWholePDF(_ task: ResearchPDFIndex.WholeTask) {
        guard canUseAssociatedFile, checkAttachedFileVersion(), let index = fixedMaterial?.pdfIndex else { return }
        let instruction = task == .translation ? "请将整篇 PDF 翻译为中文。" : "请分析整篇 PDF 的主要论证、证据和限制。"
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        startPDFRequest(index, question: typed.isEmpty ? instruction : instruction + "\n" + typed,
                        mode: .ask, whole: task, capturedDraft: draft)
    }

    private func startPDFRequest(_ index: ResearchPDFIndex, question: String, mode: ResearchPromptMode,
                                 whole: ResearchPDFIndex.WholeTask?, capturedDraft: String) {
        guard !retirementInProgress, canUseAssociatedFile, draftImages.isEmpty, selectedWorkspace != nil,
              !modelSelectionAvailable || selectedResearchModel != nil else {
            lastError = "请确认当前模型、会话及附件状态，等待上一轮处理完成。"
            return
        }
        let revision = materialRevision
        let generation = connectionGeneration
        let binding = sessionBindingGeneration
        let model: ResearchModelSelection?
        do { model = try modelForDocument() }
        catch { lastError = error.localizedDescription; return }
        pdfRequestRunning = true
        pdfRequestStatus = "正在核验原 PDF 并从全部 \(index.pages.count) 页准备材料…"
        lastError = nil
        pdfTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = 0
            var total = 0
            defer { pdfRequestRunning = false; pdfTask = nil }
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard connectionGeneration == generation, sessionBindingGeneration == binding,
                      materialRevision == revision, includePaperContext else { throw CancellationError() }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    guard let url = index.reference.resolve() else {
                        throw ResearchMaterialError.message("原 PDF 已变更、移走或不可读，请刷新或重新选择文件。")
                    }
                    let stamp = try ResearchFileReference.fileStamp(url)
                    let chunks = try whole == nil ? index.prepare(question) : index.segments()
                    return (url, stamp, chunks)
                }
                let (url, stamp, chunks) = try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                try check()
                @MainActor func checkFile() throws {
                    try check()
                    guard (try? ResearchFileReference.fileStamp(url)) == stamp else {
                        throw ResearchMaterialError.message("处理时原 PDF 已变化或无法访问，已停止。请刷新文件。")
                    }
                }
                try checkFile()
                guard draft == capturedDraft, draftImages.isEmpty else { throw CancellationError() }
                guard !chunks.isEmpty else { throw ResearchMaterialError.message("未取得可核验的 PDF 原文。") }
                if chunks.count == 1 {
                    pdfRequestRunning = false
                    pdfRequestStatus = chunks[0].scope
                    // The packet belongs to this question. Never send or overwrite the presentation card.
                    submitPreparedDraft(selection: nil, prepared: chunks[0], questionOverride: documentInstruction(question, mode: mode), pinned: model)
                    return
                }
                let translate = mode == .translate || question.range(of: #"翻译|译成|译为|translate|translation"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
                let operation = whole ?? (translate ? .translation : .analysis)
                let synthesizes = operation == .analysis
                let scopeName = whole != nil ? "整篇 PDF" : "指定原文范围"
                let extra = synthesizes ? 1 : 0
                let coverage = ResearchPDFIndex.pageList(chunks.flatMap { ($0.pdfPositions ?? []).map { $0.page } })
                try await approvePDFBatch(count: chunks.count + extra, scope: scopeName + (coverage.isEmpty ? "" : " · 文件页 " + coverage), model: model)
                try checkFile()
                guard draft == capturedDraft else { throw CancellationError() }
                let session = try await ensureSession(expectedGeneration: generation)
                try checkFile()
                let workspace = try requireWorkspaceID()
                let pinnedModel: ResearchModelSelection?
                if let model {
                    pinnedModel = try await bindTranslation(model, session: session, workspace: workspace, generation: generation)
                    try checkFile()
                } else { pinnedModel = model }
                var notes: [String] = []
                total = chunks.count
                for (i, chunk) in chunks.enumerated() {
                    try checkFile()
                    let label = "第 \(i + 1)/\(total) 段 · PDF 文件第 \(chunk.pdfPages ?? "") 页"
                    pdfRequestStatus = "\(label) · 正在等待本段回答"
                    let action = operation == .translation
                        ? "按顺序完整翻译本段，保留术语、公式与文件页标识。"
                        : "分析本段与用户问题相关的证据、结果和限制，保留文件页码；输出简明的分段分析。"
                    let answer = try await submitPDFTurn(question: question + "\n" + label + "。 " + action,
                        material: chunk, session: session, workspace: workspace, generation: generation, model: pinnedModel)
                    completed += 1
                    if synthesizes { notes.append(label + "\n" + answer) }
                    if i == 0 && draft == capturedDraft { draft = "" }
                }
                if synthesizes && notes.count > 1 {
                    // Synthesize every chunk. Hierarchical grouping also handles long model answers.
                    var level = 0
                    var approvedSummaryCalls = 1
                    while notes.count > 1 {
                        try checkFile()
                        level += 1
                        guard level <= 6 else { throw ResearchMaterialError.message("分段分析已在会话中，汇总未能收敛。") }
                        let groups = try ResearchPDFIndex.summaryGroups(notes)
                        if groups.count > approvedSummaryCalls {
                            try await approvePDFBatch(count: groups.count - approvedSummaryCalls, scope: "追加分段汇总", model: pinnedModel)
                            try checkFile()
                        }
                        approvedSummaryCalls = 0
                        var reduced: [String] = []
                        for (i, group) in groups.enumerated() {
                            try checkFile()
                            pdfRequestStatus = "已分析全部 \(total) 段 · 正在汇总 \(i + 1)/\(groups.count)"
                            let material = ResearchMaterial(source: "分段分析记录", title: index.title, text: group,
                                scope: "全文分析的分段回答汇总；此材料为模型先前的分析，页码请对照原件。", fileReference: index.reference)
                            let answer = try await submitPDFTurn(question: question + "\n综合各段已记录的分析，交叉核对结论、证据与限制并标明对应文件页。请在约 800 字内回答。",
                                material: material, session: session, workspace: workspace, generation: generation, model: pinnedModel)
                            reduced.append(answer)
                        }
                        notes = reduced
                    }
                }
                try check()
                pdfRequestStatus = "已完成 \(total)/\(total) 段 · \(scopeName)。回答已按顺序保存在当前会话。"
            } catch {
                if materialRevision == revision {
                    let message = error is CancellationError ? "已停止后续处理。" : errorMessage(error)
                    pdfRequestStatus = total == 0 ? message : "已完成 \(completed)/\(total) 段。\(message)"
                    if !(error is CancellationError) { lastError = message }
                }
            }
        }
    }

    private func submitPDFTurn(question: String, material: ResearchMaterial, session: String, workspace: String,
                               generation: Int, model: ResearchModelSelection?) async throws -> String {
        try Task.checkCancellation()
        guard sessionID == session, generation == connectionGeneration else { throw DSHPetCommandError.unavailable }
        let id = "dsh-pet-\(UUID().uuidString.lowercased())"
        let store = provenanceStore
        try await Task.detached(priority: .userInitiated) {
            try store.record(session: session, requestID: id, material: material)
        }.value
        try Task.checkCancellation()
        guard sessionID == session, selectedWorkspaceID == workspace, generation == connectionGeneration else { throw DSHPetCommandError.unavailable }
        var fields: [String: Any] = ["workspaceId": workspace, "sessionId": session, "requestId": id,
            "text": question, "mode": "ask", "includeContext": true, "material": material.fields]
        if let model { fields["selection"] = model.wire }
        // Admission can outlive a socket or app restart. Reuse the existing unresolved
        // request guard, so a lost acknowledgment cannot silently duplicate a segment.
        pendingRequestID = id
        pendingRequestText = question
        pendingRequestSignature = "pdf:" + id
        defaults.set(id, forKey: Keys.requestID)
        defaults.set(question, forKey: Keys.requestText)
        defaults.set(pendingRequestSignature, forKey: Keys.requestSignature)
        promptMayHaveBeenSent = true
        do {
            let response = try await request(action: "researchPrompt", fields: fields, timeout: 32, expectedGeneration: generation)
            guard response["accepted"] as? Bool == true else { throw DSHPetCommandError.malformed }
            invalidatePendingSubmission()
        } catch DSHPetCommandError.server(let code, let message) {
            invalidatePendingSubmission()
            throw DSHPetCommandError.server(code: code, message: message)
        } catch {
            submissionStatus = .unconfirmed
            throw ResearchMaterialError.message("本段发送状态未确认；请核对当前会话后再继续。")
        }
        let timeout = ContinuousClock.now.advanced(by: .seconds(600))
        while ContinuousClock.now < timeout {
            try Task.checkCancellation()
            guard sessionID == session, connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
            await refreshConversation(generation: generation)
            try Task.checkCancellation()
            if !conversationRunning {
                if let error = conversationError { throw ResearchMaterialError.message("本段已提交，未能确认完整回答：\(error)") }
                if let answer = conversationMessages.last(where: { $0.role == "assistant" && $0.reply?.requestId == id }),
                   !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return answer.text }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ResearchMaterialError.message("本段已提交，等待完整回答超时；请在会话核对。")
    }

    private func modelKey(target: String?, workspace: String?, session: String?) -> String? {
        guard let target, let workspace else { return nil }
        let fields = [target, workspace] + (session.map { [$0] } ?? [])
        guard let encoded = try? JSONEncoder().encode(fields) else { return nil }
        return "research.translation.model." + encoded.base64EncodedString()
    }

    private func modelForTurn(translation: Bool) throws -> ResearchModelSelection? {
        if translation {
            guard modelSelectionAvailable, let catalog = modelCatalog else {
                throw ResearchMaterialError.message(modelCatalogError ?? "尚未取得账号模型目录，本次翻译未发送。")
            }
            func stored(_ session: String?) -> ResearchModelSelection? {
                guard let key = modelKey(target: targetBindingKey, workspace: selectedWorkspaceID, session: session),
                      let data = defaults.data(forKey: key) else { return nil }
                return try? JSONDecoder().decode(ResearchModelSelection.self, from: data)
            }
            return try catalog.translation(current: sessionID == nil ? nil : conversationSelection,
                explicit: sessionID.flatMap { stored($0) }, preferred: stored(nil),
                hasHistory: sessionID != nil && !conversationMessages.isEmpty)
        }
        if modelSelectionAvailable, selectedResearchModel == nil {
            throw ResearchMaterialError.message("正在读取当前会话模型。请等模型显示后再发送。")
        }
        return modelSelectionAvailable ? selectedResearchModel : nil
    }

    private func selectOnBridge(_ selection: ResearchModelSelection, session: String, workspace: String,
                                generation: Int) async throws -> ResearchModelSelection {
        let response = try await request(action: "researchSelectModel", fields: [
            "workspaceId": workspace, "sessionId": session, "selection": selection.wire,
        ], timeout: 22, expectedGeneration: generation)
        guard connectionGeneration == generation, sessionID == session, selectedWorkspaceID == workspace else {
            throw DSHPetCommandError.unavailable
        }
        guard let selected = ResearchProtocol.decode(ResearchModelSelection.self, from: response["selected"]),
              selected.provider == selection.provider, selected.model == selection.model,
              selection.reasoningEffort == nil || selection.reasoningEffort == selected.reasoningEffort else {
            throw DSHPetCommandError.malformed
        }
        modelSelectionRevision &+= 1
        conversationSelection = selected
        return selected
    }

    private func bindTranslation(_ selection: ResearchModelSelection, session: String, workspace: String,
                                 generation: Int) async throws -> ResearchModelSelection {
        // The bridge checks this exact tuple again when admitting the prompt and at the model step.
        if selection == conversationSelection { return selection }
        // A just-restored session can have durable history before the first UI poll completes.
        let state = try await request(action: "conversation", fields: ["workspaceId": workspace, "sessionId": session],
                                      timeout: 12, expectedGeneration: generation)
        guard self.sessionID == session, selectedWorkspaceID == workspace, connectionGeneration == generation,
              let messages = state["messages"] as? [[String: Any]] else { throw DSHPetCommandError.unavailable }
        let actual = ResearchProtocol.decode(ResearchModelSelection.self, from: state["selection"])
        if selection == actual { return selection }
        guard messages.isEmpty else {
            throw ResearchMaterialError.message("已有会话的模型已变更，请在会话模型菜单确认翻译模型后再发送。")
        }
        return try await selectOnBridge(selection, session: session, workspace: workspace, generation: generation)
    }

    private var catalogFetch: (generation: Int, task: Task<ResearchModelCatalog, Error>)?

    @discardableResult private func fetchCatalog(_ generation: Int) async throws -> ResearchModelCatalog {
        if let fetch = catalogFetch, fetch.generation == generation { return try await fetch.task.value }
        modelCatalogLoading = true
        modelCatalogError = nil
        let task = Task { @MainActor in
            let response = try await request(action: "modelCatalog", timeout: 20, expectedGeneration: generation)
            guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
            guard let catalog = ResearchProtocol.decode(ResearchModelCatalog.self, from: response["catalog"]) else {
                throw DSHPetCommandError.malformed
            }
            return catalog
        }
        catalogFetch = (generation, task)
        defer { if connectionGeneration == generation { catalogFetch = nil; modelCatalogLoading = false } }
        do {
            let catalog = try await task.value
            guard connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
            modelCatalog = catalog
            return catalog
        } catch {
            if connectionGeneration == generation { modelCatalog = nil; modelCatalogError = errorMessage(error) }
            throw error
        }
    }

    func refreshModelCatalog() {
        guard modelSelectionAvailable, !modelCatalogLoading, connection == .connected else { return }
        let generation = connectionGeneration
        Task { @MainActor in _ = try? await fetchCatalog(generation) }
    }

    func selectResearchModel(_ selection: ResearchModelSelection) {
        guard canSelectResearchModel, modelCatalog?.model(for: selection) != nil else { return }
        let generation = connectionGeneration
        modelSwitching = true
        modelSwitchError = nil
        modelSelectionRevision &+= 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if connectionGeneration == generation {
                    modelSelectionRevision &+= 1
                    modelSwitching = false
                    refreshResearch()
                }
            }
            do {
                let target = try await ensureSession(expectedGeneration: generation)
                let workspace = try requireWorkspaceID()
                let selected = try await selectOnBridge(selection, session: target, workspace: workspace, generation: generation)
                if let data = try? JSONEncoder().encode(selected) {
                    let scopes: [String?] = selected.isSubscription ? [target, nil] : [target]
                    for scope in scopes {
                        if let key = modelKey(target: targetBindingKey, workspace: workspace, session: scope) {
                            defaults.set(data, forKey: key)
                        }
                    }
                }
            } catch {
                guard connectionGeneration == generation else { return }
                modelSwitchError = errorMessage(error)
            }
        }
    }

    private func receiveResearchStream(_ value: Any?) {
        guard let stream = value as? [String: Any], let revision = stream["revision"] as? Int,
              revision > streamRevision || (revision == streamRevision && stream["message"] is NSNull) else { return }
        streamRevision = revision
        let current = ResearchProtocol.decodeStreamMessage(stream["message"])
        if conversationStream != current { conversationStream = current }
        if current != nil, stream["settled"] as? Bool != true, !conversationRunning { conversationRunning = true }
    }

    func beginResearchPolling() {
        guard researchPollingTask == nil else { return }
        if modelCatalog == nil { refreshModelCatalog() }
        // An explicit open needs one initial history load even when Finder
        // retains focus. Only recurring polling depends on window activity.
        refreshResearch()
        researchPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, self.researchWindowForeground {
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    var due: ResearchRefresh = []
                    if timestamp - self.lastConversationRead >= (self.conversationRunning ? 5 : 12),
                       timestamp - self.lastStreamUpdate >= 5 { due.insert(.conversation) }
                    if !due.isEmpty { await self.refreshResearchState(due, enqueueIfBusy: false) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopResearchPolling() {
        flushDraftPersistence()
        researchPollingTask?.cancel()
        researchPollingTask = nil
    }

    func setResearchWindowForeground(_ foreground: Bool) {
        guard researchWindowForeground != foreground else { return }
        researchWindowForeground = foreground
        if foreground { refreshResearch() }
        else { flushDraftPersistence() }
    }

    func refreshResearch() {
        refreshResearch(.all)
    }

    private func refreshResearch(_ kind: ResearchRefresh) {
        Task { @MainActor [weak self] in await self?.refreshResearchState(kind) }
    }

    private func attachmentKey(session: String?) -> String? {
        guard let workspace = selectedWorkspaceID else { return nil }
        return ResearchFileAttachment.key(host: targetBindingKey ?? "", workspace: workspace, session: session)
    }

    private func resetCurrentFile(clearSelection: Bool = true) {
        if clearSelection { removeResearchSelection() }
        beginMaterialSource(.none)
        attachment = nil
        fixedMaterial = nil
        associatedPDFName = nil
        fixedMaterialURL = nil
        fixedStamp = nil
        restoredAttachmentKey = nil
    }

    private func restoreCurrentFileIfNeeded() {
        guard let key = attachmentKey(session: sessionID), key != restoredAttachmentKey else { return }
        restoredAttachmentKey = key
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let saved = try JSONDecoder().decode(ResearchFileAttachment.self, from: data)
            loadSessionFile(URL(fileURLWithPath: saved.file.originalPath), recognizeScans: saved.recognizeScans, restoring: saved)
        } catch {
            beginMaterialSource(.fixedFile)
            materialError = "已关联文件的信息无法读取。请选择文件或移除这份关联。"
        }
    }

    var hasAssociatedFile: Bool { attachment != nil || materialSource == .fixedFile || fixedMaterial != nil }

    var displayedResearchMaterial: ResearchMaterial? {
        if let appMaterial { return appMaterial }
        if hasAssociatedFile { return fixedMaterial }
        switch materialSource {
        case .none: return nil
        case .appSelection: return appMaterial
        case .fixedFile: return fixedMaterial
        case .zotero:
            guard let paperContext, paperContext.available, paperContext.hasText else { return nil }
            return ResearchMaterial(source: "Zotero", title: paperContext.title, text: paperContext.text,
                scope: paperContext.scope ?? "Zotero 提供的摘录", page: paperContext.pageLabel)
        }
    }

    var hasSendableResearchMaterial: Bool {
        guard let material = displayedResearchMaterial else { return false }
        if let index = material.pdfIndex { return materialTransportAvailable && index.hasReadableContent }
        guard !material.text.isEmpty, material.text.utf16.count <= ResearchMaterial.maximumLength else { return false }
        return appMaterial == nil && materialSource == .zotero ? !(paperContext?.key?.isEmpty ?? true) : materialTransportAvailable
    }

    var canUseResearchMaterial: Bool { readyForMaterialRequest && hasSendableResearchMaterial && !capturingSelection }

    var canUseAssociatedFile: Bool {
        readyForMaterialRequest && materialTransportAvailable && (fixedMaterial?.pdfIndex?.hasReadableContent ?? (fixedMaterial?.text.isEmpty == false))
    }

    private var readyForMaterialRequest: Bool {
        researchAvailable && !retirementInProgress && includePaperContext && !hasPendingSubmission
            && !choosingResearchFile && !loadingResearchFile && !pdfRequestRunning && !modelSwitching
            && submissionStatus != .submitting && !conversationRunning && sessionSnapshot?.taskRunning != true
    }

    func noteMaterialMessage(_ message: String) {
        materialError = message
    }

    private func beginMaterialSource(_ source: ResearchMaterialSource) {
        materialRevision &+= 1
        pdfTask?.cancel()
        pdfRequestStatus = nil
        materialReadTask?.cancel()
        materialReadTask = nil
        loadingResearchFile = false
        materialSource = source
        materialError = nil
        contextError = nil
        paperContext = nil
    }

    struct SelectionRequest {
        let id = UUID()
        let revision: Int
        let connection: Int
        let session: Int
        let previewOnly: Bool
    }

    func beginSelectionTranslation(previewOnly: Bool = false) -> SelectionRequest? {
        removeResearchSelection()
        guard !pdfRequestRunning, !choosingResearchFile, previewOnly || !loadingResearchFile else {
            selectionError = "正在选择或处理文件，请稍后重试取词。"
            return nil
        }
        capturingSelection = true
        return SelectionRequest(revision: captureRevision, connection: connectionGeneration, session: sessionBindingGeneration, previewOnly: previewOnly)
    }

    func finishSelectionTranslation(_ request: SelectionRequest, result: Result<ResearchMaterial, Error>) {
        guard request.revision == captureRevision else { return }
        guard request.previewOnly || request.connection == connectionGeneration, request.session == sessionBindingGeneration else {
            rejectResearchSelection("科研工作区或会话已切换，请重新翻译选区。")
            return
        }
        switch result {
        case .failure(let error):
            rejectResearchSelection(error.localizedDescription)
        case .success(let material):
            guard material.selectionIsComplete else { rejectResearchSelection(SelectionCaptureError.tooLarge.localizedDescription); return }
            // Consuming this request prevents replay by delayed callbacks.
            removeResearchSelection()
            appMaterial = material
            if request.previewOnly { includePaperContext = true; return }
            guard material.text.utf16.count <= ResearchMaterial.maximumLength else {
                selectionError = ResearchMaterial.oversizeMessage
                return
            }
            guard connection == .connected, capabilitiesAvailable, researchAvailable, materialTransportAvailable else {
                selectionError = "科研桥尚未连接或不支持选区翻译。重新连接后请再次触发。"
                return
            }
            guard !hasPendingSubmission, submissionStatus != .submitting, !conversationRunning,
                  sessionSnapshot?.taskRunning != true, !modelSwitching, !pdfRequestRunning else {
                selectionError = "会话正忙或有待核对的请求，本次选区尚未发送。"
                return
            }
            if modelSelectionAvailable, modelCatalog == nil {
                let revision = captureRevision
                Task { @MainActor in
                    do {
                        let catalog = try await fetchCatalog(request.connection)
                        guard captureRevision == revision, sessionBindingGeneration == request.session,
                              connectionGeneration == request.connection else { return }
                        modelCatalog = catalog
                        submitPreparedDraft(selection: (request.id, material))
                    } catch {
                        if captureRevision == revision { selectionError = error.localizedDescription }
                    }
                }
            } else {
                submitPreparedDraft(selection: (request.id, material))
            }
        }
    }

    func acceptResearchServiceSelection(_ material: ResearchMaterial, from application: NSRunningApplication?) {
        removeResearchSelection()
        includePaperContext = true
        appMaterial = material
        guard ResearchSelectionCapture.accessibilityAvailable,
              let application, let target = ResearchSelectionCapture.target(application) else { return }
        let revision = captureRevision
        let worker = Task.detached(priority: .userInitiated) { try ResearchSelectionCapture.read(target) }
        selectionReadTask = Task { @MainActor [weak self] in
            let capture = await withTaskCancellationHandler {
                try? await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.captureRevision == revision else { return }
            selectionReadTask = nil
            if let capture, let enriched = material.withLocator(from: capture) { appMaterial = enriched }
        }
    }

    func removeResearchSelection() {
        capturingSelection = false
        captureRevision &+= 1
        selectionReadTask?.cancel()
        selectionReadTask = nil
        appMaterial = nil
        selectionError = nil
    }

    func rejectResearchSelection(_ message: String) {
        removeResearchSelection()
        selectionError = message
    }

    func clearTransientResearchMaterialOnClose() {
        removeResearchSelection()
        if materialSource == .zotero { beginMaterialSource(.zotero) }
    }

    func removeResearchFile() {
        if let key = attachmentKey(session: sessionID) { defaults.removeObject(forKey: key) }
        resetCurrentFile(clearSelection: false)
    }

    func removeResearchMaterial() {
        if hasAssociatedFile { removeResearchFile() } else { removeResearchSelection() }
    }

    func openAssociatedFile() {
        guard let reference = fixedMaterial?.fileReference else { return }
        let generation = sessionBindingGeneration
        let revision = materialRevision
        Task { @MainActor [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) { reference.resolve() }.value
            guard let self, generation == sessionBindingGeneration, revision == materialRevision,
                  fixedMaterial?.fileReference == reference else { return }
            guard let resolved else {
                materialError = "原文件已移走、变更或无法读取，请重新选择文件。"
                return
            }
            do { _ = try await NSWorkspace.shared.open(resolved, configuration: .init()) }
            catch {
                if generation == sessionBindingGeneration, revision == materialRevision {
                    materialError = "无法打开原文件：" + error.localizedDescription
                }
            }
        }
    }

    func recognizePDFScans() {
        guard let url = fixedMaterialURL, fixedMaterial?.pdfIndex?.canRequestOCR == true,
              !loadingResearchFile, !pdfRequestRunning, !retirementInProgress else { return }
        loadFixedMaterial(url, recognizeScans: true)
    }

    func loadFixedMaterial(_ url: URL, recognizeScans: Bool = false) {
        guard !pdfRequestRunning, !retirementInProgress else { return }
        loadSessionFile(url, recognizeScans: recognizeScans, restoring: nil)
    }

    private func loadSessionFile(_ url: URL, recognizeScans: Bool, restoring: ResearchFileAttachment?) {
        beginMaterialSource(.fixedFile)
        loadingResearchFile = true
        associatedPDFName = url.pathExtension.lowercased() == "pdf" ? url.lastPathComponent : nil
        fixedMaterial = nil
        fixedMaterialURL = nil
        fixedStamp = nil
        attachment = restoring
        if restoring == nil, let key = attachmentKey(session: sessionID) {
            defaults.removeObject(forKey: key)
        }
        materialError = "正在读取「\(url.lastPathComponent)」…"
        let revision = materialRevision
        let progress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, materialRevision == revision, loadingResearchFile else { return }
                materialError = message
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            // Follow a moved file only if its saved content matches. A changed file
            // at its original location gets a fresh index; past answers keep theirs.
            let resolved = restoring?.file.resolve() ?? url
            let stamp = try ResearchFileReference.fileStamp(resolved)
            let material = try ResearchFileMaterial.load(resolved, recognizeScans: recognizeScans, progress: progress)
            guard try ResearchFileReference.fileStamp(resolved) == stamp, let reference = material.fileReference else {
                throw ResearchMaterialError.message("读取时文件已发生变化，请重新选择。")
            }
            return (resolved, material, reference, stamp)
        }
        materialReadTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, materialRevision == revision, !Task.isCancelled else { return }
            materialReadTask = nil
            loadingResearchFile = false
            switch result {
            case .success(let (resolved, material, reference, stamp)):
                fixedMaterial = material
                fixedMaterialURL = resolved
                fixedStamp = stamp
                let saved = ResearchFileAttachment(file: reference, recognizeScans: recognizeScans)
                attachment = saved
                if let key = attachmentKey(session: sessionID), let encoded = try? JSONEncoder().encode(saved) {
                    defaults.set(encoded, forKey: key)
                    restoredAttachmentKey = key
                }
                if restoring == nil { includePaperContext = true }
                materialError = restoring.map { $0.file.fingerprint != reference.fingerprint } == true
                    ? "原文件已更新，现已读取新版本；已有回答仍保留当时的摘录。" : nil
            case .failure(let error):
                materialError = "无法读取「\(url.lastPathComponent)」：\(error.localizedDescription) 请重新选择可用文件或移除材料。"
            }
        }
    }

    func beginResearchFileChoice() -> Bool {
        guard !choosingResearchFile, !pdfRequestRunning, !retirementInProgress else { return false }
        choosingResearchFile = true
        fileChoiceBinding = sessionBindingGeneration
        return true
    }

    func finishResearchFileChoice(_ url: URL?) {
        guard choosingResearchFile else { return }
        choosingResearchFile = false
        defer { fileChoiceBinding = nil }
        guard fileChoiceBinding == sessionBindingGeneration else { return }
        if let url { loadFixedMaterial(url) }
    }
    private func refreshResearchState(_ kind: ResearchRefresh = .all, enqueueIfBusy: Bool = true) async {
        guard researchAvailable, connection == .connected, capabilitiesValidated, !Task.isCancelled else { return }
        if researchRefreshInFlight {
            if enqueueIfBusy { researchRefreshQueued.formUnion(kind) }
            return
        }
        researchRefreshInFlight = true
        defer {
            researchRefreshInFlight = false
            if !researchRefreshQueued.isEmpty {
                let queued = researchRefreshQueued
                researchRefreshQueued = []
                refreshResearch(queued)
            }
        }
        let generation = connectionGeneration
        if kind.contains(.conversation) { await refreshConversation(generation: generation) }
        if kind.contains(.material), !Task.isCancelled, connectionGeneration == generation, materialSource == .zotero {
            await refreshPaperContext(generation: generation)
        }
    }

    private func refreshPaperContext(generation: Int) async {
        let revision = materialRevision
        do {
            let response = try await request(action: "researchContext", timeout: 6, expectedGeneration: generation)
            guard connectionGeneration == generation, !Task.isCancelled,
                  materialSource == .zotero, materialRevision == revision else { return }
            let context = try ResearchProtocol.decodeContext(response["context"])
            let error = context?.error ?? response["error"] as? String
            if paperContext != context { paperContext = context }
            if contextError != error { contextError = error }
        } catch {
            guard connectionGeneration == generation, !Task.isCancelled,
                  materialSource == .zotero, materialRevision == revision else { return }
            if paperContext != nil { paperContext = nil }
            let message = errorMessage(error)
            if contextError != message { contextError = message }
        }
    }

    private func refreshConversation(generation: Int) async {
        lastConversationRead = ProcessInfo.processInfo.systemUptime
        guard let session = sessionID, let workspace = selectedWorkspaceID else { return }
        let modelRevision = modelSelectionRevision
        let binding = sessionBindingGeneration
        var fields = ["workspaceId": workspace, "sessionId": session]
        if let wireHistoryRevision { fields["knownHistory"] = wireHistoryRevision }
        do {
            let response = try await request(action: "conversation", fields: fields,
                timeout: 8, expectedGeneration: generation)
            guard connectionGeneration == generation, sessionID == session,
                  selectedWorkspaceID == workspace, sessionBindingGeneration == binding, !Task.isCancelled else { return }
            let returnedRevision = response["historyRevision"] as? String
            if response["historyUnchanged"] as? Bool == true {
                guard let returnedRevision, returnedRevision == wireHistoryRevision else {
                    throw DSHPetCommandError.malformed
                }
            } else {
                let messages = try ResearchProtocol.decodeMessages(response["messages"])
                if conversationMessages != messages { conversationMessages = messages }
                wireHistoryRevision = returnedRevision
            }
            let model = response["model"] as? String
            let running = response["running"] as? Bool ?? false
            let error = response["error"] as? String
            if conversationModel != model { conversationModel = model }
            if conversationRunning != running { conversationRunning = running }
            if conversationError != error { conversationError = error }
            if !modelSwitching, modelSelectionRevision == modelRevision {
                let selection = ResearchProtocol.decode(ResearchModelSelection.self, from: response["selection"])
                if conversationSelection != selection { conversationSelection = selection }
            }
            receiveResearchStream(response["stream"])
        } catch {
            guard connectionGeneration == generation, sessionID == session,
                  sessionBindingGeneration == binding, !Task.isCancelled else { return }
            let message = errorMessage(error)
            if conversationError != message { conversationError = message }
        }
    }

    private func ensureSession(expectedGeneration: Int) async throws -> String {
        guard connectionGeneration == expectedGeneration else { throw DSHPetCommandError.unavailable }
        let workspaceID = try requireWorkspaceID()
        if let sessionCreationTask { return try await sessionCreationTask.value }
        if let existing = sessionID {
            return try await reuseBoundSession(existing, workspaceID: workspaceID,
                expectedGeneration: expectedGeneration, bindingGeneration: sessionBindingGeneration)
        }
        let bindingGeneration = sessionBindingGeneration
        let creation = Task { @MainActor [weak self] in
            guard let self else { throw DSHPetCommandError.unavailable }
            return try await createBoundSession(workspaceID: workspaceID,
                expectedGeneration: expectedGeneration, bindingGeneration: bindingGeneration)
        }
        sessionCreationTask = creation
        defer {
            if sessionBindingGeneration == bindingGeneration { sessionCreationTask = nil }
        }
        return try await creation.value
    }

    private func createBoundSession(workspaceID: String, expectedGeneration: Int, bindingGeneration: Int) async throws -> String {
        let session: String
        if let pendingSessionID {
            // The previous createSession may have succeeded on the host even if
            // its response timed out; reuse the candidate id so the retry is
            // idempotent instead of creating an orphan Session.
            session = pendingSessionID
        } else {
            session = "dsh-pet-session-\(UUID().uuidString.lowercased())"
            pendingSessionID = session
            defaults.set(session, forKey: Keys.pendingSessionID)
        }
        let response = try await request(
            action: "createSession",
            fields: ["workspaceId": workspaceID, "sessionId": session],
            timeout: 12,
            expectedGeneration: expectedGeneration
        )
        guard connectionGeneration == expectedGeneration, sessionBindingGeneration == bindingGeneration,
              selectedWorkspaceID == workspaceID else { throw DSHPetCommandError.unavailable }
        guard let returnedSession = response["sessionId"] as? String, !returnedSession.isEmpty else {
            throw DSHPetCommandError.malformed
        }
        pendingSessionID = nil
        defaults.removeObject(forKey: Keys.pendingSessionID)
        let compositionKey = attachmentKey(session: nil)
        sessionID = returnedSession
        if let key = attachmentKey(session: returnedSession) {
            restoredAttachmentKey = key
            if let attachment, let encoded = try? JSONEncoder().encode(attachment) { defaults.set(encoded, forKey: key) }
            if let compositionKey { defaults.removeObject(forKey: compositionKey) }
        }
        defaults.set(returnedSession, forKey: Keys.sessionID)
        ResearchLaunchLog.write("session-created")
        let subscribed = try await request(
            action: "subscribe",
            fields: ["sessionId": returnedSession],
            timeout: 8,
            expectedGeneration: expectedGeneration
        )
        guard connectionGeneration == expectedGeneration, sessionBindingGeneration == bindingGeneration,
              selectedWorkspaceID == workspaceID, sessionID == returnedSession else { throw DSHPetCommandError.unavailable }
        if let snapshot = decodeSnapshot(subscribed["snapshot"]),
           snapshotMatchesSelectedInstance(snapshot) {
            sessionSnapshot = snapshot
        }
        return returnedSession
    }

    private func reuseBoundSession(_ existing: String, workspaceID: String,
        expectedGeneration: Int, bindingGeneration: Int) async throws -> String {
        let response = try await request(action: "workspaces", timeout: 8, expectedGeneration: expectedGeneration)
        guard connectionGeneration == expectedGeneration, sessionBindingGeneration == bindingGeneration,
              selectedWorkspaceID == workspaceID, sessionID == existing else { throw DSHPetCommandError.unavailable }
        let listed = decodeWorkspaces(response["workspaces"])
        guard let workspace = listed.first(where: { $0.id == workspaceID }), workspace.sessionIds.contains(existing) else {
            ResearchLaunchLog.write("session-binding-rejected")
            throw DSHPetCommandError.server(code: "session/binding-invalid",
                message: "原会话不在当前工作区，已停止发送并保留绑定。请在 DSH 检查原会话，或明确点击新建对话。")
        }
        let subscribed = try await request(action: "subscribe", fields: ["sessionId": existing],
            timeout: 8, expectedGeneration: expectedGeneration)
        guard connectionGeneration == expectedGeneration, sessionBindingGeneration == bindingGeneration,
              selectedWorkspaceID == workspaceID, sessionID == existing else { throw DSHPetCommandError.unavailable }
        if let snapshot = decodeSnapshot(subscribed["snapshot"]), snapshotMatchesSelectedInstance(snapshot) {
            if sessionSnapshot != snapshot { sessionSnapshot = snapshot }
        }
        ResearchLaunchLog.write("session-reused")
        return existing
    }

    private func requireWorkspaceID() throws -> String {
        guard let id = selectedWorkspaceID,
              workspaces.contains(where: { $0.id == id }) else {
            throw DSHPetCommandError.server(code: "workspace/not-selected", message: "请先选择工作区")
        }
        return id
    }

    private func resetResearchConversation() {
        conversationMessages = []
        wireHistoryRevision = nil
        conversationStream = nil
        streamRevision = -1
        lastStreamUpdate = -.infinity
        conversationError = nil
        conversationModel = nil
        conversationSelection = nil
        modelSwitchError = nil
        conversationRunning = false
    }

    private func clearSessionBinding() {
        sessionBindingGeneration &+= 1
        sessionCreationTask?.cancel()
        sessionCreationTask = nil
        dismissCandidates()
        sessionID = nil
        resetCurrentFile()
        restoreCurrentFileIfNeeded()
        sessionSnapshot = nil
        resetResearchConversation()
        pendingSessionID = nil
        pendingRequestID = nil
        pendingRequestText = nil
        pendingRequestSignature = nil
        promptMayHaveBeenSent = false
        defaults.removeObject(forKey: Keys.sessionID)
        defaults.removeObject(forKey: Keys.pendingSessionID)
        defaults.removeObject(forKey: Keys.requestID)
        defaults.removeObject(forKey: Keys.requestText)
        defaults.removeObject(forKey: Keys.requestSignature)
        continuationWarning = nil
    }

    private func clearTargetCaches() {
        selectedWorkspaceID = nil
        defaults.removeObject(forKey: Keys.workspaceID)
        workspaces = []
        tasks = []
        readMarkers = [:]
        defaults.removeObject(forKey: Keys.taskReadMarkers)
        hasReceivedTaskBaseline = false
        presentedActiveTaskIDs = nil
        focusedTaskID = nil
        clearSessionBinding()
        submissionStatus = .idle
        lastError = nil
        resetBubbleDeckState()
    }

    private func invalidateConnection(clearPersistedPending: Bool) {
        connectionGeneration &+= 1
        sessionBindingGeneration &+= 1
        sessionCreationTask?.cancel()
        sessionCreationTask = nil
        dismissCandidates()
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        taskPreview = nil
        taskPreviewStatus = focusedTaskID == nil ? nil : "Harness 连接已断开"
        connectionHandle?.cancel()
        connectionHandle = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        queuedPayloads.removeAll(keepingCapacity: false)
        failPending(with: DSHPetCommandError.unavailable)
        if clearPersistedPending {
            pendingRequestID = nil
            pendingRequestText = nil
            pendingRequestSignature = nil
            promptMayHaveBeenSent = false
            defaults.removeObject(forKey: Keys.requestID)
            defaults.removeObject(forKey: Keys.requestText)
            defaults.removeObject(forKey: Keys.requestSignature)
        }
        connection = .disconnected
    }

    private func resetCapabilityState() {
        capabilitiesValidated = false
        capabilitiesAvailable = false
        taskListAvailable = false
        imageAttachmentsAvailable = false
        fileCandidatesAvailable = false
        skillCandidatesAvailable = false
        taskPreviewAvailable = false
        researchAvailable = false
        onlineDeletionAvailable = false
        researchDeletionAvailable = false
        researchHistoryAvailable = false
        modelSelectionAvailable = false
        modelCatalog = nil
        modelCatalogLoading = false
        modelCatalogError = nil
        modelSwitchError = nil
        modelSwitching = false
        conversationStream = nil
        streamRevision = -1
        lastStreamUpdate = -.infinity
        modelSelectionRevision &+= 1
        materialTransportAvailable = false
        paperContext = nil
        contextError = nil
        conversationRunning = false
        imageLimits = nil
        dismissCandidates()
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        if focusedTaskID != nil {
            taskPreview = nil
            taskPreviewStatus = "Harness 连接已断开"
        }
        resetBubbleDeckState()
    }

    private func connect() {
        guard started, sourceEnabled, connectionHandle == nil else { return }
        connection = .connecting
        let generation = connectionGeneration
        let handle = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connectionHandle = handle
        handle.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionGeneration == generation,
                      self.connectionHandle === handle else { return }
                switch state {
                case .ready:
                    connection = .connected
                    resetCapabilityState()
                    refreshCapabilitiesAndWorkspaces()
                case .waiting:
                    // A Unix socket that is not available yet enters
                    // NWConnection.waiting rather than failed. Clear the
                    // handle so the retry loop can reconnect after Harness
                    // starts and creates the command socket.
                    connectionHandle = nil
                    connection = .disconnected
                    resetCapabilityState()
                    failPending(with: DSHPetCommandError.unavailable)
                    handle.cancel()
                    scheduleReconnect()
                case .failed, .cancelled:
                    connectionHandle = nil
                    connection = .disconnected
                    resetCapabilityState()
                    failPending(with: DSHPetCommandError.unavailable)
                    scheduleReconnect()
                default:
                    break
                }
            }
        }
        handle.start(queue: queue)
        receiveNext(on: handle, frames: DSHPetCommandFrames())
    }

    private func receiveNext(on handle: NWConnection, frames: DSHPetCommandFrames) {
        handle.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, _ in
            let batch = frames.append(data)
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionHandle === handle else { return }
                consume(batch.objects)
                if isComplete {
                    connectionHandle = nil
                    connection = .disconnected
                    resetCapabilityState()
                    failPending(with: DSHPetCommandError.unavailable)
                    scheduleReconnect()
                } else if connectionHandle != nil {
                    receiveNext(on: handle, frames: frames)
                }
            }
        }
    }

    private func consume(_ objects: [[String: Any]]) {
        for object in objects {
            if object["event"] as? String == "status" {
                if let sessionID = object["sessionId"] as? String,
                   sessionID == self.sessionID,
                   let snapshot = decodeSnapshot(object["snapshot"]),
                   snapshotMatchesSelectedInstance(snapshot) {
                    let runningChanged = sessionSnapshot?.taskRunning != snapshot.taskRunning
                    if sessionSnapshot != snapshot { sessionSnapshot = snapshot }
                    if runningChanged && researchWindowForeground { refreshResearch(.conversation) }
                }
                continue
            }
            if object["event"] as? String == "tasks" {
                applyTasks(object["tasks"])
                continue
            }
            if object["event"] as? String == "researchStream" {
                if researchWindowForeground, object["sessionId"] as? String == sessionID,
                   let state = object["state"] as? [String: Any] {
                    lastStreamUpdate = ProcessInfo.processInfo.systemUptime
                    receiveResearchStream(state)
                    if state["settled"] as? Bool == true { refreshResearch(.conversation) }
                }
                continue
            }
            if object["event"] as? String == "taskPreviewChanged" {
                if let task = focusedTask, object["sessionId"] as? String == task.sessionID {
                    refreshTaskPreview(task)
                }
                continue
            }
            guard let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
            if let ok = object["ok"] as? Bool, !ok {
                let error = object["error"] as? [String: Any]
                continuation(.failure(DSHPetCommandError.server(
                    code: error?["code"] as? String ?? "command-failed",
                    message: error?["message"] as? String ?? "Research Companion 桥接插件拒绝了请求"
                )))
            } else {
                continuation(.success(object))
            }
        }
    }

    private func request(
        action: String,
        fields: [String: Any] = [:],
        timeout: TimeInterval = 8,
        expectedGeneration: Int? = nil
    ) async throws -> [String: Any] {
        guard started else { throw DSHPetCommandError.unavailable }
        if let expectedGeneration, expectedGeneration != connectionGeneration {
            throw DSHPetCommandError.unavailable
        }
        if action != "capabilities" && !capabilitiesValidated {
            throw DSHPetCommandError.unavailable
        }
        connect()
        let requestGeneration = connectionGeneration
        let id = UUID().uuidString.lowercased()
        var object: [String: Any] = ["id": id, "action": action]
        for (key, value) in fields { object[key] = value }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { result in continuation.resume(with: result) }
            queuedPayloads.append((id: id, data: data))
            if connection == .connected { flushQueuedPayloads() }
            Task { @MainActor [weak self] in
                let delay = UInt64(max(0.5, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.connectionGeneration == requestGeneration else { return }
                self.timeOut(id)
            }
        }
    }

    private func refreshCapabilitiesAndWorkspaces() {
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                ResearchLaunchLog.write("capabilities-requested")
                let response = try await request(
                    action: "capabilities",
                    timeout: 5,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation else { return }
                guard response["protocolVersion"] as? Int == 1,
                      response["commandSocket"] as? Bool == true,
                      validateCapabilitiesInstance(response["instance"]) else {
                    throw DSHPetCommandError.malformed
                }
                capabilitiesValidated = true
                capabilitiesAvailable = true
                ResearchLaunchLog.write("capabilities-validated")
                // A handshake on the new connection supersedes the previous
                // transport error; otherwise the composer keeps showing
                // "unavailable" after a successful reconnect.
                lastError = nil
                let supports = response["supports"] as? [String] ?? []
                taskListAvailable = supports.contains("tasks") && supports.contains("subscribeTasks")
                imageAttachmentsAvailable = supports.contains("imageAttachments")
                fileCandidatesAvailable = supports.contains("fileCandidates")
                skillCandidatesAvailable = supports.contains("skillCandidates")
                taskPreviewAvailable = supports.contains("taskPreview")
                researchAvailable = ["conversation", "researchContext", "researchPrompt"].allSatisfy(supports.contains)
                onlineDeletionAvailable = supports.contains("research.retirement.online.v1")
                researchDeletionAvailable = supports.contains("research.retirement.offline.v1") && targetInstance?.kind == .desktop
                researchHistoryAvailable = supports.contains("researchHistory")
                modelSelectionAvailable = ["modelCatalog", "researchSelectModel"].allSatisfy(supports.contains)
                if researchPollingTask != nil { refreshModelCatalog() }
                materialTransportAvailable = supports.contains("researchMaterial")
                imageLimits = decodeImageLimits(response["attachmentLimits"])
                if taskListAvailable {
                    subscribeTasks(expectedGeneration: generation)
                } else {
                    tasks = []
                    refreshBubbleDeck()
                }
                if let sessionID { subscribe(to: sessionID, expectedGeneration: generation) }
                refreshWorkspaces(expectedGeneration: generation)
                if researchPollingTask != nil { refreshResearch() }
                if let task = focusedTask { refreshTaskPreview(task) }
            } catch {
                guard self.connectionGeneration == generation else { return }
                capabilitiesAvailable = false
                researchDeletionAvailable = false
                researchHistoryAvailable = false
                taskListAvailable = false
                imageAttachmentsAvailable = false
                imageLimits = nil
                resetBubbleDeckState()
                record(error)
            }
        }
    }

    private func flushQueuedPayloads() {
        guard let connectionHandle, connection == .connected else { return }
        let payloads = queuedPayloads
        queuedPayloads.removeAll(keepingCapacity: true)
        for payload in payloads {
            connectionHandle.send(content: payload.data + Data([10]), completion: .contentProcessed { _ in })
        }
    }

    private func timeOut(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        queuedPayloads.removeAll { $0.id == id }
        continuation(.failure(DSHPetCommandError.timedOut))
    }

    private func scheduleReconnect() {
        guard started, reconnectTask == nil else { return }
        let generation = connectionGeneration
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.started,
                  self.connectionGeneration == generation else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func failPending(with error: Error) {
        queuedPayloads.removeAll(keepingCapacity: false)
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation(.failure(error)) }
    }

    private func record(_ error: Error) {
        lastError = errorMessage(error)
        switch error {
        case DSHPetCommandError.unavailable: ResearchLaunchLog.write("command-unavailable")
        case DSHPetCommandError.timedOut: ResearchLaunchLog.write("command-timeout")
        case DSHPetCommandError.malformed: ResearchLaunchLog.write("command-malformed")
        case DSHPetCommandError.server: ResearchLaunchLog.write("command-server-rejected")
        default: ResearchLaunchLog.write("command-other-error")
        }
        // An unavailable operation is not evidence that the NWConnection
        // disconnected. Only its transport callbacks may change that state.
        if case DSHPetCommandError.unavailable = error, connectionHandle == nil { connection = .disconnected }
    }

    private func decodeWorkspaces(_ value: Any?) -> [DSHPetWorkspace] {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([DSHPetWorkspace].self, from: data) else { return [] }
        return decoded
    }

    private func decodeSnapshot(_ value: Any?) -> MoodBridgeSnapshot? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MoodBridgeSnapshot.self, from: data)
    }

    private func snapshotMatchesSelectedInstance(_ snapshot: MoodBridgeSnapshot) -> Bool {
        guard let expectedInstanceID else { return false }
        return snapshot.instanceId == expectedInstanceID
    }

    private func validateCapabilitiesInstance(_ value: Any?) -> Bool {
        guard let targetInstance else { return false }
        guard let descriptor = value as? [String: Any],
              descriptor["instanceId"] as? String == targetInstance.instanceId,
              descriptor["statusSocketPath"] as? String == targetInstance.statusSocketPath,
              descriptor["commandSocketPath"] as? String == targetInstance.commandSocketPath else {
            lastError = "Harness 来源身份校验失败，已停止发送"
            return false
        }
        return true
    }

    private func decodeImageLimits(_ value: Any?) -> DSHPetImageLimits? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(DSHPetImageLimits.self, from: data)
    }

    private func addDraftImage(data: Data, mediaType: String, name: String) {
        do {
            let directory = try draftImageDirectory()
            let url = directory.appendingPathComponent("draft-\(UUID().uuidString.lowercased()).png")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            addDraftImageFile(url: url, data: data, mediaType: mediaType, name: name)
        } catch {
            lastError = errorMessage(error)
        }
    }

    private func addDraftImageFile(url: URL, data: Data, mediaType: String, name: String) {
        if let limits = imageLimits {
            guard draftImages.count < limits.maxImagesPerMessage else {
                try? FileManager.default.removeItem(at: url)
                lastError = "图片数量超过 Harness 限制（最多 \(limits.maxImagesPerMessage) 张）"
                return
            }
            guard data.count <= limits.maxImageBytes else {
                try? FileManager.default.removeItem(at: url)
                lastError = "图片超过 Harness 单张大小限制（\(Self.byteLabel(limits.maxImageBytes))）"
                return
            }
            guard draftImages.reduce(0, { $0 + $1.bytes }) + data.count <= limits.maxMessageImageBytes else {
                try? FileManager.default.removeItem(at: url)
                lastError = "图片总大小超过 Harness 限制（\(Self.byteLabel(limits.maxMessageImageBytes))）"
                return
            }
        }
        draftImages.append(DSHPetDraftImage(
            id: UUID().uuidString.lowercased(),
            path: url.path,
            mediaType: mediaType,
            name: name,
            bytes: data.count,
            error: nil
        ))
        invalidatePendingSubmission()
        persistDraftImages()
        lastError = nil
    }

    private func encodedDraftImages(_ images: [DSHPetDraftImage]) throws -> [[String: Any]] {
        try images.map { image in
            let data = try Data(contentsOf: image.fileURL, options: [.mappedIfSafe])
            return [
                "id": image.id,
                "mediaType": image.mediaType,
                "name": image.name,
                "data": data.base64EncodedString(),
            ]
        }
    }

    private func draftImageDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Research Companion/PrivateDraftImages", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func clearDraftImages(ids: Set<String>) {
        for image in draftImages where ids.contains(image.id) {
            try? FileManager.default.removeItem(at: image.fileURL)
        }
        draftImages.removeAll { ids.contains($0.id) }
        persistDraftImages()
    }

    private func persistDraftImages() {
        if let data = try? JSONEncoder().encode(draftImages) {
            defaults.set(data, forKey: Keys.draftImages)
        }
    }

    private func invalidatePendingSubmission() {
        pendingRequestID = nil
        pendingRequestText = nil
        pendingRequestSignature = nil
        promptMayHaveBeenSent = false
        defaults.removeObject(forKey: Keys.requestID)
        defaults.removeObject(forKey: Keys.requestText)
        defaults.removeObject(forKey: Keys.requestSignature)
    }

    private func submissionSignature(text: String) -> String {
        ([text] + draftImages.map { "\($0.id):\($0.bytes)" }).joined(separator: "|")
    }

    private static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func subscribeTasks(expectedGeneration: Int? = nil) {
        let generation = expectedGeneration ?? connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(
                    action: "subscribeTasks",
                    timeout: 12,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation else { return }
                applyTasks(response["tasks"])
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    private func subscribe(to sessionID: String, expectedGeneration: Int? = nil) {
        let generation = expectedGeneration ?? connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(
                    action: "subscribe",
                    fields: ["sessionId": sessionID],
                    timeout: 8,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation,
                      self.sessionID == sessionID else { return }
                if let snapshot = decodeSnapshot(response["snapshot"]),
                   snapshotMatchesSelectedInstance(snapshot) {
                    self.sessionSnapshot = snapshot
                }
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    private func applyTasks(_ value: Any?) {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([DSHPetTaskSummary].self, from: data) else { return }

        if !hasReceivedTaskBaseline {
            // The first baseline is historical context, not a burst of unread
            // reminders. Retain existing markers so a result that arrived while
            // the App was closed can still be recognized after reconnect.
            for task in decoded where readMarkers[task.id] == nil {
                readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
            }
            hasReceivedTaskBaseline = true
            persistReadMarkers()
        }
        applyTaskSummaries(decoded)
    }

    /// Task-card history and the pet's live animation are separate state
    /// channels. In particular, a retained done/failed card must never replace
    /// the live Session snapshot merely because the card list refreshed.
    func applyTaskSummaries(_ decoded: [DSHPetTaskSummary], establishesBaseline: Bool = false) {
        if establishesBaseline {
            for task in decoded {
                readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
            }
            hasReceivedTaskBaseline = true
            persistReadMarkers()
        }
        let previousFocused = focusedTask
        let current = now()
        observeTaskTransitions(decoded, now: current)
        tasks = decoded
        pruneReadMarkers(now: current)
        rebuildBubbleDeck(now: current)
        if let previousFocused,
           let currentFocused = focusedTask,
           previousFocused.taskRunning && !currentFocused.taskRunning {
            refreshTaskPreview(currentFocused, retryEmpty: true)
        }
    }

    func isTaskUnread(_ task: DSHPetTaskSummary) -> Bool {
        guard hasReceivedTaskBaseline else { return false }
        guard let marker = readMarkers[task.id] else { return true }
        return marker.updatedAt != task.updatedAt || marker.mood != task.mood
    }

    private func markTaskRead(_ task: DSHPetTaskSummary) {
        if presentedActiveTaskIDs != nil, isTaskActive(task) {
            presentedActiveTaskIDs?.insert(task.id)
        }
        readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
        persistReadMarkers()
        rebuildBubbleDeck(now: now())
    }

    private func pruneReadMarkers(now: TimeInterval) {
        let activeSessionIDs = Set(tasks.map(\.id))
        let cutoff = (now - Self.readMarkerRetention) * 1_000
        let retained = readMarkers.filter { sessionID, marker in
            activeSessionIDs.contains(sessionID) || marker.updatedAt >= cutoff
        }
        guard retained.count != readMarkers.count else { return }
        readMarkers = retained
        persistReadMarkers()
    }

    private func persistReadMarkers() {
        guard let data = try? JSONEncoder().encode(readMarkers) else { return }
        defaults.set(data, forKey: Keys.taskReadMarkers)
    }

    /// Rebuild the presentation deck from the current task list. Exposed to the
    /// hold timer (and tests) because terminal results expire without another
    /// Harness event arriving.
    func refreshBubbleDeck() {
        rebuildBubbleDeck(now: now())
    }

    private func resetBubbleDeckState() {
        bubbleHoldTask?.cancel()
        bubbleHoldTask = nil
        bubbleOrder = []
        terminalHoldUntil = [:]
        lastBubbleObservation = [:]
        if bubbleDeck != .empty { bubbleDeck = .empty }
    }

    private func observeTaskTransitions(_ decoded: [DSHPetTaskSummary], now: TimeInterval) {
        var next: [String: BubbleObservation] = [:]
        for task in decoded {
            let terminal = DSHPetBubbleDeckBuilder.isTerminal(task)
            let previous = lastBubbleObservation[task.sessionID]
            if terminal {
                let changed = previous.map {
                    !$0.terminal || $0.updatedAt != task.updatedAt || $0.mood != task.mood
                } ?? false
                if changed {
                    terminalHoldUntil[task.sessionID] = now + DSHPetBubbleDeckBuilder.holdDuration(for: task)
                }
            } else {
                terminalHoldUntil.removeValue(forKey: task.sessionID)
            }
            next[task.sessionID] = BubbleObservation(
                mood: task.mood,
                updatedAt: task.updatedAt,
                terminal: terminal
            )
        }
        lastBubbleObservation = next
        terminalHoldUntil = terminalHoldUntil.filter { next[$0.key] != nil }
    }

    private func rebuildBubbleDeck(now: TimeInterval) {
        let attention = tasks.filter { task in
            DSHPetBubbleDeckBuilder.isAttention(
                task: task,
                isUnread: isTaskUnread(task),
                holdUntil: terminalHoldUntil[task.sessionID] ?? 0,
                now: now
            )
        }
        let attentionIDs = attention.map { $0.sessionID }
        bubbleOrder = bubbleOrder.filter { attentionIDs.contains($0) }
        for id in attentionIDs where !bubbleOrder.contains(id) {
            bubbleOrder.append(id)
        }

        let inputs = bubbleOrder.compactMap { id in
            tasks.first { $0.sessionID == id }.map { task in
                DSHPetBubbleTaskInput(
                    task: task,
                    workspaceTitle: workspaceTitle(for: task),
                    isUnread: isTaskUnread(task),
                    holdUntil: terminalHoldUntil[id] ?? 0
                )
            }
        }
        let deck = DSHPetBubbleDeckBuilder.build(inputs: inputs, now: now)
        if bubbleDeck != deck { bubbleDeck = deck }
        scheduleBubbleHoldRefresh(now: now)
    }

    private func scheduleBubbleHoldRefresh(now: TimeInterval) {
        bubbleHoldTask?.cancel()
        bubbleHoldTask = nil
        let pending = terminalHoldUntil.values.filter { $0 > now }
        guard let next = pending.min() else { return }
        let delay = max(0.05, next - now)
        bubbleHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshBubbleDeck()
        }
    }

    private func taskRank(_ task: DSHPetTaskSummary) -> Int {
        if task.waitingForUser { return 0 }
        if isTaskUnread(task) && task.failed { return 1 }
        if isTaskUnread(task) && task.completed { return 2 }
        if task.taskRunning || task.running { return 3 }
        return 4
    }

    private func isTaskActive(_ task: DSHPetTaskSummary) -> Bool {
        task.waitingForUser
            || task.taskRunning
            || task.running
            || (isTaskUnread(task) && (task.completed || task.failed))
    }

    private func taskPrecedes(_ left: DSHPetTaskSummary, _ right: DSHPetTaskSummary) -> Bool {
        let leftRank = taskRank(left)
        let rightRank = taskRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        return recentTaskPrecedes(left, right)
    }

    /// Presentation membership preserves terminal cards after they are read;
    /// their visual priority must remain failure/completion instead of falling
    /// behind running work while the same panel is still open.
    private func activeTaskPrecedes(_ left: DSHPetTaskSummary, _ right: DSHPetTaskSummary) -> Bool {
        let leftRank = activeTaskRank(left)
        let rightRank = activeTaskRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        return recentTaskPrecedes(left, right)
    }

    private func activeTaskRank(_ task: DSHPetTaskSummary) -> Int {
        if task.waitingForUser { return 0 }
        if task.failed { return 1 }
        if task.completed { return 2 }
        if task.taskRunning || task.running { return 3 }
        return 4
    }

    private func recentTaskPrecedes(_ left: DSHPetTaskSummary, _ right: DSHPetTaskSummary) -> Bool {
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        let titleOrder = left.title.localizedStandardCompare(right.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return left.id < right.id
    }
}

private func errorMessage(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let message = localized.errorDescription { return message }
    return error.localizedDescription
}
