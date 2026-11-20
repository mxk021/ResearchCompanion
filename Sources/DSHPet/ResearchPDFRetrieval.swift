import Foundation
import NaturalLanguage

extension ResearchPDFIndex {
    var hasReadableContent: Bool {
        corpus.entries.contains { !unavailable.contains($0.page) && pages[$0.page - 1].blocks[$0.block].reliable }
    }

    static func requestsLocation(_ question: String) -> Bool {
        if case .none = ResearchPDFAddress.parse(question) { return false }
        return true
    }

    static func termCounts(_ text: String) -> [String: Int] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var counts: [String: Int] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if !stopWords.contains(word), word.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                counts[word, default: 0] += 1
            }
            return true
        }
        return counts
    }

    private static let stopWords: Set<String> = [
        "的","了","是","与","和","在","中","有","及","请","结合","本文","本篇","论文","这篇","作者","文件","会话",
        "选区","解释","总结","翻译","这个","如何","怎样","什么","哪些","进行","指出","提出","为什么","他们","内容","告诉",
        "我","一下","材料","所选","原文","对","来","做","对比","比较","这","那","该","这段","段落","结果是",
        "the","a","an","and","by","on","from","for","in","of","is","are","to","that","this","does","did","as",
        "about","which","there","at","with","it","its","was","or","what","how","compared","compare","between",
        "explain","describe","please","authors","author","summarize","paper","file","pdf","page","document","selection"
    ]

    private func missingPages(_ missing: [Int], whole: Bool) -> ResearchMaterialError {
        let next = canRequestOCR ? "可在材料卡中运行本机 OCR 后重试。" : "请重新读取或选择可核对的页段。"
        return .message((whole ? "无法核验整个文件。" : "所问页段不完整。") + "文件第 \(Self.pageList(missing)) 页缺少可核对的正文。" + next)
    }

    private func verified(_ slices: [ResearchPDFSlice], checkOrder: Bool = true) throws {
        guard !slices.isEmpty else { throw ResearchMaterialError.message("没有可核对的目标正文。") }
        var uncertain = Set<Int>()
        for slice in slices {
            let entry = corpus.entries[slice.entry]
            let page = pages[entry.page - 1]
            if (checkOrder && !page.reliableOrder) || !page.blocks[entry.block].reliable {
                uncertain.insert(entry.page)
            }
        }
        guard uncertain.isEmpty else {
            throw ResearchMaterialError.message("文件第 \(Self.pageList(Array(uncertain))) 页的文字或阅读顺序无法可靠核验。请在原 PDF 核对，或选取可确认的原文。")
        }
    }

    private func exact(_ start: String, _ end: String?) throws -> [ResearchMaterial] {
        // A missing physical page could hide a second occurrence of either anchor.
        if !unavailable.isEmpty { throw missingPages(Array(unavailable), whole: true) }
        func locate(_ text: String, _ name: String) throws -> NSRange {
            let hits = try corpus.narrative.occurrences(text)
            guard let hit = hits.first else { throw ResearchMaterialError.message("\(name)未在可核验的全文正文中找到：「\(text)」。请核对原文。") }
            guard hits.count == 1 else {
                let numbers = hits.flatMap { corpus.slices(intersecting: $0).map { corpus.entries[$0.entry].page } }
                throw ResearchMaterialError.message("\(name)在文件第 \(Self.pageList(numbers)) 页至少出现两次：「\(text)」。请提供更长的唯一原文。")
            }
            return hit
        }
        let first = try locate(start, end == nil ? "引文" : "起点")
        let last = try end.map { try locate($0, "终点") } ?? first
        guard first.location <= last.location, NSMaxRange(first) <= NSMaxRange(last) else {
            throw ResearchMaterialError.message("终点位于起点之前，无法按所给顺序提取。")
        }
        let slices = corpus.slices(intersecting: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
        try verified(slices)
        return try materials(slices, scope: "已核验原文范围（正文阅读顺序，含两端；页眉、页脚及独立脚注不计入）", limit: ResearchMaterial.maximumLength)
    }

    private func physicalPages(_ question: String) throws -> Set<Int>? {
        let q = question.lowercased()
            .replacingOccurrences(of: #"页\s*([至到–—-])\s*(?:第\s*)?"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\d)\s+to\s+page\s+"#, with: " to ", options: .regularExpression)
        var selected = Set<Int>()
        let groups = try NSRegularExpression(pattern: ResearchPDFAddress.pagePattern)
        let digits = ResearchPDFAddress.number
        let ranges = try NSRegularExpression(pattern: "(" + digits + #")(?:\s*(?:[-–—至到]|to)\s*(?:第\s*)?("# + digits + #"))?"#)
        for group in groups.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
            let list = group.range(at: 1).location == NSNotFound ? group.range(at: 2) : group.range(at: 1)
            for pair in ranges.matches(in: q, range: list) {
                let a = Range(pair.range(at: 1), in: q).flatMap { ResearchPDFAddress.integer(String(q[$0])) }
                let b = Range(pair.range(at: 2), in: q).flatMap { ResearchPDFAddress.integer(String(q[$0])) } ?? a
                guard let a, let b, a >= 1, b >= a, b <= pages.count else {
                    throw ResearchMaterialError.message("所问页码超出 PDF 的文件页 1–\(pages.count)，或范围顺序有误。")
                }
                selected.formUnion(a...b)
            }
        }
        if ResearchPDFAddress.captures(#"末页|尾页|最后一页|\b(?:last|final) page\b"#, in: q) != nil { selected.insert(pages.count) }
        if ResearchPDFAddress.captures(#"首页|第一页|\bfirst page\b"#, in: q) != nil { selected.insert(1) }
        if ResearchPDFAddress.captures(#"中间页|中间部分|中部|\bmiddle page\b"#, in: q) != nil { selected.insert((pages.count + 1) / 2) }
        return selected.isEmpty ? nil : selected
    }

    private static func headingNumber(_ text: String) -> String? {
        ResearchPDFAddress.captures(#"^\s*(?:(?:section|chapter)\s+)?(\d+(?:\.\d+)*)(?:\s|[.、:：)）])"#, in: text)?[1]
    }

    private func heading(_ id: Int) -> String? {
        let entry = corpus.entries[id]
        let block = pages[entry.page - 1].blocks[entry.block]
        let line = entry.text.split(whereSeparator: \.isNewline).first.map(String.init)?.lowercased() ?? ""
        if block.kind == .heading { return line }
        if ResearchPDFAddress.captures(#"^(?:abstract|摘要)(?:\s*[:：—–.]|\s*$)"#, in: line) != nil { return "abstract" }
        return nil
    }

    private func sectionEntries(_ name: String) throws -> Range<Int> {
        let aliases = ResearchPDFAddress.sections.first { $0.label == name }?.aliases ?? [name]
        let starts = corpus.entries.indices.filter { id in
            guard let line = heading(id) else { return false }
            if name.first?.isNumber == true { return Self.headingNumber(line) == name }
            let stripped = line.replacingOccurrences(of: #"^\s*(?:(?:section|chapter)\s+)?(?:\d+(?:\.\d+)*|[ivxlcdm]+)[.:、)）\s-]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return aliases.contains { stripped == $0 }
        }
        guard starts.count == 1, let start = starts.first else {
            throw ResearchMaterialError.message(starts.isEmpty ? "未找到可核验的章节标题「\(name)」，请指定页码或起止原文。" : "章节标题「\(name)」有多个候选，请指定起止原文。")
        }
        let number = heading(start).flatMap(Self.headingNumber)
        let end = corpus.entries.indices.dropFirst(start + 1).first { id in
            guard let line = heading(id) else { return false }
            if let number, let next = Self.headingNumber(line), next.hasPrefix(number + ".") { return false }
            return true
        } ?? corpus.entries.endIndex
        return start..<end
    }

    private func locatedSlices(_ question: String) throws -> [ResearchPDFSlice]? {
        let pageFilter = try physicalPages(question)
        let section = ResearchPDFAddress.explicitSection(question)
        let col = ResearchPDFAddress.captures(ResearchPDFAddress.columns, in: question)?.first?.lowercased()
        let paragraph = ResearchPDFAddress.captures(ResearchPDFAddress.paragraphPattern, in: question)
        let last = ResearchPDFAddress.captures(ResearchPDFAddress.lastParagraph, in: question) != nil
        let first = ResearchPDFAddress.captures(ResearchPDFAddress.firstParagraph, in: question) != nil
        let specific = last || first || paragraph != nil
        if col != nil || specific, pageFilter == nil && section == nil {
            throw ResearchMaterialError.message("请指定该栏或段落所在的 PDF 文件页或章节。")
        }
        guard pageFilter != nil || section != nil || col != nil || specific else { return nil }
        let chapters = try section.map(sectionEntries)
        var ids = (chapters ?? corpus.entries.indices).filter { id in
            let entry = corpus.entries[id]
            if let filter = pageFilter, !filter.contains(entry.page) { return false }
            if let col {
                let number = col.contains("左") || col.contains("left") ? 1 : 2
                if pages[entry.page - 1].blocks[entry.block].column != number { return false }
            }
            return true
        }
        var physical = pageFilter ?? Set(ids.map { corpus.entries[$0].page })
        if chapters != nil, let lo = physical.min(), let hi = physical.max() { physical.formUnion(lo...hi) }
        let missing = unavailable.intersection(physical)
        guard missing.isEmpty else { throw missingPages(Array(missing), whole: false) }
        if specific {
            if (pageFilter?.count ?? 0) > 1 { throw ResearchMaterialError.message("请明确需要哪一页的该段文字。") }
            let body = ids.filter { id in
                let entry = corpus.entries[id]
                return pages[entry.page - 1].blocks[entry.block].kind == .body
            }
            let ordinal = paragraph.flatMap { match in match.dropFirst().first(where: { !$0.isEmpty }) }.flatMap(ResearchPDFAddress.integer)
            let n = last ? body.count : ordinal ?? 1
            guard n > 0, n <= body.count else { throw ResearchMaterialError.message("所指页或栏中没有可核对的该段正文。") }
            ids = [body[n - 1]]
        }
        let slices = ids.map(corpus.full)
        try verified(slices)
        return slices
    }

    func prepare(_ question: String) throws -> [ResearchMaterial] {
        let address = ResearchPDFAddress.parse(question)
        try address.requireAnchorText()
        switch address {
        case let .anchors(a, b):
            let alternatives = try ResearchPDFAddress.englishEndpoints(question)
            if !alternatives.isEmpty {
                let valid = try alternatives.filter { pair in
                    guard !pair.0.isEmpty, !pair.1.isEmpty else { return false }
                    return try !corpus.narrative.occurrences(pair.0).isEmpty && !corpus.narrative.occurrences(pair.1).isEmpty
                }
                guard valid.count == 1, let pair = valid.first else {
                    throw ResearchMaterialError.message("无法唯一确定英文起止短句，请分别用引号标出两处原文。")
                }
                return try exact(pair.0, pair.1)
            }
            return try exact(a, b)
        case let .quotation(quote): return try exact(quote, nil)
        case .location, .none: break
        }
        if let slices = try locatedSlices(question) {
            return try materials(slices, scope: "按指定文件页、栏或章节取出的原文", limit: ResearchMaterial.maximumLength)
        }
        return [try ranked(question, background: nil)]
    }

    func retrieve(_ question: String, backgroundKeywords: String? = nil) throws -> ResearchMaterial {
        if backgroundKeywords == nil {
            let result = try prepare(question)
            guard result.count == 1, let value = result.first else { throw ResearchMaterialError.message("目标范围需要 \(result.count) 段，请使用文档分段处理。") }
            return value
        }
        let address = ResearchPDFAddress.parse(question)
        switch address {
        case .anchors, .quotation:
            let result = try prepare(question)
            guard result.count == 1, let value = result.first else { throw ResearchMaterialError.message("指定原文超过一次选区问答的上限，请单独处理文件。") }
            return value
        default: return try ranked(question, background: backgroundKeywords)
        }
    }

    func segments() throws -> [ResearchMaterial] {
        guard unavailable.isEmpty else { throw missingPages(Array(unavailable), whole: true) }
        let slices = corpus.entries.indices.map(corpus.full)
        try verified(slices)
        return try materials(slices, scope: "整篇按文件页序连续分段，已排除页眉页脚", limit: 7_200)
    }
}

extension ResearchPDFIndex {
    private static let concepts: [[String]] = [
        ["方法", "技术", "method", "methods", "approach", "algorithm", "technique", "framework"],
        ["传统", "常规", "baseline", "conventional", "traditional", "standard"],
        ["贡献", "创新", "contribution", "contributions", "propose", "proposed", "introduce", "novel"],
        ["局限", "局限性", "限制", "不足", "limitation", "limitations", "limited", "challenge", "however", "future"],
        ["结果", "实验", "results", "experiments", "experimental", "evaluation", "measured"],
        ["准确性", "精度", "accuracy", "accurate", "error", "precision"],
        ["加速", "效率", "速度", "speedup", "acceleration", "faster", "runtime", "speed", "time"],
        ["摘要", "abstract"], ["引言", "介绍", "introduction"],
        ["结论", "conclusion", "conclusions"], ["附录", "appendix", "appendices"],
        ["讨论", "discussion"], ["厚掩模", "thick", "mask"]
    ]

    private func ranked(_ question: String, background: String?) throws -> ResearchMaterial {
        var weights = [String: Double]()
        if let background {
            for w in Self.termCounts(background).keys { weights[w] = 0.65 }
        }
        let direct = Set(Self.termCounts(question).keys)
        var facets: [Set<String>] = []
        for concept in Self.concepts where concept.contains(where: { direct.contains($0) || ($0.first?.isASCII == false && question.contains($0)) }) {
            facets.append(Set(concept))
            for word in concept { weights[word] = max(weights[word] ?? 0, 0.6) }
        }
        for w in direct { weights[w] = 1 }
        let explicit = try locatedSlices(question)
        let allowed = explicit.map { Set($0.map(\.entry)) }
        struct Hit {
            let passage: Int
            let score: Double
            let matched: Set<String>
        }
        var ranked: [Hit] = []
        let population = Double(corpus.passages.count)
        // Lexical relevance (BM25 term saturation with document frequency) plus
        // adjacent evidence and independent question facets. No unrelated filler.
        for (id, p) in corpus.passages.enumerated() {
            try Task.checkCancellation()
            let entry = corpus.entries[p.slice.entry]
            let page = pages[entry.page - 1]
            let block = page.blocks[entry.block]
            guard allowed?.contains(p.slice.entry) != false, block.reliable, !unavailable.contains(entry.page) else { continue }
            let matches = Set(p.terms.keys.filter { weights[$0] != nil })
            var score = matches.reduce(0.0) { sum, w in
                let df = Double(corpus.frequency[w] ?? 0)
                let tf = Double(p.terms[w] ?? 0)
                let idf = log(1 + (population - df + 0.5) / (df + 0.5))
                return sum + weights[w, default: 0] * idf * tf * 2.2 / (tf + 1.2 * (0.35 + 0.65 * Double(p.count) / 72))
            }
            if block.kind == .reference { score *= 0.30 }
            if block.kind == .footnote { score *= 0.65 }
            if !page.reliableOrder { score *= 0.7 }
            if score > 0 { ranked.append(Hit(passage: id, score: score, matched: matches)) }
        }
        ranked.sort { $0.score == $1.score ? $0.passage < $1.passage : $0.score > $1.score }
        if ranked.isEmpty, let explicit, background != nil {
            let value = try materials(explicit, scope: "明确指定的文件位置", limit: 4_000)
            guard value.count == 1, let material = value.first else { throw ResearchMaterialError.message("指定页段过长，且未找到与选区匹配的证据。") }
            return material
        }
        guard let best = ranked.first else {
            throw ResearchMaterialError.message("已检索可读全文，未找到足以核对问题的相关段落。请提供原文术语、页码或章节。")
        }
        var selected: [Int] = []
        var budget = background == nil ? 10_500 : 3_500
        func include(_ id: Int) {
            guard corpus.passages.indices.contains(id), !selected.contains(id) else { return }
            let slice = corpus.passages[id].slice
            let cost = slice.range.length + 42
            guard cost <= budget else { return }
            budget -= cost
            selected.append(id)
        }
        include(best.passage)
        for terms in facets {
            if let candidate = ranked.first(where: { !$0.matched.isDisjoint(with: terms) }) { include(candidate.passage) }
        }
        for hit in ranked.prefix(10) where hit.score >= best.score * 0.18 { include(hit.passage) }
        // Headings, short observations and equations often depend on the adjacent
        // explanation. Only add neighbors from a verified reading order and column.
        for id in selected {
            let seed = corpus.entries[corpus.passages[id].slice.entry]
            let page = pages[seed.page - 1]
            let origin = page.blocks[seed.block]
            guard page.reliableOrder, origin.kind != .reference else { continue }
            for next in [id + 1, id - 1] where corpus.passages.indices.contains(next) {
                let other = corpus.entries[corpus.passages[next].slice.entry]
                guard other.page == seed.page, allowed?.contains(corpus.passages[next].slice.entry) != false else { continue }
                let neighbor = page.blocks[other.block]
                if neighbor.reliable && neighbor.column == origin.column && (neighbor.kind == .body || neighbor.kind == .formula) {
                    include(next)
                }
            }
        }
        let slices = selected.sorted().map { corpus.passages[$0].slice }
        let scope = unavailable.isEmpty ? "相关证据摘录；各处独立核对，未覆盖之处证据不足" :
            "可读页的相关证据摘录；文件第 \(Self.pageList(Array(unavailable))) 页不可核对"
        guard let value = try materials(slices, scope: scope, limit: ResearchMaterial.maximumLength, independent: true).first else {
            throw ResearchMaterialError.message("找不到可核对的文件证据。")
        }
        return value
    }

    private func materials(_ slices: [ResearchPDFSlice], scope: String, limit: Int,
                           independent: Bool = false) throws -> [ResearchMaterial] {
        var body = ""
        var length = 0
        var spans: [(span: NSRange, slice: ResearchPDFSlice)] = []
        var previous: ResearchPDFSlice?
        for slice in slices {
            try Task.checkCancellation()
            let entry = corpus.entries[slice.entry]
            let block = pages[entry.page - 1].blocks[entry.block]
            let substring = (entry.text as NSString).substring(with: slice.range)
            var separator = ""
            if let previous {
                let same = previous.entry == slice.entry && NSMaxRange(previous.range) == slice.range.location
                if !same { separator = "\n\n" }
                if !independent, entry.page > corpus.entries[previous.entry].page + 1 {
                    separator += "【另一个指定位置 · 文件第 \(entry.page) 页】\n"
                }
            }
            if independent {
                let column = block.column == 1 ? " · 左栏" : block.column == 2 ? " · 右栏" : ""
                let source = pages[entry.page - 1].ocr ? " · 本机 OCR" : ""
                separator += "【文件第 \(entry.page) 页\(column)\(source) · 第 \(entry.block + 1) 块】\n"
            }
            body += separator
            length += separator.utf16.count
            spans.append((NSRange(location: length, length: slice.range.length), slice))
            body += substring
            length += slice.range.length
            previous = slice
        }
        let chunks = try Self.split(body, limit: limit)
        var offset = 0, start = 0
        return try chunks.map { chunk in
            try Task.checkCancellation()
            let span = NSRange(location: offset, length: chunk.utf16.count)
            defer { offset = NSMaxRange(span) }
            while start < spans.count && NSMaxRange(spans[start].span) <= span.location { start += 1 }
            var cursor = start
            var numbers: [Int] = []
            var pageStarts: [String] = []
            var positions: [ResearchPDFSourcePosition] = []
            while cursor < spans.count && spans[cursor].span.location < NSMaxRange(span) {
                let part = spans[cursor]
                let clipped = NSIntersectionRange(part.span, span)
                if clipped.length > 0 {
                    let slice = part.slice
                    let entry = corpus.entries[slice.entry]
                    if numbers.last != entry.page {
                        numbers.append(entry.page)
                        pageStarts.append("\(entry.page)@\(clipped.location - offset)")
                    }
                    let local = NSRange(location: slice.range.location + clipped.location - part.span.location, length: clipped.length)
                    positions += sourcePositions(entry: entry, local: local)
                }
                cursor += 1
            }
            let range = Self.pageList(numbers)
            let marked = independent || numbers.count < 2 ? "" : " · 页@本段UTF-16偏移 " + pageStarts.joined(separator: "，")
            let ocrPages = numbers.filter { pages[$0 - 1].ocr }
            let ocr = ocrPages.isEmpty ? "" : " · 本机 OCR 页 " + Self.pageList(ocrPages)
            let label = ResearchMaterial.bounded(scope + " · 文件页 " + range + " / 共 \(pages.count) 页" + ocr + marked, limit: 510)
            var material = ResearchMaterial(source: "PDF 文件", title: title, text: chunk, scope: label, fileReference: reference, pdfPages: range)
            material.pdfPositions = positions.isEmpty ? nil : positions
            return material
        }
    }

    private func sourcePositions(entry: ResearchPDFCorpus.Entry, local: NSRange) -> [ResearchPDFSourcePosition] {
        let page = pages[entry.page - 1]
        let block = page.blocks[entry.block]
        var offset = 0
        var result: [ResearchPDFSourcePosition] = []
        for line in block.lines {
            let lineRange = NSRange(location: offset, length: line.text.utf16.count)
            let clip = NSIntersectionRange(lineRange, local)
            if clip.length > 0, !line.bounds.isEmpty, !line.bounds.isInfinite {
                let native = line.sourceRange.flatMap { source -> NSRange? in
                    guard source.length == lineRange.length else { return nil }
                    return NSRange(location: source.location + clip.location - offset, length: clip.length)
                }
                result.append(ResearchPDFSourcePosition(page: entry.page, bounds: line.bounds, column: block.column,
                    blockIndex: entry.block, blockRange: clip, sourceRange: native, ocr: line.ocr))
            }
            offset = NSMaxRange(lineRange) + 1
            if offset >= NSMaxRange(local) { break }
        }
        return result
    }
}
