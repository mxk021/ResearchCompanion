import AppKit
import PDFKit

enum ResearchPDFPageState { case native, ocr, needsOCR, unreadable, failed }
enum ResearchPDFBlockKind { case body, heading, caption, table, formula, footnote, header, footer, reference }

/// Bounds are always in unscaled, unrotated PDF page coordinates, including the crop-box origin.
/// PDFKit ranges index the immutable source page, including any ligatures or superscripts it exposes.
struct ResearchPDFLine {
    let text: String
    let bounds: CGRect
    let sourceRanges: [NSRange]
    var sourceRange: NSRange? { sourceRanges.count == 1 ? sourceRanges[0] : nil }
    let confidence: Float
    let ocr: Bool
    var corroboratedOCR = false
    var reliable: Bool { confidence >= 0.65 || corroboratedOCR }
}

struct ResearchPDFBlock {
    let lines: [ResearchPDFLine]
    let bounds: CGRect
    let column: Int                 // 0 = full width or single column, 1 = left, 2 = right
    var kind: ResearchPDFBlockKind
    var marginCandidate: ResearchPDFBlockKind? = nil
    let reliable: Bool
    let text: String
}

enum ResearchPDFLayout {
    /// Geometry for grouping is in upright display space. Only the original bounds escape the indexer.
    struct Fragment {
        let line: ResearchPDFLine
        let box: CGRect
    }

    struct Geometry {
        let canvas: CGRect
        let display: CGAffineTransform

        init(_ page: PDFPage) {
            let crop = page.bounds(for: .cropBox)
            let turned = abs(page.rotation) % 180 == 90
            canvas = CGRect(origin: .zero, size: turned ? CGSize(width: crop.height, height: crop.width) : crop.size)
            display = page.pageRef?.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
                ?? CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        }
    }

    private static let blanks = NSCharacterSet.whitespaces as NSCharacterSet
    private static let breaks = NSCharacterSet.newlines as NSCharacterSet

