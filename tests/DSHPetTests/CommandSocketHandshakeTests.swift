import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import DSHPet

final class CommandSocketHandshakeTests: XCTestCase {
    func testManualImagesAndPDFRegionsShareOneTransportBudget() throws {
        let limits = DSHPetImageLimits(maxImageBytes: 10, maxImagesPerMessage: 3, maxMessageImageBytes: 16,
                                      mediaTypes: ["image/jpeg", "image/png"], maxImagePixels: nil, maxImageDimension: nil)
        let image = DSHPetDraftImage(id: "image", path: "", mediaType: "image/png", name: "image.png", bytes: 8, error: nil)
        let crop = Data(repeating: 7, count: 4)
        XCTAssertNoThrow(try DSHPetCommandClient.validateTurnImageBudget(userImages: [image],
                                                                         documentImages: [crop, crop], limits: limits))
        XCTAssertThrowsError(try DSHPetCommandClient.validateTurnImageBudget(userImages: [image, image],
                                                                             documentImages: [crop], limits: limits))
        XCTAssertThrowsError(try DSHPetCommandClient.validateTurnImageBudget(userImages: [image],
                                                                             documentImages: [crop, crop, crop], limits: limits))
    }

    @MainActor
    func testResearchTurnSendsVerifiedFigureSelectionAndManualImageTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/tmp/rc-mixed-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, researchImages: true)
        defer { server.stop() }
        let suite = "ResearchMixedImagesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path,
            provenanceStore: ResearchProvenanceStore(root: root.appendingPathComponent("sources")),
            draftImageStorage: root.appendingPathComponent("drafts"))
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        defer { client.stop() }
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        client.refreshModelCatalog()
        for _ in 0..<100 where client.selectedResearchModel == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.selectedResearchModel?.reasoningEffort, "high")
        let pdf = root.appendingPathComponent("source.pdf")
        let image = root.appendingPathComponent("manual.png")
        try writeMixedEvidenceFixtures(pdf: pdf, image: image)
        XCTAssertTrue(client.beginResearchFileChoice())
        client.finishResearchFileChoice(pdf)
        for _ in 0..<100 where client.loadingResearchFile {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(client.canUseAssociatedFile, client.materialError ?? "")
        let selection = try ResearchMaterial.selection("This is the independently selected observation.",
                                                       source: "TextEdit", title: "Synthetic selection")
        let capture = try XCTUnwrap(client.beginResearchSelectionCapture())
        client.finishResearchSelectionCapture(capture, result: .success(selection))
        XCTAssertTrue(client.beginResearchFileChoice())
        client.finishDraftImageChoice([image])
        for _ in 0..<100 where client.importingDraftImages {
            try await Task.sleep(for: .milliseconds(20))
        }
        let imported = try XCTUnwrap(client.draftImages.first)
        let expectedImage = try Data(contentsOf: imported.fileURL)
        let question = "结合论文解释这段选区、Fig. 3 和附加图片。"
        client.draft = question
        client.submitResearch()
        await server.waitForActionCount("researchPrompt", atLeast: 1)
        let prompt = try XCTUnwrap(server.mixedPrompt())
        XCTAssertEqual(prompt["text"] as? String, question)
        XCTAssertEqual(prompt["selection"] as? [String: String], CommandSocketServer.visionSelection)
        let material = try XCTUnwrap(prompt["material"] as? [String: Any])
        let body = try XCTUnwrap(material["text"] as? String)
        XCTAssertTrue(body.contains(selection.text))
        XCTAssertTrue(body.contains("The last observation is the audited modulation signal."))
        let crops = try XCTUnwrap(prompt["images"] as? [[String: String]])
        XCTAssertEqual(crops.count, 2)
        XCTAssertTrue(crops.allSatisfy { $0["mediaType"] == "image/jpeg" && ($0["name"] ?? "").hasPrefix("PDF-region-") })
        let attachments = try XCTUnwrap(prompt["userImages"] as? [[String: String]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["data"], expectedImage.base64EncodedString())
        XCTAssertEqual(server.actionCount("createSession"), 1)
        XCTAssertEqual(server.actionCount("researchPrompt"), 1)
        XCTAssertEqual(server.actionCount("researchDocumentPlan"), 0)
        XCTAssertEqual(server.actionCount("prompt"), 0)
        for _ in 0..<100 where client.submissionStatus == .submitting {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(client.draft.isEmpty)
        XCTAssertTrue(client.draftImages.isEmpty)
        XCTAssertEqual(client.availableResearchSelection?.text, selection.text)
        XCTAssertTrue(client.hasAssociatedFile)
    }

    private func writeMixedEvidenceFixtures(pdf: URL, image: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdf as CFURL))
        let canvas = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &page, nil))
        let small = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let normal = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let equation = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ font: CTFont) {
            canvas.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), canvas)
        }
        canvas.beginPDFPage(nil)
        let paragraphs = ["This paragraph motivates the calibration.", "The fixture prints both lanes in parallel.",
            "Figure 3a illustrates the control array.", "The output is sampled every five minutes.",
            "These measurements establish a reference."]
        for (i, text) in paragraphs.enumerated() {
            line(text, 48, 741 - CGFloat(14 * i), normal)
            line("Independent right column. " + text.prefix(17), 323, 741 - CGFloat(14 * i), normal)
        }
        canvas.setStrokeColor(gray: 0, alpha: 1)
        canvas.setLineWidth(1)
        canvas.stroke(CGRect(x: 46, y: 471, width: 253, height: 178))
        canvas.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        canvas.fill(CGRect(x: 55, y: 539, width: 105, height: 96))
        canvas.fill(CGRect(x: 176, y: 545, width: 113, height: 87))
        canvas.setFillColor(gray: 0, alpha: 1)
        line("(a) Control", 56, 642, small)
        line("(b) Measured", 177, 641, small)
        line("Fig. 3. A diagram with two panels and a formula.", 51, 527, small)
        line("The shaded bars show the complete reference and test grids.", 51, 516, small)
        line("The notation ∥u∥ = c.", 51, 500, equation)
        line("The last observation is the audited modulation signal.", 51, 480, small)
        line("The independent following paragraph is absent from the caption.", 48, 442, normal)
        canvas.endPDFPage()
        canvas.closePDF()
        let raster = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.setFillColor(red: 0.8, green: 0.1, blue: 0.3, alpha: 1)
        raster.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(raster.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    @MainActor
    func testTwoPromptsReuseTheSameNonblankSessionWithoutCreatingAgain() async throws {
        let path = "/tmp/research-session-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance)
        defer { server.stop() }
        let suite = "ResearchSessionReuseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults)
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        defer { client.stop() }
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        client.draft = "first question"
        client.submitDraft()
        await server.waitForAction("prompt")
        for _ in 0..<100 where client.submissionStatus == .submitting {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(client.hasPendingSubmission)
        XCTAssertTrue(client.draft.isEmpty)
        let original = try XCTUnwrap(client.sessionID)
        client.draft = "a follow-up using the first answer"
        client.submitDraft()
        await server.waitForActionCount("prompt", atLeast: 2)
        XCTAssertEqual(server.actionCount("prompt"), 2)
        XCTAssertEqual(server.actionCount("createSession"), 1)
        XCTAssertEqual(client.sessionID, original)
    }

    @MainActor
    func testDisconnectDuringPromptRemainsUnconfirmedWithoutAutomaticResend() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, disconnectOnPrompt: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        defer { client.stop() }
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(client.selectedWorkspaceID)
        client.draft = "断线时保留的消息"
        client.submitDraft()
        await server.waitForAction("prompt")
        for _ in 0..<100 where client.submissionStatus != .unconfirmed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.submissionStatus, .unconfirmed)
        XCTAssertEqual(client.draft, "断线时保留的消息")
        await server.waitForActionCount("capabilities", atLeast: 2)
        XCTAssertGreaterThanOrEqual(server.actionCount("capabilities"), 2)
        XCTAssertEqual(server.actionCount("prompt"), 1)
    }

    @MainActor
    func testServerRejectionClearsPendingRequestGuardAndKeepsDraft() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, rejectPrompt: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        defer { client.stop() }
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        client.draft = "服务端明确拒绝的消息"
        client.submitDraft()
        await server.waitForAction("prompt")
        for _ in 0..<100 {
            if case .failed = client.submissionStatus { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.submissionStatus, .failed("rejected by test"))
        XCTAssertFalse(client.hasPendingSubmission)
        XCTAssertEqual(client.draft, "服务端明确拒绝的消息")
        XCTAssertNil(defaults.string(forKey: "dsh-pet.command.pendingRequestID"))
    }

    @MainActor
    func testPreviewUpdatesOnlyForFocusedSession() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, previewSupport: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        await server.waitForAction("workspaces")
        let task = DSHPetTaskSummary(sessionID: "focused", workspaceID: "workspace", title: "测试", cwd: nil,
            updatedAt: 1, running: false, blank: false, state: .completed, mood: "done", taskRunning: false,
            waitingForUser: false, failed: false, completed: true, tool: nil, message: nil)
        client.applyTaskSummaries([task])
        client.focusTask(task.id)
        await server.waitForAction("taskPreview")
        server.sendEvent(["event": "taskPreviewChanged", "sessionId": "other"])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.actionCount("taskPreview"), 1)
        server.sendEvent(["event": "taskPreviewChanged", "sessionId": "focused"])
        await server.waitForActionCount("taskPreview", atLeast: 2)
        XCTAssertEqual(server.actionCount("taskPreview"), 2)
        client.stop()
    }

    @MainActor
    func testCandidateQueriesSharePendingSessionAndIgnoreOldQuery() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, delayCreateSession: true, candidateSupport: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        client.updateCandidates(kind: .file, query: "old")
        await server.waitForAction("createSession")
        client.updateCandidates(kind: .file, query: "new")
        server.releaseCreateSession()
        await server.waitForAction("fileCandidates")
        for _ in 0..<100 where client.candidatesLoading {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(server.actionCount("createSession"), 1)
        XCTAssertEqual(client.candidates.map(\.insertText), ["@new"])
        client.stop()
    }

    @MainActor
    func testNewSessionInvalidatesPendingCandidateSessionCreation() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, delayCreateSession: true, candidateSupport: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        client.updateCandidates(kind: .file, query: "old")
        await server.waitForAction("createSession")
        client.startNewSession()
        server.releaseCreateSession()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(client.sessionID)
        XCTAssertFalse(server.containsAction("subscribe"))
        XCTAssertFalse(server.containsAction("fileCandidates"))
        XCTAssertNil(client.candidateKind)
        client.stop()
    }
    @MainActor
    func testMismatchedCapabilitiesNeverUnlockBusinessRequests() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let wrong = makeInstance(id: "other", status: "/tmp/other-status.sock", command: "/tmp/other-command.sock")
        let server = try CommandSocketServer(path: path, instance: wrong)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)

        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        await server.waitForAction("capabilities")
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(client.capabilitiesAvailable)
        client.refreshWorkspaces()
        client.draft = "不会发送"
        client.submitDraft()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(server.containsAction("workspaces"))
        XCTAssertFalse(server.containsAction("createSession"))
        XCTAssertFalse(server.containsAction("prompt"))
        client.stop()
    }

    @MainActor
    func testMatchingCapabilitiesUnlocksWorkspacesOnSelectedSocket() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)

        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<20 where client.workspaces.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.capabilitiesAvailable)
        XCTAssertEqual(client.workspaces.map(\.id), ["workspace"])
        client.stop()
    }

    @MainActor
    func testSameStableTargetReloadPreservesDraftAndPersistedSession() {
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("profile-desktop", forKey: "dsh-pet.command.targetBindingKey")
        defaults.set("kept-session", forKey: "dsh-pet.command.sessionID")
        defaults.set("workspace", forKey: "dsh-pet.command.workspaceID")
        let client = DSHPetCommandClient(defaults: defaults, socketPath: "/tmp/unused.sock")
        let first = makeInstance(id: "first", status: "/tmp/first-status.sock", command: "/tmp/first-command.sock", pid: Int32(getpid()))
        let second = makeInstance(id: "second", status: "/tmp/second-status.sock", command: "/tmp/second-command.sock", pid: Int32(getpid()))
        XCTAssertTrue(client.configure(instance: first))
        client.draft = "保留在第一个目标"

        XCTAssertTrue(client.configure(instance: second))
        XCTAssertEqual(client.draft, "保留在第一个目标")
        XCTAssertEqual(client.sessionID, "kept-session")
    }

    @MainActor
    func testSubmitTransactionStopsBeforeSubscribeAfterSameSourceRestart() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, delayCreateSession: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)

        XCTAssertTrue(client.configure(instance: instance))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<20 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        client.draft = "等待来源切换"
        client.submitDraft()
        await server.waitForAction("createSession")

        // Reconnect the same selected target while createSession is awaiting a
        // response. The old task must not subscribe or prompt on the new socket.
        XCTAssertTrue(client.configure(instance: nil))
        XCTAssertEqual(client.submissionStatus, .failed("消息尚未发送，请在连接恢复后重试"))
        XCTAssertEqual(client.draft, "等待来源切换")
        XCTAssertTrue(client.configure(instance: instance))
        server.releaseCreateSession()
        await server.waitForActionCount("capabilities", atLeast: 2)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(server.containsAction("subscribe"))
        XCTAssertFalse(server.containsAction("prompt"))
        client.stop()
    }

    private func makeInstance(
        id: String,
        status: String,
        command: String,
        pid: Int32 = 999_999
    ) -> HarnessInstance {
        HarnessInstance(
            protocolVersion: 1,
            instanceId: id,
            kind: .desktop,
            profile: "desktop",
            pid: pid,
            startedAt: 1,
            webURL: nil,
            statusSocketPath: status,
            commandSocketPath: command,
            targetId: "profile-desktop"
        )
    }

}

