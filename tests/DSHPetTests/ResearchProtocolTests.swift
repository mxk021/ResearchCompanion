import XCTest
@testable import DSHPet

final class ResearchProtocolTests: XCTestCase {
    func testCurrentPaperAndSelectionAreDecodedWithoutLosingSource() throws {
        let context = try XCTUnwrap(ResearchProtocol.decodeContext([
            "available": true, "key": "PAPER123", "title": "A real paper", "text": "An exact selected passage.",
            "pageLabel": "iv", "source": "zotero-reader",
        ]))
        XCTAssertEqual(context.key, "PAPER123")
        XCTAssertEqual(context.title, "A real paper")
        XCTAssertEqual(context.text, "An exact selected passage.")
        XCTAssertEqual(context.pageLabel, "iv")
        XCTAssertTrue(context.hasText)
        XCTAssertNil(context.error)
    }

    func testNoPaperDoesNotBecomeSyntheticContext() throws {
        XCTAssertNil(try ResearchProtocol.decodeContext(nil))
        XCTAssertNil(try ResearchProtocol.decodeContext(NSNull()))
        let unavailable = try XCTUnwrap(ResearchProtocol.decodeContext([
            "title": "Selected attachment", "error": "Reader bridge is not enabled",
        ]))
        XCTAssertFalse(unavailable.hasText)
        XCTAssertEqual(unavailable.error, "Reader bridge is not enabled")
        XCTAssertThrowsError(try ResearchProtocol.decodeContext("invalid"))
    }

    func testConversationRetainsFullLongAnswerAndStableRoles() throws {
        let answer = String(repeating: "Evidence from the source.\n", count: 300)
        let messages = try ResearchProtocol.decodeMessages([
            ["id": "u1", "role": "user", "text": "Explain this passage"],
            ["id": "a1", "role": "assistant", "text": answer],
        ])
        XCTAssertEqual(messages.map(\.id), ["u1", "a1"])
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.last?.text, answer)
        XCTAssertEqual(try ResearchProtocol.decodeMessages([]).count, 0)
    }

    func testMalformedOrToolRecordsCannotMasqueradeAsAnswers() {
        XCTAssertThrowsError(try ResearchProtocol.decodeMessages(nil))
        XCTAssertThrowsError(try ResearchProtocol.decodeMessages([["role": "tool", "text": "secret result"]]))
        XCTAssertThrowsError(try ResearchProtocol.decodeMessages([["role": "assistant", "text": 42]]))
    }

    @MainActor
    func testResearchSubmissionFailsClosedWithoutBridgeAndKeepsDraft() {
        let suite = "ResearchCompanionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults)
        client.draft = "An unsent question"
        client.submitResearch()
        XCTAssertEqual(client.draft, "An unsent question")
        XCTAssertFalse(client.researchAvailable)
        XCTAssertFalse(client.hasPendingSubmission)
        XCTAssertNotNil(client.lastError)
        XCTAssertTrue(client.conversationMessages.isEmpty)
    }
}
