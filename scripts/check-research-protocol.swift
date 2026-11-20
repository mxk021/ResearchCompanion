import Foundation

/// Standalone checks for the production Swift wire decoder. This runs on
/// Command Line Tools without requiring XCTest or granting app permissions.
@main
struct ResearchProtocolChecks {
    static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            passed += 1
            print("PASS: \(label)")
        }
        let context = try ResearchProtocol.decodeContext([
            "available": true, "key": "PAPER123", "title": "Source paper", "text": "Exact source passage.",
            "pageLabel": "iv", "source": "zotero-reader",
        ])!
        check(context.key == "PAPER123" && context.title == "Source paper", "paper identity retained")
        check(context.text == "Exact source passage." && context.pageLabel == "iv", "original selection and page retained")
        check(context.available && context.hasText && context.error == nil, "actual text is available")
        let noPaper = try ResearchProtocol.decodeContext(NSNull())
        check(noPaper == nil, "missing paper stays missing")
        let unavailable = try ResearchProtocol.decodeContext(["error": "Reader bridge unavailable"])!
        check(!unavailable.available && !unavailable.hasText && unavailable.error == "Reader bridge unavailable", "bridge failure cannot become invented context")
        let longAnswer = String(repeating: "Evidence and explanation.\n", count: 500)
        let messages = try ResearchProtocol.decodeMessages([
            ["id": "u1", "role": "user", "text": "Explain it"],
            ["id": "a1", "role": "assistant", "text": longAnswer],
        ])
        check(messages.map(\.role) == ["user", "assistant"], "conversation roles retained")
        check(messages[1].text == longAnswer && messages[1].id == "a1", "long answer is complete and identifiable")
        let empty = try ResearchProtocol.decodeMessages([])
        check(empty.isEmpty, "no messages does not create a simulated response")
        let wrappedPrompt = "Persona\n【原文】Exact quotation\n【用户问题】Explain the result"
        let wrapped = try ResearchProtocol.decodeMessages([["role": "user", "text": wrappedPrompt]])
        check(wrapped[0].text == "Explain the result" && wrapped[0].originalPrompt == wrappedPrompt,
            "user question stays readable while its original evidence remains inspectable")
        let external = "Persona\n\n【材料原文，JSON 引用数据】\n{\"text\":\"【用户问题】 这一句是原文\"}\n\n【用户问题】\n真实问题"
        let externalMessage = try ResearchProtocol.decodeMessages([["role": "user", "text": external]])[0]
        check(externalMessage.text == "真实问题" && externalMessage.originalPrompt == external,
            "marker inside material JSON cannot replace the visible question")
        do {
            _ = try ResearchProtocol.decodeMessages([["role": "tool", "text": "result"]])
            fatalError("FAIL: tool result accepted as conversation answer")
        } catch ResearchProtocolError.malformed { check(true, "tool results cannot masquerade as answers") }
        do {
            _ = try ResearchProtocol.decodeMessages([["role": "assistant", "text": 42]])
            fatalError("FAIL: invalid response accepted")
        } catch ResearchProtocolError.malformed { check(true, "invalid response fails closed") }
        print("\(passed) research protocol checks passed.")
    }
}
