import AppKit
import PDFKit

enum ResearchPDFPageState { case native, ocr, needsOCR, unreadable, failed }
enum ResearchPDFBlockKind { case body, heading, caption, figureLabel, table, formula, footnote, header, footer, reference }

enum ResearchPDFParagraphRole: Equatable { case ordinary, statement, proof, algorithm }

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
    // Set only for regions whose geometric sequence admits competing interpretations.
    var orderUncertain = false
    // Native text recovered independently through a narrow geometric PDFKit selection.
    var regionVerified: Bool? = nil
    /// Display-space measurements of the ordinary characters, excluding the
    /// tall inline math and superscripts included in the enclosing rectangle.
    var typeHeight: CGFloat? = nil
    var typeCenter: CGFloat? = nil
    var reliable: Bool { confidence >= 0.65 || corroboratedOCR }
}

struct ResearchPDFBlock {
    var lines: [ResearchPDFLine]
    let bounds: CGRect
    let column: Int                 // 0 = full width or single column, 1 = left, 2 = right
    var kind: ResearchPDFBlockKind
    var marginCandidate: ResearchPDFBlockKind? = nil
    let reliable: Bool
    let text: String
    var detachedCaption = false
    var paragraphRole: ResearchPDFParagraphRole = .ordinary
    var printedFigureFrame: CGRect? = nil   // Upright display coordinates for the same verified page.
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
    private static let letters = NSCharacterSet.letters as NSCharacterSet

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
        var glyphHeights: [CGFloat] = []
        var glyphCenters: [CGFloat] = []
        func flush() {
            if let first = start {
                let range = NSRange(location: first, length: end - first)
                let valid = !box.isNull && !box.isEmpty
                let bounds = valid ? box : .zero
                let line = ResearchPDFLine(text: source.substring(with: range), bounds: bounds,
                    sourceRanges: [range], confidence: valid ? 1 : 0, ocr: false,
                    typeHeight: glyphHeights.isEmpty ? nil : median(glyphHeights, fallback: 0),
                    typeCenter: glyphCenters.isEmpty ? nil : median(glyphCenters, fallback: 0))
                result.append(Fragment(line: line, box: bounds.applying(geometry.display)))
            }
            start = nil
            box = .null
            previous = .null
            glyphHeights.removeAll(keepingCapacity: true)
            glyphCenters.removeAll(keepingCapacity: true)
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
                if letters.characterIsMember(code) {
                    glyphHeights.append(current.height)
                    glyphCenters.append(current.midY)
                }
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
    private static func gutter(_ lines: [Fragment], canvas: CGRect) -> (x: CGFloat?, ambiguousBands: [ClosedRange<CGFloat>]) {
        let width = canvas.width
        guard width > 0 else { return (nil, [-CGFloat.infinity...CGFloat.infinity]) }
        let prose = lines.filter { $0.box.width >= width * 0.105 && $0.box.height > 0 }
        let sparse = prose.filter { $0.box.midY > canvas.height * 0.1 && $0.box.midY < canvas.height * 0.9 }
        if prose.count < 4 {
            let splitRows = sparse.filter { l in sparse.contains { r in
                l.box.maxX < width * 0.62 && r.box.minX > width * 0.38 &&
                    r.box.minX - l.box.maxX > width * 0.08 && abs(l.box.midY - r.box.midY) < l.box.height
            } }
            return (nil, splitRows.map { $0.box.minY...$0.box.maxY })
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
        guard let best else { return (nil, []) }
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
        // Join nearby ambiguous baselines, including the space between table rows,
        // without marking body text above or below the table.
        var bands: [ClosedRange<CGFloat>] = []
        if threeLanes {
            for item in threeLaneRows.sorted(by: { $0.box.minY < $1.box.minY }) {
                let window = item.box.insetBy(dx: 0, dy: -item.box.height * 0.65)
                if let last = bands.last, window.minY - last.upperBound <= item.box.height * 1.1 {
                    bands[bands.count - 1] = last.lowerBound...max(window.maxY, last.upperBound)
                } else { bands.append(window.minY...window.maxY) }
            }
        }
        return (best.x, bands)
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
            let representative = parts.max(by: { $0.line.text.utf16.count < $1.line.text.utf16.count })?.line
            return .init(text: text, bounds: parts.reduce(.null) { $0.union($1.line.bounds) },
                         sourceRanges: parts.flatMap { $0.line.sourceRanges },
                         confidence: parts.map { $0.line.confidence }.min() ?? 0, ocr: parts.contains { $0.line.ocr },
                         corroboratedOCR: parts.contains { $0.line.corroboratedOCR } && parts.allSatisfy { $0.line.reliable },
                         typeHeight: representative?.typeHeight, typeCenter: representative?.typeCenter)
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

    private static func ordered(_ rows: [Row], gutter: CGFloat?, ambiguousBands: [ClosedRange<CGFloat>],
                                captionOwners: [Int: Int]) -> [Positioned] {
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
        for (index, row) in rows.enumerated() {
            let verticalExtent = row.box.minY...row.box.maxY
            if ambiguousBands.contains(where: { $0.overlaps(verticalExtent) }) {
                // A multi-lane grid is its own physical region. Preserve the visible rows
                // as a reviewable candidate. The surrounding prose must never enter it
                // through the global two-column ordering. Do not label its cells left/right.
                flush()
                finished.append(Positioned(row: row, line: row.line, column: 0))
                continue
            }
            var column = 0
            if let gutter, captionOwners[index] == nil {
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

    private static func captionStart(_ text: String, table: Bool) -> Bool {
        let number = #"(?:[A-Z][.-]?)?\d+(?:[.-]\d+)*[a-z]?(?!\w)"#
        let marker = (table ? #"(?i)^(?:table|表)\s*"# : #"(?i)^(?:fig(?:ure)?\.?|图)\s*"#) + number
        guard let label = text.range(of: marker, options: .regularExpression) else { return false }
        let remainder = text[label.upperBound...].trimmingCharacters(in: .whitespaces)
        // “Fig. 2 shows ...” and “Table 1 lists ...” are running text. A numbered caption
        // ordinarily starts a title, has a delimiter, or sits on its own line.
        guard let first = remainder.first else { return true }
        // A wrapped sentence can end with a figure reference at the left
        // edge of a line, followed by ordinary transitional prose.
        if matches(remainder, #"^\.\s*(?:moreover|however|therefore|thus|hence|indeed|respectively)\b"#) { return false }
        return first.isUppercase || ".:：、—–|".contains(first)
    }

    private static let statements = try! NSRegularExpression(pattern:
        #"^\s*(?:Theorem|Lemma|Corollary|Proposition|Definition|Observation|Claim|定理|引理|推论|命题|定义)\s+[\p{L}]?\d+(?:[.\-]\d+)*\s*(?=[.:(（：]|$)"#,
        options: .caseInsensitive)
    private static let proofs = try! NSRegularExpression(pattern: #"^\s*(?:Proof|证明)(?=\s*(?:[.:：]|of\b|$))"#, options: .caseInsensitive)
    private static let algorithms = try! NSRegularExpression(pattern:
        #"^\s*(?:Algorithm|算法)\s*\d+(?:[.\-]\d+)*(?:[.:：]|\s+(?=\p{Lu})|$)"#)

    static func paragraphRole(_ text: String) -> ResearchPDFParagraphRole {
        let range = NSRange(text.startIndex..., in: text)
        if statements.firstMatch(in: text, range: range) != nil { return .statement }
        if proofs.firstMatch(in: text, range: range) != nil { return .proof }
        if algorithms.firstMatch(in: text, range: range) != nil { return .algorithm }
        return .ordinary
    }

    static func endsCaptionSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".?!。？！".contains($0) } == true
    }

    static func openCaptionDelimiter(_ text: String) -> Character? {
        let partners: [Character: Character] = ["(": ")", "[": "]", "（": "）", "［": "］"]
        var open: [Character] = []
        for character in text {
            if let closing = partners[character] { open.append(closing) }
            else if character == open.last { open.removeLast() }
        }
        return open.last
    }

    static func isNearbyCaptionLine(_ line: CGRect, after previous: CGRect, left: CGFloat,
                                    height: CGFloat, leading: CGFloat) -> Bool {
        let advance = previous.midY - line.midY
        return advance >= leading * 0.72 && advance <= leading * 1.32 &&
            abs(line.minX - left) <= max(2, height * 0.32) &&
            abs(line.height - height) <= height * 0.20
    }

    /// A numbered spanning object can own a short terminal line before the
    /// gutter, even when that line would otherwise be assigned to body flow.
    /// Require a unique continuation with positive print and text evidence.
    private static func spanningCaptionOwners(_ rows: [Row], gutter: CGFloat, geometry: Geometry,
                                              page: PDFPage) -> [Int: Int] {
        func spansLanes(_ box: CGRect) -> Bool { box.minX < gutter - 1 && box.maxX > gutter + 1 }
        var candidates: [Int: [Int]] = [:]
        for (index, seed) in rows.enumerated() where spansLanes(seed.box) {
            let heading = seed.line
            guard heading.reliable, !heading.ocr,
                  captionStart(heading.text, table: false) || captionStart(heading.text, table: true) else { continue }
            let height = seed.box.height
            var previous = seed
            var caption = heading.text
            var advances: [CGFloat] = []
            for next in rows.indices.dropFirst(index + 1) {
                let row = rows[next]
                let leading = median(advances, fallback: height * 1.38)
                guard isNearbyCaptionLine(row.box, after: previous.box, left: seed.box.minX,
                                          height: height, leading: leading) else { break }
                let line = row.line
                guard paragraphRole(line.text) == .ordinary,
                      !captionStart(line.text, table: false), !captionStart(line.text, table: true) else { break }
                if spansLanes(row.box) {
                    advances.append(previous.box.midY - row.box.midY)
                    previous = row
                    caption += "\n" + line.text
                    continue
                }
                let successor = rows.indices.contains(next + 1) ? rows[next + 1].box : nil
                let separated = successor.map { row.box.midY - $0.midY >= leading * 1.35 } ?? true
                let closesDelimiter = openCaptionDelimiter(caption).map { line.text.contains($0) } == true
                let wrapsWord = previous.line.text.last.map { "-‐‑".contains($0) } == true
                let fullPreviousLine = previous.box.width >= seed.box.width * 0.91
                let ordinaryWrap = (fullPreviousLine || !advances.isEmpty || wrapsWord) &&
                    line.text.first(where: \.isLetter)?.isUppercase == false
                guard closesDelimiter || ordinaryWrap, row.box.maxX <= gutter + 1,
                      seed.box.maxX - previous.box.maxX <= height * 1.5,
                      !endsCaptionSentence(previous.line.text), endsCaptionSentence(line.text), separated,
                      line.reliable, !line.ocr,
                      verifies(line, displayBounds: row.box, geometry: geometry, page: page) else { break }
                candidates[next, default: []].append(index)
                break
            }
        }
        return candidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private static func verifies(_ line: ResearchPDFLine, displayBounds: CGRect,
                                 geometry: Geometry, page: PDFPage) -> Bool {
        guard !line.bounds.isEmpty, !line.sourceRanges.isEmpty else { return false }
        // PDFKit's range and rectangle selection use different addressing. Check the original
        // characters as well as their physical line. Allow only space differences between glyph runs.
        let parts = line.sourceRanges.compactMap { page.selection(for: $0)?.string }
        func letters(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let expected = letters(line.text)
        guard parts.count == line.sourceRanges.count, !expected.isEmpty,
              letters(parts.joined()) == expected else { return false }
        let strip = displayBounds.insetBy(dx: -0.25, dy: displayBounds.height * 0.28)
            .applying(geometry.display.inverted())
        guard let reading = page.selection(for: strip)?.string else { return false }
        return letters(reading) == expected
    }

    /// Labels leave the reading flow only when the numbered caption and the original
    /// graphic establish their relationship. Keep their source ranges for object queries.
    private static func identifyFigureLabels(_ blocks: inout [ResearchPDFBlock], page: PDFPage,
                                              geometry: Geometry, height: CGFloat) {
        guard let original = page.pageRef else { return }
        var painted: ResearchPDFImageGeometry.Placements?
        func placements() -> ResearchPDFImageGeometry.Placements {
            if let painted { return painted }
            let result = ResearchPDFImageGeometry.paintedObjects(on: original)
            painted = result
            return result
        }
        for c in blocks.indices where c >= 2 && blocks[c].kind == .caption {
            let caption = blocks[c].bounds.applying(geometry.display)
            let lane = blocks[c].column
            guard let title = blocks[c].lines.first?.text, captionStart(title, table: false) else { continue }

            if lane == 0 {
                let preceding = blocks[..<c].indices.filter { i in
                    let box = blocks[i].bounds.applying(geometry.display)
                    return [.body, .heading, .formula, .figureLabel].contains(blocks[i].kind) && box.minY > caption.maxY &&
                        box.maxY - caption.maxY < geometry.canvas.height * 0.26 &&
                        box.minX >= caption.minX - height && box.maxX <= caption.maxX + height
                }
                if caption.width > geometry.canvas.width * 0.65, caption.minY > geometry.canvas.height * 0.65,
                   preceding.count >= 5, preceding.allSatisfy({ i in
                       let block = blocks[i]
                       return block.lines.count <= 3 && block.lines.allSatisfy { !$0.ocr } &&
                           !block.lines.contains { line in
                               endsCaptionSentence(line.text) && line.text.split(whereSeparator: \.isWhitespace).count > 5 &&
                                   (line.typeHeight ?? line.bounds.applying(geometry.display).height) >= height * 0.9
                           }
                   }) {
                    let labels = preceding.flatMap { blocks[$0].lines.map { $0.bounds.applying(geometry.display) } }
                    let labelBounds = labels.reduce(CGRect.null) { $0.union($1) }
                    let region = CGRect(x: caption.minX, y: caption.maxY, width: caption.width,
                                        height: labelBounds.maxY - caption.maxY)
                    let pairedPanels = labelBounds.maxY > geometry.canvas.height * 0.92 &&
                        Set(preceding.map { blocks[$0].column }).isSuperset(of: [1, 2])
                    // A diagram can consist of rotated, scattered text
                    // fragments that have no meaningful prose column.
                    let fragmentedGraphic = labels.count >= 10 && labelBounds.width >= caption.width * 0.67 &&
                        labelBounds.height >= height * 3 && labelBounds.minY - caption.maxY < height * 3
                    var enclosedPanels = false
                    if !pairedPanels && !fragmentedGraphic {
                        let panels = placements().images.map { $0.applying(geometry.display) }.filter {
                            $0.minY >= caption.maxY - height && $0.minY < caption.maxY + height * 6 &&
                                $0.maxY <= labelBounds.maxY + height * 2 &&
                                $0.width >= height * 3 && $0.height >= height * 3 &&
                                $0.minX >= caption.minX - height && $0.maxX <= caption.maxX + height
                        }
                        let extent = panels.reduce(CGRect.null) { $0.union($1) }
                        enclosedPanels = panels.count >= 2 && extent.width >= caption.width * 0.55 &&
                            labels.allSatisfy { label in
                                label.minX >= extent.minX - height * 1.3 && label.maxX <= extent.maxX + height * 1.3 &&
                                    label.minY >= extent.minY - height * 2 && label.maxY <= extent.maxY + height * 2
                            }
                    }
                    if pairedPanels || fragmentedGraphic || enclosedPanels,
                       graphicInk(in: region, masking: labels, geometry: geometry, original: original) {
                        for i in preceding { blocks[i].kind = .figureLabel }
                        // The short last line can fall in a single lane under a
                        // cross-lane caption. Keep its original text and coordinates.
                        if let ending = blocks[c].lines.last, !endsCaptionSentence(ending.text) {
                            let follow = blocks.indices.filter { i in
                                guard i > c, blocks[i].kind == .body, blocks[i].lines.count == 1,
                                      let line = blocks[i].lines.first, !line.ocr, endsCaptionSentence(line.text),
                                      line.text.trimmingCharacters(in: .whitespaces).first?.isLowercase == true else { return false }
                                let box = line.bounds.applying(geometry.display)
                                return abs(box.minX - caption.minX) < height &&
                                    (height * 0.7...height * 1.6).contains(ending.bounds.applying(geometry.display).midY - box.midY)
                            }
                            if follow.count == 1 {
                                blocks[follow[0]].kind = .caption
                                blocks[follow[0]].detachedCaption = true
                            }
                        }
                        continue
                    }
                }
                // Panel captions can be complete sentences. Require separate
                // labels (a), (b) in the two lanes at a common height and a
                // third label adjacent to the enclosing numbered caption.
                let panels = blocks[..<c].indices.compactMap { index -> (Int, String, CGRect)? in
                    let block = blocks[index]
                    guard block.kind == .body || block.kind == .figureLabel, block.lines.count <= 2,
                          let line = block.lines.last, !line.ocr,
                          let tag = line.text.range(of: #"^\s*\([a-c]\)(?=\s+\p{L})"#, options: .regularExpression),
                          let letter = line.text[tag].last(where: \.isLetter) else { return nil }
                    let box = line.bounds.applying(geometry.display)
                    guard box.minY > caption.maxY, box.maxY - caption.maxY < geometry.canvas.height * 0.36 else { return nil }
                    return (index, String(letter), box)
                }
                let left = panels.filter { $0.1 == "a" }, right = panels.filter { $0.1 == "b" }
                let bottom = panels.filter { $0.1 == "c" }
                if left.count == 1, right.count == 1, bottom.count == 1,
                   left[0].2.maxX <= geometry.canvas.midX && right[0].2.minX >= geometry.canvas.midX,
                   abs(left[0].2.midY - right[0].2.midY) < height * 0.75,
                   bottom[0].2.maxY < left[0].2.minY && bottom[0].2.minY - caption.maxY < height * 3 {
                    for index in [left[0].0, right[0].0, bottom[0].0] { blocks[index].kind = .figureLabel }
                }
            }

            if lane != 0 {
                let preceding = blocks[..<c].indices.reversed().prefix { blocks[$0].column == lane }
                let labels = preceding.prefix { i in
                    let block = blocks[i]
                    return block.kind == .body && block.lines.allSatisfy { line in
                        let box = line.bounds.applying(geometry.display)
                        return !line.ocr && !box.isEmpty && box.height <= height * 1.4 &&
                            box.width < caption.width * 0.55 && line.text.count <= 55 &&
                            !line.text.contains(where: { ".!?。！？".contains($0) })
                    }
                }
                if labels.count >= 2, let previous = preceding.dropFirst(labels.count).first,
                   blocks[previous].kind == .body {
                    // Stop at a genuine line of column text. Choosing a lane solely
                    // from the caption and images can swallow prose between diagrams.
                    let prose = blocks[previous].lines.last!.bounds.applying(geometry.display)
                    if prose.width >= caption.width * 0.65 {
                        let laneBounds = caption.insetBy(dx: -height * 1.2, dy: 0)
                        let graphic = placements().images.map { $0.applying(geometry.display) }.reduce(CGRect.null) { union, image in
                            guard image.minX >= laneBounds.minX, image.maxX <= laneBounds.maxX,
                                  image.minY >= caption.maxY, image.maxY <= prose.minY,
                                  min(image.width, image.height) >= height * 2 else { return union }
                            return union.union(image)
                        }
                        let labeledArea = graphic.insetBy(dx: -height * 2.6, dy: -height * 2.5)
                        let overlapping = labels.filter { blocks[$0].bounds.applying(geometry.display).intersects(graphic) }
                        if overlapping.count >= 2, labels.allSatisfy({ i in
                            let box = blocks[i].bounds.applying(geometry.display)
                            return labeledArea.contains(box) && laneBounds.minX <= box.minX &&
                                box.maxX <= laneBounds.maxX && box.minY >= caption.maxY &&
                                box.maxY <= prose.minY
                        }) {
                            for i in labels { blocks[i].kind = .figureLabel }
                            continue
                        }
                    }
                }
            }

            // A vector diagram has no image placement. Verify strokes outside
            // its short text labels, in the same lane and immediately above
            // its numbered caption, before detaching it from running prose.
            // A hanging caption can be narrower than its illustration. Use
            // the following full text lane only when it encloses the caption.
            var laneBounds = caption
            if let next = blocks.dropFirst(c + 1).first(where: { $0.column == lane }),
               next.kind == .body, next.lines.count >= 2 {
                let prose = next.bounds.applying(geometry.display)
                if prose.maxY < caption.minY, prose.minX <= caption.minX, prose.maxX >= caption.maxX - height * 0.3 {
                    laneBounds = caption.union(prose)
                }
            }
            var members: [Int] = []
            var group = CGRect.null
            for i in stride(from: c-1, through: 0, by: -1) {
                let block = blocks[i], box = block.bounds.applying(geometry.display)
                guard block.column == lane,
                      [.body, .heading, .formula, .figureLabel].contains(block.kind),
                      block.lines.allSatisfy({ line in
                          let row = line.bounds.applying(geometry.display)
                          return !line.ocr && line.text.count < 45 && row.width < caption.width * 0.68 &&
                              !endsCaptionSentence(line.text)
                      }), box.minX >= laneBounds.minX - height * 2, box.maxX <= laneBounds.maxX + height * 2,
                      box.minY >= caption.maxY, box.maxY - caption.maxY < geometry.canvas.height * 0.44,
                      group.isNull ? box.minY - caption.maxY <= geometry.canvas.height * 0.22 :
                        box.minY - group.maxY <= height * 2.4 else { break }
                members.append(i)
                group = group.union(box)
            }
            guard members.count >= 2 else { continue }
            let gap = CGRect(x: min(group.minX, caption.minX), y: caption.maxY + 1,
                             width: max(group.maxX, caption.maxX) - min(group.minX, caption.minX),
                             height: group.maxY - caption.maxY)
            let labels = members.flatMap { blocks[$0].lines.map { $0.bounds.applying(geometry.display) } }
            // Vector charts authored in a bounded PDF Form frequently contain
            // hundreds of thousands of segments. Verify the already discovered
            // label cluster against that distinct, actually stroked object. A
            // whole-page form or a nearby illustration cannot satisfy this.
            let formCarriesLabels = placements().linePlots.contains { raw in
                let plot = raw.applying(geometry.display)
                return plot.width > caption.width * 0.45 && plot.width < caption.width * 1.42 &&
                    plot.height > height * 2 && plot.minY >= caption.maxY - height * 0.8 &&
                    plot.minY - caption.maxY < height * 3.5 &&
                    plot.height < geometry.canvas.height * 0.48 &&
                    labels.allSatisfy { plot.insetBy(dx: -height * 0.6, dy: -height * 0.6).contains($0) }
            }
            guard formCarriesLabels || graphicInk(in: gap, masking: labels, geometry: geometry, original: original) else { continue }
            for i in members { blocks[i].kind = .figureLabel }
        }
    }

    /// A boxed illustration can span both columns and contain labels that look like body text
    /// to PDFKit. Require a numbered caption inside an actual four-sided frame before treating
    /// any text inside the frame as detached from the narrative.
    private static func markFramedFigures(_ blocks: inout [ResearchPDFBlock], page: PDFPage,
                                          geometry: Geometry, height: CGFloat) {
        guard let original = page.pageRef else { return }
        for index in blocks.indices where blocks[index].kind == .caption && blocks[index].column == 0 {
            let caption = blocks[index].bounds.applying(geometry.display)
            guard geometry.canvas.contains(caption), caption.width >= geometry.canvas.width * 0.54,
                  let frame = figureFrame(around: caption, lineHeight: height, geometry: geometry, original: original)
            else { continue }
            blocks[index].printedFigureFrame = frame
            for i in blocks.indices {
                let block = blocks[i]
                guard !block.bounds.isEmpty, frame.contains(block.bounds.applying(geometry.display)) else { continue }
                switch block.kind {
                case .caption, .table:
                    blocks[i].detachedCaption = true
                case .body, .heading, .formula:
                    blocks[i].kind = .figureLabel
                default:
                    break
                }
            }
        }
    }

    private struct HorizontalEdge {
        let row: Int
        let left: Int
        let right: Int
    }

    static func figureFrame(around caption: CGRect, lineHeight: CGFloat, geometry: Geometry,
                            original: CGPDFPage, lane: CGRect? = nil) -> CGRect? {
        let horizontal = lane ?? geometry.canvas
        // For an individual object, also search below the anchor block: a printed
        // frame can enclose several caption paragraphs or lines of spatial math.
        let lower = lane == nil ? lineHeight * 2 : geometry.canvas.height * 0.20
        let area = CGRect(x: horizontal.minX, y: caption.minY - lower,
                          width: horizontal.width,
                          height: caption.height + lower + geometry.canvas.height * 0.56)
            .intersection(geometry.canvas)
        guard !area.isNull, !area.isEmpty else { return nil }
        // The grayscale bitmap is only used to verify printed borders, never to recover text.
        let scale = min(2, 1_248 / max(area.width, area.height))
        let width = Int((scale * area.width).rounded(.down))
        let height = Int((scale * area.height).rounded(.down))
        guard width >= 12, height >= 12 else { return nil }
        let upperCaption = Int(((area.maxY - caption.maxY) * scale).rounded(.down))
        let lowerCaption = Int(((area.maxY - caption.minY) * scale).rounded(.up))
        let minimumRun = Int((caption.width - lineHeight * 0.45) * scale)
        let edgeTolerance = Int((lineHeight * 0.32 * scale).rounded(.up))
        let minPanelHeight = Int((lineHeight * 3.2 * scale).rounded(.up))
        guard lowerCaption < height, upperCaption >= minPanelHeight else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        return pixels.withUnsafeMutableBytes { pixelBuffer in
            guard let drawing = CGContext(data: pixelBuffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            drawing.scaleBy(x: scale, y: scale)
            drawing.translateBy(x: -area.minX, y: -area.minY)
            // A frame enclosing this caption must have a long bottom edge
            // below it. Cull the expensive graph above the caption before
            // asking Core Graphics to rasterize any of its paths.
            drawing.saveGState()
            let stripHeight = CGFloat(height - lowerCaption + 1) / scale
            drawing.clip(to: CGRect(x: area.minX, y: area.minY, width: area.width, height: stripHeight))
            drawing.concatenate(geometry.display)
            drawing.drawPDFPage(original)
            drawing.restoreGState()
            let samples = pixelBuffer.bindMemory(to: UInt8.self)
            func edges(on row: Int) -> [HorizontalEdge] {
                var result: [HorizontalEdge] = []
                var start = 0
                let offset = row * width
                for x in 0...width where x == width || samples[offset + x] >= 186 {
                    if x - start >= minimumRun {
                        result.append(.init(row: row, left: start, right: x - 1))
                    }
                    start = x + 1
                }
                return result
            }
            func hasSide(from top: Int, to bottom: Int, at column: Int) -> Bool {
                let left = max(0, column - edgeTolerance)
                let right = min(width - 1, column + edgeTolerance)
                var ink = 0
                for row in top...bottom where samples[(row * width + left)...(row * width + right)]
                    .contains(where: { $0 < 186 }) { ink += 1 }
                return ink * 100 >= (bottom - top + 1) * 94
            }
            let bottomEdges = (lowerCaption..<height).flatMap(edges(on:))
            guard !bottomEdges.isEmpty else { return nil }
            drawing.concatenate(geometry.display)
            drawing.drawPDFPage(original)
            for y in (0...(upperCaption - minPanelHeight)).reversed() {
                for top in edges(on: y) {
                    for bottom in bottomEdges where abs(top.left - bottom.left) <= edgeTolerance &&
                        abs(top.right - bottom.right) <= edgeTolerance {
                        guard hasSide(from: top.row, to: bottom.row, at: top.left),
                              hasSide(from: top.row, to: bottom.row, at: top.right) else { continue }
                        let frame = CGRect(x: area.minX + CGFloat(top.left) / scale,
                                           y: area.minY + CGFloat(height - bottom.row - 1) / scale,
                                           width: CGFloat(top.right - top.left + 1) / scale,
                                           height: CGFloat(bottom.row - top.row + 1) / scale)
                        if frame.contains(caption) { return frame }
                    }
                }
            }
            return nil
        }
    }

    private static func checkCaptionEdges(_ blocks: inout [ResearchPDFBlock], page: PDFPage,
                                          geometry: Geometry, height: CGFloat) {
        var check = Set<Int>()
        var checkedThrough = -1
        var illustrations: [CGRect]?
        for i in blocks.indices where blocks[i].kind == .caption || blocks[i].kind == .table {
            let caption = blocks[i]
            guard !caption.detachedCaption, i > checkedThrough else { continue }
            var tail = i
            // Margin detection and paragraph grouping can put the end of a caption in
            // its own block. A visible, aligned continuation is still the same caption.
            while tail + 1 < blocks.count {
                let ending = blocks[tail].lines.last!
                let following = blocks[tail + 1], opening = following.lines[0]
                guard following.column == caption.column, following.kind == caption.kind,
                      paragraphRole(opening.text) == .ordinary,
                      !captionStart(opening.text, table: caption.kind == .table),
                      ending.text.last.map({ !".!?。！？:：".contains($0) }) == true else { break }
                let a = ending.bounds.applying(geometry.display), b = opening.bounds.applying(geometry.display)
                guard a.midY - b.midY > 0, a.midY - b.midY <= height * 1.75,
                      abs(a.minX - b.minX) <= height * 0.5, abs(a.height - b.height) <= height * 0.22
                else { break }
                tail += 1
            }
            checkedThrough = tail
            let last = blocks[tail].lines.last!.bounds.applying(geometry.display)
            let next = blocks.indices.dropFirst(tail+1).first { blocks[$0].column == caption.column }
            // A caption whose end cannot be separated from same-size running prose must remain
            // in the candidate. Losing an unmarked continuation would make the range incomplete.
            let separated = next.map { n in
                let line = blocks[n].lines[0].bounds.applying(geometry.display)
                return last.minY - line.maxY > height * 0.7 ||
                    line.minX - caption.bounds.applying(geometry.display).minX > height * 0.5 ||
                    blocks[n].kind == .heading || blocks[n].paragraphRole != .ordinary ||
                    abs(line.height - last.height) > height * 0.22
            } ?? false
            let lines = blocks[i...tail].flatMap(\.lines)
            let extent = blocks[i...tail].reduce(CGRect.null) { $0.union($1.bounds.applying(geometry.display)) }
            let possibleParagraphBoundary = zip(lines, lines.dropFirst()).contains { before, after in
                let a = before.bounds.applying(geometry.display), b = after.bounds.applying(geometry.display)
                // A short terminal line followed at the ordinary left margin can be the start
                // of prose even with identical baseline spacing. Keep the entire disputed block.
                let punctuation = before.text.last.map { ".!?。！？:：".contains($0) } ?? false
                let raggedBreak = punctuation && extent.maxX - a.maxX > max(height * 1.8, extent.width * 0.08)
                return raggedBreak || abs(a.height-b.height) > height * 0.22
            }
            let nextIsFigure = next.map { k in
                blocks[k].kind == .caption && captionStart(blocks[k].text, table: false) &&
                    extent.minY - blocks[k].bounds.applying(geometry.display).maxY > height * 2.5
            } ?? false
            var separateIllustrations = false
            if separated, possibleParagraphBoundary, nextIsFigure, let native = page.pageRef {
                if illustrations == nil {
                    illustrations = ResearchPDFImageGeometry.placements(on: native).map { $0.applying(geometry.display) }
                }
                separateIllustrations = illustrations?.contains { image in
                    min(image.width, image.height) >= height * 2 &&
                        image.minY >= extent.maxY && image.minY - extent.maxY <= height * 4 &&
                        image.maxX >= extent.minX && image.minX <= extent.maxX
                } == true
            }
            // Raised symbols can change line height inside an otherwise
            // uniform indented caption. Confirm its end against the return to
            // the wider body lane and a physical paragraph gap.
            let indentedCaption = next.map { n in
                let body = blocks[n]
                let first = body.lines[0].bounds.applying(geometry.display)
                return body.kind == .body && body.lines.count >= 2 && last.minY - first.maxY > height &&
                    first.minX + height * 2 < extent.minX &&
                    abs(first.maxX - extent.maxX) <= height &&
                    lines.allSatisfy { abs($0.bounds.applying(geometry.display).minX - extent.minX) < height * 0.5 } &&
                    endsCaptionSentence(lines.last!.text)
            } ?? false
            let detached = lines.count == 1 || separated && (!possibleParagraphBoundary || separateIllustrations || indentedCaption)
            for index in i...tail {
                blocks[index].detachedCaption = detached
                if !detached {
                    for j in blocks[index].lines.indices { blocks[index].lines[j].orderUncertain = true }
                    check.insert(index)
                }
            }
            // Verify the body/float boundary through a physical region selection. Only lines
            // near an actual float need this extra read on an otherwise well-ordered page.
            if let next, blocks[next].kind == .body { check.insert(next) }
        }
        for i in check {
            for j in blocks[i].lines.indices {
                let line = blocks[i].lines[j]
                guard !line.ocr else { continue }
                blocks[i].lines[j].regionVerified = verifies(line, displayBounds: line.bounds.applying(geometry.display),
                                                             geometry: geometry, page: page)
            }
        }
    }

    private static func graphicInk(in area: CGRect, masking: [CGRect] = [], geometry: Geometry, original: CGPDFPage) -> Bool {
        let w = 96, h = 48
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard area.width > 0, area.height > 0 else { return false }
        return pixels.withUnsafeMutableBytes { pixelBuffer in
            guard let drawing = CGContext(data: pixelBuffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            drawing.scaleBy(x: CGFloat(w) / area.width, y: CGFloat(h) / area.height)
            drawing.translateBy(x: -area.minX, y: -area.minY)
            drawing.concatenate(geometry.display)
            drawing.drawPDFPage(original)
            let samples = pixelBuffer.bindMemory(to: UInt8.self)
            for rect in masking {
                let x0 = max(0, Int(floor((rect.minX - area.minX) / area.width * CGFloat(w))))
                let x1 = min(w, Int(ceil((rect.maxX - area.minX) / area.width * CGFloat(w))))
                let y0 = max(0, Int(floor((area.maxY - rect.maxY) / area.height * CGFloat(h))))
                let y1 = min(h, Int(ceil((area.maxY - rect.minY) / area.height * CGFloat(h))))
                if x0 < x1, y0 < y1 {
                    for y in y0..<y1 { for x in x0..<x1 { samples[y*w+x] = 255 } }
                }
            }
            let rows = (0..<h).filter { y in samples[(y*w)..<((y+1)*w)].filter { $0 < 222 }.count >= 3 }
            return rows.count >= h / 4
        }
    }

    /// A rotated marginal stamp is split into short runs by PDFKit. Remove a
    /// verified narrow vertical strip before grouping horizontal baselines,
    /// otherwise a run can become part of the adjacent figure caption.
    private static func withoutMarginalStamps(_ fragments: [Fragment], canvas: CGRect) -> [Fragment] {
        let outer = canvas.width * 0.075
        let strips = Dictionary(grouping: fragments.filter { part in
            let box = part.box
            return !part.line.ocr && box.width > 2 && box.width < outer * 0.7 &&
                (box.maxX <= canvas.minX + outer || box.minX >= canvas.maxX - outer)
        }) { Int(($0.box.midX * 2).rounded()) }
        let stamps = strips.values.compactMap { parts -> CGRect? in
            let span = parts.reduce(CGRect.null) { $0.union($1.box) }
            guard parts.count >= 6, span.height >= canvas.height * 0.30,
                  parts.filter({ $0.box.height >= $0.box.width * 1.55 }).count >= 3,
                  parts.reduce(0, { $0 + $1.box.height }) >= span.height * 0.72,
                  parts.allSatisfy({ abs($0.box.width - span.width) <= 1 }) else { return nil }
            return span
        }
        guard !stamps.isEmpty else { return fragments }
        return fragments.filter { part in
            !stamps.contains { $0.contains(part.box) && abs($0.width - part.box.width) <= 1 }
        }
    }

    /// A ruled algorithm is a float. Assign its steps to that object before
    /// enumerating the running text. A heading by itself is insufficient.
    private static func attachAlgorithmSteps(_ blocks: inout [ResearchPDFBlock], page: PDFPage,
                                             geometry: Geometry, height: CGFloat) {
        guard let original = page.pageRef else { return }
        for index in blocks.indices where blocks[index].paragraphRole == .algorithm {
            let anchor = blocks[index].bounds.applying(geometry.display)
            let column = blocks[index].column
            let lane = blocks.lazy.filter { block in
                block.column == column && block.kind == .body
            }.map { $0.bounds.applying(geometry.display) }.filter { box in
                abs(box.minX - anchor.minX) < height && box.width >= anchor.width
            }.max(by: { $0.width < $1.width }) ?? anchor
            let area = CGRect(x: anchor.minX - height * 0.25,
                y: max(geometry.canvas.minY, anchor.minY - height * 25),
                width: max(anchor.width, lane.maxX - anchor.minX) + height * 0.5,
                height: min(anchor.minY - geometry.canvas.minY, height * 25) + anchor.height + height)
                .intersection(geometry.canvas)
            guard area.width >= height * 4, area.height > height * 4 else { continue }
            let width = 144, rows = Int(ceil(area.height * 3))
            var pixels = [UInt8](repeating: 255, count: width * rows)
            let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let draw = CGContext(data: buffer.baseAddress, width: width, height: rows,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                draw.scaleBy(x: CGFloat(width) / area.width, y: CGFloat(rows) / area.height)
                draw.translateBy(x: -area.minX, y: -area.minY)
                draw.concatenate(geometry.display)
                draw.drawPDFPage(original)
                return true
            }
            guard rendered else { continue }
            var rules: [CGFloat] = []
            for row in 0..<rows {
                let offset = row * width
                guard pixels[offset..<(offset + width)].filter({ $0 < 170 }).count >= width * 85 / 100 else { continue }
                let y = area.maxY - (CGFloat(row) + 0.5) * area.height / CGFloat(rows)
                if rules.last.map({ $0 - y > height * 0.20 }) ?? true { rules.append(y) }
            }
            guard rules.contains(where: { $0 >= anchor.minY - height * 0.75 && $0 <= anchor.maxY + height }),
                  let bottom = rules.first(where: { $0 < anchor.minY - height * 3 }) else { continue }
            let steps = blocks.indices.filter { i in
                let block = blocks[i]
                let box = block.bounds.applying(geometry.display)
                return i != index && block.column == column && (block.kind == .body || block.kind == .formula) &&
                    block.paragraphRole == .ordinary && box.maxY <= anchor.maxY &&
                    box.minY >= bottom - height * 0.25 && box.minX >= area.minX && box.maxX <= area.maxX
            }
            guard steps.count >= 2, !blocks.contains(where: { block in
                if block.column != column || block.paragraphRole != .statement { return false }
                let y = block.bounds.applying(geometry.display).midY
                return y > bottom && y < anchor.minY
            }) else { continue }
            for step in steps { blocks[step].paragraphRole = .algorithm }
        }
    }

    private static func startsRaisedFootnote(_ line: ResearchPDFLine, at rect: CGRect, geometry: Geometry,
                                             page: PDFPage?) -> Bool {
        guard rect.midY < geometry.canvas.height * 0.21,
              matches(line.text, #"^\s*[1-9]\d?(?=\p{Lu})"#), let page,
              let run = line.sourceRanges.first,
              let digit = page.selection(for: NSRange(location: run.location, length: 1))?.bounds(for: page),
              !digit.isEmpty else { return false }
        let marker = digit.applying(geometry.display)
        let fontHeight = line.typeHeight ?? rect.height
        return marker.height <= fontHeight * 0.85 &&
            marker.midY > (line.typeCenter ?? rect.midY) + fontHeight * 0.04
    }

    static func blocks(_ source: [Fragment], geometry: Geometry, pageNumber: Int,
                       inReferences: inout Bool, page: PDFPage? = nil,
                       measureRelationships: ((Duration) -> Void)? = nil) -> (blocks: [ResearchPDFBlock], reliableOrder: Bool) {
        let fragments = withoutMarginalStamps(source, canvas: geometry.canvas)
        guard !fragments.isEmpty else { return ([], false) }
        let canvas = geometry.canvas
        let prose = fragments.filter { $0.box.width >= canvas.width * 0.21 && $0.line.text.utf16.count >= 26 }
        let height = median(prose.map(\.box.height),
                            fallback: median(fragments.filter { $0.line.text.count >= 12 }.map(\.box.height), fallback: 10))
        let lanes = gutter(fragments, canvas: canvas)
        let positionedRows = rows(fragments, gutter: lanes.x, bodyHeight: height)
        let ownerStart = measureRelationships.map { _ in ContinuousClock.now }
        let captionOwners = lanes.x.flatMap { gutter in
            page.map { spanningCaptionOwners(positionedRows, gutter: gutter, geometry: geometry, page: $0) }
        } ?? [:]
        var ordered = ordered(positionedRows, gutter: lanes.x, ambiguousBands: lanes.ambiguousBands,
                              captionOwners: captionOwners)
        if let ownerStart { measureRelationships?(ownerStart.duration(to: .now)) }
        let hasUnplacedText = fragments.contains { $0.box.isEmpty }
        for i in ordered.indices {
            let here = ordered[i]
            var line = here.line
            line.orderUncertain = lanes.ambiguousBands.contains { $0.overlaps(here.row.box.minY...here.row.box.maxY) }
            ordered[i] = Positioned(row: here.row, line: line, column: here.column)
        }
        // Mark both members of a same-baseline collision. Selection inside a sound line remains
        // usable, even if another line in the block has a different order or text confidence.
        for i in ordered.indices.dropFirst() where ordered[i].column == ordered[i-1].column {
            let delta = ordered[i-1].row.box.midY - ordered[i].row.box.midY
            if abs(delta) < height * 0.42 {
                for j in [i-1, i] {
                    let item = ordered[j]
                    var line = item.line
                    line.orderUncertain = true
                    ordered[j] = Positioned(row: item.row, line: line, column: item.column)
                }
            }
        }
        if let page {
            for i in ordered.indices {
                let item = ordered[i]
                guard !item.line.ocr, !hasUnplacedText,
                      item.line.orderUncertain || !lanes.ambiguousBands.isEmpty || !item.line.reliable else { continue }
                var line = item.line
                line.regionVerified = verifies(line, displayBounds: item.row.box, geometry: geometry, page: page)
                ordered[i] = Positioned(row: item.row, line: line, column: item.column)
            }
        }
        let leading = Dictionary(grouping: ordered.filter { $0.row.box.width >= canvas.width * 0.24 }, by: \.column)
            .mapValues { lines in
                let starts = Dictionary(grouping: lines) { Int(($0.row.box.minX / 2).rounded()) }
                return starts.values.sorted {
                    $0.count == $1.count ? $0[0].row.box.minX < $1[0].row.box.minX : $0.count > $1.count
                }.first?[0].row.box.minX ?? 0
            }
        var footnoteTops: [Int: CGFloat] = [:]
        var copyrightTops: [Int: CGFloat] = [:]
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
                                text: active.map(\.text).joined(separator: "\n"),
                                paragraphRole: kind == .body ? paragraphRole(active[0].text) : .ordinary))
            active.removeAll(keepingCapacity: true)
            blockGood = true
        }
        for item in ordered {
            let s = item.line.text
            let rect = item.row.box
            let nearBottom = rect.midY < canvas.height * 0.28
            // At the page foot, a symbolic note marker followed by running
            // prose also covers author contributions and code availability.
            // A mathematical star followed by a quantity is insufficient.
            let authorFootnote = rect.midY < canvas.height * 0.15 &&
                (matches(s, #"^[*∗†‡+]?\s*(?:(?:current|present)\s+(?:affiliation|address)|author affiliations?)\s*:"#) ||
                 matches(s, #"^[*∗†‡]\s*\p{L}{2,}(?:[ ,]+\p{L}{2,}){3}\b"#))
            // Title-page contributor notes can follow a flattened glyph or numbered
            // marker and end before a four-word prose test can recognize them.
            let contributorNote = pageNumber == 1 && rect.midY < canvas.height * 0.17 &&
                matches(s, #"^(?:[*∗†‡⇤+]|\d{1,2})\s*(?:equal(?:ly)? contribut(?:ion|e[ds]?)\b|these authors contributed equally\b)"#)
            if authorFootnote || contributorNote || startsRaisedFootnote(item.line, at: rect, geometry: geometry, page: page) ||
                nearBottom && matches(s, #"^(?:correspondence|corresponding author|通讯作者|\*\s*(?:e-?mail|address))"#) {
                footnoteTops[item.column] = rect.maxY
            }
            if nearBottom && matches(s, #"^(?:©|c\p{Me}|copyright|open access\s+this article)"#) {
                copyrightTops[item.column] = max(copyrightTops[item.column] ?? 0, rect.maxY)
            }
            var kind: ResearchPDFBlockKind = .body
            let topMargin = rect.midY > canvas.height * 0.90 && rect.height <= height * 1.3
            let bottomMargin = rect.midY < canvas.height * 0.09 && rect.height <= height * 1.3
            let margin: ResearchPDFBlockKind? = topMargin ? .header : (bottomMargin ? .footer : nil)
            // A citation inside a continued paragraph is not page furniture.
            // Repeated author headers are checked after indexing adjacent pages.
            let running = #"^(?:https?://doi\.org|www\.|page\s+\d+|\d+\s*\||\d+\s*$)|\s\|\s"#
            // The first page often carries a one-off imprint rather than a
            // repeating footer. Some embedded fonts encode © as c + enclosing
            // circle. Require both a physical margin and publication metadata.
            let imprint = #"^(?:published by\s+|proceedings of\b.*\bpages?\s+\d)|(?:©|c\p{Me})\s*(?:19|20)\d{2}\b"#
            if rect.midY < canvas.height * 0.09, matches(s, imprint) {
                kind = .footer
            } else if let margin, matches(s, running) {
                kind = margin
            } else if rect.midY < (copyrightTops[item.column] ?? -.infinity) ||
                        rect.midY < (footnoteTops[item.column] ?? -.infinity)
                        || (nearBottom && rect.height < height * 0.70) {
                kind = .footnote
            } else if matches(s, #"^(?:(?:[IVX]+|\d+(?:\.\d+)*)[.)]?\s+)?(?:references|bibliography|参考文献)\s*[:.]?$"#) {
                kind = .heading
                inReferences = true
            } else if matches(s, #"^(?:(?:[IVX]+|\d+(?:\.\d+)*)[.)]?\s+)?(?:abstract|introduction|background|methods?(?: and materials)?|materials and methods|results?(?: and discussion)?|discussion|conclusions?|appendix(?:\s+[A-Z])?|acknowledg[e]?ments?|摘要|引言|方法|实验结果|结论)\s*[:.]?$"#) {
                kind = .heading
                inReferences = false
            } else if inReferences { kind = .reference }
            else if captionStart(s, table: false) { kind = .caption }
            else if captionStart(s, table: true) { kind = .table }
            else if matches(s, #"^(?:[IVX]+\.|\d+(?:\.\d+)+)\s+[[:upper:]][[:alpha:] ]+$"#) ||
                (rect.height > height * 1.48 && s.count < 70 && s.split(whereSeparator: \.isWhitespace).count <= 7 &&
                    !matches(s, #"[=∫∑∂∥≈≤≥+(),]"#)) { kind = .heading }
            else if s.count < 95 && matches(s, #"[=∫∑∂∥≈≤≥]"#) &&
                (rect.width < canvas.width * 0.32 || s.split(whereSeparator: \.isWhitespace).filter {
                    $0.filter(\.isLetter).count >= 3
                }.count < 4) { kind = .formula }

            let sameColumn = last?.column == item.column
            let delta = last.map { $0.row.box.midY - rect.midY } ?? 0
            // A paragraph ending a line with “and”, “see” or a preposition can
            // continue with a figure reference at the left margin of the next line.
            if [.caption, .table].contains(kind), lastKind == .body, sameColumn, let last,
               (height * 0.65...height * 1.6).contains(delta),
               abs(rect.minX - last.row.box.minX) < height * 0.55,
               abs(rect.height - last.row.box.height) < height * 0.30,
               matches(last.line.text, #"\b(?:and|or|in|see|of|from|to|cf\.)\s*$"#) { kind = .body }

            let indent = (leading[item.column].map { rect.minX - $0 } ?? 0)
            let paragraphIndent = indent >= height * 0.5 && indent <= height * 2.8 &&
                (last.map { $0.row.box.minX < rect.minX - height * 0.4 || $0.row.box.width < rect.width * 0.94 } ?? false)
            let startsParagraph = kind == .body && paragraphRole(s) != .ordinary
            let separate = !sameColumn || delta > height * 1.94 || delta <= height * 0.43 || paragraphIndent || startsParagraph
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
        if let page {
            let ownershipStart = measureRelationships.map { _ in ContinuousClock.now }
            identifyFigureLabels(&output, page: page, geometry: geometry, height: height)
            markFramedFigures(&output, page: page, geometry: geometry, height: height)
            checkCaptionEdges(&output, page: page, geometry: geometry, height: height)
            attachAlgorithmSteps(&output, page: page, geometry: geometry, height: height)
            if let ownershipStart { measureRelationships?(ownershipStart.duration(to: .now)) }
        }
        return (output, lanes.ambiguousBands.isEmpty && !hasUnplacedText)
    }
}
