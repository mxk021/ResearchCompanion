import AppKit
import XCTest
@testable import DSHPet

final class ResearchSourceTests: XCTestCase {
    func testNoteExportsOnlyVerifiedSlicesOfTheImmutableRequest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ResearchProvenanceStore(root: folder)
        let text = #"The figure shows $\alpha^2$."# + "\n~~~~\n<img src=\"https://example.invalid/pixel\">"
        let capture = try ResearchMaterial.selection(text, source: "Safari", title: "Public paper")
        var background = ResearchMaterial(source: "PDF 文件", title: "Supporting article", text: "Local tool status\nFrom the original, x is the input.", scope: "Page 7")
        let appLine = "Local tool status\n"
        background.verifiedExcerpts = [.init(kind: .body,
            range: NSRange(location: appLine.utf16.count, length: background.text.utf16.count - appLine.utf16.count),
            title: background.title, page: 7, doi: "10.1234/sample")]
        var packet = try capture.withBackgroundEvidence(background)
        packet.fileReference = .init(originalPath: "/private/research/internal-paper.pdf", bookmark: nil, fingerprint: "fixture")
        packet.localWebURL = "https://example.invalid/preview?token=PRIVATE_CREDENTIAL"
        packet.documentImages = [Data([0, 1, 2, 3])]
        try store.record(session: "session", requestID: "new", material: packet, question: "Only this question")
        var legacy = packet
        legacy.verifiedExcerpts = nil
        try store.record(session: "session", requestID: "legacy", material: legacy)

