import Foundation

enum ResearchProtocolError: LocalizedError {
    case malformed
    case translation(String)

    var errorDescription: String? {
        switch self {
        case .malformed: return "科研桥返回的数据格式无效。"
        case .translation(let message): return message
        }
    }
}

enum ResearchPromptMode: String {
    case ask, translate, explain
}

struct ResearchModelSelection: Hashable, Codable {
    let provider: String
    let model: String
    let reasoningEffort: String?

    var isSubscription: Bool { provider == "chatgpt" || provider == "chatgpt-sub" }

    var wire: [String: String] {
        var value = ["provider": provider, "model": model]
        if let reasoningEffort { value["reasoningEffort"] = reasoningEffort }
        return value
    }

    var signature: String { [provider, model, reasoningEffort ?? ""].joined(separator: ":") }
}

struct ResearchModelCatalog: Equatable, Decodable {
    struct Provider: Equatable, Decodable, Identifiable {
        let id: String
        let name: String
        let models: [Model]
        let error: String?
    }
    struct Model: Equatable, Decodable, Identifiable {
        struct Reasoning: Equatable, Decodable {
            struct Effort: Equatable, Decodable, Identifiable {
                let id: String
                let name: String
            }
            let efforts: [Effort]
            let defaultEffort: String?
        }
        let id: String
        let name: String
        let reasoning: Reasoning?
        var inputModalities: [String]? = nil
    }
    let groups: [Provider]
    let defaultSelection: ResearchModelSelection?

    func model(for selection: ResearchModelSelection?) -> Model? {
        guard let selection else { return nil }
        return groups.first { $0.id == selection.provider }?.models.first { $0.id == selection.model }
    }
    /// Automatic translation only uses routes published by the account-aware research bridge.
    func translation(current: ResearchModelSelection?, explicit: ResearchModelSelection?,
                     preferred: ResearchModelSelection?, hasHistory: Bool) throws -> ResearchModelSelection {
        func offered(_ pick: ResearchModelSelection) -> Bool {
            guard let group = groups.first(where: { $0.id == pick.provider }), group.error == nil,
                  let model = group.models.first(where: { $0.id == pick.model }) else { return false }
            guard let effort = pick.reasoningEffort else { return true }
            return model.reasoning?.efforts.contains(where: { $0.id == effort }) == true
        }
        if let current, current.isSubscription || (current.provider == "deepseek-account" && current == explicit) {
            guard offered(current) else { throw ResearchProtocolError.translation("当前会话模型不可用。请在模型菜单重新选择。") }
            return current
        }
        if hasHistory {
            throw ResearchProtocolError.translation("这条历史会话尚未明确选择翻译模型。请在模型菜单选择 ChatGPT 订阅，或点选 DeepSeek 表示使用该账号余额。")
        }
        for pick in [preferred, defaultSelection].compactMap({ $0 }) where pick.isSubscription && offered(pick) {
            return pick
        }
        let choices = groups.filter { $0.error == nil && ["chatgpt", "chatgpt-sub"].contains($0.id) }.flatMap { group in
            group.models.map { model in
                ResearchModelSelection(provider: group.id, model: model.id, reasoningEffort:
                    model.reasoning?.efforts.contains(where: { $0.id == "low" }) == true ? "low" : model.reasoning?.defaultEffort)
            }
        }
        if let sol = choices.first(where: { $0.model == "gpt-6.2-sol" }), offered(sol) { return sol }
        if choices.count == 1, let only = choices.first, offered(only) { return only }
        throw ResearchProtocolError.translation("无法确定可用的订阅翻译模型。请在会话模型菜单选择 ChatGPT 订阅。")
    }

}

struct ResearchChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let originalPrompt: String?
    var reply: ResearchReplyContext? = nil
}

/// Decode only the user/assistant projection supplied by the local DSH bridge.
/// A missing/invalid response is an error, never a synthetic model answer.
enum ResearchProtocol {
    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func decodeStreamMessage(_ value: Any?) -> ResearchChatMessage? {
        guard let row = value as? [String: Any], let id = row["id"] as? String,
              row["role"] as? String == "assistant", let text = row["text"] as? String else { return nil }
        return .init(id: id, role: "assistant", text: text, originalPrompt: nil)
    }

    static func decodeMessages(_ value: Any?) throws -> [ResearchChatMessage] {
        guard let rows = value as? [[String: Any]] else { throw ResearchProtocolError.malformed }
        return try rows.enumerated().map { index, row in
            guard let role = row["role"] as? String, ["user", "assistant"].contains(role),
                  let text = row["text"] as? String else { throw ResearchProtocolError.malformed }
            // The JSON excerpt can itself contain the marker as ordinary text.
            // A raw newline-delimited marker can only be emitted by the bridge.
            let question = role == "user" && row["plainQuestion"] as? Bool != true ? (
                text.range(of: "\n\n【用户问题】\n") ??
                    (text.contains("\n【原文】") ? text.range(of: "\n【用户问题】") : nil)
            ) : nil
            let display = question.map { String(text[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? text
            return ResearchChatMessage(id: row["id"] as? String ?? "\(index)-\(role)", role: role,
                text: display, originalPrompt: question == nil ? nil : text,
                reply: role == "assistant" ? decode(ResearchReplyContext.self, from: row["reply"]) : nil)
        }
    }
}

