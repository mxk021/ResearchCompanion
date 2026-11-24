import Foundation
import Darwin

/// Bounded lifecycle diagnostics only. Never log prompts, paper text, file
/// locations, model responses, tokens, or account information.
enum ResearchLaunchLog {
    static func write(_ event: String) {
        let allowed = Set(["main-entered", "delegate-launched", "panels-created", "first-panel-presented",
            "bridge-disconnected", "bridge-connecting", "bridge-connected",
            "capabilities-requested", "capabilities-validated", "command-unavailable", "command-timeout",
            "command-malformed", "command-server-rejected", "command-other-error",
            "session-created", "session-reused", "session-binding-rejected",
            "panel-opened", "panel-explicitly-closed", "app-hidden", "pet-chat-clicked",
            "selection-service-invoked", "selection-service-origin-rejected", "selection-service-empty",
            "selection-accessibility-allowed", "selection-accessibility-denied",
            "selection-service-accepted", "selection-service-invalid",
            "close-button", "text-escape", "panel-cancel", "old-composer-close", "old-composer-text-escape", "test-panel-close",
            "close-event-keydown-escape", "close-event-other-keydown", "close-event-no-escape-keydown",
            "app-terminating", "duplicate-instance-exit"])
        guard allowed.contains(event) else { return }
        if CommandLine.arguments.contains("--check-bridge") || CommandLine.arguments.contains("--verify-live-session") { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Research Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("launch.log").path
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return }
        _ = fchmod(fd, 0o600)
        if info.st_size > 32_768 { _ = ftruncate(fd, 0) }
        let row = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        row.utf8CString.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress { _ = Darwin.write(fd, address, bytes.count - 1) }
        }
    }
}
