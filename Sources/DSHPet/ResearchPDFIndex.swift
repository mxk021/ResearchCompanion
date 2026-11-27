import AppKit
import NaturalLanguage
import PDFKit
import Vision

/// A fixed document's local search corpus. Only a material returned by retrieve or
/// segments is serialized. The original PDF is opened read-only and never rewritten.
final class ResearchPDFIndex: Equatable, @unchecked Sendable {
    struct Page {
        let number: Int             // one-based physical page, independent of printed labels
        var blocks: [ResearchPDFBlock]
        let reliableOrder: Bool
        let state: ResearchPDFPageState
        var hasLocalOrderMap = false
        var geometry: ResearchPDFLayout.Geometry? = nil
        var equationLabels: Set<String> = []
        var text: String { blocks.map(\.text).joined(separator: "\n\n") }
        var utf16Length: Int { blocks.reduce(0) { $0 + $1.text.utf16.count + 2 } }
        var ocr: Bool { blocks.contains { $0.lines.contains(where: \.ocr) } }
    }
    private static let cache: NSCache<NSString, ResearchPDFIndex> = {
        let cache = NSCache<NSString, ResearchPDFIndex>()
        cache.countLimit = 5
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()
    // Evidence geometry and verbatim spans remain attached to the parser
    // that produced them. Historical answer snapshots remain unchanged.
    private static let layoutRevision = 5
    enum WholeTask { case translation, analysis }
    let pages: [Page]
    let reference: ResearchFileReference
    let title: String
    let corpus: ResearchPDFCorpus
    let objects: ResearchPDFObjectIndex
    let metadata: ResearchPDFMetadata
    let cardStatus: String
    let status: String
    let canRequestOCR: Bool
    let unavailable: Set<Int>
    static func == (left: ResearchPDFIndex, right: ResearchPDFIndex) -> Bool { left === right }

    static func summaryGroups(_ notes: [String], limit: Int = 18_000) throws -> [String] {
        var groups: [String] = []
        var group = ""
        for note in notes {
            for part in try split(note, limit: min(limit, 8_000)) {
                if !group.isEmpty && group.utf16.count + part.utf16.count + 2 > limit {
                    groups.append(group)
                    group = ""
                }
                group += (group.isEmpty ? "" : "\n\n") + part
            }
        }
        if !group.isEmpty { groups.append(group) }
        return groups
    }

    static func read(_ url: URL, title: String, recognizeScans: Bool = false,
                     measureRelationships: ((Duration) -> Void)? = nil,
                     progress: @Sendable (String) -> Void) throws -> ResearchPDFIndex {
        let reference = try ResearchFileReference.capture(url)
        let key = "\(layoutRevision)|\(url.standardizedFileURL.path)|\(reference.fingerprint)|\(recognizeScans)" as NSString
        if let existing = cache.object(forKey: key) {
            try Task.checkCancellation()
            return existing
        }
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            throw ResearchMaterialError.message("PDF 无法打开、没有页面或受到密码保护。")
        }
        let count = doc.pageCount
        var pages: [Page] = []
        var inReferences = false
        var lastUpdate: TimeInterval = -.infinity
        for i in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let number = i + 1
                guard let page = doc.page(at: i) else {
                    pages.append(Page(number: number, blocks: [], reliableOrder: false, state: .failed))
                    return
                }
                let geometry = ResearchPDFLayout.Geometry(page)
                let native = page.string ?? ""
                let readable = ResearchMaterial.hasReadableText(native)
                let length = native.trimmingCharacters(in: .whitespacesAndNewlines).count
                // Scans can have a native page number or a cover line over a raster body.
                let thin = !readable || (length < 420 && hasScanImage(page))
                    || (length < 16 && native.range(of: #"^\s*(?:\d+|[ivx]+)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil)
                let useOCR = thin && recognizeScans
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate >= 0.15 || i == count - 1 {
                    progress("正在" + (useOCR ? "本机 OCR" : "建立页索引") + " · PDF 第 \(number) / \(count) 页")
                    lastUpdate = now
                }
                let partialNative = !readable && !useOCR
                var fragments = readable || partialNative ? try ResearchPDFLayout.native(page, text: native, geometry: geometry) : []
                var state: ResearchPDFPageState = thin ? .needsOCR : .native
                if useOCR {
                    do {
                        let seen = try recognize(page, geometry: geometry)
                        // Prefer the PDF's exact glyphs wherever OCR merely re-read the same native text.
                        let extra = seen.lines.filter { observation in
                            !fragments.contains { native in
                                let intersection = native.box.intersection(observation.box)
                                return intersection.width > min(native.box.width, observation.box.width) * 0.72
                                    && intersection.height > min(native.box.height, observation.box.height) * 0.60
                                    && observation.line.text.localizedCaseInsensitiveContains(native.line.text)
                            }
                        }
                        fragments += extra
                        state = extra.isEmpty || seen.incomplete ? .unreadable : .ocr
                    } catch is CancellationError { throw CancellationError() }
                    catch { state = .failed }
                }
                let layout = ResearchPDFLayout.blocks(fragments, geometry: geometry, pageNumber: number,
                    inReferences: &inReferences, page: page, measureRelationships: measureRelationships)
                // Keep broken spans in the reading map. A bad glyph in an
                // unrelated equation need not disable a verified prose range,
                // but a range that includes that glyph must still fail.
                let localMap = !fragments.contains { $0.box.isEmpty } && (!partialNative || layout.blocks.lazy
                    .filter { $0.kind == .body }.flatMap(\.lines)
                    .filter { $0.text.utf16.count >= 24 && ResearchMaterial.hasReadableText($0.text) }.prefix(4).count == 4)
                pages.append(Page(number: number, blocks: layout.blocks, reliableOrder: layout.reliableOrder && localMap, state: state,
                                  hasLocalOrderMap: localMap, geometry: geometry,
                                  equationLabels: ResearchPDFObjectIndex.numberedEquations(in: native)))
            }
        }
        try distinguishRunningMargins(&pages)
        let index = try ResearchPDFIndex(pages: pages, metadata: ResearchPDFMetadata.read(doc),
                                         reference: reference, title: title, document: doc)
        try Task.checkCancellation()
        guard reference.matches(url) else {
            throw ResearchMaterialError.message("建立索引时原文件已变化，请重新读取。")
        }
        if !pages.contains(where: { $0.state == .failed }) {
            let cost = pages.reduce(0) { total, page in
                total + page.utf16Length * 32 + page.blocks.reduce(0) { $0 + 192 * $1.lines.count }
            }
            cache.setObject(index, forKey: key, cost: cost)
        }
        return index
    }

