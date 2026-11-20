import Foundation

/// Explicit integration test over the production native client. Uses a fresh
/// temporary preference suite, one dedicated test conversation and three small
/// marker prompts. Never reads/modifies the running app's preferences or session.
@MainActor
enum ResearchLiveSessionCheck {
    private enum Failure: Error { case stage(String) }

    static func run(manifestPath: String) async -> Int32 {
        let url = URL(fileURLWithPath: manifestPath)
        let discovered = HarnessConnectionManager.discover(in: url.deletingLastPathComponent())
        guard let instance = discovered.first(where: { "\($0.id).json" == url.lastPathComponent }) else {
            print("{\"ok\":false,\"stage\":\"manifest\",\"nativeClient\":true}")
            return 2
        }
        let suite = "ResearchCompanionLiveSessionCheck.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { return 2 }
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = DSHPetCommandClient(defaults: preferences)
        defer { first.stop() }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let markers = ["NATIVE_FIRST_\(suffix)", "NATIVE_SECOND_\(suffix)", "NATIVE_RESTART_\(suffix)"]
        do {
            first.includePaperContext = false
            guard first.configure(instance: instance) else { throw Failure.stage("configure") }
            first.start()
            // Same early UI refresh that previously raced capabilities.
            first.refreshWorkspaces()
            guard await waitFor(first, seconds: 15, condition: {
                first.capabilitiesAvailable && first.researchAvailable && first.selectedWorkspace != nil
            }) else { throw Failure.stage("handshake") }
            try await sendMarker(markers[0], via: first, stage: "first-turn")
            guard let session = first.sessionID else { throw Failure.stage("first-session") }
            try await sendMarker(markers[1], via: first, stage: "second-turn")
            guard first.sessionID == session else { throw Failure.stage("second-session-changed") }
            first.stop()

            // Construct after the first client saved its binding, just as a
            // fresh app launch would. The user's app suite is never involved.
            let restored = DSHPetCommandClient(defaults: preferences)
            defer { restored.stop() }
            restored.includePaperContext = false
            guard restored.configure(instance: instance), restored.sessionID == session else {
                throw Failure.stage("restart-binding")
            }
            restored.start()
            guard await waitFor(restored, seconds: 15, condition: {
                restored.capabilitiesAvailable && restored.researchAvailable && restored.selectedWorkspace != nil
            }) else { throw Failure.stage("restart-handshake") }
            try await sendMarker(markers[2], via: restored, stage: "third-turn")
            guard restored.sessionID == session else { throw Failure.stage("restart-session-changed") }
            let replies = restored.conversationMessages.filter { $0.role == "assistant" }
            guard markers.allSatisfy({ marker in replies.contains(where: { $0.text.contains(marker) }) }) else {
                throw Failure.stage("history-not-continuous")
            }
            print("{\"ok\":true,\"nativeClient\":true,\"turns\":3,\"stableSession\":true,\"restartReuse\":true,\"isolatedPreferences\":true,\"paperIncluded\":false}")
            return 0
        } catch Failure.stage(let stage) {
            // Every stage is a fixed internal literal, never a server message.
            print("{\"ok\":false,\"nativeClient\":true,\"stage\":\"\(stage)\",\"isolatedPreferences\":true}")
            return 1
        } catch {
            print("{\"ok\":false,\"nativeClient\":true,\"stage\":\"unexpected\",\"isolatedPreferences\":true}")
            return 1
        }
    }

    private static func sendMarker(_ marker: String, via client: DSHPetCommandClient, stage: String) async throws {
        guard await waitFor(client, seconds: 30, condition: {
            !client.conversationRunning && client.sessionSnapshot?.taskRunning != true
                && client.submissionStatus != .submitting && !client.hasPendingSubmission
        }) else { throw Failure.stage(stage + "-busy") }
        client.draft = "请只回复以下标记，不做其他操作：\(marker)"
        client.submitResearch(.ask)
        guard await waitFor(client, seconds: 90, condition: {
            client.conversationMessages.contains(where: { $0.role == "assistant" && $0.text.contains(marker) })
                && !client.conversationRunning && client.sessionSnapshot?.taskRunning != true
                && !client.hasPendingSubmission
        }) else { throw Failure.stage(stage) }
    }

    private static func waitFor(_ client: DSHPetCommandClient, seconds: TimeInterval,
        condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            client.refreshResearch()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return condition()
    }
}
