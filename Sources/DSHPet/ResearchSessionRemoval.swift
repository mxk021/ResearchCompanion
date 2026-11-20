import AppKit

struct ResearchRemovalPlan: Codable, Equatable {
    let sessionId: String
    let workspaceId: String
    let cwd: String
    let createdAt: Int64
    let ready: Bool
    let reason: String?
    let phase: String?
    var online: String? = nil

    var matchesResearchWorkspace: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["Documents/Codex/ResearchCompanionWorkspace", "Library/Application Support/Research Companion/Workspace"]
        return createdAt > 0 && paths.contains { home.appendingPathComponent($0).standardizedFileURL.path == cwd }
    }
}

enum ResearchRemovalError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

enum ResearchSessionRemoval {
    static let app = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app", isDirectory: true)
    static let helper = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/local-plugins/research-session-retirement/offline-delete.mjs")

    // The existing rc.5 offline helper itself accepts only the legacy workspace.
    static func supportsOffline(_ plan: ResearchRemovalPlan) -> Bool {
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Codex/ResearchCompanionWorkspace")
        return plan.matchesResearchWorkspace && plan.cwd == legacy.standardizedFileURL.path
            && FileManager.default.isReadableFile(atPath: helper.path)
    }

    struct Receipt: Decodable {
        let phase: String
        let sessionId: String?
        let workspaceId: String?
        let message: String?
    }

    @MainActor static func runningDesktop() throws -> NSRunningApplication? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseek.dsh")
        guard running.count <= 1, running.allSatisfy({ $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }) else {
            throw ResearchRemovalError.unavailable("发现另一份 DSH 桌面程序。请先正常退出重复运行的副本。")
        }
        return running.first
    }

    @MainActor static func quit(_ desktop: NSRunningApplication) async throws {
        guard desktop.terminate() else { throw ResearchRemovalError.unavailable("DSH 未接受退出请求，会话仍保留。") }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(40))
        while !desktop.isTerminated && clock.now < deadline { try await Task.sleep(for: .milliseconds(150)) }
        guard desktop.isTerminated else {
            throw ResearchRemovalError.unavailable("DSH 尚未正常退出。请检查其窗口中的任务或退出提示，然后重试。")
        }
    }

    @MainActor static func reopen() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    static func removeOffline(_ plan: ResearchRemovalPlan) throws -> Receipt {
        guard supportsOffline(plan) else {
            throw ResearchRemovalError.unavailable("科研目录或已安装的离线删除组件不可用。")
        }
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/DeepSeek Harness")
        process.arguments = [helper.path, "--research", plan.workspaceId, plan.sessionId, String(plan.createdAt)]
        process.environment = ["ELECTRON_RUN_AS_NODE":"1", "HOME":FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR":NSTemporaryDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.sessionId == plan.sessionId, receipt.workspaceId == plan.workspaceId,
              ["untouched", "pending", "deleted", "unknown"].contains(receipt.phase),
              receipt.phase != "deleted" || process.terminationStatus == 0
        else { throw ResearchRemovalError.unavailable("未取得可核对的删除回执。可安全重试同一会话。") }
        return receipt
    }
}
