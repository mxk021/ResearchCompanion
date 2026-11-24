import Foundation

/// The bridge only selects a read. Text, file identity and coordinates are supplied by the local index.
struct ResearchDocumentPlan: Decodable {
    enum Action: String, Decodable { case range, pages, search, selection, combined, whole, clarify, useEvidence, object }
    let action: Action
    var start: String?
    var end: String?
    var pageStart: Int?
    var pageEnd: Int?
    var excludeStart: Bool?
    var excludeEnd: Bool?
    var query: String?
    var reference: String?
    var needsMore: Bool?
    var question: String?

    private static func quotedLiterals(in input: String) -> [String] {
        let pattern = #"“[^”]+”|「[^」]+」|『[^』]+』|‘[^’]+’|"[^"]+"|(?<![\p{L}\p{N}])'(?:[^'\n]|(?<=[\p{L}\p{N}])'(?=[\p{L}\p{N}]))+'(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
            Range($0.range, in: input).map { String(input[$0].dropFirst().dropLast()) }
        }
    }

    private func pageRange(in index: ResearchPDFIndex) throws -> ClosedRange<Int>? {
        guard pageStart != nil || pageEnd != nil else { return nil }
        let a = pageStart ?? 1, b = pageEnd ?? index.pages.count
        guard a >= 1, a <= b, b <= index.pages.count else {
            throw ResearchMaterialError.message("模型请求的页序超出当前 PDF。")
        }
        return a...b
    }

    func read(index: ResearchPDFIndex, question input: String, selection: ResearchMaterial?,
              requireSelection: Bool, verifiedFeedback: String? = nil, chosenRangeID: String? = nil) throws -> [ResearchMaterial] {
        try Task.checkCancellation()
        switch action {
        case .range:
            func grounded(_ anchor: String?) -> String? {
                guard let anchor, !anchor.isEmpty else { return nil }
                let quoted = [input, selection?.text ?? "", verifiedFeedback ?? ""]
                let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
                // If an endpoint comes from a literal quoted by the user, keep the entire literal.
                let literals = Self.quotedLiterals(in: input)
                if literals.contains(where: { $0.compare(anchor, options: options) == .orderedSame }) { return anchor }
                let matches = Set(literals.filter { $0.range(of: anchor, options: options) != nil })
                if !matches.isEmpty { return matches.count == 1 ? matches.first : nil }
                return quoted.contains { $0.range(of: anchor, options: options) != nil } ? anchor : nil
            }
            guard let a = grounded(start), let b = grounded(end) else {
                throw ResearchMaterialError.message("无法把两个端点与问题或本次选区中的原句核对。")
            }
            return try index.readRange(start: a, end: b, withinPages: pageRange(in: index),
                                       includeStart: excludeStart != true, includeEnd: excludeEnd != true,
                                       selectionHint: selection?.text, chosenRangeID: chosenRangeID)
        case .pages:
            guard let pages = try pageRange(in: index) else { throw ResearchMaterialError.message("缺少所请求的文件页序。") }
            let result = try index.readPages(pages)
            if requireSelection, let selection {
                guard result.count == 1 else { throw ResearchMaterialError.message("所选页段与选区合计过长，请缩小对照页段。") }
                return [try selection.withBackgroundEvidence(result[0])]
            }
            return result
        case .whole: return try index.segments()
        case .search, .combined:
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResearchMaterialError.message("模型没有给出可执行的检索词。")
            }
            let combined = requireSelection || action == .combined
            let evidence = try index.searchEvidence(query, selection: combined ? selection.map { String($0.text.prefix(1200)) } : nil)
            if combined {
                guard let selection else { throw ResearchMaterialError.message("本次没有可对照的选区。") }
                return [try selection.withBackgroundEvidence(evidence)]
            }
            return [evidence]
        case .object:
            throw ResearchMaterialError.message("未通过本机文档对象核验。")
        case .selection:
            guard !requireSelection, let selection else { throw ResearchMaterialError.message("只读取选区无法满足本次请求。") }
            guard selection.text.utf16.count <= ResearchMaterial.maximumLength else { throw ResearchMaterialError.message(ResearchMaterial.oversizeMessage) }
            return [selection]
        case .clarify: throw ResearchMaterialError.message(question ?? "需要确认这次要查阅的具体位置。")
        case .useEvidence: throw ResearchMaterialError.message("当前尚无已经核对的原文。")
        }
    }

    /// Evidence from two independent searches stays labelled as excerpts, including all corresponding source positions.
    static func accumulated(_ prior: ResearchMaterial?, _ next: ResearchMaterial) throws -> ResearchMaterial {
        guard let prior, prior.text != next.text, prior.source == "PDF 文件", next.source == prior.source,
              prior.fileReference == next.fileReference else { return next }
        let prefix = prior.text + "\n\n【追加查阅】\n"
        let text = prefix + next.text
        guard text.utf16.count <= ResearchMaterial.maximumLength else {
            throw ResearchMaterialError.message("两轮查询的证据超过单次材料上限，请分开询问这些位置。")
        }
        let positions = (prior.pdfPositions ?? []) + (next.pdfPositions ?? [])
        let pages = ResearchPDFIndex.pageList(positions.map(\.page))
        let excerpts = (prior.verifiedExcerpts ?? []) + (next.verifiedExcerpts ?? []).map { $0.shifted(by: prefix.utf16.count) }
        return ResearchMaterial(source: next.source, title: next.title, text: text,
                                scope: "两次检索所得的独立摘录 · 文件页 " + pages,
                                fileReference: next.fileReference, pdfPages: pages, pdfPositions: positions,
                                verifiedExcerpts: excerpts.isEmpty ? nil : excerpts)
    }
}

extension ResearchPDFIndex {
    /// A planner may inspect the text adjacent to a unique selection, including a page break.
    /// Only a later, verified read may turn these hints into an answer's cited material.
    func planningFeedback(for evidence: ResearchMaterial, selection: ResearchMaterial?) throws -> String {
        var text = "【已读取的证据】\n" + evidence.scope + "\n" + ResearchMaterial.bounded(evidence.text, limit: 1600)
        guard let selection, selection.text.utf16.count <= 2000 else { return text }
        let hits = try corpus.narrative.occurrences(selection.text)
        guard hits.count == 1, let last = corpus.slices(intersecting: hits[0]).last else { return text }
        for entry in corpus.entries[last.entry...].prefix(3) {
            let page = pages[entry.page - 1], block = page.blocks[entry.block]
            guard page.reliableOrder, block.reliable, !unavailable.contains(entry.page) else { break }
            guard entry.narrativeRange != nil else { continue }
            let ns = entry.text as NSString
            let excerpt: String
            if ns.length > 600 {
                let suffix = ns.rangeOfComposedCharacterSequences(for: NSRange(location: ns.length - 230, length: 230))
                excerpt = ResearchMaterial.bounded(entry.text, limit: 350) + "\n[…]\n" + ns.substring(with: suffix)
            } else { excerpt = entry.text }
            text += "\n【选区邻近正文 · 文件第 \(entry.page) 页第 \(entry.block + 1) 块】\n" + excerpt
        }
        return text
    }
}
