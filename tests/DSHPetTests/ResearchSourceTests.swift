import XCTest
@testable import DSHPet

final class ResearchSourceTests: XCTestCase {
    func testProvenanceRemainsBoundToInTurnExcerptAfterFileMoves() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("A.txt")
        let moved = root.appendingPathComponent("A-moved.txt")
        let b = root.appendingPathComponent("B.txt")
        let executable = root.appendingPathComponent("A.command")
        try "Material A".write(to: a, atomically: true, encoding: .utf8)
        try "Material B".write(to: b, atomically: true, encoding: .utf8)
        try "Material A".write(to: executable, atomically: true, encoding: .utf8)
        let material = try ResearchFileMaterial.load(a)
        XCTAssertNil(material.fields["url"])
        XCTAssertFalse(material.fields.description.contains(a.path))
        let storePath = root.appendingPathComponent("Provenance")
        let store = ResearchProvenanceStore(root: storePath)
        let request = "stable-request"
        let evidence = ResearchSourceMaterial(key: "inline:digest", title: material.title, text: material.text,
                                              source: material.source, scope: material.scope, url: nil, pageLabel: nil, pageIndex: nil)
        let reply = ResearchReplyContext(question: "Explain A", questionId: "q", requestId: request,
                                         time: 1_700_000_000_000, material: evidence)
        try store.record(session: "conversation-a", requestID: request, material: material)
        try store.record(session: "conversation-a", requestID: request, material: ResearchFileMaterial.load(b))
        let afterRestart = ResearchProvenanceStore(root: storePath)
        let original = afterRestart.read(session: "conversation-a", reply: reply)?.file
        XCTAssertEqual(original?.resolve(), a)
        XCTAssertNil(afterRestart.read(session: "conversation-b", reply: reply))
        try fm.moveItem(at: a, to: moved)
        XCTAssertFalse(original?.matches(b) ?? true)
        XCTAssertFalse(original?.matches(executable) ?? true)
        XCTAssertThrowsError(try afterRestart.relink(session: "conversation-a", reply: reply, file: b))
        try afterRestart.relink(session: "conversation-a", reply: reply, file: moved)
        let answer = ResearchChatMessage(id: "answer", role: "assistant", text: #"Its formula is $a^2$."#,
                                         originalPrompt: nil, reply: reply)
        let source = ResearchAnswerSource(session: "conversation-a", answer: answer, store: afterRestart)
        XCTAssertEqual(source.local?.file?.resolve(), moved)
        let note = source.markdown(interpretation: #"$a^2$"#, supplement: "我的核对", savedAt: Date(timeIntervalSince1970: 0))
        let exported = root.appendingPathComponent("笔记.md")
        try note.write(to: exported, atomically: true, encoding: .utf8)
        XCTAssertTrue(note.contains("## AI 解释\n\n$a^2$"))
        XCTAssertTrue(note.contains("> Material A"))
        XCTAssertTrue(note.contains("> Explain A"))
        XCTAssertFalse(note.contains("Material B"))
        XCTAssertTrue(note.contains("## 用户补充\n\n我的核对"))
        try afterRestart.remove(session: "conversation-a")
        XCTAssertNil(afterRestart.read(session: "conversation-a", reply: reply))
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), note)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "Material A")
    }

    func testZoteroAttachmentPositionIsNotThePrintedPageLabel() {
        func source(_ link: String, position: Int?) -> ResearchSourceMaterial {
            .init(key: "1:ABCDEFGH:JKLMNPQR:" + String(repeating: "a", count: 64), title: "Paper", text: "Excerpt",
                  source: link, scope: "Selection", url: nil, pageLabel: "iv", pageIndex: position)
        }
        XCTAssertEqual(ResearchSourceLocation.zoteroURL(source("zotero://select/library/items/ABCDEFGH", position: 7))?.absoluteString,
                       "zotero://open-pdf/library/items/JKLMNPQR?page=8")
        XCTAssertEqual(ResearchSourceLocation.zoteroURL(source("zotero://select/groups/123/items/ABCDEFGH", position: nil))?.absoluteString,
                       "zotero://open-pdf/groups/123/items/JKLMNPQR")
        XCTAssertNil(ResearchSourceLocation.zoteroURL(source("zotero://select/library/items/XXXXXXXX", position: 7)))
        XCTAssertNil(ResearchSourceLocation.webURL(URL(string: "https://username:password@example.com/path")!))
    }

    func testDirectJumpUsesOriginalWebCaptureAndDoesNotUseAnAnswerLink() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchProvenanceStore(root: root)
        var capture = try ResearchMaterial.selection("Verified original", source: "Safari", title: "First article",
                                                     url: "https://example.org/a")
        capture.localWebURL = "https://example.org/a?section=results#figure-1"
        try store.record(session: "first", requestID: "original-request", material: capture)
        let evidence = ResearchSourceMaterial(key: "inline:a", title: capture.title, text: capture.text,
                                              source: capture.source, scope: capture.scope, url: capture.url,
                                              pageLabel: nil, pageIndex: nil)
        let reply = ResearchReplyContext(question: "Explain A", questionId: "u", requestId: "original-request",
                                         time: nil, material: evidence)
        let text = "[Suggested link](https://example.invalid/model)"
        let answer = ResearchChatMessage(id: "reply", role: "assistant", text: text, originalPrompt: nil, reply: reply)
        let source = ResearchAnswerSource(session: "first", answer: answer, store: store)
        let target = try XCTUnwrap(source.directTarget)
        let url = await target.resolve()
        XCTAssertEqual(url?.absoluteString, capture.localWebURL)

        let withoutSource = ResearchChatMessage(id: "reply", role: "assistant", text: text, originalPrompt: nil)
        XCTAssertNil(ResearchAnswerSource(session: "first", answer: withoutSource, store: store).directTarget)
        let oldReply = ResearchReplyContext(question: "Explain A", questionId: "u", requestId: nil,
                                            time: nil, material: evidence)
        let oldAnswer = ResearchChatMessage(id: "reply", role: "assistant", text: text, originalPrompt: nil, reply: oldReply)
        XCTAssertNil(ResearchAnswerSource(session: "first", answer: oldAnswer, store: store).directTarget)
    }

    func testDirectJumpCannotOpenChangedLocalFile() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("A.md")
        try "Material A".write(to: file, atomically: true, encoding: .utf8)
        let capture = try ResearchFileMaterial.load(file)
        let store = ResearchProvenanceStore(root: root.appendingPathComponent("Sources"))
        try store.record(session: "test", requestID: "request-a", material: capture)
        let evidence = ResearchSourceMaterial(key: "inline:a", title: capture.title, text: capture.text,
                                              source: capture.source, scope: capture.scope, url: nil,
                                              pageLabel: nil, pageIndex: nil)
        let reply = ResearchReplyContext(question: "Explain A", questionId: "u", requestId: "request-a",
                                         time: nil, material: evidence)
        let answer = ResearchChatMessage(id: "reply", role: "assistant", text: "A", originalPrompt: nil, reply: reply)
        let target = try XCTUnwrap(ResearchAnswerSource(session: "test", answer: answer, store: store).directTarget)
        let existingURL = await target.resolve()
        XCTAssertEqual(existingURL, file)
        try "Different material".write(to: file, atomically: true, encoding: .utf8)
        let invalidURL = await target.resolve()
        XCTAssertNil(invalidURL)
    }

    func testServiceLocatorRequiresCompleteMatchingTextAndPreservesSubmittedBytes() throws {
        let fromService = try ResearchMaterial.selection("页面\r\n第二行", source: "Safari", title: "浏览器选区")
        let fromAccessibility = try ResearchMaterial.selection("页面\n第二行", source: "Safari", title: "实际网页",
                                                               url: "https://example.net/page")
        let enriched = try XCTUnwrap(fromService.withLocator(from: fromAccessibility))
        XCTAssertEqual(enriched.text, "页面\r\n第二行")
        XCTAssertEqual(enriched.url, "https://example.net/page")
        let different = try ResearchMaterial.selection("另一段选区", source: "Safari", title: "不同页面")
        XCTAssertNil(fromService.withLocator(from: different))
        let long = try ResearchMaterial.selection(String(repeating: "a", count: ResearchMaterial.maximumLength + 1),
                                                  source: "Safari", title: "部分选区")
        XCTAssertTrue(long.selectionIsComplete)
        XCTAssertEqual(long.withLocator(from: long)?.text.utf16.count, 24_001)
    }
    func testSelectionBackgroundRequiresDocumentIntent() {
        for query in ["不要结合 PDF，只解释这一句", "仅翻译选区", "what is the meaning of “paper”?", "Explain this selection only."] {
            XCTAssertFalse(ResearchMaterial.requestsFileBackground(query, filename: "fixture.pdf"), query)
        }
        for query in ["结合这篇论文解释选区", "对照会话文件", "What does page 52 say?", "依据 fixture.pdf 的实测数据判断"] {
            XCTAssertTrue(ResearchMaterial.requestsFileBackground(query, filename: "fixture.pdf"), query)
        }
    }

}
