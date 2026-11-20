import Foundation

/// Read-only diagnostic using the production native client and the actual
/// owned manifest/socket. It never creates a session, sends a prompt, reads a
/// paper, or prints identifiers, paths, tokens, task content or error text.
@MainActor
enum ResearchBridgeSelfCheck {
    static func run(manifestPath: String) async -> Int32 {
        let url = URL(fileURLWithPath: manifestPath)
        let discovered = HarnessConnectionManager.discover(in: url.deletingLastPathComponent())
        guard let instance = discovered.first(where: { "\($0.id).json" == url.lastPathComponent }) else {
            print("{\"ok\":false,\"manifestAccepted\":false}")
            return 2
        }
        let suite = "ResearchCompanionBridgeCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults)
        _ = client.configure(instance: instance)
        client.start()
        // Reproduce a panel opening during handshake; this must not poison
        // the physical connection or strand the capabilities request.
        client.refreshWorkspaces()
        defer { client.stop() }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if client.connection == .connected, client.capabilitiesAvailable,
               client.researchAvailable, !client.workspaces.isEmpty {
                print("{\"ok\":true,\"manifestAccepted\":true,\"capabilities\":true,\"researchProtocol\":true,\"workspaceCount\":\(client.workspaces.count),\"sessionCreated\":false}")
                return 0
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("{\"ok\":false,\"manifestAccepted\":true,\"capabilities\":\(client.capabilitiesAvailable),\"researchProtocol\":\(client.researchAvailable),\"workspaceCount\":\(client.workspaces.count),\"hasError\":\(client.lastError != nil),\"sessionCreated\":false}")
        return 1
    }
}