    /// PDFKit can return a single logical line that crosses the gutter or multiple ranges for a
    /// word and its citation. Inspect glyph positions before trusting its line boundaries.
    static func native(_ page: PDFPage, text: String, geometry: Geometry) throws -> [Fragment] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var result: [Fragment] = []
        var start: Int?
        var end = 0
        var box = CGRect.null
        var previous = CGRect.null
        func flush() {
            if let first = start {
                let range = NSRange(location: first, length: end - first)
                let valid = !box.isNull && !box.isEmpty
                let bounds = valid ? box : .zero
                result.append(Fragment(line: .init(text: source.substring(with: range), bounds: bounds,
                    sourceRanges: [range], confidence: valid ? 1 : 0, ocr: false), box: bounds.applying(geometry.display)))
            }
            start = nil
            box = .null
            previous = .null
        }
        let count = page.numberOfCharacters
        for i in 0..<source.length {
            if i.isMultiple(of: 512) { try Task.checkCancellation() }
            let code = source.character(at: i)
            if breaks.characterIsMember(code) { flush(); continue }
            if blanks.characterIsMember(code) { continue }
            // PDFKit's characterBounds can use glyph indices that skip synthetic spaces/newlines.
            // A one-character selection uses the same UTF-16 coordinate system as page.string.
            let glyph = i < count ? page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero : .zero
            let valid = !glyph.isEmpty && !glyph.isInfinite && glyph.minX.isFinite && glyph.minY.isFinite
            if valid {
                let current = glyph.applying(geometry.display)
                if !previous.isNull {
                    let gap = current.minX - previous.maxX
                    let h = max(3, min(current.height, previous.height))
                    let middle = (current.minX + previous.maxX) / 2 / max(1, geometry.canvas.width)
                    let atGutter = (0.22...0.78).contains(middle)
                    if gap > max(atGutter ? 8 : 15, h * (atGutter ? 0.96 : 1.7))
                        || (abs(current.midY - previous.midY) > h * 1.3 && current.minX < previous.maxX - h) {
                        flush()
                    }
                }
                box = box.union(glyph)
                previous = current
            }
            if start == nil { start = i }
            end = i + 1
        }
        flush()
        return result
    }

    private static func median(_ values: [CGFloat], fallback: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return fallback }
        return values.sorted()[values.count / 2]
    }

    /// A gutter needs lines on BOTH sides at overlapping heights. Test fixed x positions against
    /// the observed line ends and beginnings. Wide text elsewhere (abstracts, captions) may span it.
    private static func gutter(_ lines: [Fragment], canvas: CGRect) -> (x: CGFloat?, ambiguous: Bool) {
        let width = canvas.width
        guard width > 0 else { return (nil, true) }
        let prose = lines.filter { $0.box.width >= width * 0.105 && $0.box.height > 0 }
        let sparse = prose.filter { $0.box.midY > canvas.height * 0.1 && $0.box.midY < canvas.height * 0.9 }
        if prose.count < 4 {
            let splitRow = sparse.contains { l in sparse.contains { r in
                l.box.maxX < width * 0.62 && r.box.minX > width * 0.38 &&
                    r.box.minX - l.box.maxX > width * 0.08 && abs(l.box.midY - r.box.midY) < l.box.height
            } }
            return (nil, splitRow)
        }
        var best: (x: CGFloat, score: Double, pairs: Int)?
        for j in stride(from: 24, through: 76, by: 1) {
            let x = width * CGFloat(j) / 100
            let left = prose.filter { $0.box.maxX < x + 0.75 }
            let right = prose.filter { $0.box.minX > x - 0.75 && $0.box.minX - x < width * 0.16 }
            guard left.count >= 2, right.count >= 2 else { continue }
            // Adjacent columns share a vertical extent; same-baseline pairs are strong evidence.
            let rightByY = right.sorted { $0.box.midY < $1.box.midY }
            var cursor = 0
            var pairs = 0
            for l in left.sorted(by: { $0.box.midY < $1.box.midY }) {
                while cursor + 1 < rightByY.count &&
                        abs(rightByY[cursor + 1].box.midY - l.box.midY) <= abs(rightByY[cursor].box.midY - l.box.midY) {
                    cursor += 1
                }
                let r = rightByY[cursor]
                if abs(l.box.midY - r.box.midY) <= max(l.box.height, r.box.height) * 1.2 { pairs += 1 }
            }
            guard pairs >= 2 else { continue }
            let crossing = prose.filter { $0.box.minX + 1 < x && $0.box.maxX - 1 > x }.count
            let score = Double(min(left.count, right.count) + 3 * min(pairs, right.count))
                - 0.40 * Double(crossing) - 0.012 * abs(Double(j - 50))
            if best == nil || score > best!.score { best = (x, score, pairs) }
        }
        guard let best else { return (nil, false) }
        // A second populated gutter on one side is evidence for a table or a three-column page.
        // Scattered short equation/figure labels alone are insufficient for this test.
        let narrow = prose.filter { $0.box.width < width * 0.32 && $0.line.text.count >= 12 }
        let threeLaneRows = narrow.filter { l in
            guard l.box.midX < width * 0.39 else { return false }
            let matches = narrow.filter { abs($0.box.midY - l.box.midY) < max(3, l.box.height) }
            return matches.contains { $0.box.midX > width * 0.4 && $0.box.midX < width * 0.62 && $0.box.minX > l.box.maxX + 5 }
                && matches.contains { $0.box.midX > width * 0.72 }
        }
        // Repeated rows at distinct heights, not a single byline with three names.
        let ys = threeLaneRows.map(\.box.midY)
        let threeLanes = ys.count >= 2 && (ys.max() ?? 0) - (ys.min() ?? 0) > 12
        return (best.x, threeLanes)
    }

    private struct Row {
        var parts: [Fragment]
        var box: CGRect
        var line: ResearchPDFLine {
            var text = ""
            var prior: Fragment?
            for part in parts {
                if let prior {
                    let gap = part.box.minX - prior.box.maxX
                    // Source whitespace and a word-sized gap each justify a separator. Preserve
                    // tightly attached superscripts, punctuation and split ligatures as supplied.
                    if gap > min(prior.box.height, part.box.height) * 0.14 { text += " " }
                }
                text += part.line.text
                prior = part
            }
            return .init(text: text, bounds: parts.reduce(.null) { $0.union($1.line.bounds) },
                         sourceRanges: parts.flatMap { $0.line.sourceRanges },
                         confidence: parts.map { $0.line.confidence }.min() ?? 0, ocr: parts.contains { $0.line.ocr },
                         corroboratedOCR: parts.contains { $0.line.corroboratedOCR } && parts.allSatisfy { $0.line.reliable })
        }
    }

    /// Group nearby baselines first, then join adjacent fragments without crossing an observed gutter.
    private static func rows(_ fragments: [Fragment], gutter: CGFloat?, bodyHeight: CGFloat) -> [Row] {
        let sorted = fragments.sorted {
            $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY
        }
        var bands: [[Fragment]] = []
        var baseline: CGFloat?
        for f in sorted {
            let tolerance = max(1, min(bodyHeight, f.box.height) * 0.43)
            if let baseline, abs(baseline - f.box.midY) <= tolerance {
                bands[bands.count - 1].append(f)
            } else {
                bands.append([f])
                baseline = f.box.midY
            }
        }
        var result: [Row] = []
        for band in bands {
            var current: Row?
            for f in band.sorted(by: { $0.box.minX < $1.box.minX }) {
                if var row = current {
                    let gap = f.box.minX - row.box.maxX
                    let h = min(bodyHeight, max(row.box.height, f.box.height))
                    let crosses = gutter.map { row.box.maxX <= $0 + 1 && f.box.minX >= $0 - 1 && gap > max(3, h * 0.55) } ?? false
                    if !crosses && gap >= -h * 0.6 && gap <= h * 2.15 {
                        row.parts.append(f)
                        row.box = row.box.union(f.box)
                        current = row
                        continue
                    }
                    result.append(row)
                }
                current = Row(parts: [f], box: f.box)
            }
            if let current { result.append(current) }
        }
        return result
    }

    private struct Positioned {
        let row: Row
        let line: ResearchPDFLine
        let column: Int
    }

    private static func ordered(_ rows: [Row], gutter: CGFloat?) -> [Positioned] {
        var finished: [Positioned] = []
        var band: [Positioned] = []
        func flush() {
            if band.contains(where: { $0.column == 1 }) && band.contains(where: { $0.column == 2 }) {
                finished += band.filter { $0.column == 1 }
                finished += band.filter { $0.column == 2 }
            } else {
                // Short last line of a full-width abstract, or a heading before a full-width row.
                finished += band.map { Positioned(row: $0.row, line: $0.line, column: 0) }
            }
            band.removeAll(keepingCapacity: true)
        }
        for row in rows {
            var column = 0
            if let gutter {
                if row.box.maxX <= gutter + 1 { column = 1 }
                else if row.box.minX >= gutter - 1 { column = 2 }
            }
            let item = Positioned(row: row, line: row.line, column: column)
            if column == 0 { flush(); finished.append(item) }
            else { band.append(item) }
        }
        flush()
        return finished
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func blocks(_ fragments: [Fragment], geometry: Geometry, pageNumber: Int,
                       inReferences: inout Bool) -> (blocks: [ResearchPDFBlock], reliableOrder: Bool) {
        guard !fragments.isEmpty else { return ([], false) }
        let canvas = geometry.canvas
        let height = median(fragments.filter { $0.line.text.count >= 12 }.map(\.box.height), fallback: 10)
        let lanes = gutter(fragments, canvas: canvas)
        let ordered = ordered(rows(fragments, gutter: lanes.x, bodyHeight: height), gutter: lanes.x)
        let leading = Dictionary(grouping: ordered.filter { $0.row.box.width >= canvas.width * 0.24 }, by: \.column)
            .mapValues { lines in
                let starts = Dictionary(grouping: lines) { Int(($0.row.box.minX / 2).rounded()) }
                return starts.values.sorted {
                    $0.count == $1.count ? $0[0].row.box.minX < $1[0].row.box.minX : $0.count > $1.count
                }.first?[0].row.box.minX ?? 0
            }
        var footnoteTops: [Int: CGFloat] = [:]
        var copyrightTop: CGFloat?
        var last: Positioned?
        var lastKind: ResearchPDFBlockKind?
        var lastMargin: ResearchPDFBlockKind?
        var active: [ResearchPDFLine] = []
        var output: [ResearchPDFBlock] = []
        var blockGood = true
        func finish() {
            guard let kind = lastKind, let last, !active.isEmpty else { return }
            output.append(.init(lines: active, bounds: active.reduce(.null) { $0.union($1.bounds) },
                                column: last.column, kind: kind, marginCandidate: lastMargin, reliable: blockGood,
                                text: active.map(\.text).joined(separator: "\n")))
            active.removeAll(keepingCapacity: true)
            blockGood = true
        }
        for item in ordered {
            let s = item.line.text
            let rect = item.row.box
            let nearBottom = rect.midY < canvas.height * 0.28
            if nearBottom && matches(s, #"^(?:correspondence|corresponding author|通讯作者|\*\s*(?:e-?mail|address))"#) {
                footnoteTops[item.column] = rect.maxY
            }
            if nearBottom && matches(s, #"^(?:©|copyright|open access\s+this article)"#) {
                copyrightTop = max(copyrightTop ?? 0, rect.maxY)
            }
            var kind: ResearchPDFBlockKind = .body
            let topMargin = rect.midY > canvas.height * 0.90 && rect.height <= height * 1.3
            let bottomMargin = rect.midY < canvas.height * 0.09 && rect.height <= height * 1.3
            let margin: ResearchPDFBlockKind? = topMargin ? .header : (bottomMargin ? .footer : nil)
            let running = #"^(?:https?://doi\.org|www\.|page\s+\d+|\d+\s*\||\d+\s*$)|\bet al\.|\s\|\s"#
            if let margin, matches(s, running) {
                kind = margin
            } else if rect.midY < (copyrightTop ?? -.infinity) || rect.midY < (footnoteTops[item.column] ?? -.infinity)
                        || (nearBottom && rect.height < height * 0.70) {
                kind = .footnote
            } else if matches(s, #"^(?:(?:[IVX]+|\d+(?:\.\d+)*)[.)]?\s+)?(?:references|bibliography|参考文献)\s*[:.]?$"#) {
                kind = .heading
                inReferences = true
            } else if matches(s, #"^(?:(?:[IVX]+|\d+(?:\.\d+)*)[.)]?\s+)?(?:abstract|introduction|background|methods?(?: and materials)?|materials and methods|results?(?: and discussion)?|discussion|conclusions?|appendix(?:\s+[A-Z])?|acknowledg[e]?ments?|摘要|引言|方法|实验结果|结论)\s*[:.]?$"#) {
                kind = .heading
                inReferences = false
            } else if inReferences { kind = .reference }
            else if matches(s, #"^(?:fig(?:ure)?\.?\s*\d+\b|图\s*\d+)"#) { kind = .caption }
            else if matches(s, #"^(?:table\s+\d+\b|表\s*\d+)"#) { kind = .table }
            else if s.count < 130 && (rect.height > height * 1.48 || matches(s, #"^(?:[IVX]+\.|\d+(?:\.\d+)+)\s+[[:upper:]][[:alpha:] ]+$"#)) { kind = .heading }
            else if s.count < 95 && matches(s, #"[=∫∑∂∥≈≤≥]"#) { kind = .formula }

            let sameColumn = last?.column == item.column
            let delta = last.map { $0.row.box.midY - rect.midY } ?? 0
            let indent = (leading[item.column].map { rect.minX - $0 } ?? 0)
            let paragraphIndent = indent >= height * 0.5 && indent <= height * 2.8 &&
                (last.map { $0.row.box.minX < rect.minX - height * 0.4 || $0.row.box.width < rect.width * 0.94 } ?? false)
            let separate = !sameColumn || delta > height * 1.94 || delta <= height * 0.43 || paragraphIndent
            if kind == .body, sameColumn, !separate, let prior = lastKind, [.caption, .table].contains(prior) {
                kind = prior
            }
            if separate || lastKind != kind || lastMargin != margin || kind == .heading { finish() }
            // Substantially overlapping disjoint elements (e.g. stacked mathematical terms) have
            // valid coordinates but cannot be guaranteed to form a linear sentence.
            if sameColumn && delta >= 0 && delta < height * 0.42 && lastKind == kind { blockGood = false }
            blockGood = blockGood && item.line.reliable
            active.append(item.line)
            last = item
            lastKind = kind
            lastMargin = margin
        }
        finish()
        return (output, !lanes.ambiguous && !fragments.contains { $0.box.isEmpty })
    }
}
