import XCTest
@testable import DSHPet

final class ResearchProtocolTests: XCTestCase {
    func testCurrentZoteroSelectionKeepsExactTextAndVerifiedLocation() throws {
        let requestID = UUID()
        let selected = "  Selected α\r\nSecond line.  "
        let response = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "liveSelection": [
                "requestId": requestID.uuidString,
                "text": selected,
                "title": "Synthetic paper",
                "capture": ["method": "pdf-native", "tabID": "fixture-tab", "attachmentID": 1, "attachmentKey": "PAPER123"],
                "location": ["library": "library", "attachmentKey": "PAPER123", "pageIndex": 3, "pageLabel": "iv"],
            ],
        ])
        let material = try ResearchZoteroSelection.decode(response, status: 200, requestID: requestID)
        XCTAssertEqual(material.source, "Zotero")
        XCTAssertEqual(material.title, "Synthetic paper")
        XCTAssertEqual(Data(material.text.utf8), Data(selected.utf8))
        XCTAssertEqual(material.page, "iv")
        XCTAssertEqual(material.zoteroLocation?.attachmentKey, "PAPER123")
        XCTAssertEqual(material.zoteroLocation?.physicalPage, 4)
    }

    func testZoteroCannotSubstituteCachedOrMalformedContextForLiveSelection() throws {
        let requestID = UUID()
        let responses: [(status: Int, body: [String: Any], error: SelectionCaptureError)] = [
            (422, ["ok": false, "error": "NO_SELECTION"], .empty),
            (409, ["ok": false, "error": "NO_ACTIVE_PAPER"], .sourceChanged),
            (200, ["ok": true, "selection": ["text": "An old excerpt"]], .zoteroBridge),
            (200, ["ok": true, "liveSelection": "invalid"], .zoteroBridge),
        ]
        for response in responses {
            let data = try JSONSerialization.data(withJSONObject: response.body)
            XCTAssertThrowsError(try ResearchZoteroSelection.decode(data, status: response.status, requestID: requestID)) { error in
                XCTAssertEqual(error as? SelectionCaptureError, response.error)
            }
        }
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

    func testHistoryKeepsOriginalPromptWhileDisplayingOnlyTheQuestion() throws {
        let prompts = [
            ("Persona\n【原文】Exact quotation\n【用户问题】Explain the result", "Explain the result"),
            ("Persona\n\n【材料原文，JSON 引用数据】\n{\"text\":\"【用户问题】 这一句是原文\"}\n\n【用户问题】\n真实问题", "真实问题"),
        ]
        for (raw, question) in prompts {
            let message = try XCTUnwrap(ResearchProtocol.decodeMessages([["role": "user", "text": raw]]).first)
            XCTAssertEqual(message.text, question)
            XCTAssertEqual(message.originalPrompt, raw)
        }
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