    /// Repeated journal/running titles are useful in the source view but interrupt a
    /// paragraph at a page break. An isolated line in the margin can still be body text.
    private static func distinguishRunningMargins(_ pages: inout [Page]) throws {
        func signatures(_ block: ResearchPDFBlock, on page: Page) -> [(key: String, kind: ResearchPDFBlockKind)] {
            guard block.lines.count <= 2, block.text.count < 180 else { return [] }
            var values: [(key: String, kind: ResearchPDFBlockKind)] = []
            if let margin = block.marginCandidate, [.body, .header, .footer].contains(block.kind) {
                let normal = block.text.lowercased().replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                values.append(((margin == .header ? "h" : "f") + normal, margin))
            }
            // A masthead may be larger than the body font, or set as a
            // heading. Confirm the same wording in the same narrow top band
            // on another physical page before removing it from reading order.
            if (block.kind == .body || block.kind == .heading), block.lines.count == 1,
               let geometry = page.geometry {
                let box = block.bounds.applying(geometry.display)
                let y = box.midY / geometry.canvas.height
                if y > 0.94, y < 1, block.text.contains(where: \.isLetter) {
                    values.append(("masthead:\(Int((y * 40).rounded())):" + block.text.lowercased(), .header))
                }
            }
            return values
        }
        var counts: [String: Int] = [:]
        for page in pages {
            try Task.checkCancellation()
            let keys = page.blocks.flatMap { signatures($0, on: page).map(\.key) }
            for value in Set(keys) { counts[value, default: 0] += 1 }
        }
        for i in pages.indices {
            try Task.checkCancellation()
            for j in pages[i].blocks.indices {
                let block = pages[i].blocks[j]
                if let value = signatures(block, on: pages[i]).first(where: { counts[$0.key, default: 0] >= 2 }) {
                    pages[i].blocks[j].kind = value.kind
                }
            }
        }
    }