        func note(_ id: String, body: String, session: String = "session") -> String {
            let material = ResearchSourceMaterial(key: "inline:fixture", title: packet.title, text: body,
                source: packet.source, scope: packet.scope, url: nil, pageLabel: nil, pageIndex: nil)
            let reply = ResearchReplyContext(question: "Bridge-generated mode instruction\nOnly this question",
                questionId: "q", requestId: id, time: nil, material: material)
            let answer = ResearchChatMessage(id: "a", role: "assistant", text: "Selected explanation", originalPrompt: nil, reply: reply)
            return ResearchAnswerSource(session: session, answer: answer, store: store, includePositions: false)
                .markdown(interpretation: #"Keep only $\frac{x}{y}$."#, supplement: "我的想法", savedAt: Date(timeIntervalSince1970: 1))
        }
        let exported = note("new", body: packet.text)
        XCTAssertTrue(exported.contains("> ~~~~~text\n> The figure shows"))
        XCTAssertTrue(exported.contains("> ~~~~\n> <img src="))
        XCTAssertTrue(exported.contains("> From the original, x is the input."))
        XCTAssertTrue(exported.contains("辅助原文 · Supporting article · PDF 文件第 7 页 · DOI 10.1234/sample"))
        XCTAssertTrue(exported.contains("关联 1 处原页裁图，Markdown 仅导出文字"))
        XCTAssertTrue(exported.contains(#"Keep only $\frac{x}{y}$."#))
        XCTAssertTrue(exported.contains("> Only this question"))
        XCTAssertTrue(exported.contains("我的想法"))
        for string in [appLine, "PRIVATE_CREDENTIAL", "/private/research", "【本次选区", "【会话文件摘录", "Bridge-generated mode instruction"] {
            XCTAssertFalse(exported.contains(string))
        }
        for fallback in [note("legacy", body: packet.text), note("new", body: packet.text + " revised"),
                         note("new", body: packet.text, session: "other")] {
            XCTAssertTrue(fallback.contains("没有可独立核验的文字摘录"))
            XCTAssertFalse(fallback.contains("The figure shows"))
            XCTAssertFalse(fallback.contains("From the original"))
        }
    }

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

    func testLiveZoteroDestinationPersistsLocallyWithoutChangingModelFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchProvenanceStore(root: root)
        let id = UUID()
        func reply(_ library: String, attachment: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ok": true, "liveSelection": [
                "text": "Verified paper text", "title": "Test PDF", "requestId": id.uuidString,
                "capture": ["method": "pdf-canvas", "tabID": "tab", "attachmentID": 42, "attachmentKey": "ABCD1234"],
                "location": ["library": library, "attachmentKey": attachment, "pageIndex": 6, "pageLabel": "iv"]]])
        }
        let capture = try ResearchZoteroSelection.decode(reply("groups/12", attachment: "ABCD1234"), status: 200, requestID: id)
        XCTAssertEqual(capture.page, "iv")
        XCTAssertEqual(capture.zoteroLocation?.url?.absoluteString, "zotero://open-pdf/groups/12/items/ABCD1234?page=7")
        XCTAssertFalse(capture.fields.values.contains(where: { $0.contains("ABCD1234") || $0.contains("groups/12") }))
        for (library, attachment) in [("groups/+12", "ABCD1234"), ("groups/12", "WRONG123")] {
            XCTAssertNil(try ResearchZoteroSelection.decode(reply(library, attachment: attachment), status: 200, requestID: id).zoteroLocation)
        }
        try store.savePendingSelection(capture, for: "pending")
        XCTAssertEqual(store.pendingSelection("pending")?.zoteroLocation, capture.zoteroLocation)
        let background = ResearchMaterial(source: "PDF 文件", title: "Other paper", text: "Background", scope: "Excerpt")
        let combined = try capture.withBackgroundEvidence(background)
        try store.record(session: "session", requestID: "request", material: combined)
        let material = ResearchSourceMaterial(key: "inline:digest", title: combined.title, text: combined.text,
                                              source: combined.source, scope: combined.scope, url: nil, pageLabel: nil, pageIndex: nil)
        let context = ResearchReplyContext(question: "Explain", questionId: "q", requestId: "request", time: nil, material: material)
        let answer = ResearchChatMessage(id: "answer", role: "assistant", text: "Answer", originalPrompt: nil, reply: context)
        let source = ResearchAnswerSource(session: "session", answer: answer, store: store, includePositions: false)
        XCTAssertEqual(source.zoteroURL, capture.zoteroLocation?.url)
        XCTAssertEqual(source.sourcePresentation?.page, "PDF 文件第 7 页")
        XCTAssertTrue(source.sourcePresentation?.details.contains("阅读器页标签 iv") == true)
    }

    func testBrowserReuseRequiresTheExactVerifiedDestination() {
        let destination = URL(string: "https://example.org/paper.pdf?edition=2#page=7")!
        XCTAssertTrue(ResearchBrowserNavigation.isExactPage(destination.absoluteString, destination))
        for candidate in ["example.org/paper.pdf?edition=2#page=7", "http://example.org/paper.pdf?edition=2#page=7",
                          "https://example.org/paper.pdf?edition=1#page=7", "https://example.org/paper.pdf?edition=2#page=8",
                          "https://user:secret@example.org/paper.pdf?edition=2#page=7", "https://example.org/paper.pdf?edition=2"] {
            XCTAssertFalse(ResearchBrowserNavigation.isExactPage(candidate, destination))
        }
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

    func testBrowserCapturePreservesSelectedBytesAndKeepsNavigationDetailsLocal() throws {
        let body = "原文 α₁ — 逐字匹配\r\n保留空格  "
        let destination = try XCTUnwrap(URL(string: "https://example.net/page?edition=2#figure-1"))
        let capture = try ResearchSelectionCapture.exactSelection(body, source: "Safari", title: "实际网页", webURL: destination)
        XCTAssertEqual(Array(capture.text.utf8), Array(body.utf8))
        XCTAssertEqual(capture.fields["text"], body)
        XCTAssertEqual(capture.fields["url"], "https://example.net/page")
        XCTAssertEqual(capture.localWebURL, destination.absoluteString)

        let largeBody = String(repeating: "a", count: ResearchMaterial.maximumLength + 1)
        let long = try ResearchSelectionCapture.exactSelection(largeBody, source: "Safari", title: "完整选区")
        XCTAssertTrue(long.selectionIsComplete)
        XCTAssertEqual(Array(long.text.utf8), Array(largeBody.utf8))
    }

    @MainActor
    func testUnboundSystemServicePreservesSelectedBytesWithoutInferringDestination() async throws {
        let body = "原文 α₁ — 逐字匹配\r\n保留空格  "
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertThrowsError(try ResearchSelectionCapture.serviceSelectionText(from: board))
        board.clearContents()
        XCTAssertTrue(board.setString(body, forType: .string))
        let revision = board.changeCount
        let text = try ResearchSelectionCapture.serviceSelectionText(from: board)
        let service = try ResearchSelectionCapture.exactSelection(text, source: ResearchMaterial.selectionServiceSource,
                                                                  title: "正文已取得 · 出处未确认")
        XCTAssertEqual(service.source, "系统服务")
        XCTAssertNil(service.url)
        XCTAssertNil(service.localWebURL)
        XCTAssertEqual(Array(service.text.utf8), Array(body.utf8))
        XCTAssertEqual(board.changeCount, revision)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchProvenanceStore(root: root)
        try store.record(session: "session", requestID: "service", material: service)
        let evidence = ResearchSourceMaterial(key: "inline:fixture", title: service.title, text: service.text,
                                              source: service.source, scope: service.scope, url: nil,
                                              pageLabel: nil, pageIndex: nil)
        let reply = ResearchReplyContext(question: "Explain", questionId: "q", requestId: "service",
                                         time: nil, material: evidence)
        let answer = ResearchChatMessage(id: "reply", role: "assistant", text: "[Suggested link](https://example.invalid/model)",
                                         originalPrompt: nil, reply: reply)
        let source = ResearchAnswerSource(session: "session", answer: answer, store: store)
        XCTAssertNil(source.directTarget)
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
