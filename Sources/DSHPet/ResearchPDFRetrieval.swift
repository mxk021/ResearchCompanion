import Foundation
import NaturalLanguage
import PDFKit

/// All candidate text and coordinates are present; only reading order needs a human decision.
struct ResearchPDFReviewRequired: LocalizedError {
    let reason: String
    let pages: [Int]
    let materials: [ResearchMaterial]
    var errorDescription: String? { reason }
}

/// A bounded choice of exact document addresses. The selected address is checked
/// against the same frozen document and the original endpoints before extracting.
struct ResearchPDFRangeCandidate: Identifiable, Sendable {
    let id: String
    let startPage: Int
    let endPage: Int
    let startPreview: String
    let endPreview: String
    let section: String?
    let fileFingerprint: String
}

struct ResearchPDFRangeAmbiguity: LocalizedError, Sendable {
    let candidates: [ResearchPDFRangeCandidate]
    let truncated: Bool
    let anchors: ResearchPDFAnchors
    var reason: String? = nil
    var errorDescription: String? {
        reason ?? "起点或终点至少出现两次。请核对这次所需的起止位置。"
    }
}

extension ResearchPDFIndex {
    func addressedObjects(in question: String, address: ResearchPDFAddress) -> [ResearchPDFObjectID] {
        addressedObjects(for: ResearchPDFRequest(question, address: address))
    }

    func addressedObjects(for request: ResearchPDFRequest) -> [ResearchPDFObjectID] {
        if !request.objects.isEmpty { return request.objects }
        // A printed identifier can disambiguate the category of a bare list.
        // Once established, preserve the whole list, including missing items.
        return request.untypedObjects.contains(where: objects.hasEquationCandidate)
            ? request.untypedObjects : []
    }

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