    private static func hasScanImage(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) {
                var width = 0
                var height = 0
                if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
                   CGPDFDictionaryGetInteger(dictionary, "Height", &height), width >= 240 && height >= 100 {
                    found = true
                }
            }
            return !found
        }, nil)
        return found
    }

    init(pages: [Page], metadata: ResearchPDFMetadata, reference: ResearchFileReference, title: String,
         document: PDFDocument? = nil) throws {
        self.pages = pages
        self.objects = try ResearchPDFObjectIndex(pages: pages, document: document)
        self.corpus = try ResearchPDFCorpus(pages: pages)
        self.metadata = metadata
        self.reference = reference
        self.title = title
        let needsOCR = pages.filter { $0.state == .needsOCR }.map(\.number)
        let missing = pages.filter { $0.state == .unreadable }.map(\.number)
        let failed = pages.filter { $0.state == .failed }.map(\.number)
        let unavailable = Set(needsOCR + missing + failed)
        self.unavailable = unavailable
        canRequestOCR = !needsOCR.isEmpty || !failed.isEmpty
        let ocr = pages.filter(\.ocr).map(\.number)
        let uncertain = pages.filter { !unavailable.contains($0.number) &&
            (!$0.reliableOrder || $0.blocks.contains { !$0.reliable }) }.map(\.number)
        if failed.count == pages.count { cardStatus = "文件读取失败" }
        else if needsOCR.count == pages.count { cardStatus = "需要本机 OCR · \(needsOCR.count) 页" }
        else if missing.count == pages.count { cardStatus = "未识别到正文 · \(missing.count) 页" }
        else if !failed.isEmpty { cardStatus = "部分页面读取失败 · \(failed.count) 页" }
        else if !needsOCR.isEmpty { cardStatus = "部分页面需要 OCR · \(needsOCR.count) 页" }
        else if !missing.isEmpty { cardStatus = "部分页面无文本或未识别 · \(missing.count) 页" }
        else { cardStatus = "已完成全文索引 · \(pages.count) 页" }
        var details = [cardStatus]
        if !needsOCR.isEmpty { details.append("可运行本机 OCR 的文件页 \(Self.pageList(needsOCR))。") }
        if !missing.isEmpty { details.append("OCR 未取得可核对正文的文件页 \(Self.pageList(missing))。") }
        if !failed.isEmpty { details.append("读取或识别失败的文件页 \(Self.pageList(failed))。") }
        if !ocr.isEmpty { details.append("本机 OCR 页 \(Self.pageList(ocr))。") }
        if !uncertain.isEmpty { details.append("部分文字或版面顺序需核对的文件页 \(Self.pageList(uncertain))。") }
        status = details.joined(separator: " ")
    }

    /// Corroborate a native line only when rectangular selection disagrees with its glyph ranges.
    /// No OCR transcription enters the material. Unknown, extra or missing symbols fail closed.
    static func confirmNativeLineByOCR(_ line: ResearchPDFLine, page: PDFPage) throws -> Bool {
        try Task.checkCancellation()
        guard !line.ocr, let original = page.pageRef, !line.sourceRanges.isEmpty else { return false }
        let pieces = line.sourceRanges.compactMap { page.selection(for: $0)?.string }
        func comparable(_ value: String) -> String {
            value.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
        }
        let expected = comparable(line.text)
        guard pieces.count == line.sourceRanges.count, !expected.isEmpty,
              comparable(pieces.joined()) == expected else { return false }
        let geometry = ResearchPDFLayout.Geometry(page)
        let area = line.bounds.applying(geometry.display).insetBy(dx: -1, dy: -0.65)
        guard !area.isEmpty, area.width.isFinite, area.height.isFinite else { return false }
        let scale = min(3.5, 1800 / area.width, 160 / area.height)
        let width = Int(ceil(area.width * scale)), height = Int(ceil(area.height * scale))
        guard width >= 8, height >= 8,
              let image = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        image.setFillColor(gray: 1, alpha: 1)
        image.fill(CGRect(x: 0, y: 0, width: width, height: height))
        image.scaleBy(x: scale, y: scale)
        image.translateBy(x: -area.minX, y: -area.minY)
        image.concatenate(geometry.display)
        image.drawPDFPage(original)
        guard let crop = image.makeImage() else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        do { try VNImageRequestHandler(cgImage: crop).perform([request]) } catch { return false }
        try Task.checkCancellation()
        guard let observations = request.results, observations.count == 1,
              let candidate = observations[0].topCandidates(1).first, candidate.confidence >= 0.8 else { return false }
        return comparable(candidate.string) == expected
    }

    /// Vision boxes use the upright rendered image. Invert the exact render transform so
    /// the stored locator uses PDF coordinates even for rotated pages or offset crop boxes.
    private static func recognize(_ page: PDFPage, geometry: ResearchPDFLayout.Geometry) throws -> (lines: [ResearchPDFLayout.Fragment], incomplete: Bool) {
        try Task.checkCancellation()
        guard let original = page.pageRef, !geometry.canvas.isEmpty, !geometry.canvas.isInfinite else { return ([], true) }
        let size = geometry.canvas.size
        let scale = min(3, 2400 / max(size.width, size.height))
        let target = CGRect(x: 0, y: 0, width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        guard let canvas = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ResearchMaterialError.message("无法渲染 OCR 页面。")
        }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(target)
        let transform = original.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
        canvas.concatenate(transform)
        canvas.drawPDFPage(original)
        guard let image = canvas.makeImage() else { return ([], true) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        let detector = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request, detector])
        try Task.checkCancellation()
        let observations = request.results ?? []
        // With Chinese and English enabled, Vision may give a clear Latin line a score of
        // 0.5. Recheck borderline Latin text with the English recognizer and an independent
        // fast decoding pass. Agreement must include the entire string and the same location.
        var latinResults: [VNRecognizedTextObservation] = []
        var fastResults: [VNRecognizedTextObservation] = []
        if observations.contains(where: {
            guard let top = $0.topCandidates(1).first else { return false }
            return top.confidence < 0.65 && top.string.unicodeScalars.allSatisfy(\.isASCII)
        }) {
            let latin = VNRecognizeTextRequest()
            latin.recognitionLevel = .accurate
            latin.recognitionLanguages = ["en-US"]
            latin.usesLanguageCorrection = false
            let fast = VNRecognizeTextRequest()
            fast.recognitionLevel = .fast
            fast.recognitionLanguages = ["en-US"]
            fast.usesLanguageCorrection = false
            if (try? VNImageRequestHandler(cgImage: image).perform([latin, fast])) != nil {
                latinResults = latin.results ?? []
                fastResults = fast.results ?? []
            }
            try Task.checkCancellation()
        }
        func confirms(_ candidate: VNRecognizedText, in box: CGRect, with results: [VNRecognizedTextObservation],
                      minimum: Float) -> Bool {
            results.contains { result in
                guard let other = result.topCandidates(1).first, other.confidence >= minimum,
                      other.string == candidate.string else { return false }
                let overlap = box.intersection(result.boundingBox)
                let union = box.union(result.boundingBox)
                return !overlap.isNull && overlap.width * overlap.height > union.width * union.height * 0.48
            }
        }
        let scaleToPixels = CGAffineTransform(scaleX: target.width, y: target.height)
        func fragment(_ text: String, _ imageBox: CGRect, confidence: Float, confirmed: Bool) -> ResearchPDFLayout.Fragment {
            let bounds = imageBox.applying(scaleToPixels).applying(transform.inverted())
            return .init(line: .init(text: text, bounds: bounds, sourceRanges: [], confidence: confidence, ocr: true, corroboratedOCR: confirmed),
                         box: bounds.applying(geometry.display))
        }
        // Detection can find a region of text even when recognition returns no transcription.
        // Keep readable lines for inspection but never assert a complete range on such a page.
        var incomplete = (detector.results ?? []).contains { detected in
            let box = detected.boundingBox
            guard box.width * target.width >= 12, box.height * target.height >= 5 else { return false }
            return !observations.contains { item in
                let intersection = box.intersection(item.boundingBox)
                return intersection.width * intersection.height >= box.width * box.height * 0.44
                    && !intersection.isNull
            }
        }
        let words = try NSRegularExpression(pattern: #"\S+"#)
        var result: [ResearchPDFLayout.Fragment] = []
        for observation in observations {
            try Task.checkCancellation()
            guard let top = observation.topCandidates(1).first, ResearchMaterial.hasReadableText(top.string) else {
                incomplete = true
                continue
            }
            let confirmed = top.confidence < 0.65 &&
                confirms(top, in: observation.boundingBox, with: latinResults, minimum: 0.8) &&
                confirms(top, in: observation.boundingBox, with: fastResults, minimum: 0.5)
            if top.confidence < 0.50 && !confirmed { incomplete = true }
            let whole = fragment(top.string, observation.boundingBox, confidence: top.confidence, confirmed: confirmed)
            guard observation.boundingBox.width > 0.37 else { result.append(whole); continue }
            // Vision occasionally treats aligned columns as one observation. Its accurate-mode
            // word rectangles expose the intervening whitespace; retain the original substrings.
            let text = top.string
            var groups: [(range: NSRange, box: CGRect)] = []
            var valid = true
            for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      let wordBox = (try? top.boundingBox(for: range))?.boundingBox else { valid = false; break }
                if let previous = groups.last,
                   (wordBox.minX - previous.box.maxX) * target.width < max(target.width * 0.022, wordBox.height * target.height) {
                    groups[groups.count - 1] = (NSUnionRange(previous.range, match.range), previous.box.union(wordBox))
                } else { groups.append((match.range, wordBox)) }
            }
            if valid && groups.count > 1 {
                for group in groups {
                    result.append(fragment((text as NSString).substring(with: group.range), group.box, confidence: top.confidence, confirmed: confirmed))
                }
            } else { result.append(whole) }
        }
        return (result, incomplete)
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

    var preview: ResearchMaterial {
        ResearchMaterial(source: "PDF 文件", title: title, text: "", scope: status, fileReference: reference, pdfIndex: self)
    }

    static func wholeTask(_ question: String, mode: ResearchPromptMode) -> WholeTask? {
        let value = question.lowercased()
        // An explicit page-only or negative instruction must not initiate a paid multi-turn job.
        let limited = #"不要|不用|无需|不必|只(?:看|要|用|翻译|解释|分析|处理)|仅(?:需|看|翻译|解释|分析|处理)|\b(?:do not|don.t|skip|only)\b"#
        if value.range(of: limited, options: .regularExpression) != nil { return nil }
        let full = value.range(of: #"全文|全篇|整篇|整本|整份|通篇|通读|从头到尾|逐页|逐段|所有页|每一页|\b(?:entire|whole|full|all pages)\b"#, options: .regularExpression) != nil
        guard full else { return nil }
        if mode == .translate || value.contains("翻译") || value.contains("translat") { return .translation }
        let analysis = #"分析|解读|总结|归纳|梳理|概括|解释|评析|综述|复述|analy[sz]|summari[sz]|explain|review"#
        if mode == .explain || value.range(of: analysis, options: .regularExpression) != nil { return .analysis }
        return nil
    }

}
