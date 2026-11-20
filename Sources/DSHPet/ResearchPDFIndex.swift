import AppKit
import NaturalLanguage
import PDFKit
import Vision

/// A fixed document's local search corpus. Only a material returned by retrieve or
/// segments is serialized. The original PDF is opened read-only and never rewritten.
final class ResearchPDFIndex: Equatable, @unchecked Sendable {
    struct Page {
        let number: Int                 // one-based physical position, independent of printed labels
        let text: String
        let ocr: Bool
    }
    private struct Passage {
        let page: Int
        let text: String
        let words: Set<String>
    }

    enum WholeTask { case translation, analysis }
    let pages: [Page]
    let reference: ResearchFileReference
    let title: String
    private let passages: [Passage]
    let status: String
    let canRequestOCR: Bool
    private let unavailable: Set<Int>
    static func == (left: ResearchPDFIndex, right: ResearchPDFIndex) -> Bool { left === right }

    static func summaryGroups(_ notes: [String]) throws -> [String] {
        var groups: [String] = []
        var group = ""
        for note in notes {
            for part in try split(note, limit: 8_000) {
                if group.utf16.count + part.utf16.count + 2 > 18_000 {
                    groups.append(group)
                    group = ""
                }
                group += (group.isEmpty ? "" : "\n\n") + part
            }
        }
        if !group.isEmpty { groups.append(group) }
        return groups
    }