    /// Validate the exact UTF-16 intersections, not every expression and diagram on the page.
    /// An unplaced glyph can belong anywhere; an old index without local geometry stays fail-closed.
    private func verified(_ slices: [ResearchPDFSlice], scope: String, limit: Int, independent: Bool = false,
                          requestCheck: ResearchPDFEvidenceCheck? = nil) throws {
        guard !slices.isEmpty else { throw ResearchMaterialError.message("没有可核对的目标正文。") }
        var reviewPages = Set<Int>()
        var lineCount = 0
        var visionPage: PDFDocument?
        var visionOpened = false
        var remainingVisionChecks = 8
        var immutableBytes: Data?
        var attemptedBytes = false
        var glyphPages: [Int: ResearchPDFGlyphPage] = [:]
        var attemptedPages = Set<Int>()
        func confirmGlyphs(_ text: String, bounds: CGRect, on page: Page) throws -> Bool {
            guard requestCheck != nil, let geometry = page.geometry else { return false }
            if !attemptedPages.contains(page.number), attemptedPages.count < 4 {
                attemptedPages.insert(page.number)
                glyphPages[page.number] = try ResearchPDFCropRenderer.glyphPage(
                    fingerprint: reference.fingerprint, pageIndex: page.number - 1,
                    canvas: geometry.canvas, display: geometry.display) {
                        if !attemptedBytes { attemptedBytes = true; immutableBytes = reference.verifiedPDF()?.1 }
                        return immutableBytes
                    }
            }
            guard let glyphPage = glyphPages[page.number] else { return false }
            let expected = Self.printedLineKey(text)
            guard expected.count >= 5 else { return false }
            let glyphs = glyphPage.glyphs(in: bounds.insetBy(dx: -0.6, dy: -0.6))
            let actual = String(String.UnicodeScalarView(glyphs.map(\.scalar)))
            return Self.printedLineKey(actual) == expected
        }
        let selected = slices.map { slice -> [ResearchPDFLine] in
            let entry = corpus.entries[slice.entry]
            var offset = 0
            return pages[entry.page - 1].blocks[entry.block].lines.filter { line in
                let n = line.text.utf16.count
                defer { offset += n + 1 }
                return NSIntersectionRange(slice.range, NSRange(location: offset, length: n)).length > 0
            }
        }
        func confirmsSplitRow(_ first: ResearchPDFLine, entry: ResearchPDFCorpus.Entry,
                              _ second: ResearchPDFLine, nextEntry: ResearchPDFCorpus.Entry,
                              page: Page) throws -> Bool {
            let blocks = page.blocks
            guard entry.page == nextEntry.page, blocks[entry.block].kind == .body, blocks[nextEntry.block].kind == .body,
                  blocks[entry.block].column == blocks[nextEntry.block].column,
                  first.orderUncertain, second.orderUncertain, first.reliable, second.reliable, !first.ocr, !second.ocr,
                  let geometry = page.geometry, let a = first.sourceRanges.last, let b = second.sourceRanges.first,
                  (0...2).contains(b.location - NSMaxRange(a)) else { return false }
            let left = first.bounds.applying(geometry.display), right = second.bounds.applying(geometry.display)
            let height = max(left.height, right.height)
            let gap = right.minX - left.maxX
            guard page.reliableOrder, right.maxX > left.maxX, right.midX > left.midX,
                  abs(left.midY - right.midY) <= height * 0.32,
                  (-height...height * 0.6).contains(gap) else { return false }
            // Split runs can overlap around raised and lowered characters.
            // Confirm their entire joined sequence independently in the one
            // printed row, never by trusting the left/right bounding boxes alone.
            return try confirmGlyphs(first.text + second.text, bounds: first.bounds.union(second.bounds), on: page)
        }
        for (sliceIndex, slice) in slices.enumerated() {
            try Task.checkCancellation()
            let entry = corpus.entries[slice.entry]
            let page = pages[entry.page - 1], block = page.blocks[entry.block]
            func unavailable(_ detail: String) -> ResearchMaterialError {
                .message("文件第 \(entry.page) 页第 \(entry.block + 1) 块无法可靠核验：\(detail)。已保留问题，请在原 PDF 核对。")
            }
            guard page.reliableOrder || page.hasLocalOrderMap else {
                throw unavailable("存在无法定位的文字或版面缺少局部坐标")
            }
            var selectedLines = 0
            var localAmbiguity = false
            let lines = selected[sliceIndex]
            for (lineIndex, line) in lines.enumerated() {
                lineCount += 1
                selectedLines += 1
                guard line.reliable, !line.bounds.isEmpty, !line.bounds.isInfinite else {
                    throw unavailable("选中行的字形位置或文字识别置信度不足")
                }
                if page.state == .needsOCR && !ResearchMaterial.hasReadableText(line.text) {
                    throw unavailable("请求范围内含无法从文字层核对的原始字形")
                }
                if !page.reliableOrder || !block.reliable || line.orderUncertain || line.regionVerified == false {
                    guard page.hasLocalOrderMap else { throw unavailable("当前块缺少独立的局部核验") }
                    if line.ocr {
                        // A recognised string cannot prove an uncertain geometric sequence or
                        // that two overlapping OCR regions cover all underlying words.
                        throw unavailable("OCR 行缺少可交叉核对的文字层")
                    }
                    var joined = false
                    if line.orderUncertain && requestCheck != nil {
                        if lineIndex > 0 {
                            joined = try confirmsSplitRow(lines[lineIndex - 1], entry: entry, line, nextEntry: entry, page: page)
                        } else if sliceIndex > 0, let before = selected[sliceIndex - 1].last {
                            joined = try confirmsSplitRow(before, entry: corpus.entries[slices[sliceIndex - 1].entry],
                                                          line, nextEntry: entry, page: page)
                        }
                        if !joined, lineIndex + 1 < lines.count {
                            joined = try confirmsSplitRow(line, entry: entry, lines[lineIndex + 1], nextEntry: entry, page: page)
                        } else if !joined, lineIndex + 1 == lines.count, sliceIndex + 1 < slices.count,
                                  let after = selected[sliceIndex + 1].first {
                            joined = try confirmsSplitRow(line, entry: entry, after,
                                nextEntry: corpus.entries[slices[sliceIndex + 1].entry], page: page)
                        }
                    }
                    if !joined && (line.regionVerified == false || line.regionVerified != true && (line.orderUncertain || !page.reliableOrder)) {
                        if try !confirmGlyphs(line.text, bounds: line.bounds, on: page) {
                            // OCR may verify a glyph, but does not determine the
                            // order of overlapping regions on a typeset page.
                            if requestCheck != nil, line.orderUncertain, page.geometry != nil {
                                throw unavailable("两套文字层对选中行的字形或顺序未能取得一致结果")
                            }
                            guard remainingVisionChecks > 0 else { throw unavailable("待核对的行超出本次局部复核上限") }
                            remainingVisionChecks -= 1
                            if !visionOpened {
                                visionOpened = true
                                visionPage = reference.verifiedPDF().flatMap { PDFDocument(data: $0.1) }
                            }
                            guard let original = visionPage?.page(at: entry.page - 1),
                                  try Self.confirmNativeLineByOCR(line, page: original) else {
                                throw unavailable("局部选区、原生文字与页面字形未能取得一致结果")
                            }
                        }
                    }
                    if line.orderUncertain && !joined { localAmbiguity = true }
                }
            }
            if localAmbiguity && (!independent || selectedLines > 1) { reviewPages.insert(entry.page) }
        }
        // An exact quotation wholly inside one geometrically confirmed line involves no inter-line ordering.
        if !reviewPages.isEmpty && lineCount > 1 {
            let reason = "文件第 \(Self.pageList(Array(reviewPages))) 页的候选文字可逐行定位，但相邻栏、同基线文字或表格的先后顺序仍有歧义。请与原 PDF 对照。"
            let tentative = requestCheck.map { ResearchPDFEvidenceCheck(kind: $0.kind, target: $0.target, status: .ambiguous) }
            let candidates = try materials(slices, scope: scope + " · 经用户对照采用的候选顺序", limit: limit,
                                           independent: independent, requestCheck: tentative)
            throw ResearchPDFReviewRequired(reason: reason, pages: reviewPages.sorted(), materials: candidates)
        }
    }

