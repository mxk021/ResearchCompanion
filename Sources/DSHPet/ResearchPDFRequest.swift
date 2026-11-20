import Foundation

/// Recognizes user-facing document addresses before relevance retrieval is considered.
enum ResearchPDFAddress {
    case anchors(String, String), quotation(String)
    case location, none

    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static let number = #"[0-9]+|[零〇一二两三四五六七八九十百千]+"#
    static let pagePattern = #"(?:第\s*)?((?:"# + number + #")(?:\s*(?:[-–—至到、,，和与及])\s*(?:第\s*)?(?:"# + number + #"))*)\s*页|\b(?:pages?\s+|p\.\s*)([0-9]+(?:\s*(?:[-–—,]|and|to)\s*[0-9]+)*)"#
    static let paragraphPattern = #"(?:第\s*("# + number + #")\s*(?:个)?(?:自然)?段)|(?:paragraph\s+(\d+))"#
    static let lastParagraph = #"最后(?:一|1|一个|1个)?(?:自然)?段|末段|\blast paragraph\b"#
    static let firstParagraph = #"首段|\bfirst paragraph\b"#
    static let columns = #"左[侧边]?栏|右[侧边]?栏|\b(?:left|right)(?:[- ]hand)?\s+column\b"#

    static func parse(_ input: String) -> Self {
        let q = endpointOptions(input).question.trimmingCharacters(in: .whitespacesAndNewlines)
        // Explicitly quoted endpoints keep punctuation inside the quotes.
        let quoted = #"(?:“([^”]*)”|「([^」]*)」|『([^』]*)』|‘([^’]*)’|"([^"]*)"|'([^']*)')"#
        if let m = captures(#"(?:从|自|\bfrom)\s*"# + quoted + #"\s*(?:至|到|直到|\bto\b|\bthrough\b)\s*"# + quoted, in: q) {
            return .anchors(m[1...6].first { !$0.isEmpty } ?? "", m[7...12].first { !$0.isEmpty } ?? "")
        }
        // Parse only explicitly marked boundaries here. Other colloquial descriptions
        // go through the current model's document planner rather than guessing words.
        // Two foreign-language excerpts separated by a Chinese range connector. At a
        // script boundary the trailing imperative is outside the unquoted document text.
        let foreign = #"([\p{Latin}\p{N}][\p{Latin}\p{M}\p{N}\s_\-–−'’(),./:;·]*?)"#
        if let m = captures(#"(?:^|[\p{Han}：:，,])\s*"# + foreign + #"\s*(?:直到|至|到)\s*"# + foreign
                            + #"\s*[。.,，；;：:\s]*这(?:一)?(?:段|部分|段落)(?:的)?(?:内容|原文|文字)?\s*(?:请|帮我)?(?:完整|全部)?(?:翻译|译成|译为|译出)"#, in: q) {
            return .anchors(clean(m[1]), clean(m[2]))
        }
        let marked = [
            #"(?:以|由)\s*(.+?)\s*(?:开头|起头|为起点|开始)[、，,；;\s]*(?:一直)?(?:直到|到|至|以)\s*(.+?)\s*(?:为终点|结束|为止|结尾)"#,
            #"\b(?:beginning|starting) (?:with|at)\s+(.+?)\s*[,;]?\s*(?:and\s+)?ending (?:with|at)\s+(.+)$"#
        ]
        for pattern in marked {
            if let m = captures(pattern, in: q) { return .anchors(clean(m[1]), clean(m[2], trailing: true)) }
        }
        let isPageToPage = captures(#"(?:从|自)\s*第?(?:"# + number + #")\s*页?\s*(?:至|到)\s*第?(?:"# + number + #")\s*页|\bfrom\s+page\s+\d+\s+to\s+page\s+\d+"#, in: q) != nil
        if !isPageToPage {
            // An unquoted Chinese request has an unambiguous delimiter even when
            // the English source phrase itself contains the word “to”.
            if let m = captures(#"(?:从|自)\s*(.+?)\s*(?:直到|到|至)\s*(.+)$"#, in: q) {
                return .anchors(clean(m[1]), clean(m[2], trailing: true))
            }
            if let m = captures(#"\bfrom\s+(.+?)\s+(?:to|through)\s+(.+)$"#, in: q) {
                return .anchors(clean(m[1]), clean(m[2], trailing: true))
            }
            if captures(#"(?:从|自)\s*.*?(?:直到|至|到)\s*[。！？!?]?$|(?:从|自)\s*(?:直到|到|至)\s*.+|\bfrom\s+.*\s+(?:to|through)\s*[.!?]?$"#, in: q) != nil {
                return .anchors("", "")
            }
        }
        if let m = captures(#"(?:定位|查找|找到|搜索|检索|寻找|翻译|\b(?:locate|find|search for|translate)\s*)\s*"# + quoted, in: q) {
            return .quotation(m.dropFirst().first { !$0.isEmpty } ?? "")
        }
        if captures(pagePattern + "|" + paragraphPattern + "|" + lastParagraph + "|" + columns +
            #"|最后一页|末页|尾页|首页|中间页|\b(?:last|first|middle|final) page\b|第\s*(?:"# + number +
            #")(?:[.]\d+)*\s*[节章]|\b(?:section|chapter)\s+\d"#, in: q) != nil || explicitSection(q) != nil {
            return .location
        }
        return .none
    }

    /// An English anchor can itself contain “to”. Test alternative delimiter
    /// positions against the local index before claiming a unique range.
    static func englishEndpoints(_ question: String) throws -> [(String, String)] {
        guard captures(#"(?:从|自).+?(?:到|至)"#, in: question) == nil,
              let m = captures(#"\bfrom\s+(.+)$"#, in: question),
              !m[1].contains(where: { "“”「」『』‘’\"".contains($0) }),
              !m[1].hasPrefix("'") else { return [] }
        let body = m[1]
        let divider = try NSRegularExpression(pattern: #"\s+(?:to|through)\s+"#, options: [.caseInsensitive])
        let matches = divider.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard matches.count > 1 else { return [] }
        guard matches.count <= 12 else { throw ResearchMaterialError.message("起止短句含多个可能的分隔词，请分别用引号标出。") }
        return matches.compactMap { match in
            guard let r = Range(match.range, in: body) else { return nil }
            return (clean(String(body[..<r.lowerBound])), clean(String(body[r.upperBound...]), trailing: true))
        }
    }

    /// A boundary exclusion is an instruction only as a separate trailing clause.
    /// Preserve punctuation and words *inside* the quoted endpoints.
    static func endpointOptions(_ question: String) -> (question: String, includeStart: Bool, includeEnd: Bool) {
        guard let parts = captures(#"^(.*?)(?:[，,；;（(]\s*)((?:不含|不包括|不包含|排除|excluding|exclude)\s*(?:起点(?:原文)?|终点(?:原文)?|两端(?:原文)?|(?:the )?(?:start|end|both endpoints?)))[）)。.!！]?\s*$"#, in: question) else {
            return (question, true, true)
        }
        let clause = parts[2].lowercased()
        let both = clause.contains("两端") || clause.contains("both")
        return (parts[1], !(both || clause.contains("起点") || clause.contains("start")),
                !(both || clause.contains("终点") || clause.contains("end")))
    }

    private static func clean(_ text: String, trailing: Bool = false) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trailing {
            // Only strip punctuation belonging to the command. A full stop inside
            // quoted anchors was already captured above.
            value = value.replacingOccurrences(of: #"(?:(?:[，,]?\s*(?:之间|为止|结束处)?\s*的\s*|\s+)(?:(?:全部|所有|整段|完整|这部分|这一段)\s*)?(?:内容|原文|文字|段落|部分))(?:[，,].*)?[。！？.!?]?\s*$"#, with: "", options: .regularExpression)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?"))
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』", "\"": "\"", "'": "'"]
        if value.count >= 2, let start = value.first, let end = wrappers[start], value.last == end {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func integer(_ text: String) -> Int? {
        if let n = Int(text) { return n }
        let digits: [Character: Int] = ["零":0, "〇":0, "一":1, "二":2, "两":2, "三":3, "四":4, "五":5, "六":6, "七":7, "八":8, "九":9]
        let units: [Character: Int] = ["十":10, "百":100, "千":1000]
        var total = 0, digit = 0
        for c in text {
            if let value = digits[c] { digit = value }
            else if let unit = units[c], total < 100_000 { total += max(1, digit) * unit; digit = 0 }
            else { return nil }
        }
        return total + digit
    }

    static let sections: [(label: String, aliases: [String])] = [
        ("abstract", ["abstract", "摘要"]), ("introduction", ["introduction", "背景", "引言", "绪论"]),
        ("methods", ["materials and methods", "methodology", "methods", "method", "方法"]),
        ("results", ["experimental results", "results", "experiments", "实验结果", "结果", "实验"]),
        ("discussion", ["discussion", "讨论"]), ("conclusion", ["conclusions", "conclusion", "结论"]),
        ("references", ["references", "bibliography", "参考文献"]), ("appendix", ["appendix", "附录"])
    ]

    static func explicitSection(_ text: String) -> String? {
        if let m = captures(#"(?:第\s*((?:"# + number + #")(?:[.]\d+)*)\s*[节章]|\b(?:section|chapter)\s+(\d+(?:[.]\d+)*))"#, in: text) {
            let value = m[1].isEmpty ? m[2] : m[1]
            return integer(value).map(String.init) ?? value
        }
        if let m = captures(#"(?:章节|小节|\bsection)\s*[\"“「](.+?)[\"”」]"#, in: text) { return m[1].lowercased() }
        if captures(#"比较|对比|对照|compare|contrast"#, in: text) != nil { return nil }
        for section in sections {
            let alternatives = section.aliases.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            if captures("(?:(?:" + alternatives + #")\s*(?:部分|章节|一节|小节|section)|(?:翻译|读出|提取|逐句解释|translate|read|extract)\s*(?:本文的?|论文的?|the\s+)?(?:"# + alternatives + #")\s*[。.!?？]?$)"#, in: text) != nil { return section.label }
        }
        return nil
    }

    func requireAnchorText() throws {
        if case let .anchors(a, b) = self, a.isEmpty || b.isEmpty {
            throw ResearchMaterialError.message("需要同时给出范围的起点和终点原文。")
        }
    }
}