    static func read(_ url: URL, title: String, recognizeScans: Bool = false, progress: @Sendable (String) -> Void) throws -> ResearchPDFIndex {
        let reference = try ResearchFileReference.capture(url)
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            throw ResearchMaterialError.message("PDF 无法打开、没有页面或受到密码保护。")
        }
        let count = doc.pageCount
        var pages: [Page] = []
        var passages: [Passage] = []
        var needsOCR: [Int] = []
        var failed: [Int] = []
        var lastUpdate: TimeInterval = -.infinity
        for i in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let page = doc.page(at: i)
                let native = page?.string ?? ""
                let readable = ResearchMaterial.hasReadableText(native)
                // Some scans contain only a page-number text layer over a raster image.
                if page == nil { failed.append(i + 1) }
                let thinLayer = !readable || native.trimmingCharacters(in: .whitespacesAndNewlines).count < 16
                if page != nil && thinLayer { needsOCR.append(i + 1) }
                let useOCR = recognizeScans && thinLayer && page != nil
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.15 || i == count - 1 {
                    progress("正在" + (useOCR ? "本机 OCR" : "建立页索引") + " · PDF 第 \(i + 1) / \(count) 页")
                    lastUpdate = now
                }
                var recognized = ""
                if useOCR, let page {
                    do { recognized = try recognize(page) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failed.append(i + 1) }
                }
                let fromOCR = ResearchMaterial.hasReadableText(recognized) && (!readable || recognized.count > native.count)
                let text = fromOCR ? recognized : (readable ? native : "")
                pages.append(Page(number: i + 1, text: text, ocr: fromOCR))
                for slice in try split(text, limit: 1_700) {
                    passages.append(Passage(page: i + 1, text: slice, words: tokens(slice)))
                }
            }
        }
        try Task.checkCancellation()
        guard reference.matches(url) else {
            throw ResearchMaterialError.message("建立索引时原文件已变化，请重新读取。")
        }
        return ResearchPDFIndex(pages: pages, passages: passages, reference: reference, title: title, needsOCR: needsOCR, failed: failed, attemptedOCR: recognizeScans)
    }

    private init(pages: [Page], passages: [Passage], reference: ResearchFileReference, title: String, needsOCR: [Int], failed: [Int], attemptedOCR: Bool) {
        self.pages = pages
        self.passages = passages
        self.reference = reference
        self.title = title
        let missing = pages.filter { $0.text.isEmpty }.map(\.number)
        unavailable = Set(missing + failed)
        canRequestOCR = !needsOCR.isEmpty && (!attemptedOCR || !failed.isEmpty)
        let ocrPages = pages.filter(\.ocr).map(\.number)
        var lines = ["本机已检查全部 \(pages.count) 页。"]
        if !attemptedOCR && !needsOCR.isEmpty { lines.append("可在材料卡「…」中用本机 OCR 识别文字层缺失或过少的文件页 \(Self.pageList(needsOCR))。") }
        if !ocrPages.isEmpty { lines.append("本机 OCR 页 \(Self.pageList(ocrPages))。") }
        if !missing.isEmpty { lines.append("无可提取文字的文件页 \(Self.pageList(missing))。") }
        if !failed.isEmpty { lines.append("读取或识别失败的文件页 \(Self.pageList(failed))。") }
        status = lines.joined(separator: " ")

    }

    /// Snapshot of a CGPDF page keeps rendering independent of the AppKit main thread.
    private static func recognize(_ page: PDFPage) throws -> String {
        try Task.checkCancellation()
        guard let original = page.pageRef else { return "" }
        let bounds = original.getBoxRect(.cropBox)
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite else { return "" }
        let rotated = abs(original.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = min(3, 2400 / max(size.width, size.height))
        let target = CGRect(x: 0, y: 0, width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        guard let canvas = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return "" }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(target)
        canvas.concatenate(original.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        canvas.drawPDFPage(original)
        guard let image = canvas.makeImage() else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func split(_ text: String, limit: Int) throws -> [String] {
        // Walk graphemes once; prefer complete lines/words and keep all source whitespace.
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            var cursor = start
            var boundary = start
            var length = 0
            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                let units = text[cursor..<next].utf16.count
                if length + units > limit { break }
                length += units
                if length >= limit / 2 && text[cursor].isWhitespace { boundary = next }
                cursor = next
            }
            guard cursor > start else { throw ResearchMaterialError.message("PDF 中有异常超长字符，无法安全分段。") }
            let end = cursor < text.endIndex && boundary > start ? boundary : cursor
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    private static func tokens(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words = Set<String>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            words.insert(text[range].lowercased())
            return true
        }
        return words
    }

    static func searchTerms(_ text: String) -> Set<String> {
        let common: Set<String> = ["的", "是", "和", "在", "中", "请", "结合", "文件", "论文", "本文", "会话", "选区", "内容", "解释", "这个", "如何", "the", "a", "an", "and", "in", "of", "is", "this", "with", "paper", "file", "pdf", "page", "document", "selection"]
        return tokens(text).subtracting(common).filter { word in
            word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
        }
    }

    static func pageList(_ pages: [Int]) -> String {
        let numbers = Set(pages).sorted()
        var ranges: [String] = []
        var i = 0
        while i < numbers.count {
            let start = numbers[i]
            while i + 1 < numbers.count && numbers[i + 1] == numbers[i] + 1 { i += 1 }
            ranges.append(start == numbers[i] ? "\(start)" : "\(start)–\(numbers[i])")
            i += 1
        }
        return ranges.joined(separator: "、")
    }

    private func material(_ ids: [Int], scope: String) -> ResearchMaterial {
        let numbers = ids.map { passages[$0].page }
        let range = Self.pageList(numbers)
        var last = 0
        var body = ""
        for id in ids {
            let passage = passages[id]
            if passage.page != last {
                if !body.isEmpty { body += "\n\n" }
                body += "【PDF 文件第 \(passage.page) 页" + (pages[passage.page - 1].ocr ? " · 本机 OCR" : "") + "】\n"
            } else if id > 0 && !ids.contains(id - 1) {
                body += "\n[…]\n"
            }
            body += passage.text
            last = passage.page
        }
        return ResearchMaterial(source: "PDF 文件", title: title, text: body,
            scope: ResearchMaterial.bounded("\(scope) · 文件页 \(range) / 共 \(pages.count) 页。", limit: 510),
            fileReference: reference, pdfPages: range)
    }

    var preview: ResearchMaterial {
        var value = passages.isEmpty
            ? ResearchMaterial(source: "PDF 文件", title: title, text: "", scope: status, fileReference: reference)
            : material([0], scope: "本机索引预览")
        value.pdfIndex = self
        return value
    }

    static func wholeTask(_ question: String, mode: ResearchPromptMode) -> WholeTask? {
        let value = question.lowercased()
        // An explicit page-only or negative instruction must not initiate a paid multi-turn job.
        let limited = #"不要|不用|无需|不必|只(?:看|要|用|翻译|解释|分析|处理)|仅(?:需|看|翻译|解释|分析|处理)|\b(?:do not|don.t|skip|only)\b"#
        if value.range(of: limited, options: .regularExpression) != nil { return nil }
        let full = value.range(of: #"全文|全篇|整篇|整本|整份|通篇|逐页|逐段|所有页|每一页|\b(?:entire|whole|full|all pages)\b"#, options: .regularExpression) != nil
        guard full else { return nil }
        if mode == .translate || value.contains("翻译") || value.contains("translat") { return .translation }
        let analysis = #"分析|解读|总结|归纳|梳理|概括|解释|评析|综述|复述|analy[sz]|summari[sz]|explain|review"#
        if mode == .explain || value.range(of: analysis, options: .regularExpression) != nil { return .analysis }
        return nil
    }

    private func pageFilter(_ query: String) throws -> Set<Int>? {
        let q = query.lowercased()
        var selected = Set<Int>()
        func choose(_ a: Int, _ b: Int) throws {
            guard a >= 1, b >= a, b <= pages.count else {
                throw ResearchMaterialError.message("所问页码超出 PDF 的文件页 1–\(pages.count)。")
            }
            selected.formUnion(a...b)
        }
        let groupPattern = #"(?:第\s*)?([0-9]+(?:\s*[-–—至到、,，和与及]\s*(?:第\s*)?[0-9]+)*)\s*页|(?:\bpages?\s+|\bp\.\s*)([0-9]+(?:\s*(?:[-–—,]|and|to)\s*[0-9]+)*)"#
        let groups = try NSRegularExpression(pattern: groupPattern)
        let ranges = try NSRegularExpression(pattern: #"([0-9]+)(?:\s*(?:[-–—至到]|to)\s*(?:第\s*)?([0-9]+))?"#)
        for group in groups.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
            let parts = group.range(at: 1).location == NSNotFound ? group.range(at: 2) : group.range(at: 1)
            for part in ranges.matches(in: q, range: parts) {
                guard let first = Range(part.range(at: 1), in: q), let a = Int(q[first]) else {
                    throw ResearchMaterialError.message("无法识别 PDF 文件页码。")
                }
                var b = a
                if let end = Range(part.range(at: 2), in: q) {
                    guard let parsed = Int(q[end]) else { throw ResearchMaterialError.message("无法识别 PDF 文件页码。") }
                    b = parsed
                }
                try choose(a, b)
            }
        }
        if q.range(of: #"最后一页|末页|末尾|结尾|尾页|\blast page\b|\bfinal page\b"#, options: .regularExpression) != nil { selected.insert(pages.count) }
        if q.range(of: #"第一页|首页|开头|\bfirst page\b|\bopening page\b"#, options: .regularExpression) != nil { selected.insert(1) }
        if q.range(of: #"中间页|中间部分|中部|\bmiddle page\b"#, options: .regularExpression) != nil { selected.insert((pages.count + 1) / 2) }
        return selected.isEmpty ? nil : selected
    }

    func retrieve(_ question: String, backgroundKeywords: String? = nil) throws -> ResearchMaterial {
        let filter = try pageFilter(question)
        if let filter {
            let missing = unavailable.intersection(filter)
            if !missing.isEmpty { throw missingPages(Array(missing), whole: false) }
        }
        let candidates = passages.indices.filter { filter?.contains(passages[$0].page) ?? true }
        guard !candidates.isEmpty else { throw ResearchMaterialError.message("所问页没有可读取的文字，无法引用。") }
        var query = question
        for (phrase, terms) in [("附录", " appendix appendices supplement"), ("讨论", " discussion"),
                                ("结论", " conclusion conclusions"), ("方法", " methods methodology"),
                                ("结果", " results findings"), ("摘要", " abstract")] where query.contains(phrase) { query += terms }
        let words = backgroundKeywords.map { Self.searchTerms(query + " " + $0) } ?? Self.tokens(query)
        var frequency = [String: Int]()
        for id in candidates {
            try Task.checkCancellation()
            for word in words.intersection(passages[id].words) { frequency[word, default: 0] += 1 }
        }
        var ranked = candidates.map { id -> (Int, Double) in
            let score = words.intersection(passages[id].words).reduce(0.0) { sum, word in
                sum + log(1 + Double(candidates.count) / Double(frequency[word] ?? 1))
            }
            return (id, score)
        }
        ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var order = ranked.filter { $0.1 > 0 }.map(\.0)
        // An open-ended question should see the beginning, middle and end even with no term hit.
        if backgroundKeywords != nil, filter == nil, order.isEmpty {
            throw ResearchMaterialError.message("整篇索引中没有找到与选区或问题相关的文件段落。请指定文件页或关键词。")
        }
        if backgroundKeywords == nil, candidates.count > 1 {
            for n in [0, 4, 2, 1, 3] { order.append(candidates[(candidates.count - 1) * n / 4]) }
        }
        if backgroundKeywords == nil || filter != nil { order += candidates }
        let budget = backgroundKeywords == nil ? 12_000 : 4_000
        var ids = Set<Int>()
        var length = 0
        for id in order where !ids.contains(id) {
            let cost = passages[id].text.utf16.count + 52
            if length + cost <= budget { ids.insert(id); length += cost }
            if length >= budget - 50 { break }
        }
        if let filter {
            let omitted = filter.subtracting(ids.map { passages[$0].page })
            if !omitted.isEmpty {
                throw ResearchMaterialError.message("所问页段超过一次问答的材料上限，无法同时带入文件第 \(Self.pageList(Array(omitted))) 页。请缩小页段或使用整篇分析。")
            }
        }
        return material(ids.sorted(), scope: "从整篇本机索引选取的问答摘录")
    }

    private func missingPages(_ missing: [Int], whole: Bool) -> ResearchMaterialError {
        let next = canRequestOCR ? "可在材料卡「…」中运行本机 OCR，或另选可读页。" : "请另选可读页。"
        return .message((whole ? "无法完成整篇处理。" : "所问页段不完整。") + "文件第 \(Self.pageList(missing)) 页缺少可核对的正文。" + next)
    }

    func segments() throws -> [ResearchMaterial] {
        guard unavailable.isEmpty else { throw missingPages(Array(unavailable), whole: true) }
        var result: [ResearchMaterial] = []
        var ids: [Int] = []
        var length = 0
        for id in passages.indices {
            try Task.checkCancellation()
            let cost = passages[id].text.utf16.count + 52
            if !ids.isEmpty && length + cost > 7_200 {
                result.append(material(ids, scope: "整篇按文件页序连续分段"))
                ids.removeAll(keepingCapacity: true)
                length = 0
            }
            ids.append(id)
            length += cost
        }
        if !ids.isEmpty { result.append(material(ids, scope: "整篇按文件页序连续分段")) }
        return result
    }
}