private final class CommandSocketServer: @unchecked Sendable {
    static let visionSelection = ["provider": "chatgpt", "model": "fixture-vision", "reasoningEffort": "high"]
    private let listener: Int32
    private let path: String
    private let instance: HarnessInstance
    private let delayCreateSession: Bool
    private let candidateSupport: Bool
    private let previewSupport: Bool
    private let disconnectOnPrompt: Bool
    private let rejectPrompt: Bool
    private let researchImages: Bool
    private let createSessionRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var sessionIDs: [String] = []
    private var mixedResearchPrompt: [String: Any]?
    private(set) var actions: [String] = []

    init(path: String, instance: HarnessInstance, delayCreateSession: Bool = false, candidateSupport: Bool = false, previewSupport: Bool = false, disconnectOnPrompt: Bool = false, rejectPrompt: Bool = false, researchImages: Bool = false) throws {
        self.path = path
        self.instance = instance
        self.delayCreateSession = delayCreateSession
        self.candidateSupport = candidateSupport
        self.previewSupport = previewSupport
        self.disconnectOnPrompt = disconnectOnPrompt
        self.rejectPrompt = rejectPrompt
        self.researchImages = researchImages
        listener = try Self.makeListener(path: path)
        DispatchQueue.global().async { [weak self] in self?.acceptLoop() }
    }