    private static func printedLineKey(_ text: String) -> String {
        let scalars = text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{00AD}" && $0 != "\u{200B}"
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Evidence from one contiguous range in the PDF reading order. Inputs from a model
    /// are addresses only; the body and every location come from this version of the file.
    func readRange(start: String, end: String, withinPages: ClosedRange<Int>? = nil, section: String? = nil,
                   includeStart: Bool = true, includeEnd: Bool = true, selectionHint: String? = nil,
                   chosenRangeID: String? = nil, includeDetachedCaptions: Bool = false) throws -> [ResearchMaterial] {
        try exact(start, end, withinPages: withinPages, section: section, includeStart: includeStart, includeEnd: includeEnd,
                  selectionHint: selectionHint, chosenRangeID: chosenRangeID, includeDetachedCaptions: includeDetachedCaptions)
    }

    private func exact(_ start: String, _ end: String?, withinPages: ClosedRange<Int>? = nil,
                       section: String? = nil, includeStart: Bool = true, includeEnd: Bool = true,
                       selectionHint: String? = nil, chosenRangeID: String? = nil,
                       includeDetachedCaptions: Bool = false) throws -> [ResearchMaterial] {
        let requirement = ResearchPDFEvidenceCheck(kind: end == nil ? .content : .continuousRange,
            target: end == nil ? "所问的原文引句" : "所问的连续原文", status: .verified)
        if let withinPages { try validatePages(withinPages) }
        let chapter = try section.map { try sectionEntries($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        let scopeIDs = (chapter ?? corpus.entries.indices).filter { withinPages?.contains(corpus.entries[$0].page) ?? true }
        var physical = withinPages ?? (1...pages.count)
        if chapter != nil, let first = scopeIDs.first, let last = scopeIDs.last {
            physical = corpus.entries[first].page...corpus.entries[last].page
        }
        let missing = unavailable.filter {
            physical.contains($0) && !(pages[$0 - 1].state == .needsOCR && pages[$0 - 1].hasLocalOrderMap)
        }
        func distinctive(_ anchor: String) -> Bool {
            // A short fragment such as “the results” can recur on unseen
            // pages. Require a sentence fragment with several distinct words
            // before accepting a locally verified pair in a partial index.
            // Continuous writing can provide the same evidence in one token.
            let words = anchor.lowercased().split { !$0.isLetter && !$0.isNumber }
            let han = anchor.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }
            return (Set(words).count >= 4 && words.reduce(0) { $0 + $1.count } >= 18) ||
                Set(han).count >= 10
        }
        var uniquePrintedPair = false
        func checkedScope(_ scope: String, from firstPage: Int, through lastPage: Int) throws -> String {
            let interior = missing.filter((firstPage...lastPage).contains)
            guard interior.isEmpty else { throw missingPages(Array(interior), whole: false) }
            guard !missing.isEmpty else { return scope }
            guard firstPage == lastPage || uniquePrintedPair else { throw missingPages(Array(missing), whole: false) }
            return scope + "；范围外文件第 \(Self.pageList(Array(missing))) 页不可核对，无法排查这些页中的重复引文"
        }
        let narrative = scopeIDs.compactMap { corpus.entries[$0].narrativeRange }
        let search = narrative.first.flatMap { first in narrative.last.map { NSUnionRange(first, $0) } }
        let matchLimit = 65
        func printedHits(_ anchor: String, in span: NSRange) throws -> [NSRange] {
            let literal = try corpus.narrative.occurrences(anchor, within: span, limit: matchLimit)
            if !literal.isEmpty { return literal }
            return try corpus.narrative.occurrences(anchor, within: span, limit: matchLimit,
                                                    allowMathematicalTypography: true)
        }
        let starts = try search.map { try printedHits(start, in: $0) } ?? []
        var usesPrintedInflection = false
        let endHits: [NSRange]? = try end.map { anchor in
            try search.map { span in
                let literal = try printedHits(anchor, in: span)
                guard literal.isEmpty, !starts.isEmpty else { return literal }
                // A user may copy the last printed line starting at the
                // remainder of a hyphenated word. The interval still includes
                // the first half from the previous line. Opening anchors and
                // stand-alone quotations keep the full-word boundary.
                if includeEnd {
                    let wrapped = try corpus.narrative.occurrences(anchor, within: span, limit: matchLimit,
                                                                  startsAfterPrintedWrap: true)
                    if !wrapped.isEmpty { return wrapped }
                }
                let numbered = try corpus.narrative.occurrences(anchor, within: span, limit: matchLimit, beforeCitationNumber: true)
                if !numbered.isEmpty, let original = reference.verifiedPDF().flatMap({ PDFDocument(data: $0.1) }) {
                    let verified = numbered.filter { hasRaisedCitation(after: $0, in: original) }
                    if !verified.isEmpty { return verified }
                }
                let matches = try corpus.narrative.occurrences(anchor, within: span, limit: matchLimit, allowOpeningInflection: true)
                usesPrintedInflection = !matches.isEmpty
                return matches
            } ?? []
        }
        if starts.isEmpty || endHits?.isEmpty == true {
            guard chosenRangeID == nil else {
                throw ResearchMaterialError.message("所选范围已变化，请重新核对原文。")
            }
            // A user can still quote a figure or footnote itself. Never join a caption
            // to an unrelated paragraph/figure to manufacture a continuous interval.
            var found: ResearchPDFSlice?
            for id in scopeIDs where corpus.entries[id].narrativeRange == nil {
                let isolated = try ResearchPDFSearchText(corpus.entries[id].text)
                let a = try isolated.occurrences(start)
                guard !a.isEmpty else { continue }
                let b = try end.map { try isolated.occurrences($0) } ?? a
                guard !b.isEmpty, let first = a.first, let last = b.first,
                      first.location <= last.location, NSMaxRange(first) <= NSMaxRange(last) else { continue }
                guard a.count == 1, b.count == 1, found == nil else {
                    throw ResearchMaterialError.message("引文在独立图表或脚注中有多个候选位置，请指定文件页或更长的原句。")
                }
                let lo = includeStart ? first.location : NSMaxRange(first), hi = includeEnd ? NSMaxRange(last) : last.location
                guard hi > lo else { throw ResearchMaterialError.message("按指定边界排除端点后没有连续原文。") }
                found = ResearchPDFSlice(entry: id, range: NSRange(location: lo, length: hi-lo))
            }
            if let found {
                let p = corpus.entries[found.entry].page
                let scope = try checkedScope("独立图表或脚注中的连续原文", from: p, through: p)
                try verified([found], scope: scope, limit: 7_200, requestCheck: requirement)
                return try materials([found], scope: scope, limit: 7_200, requestCheck: requirement)
            }
            let name = starts.isEmpty ? (end == nil ? "引文" : "起点") : "终点"
            let gaps = missing.isEmpty ? "" : "文件第 \(Self.pageList(Array(missing))) 页缺少可核对的正文。"
            let explanation = "\(name)未在可核对的连续正文中找到：「\(starts.isEmpty ? start : end ?? start)」。\(gaps)请核对原文。"
            if let end {
                throw ResearchPDFRangeAmbiguity(candidates: [], truncated: false, anchors: .init(start: start, end: end), reason: explanation)
            }
            throw ResearchMaterialError.message(explanation)
        }
        func ambiguous(_ hits: [NSRange], name: String) -> ResearchMaterialError {
            let candidates = hits.prefix(3).compactMap { hit -> String? in
                guard let slice = corpus.slices(intersecting: hit).first else { return nil }
                let entry = corpus.entries[slice.entry]
                let block = pages[entry.page - 1].blocks[entry.block]
                let column = block.column == 1 ? "左栏" : block.column == 2 ? "右栏" : ""
                let ns = entry.text as NSString
                let low = max(0, slice.range.location - 24)
                let excerpt = ns.substring(with: ns.rangeOfComposedCharacterSequences(for:
                    NSRange(location: low, length: min(70, ns.length - low)))).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return "文件第 \(entry.page) 页\(column)第 \(entry.block + 1) 块「\(excerpt)」"
            }
            return .message("\(name)至少出现两次。候选位置：" + candidates.joined(separator: "；") + "。可指定文件页、章节或较长的原文。")
        }
        let first: NSRange, last: NSRange
        if let ends = endHits {
            let pair = try pairedRange(starts: starts, ends: ends, anchors: .init(start: start, end: end ?? start), section: section,
                                       selectionHint: selectionHint, chosenRangeID: chosenRangeID,
                                       complete: starts.count < matchLimit && ends.count < matchLimit)
            (first, last) = (pair.start, pair.end)
            uniquePrintedPair = starts.count == 1 && ends.count == 1 && !usesPrintedInflection &&
                distinctive(start) && end.map(distinctive) == true
        } else {
            guard starts.count == 1, chosenRangeID == nil else { throw ambiguous(starts, name: "引文") }
            (first, last) = (starts[0], starts[0])
        }
        let lo = includeStart ? first.location : NSMaxRange(first)
        let hi = includeEnd ? NSMaxRange(last) : last.location
        guard hi > lo else { throw ResearchMaterialError.message("按指定边界排除端点后没有连续正文。") }
        let main = corpus.slices(intersecting: NSRange(location: lo, length: hi - lo))
        var slices = main
        if includeDetachedCaptions, let from = main.first?.entry, let through = main.last?.entry {
            let captions = ((from + 1)..<max(from + 1, through)).compactMap { id -> ResearchPDFSlice? in
                let entry = corpus.entries[id]
                let block = pages[entry.page - 1].blocks[entry.block]
                guard (block.kind == .caption || block.kind == .table) && entry.narrativeRange == nil else { return nil }
                return corpus.full(id)
            }
            slices = (main + captions).sorted { $0.entry < $1.entry }
        }
        let ends = includeStart && includeEnd ? "含两端" : "按所指定的端点开闭取文"
        let description = (includeDetachedCaptions
            ? "正文连续范围（\(ends)，含请求范围内的图表注释）"
            : "正文连续范围（\(ends)，排除页眉页脚、浮动图表注释及独立脚注）")
            + (usesPrintedInflection ? "；终点首词采用原页实际词形" : "")
        guard let opening = corpus.slices(intersecting: first).first,
              let closing = corpus.slices(intersecting: last).last else {
            throw ResearchMaterialError.message("起止原文无法映射到 PDF 文件页。")
        }
        // Even an excluded endpoint is part of the proof of continuity.
        let scope = try checkedScope(description, from: corpus.entries[opening.entry].page,
                                     through: corpus.entries[closing.entry].page)
        try verified(slices, scope: scope, limit: 7_200, requestCheck: requirement)
        return try materials(slices, scope: scope, limit: 7_200, requestCheck: requirement)
    }

    /// PDFKit flattens superscript references into the preceding word. Accept that
    /// boundary only when the printed reference rises above the prose baseline.
    /// Keep the canonical source indices and the caller's inclusive endpoint intact.
    private func hasRaisedCitation(after match: NSRange, in original: PDFDocument) -> Bool {
        let pair = NSRange(location: NSMaxRange(match) - 1, length: 2)
        let slices = corpus.slices(intersecting: pair)
        guard slices.count == 1, let slice = slices.first else { return false }
        let entry = corpus.entries[slice.entry]
        guard pages[entry.page-1].blocks[entry.block].kind == .body,
              let native = sourcePositions(entry: entry, local: slice.range).first?.sourceRange,
              native.length == 2, let page = original.page(at: entry.page-1),
              let printed = page.selection(for: native)?.attributedString, printed.length == 2,
              printed.string == corpus.narrativeSource.substring(with: pair),
              let normal = printed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
              let raised = printed.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        else { return false }
        let key = NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)
        let baseline = (printed.attribute(key, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        let offset = (printed.attribute(key, at: 1, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        return raised.pointSize < normal.pointSize * 0.94 && offset - baseline > normal.pointSize * 0.15
    }

    private struct AnchorPair {
        let start: NSRange
        let end: NSRange
        var id: String { "\(start.location):\(NSMaxRange(end))" }
        var span: NSRange { NSUnionRange(start, end) }
    }

    private func pairedRange(starts: [NSRange], ends: [NSRange], anchors: ResearchPDFAnchors, section: String?,
                             selectionHint: String?, chosenRangeID: String?, complete: Bool) throws -> AnchorPair {
        var pairs = starts.flatMap { start in
            ends.compactMap { end in
                start.location <= end.location && NSMaxRange(start) <= NSMaxRange(end)
                    ? AnchorPair(start: start, end: end) : nil
            }
        }
        guard !pairs.isEmpty else {
            throw ResearchPDFRangeAmbiguity(candidates: [], truncated: !complete, anchors: anchors,
                reason: complete ? "终点位于起点之前，无法按所给顺序提取。" : "当前找到的端点过多，请指定文件页、章节或更长的原句。")
        }
        if let chosenRangeID {
            guard let pair = pairs.first(where: { $0.id == chosenRangeID }) else {
                throw ResearchMaterialError.message("所选起止位置已变化，请重新核对原文。")
            }
            return pair
        }
        if pairs.count == 1, complete { return pairs[0] }

        let source = corpus.narrativeSource
        // Capitalization distinguishes a quoted sentence opener from lowercase mid-sentence
        // mentions only when the punctuation and original text corroborate that reading.
        func isSentenceOpening(_ hit: NSRange) -> Bool {
            guard let first = source.substring(with: hit).first(where: \.isLetter), first.isUppercase else { return false }
            if hit.location == 0 { return true }
            if let leading = corpus.slices(intersecting: hit).first, leading.range.location == 0, leading.entry > 0,
               heading(leading.entry - 1) != nil { return true }
            let lo = max(0, hit.location - 100)
            let prefixRange = source.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: hit.location - lo))
            let prefix = source.substring(with: prefixRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: #"”’"'）)]】》"#))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = prefix.last, ".?!。！？".contains(last) else { return false }
            // Protect common references/abbreviations, initials and numeric decimals.
            return ResearchPDFAddress.captures(#"(?:\b(?:fig|eq|ref|sec|tab|no|dr|mr|ms|prof|vs|al|vol|pp|e\.g|i\.e)|\b(?-i:[A-Z])|\d)\.$"#, in: prefix) == nil
        }
        if anchors.start.first(where: \.isLetter)?.isUppercase == true, anchors.start.contains(where: \.isLowercase) {
            let caseMatched = Set(starts.filter { isSentenceOpening($0) }.map(\.location))
            let preferred = pairs.filter { caseMatched.contains($0.start.location) }
            if !preferred.isEmpty { pairs = preferred }
        }
        if pairs.count == 1, complete { return pairs[0] }

        if let hint = selectionHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           (12...512).contains(hint.utf16.count),
           let matches = try? corpus.narrative.occurrences(hint, limit: 2),
           matches.count == 1, let selected = matches.first {
            let containing = pairs.filter { NSIntersectionRange($0.span, selected) == selected }
            let sharesEndpoint = containing.filter {
                $0.start.location == selected.location || NSMaxRange($0.end) == NSMaxRange(selected)
            }
            if !sharesEndpoint.isEmpty { pairs = sharesEndpoint }
            if pairs.count == 1, complete { return pairs[0] }
        }

        let limit = 6
        var candidates: [ResearchPDFRangeCandidate] = []
        for pair in pairs.prefix(limit) {
            guard let first = corpus.slices(intersecting: pair.start).first,
                  let last = corpus.slices(intersecting: pair.end).last else { continue }
            func excerpt(from hit: NSRange, leading: Bool) -> String {
                let lo = leading ? hit.location : max(0, NSMaxRange(hit) - 112)
                let hi = leading ? min(source.length, hit.location + 112) : NSMaxRange(hit)
                let bounds = source.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: hi - lo))
                return source.substring(with: bounds).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            let sectionTitle = section ?? corpus.entries.indices[..<first.entry].reversed().lazy.compactMap(self.heading).first
            candidates.append(.init(id: pair.id, startPage: corpus.entries[first.entry].page, endPage: corpus.entries[last.entry].page,
                                    startPreview: excerpt(from: pair.start, leading: true), endPreview: excerpt(from: pair.end, leading: false),
                                    section: sectionTitle.map { String($0.prefix(80)) }, fileFingerprint: reference.fingerprint))
        }
        if candidates.isEmpty { throw ResearchMaterialError.message("没有可核对的连续起止位置。") }
        throw ResearchPDFRangeAmbiguity(candidates: candidates, truncated: !complete || pairs.count > limit, anchors: anchors)
    }

    private func validatePages(_ range: ClosedRange<Int>) throws {
        guard range.lowerBound >= 1, range.upperBound <= pages.count else {
            throw ResearchMaterialError.message("所问页码超出 PDF 的文件页 1–\(pages.count)。")
        }
    }

    func readPages(_ range: ClosedRange<Int>) throws -> [ResearchMaterial] {
        try validatePages(range)
        let missing = unavailable.filter(range.contains)
        guard missing.isEmpty else { throw missingPages(Array(missing), whole: false) }
        let slices = corpus.entries.indices.filter { range.contains(corpus.entries[$0].page) }.map(corpus.full)
        try verified(slices, scope: "按文件页序读取", limit: 7_200)
        return try materials(slices, scope: "按文件页序连续取出的原文", limit: 7_200)
    }

    func searchEvidence(_ query: String, selection: String? = nil) throws -> ResearchMaterial {
        try ranked(query, background: selection)
    }

    var documentOutline: [String] {
        var result: [String] = []
        for id in corpus.entries.indices {
            guard let title = heading(id), !title.isEmpty else { continue }
            result.append("文件第 \(corpus.entries[id].page) 页 · " + String(title.prefix(96)))
            if result.count == 24 { break }
        }
        return result
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

    private func locatedSlices(_ question: String, requestCheck: ResearchPDFEvidenceCheck? = nil) throws -> [ResearchPDFSlice]? {
        let pageFilter = try physicalPages(question)
        let section = ResearchPDFAddress.explicitSection(question)
        let col = ResearchPDFAddress.captures(ResearchPDFAddress.columns, in: question)?.first?.lowercased()
        let paragraphs = ResearchPDFAddress.paragraphs(in: question)
        if col != nil || paragraphs != nil, pageFilter == nil && section == nil {
            throw ResearchMaterialError.message("请指定该栏或段落所在的 PDF 文件页或章节。")
        }
        guard pageFilter != nil || section != nil || col != nil || paragraphs != nil else { return nil }
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
        if let paragraphs {
            if (pageFilter?.count ?? 0) > 1 { throw ResearchMaterialError.message("请明确需要哪一页的该段文字。") }
            let body = ids.filter { id in
                let entry = corpus.entries[id]
                return entry.narrativeRange != nil && pages[entry.page - 1].blocks[entry.block].kind == .body
            }
            let required: Int
            switch paragraphs {
            case .ordinal(let n), .first(let n), .last(let n): required = n
            }
            guard required > 0, required <= body.count else {
                throw ResearchMaterialError.message("所指位置中没有足够的可核对正文段落。")
            }
            switch paragraphs {
            case .ordinal: ids = [body[required - 1]]
            case .first: ids = Array(body.prefix(required))
            case .last: ids = Array(body.suffix(required))
            }
        }
        let slices = ids.map(corpus.full)
        try verified(slices, scope: "按指定页、栏或章节读取", limit: ResearchMaterial.maximumLength,
                     requestCheck: requestCheck)
        return slices
    }

    func prepare(_ question: String, selectionHint: String? = nil, chosenRangeID: String? = nil,
                 correctedAnchors: ResearchPDFAnchors? = nil) throws -> [ResearchMaterial] {
        try prepare(ResearchPDFRequest(question), selectionHint: selectionHint, chosenRangeID: chosenRangeID,
                    correctedAnchors: correctedAnchors)
    }

    func prepare(_ request: ResearchPDFRequest, selectionHint: String? = nil, chosenRangeID: String? = nil,
                 correctedAnchors: ResearchPDFAnchors? = nil) throws -> [ResearchMaterial] {
        switch request.address {
        case let .anchors(range):
            let explicitPages = try physicalPages(range.prefix)
            let pageRange: ClosedRange<Int>?
            if let pages = explicitPages, let low = pages.min(), let high = pages.max() {
                guard pages.count == high - low + 1 else {
                    throw ResearchMaterialError.message("连续范围只能以相邻的文件页消歧，请指定单页或连续页段。")
                }
                pageRange = low...high
            } else { pageRange = nil }
            let section = ResearchPDFAddress.explicitSection(range.prefix)
            func read(_ anchors: ResearchPDFAnchors) throws -> [ResearchMaterial] {
                guard anchors.complete else {
                    throw ResearchPDFRangeAmbiguity(candidates: [], truncated: false, anchors: anchors,
                                                    reason: "需要同时给出范围的起点和终点原文。")
                }
                return try readRange(start: anchors.start, end: anchors.end, withinPages: pageRange, section: section,
                                     includeStart: range.includeStart, includeEnd: range.includeEnd, selectionHint: selectionHint,
                                     chosenRangeID: chosenRangeID, includeDetachedCaptions: range.includeCaptions)
            }
            if let correctedAnchors { return try read(correctedAnchors) }
            if range.separatorLimitExceeded {
                throw ResearchPDFRangeAmbiguity(candidates: [], truncated: false, anchors: range.first,
                                                reason: "起止短句含多个可能的分隔词，请核对两处原文。")
            }
            if range.endpoints.count <= 1 { return try read(range.first) }
            // A delimiter within an English endpoint and a literal Chinese tail
            // are both possible. Only scoped, indexed evidence can choose one.
            var verified: [ResearchMaterial]?
            var ambiguous: ResearchPDFRangeAmbiguity?
            var misses: ResearchPDFRangeAmbiguity?
            for (offset, anchors) in range.endpoints.enumerated() {
                let match: [ResearchMaterial]
                do {
                    match = try read(anchors)
                } catch let issue as ResearchPDFRangeAmbiguity {
                    if !issue.candidates.isEmpty {
                        if ambiguous != nil {
                            throw ResearchPDFRangeAmbiguity(candidates: [], truncated: false, anchors: range.first,
                                                            reason: "这句话对应多个可能的起止范围，请核对两处原文。")
                        }
                        ambiguous = issue
                    } else if offset == 0 { misses = issue }
                    continue
                } catch {
                    // A failed selected candidate belongs to another syntax
                    // split. A known candidate must still revalidate end to end.
                    guard chosenRangeID != nil else { throw error }
                    continue
                }
                if let previous = verified {
                    if previous.map(\.text) != match.map(\.text) || previous.map(\.pdfPositions) != match.map(\.pdfPositions) {
                        throw ResearchPDFRangeAmbiguity(candidates: [], truncated: false, anchors: range.first,
                                                        reason: "这句话对应多个可能的起止范围，请核对两处原文。")
                    }
                } else {
                    verified = match
                }
            }
            if let verified, ambiguous == nil { return verified }
            if let ambiguous, verified == nil { throw ambiguous }
            if verified != nil {
                throw ResearchPDFRangeAmbiguity(candidates: [], truncated: false, anchors: range.first,
                                                reason: "这句话对应多个可能的起止范围，请核对两处原文。")
            }
            if let misses { throw misses }
            throw ResearchMaterialError.message("所选范围已变化，请重新核对原文。")
        case let .quotation(quote): return try exact(quote, nil)
        case .location, .none: break
        }
        let requirement = ResearchPDFEvidenceCheck(kind: .location,
            target: ResearchPDFAddress.paragraphs(in: request.question) == nil ? "所问的文件页、栏或章节" : "所问的自然段",
            status: .verified)
        if let slices = try locatedSlices(request.question, requestCheck: requirement) {
            return try materials(slices, scope: "按指定文件页、栏或章节取出的原文",
                                 limit: ResearchMaterial.maximumLength, requestCheck: requirement)
        }
        return [request.requiringDefinitions(in: try ranked(request.question, background: nil))]
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
        try verified(slices, scope: "按整篇文件页序读取", limit: 7_200)
        return try materials(slices, scope: "整篇按文件页序连续分段，已排除页眉页脚", limit: 7_200)
    }
}

extension ResearchPDFIndex {
    /// Keep an author's explicit connection between objects separate from their
    /// crops. Searching for both references in the same verified paragraph
    /// avoids assembling a relationship out of unrelated nearby fragments.
    func supportingObjectRelation(_ ids: [ResearchPDFObjectID], near pages: [Int]) throws -> ResearchMaterial? {
        let targets = Set(ids.map { $0.parentFigure ?? $0 })
        guard targets.count > 1, !pages.isEmpty else { return nil }
        let origins = Set(pages)
        var candidates: [(distance: Int, slice: ResearchPDFSlice)] = []
        for (id, entry) in corpus.entries.enumerated() {
            try Task.checkCancellation()
            let block = self.pages[entry.page - 1].blocks[entry.block]
            guard block.kind == .body, !block.detachedCaption, block.reliable,
                  entry.text.utf16.count <= 1_600 else { continue }
            let mentioned = ResearchPDFObjectID.addresses(in: entry.text).map { $0.parentFigure ?? $0 }
            guard targets.isSubset(of: mentioned) else { continue }
            let distance = origins.map { abs($0 - entry.page) }.min() ?? 0
            candidates.append((distance, corpus.full(id)))
        }
        let ordered = candidates.sorted {
            $0.distance == $1.distance ? $0.slice.entry < $1.slice.entry : $0.distance < $1.distance
        }
        for candidate in ordered.prefix(6) {
            do {
                let scope = "同段中核对到的对象引用"
                try verified([candidate.slice], scope: scope, limit: 1_600, independent: true)
                return try materials([candidate.slice], scope: scope, limit: 1_700, independent: true).first
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    private static let concepts: [[String]] = [
        ["方法", "技术", "method", "methods", "approach", "algorithm", "technique", "framework"],
        ["传统", "常规", "baseline", "conventional", "traditional", "standard"],
        ["贡献", "创新", "contribution", "contributions", "propose", "proposed", "introduce", "novel"],
        ["局限", "局限性", "限制", "不足", "limitation", "limitations", "limited", "challenge", "however", "future"],
        ["结果", "实验", "results", "experiments", "experimental", "evaluation", "measured"],
        ["准确性", "精度", "accuracy", "accurate", "error", "precision"],
        ["加速", "效率", "速度", "speedup", "acceleration", "faster", "runtime", "speed", "time"],
        ["计算复杂度", "时间复杂度", "复杂度", "渐近", "complexity", "asymptotic", "flops"],
        ["梯度下降", "gradient", "descent"],
        ["收敛", "convergence", "converge", "converges"],
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
        let weightedTerms = weights.keys.sorted().compactMap { term -> (word: String, weight: Double)? in
            guard let count = corpus.frequency[term] else { return nil }
            let frequency = Double(count)
            return (term, weights[term, default: 0] * log(1 + (population - frequency + 0.5) / (frequency + 0.5)))
        }
        // Lexical relevance (BM25 term saturation with document frequency) plus
        // adjacent evidence and independent question facets. Score only the
        // indexed query terms before validating the geometry of matched blocks.
        for (id, p) in corpus.passages.enumerated() {
            try Task.checkCancellation()
            let entry = corpus.entries[p.slice.entry]
            let page = pages[entry.page - 1]
            let block = page.blocks[entry.block]
            guard allowed?.contains(p.slice.entry) != false, block.reliable, !unavailable.contains(entry.page) else { continue }
            var matches: Set<String> = []
            var score = 0.0
            let lengthPenalty = 1.2 * (0.35 + 0.65 * Double(p.count) / 72)
            for (word, weight) in weightedTerms {
                guard let count = p.terms[word] else { continue }
                matches.insert(word)
                let tf = Double(count)
                score += weight * tf * 2.2 / (tf + lengthPenalty)
            }
            guard score > 0,
                  block.lines.allSatisfy({ line in
                      line.regionVerified != false && (!line.orderUncertain || block.lines.count == 1 && line.regionVerified == true)
                  }) else { continue }
            if block.kind == .reference { score *= 0.30 }
            if block.kind == .footnote { score *= 0.65 }
            if !page.reliableOrder { score *= 0.7 }
            ranked.append(Hit(passage: id, score: score, matched: matches))
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
                if neighbor.reliable && neighbor.column == origin.column && (neighbor.kind == .body || neighbor.kind == .formula)
                    && neighbor.lines.allSatisfy({ !$0.orderUncertain && $0.regionVerified != false }) {
                    include(next)
                }
            }
        }
        let slices = selected.sorted().map { corpus.passages[$0].slice }
        let scope = unavailable.isEmpty ? "相关证据摘录；各处独立核对，未覆盖之处证据不足" :
            "可读页的相关证据摘录；文件第 \(Self.pageList(Array(unavailable))) 页不可核对"
        try verified(slices, scope: scope, limit: ResearchMaterial.maximumLength, independent: true)
        guard let value = try materials(slices, scope: scope, limit: ResearchMaterial.maximumLength, independent: true).first else {
            throw ResearchMaterialError.message("找不到可核对的文件证据。")
        }
        return value
    }

    private func materials(_ slices: [ResearchPDFSlice], scope: String, limit: Int,
                           independent: Bool = false, requestCheck: ResearchPDFEvidenceCheck? = nil) throws -> [ResearchMaterial] {
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
            var excerpts: [ResearchVerifiedExcerpt] = []
            var hasUnmappedSpan = false
            let doi = ResearchVerifiedExcerpt.doi(from: metadata.link)
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
                    let matching = sourcePositions(entry: entry, local: local)
                    positions += matching
                    if matching.isEmpty { hasUnmappedSpan = true }
                    if !matching.isEmpty {
                        excerpts.append(.init(kind: .body,
                            range: NSRange(location: clipped.location - offset, length: clipped.length),
                            title: metadata.title ?? title, page: entry.page, doi: doi, ocr: matching.contains(where: \.ocr)))
                    }
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
            material.verifiedExcerpts = excerpts.isEmpty ? nil : excerpts
            if let requestCheck {
                // Keep source mapping separate from the requested content claim.
                let located = !positions.isEmpty && !hasUnmappedSpan
                guard located || requestCheck.status != .verified else {
                    throw ResearchMaterialError.message("部分请求的原文未能映射到 PDF 页面，请核对起点、终点或所问章节。")
                }
                material.evidenceChecks = requestCheck.kind == .location ? [requestCheck] :
                    [requestCheck, .init(kind: .location, target: "原文页位", status: located ? .verified : .missing)]
            }
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
