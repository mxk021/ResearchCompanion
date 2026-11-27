import Foundation

/// Interpret the question independently of the evidence that happens to be indexed.
struct ResearchPDFRequest: Sendable {
    struct Output: Sendable {
        enum Action: Equatable, Sendable { case answer, translate, quote, explain, compare }
        enum Unit: Equatable, Sendable { case passage, paragraph, sentence, word }
        let action: Action
        let language: String?
        let unit: Unit
        let captionOnly: Bool
        let preserveFormulae: Bool
    }

    struct Symbol: Sendable {
        let printed: String
        /// Name used in author definitions, without punctuation or function arguments.
        let name: String
    }

    let question: String
    let address: ResearchPDFAddress
    let objects: [ResearchPDFObjectID]
    let untypedObjects: [ResearchPDFObjectID]
    let algorithmMentions: [String]
    let symbolRequirements: [Symbol]
    let requiresObjectRelationship: Bool
    let requiresProseDefinitions: Bool
    let requestsAdjacentDefinitions: Bool
    let requiresExactEvidence: Bool
    let allowsPartialEvidence: Bool
    let output: Output

    var requestedSymbols: [String] { symbolRequirements.map(\.name) }

    init(_ question: String, address parsedAddress: ResearchPDFAddress? = nil, includingUserImages: Bool = false) {
        self.question = question
        let address = parsedAddress ?? ResearchPDFAddress.parse(question)
        self.address = address
        let requested = Self.outsidePassage(question, address: address)
        let instruction = includingUserImages ? Self.documentInstruction(requested) : requested
        let outputInstruction = instruction.replacingOccurrences(
            of: #"(?i)(?:不(?:用|要|需要|必)|无需)\s*(?:逐字)?\s*(?:精确引用|准确引用|引用原文|翻译|摘录|照录)|\b(?:do not|don't|no need to)\s+(?:translate|quote|transcribe)\b"#,
            with: "", options: .regularExpression)
        objects = address.addressesPassage ? [] : ResearchPDFObjectID.addresses(in: instruction)
        untypedObjects = address.addressesPassage || !objects.isEmpty
            ? [] : ResearchPDFObjectID.untypedEquationList(in: instruction)
        algorithmMentions = address.addressesPassage ? [] : Self.algorithms(in: instruction)
        let definesSymbols = Self.matches(#"是什么|什么量|是指|含义|代表什么|表示什么|定义|起什么作用|作用在哪|怎么设定|如何设定|各自的作用|解释.{0,7}(?:变量|符号|参数)|\b(?:denote(?:s)?|represent(?:s)?|definition|defined|what does|what is|explain (?:the )?(?:variable|symbol|parameter))\b"#,
                                          instruction)
        symbolRequirements = definesSymbols ? Self.symbols(in: instruction) : []
        requestsAdjacentDefinitions = definesSymbols && Self.matches(
            #"跨页|前后页|下一页|上一页|相邻页|\bacross\s+pages\b|\b(?:previous|next)\s+page\b"#,
            instruction)
        requiresProseDefinitions = definesSymbols && Self.matches(
            #"跨页|含义|什么意思|具体指什么|物理|起什么作用|由来|作用在哪|怎么设定|如何设定|作者的?[^。！？]{0,12}(?:原话|解释|说明)|\b(?:meaning|interpretation|physical|intuition|role)\b"#,
            instruction)
        requiresObjectRelationship = (objects.count + untypedObjects.count) > 1 &&
            Self.matches(#"关系|关联|联系|对比|比较|如何结合|(?:一起|共同).{0,10}(?:说明|解释)|(?:结合|用|根据).{0,64}(?:说明|解释|为什么)|(?:为什么|如何).{0,64}(?:结合|根据)|\b(?:relat(?:e|ed|ion|ionship)|compar(?:e|ison)|connect(?:s|ion)?)\b"#,
                         instruction)

        let action: Output.Action
        if Self.matches(#"翻译|译[成为出]|翻[成为]|\b(?:translate|(?:provide|give|need|want|request) (?:a |the )?translation)\b"#, outputInstruction) { action = .translate }
        else if Self.matches(#"摘录|抄[录出写]|照录|逐字|读出|(?:摘出|提取)\s*(?:论文)?(?:原文|正文|完整文本|文字)|\b(?:quote|transcribe|verbatim|read out|extract (?:the )?(?:original|text|exact wording))\b"#, outputInstruction) { action = .quote }
        else if Self.matches(#"比较|对比|对照|\bcompar(?:e|ison)\b"#, instruction) { action = .compare }
        else if Self.matches(#"解释|说明|\bexplain\b"#, instruction) { action = .explain }
        else { action = .answer }
        let unit: Output.Unit
        if Self.matches(#"逐段|paragraph by paragraph"#, outputInstruction) { unit = .paragraph }
        else if Self.matches(#"逐句|sentence by sentence"#, outputInstruction) { unit = .sentence }
        else if Self.matches(#"逐字|word for word"#, outputInstruction) { unit = .word }
        else { unit = .passage }
        let caption = Self.matches(#"图注|\bcaption(?:s)?\b"#, instruction)
        let limitsCaption = Self.matches(#"(?:只|仅)(?:需|要)?[^。!?]{0,28}图注|\b(?:caption\s+only|(?:only|just)\s+(?:the\s+)?caption)\b|^\s*(?:图注|caption)[。.!]?\s*$"#,
                                         instruction)
        let asksForGraphic = Self.matches(#"原图|整图(?!注)|图内|图像|图片|示意图|(?:展示|给出|包含|附上|和|与|及)\s*(?:各|所有|每个|全部)?\s*子图|\b(?:image|pixels?)\b|\b(?:show|include|with|and)\s+(?:all|the|each)?\s*panels?\b"#,
                                         instruction)
        let language = action == .translate ? ResearchPDFAddress.captures(
            #"(?:成|为|into\s+|in\s+)(简体中文|繁体中文|中文|汉语|英文|英语|日语|法语|德语|Chinese|English)"#,
            in: instruction)?[1] : nil
        output = Output(action: action, language: language, unit: unit,
            captionOnly: !address.addressesPassage && caption &&
                (limitsCaption || !asksForGraphic && (action == .quote || action == .translate)),
            preserveFormulae: Self.matches(#"(?:保留|包含|包括)[^。！？]{0,12}(?:公式|原式)|(?:公式|原式)[^。！？]{0,8}(?:保留|也要)|\b(?:include|preserve)\s+(?:the\s+)?(?:equations?|formulae|formulas)\b"#, instruction))
        let requestsVerbatimLocation: Bool
        if case .quotation = address { requestsVerbatimLocation = true }
        else { requestsVerbatimLocation = false }
        requiresExactEvidence = action == .translate || action == .quote || unit == .word ||
            requestsVerbatimLocation || Self.matches(
                #"必须完整|完整(?:原文|正文|原式)|不得遗漏|不遗漏|不增不减|精确引用|准确引用|只(?:给|要|看)原文|原文引用|原样(?:给出|输出|照录)|(?:列出|写出|给出|展示|保留)\s*(?:其|该|(?:[两多\d]+条)|(?:公式|方程)[^。！？]{0,12}的?)?原式|(?:只|仅)(?:能|可)?(?:根据|依据|使用|引用|参考)[^。！？]{0,12}(?:论文|本文|PDF|原文)|\b(?:without omissions|word for word|exact wording|original wording|(?:show|copy|give|preserve) (?:the )?original (?:equation|formula)|(?:only|solely) (?:use|rely on|based on) (?:the )?(?:paper|document|pdf|original text))\b"#,
                outputInstruction)
        // Precise addressing keeps stronger extraction checks. Submission
        // can still use other sources when the user requests discussion.
        allowsPartialEvidence = !requiresExactEvidence && unit == .passage &&
            !address.addressesPassage && objects.isEmpty && untypedObjects.isEmpty && !definesSymbols &&
            ResearchPDFAddress.paragraphs(in: instruction) == nil &&
            ResearchPDFAddress.explicitSection(instruction) == nil && !Self.matches(ResearchPDFAddress.columns, instruction) &&
            !Self.matches(#"不要(?:总结|分析)|无需(?:总结|分析)|必须完整|不得遗漏|不遗漏|逐页|逐条|精确引用|准确引用|只(?:给|要|看)原文|原文引用|公式|原式|方程|算式|推导|变量|正则式|等式|不等式|定理|引理|\b(?:do not|don.t)\s+(?:summari[sz]e|analy[sz]e)\b|\b(?:formulae?|formulas|equations?|derivations?|variables?|theorems?|lemmas?|proof|verbatim|without omissions)\b"#,
                          instruction)

    }

    /// A general search can supply useful excerpts without authenticating the
    /// definition of a named symbol. Carry that gap through to the packet.
    func requiringDefinitions(in evidence: ResearchMaterial) -> ResearchMaterial {
        guard !symbolRequirements.isEmpty,
              evidence.evidenceChecks?.contains(where: { $0.kind == .definition }) != true else { return evidence }
        var checked = evidence
        let labels = symbolRequirements.prefix(12).map { $0.printed + " 的定义" }
        checked.evidenceChecks = (evidence.evidenceChecks ?? []) + labels.map {
            .init(kind: .definition, target: $0, status: .missing)
        }
        checked.scope += " · 具名符号定义未核实"
        let warning = "\n\n未将以下符号与作者原文定义可靠关联：" + labels.joined(separator: "、") + "。"
        if checked.text.utf16.count + warning.utf16.count <= ResearchMaterial.maximumLength { checked.text += warning }
        return checked
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        ResearchPDFAddress.captures(pattern, in: text) != nil
    }

    // Algorithms are searchable text labels. The visual object index does not
    // attest that a mention or an adjacent passage is complete pseudocode.
    private static let algorithm = try! NSRegularExpression(
        pattern: #"(?:\balgorithm\s+|算法\s*)[(（]?\s*(\d+(?:[.-]\d+)*[a-z]?)(?![\p{Latin}\d])"#,
        options: .caseInsensitive)

    static func algorithms(in text: String) -> [String] {
        var labels: [String] = []
        for hit in algorithm.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let number = Range(hit.range(at: 1), in: text) else { continue }
            let label = "Algorithm " + text[number].lowercased()
            if !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    private static func documentInstruction(_ instruction: String) -> String {
        // A standalone instruction about a user's picture cannot set the
        // precision required of the PDF text. Mixed or ambiguous clauses keep
        // the original checks, and the model still receives the full question.
        let separated = instruction.replacingOccurrences(of: #"(?<=\.)\s+(?=[A-Z])"#, with: "\n", options: .regularExpression)
        let clauses = separated.split { "。！!？?；;\n".contains($0) }
        let document = clauses.map(String.init).filter { clause in
            let userImage = matches(#"用户(?:提供的?|附加的?)?(?:附图|图片|图像|截屏|截图)|(?:本轮|随附|上传|附加|提供)(?:的|过的)?(?:附图|图片|图像|截屏|截图)|\b(?:attached|uploaded|user[- ]provided)\s+(?:images?|photos?|pictures?|screenshots?)\b"#, clause)
            let otherSource = matches(#"原文|论文|本文|文献|文档|文件|选区|页码|第\s*\d+\s*页|\b(?:PDF|paper|document|excerpt|selection|source\s+text|pages?\s*\d+)\b"#, clause)
            return !userImage || otherSource
        }
        if document.isEmpty || document.count == clauses.count { return instruction }
        return document.joined(separator: "\n")
    }

    private static func outsidePassage(_ question: String, address: ResearchPDFAddress) -> String {
        switch address {
        case let .anchors(range):
            let anchors = range.first
            guard anchors.complete, let first = question.range(of: anchors.start, options: .literal),
                  let last = question.range(of: anchors.end, options: .literal, range: first.upperBound..<question.endIndex)
            else { return range.prefix }
            return String(question[..<first.lowerBound]) + " " + String(question[first.upperBound..<last.lowerBound]) +
                " " + String(question[last.upperBound...])
        case let .quotation(excerpt):
            guard address.addressesPassage, let r = question.range(of: excerpt, options: .literal) else { return question }
            return String(question[..<r.lowerBound]) + " " + String(question[r.upperBound...])
        default: return question
        }
    }

    private static let notation = try! NSRegularExpression(pattern:
        #"(?<![\p{Latin}\p{Greek}\p{N}_])([\p{Latin}\p{Greek}])(?:_\{?([\p{Latin}\p{Greek}\p{N}]+)(?:,[\p{Latin}\p{Greek}\p{N}]+)?\}?|([\p{Greek}\p{N}]+|[a-z]))?(?:\^\{?[\p{Latin}\p{Greek}\p{N}+-]+\}?)?[∗*′]*(?:\([\p{Latin}\p{Greek}\p{N}, ]{1,12}\))?(?![\p{Latin}\p{Greek}\p{N}_])"#)
    private static let ordinaryWords: Set<String> = [
        "am", "an", "as", "at", "be", "by", "do", "eq", "go", "he", "if", "in", "is", "it",
        "me", "my", "no", "of", "on", "or", "so", "to", "up", "us", "we"
    ]

    private static func symbols(in question: String) -> [Symbol] {
        let text = question.precomposedStringWithCompatibilityMapping as NSString
        let scope = NSRange(location: 0, length: text.length)
        var seen = Set<String>()
        return notation.matches(in: text as String, range: scope).compactMap { match in
            let printed = text.substring(with: match.range)
            let base = text.substring(with: match.range(at: 1))
            // Ordinary English articles are not mathematical notation.
            // An explicit “variable a” or quoted identifier still counts.
            if printed == base, ["a", "A", "I"].contains(base) {
                let prefix = text.substring(to: match.range.location)
                let suffix = text.substring(from: NSMaxRange(match.range))
                if !Self.matches(#"(?:变量|符号|variable|symbol|[（('\x60“「])\s*$"#, prefix),
                   Self.matches(#"^\s+[a-z][a-z]{1,}\b"#, suffix) { return nil }
            }
            let subscriptText = [2, 3].first { match.range(at: $0).location != NSNotFound }
                .map { text.substring(with: match.range(at: $0)) } ?? ""
            let name = base + subscriptText
            if name == printed, ordinaryWords.contains(name.lowercased()) { return nil }
            guard seen.insert(name).inserted else { return nil }
            return Symbol(printed: printed, name: name)
        }
    }
}

struct ResearchPDFAnchors: Equatable, Sendable {
    let start: String
    let end: String

    var complete: Bool { !start.isEmpty && !end.isEmpty }

    func updatingQuestion(_ question: String, from original: Self) -> String {
        guard self != original else { return question }
        if original.complete,
           let a = question.range(of: original.start, options: .literal),
           let b = question.range(of: original.end, options: .literal, range: a.upperBound..<question.endIndex),
           question.range(of: original.start, options: .literal, range: a.upperBound..<b.lowerBound) == nil,
           question.range(of: original.end, options: .literal, range: b.upperBound..<question.endIndex) == nil {
            let rewritten = String(question[..<a.lowerBound]) + start + String(question[a.upperBound..<b.lowerBound]) +
                end + String(question[b.upperBound...])
            if case .anchors(let range) = ResearchPDFAddress.parse(rewritten), range.endpoints.contains(self) {
                return rewritten
            }
        }
        return question + "\n\n【用户已校正并核验的范围】起点：「" + start + "」；终点：「" + end +
            "」。此前问题中的起止短句以本段为准。按原要求处理随附的已核验原文。"
    }
}

/// Recognizes user-facing document addresses before relevance retrieval is considered.
enum ResearchPDFAddress: Sendable {
    struct RangeRequest: Sendable {
        let endpoints: [ResearchPDFAnchors]
        let prefix: String
        let includeStart: Bool
        let includeEnd: Bool
        let includeCaptions: Bool
        let separatorLimitExceeded: Bool

        var first: ResearchPDFAnchors { endpoints.first ?? .init(start: "", end: "") }
    }

    case anchors(RangeRequest), quotation(String)
    case location(paragraphs: Bool), none

    /// A reference in the quoted prose is not a request to open that figure.
    var addressesPassage: Bool {
        switch self {
        case .anchors: return true
        case .quotation(let excerpt): return ResearchPDFObjectID.addresses(in: excerpt).isEmpty
        case .location(let paragraphs): return paragraphs
        case .none: return false
        }
    }

    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static let number = #"[0-9]+|[零〇一二两三四五六七八九十百千]+"#
    static let pagePattern = #"(?:第\s*)?((?:"# + number + #")(?:\s*(?:[-–—至到、,，和与及])\s*(?:第\s*)?(?:"# + number + #"))*)\s*页|\b(?:pages?\s+|p\.\s*)([0-9]+(?:\s*(?:[-–—,]|and|to)\s*[0-9]+)*)"#
    private static let paragraphOrdinal = #"(?:第\s*("# + number + #")\s*(?:个)?(?:自然)?段)|(?:\bparagraph\s+(\d+)\b)"#
    private static let paragraphEnd = #"(?:最后|末)\s*(?:("# + number + #")\s*个?\s*)?(?:自然)?段|\blast\s+(?:(\d+|[a-z]+)\s+)?paragraphs?\b"#
    private static let paragraphStart = #"首段|(?:开头|最初|前)\s*("# + number + #")\s*个?\s*(?:自然)?段|\bfirst\s+(?:(\d+|[a-z]+)\s+)?paragraphs?\b"#
    static let columns = #"左[侧边]?栏|右[侧边]?栏|\b(?:left|right)(?:[- ]hand)?\s+column\b"#

    enum Paragraphs {
        case ordinal(Int), first(Int), last(Int)
    }

    static func paragraphs(in text: String) -> Paragraphs? {
        func count(_ match: [String]) -> Int {
            guard let value = match.dropFirst().first(where: { !$0.isEmpty }) else { return 1 }
            if let n = integer(value) { return n }
            return ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
                .firstIndex(of: value.lowercased()).map { $0 + 1 } ?? 0
        }
        if let m = captures(paragraphEnd, in: text) { return .last(count(m)) }
        if let m = captures(paragraphStart, in: text) { return .first(count(m)) }
        if let m = captures(paragraphOrdinal, in: text) { return .ordinal(count(m)) }
        return nil
    }

    static func captionRequest(in text: String) -> Range<String.Index>? {
        text.range(of: #"(?:[,，;；]\s*|\s+)(?:(?:并|同时|也|连同)\s*(?:翻译|包含|包括|带上)?\s*(?:中间的?)?(?:图(?:表)?注|图题)|(?:and\s+)?includ(?:e|ing) (?:the )?(?:figure )?captions?)\s*[。！？.!?]?\s*$"#,
                   options: [.regularExpression, .caseInsensitive])
    }

    private static let quoted = #"(?:“([^”]*)”|「([^」]*)」|『([^』]*)』|‘([^’]*)’|"([^"]*)"|'([^']*)')"#
    private static let command = #"(?:翻译|译出|提取|摘[录出]|抄[录出]|照录|逐句解释)"#
    private static let chineseDelimiter = #"(?:截止到|截至|直到|读到|译到|至|到)"#
    private static let openingMarker = #"(?:开头|起头|为起点|开始|起读|起)"#
    private static let closingMarker = #"(?:为终点|结束|为止|结尾)"#
    private static let punctuation = #"[、，,；;]"#
    private static let scopeNoun = #"(?:正文|原文|文本|内容|文字|段落|部分|范围)"#
    private static let scopeQuantity = #"(?:(?:全部|完整|所有|整段|整个)\s*)*"#
    private static let layoutScope = #"(?:(?:跨页|跨栏|跨段|连续)\s*)*"#
    // Bare 自 is also a productive prefix in nouns such as 自注意力. Accept it
    // as an introducer at a clause boundary or before a delimited excerpt.
    private static let from = #"(?:从|(?<![\p{L}\p{N}])自|自(?=[\s\p{Latin}\p{N}“「『"']))"#

    static func parse(_ input: String) -> Self {
        let options = endpointOptions(input)
        let trailing = rangeClauses(options.question)
        let structural = trailing.body
        let q = structural.trimmingCharacters(in: .whitespacesAndNewlines)
        func range(_ prefix: String, _ endpoints: [ResearchPDFAnchors], limited: Bool = false) -> Self {
            .anchors(.init(endpoints: endpoints, prefix: prefix, includeStart: options.includeStart,
                          includeEnd: options.includeEnd, includeCaptions: trailing.includeCaptions, separatorLimitExceeded: limited))
        }
        func quotedRange(_ match: [String]) -> Self {
            range(match[1], [.init(start: match[2...7].first { !$0.isEmpty } ?? "",
                                  end: match[8...13].first { !$0.isEmpty } ?? "")])
        }
        // Complete quoted endpoints are copied verbatim, including terminal punctuation.
        let connector = #"(?:(?:一直\s*)?"# + chineseDelimiter + #"|\b(?:to|through)\b)"#
        if let match = captures(#"^(.*?)(?:从|自|\bfrom\b)\s*"# + quoted + #"\s*"# + connector + #"\s*"# + quoted, in: q) {
            return quotedRange(match)
        }
        if let match = captures(#"^(.*?)"# + command + #"\s*"# + quoted + #"\s*"# + chineseDelimiter + #"\s*"# + quoted, in: q) {
            return quotedRange(match)
        }
        // “Only the complete caption” makes the numbered object the scope.
        // A following description of its start or end is not a verbatim address.
        if let object = captures(#"^(.*?(?:只|仅)(?:需|要|看|取)?[^。!?！？]{0,48}图注)(?=[，,；;：:]|\s|$)"#, in: q),
           !ResearchPDFObjectID.addresses(in: object[1]).isEmpty { return .none }
        // Two unquoted foreign excerpts can omit 从. Their script boundary also
        // distinguishes a Chinese instruction outside a source-language phrase.
        let foreign = #"([\p{Latin}\p{Greek}\p{N}][\p{Latin}\p{Greek}\p{M}\p{N}\s_\-–−'’(),./:;·!?]*?)"#
        let markedTransition = #"(?:\s*"# + punctuation + #"\s*(?:"# + chineseDelimiter +
            #")?|\s*"# + chineseDelimiter + #")\s*"#
        // Opening and closing markers can do the work of an omitted 到. A
        // punctuation-delimited foreign opening followed by an explicit 到 is
        // also a range, even if the caller omits 从 and names no ending marker.
        if let match = captures(#"^(.*?)(?:以|由|从|自|(?:把|将)(?!\s*[以由从自]))\s*(.+?)\s*"# + openingMarker + markedTransition +
                                #"(?:一直\s*)?(.+?)\s*"# + closingMarker, in: q) ??
            captures(#"^(.*?)"# + foreign + #"\s*"# + openingMarker + #"\s*"# + punctuation +
                     #"\s*"# + chineseDelimiter + #"\s*(.+)$"#, in: q) {
            return range(match[1], [endpoints(match[2], match[3])])
        }
        if let match = captures(#"^(.*?)"# + command + #"\s*"# + foreign + #"\s*"# + chineseDelimiter + #"\s*"# + foreign
                            + #"\s*(?:之间)?(?:的\s*"# + scopeQuantity + scopeNoun + #")?\s*[。！？!?]?\s*$"#, in: q) {
            return range(match[1], [endpoints(match[2], match[3])])
        }
        if let match = captures(#"^(.*?)\b(?:beginning|starting) (?:with|at)\s+(.+?)\s*[,;]?\s*(?:and\s+)?ending (?:with|at)\s+(.+)$"#, in: q) {
            return range(match[1], [endpoints(match[2], match[3])])
        }
        let isPageToPage = captures(#"(?:从|自)\s*第?(?:"# + number + #")\s*页?\s*(?:至|到)\s*第?(?:"# + number + #")\s*页|\bfrom\s+page\s+\d+\s+(?:to|through)\s+page\s+\d+"#, in: q) != nil
        if !isPageToPage {
            if let match = captures(#"^(.*?)(?:"# + from + #"|以|由)\s*(.+?)\s*(?:"# + openingMarker +
                #")?\s*(?:"# + punctuation + #")?\s*(?:一直\s*)?"# + chineseDelimiter + #"\s*(.+)$"#, in: q),
               !cleanEnd(match[3]).isEmpty {
                let cleaned = endpoints(match[2], match[3])
                // A named object's extent can be described by its stages or
                // sentence order. These descriptions are not verbatim anchors.
                // Explicitly quoted endpoints have already been handled above.
                let named = ResearchPDFObjectID.addresses(in: match[1])
                if !named.isEmpty {
                    let structuralEnd = captures(#"(?:的(?:完整|整体)?(?:结构|流程|过程|步骤|关系)|(?:首句|末句|第一句|最后一句))\s*[。！？!?]?$"#, in: cleaned.end) != nil
                    let formulaEnd = named.contains { $0.kind == .equation } &&
                        captures(#"的\s*完整(?:算式|公式|方程|等式|数学表达式)(?:\s*(?:及|和|与)\s*(?:编号|序号))?\s*[。！？!?]?$"#,
                                 in: cleaned.end) != nil
                    if structuralEnd || formulaEnd { return .none }
                }
                let literal = ResearchPDFAnchors(start: cleaned.start, end: unwrapped(match[3])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?")))
                // A simple trailing “的内容” can also be literal Chinese source
                // text. Keep it as a local fallback if the operation reading fails.
                let couldBeSource = cleaned.end.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                let choices = cleaned == literal || !couldBeSource ? [cleaned] : [cleaned, literal]
                return range(match[1], choices)
            }
            if let match = captures(#"^(.*?)\bfrom\b\s+(.+)$"#, in: q),
               let divider = try? NSRegularExpression(pattern: #"\s+(?:to|through)\s+"#, options: [.caseInsensitive]) {
                let body = match[2]
                let splits = divider.matches(in: body, range: NSRange(body.startIndex..., in: body))
                if splits.count > 12 { return range(match[1], [], limited: true) }
                let choices = splits.compactMap { split -> ResearchPDFAnchors? in
                    guard let position = Range(split.range, in: body) else { return nil }
                    return endpoints(String(body[..<position.lowerBound]), String(body[position.upperBound...]))
                }
                if !choices.isEmpty { return range(match[1], choices) }
            }
            // With no ending excerpt there is no second anchor to corroborate
            // ambiguous compounds starting with 自. Require a delimited start.
            if let match = captures(#"^(.*?)(?:从|自(?=[\s\p{Latin}\p{N}“「『"']))\s*(.*?)\s*(?:直到|至|到)\s*[。！？!?]?$|^(.*?)\bfrom\s+(.*?)\s+(?:to|through)\s*[.!?]?$"#, in: q) {
                return range(match[1].isEmpty ? match[3] : match[1], [endpoints(match[2].isEmpty ? match[4] : match[2], "")])
            }
        }
        if let match = captures(#"^(.*?)(?:^|(?<=[\p{Han}：:，,]))\s*"# + foreign + #"\s*"# + chineseDelimiter + #"\s*"# + foreign
                            + #"\s*[。.,，；;：:\s]*这(?:一)?(?:整段|段落|段|部分)(?:的)?(?:内容|原文|文字)?\s*(?:请|帮我)?(?:完整|全部)?(?:翻译|译成|译为|译出|翻成|翻为)"#,
                                in: options.question) {
            return range(match[1], [endpoints(match[2], match[3])])
        }
        if let match = captures(#"(?:定位|查找|找到|搜索|检索|寻找|翻译|\b(?:locate|find|search for|translate)\s*)\s*"# + quoted, in: structural) {
            return .quotation(match.dropFirst().first { !$0.isEmpty } ?? "")
        }
        let namesParagraphs = paragraphs(in: structural) != nil
        if namesParagraphs || captures(pagePattern + "|" + columns +
            #"|最后一页|末页|尾页|首页|中间页|\b(?:last|first|middle|final) page\b|第\s*(?:"# + number +
            #")(?:[.]\d+)*\s*[节章]|\b(?:section|chapter)\s+\d"#, in: structural) != nil || explicitSection(structural) != nil {
            return .location(paragraphs: namesParagraphs)
        }
        return .none
    }

    /// Consume only complete output clauses at a real clause boundary. Actual anchor
    /// words stay untouched; the original question continues to carry output instructions.
    private static func rangeClauses(_ text: String) -> (body: String, includeCaptions: Bool) {
        let boundary = #"\s*(?:[,，；;、]\s*|\s+|(?<=[\p{Latin}\p{Greek}\p{N})\].:：”」』]))"#
        let modifiers = #"(?:(?:逐段|逐句|逐字|连贯|连续|跨页|跨栏|跨段|完整|全部|所有|整段|整个)\s*)*"#
        let target = #"(?:简体中文|繁体中文|中文|汉语|英文|英语|日语|法语|德语|Chinese|English)"#
        let action = #"(?:(?:翻译|翻|译)\s*(?:成|为)\s*"# + target +
            #"|(?:翻译|译|抄|摘|取|读)(?:出|录|出来)|翻译|提取|照录|逐句解释)"#
        let noun = #"(?:(?:中间|连续|跨页|跨栏|跨段|完整|全部|整段|定义)\s*)*"# + scopeNoun
        let reference = #"(?:这(?:一)?(?:整段|段落|段|部分)|这个范围|起止点之间|两端之间|这两处之间|这两个位置之间)"#
        let material = "(?:" + reference + #"(?:\s*(?:的\s*)?"# + noun + ")?|" + noun + ")"
        let polite = #"(?:(?:请|帮我|把|将|只|仅)\s*)*"#
        let object = #"(?:该|相邻|独立|中间|原文中的?|浮动|跨页部分(?:以及|和|与))?\s*(?:的\s*)?(?:(?:浮动)?图(?:表)?的?\s*(?:图注|表注|说明)|图表注释|图(?:表)?注|图题|表注|脚注|页眉|页脚|中间公式|公式|原式|跨页部分)"#
        let policy = #"(?:并|也|同时|连同)?\s*(?:(?:一并|都|也)?\s*(?:保留|包含|包括|带上)|(?:不|不要|不用)\s*(?:混入|放入|包含|包括|保留)|排除|略去|去掉)"#
        let directive = "(?:" + object + #"\s*"# + policy + "|" + policy + #"\s*"# + object + ")"
        let perform = "(?:" + polite + modifiers + "(?:" + material + #"\s*"# + polite + modifiers + ")?" +
            action + #"\s*(?:"# + material + #")?|(?:请\s*)?(?:只|仅)\s*(?:取|读|保留)\s*"# + material + ")"
        let afterRange = #"(?:的\s*"# + material + #"\s*"# + polite + modifiers + action + "|" +
            boundary + perform + "|" + boundary + directive + ")"
        let english = #"\s*[,;]\s*(?:please\s+)?(?:(?:translate|render)\s+(?:the (?:passage|text)|it)\s+(?:into|in)\s+(?:Chinese|English)|(?:paragraph|sentence)\s+by\s+(?:paragraph|sentence)|(?:omit|exclude)\s+(?:the\s+)?(?:captions?|footnotes?))"#
        let suffix = #"^(.*?)(?:"# + afterRange + "|" + english + #")[。！？.!?]*\s*$"#
        var body = text
        var includeCaptions = false
        var excludeCaptions = false
        for _ in 0..<4 {
            if let caption = captionRequest(in: body) {
                includeCaptions = true
                body = String(body[..<caption.lowerBound])
            } else if let match = captures(suffix, in: body), !match[1].isEmpty,
                      match[1].utf16.count < body.utf16.count {
                let tail = String(body.dropFirst(match[1].count))
                if captures(#"(?:图注|图的说明|图的图注|图表注释|caption)"#, in: tail) != nil {
                    excludeCaptions = excludeCaptions || captures(#"不要|不用|不混入|不包含|排除|略去|去掉|exclude|omit"#, in: tail) != nil
                }
                body = match[1]
            } else { break }
        }
        return (body, includeCaptions && !excludeCaptions)
    }

    private static func endpoints(_ start: String, _ end: String) -> ResearchPDFAnchors {
        .init(start: unwrapped(start), end: cleanEnd(end))
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

    private static func cleanEnd(_ text: String) -> String {
        let instruction = #"(?:[，,]?\s*(?:之间|为止|结束处|开头)?\s*的\s*|\s+)(?:(?:这部分|这一段)\s*)?"# +
            layoutScope + scopeQuantity + scopeNoun + #"(?:[，,].*)?[。！？.!?]?\s*$"#
        let value = text.replacingOccurrences(of: instruction, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = unwrapped(value)
        return literal == value ? literal.trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?")) : literal
    }

    private static func unwrapped(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』", "\"": "\"", "'": "'"]
        guard value.count >= 2, let start = value.first, let end = wrappers[start], value.last == end else { return value }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
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
            let paragraph = paragraphStart + "|" + paragraphEnd + "|" + paragraphOrdinal
            if captures("(?:" + alternatives + #")\s*(?:的\s*)?(?:"# + paragraph + ")", in: text) != nil { return section.label }
            if captures("(?:(?:" + alternatives + #")\s*(?:部分|章节|一节|小节|section)|(?:翻译|读出|提取|逐句解释|translate|read|extract)\s*(?:本文的?|论文的?|the\s+)?(?:"# + alternatives + #")\s*[。.!?？]?$)"#, in: text) != nil { return section.label }
        }
        return nil
    }

}