    func waitForAction(_ action: String) async {
        for _ in 0..<100 {
            if lock.withLock({ actions.contains(action) }) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func containsAction(_ action: String) -> Bool {
        lock.withLock { actions.contains(action) }
    }

    func actionCount(_ action: String) -> Int {
        lock.withLock { actions.filter { $0 == action }.count }
    }

    func mixedPrompt() -> [String: Any]? { lock.withLock { mixedResearchPrompt } }

    func waitForActionCount(_ action: String, atLeast count: Int) async {
        // The client waits two seconds before reconnecting. Leave room for
        // scheduling and the actual handshake on a shared runner.
        for _ in 0..<250 {
            if lock.withLock({ actions.filter { $0 == action }.count >= count }) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func releaseCreateSession() {
        createSessionRelease.signal()
    }

    func sendEvent(_ event: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: event) else { return }
        data.append(10)
        lock.withLock {
            for client in clients {
                _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            }
        }
    }

    func stop() {
        Darwin.close(listener)
        lock.withLock {
            for client in clients { Darwin.close(client) }
            clients.removeAll()
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            Self.disableSigPipe(client)
            lock.withLock { clients.append(client) }
            DispatchQueue.global().async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] as? String,
                      let action = request["action"] as? String else { continue }
                lock.withLock {
                    actions.append(action)
                    if action == "researchPrompt" { mixedResearchPrompt = request }
                }
                if action == "prompt", disconnectOnPrompt {
                    Darwin.shutdown(client, SHUT_RDWR)
                    return
                }
                let response: [String: Any]
                if action == "capabilities" {
                    response = [
                        "id": id, "ok": true, "protocolVersion": 1,
                        "commandSocket": true, "supports": ["workspaces"]
                            + (candidateSupport ? ["fileCandidates"] : []) + (previewSupport ? ["taskPreview"] : [])
                            + (researchImages ? ["conversation", "researchContext", "researchPrompt", "researchMaterial",
                                "researchDocumentPlan", "researchDocumentImages", "researchUserImages", "imageAttachments",
                                "modelCatalog", "researchSelectModel"] : []),
                        "attachmentLimits": ["maxImageBytes": 5_000_000, "maxImagesPerMessage": 4,
                            "maxMessageImageBytes": 10_000_000, "mediaTypes": ["image/png", "image/jpeg"]],
                        "instance": [
                            "protocolVersion": instance.protocolVersion,
                            "instanceId": instance.instanceId,
                            "kind": instance.kind.rawValue,
                            "profile": instance.profile as Any,
                            "pid": instance.pid,
                            "startedAt": instance.startedAt,
                            "statusSocketPath": instance.statusSocketPath,
                            "commandSocketPath": instance.commandSocketPath,
                        ],
                    ]
                } else if action == "workspaces" {
                    response = [
                        "id": id, "ok": true,
                        "workspaces": [[
                            "id": "workspace", "title": "测试工作区", "path": "/tmp",
                            "status": "ready", "sessionIds": lock.withLock { sessionIDs },
                        ]],
                    ]
                } else {
                    if action == "createSession", delayCreateSession {
                        createSessionRelease.wait()
                    }
                    if action == "prompt", rejectPrompt {
                        response = [
                            "id": id, "ok": false,
                            "error": ["code": "test/rejected", "message": "rejected by test"],
                        ]
                    } else if action == "prompt" || action == "researchPrompt" {
                        response = ["id": id, "ok": true, "accepted": true, "sessionId": request["sessionId"] ?? ""]
                    } else if action == "modelCatalog" {
                        response = ["id": id, "ok": true, "catalog": [
                            "defaultSelection": Self.visionSelection, "groups": [[
                                "id": "chatgpt", "name": "Test", "models": [["id": "fixture-vision", "name": "Fixture vision",
                                    "inputModalities": ["text", "image"], "reasoning": [
                                        "defaultEffort": "high", "efforts": [["id": "high", "name": "High"]]]]],
                            ]],
                        ]]
                    } else if action == "conversation" {
                        response = ["id": id, "ok": true, "messages": [], "selection": Self.visionSelection]
                    } else if action == "researchSelectModel" {
                        response = ["id": id, "ok": true, "selected": Self.visionSelection]
                    } else if action == "createSession" {
                        if let session = request["sessionId"] as? String {
                            lock.withLock { if !sessionIDs.contains(session) { sessionIDs.append(session) } }
                        }
                        response = ["id": id, "ok": true, "sessionId": request["sessionId"] ?? ""]
                    } else if action == "fileCandidates" {
                        response = ["id": id, "ok": true, "candidates": [["path": request["query"] ?? "", "kind": "file"]]]
                    } else if action == "taskPreview" {
                        response = ["id": id, "ok": true, "status": "available", "text": "测试回复"]
                    } else {
                        response = ["id": id, "ok": true]
                    }
                }
                guard var data = try? JSONSerialization.data(withJSONObject: response) else { continue }
                data.append(10)
                _ = data.withUnsafeBytes { raw in
                    Darwin.write(client, raw.baseAddress, raw.count)
                }
            }
        }
    }

    private static func disableSigPipe(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    private static func makeListener(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        try? FileManager.default.removeItem(atPath: path)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map(UInt8.init(bitPattern:)))
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
