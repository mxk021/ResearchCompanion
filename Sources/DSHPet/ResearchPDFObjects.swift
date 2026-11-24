import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ResearchPDFObjectID: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case figure, equation, table
    }

    let kind: Kind
    let number: String

    var label: String {
        switch kind {
        case .figure: return "Fig. " + number
        case .equation: return "式 (" + number + ")"
        case .table: return "Table " + number
        }
    }

    private static let panel = try! NSRegularExpression(pattern: #"^\s*[(（]([a-z])[)）]"#, options: [.caseInsensitive])
    fileprivate static let numberPattern = #"(?:[A-Z][.-]?)?\d+(?:[.-]\d+)*[a-z]?"#
    private static let numberedSuffix = try! NSRegularExpression(pattern:
        #"^\s*(?:、|[,，&/]|以及|和|与|及|\band\b)\s*[（(]\s*("# + numberPattern + #")\s*[)）]"#,
        options: [.caseInsensitive])
    private static let untypedList = try! NSRegularExpression(pattern:
        #"^\s*(?:(?:请\s*)?(?:使用|用|结合|比较|对照)|(?:use|compare)\b)\s*[（(]\s*("# +
        numberPattern + #")\s*[)）]"#, options: [.caseInsensitive])
    private static let address: NSRegularExpression = {
        let kind = #"fig(?:ure)?s?\.?|eq(?:uation)?s?\.?|tables?|公式|方程|图|表|式"#
        let marker = #"(?:编号(?:为|是)?|标号(?:为|是)?|标为|numbered)\s*"#
        let forward = #"(?<![\p{Latin}\p{N}])("# + kind + #")\s*(?:"# + marker +
            #")?[-#第]?\s*[(（\[]?\s*("# + numberPattern + #")\s*[)）\]]?(?!\d|\.\d)"#
        // In a reverse reference the number is marked explicitly. A short
        // modifier can describe the formula, but cannot cross a conjunction
        // or a second object name.
        let formulaModifier = #"(?:(?:完整|原始|对应)\s*(?:(?![图表及和或与的])\p{Han}){0,8}?(?=公式|方程))?"#
        let reverse = #"(?:"# + marker + #"[（(\[]?\s*|[（(\[]\s*)("# + numberPattern +
            #")\s*[)）\]]?\s*(?:的|所示的)?\s*"# + formulaModifier + #"(公式|方程|图|表|式)(?!号|达)"#
        return try! NSRegularExpression(pattern: forward + "|" + reverse, options: .caseInsensitive)
    }()

    static func addresses(in question: String) -> [Self] {
        let text = question as NSString
        var ordered: [Self] = []
        for match in address.matches(in: question, range: NSRange(location: 0, length: text.length)) {
            let forward = match.range(at: 1).location != NSNotFound
            let name = text.substring(with: match.range(at: forward ? 1 : 4)).lowercased()
            var number = text.substring(with: match.range(at: forward ? 2 : 3)).lowercased()
            let kind: Kind = (name.hasPrefix("fig") || name == "图") ? .figure :
                (name.hasPrefix("tab") || name == "表") ? .table : .equation
            // "Fig. 4(a)" has a named panel. Its outline still belongs to the same
            // figure and can be used with the panel reference when there is no subcaption.
            if kind == .figure || kind == .table {
                let tail = text.substring(from: NSMaxRange(match.range))
                if number.last?.isNumber == true,
                   let item = panel.firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count)),
                   let letter = Range(item.range(at: 1), in: tail) { number += tail[letter].lowercased() }
            }
            let id = Self(kind: kind, number: number)
            if !ordered.contains(id) { ordered.append(id) }
            let tail = text.substring(from: NSMaxRange(match.range))
            for number in followingNumbers(tail) {
                let other = Self(kind: kind, number: number)
                if !ordered.contains(other) { ordered.append(other) }
            }
        }
        return ordered
    }

    private static func followingNumbers(_ suffix: String) -> [String] {
        var remaining = suffix as NSString
        var list: [String] = []
        // Four total objects are already beyond the supported request limit.
        for _ in 0..<3 {
            guard let next = numberedSuffix.firstMatch(in: remaining as String,
                range: NSRange(location: 0, length: remaining.length)) else { break }
            list.append(remaining.substring(with: next.range(at: 1)).lowercased())
            remaining = remaining.substring(from: NSMaxRange(next.range)) as NSString
        }
        return list
    }

    static func untypedEquationList(in question: String) -> [Self] {
        let ns = question as NSString
        guard let first = untypedList.firstMatch(in: question, range: NSRange(location: 0, length: ns.length)) else { return [] }
        let more = followingNumbers(ns.substring(from: NSMaxRange(first.range)))
        guard !more.isEmpty else { return [] }
        return ([ns.substring(with: first.range(at: 1)).lowercased()] + more).map { .init(kind: .equation, number: $0) }
    }

    var parentFigure: Self? {
        guard kind == .figure, number.last?.isLetter == true else { return nil }
        return Self(kind: kind, number: String(number.dropLast()))
    }
}

struct ResearchPDFObjectEvidence: Sendable {
    let material: ResearchMaterial
    let images: [Data]
    let ids: [ResearchPDFObjectID]
    let needsVisual: Bool
}

/// An object stores addresses into the same immutable block index used by local retrieval.
/// Native rectangles are kept separate from adjacent definitions and source text ranges.
struct ResearchPDFObjectIndex {
    struct Line {
        let position: ResearchPDFSourcePosition
        let box: CGRect         // coordinates normalized to the page display orientation
        let text: String
        let kind: ResearchPDFBlockKind
        let reliable: Bool
        var typeHeight: CGFloat? = nil
        var typeCenter: CGFloat? = nil
        var nativeSpans: [NSRange] = []

        var printedHeight: CGFloat { typeHeight ?? box.height }
        var baseline: CGFloat { typeCenter ?? box.midY }

        var isProse: Bool {
            let words = text.split(whereSeparator: \.isWhitespace)
            // A string of equations can contain many letters inside indexed
            // function calls without containing a sentence (e.g. min, sum).
            if text.filter({ "=∑∫≔≈∈".contains($0) }).count >= 2 {
                let spelledWords = words.filter {
                    let word = $0.trimmingCharacters(in: .punctuationCharacters)
                    return word.count >= 3 && word.allSatisfy(\.isLetter)
                }
                if spelledWords.count <= 2 { return false }
            }
            return (words.count >= 6 && words.filter { $0.filter(\.isLetter).count >= 3 }.count >= 4) ||
                text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count >= 18
        }
    }

    struct Object {
        let id: ResearchPDFObjectID
        let page: Int
        var primary: [Line]
        var supporting: [Line]
        var visual: ResearchPDFSourcePosition?
        let exactEquation: String?
        let labels: [String]
        var supportingVisual: ResearchPDFSourcePosition? = nil
        var caption: [Line]? = nil
        var captionVisual: ResearchPDFSourcePosition? = nil
        var captionNeedsVisual = false
        var captionEncodingUncertain = false
        var captionBoundaryVerified = true
        var visualBoundaryUncertain = false
        var physicalEquationLane: CGRect? = nil
    }

    private static let number = ResearchPDFObjectID.numberPattern
    private static let rawEquationNumber = try! NSRegularExpression(pattern:
        #"(?i)[(（][ \t\r\n]{0,4}("# + number + #")[ \t\r\n]{0,4}[)）]"#)
    private static let proseReference = try! NSRegularExpression(pattern:
        #"(?i)(?:\b(?:eq(?:uation)?s?\.?|fig(?:ure)?s?\.?|table|section|see|as in)|参见|见公式)\s*$"#)
    private static let equationNumber = try! NSRegularExpression(pattern: #"(?i)[(（]("# + number + #")[)）]\s*$"#)
    private static let figureCaption = try! NSRegularExpression(pattern: #"(?i)^\s*(?:fig(?:ure)?\.?|图)\s*("# + number + #")(?=[\s.:：)—|]|$)"#)
    private static let tableCaption = try! NSRegularExpression(pattern: #"(?i)^\s*(?:table|表)\s*("# + number + #")(?=[\s.:：)—|]|$)"#)
    private static let numberedPanelTitle = try! NSRegularExpression(pattern: #"^\s*\(([1-9]\d?)\)\s+\p{L}"#)
    private static let firstPageAffiliation = try! NSRegularExpression(pattern: #"^\s*([1-9])(?=\p{Lu})\p{L}"#)
    private static let formulaCue = try! NSRegularExpression(pattern: #"[=≔≃≈≡∈≤≥∑∫√∇∂]|^\s*(?:min|max|arg\s*(?:min|max))\b"#)
    private static let definitionCue = try! NSRegularExpression(pattern:
        #"(?i)\b(?:where|denotes?|defined?|given by|represents?|parameters?|gradient|hessian|learning rate|update)\b|其中|表示|定义"#)
    private static let variableDefinition = try! NSRegularExpression(pattern:
        #"(?i)\b(?:where|denotes?|defined as|represents?|stands? for)\b|其中|表示|定义"#)
    private static let definitionOpening = try! NSRegularExpression(pattern:
        #"(?i)^\s*(?:where\b|其中|(?:in|for)\s*(?:eq\.?\s*)?[(（])"#)
    private static let variableName = try! NSRegularExpression(pattern:
        #"(?<![\p{Latin}\p{Greek}\d])[\p{Latin}\p{Greek}]\d*(?![\p{Latin}\p{Greek}\d])"#)
    private static let definedVariable = try! NSRegularExpression(pattern:
        #"(?<![\p{Latin}\p{Greek}\d])([\p{Latin}\p{Greek}]\d*)[ \t]*(?:(?i:is|are|denotes?|represents?|stands? for)\b|表示|指的是|定义为)"#)
    private static let sectionStart = try! NSRegularExpression(pattern:
        #"^\s*(?:\d+\.|\d+(?:\.\d+)+\.?|[IVX]+\.)\s+\p{Lu}"#)

    let objects: [ResearchPDFObjectID: [Object]]
    private let equationPages: [String: [ResearchPDFIndex.Page]]
    private let graphicPages: [Int: ResearchPDFIndex.Page]

    func hasEquationCandidate(_ id: ResearchPDFObjectID) -> Bool {
        id.kind == .equation && (objects[id]?.isEmpty == false || equationPages[id.number]?.isEmpty == false)
    }
    private final class Recovered {
        let values: [Object]
        init(_ values: [Object]) { self.values = values }
    }
    private let recovered: NSCache<NSString, Recovered> = {
        let value = NSCache<NSString, Recovered>()
        value.countLimit = 32
        return value
    }()
    private let images: NSCache<NSString, NSData> = {
        let value = NSCache<NSString, NSData>()
        value.countLimit = 12
        value.totalCostLimit = 5 * 1024 * 1024
        return value
    }()

    init(pages: [ResearchPDFIndex.Page], document: PDFDocument? = nil) throws {
        var items: [ResearchPDFObjectID: [Object]] = [:]
        var hints: [String: [ResearchPDFIndex.Page]] = [:]
        for page in pages {
            for label in page.equationLabels { hints[label, default: []].append(page) }
            try Task.checkCancellation()
            guard let geometry = page.geometry else { continue }
            let rows = Self.lines(on: page, geometry: geometry)
            let laneLines = Dictionary(grouping: rows.filter(\.isProse), by: { $0.position.column ?? 0 })
            let blockLines = Dictionary(grouping: rows, by: { $0.position.blockIndex })
            for row in rows where row.reliable {
                let item: Object?
                if row.kind == .caption, let (number, _) = Self.tag(Self.figureCaption, row.text),
                   let block = row.position.blockIndex, blockLines[block]?.first?.position == row.position {
                    item = Self.caption(.init(kind: .figure, number: number), at: row, rows: rows,
                                        lines: blockLines[block] ?? [], geometry: geometry, page: page.number)
                } else if row.kind == .table, let (number, _) = Self.tag(Self.tableCaption, row.text),
                          let block = row.position.blockIndex, blockLines[block]?.first?.position == row.position {
                    item = Self.caption(.init(kind: .table, number: number), at: row, rows: rows,
                                        lines: blockLines[block] ?? [], geometry: geometry, page: page.number)
                } else if row.kind != .header, row.kind != .footer, row.kind != .footnote,
                          let (number, tagRange) = Self.tag(Self.equationNumber, row.text) {
                    item = Self.equation(.init(kind: .equation, number: number), at: row, tagRange: tagRange,
                                         rows: rows, lanes: laneLines, geometry: geometry, native: document?.page(at: page.number - 1))
                } else {
                    item = nil
                }
                if let item { items[item.id, default: []].append(item) }
            }
        }
        objects = items
        equationPages = hints
        graphicPages = Dictionary(uniqueKeysWithValues: pages.map { ($0.number, $0) })
    }

    static func numberedEquations(in text: String) -> Set<String> {
        let source = text as NSString
        return Set(rawEquationNumber.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)).lowercased() })
    }

    private static func lines(on page: ResearchPDFIndex.Page, geometry: ResearchPDFLayout.Geometry) -> [Line] {
        var rows: [Line] = []
        for (blockIndex, block) in page.blocks.enumerated() where block.kind != .reference {
            var offset = 0
            for line in block.lines {
                let range = NSRange(location: offset, length: line.text.utf16.count)
                offset = NSMaxRange(range) + 1
                let box = line.bounds.applying(geometry.display)
                guard !box.isEmpty, !box.isInfinite, box.minX.isFinite, box.minY.isFinite else { continue }
                let location = ResearchPDFSourcePosition(page: page.number, bounds: line.bounds, column: block.column,
                    blockIndex: blockIndex, blockRange: range, sourceRange: line.sourceRange, ocr: line.ocr)
                rows.append(Line(position: location, box: box, text: line.text, kind: block.kind,
                                 reliable: line.reliable && !line.ocr && line.regionVerified != false &&
                                     ResearchMaterial.hasReadableText(line.text),
                                 typeHeight: line.typeHeight, typeCenter: line.typeCenter,
                                 nativeSpans: line.sourceRanges))
            }
        }
        return rows
    }

    private static func tag(_ regex: NSRegularExpression, _ text: String) -> (String, NSRange)? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: match.range(at: 1)).lowercased(), match.range)
    }

    private static func visualPosition(_ candidate: CGRect, page: Int, geometry: ResearchPDFLayout.Geometry) -> ResearchPDFSourcePosition? {
        let box = candidate.intersection(geometry.canvas)
        guard !box.isNull, box.width > 10, box.height > 5 else { return nil }
        return ResearchPDFSourcePosition(page: page, bounds: box.applying(geometry.display.inverted()))
    }

    /// Record the numbered caption as an anchor. Figure association is deferred
    /// until the object is requested and the original page can verify its geometry.
    private static func caption(_ id: ResearchPDFObjectID, at row: Line, rows: [Line], lines: [Line],
                                geometry: ResearchPDFLayout.Geometry, page: Int) -> Object {
        let owned = lines.prefix { $0.reliable }
        let caption = Array(owned)
        if id.kind == .figure {
            return Object(id: id, page: page, primary: caption, supporting: [],
                          visual: nil, exactEquation: nil, labels: [])
        }
        let (tableCaption, cells) = tableRows(around: row, seed: caption, rows: rows)
        let bounds = cells.reduce(CGRect.null) { $0.union($1.box) }
        var extent = bounds.insetBy(dx: -row.printedHeight, dy: -row.printedHeight * 0.58)
        if !extent.isNull, let captionEnd = tableCaption.last {
            let limit = row.box.midY > bounds.midY ? captionEnd.box.minY : geometry.canvas.maxY
            let floor = row.box.midY < bounds.midY ? row.box.maxY : geometry.canvas.minY
            extent = extent.intersection(CGRect(x: extent.minX, y: floor, width: extent.width, height: max(0, limit - floor)))
        }
        let visual = extent.isNull ? nil : visualPosition(extent, page: page, geometry: geometry)
        return Object(id: id, page: page, primary: tableCaption, supporting: [], visual: visual,
                      exactEquation: nil, labels: [])
    }

    /// Associate the caption to a visible grid of printed values. Tables can
    /// precede or follow their captions, even on consecutive pages of one paper.
    private static func tableRows(around start: Line, seed: [Line], rows: [Line]) -> ([Line], [Line]) {
        let height = max(5, start.printedHeight)
        let lane = rows.filter { start.position.column == 0 || $0.position.column == start.position.column }
        let neighbors = lane.filter { $0.position != start.position && separateCaption($0) }
        let above = neighbors.filter { $0.box.midY > start.box.midY }.map(\.box.minY).min() ?? .infinity
        let below = neighbors.filter { $0.box.midY < start.box.midY }.map(\.box.maxY).max() ?? -.infinity
        let candidates = lane.filter { $0.reliable && $0.box.midY > below && $0.box.midY < above &&
            $0.position != start.position && $0.kind != .header && $0.kind != .footer }
            .sorted { $0.box.midY > $1.box.midY }
        var bands: [[Line]] = []
        for row in candidates {
            if let last = bands.last?.first, abs(row.box.midY - last.box.midY) <= height * 0.29 {
                bands[bands.count - 1].append(row)
            } else {
                bands.append([row])
            }
        }
        let coordinates = bands.map { $0[0].box.midY }
        let numericPattern = try! NSRegularExpression(pattern: #"^[-−+]?(?:\d[\d.,]*(?:[eE][-+]?\d+)?%?|n/a|—|–)$"#,
                                                      options: .caseInsensitive)
        let numericColumns = bands.map { band in
            band.compactMap { cell -> CGFloat? in
                let fields = cell.text.split(whereSeparator: \.isWhitespace)
                guard !fields.isEmpty, fields.allSatisfy({ field in
                    numericPattern.firstMatch(in: String(field), range: NSRange(location: 0, length: field.utf16.count)) != nil
                }) else { return nil }
                return cell.box.maxX
            }
        }
        let valueRows = bands.indices.filter { index in
            let cells = bands[index]
            return numericColumns[index].count >= 2 || cells.count >= 2 && numericColumns[index].count == 1 &&
                cells.contains { row in row.text.split(whereSeparator: \.isWhitespace).filter { $0.first?.isNumber == true }.count >= 3 }
        }
        var groups: [[Int]] = []
        for index in valueRows {
            if let last = groups.last?.last, coordinates[last] - coordinates[index] <= height * 3.3,
               (coordinates[last] > start.box.midY) == (coordinates[index] > start.box.midY),
               numericColumns[index].contains(where: { x in numericColumns[last].contains { abs($0 - x) < height } }),
               !bands[(last + 1)..<index].contains(where: { $0.count == 1 && $0[0].isProse }) {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        let possible = groups.filter { $0.count >= 2 }.compactMap { group -> (CGFloat, [Line])? in
            guard let first = group.first, let last = group.last else { return nil }
            let data = bands[first...last].flatMap { $0 }
            let envelope = data.reduce(CGRect.null) { $0.union($1.box) }
            let pitch = (coordinates[first] - coordinates[last]) / CGFloat(group.count - 1)
            var head = first
            // A printed header shares the columns and baseline rhythm but may
            // have no numeric cells. A prose row or a caption ends the grid.
            while head > 0, coordinates[head - 1] - coordinates[head] < pitch * 1.45,
                  bands[head - 1].allSatisfy({ cell in
                      !separateCaption(cell) && !cell.isProse &&
                      cell.box.minX >= envelope.minX - height * 2.25 && cell.box.maxX <= envelope.maxX + height * 2.25
                  }), coordinates[head - 1] - envelope.maxY < pitch * 2.3 {
                head -= 1
            }
            let edge = coordinates[first] < start.box.midY ? coordinates[head] : coordinates[last]
            let distance = abs(edge - start.box.midY)
            guard distance < height * 9 else { return nil }
            return (distance, bands[head...last].flatMap { $0 })
        }.sorted { $0.0 < $1.0 }
        guard let (distance, cells) = possible.first, possible.dropFirst().first.map({ $0.0 - distance > height * 0.8 }) ?? true else {
            return (seed, [])
        }
        let tableAbove = cells[0].box.midY > start.box.midY
        let tableTop = cells.map(\.box.midY).max() ?? start.box.midY
        var caption = seed.filter { tableAbove || $0.box.midY > tableTop + height * 0.35 }
        // Some PDFs put a caption's continuation in the same block as the
        // table header. Read only the aligned caption rows before the header.
        for line in candidates where line.kind == .table && !separateCaption(line) && line.box.midY < start.box.midY &&
            (tableAbove || line.box.midY > tableTop + height * 0.35) && !caption.contains(where: { $0.position == line.position }) {
            guard let last = caption.last, (height * 0.65...height * 1.55).contains(last.box.midY - line.box.midY),
                  abs(line.box.minX - start.box.minX) < height * 0.75 else { break }
            caption.append(line)
        }
        return (caption, cells)
    }

    private static func figure(_ anchor: Object, on page: ResearchPDFIndex.Page,
                               previous: ResearchPDFIndex.Page?, next: ResearchPDFIndex.Page?,
                               native: PDFPage) throws -> Object {
        guard let geometry = page.geometry, let nativePage = native.pageRef,
              let start = anchor.primary.first else { return anchor }
        try Task.checkCancellation()
        let all = lines(on: page, geometry: geometry)
        let sourceColumn = start.position.column
        let peerLane = separateFigureLane(around: start, rows: all, canvas: geometry.canvas) ??
            floatingFigureLane(around: start, rows: all, canvas: geometry.canvas)
        let column = all.filter { $0.position.column == sourceColumn && (peerLane?.contains($0.box) ?? true) }
        let indexedBlock = start.position.blockIndex.map { page.blocks[$0] }
        let establishedFrame = indexedBlock?.printedFigureFrame.flatMap { frame in
            (peerLane?.contains(frame) ?? true) ? frame : nil
        }
        let indexedSeed = column.filter { $0.position.blockIndex == start.position.blockIndex }
        // Geometric ordering can assign an unseparated single-lane band to
        // column 0. If layout could not detach this caption, the block may
        // also contain text from the running lanes. Keep the spanning prefix.
        let needsBoundaryCheck = sourceColumn == 0 && indexedBlock?.detachedCaption == false &&
            establishedFrame == nil && start.box.width >= geometry.canvas.width * 0.58
        let indexedPrefix = needsBoundaryCheck
            ? Array(indexedSeed.prefix { $0.box.width >= start.box.width * 0.78 }) : indexedSeed
        let heights = indexedPrefix.map(\.printedHeight).sorted()
        let lineHeight = heights.isEmpty ? max(5, start.box.height) : max(5, heights[heights.count / 2])
        let advances = zip(indexedPrefix, indexedPrefix.dropFirst()).map { $0.baseline - $1.baseline }
            .filter { $0 > lineHeight * 0.75 && $0 < lineHeight * 2 }.sorted()
        let leading = advances.isEmpty ? lineHeight * 1.38 : advances[advances.count / 2]
        let (captionPrefix, detachedProse) = separateCaptionTail(indexedPrefix, height: lineHeight, leading: leading)
        let possibleContinuation = all.filter { $0.position.blockIndex != start.position.blockIndex &&
            (peerLane?.contains($0.box) ?? true) }
        let followingIndexedRows = detachedProse ? [] : Array(indexedSeed.dropFirst(indexedPrefix.count))
        let sameLine = captionPrefix.count == 1 ? splitCaptionLead(start, in: possibleContinuation) : nil
        let seed = captionPrefix + (sameLine.map { [$0] } ?? [])
        let seedBounds = seed.reduce(CGRect.null) { $0.union($1.box) }
        var (initialCaption, initialBoundary) = extendCaption(seed,
            with: possibleContinuation.filter { row in
                row.position.column == sourceColumn || row.kind == .caption && !separateCaption(row) &&
                    row.position.blockIndex.map { page.blocks[$0].detachedCaption } == true
            } + followingIndexedRows,
            lineHeight: lineHeight, leading: leading)
        // Inline math can split a spanning caption *horizontally*. Once the
        // two fragments close the same physical row, follow the native block
        // that continues across the gutter at the established line spacing.
        if needsBoundaryCheck, let part = followingIndexedRows.first,
           let previous = seed.last, abs(part.box.minX - start.box.minX) < lineHeight,
           (leading * 0.45...leading * 1.55).contains(previous.baseline - part.baseline),
           let continuation = possibleContinuation.first(where: {
               $0.position.column == sourceColumn && $0.position.blockIndex != nil &&
               abs($0.baseline - part.baseline) < lineHeight * 0.65 &&
               abs($0.box.minX - part.box.maxX) < lineHeight * 1.8 &&
               abs($0.box.maxX - seedBounds.maxX) < lineHeight * 2
           }) {
            let rest = possibleContinuation.filter { $0.position.blockIndex == continuation.position.blockIndex }
            if rest.first?.position == continuation.position, rest.count >= 2,
               rest.dropFirst().allSatisfy({ abs($0.box.minX - start.box.minX) < lineHeight &&
                   !separateCaption($0) && $0.box.maxX <= seedBounds.maxX + lineHeight }),
               zip(rest, rest.dropFirst()).allSatisfy({ (leading * 0.45...leading * 1.6).contains($0.baseline - $1.baseline) }) {
                initialCaption = seed + [part] + rest
                initialBoundary = rest.last.map { ResearchPDFLayout.endsCaptionSentence($0.text) } ?? false
            }
        }
        if needsBoundaryCheck, initialCaption.count == seed.count,
           let ending = seed.last, let hanging = followingIndexedRows.first,
           hanging.reliable, hanging.box.minX >= start.box.minX + lineHeight * 1.6,
           (ending.box.intersects(hanging.box) || (leading * 0.45...leading * 2.25).contains(ending.baseline - hanging.baseline)),
           !ResearchPDFLayout.endsCaptionSentence(ending.text), ResearchPDFLayout.endsCaptionSentence(hanging.text) {
            initialCaption.append(hanging)
            initialBoundary = true
        }
        if needsBoundaryCheck, let firstAdded = initialCaption.dropFirst(seed.count).first,
           let ending = initialCaption.last {
            // A short terminal line can end before the gutter. If it looks
            // like ordinary unindented prose and is immediately followed by
            // the same typography, retain only the proven spanning prefix.
            let hangs = firstAdded.box.minX >= start.box.minX + lineHeight * 1.6
            let competes = all.contains { line in
                !initialCaption.contains { $0.position == line.position } &&
                    !separateCaption(line) && abs(line.printedHeight - lineHeight) <= lineHeight * 0.25 &&
                    abs(line.box.minX - start.box.minX) <= lineHeight * 0.65 &&
                    (leading * 0.60...leading * 1.45).contains(ending.baseline - line.baseline)
            }
            if !hangs && (competes || !ResearchPDFLayout.endsCaptionSentence(ending.text)) {
                initialCaption = seed
                initialBoundary = false
            }
        }
        let placements = ResearchPDFImageGeometry.placements(on: nativePage).map { $0.applying(geometry.display) }
            .filter { peerLane?.contains($0) ?? true }
        let graphicSpansCaption = placements.contains { box in
            return box.width > geometry.canvas.width * 0.61 && box.minY >= seedBounds.maxY &&
                box.minY - seedBounds.maxY < geometry.canvas.height * 0.29
        }
        let followingColumn = sourceColumn == 1 && peerLane == nil
            ? matchingCaptionLane(initialCaption, in: all.filter { $0.position.column == 2 },
                                  height: lineHeight, leading: leading, graphicSpansCaption: graphicSpansCaption) : []
        let spansColumns = !followingColumn.isEmpty || sourceColumn != 0 && graphicSpansCaption
        let fullWidthFigure = peerLane == nil && (sourceColumn == 0 || spansColumns)
        let figureLines = peerLane.map { lane in all.filter { lane.contains($0.box) } } ?? (fullWidthFigure ? all : column)
        let surroundingProse = figureLines.filter { $0.kind == .body && $0.reliable && $0.isProse }
        let margin = max(2 * lineHeight, geometry.canvas.width * 0.028)
        let captionWidth = (seed + followingColumn).reduce(CGRect.null) { $0.union($1.box) }
        let left = max(geometry.canvas.minX, min(captionWidth.minX, surroundingProse.map(\.box.minX).min() ?? captionWidth.minX) - margin)
        let right = min(geometry.canvas.maxX, max(captionWidth.maxX, surroundingProse.map(\.box.maxX).max() ?? captionWidth.maxX) + margin)
        let lane = CGRect(x: left, y: geometry.canvas.minY, width: right - left, height: geometry.canvas.height)
            .intersection(peerLane ?? geometry.canvas)
        let frame = establishedFrame ?? ResearchPDFLayout.figureFrame(around: seedBounds, lineHeight: lineHeight,
            geometry: geometry, original: nativePage, lane: lane)
        try Task.checkCancellation()
        let aboveOrBelow = figureLines.filter {
            $0.position.blockIndex != start.position.blockIndex && $0.kind != .reference
        }
        var caption = seed
        var boundaryVerified = true
        if let frame {
            // A verified, closed print border can enclose both the object and
            // multiple caption blocks. A second independent numbered caption ends this one.
            let framedCandidates = aboveOrBelow + followingIndexedRows
            for row in framedCandidates.filter({
                $0.box.midY < start.box.midY && frame.insetBy(dx: -1, dy: -1).contains($0.box)
            }).sorted(by: { $0.box.midY > $1.box.midY }) {
                if ResearchPDFLayout.paragraphRole(row.text) != .ordinary { break }
                if separateCaption(row) { boundaryVerified = false; break }
                if row.kind != .header && row.kind != .footer { caption.append(row) }
            }
        } else {
            (caption, boundaryVerified) = (initialCaption, initialBoundary)
            caption += followingColumn
            if needsBoundaryCheck, let ending = caption.last {
                let disputed = all.contains { line in
                    line.position.column != sourceColumn && line.position.column == 1 && !separateCaption(line) &&
                        abs(line.printedHeight - lineHeight) <= lineHeight * 0.24 &&
                        abs(line.box.minX - start.box.minX) <= lineHeight * 0.5 &&
                        (leading * 0.60...leading * 1.45).contains(ending.baseline - line.baseline)
                }
                if disputed || !ResearchPDFLayout.endsCaptionSentence(ending.text) { boundaryVerified = false }
            }
        }
        let captionBox = caption.reduce(CGRect.null) { $0.union($1.box) }
        let hasUnmappedCaptionLine = caption.contains { !ResearchMaterial.hasReadableText($0.text) }
        caption.removeAll { !ResearchMaterial.hasReadableText($0.text) }
        let missingGlyphFragments = damagedCaptionFragments(caption, in: captionBox, page: native, geometry: geometry)
        if !missingGlyphFragments.isEmpty {
            // Insert fragments into the existing print order. Preserve the
            // order of two-column continuations and all unmodified rows.
            for row in missingGlyphFragments {
                if let next = caption.firstIndex(where: { original in
                    abs(original.box.minX - start.box.minX) < lineHeight * 1.4 && original.baseline < row.baseline - lineHeight * 0.4
                }) { caption.insert(row, at: next) } else { caption.append(row) }
            }
        }
        let source: CGRect?
        if let frame {
            let box = CGRect(x: frame.minX, y: start.box.maxY + 0.5,
                             width: frame.width, height: frame.maxY - start.box.maxY - 0.5)
            source = box.height > 3 * lineHeight ? box : nil
        } else {
            let spanningRows = peerLane.map { lane in
                all.filter { $0.kind == .body && $0.isProse && $0.box.minX < lane.minX + lineHeight * 2 &&
                    $0.box.maxX > lane.maxX - lineHeight * 2 && !lane.contains($0.box) }
            } ?? (sourceColumn == 0 || spansColumns ? [] : all.filter { $0.position.column == 0 })
            let tableEdges = all.compactMap { row -> Line? in
                guard row.kind == .table, tag(tableCaption, row.text) != nil,
                      abs(row.box.midY - captionBox.midY) < geometry.canvas.height * 0.62,
                      row.box.intersection(lane).width > row.box.width * 0.4 else { return nil }
                let (_, table) = tableRows(around: row, seed: [row], rows: all)
                let bounds = table.reduce(CGRect.null) { $0.union($1.box) }
                guard !bounds.isNull, !bounds.intersects(captionBox) else { return nil }
                return Line(position: row.position, box: bounds, text: row.text, kind: .table, reliable: row.reliable)
            }
            let byline = affiliationBarriers(above: captionBox, rows: all, canvas: geometry.canvas)
            let backgroundRows = (aboveOrBelow + spanningRows + tableEdges + byline).filter { row in
                !caption.contains { $0.position == row.position } &&
                    (row.box.intersection(lane).width >= min(lane.width, row.box.width) * 0.55)
            }
            let oppositeColumn = sourceColumn == 1 ? 2 : 1
            let adjacentProse = (sourceColumn == 1 || sourceColumn == 2) && !spansColumns ? all.filter {
                $0.position.column == oppositeColumn && $0.kind == .body && $0.reliable && $0.isProse
            } : []
            source = graphicNear(caption: captionBox, rows: backgroundRows, lane: lane, spansColumns: fullWidthFigure,
                                 adjacentProse: adjacentProse, embedded: placements, height: lineHeight, native: native, geometry: geometry)
        }
        let edge = source.map {
            checkedGraphicEdge($0, aboveOrBelow: captionBox, lane: lane, rows: all, height: lineHeight,
                               native: native, geometry: geometry)
        }
        let visual = edge.flatMap { visualPosition($0.box, page: page.number, geometry: geometry) }
        let labels: [Line] = edge.map { evidence in
            let box = evidence.box
            return figureLines.filter { row in
                row.reliable && box.contains(row.box) && row.kind != .header && row.kind != .footer &&
                    !row.text.isEmpty && (frame != nil || !row.isProse)
            }
        } ?? []
        let encodingUncertain = hasUnmappedCaptionLine || !missingGlyphFragments.isEmpty || caption.contains { line in
            line.text.contains("\u{FFFD}") ||
                sameLine != nil && line.text.range(of: #"\b[A-Za-z] +[.,;]"#, options: .regularExpression) != nil ||
                line.text.range(of: #"(?<![\p{L}\d.])\d{1,4}\s+\d{1,4}(?![\p{L}\d.])"#,
                                options: .regularExpression) != nil
        }
        let mathOrUncertain = encodingUncertain || spansColumns || caption.contains {
            !$0.reliable || $0.kind == .formula || $0.box.height > lineHeight * 1.48
        }
        var item = Object(id: anchor.id, page: page.number, primary: caption + labels,
                          supporting: figureMentions(anchor.id, around: page, previous: previous, next: next,
                                                      excluding: caption + labels),
                          visual: visual, exactEquation: nil, labels: labels.map(\.text))
        item.caption = caption
        item.visualBoundaryUncertain = edge?.uncertain == true
        let stopsMidPhrase = caption.last?.text.range(
            of: #"(?i)\b(?:and|or|with|of|for|by|as|to|the)\s*$|[‐–−-]\s*$"#,
            options: .regularExpression) != nil
        item.captionBoundaryVerified = boundaryVerified &&
            ResearchPDFLayout.openCaptionDelimiter(caption.map(\.text).joined(separator: "\n")) == nil &&
            !stopsMidPhrase &&
            !(sourceColumn == 1 && graphicSpansCaption && followingColumn.isEmpty &&
                !ResearchPDFLayout.endsCaptionSentence(caption.last?.text ?? ""))
        item.captionEncodingUncertain = encodingUncertain
        if mathOrUncertain || !captionBox.isEmpty {
            item.captionVisual = visualPosition(captionBox.insetBy(dx: -2, dy: -1),
                                               page: page.number, geometry: geometry)
            item.captionNeedsVisual = mathOrUncertain
        }
        return item
    }

    /// Two numbered captions printed side by side need separate lanes even
    /// on a page with otherwise full-width prose.
    private static func separateFigureLane(around start: Line, rows: [Line], canvas: CGRect) -> CGRect? {
        let height = start.printedHeight
        let peers = rows.filter { row in
            row.position != start.position && row.kind == .caption && tag(figureCaption, row.text) != nil &&
                abs(row.baseline - start.baseline) < height * 0.60
        }
        let left = peers.filter { $0.box.maxX < start.box.minX - height * 1.5 }
            .map { ($0.box.maxX + start.box.minX) / 2 }.max()
        let right = peers.filter { $0.box.minX > start.box.maxX + height * 1.5 }
            .map { ($0.box.minX + start.box.maxX) / 2 }.min()
        guard left != nil || right != nil else { return nil }
        let x = left ?? canvas.minX
        return CGRect(x: x, y: canvas.minY, width: (right ?? canvas.maxX) - x, height: canvas.height)
    }

    private static func separateCaptionTail(_ rows: [Line], height: CGFloat, leading: CGFloat) -> ([Line], Bool) {
        if let boundary = rows.dropFirst().firstIndex(where: { ResearchPDFLayout.paragraphRole($0.text) != .ordinary }) {
            return (Array(rows.prefix(boundary)), true)
        }
        guard rows.count >= 4, let first = rows.first else { return (rows, false) }
        if let tail = rows.last, tail.text.trimmingCharacters(in: .whitespaces).first?.isLowercase == true,
           tail.box.width < first.box.width * 0.2, tail.printedHeight > height * 1.08,
           let previous = rows.dropLast().last, ResearchPDFLayout.endsCaptionSentence(previous.text),
           previous.baseline - tail.baseline > leading * 1.22 {
            return (Array(rows.dropLast()), true)
        }
        for index in 2..<(rows.count - 1) {
            let end = rows[index - 1], next = rows[index], continuation = rows[index + 1]
            guard ResearchPDFLayout.endsCaptionSentence(end.text),
                  end.box.maxX < first.box.maxX - height * 2.5,
                  (leading * 1.30...leading * 2.1).contains(end.baseline - next.baseline),
                  (leading * 0.85...leading * 1.15).contains(next.baseline - continuation.baseline),
                  next.isProse, continuation.isProse,
                  next.text.trimmingCharacters(in: .whitespaces).first?.isLowercase == true else { continue }
            let resumesSameLane = abs(next.box.minX - first.box.minX) < height * 0.5 &&
                abs(next.box.maxX - first.box.maxX) < height
            // Captions may be indented a little farther than running prose.
            // Require the new left edge and larger type in two consecutive rows.
            let resumesWiderLane = (height * 0.4...height * 1.5).contains(first.box.minX - next.box.minX) &&
                abs(next.box.minX - continuation.box.minX) < height * 0.25 &&
                min(next.printedHeight, continuation.printedHeight) > end.printedHeight * 1.08
            if resumesSameLane || resumesWiderLane { return (Array(rows.prefix(index)), true) }
        }
        return (rows, false)
    }

    /// Page-wide reading order sometimes interleaves a narrow paragraph and
    /// an opposite-side floating figure. Its caption still has a physical lane.
    private static func floatingFigureLane(around start: Line, rows: [Line], canvas: CGRect) -> CGRect? {
        guard start.position.column == 0, start.box.width < canvas.width * 0.48 else { return nil }
        let leftFigure = start.box.maxX <= canvas.midX
        guard leftFigure || start.box.minX >= canvas.midX else { return nil }
        let clearance = max(3, start.printedHeight * 0.5)
        let prose = rows.filter { line in
            guard line.kind == .body, line.isProse, line.reliable,
                  line.box.width >= canvas.width * 0.22,
                  abs(line.baseline - start.baseline) < canvas.height * 0.14 else { return false }
            return leftFigure ? line.box.minX > start.box.maxX + clearance : line.box.maxX < start.box.minX - clearance
        }
        guard prose.count >= 3, prose.contains(where: { $0.baseline > start.baseline }),
              prose.contains(where: { $0.baseline < start.baseline }) else { return nil }
        let neighbor = leftFigure ? prose.map(\.box.minX).min() : prose.map(\.box.maxX).max()
        guard let neighbor else { return nil }
        let divider = (neighbor + (leftFigure ? start.box.maxX : start.box.minX)) / 2
        return CGRect(x: leftFigure ? canvas.minX : divider, y: canvas.minY,
                      width: leftFigure ? divider - canvas.minX : canvas.maxX - divider, height: canvas.height)
    }

    private static func affiliationBarriers(above caption: CGRect, rows: [Line], canvas: CGRect) -> [Line] {
        let bylines: [(Int, Line)] = rows.compactMap { line in
            guard line.position.page == 1, line.reliable, line.box.minY > caption.maxY,
                  line.box.midY >= canvas.height * 0.68, line.box.width < canvas.width * 0.30,
                  let (index, _) = tag(firstPageAffiliation, line.text), let number = Int(index) else { return nil }
            return (number, line)
        }
        return bylines.compactMap { index, line in
            guard bylines.contains(where: { peerIndex, peer in
                peerIndex != index && abs(line.baseline - peer.baseline) < line.printedHeight * 0.23 &&
                    abs(line.printedHeight - peer.printedHeight) < line.printedHeight * 0.18 &&
                    !line.box.intersects(peer.box)
            }) else { return nil }
            return Line(position: line.position, box: line.box, text: line.text, kind: .header, reliable: true)
        }
    }

    private static func splitCaptionLead(_ start: Line, in rows: [Line]) -> Line? {
        guard let (_, tagRange) = tag(figureCaption, start.text),
              (start.text as NSString).substring(from: NSMaxRange(tagRange))
                .trimmingCharacters(in: CharacterSet(charactersIn: ":：. ")).isEmpty else { return nil }
        let height = start.printedHeight
        let candidates = rows.filter { row in
            guard row.reliable, row.text.split(whereSeparator: \.isWhitespace).count >= 4,
                  row.position.column == start.position.column,
                  abs(row.box.midY - start.box.midY) < height * 0.38,
                  abs(row.box.height - start.box.height) < height * 0.25,
                  (0...height * 2.7).contains(row.box.minX - start.box.maxX) else { return false }
            return rows.contains { next in
                next.position.blockIndex == row.position.blockIndex &&
                    (height * 0.8...height * 1.6).contains(row.baseline - next.baseline) &&
                    abs(next.box.minX - start.box.minX) < height * 0.7
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Some font maps emit NUL for one symbol. Retain independently mappable
    /// substrings only inside an already established caption, and
    /// mark the caption partial so its original image stays authoritative.
    private static func damagedCaptionFragments(_ caption: [Line], in box: CGRect, page: PDFPage,
                                                geometry: ResearchPDFLayout.Geometry) -> [Line] {
        guard let first = caption.first, let text = page.string, text.utf8.contains(0),
              let selected = page.selection(for: box.applying(geometry.display.inverted())) else { return [] }
        let native = text as NSString
        var occupied = caption.flatMap { row in
            row.nativeSpans.isEmpty ? row.position.sourceRange.map { [$0] } ?? [] : row.nativeSpans
        }
        var additions: [Line] = []
        for line in selected.selectionsByLine() {
            for slot in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: slot, on: page)
                guard range.location != NSNotFound, NSMaxRange(range) <= native.length,
                      native.substring(with: range).utf8.contains(0) else { continue }
                let string = native.substring(with: range) as NSString
                var cursor = 0
                while cursor < string.length {
                    let remaining = NSRange(location: cursor, length: string.length - cursor)
                    let bad = string.range(of: "\u{0}", options: .literal, range: remaining)
                    let end = bad.location == NSNotFound ? string.length : bad.location
                    // PDFKit can include a synthetic line terminator in the native
                    // range while omitting it from selection.string. Keep the
                    // exact character offsets of the printable fragment.
                    var last = end
                    while last > cursor, (CharacterSet.whitespacesAndNewlines as NSCharacterSet).characterIsMember(string.character(at: last - 1)) {
                        last -= 1
                    }
                    let span = NSRange(location: range.location + cursor, length: last - cursor)
                    cursor = end + 1
                    guard span.length > 0, !occupied.contains(where: { NSIntersectionRange($0, span).length > 0 }),
                          let part = page.selection(for: span), let value = part.string,
                          value == native.substring(with: span), ResearchMaterial.hasReadableText(value) else { continue }
                    let bounds = part.bounds(for: page), upright = bounds.applying(geometry.display)
                    guard !upright.isEmpty, box.insetBy(dx: -1, dy: -1).contains(upright) else { continue }
                    let position = ResearchPDFSourcePosition(page: first.position.page, bounds: bounds,
                                                             column: first.position.column, sourceRange: span)
                    additions.append(Line(position: position, box: upright, text: value, kind: .caption, reliable: true))
                    occupied.append(span)
                }
            }
        }
        return additions
    }

    private static func separateCaption(_ row: Line) -> Bool {
        (row.kind == .caption || row.kind == .table) &&
            (tag(figureCaption, row.text) != nil || tag(tableCaption, row.text) != nil)
    }

    private static func matchingCaptionLane(_ left: [Line], in right: [Line],
                                            height: CGFloat, leading: CGFloat, graphicSpansCaption: Bool) -> [Line] {
        guard let first = left.first, let last = left.last, left.count >= 3,
              let widest = left.map(\.box.width).max(), widest > height * 17 else { return [] }
        let leftEdge = left.map(\.box.maxX).max() ?? first.box.maxX
        // Inline mathematics can enlarge the typographic box of a genuine
        // caption row. Verify its style against ordinary rows in the same block.
        let captionStyleBlocks = Set(right.filter {
            abs($0.printedHeight - height) < height * 0.30 && $0.isProse
        }.compactMap(\.position.blockIndex))
        let nearby = right.filter {
            $0.reliable && $0.kind != .header && $0.kind != .footer && $0.kind != .footnote &&
                !separateCaption($0) && (abs($0.printedHeight - height) < height * 0.30 ||
                    $0.position.blockIndex.map(captionStyleBlocks.contains) == true && $0.printedHeight < height * 2.1) &&
                $0.box.minX - leftEdge > height * 0.55 &&
                $0.baseline <= first.baseline + leading * 0.60 &&
                $0.baseline >= last.baseline - leading * 1.7
        }.sorted { $0.baseline > $1.baseline }
        guard let start = nearby.first, abs(start.baseline - first.baseline) < leading * 0.58,
              start.box.width > widest * 0.70 else { return [] }
        let panelRun = start.text.range(of: #"^\s*\(?[a-z]\)?(?:[–—-]\(?[a-z]\)?)?(?:[,. ]+)"#,
                                       options: .regularExpression) != nil
        guard !ResearchPDFLayout.endsCaptionSentence(last.text) || panelRun || graphicSpansCaption else { return [] }
        var joined = [start]
        for row in nearby.dropFirst() {
            guard let previous = joined.last else { break }
            let advance = previous.baseline - row.baseline
            if advance <= leading * 0.52 { continue }
            if advance > leading * 1.45 || abs(row.box.minX - start.box.minX) > height * 0.72 { break }
            let terminal = previous.box.width < widest * 0.70 && ResearchPDFLayout.endsCaptionSentence(previous.text)
            if terminal && previous.position.blockIndex != row.position.blockIndex { break }
            joined.append(row)
        }
        guard joined.count >= 3,
              joined.prefix(3).filter({ row in
                  left.prefix(4).contains { abs(row.baseline - $0.baseline) < leading * 0.48 }
              }).count >= 2 else { return [] }
        return joined
    }

    private static let inlineMathSymbols = CharacterSet(charactersIn: "\u{02C6}\u{0302}∑∫∥∂′−≈=")

    private static func extendCaption(_ seed: [Line], with rows: [Line], lineHeight: CGFloat,
                                      leading: CGFloat) -> ([Line], Bool) {
        guard let first = seed.first, let last = seed.last else { return (seed, false) }
        let extent = seed.reduce(CGRect.null) { $0.union($1.box) }
        let below = rows.filter { $0.baseline < last.baseline - lineHeight * 0.10 &&
            $0.box.maxX > first.box.minX - lineHeight * 0.45 && $0.box.minX < extent.maxX + lineHeight &&
            // Some PDFs expose an image as a U+FFFC text run with the entire
            // image's bounds. It cannot be a printed caption or prose boundary.
            $0.text.contains { !$0.isWhitespace && $0 != "\u{fffc}" }
        }
            .sorted { $0.baseline > $1.baseline }
        var result = seed
        for (index, row) in below.enumerated() {
            guard let previous = result.last, !separateCaption(row),
                  ResearchPDFLayout.paragraphRole(row.text) == .ordinary,
                  row.kind != .header && row.kind != .footer && row.kind != .reference else { break }
            let advance = previous.baseline - row.baseline
            let interlineGap = previous.box.minY - row.box.maxY
            let aligned = abs(row.box.minX - first.box.minX) <= lineHeight * 1.15
            let lastStyle = result.count > seed.count && previous.isProse ? previous.printedHeight : lineHeight
            let sameStyle = abs(row.printedHeight - lastStyle) <= lineHeight * 0.24
            let openSentence = !ResearchPDFLayout.endsCaptionSentence(previous.text)
            let terminalMargin = extent.maxX - previous.box.maxX
            let explicitContinuation = row.text.range(of: #"(?i)^\s*(?:notes?\s*[.:：]|the notation\b|其中|注[：:])"#,
                                                      options: .regularExpression) != nil
            let formula = row.kind == .formula ||
                row.box.height > lineHeight * 1.36 && row.text.range(of: #"[∥∑∫∂√≈≡≠=]"#,
                                                                      options: .regularExpression) != nil
            let formulaRun = formula && interlineGap < lineHeight * 0.55 && openSentence &&
                row.box.minX >= first.box.minX - 2 && row.box.maxX <= extent.maxX + lineHeight * 2
            // A fraction or accent may split a printed row into two
            // consecutive native lines, with a vertical shift at the join.
            // Keep their exact native positions; use the original crop for
            // the two-dimensional notation.
            let inlineJoin = openSentence && advance < lineHeight * 0.70 &&
                abs(row.box.minX - previous.box.maxX) < lineHeight * 1.85 &&
                row.box.maxX <= extent.maxX + lineHeight &&
                (row.box.intersects(previous.box) || interlineGap < lineHeight * 0.25)
            let continuedMath = openSentence && aligned && advance < leading * 1.60 &&
                row.box.height <= lineHeight * 2.5 &&
                (previous.text + row.text).unicodeScalars.contains { inlineMathSymbols.contains($0) }
            if inlineJoin || continuedMath && row.kind == .heading { result.append(row); continue }
            let sharesBlock = row.position.blockIndex == previous.position.blockIndex
            if advance > leading * 1.48 && !formulaRun { break }
            if !aligned && !formulaRun && !sharesBlock { break }
            if row.kind == .heading && !sameStyle && !formulaRun && !explicitContinuation { break }
            let expectedWrap = terminalMargin < max(lineHeight * 2, extent.width * 0.12)
            // A bold caption lead can produce boxes twice as tall as the
            // following text in PDFKit. Verify a real wrap by position and a
            // second same-style row before attaching these smaller glyph boxes.
            let verifiedWrap = openSentence && expectedWrap && row.reliable && row.isProse &&
                abs(row.box.minX - first.box.minX) <= lineHeight * 0.35 &&
                row.text.trimmingCharacters(in: .whitespaces).first?.isLowercase == true &&
                below.dropFirst(index + 1).prefix(2).contains { next in
                    next.reliable && !separateCaption(next) && next.kind == .body &&
                        abs(next.box.minX - row.box.minX) <= lineHeight * 0.35 &&
                        abs(next.printedHeight - row.printedHeight) <= lineHeight * 0.15 &&
                        (leading * 0.65...leading * 1.4).contains(row.baseline - next.baseline)
                }
            if (sameStyle || formulaRun || continuedMath || verifiedWrap) &&
                (openSentence || explicitContinuation || sharesBlock && expectedWrap || formulaRun) {
                result.append(row)
            } else if sameStyle && aligned && expectedWrap {
                // The next printed block could still be part of the caption.
                // Keep the verified fragment and surface the uncertain boundary.
                return (result, false)
            } else {
                break
            }
        }
        return (result, true)
    }

    private static func graphicNear(caption: CGRect, rows: [Line], lane: CGRect, spansColumns: Bool,
                                    adjacentProse: [Line], embedded: [CGRect], height: CGFloat,
                                    native: PDFPage, geometry: ResearchPDFLayout.Geometry) -> CGRect? {
        let panelTitles: [(Int, Line)] = rows.compactMap { line in
            guard line.box.minY > caption.maxY, line.box.minY - caption.maxY < geometry.canvas.height * 0.32,
                  line.printedHeight < height * 1.05, line.box.width < lane.width * 0.44,
                  let (index, _) = tag(numberedPanelTitle, line.text), let number = Int(index) else { return nil }
            return (number, line)
        }
        let pairedPanelTitles = panelTitles.filter { index, line in
            panelTitles.contains { peerIndex, peer in
                abs(peerIndex - index) == 1 && abs(peer.baseline - line.baseline) < height * 0.35 &&
                    (peer.box.minX - line.box.maxX > height || line.box.minX - peer.box.maxX > height)
            }
        }.map { $0.1.position }
        func imageEdgeLabel(_ line: Line) -> Bool {
            // Two numbered headings side by side belong to the panel grid.
            // A full phrase can otherwise look like the next prose boundary.
            if pairedPanelTitles.contains(line.position) { return true }
            // A line of words at the edge of a physical panel can be its
            // title. Require the title to overlap that panel horizontally.
            if line.box.width < lane.width * 0.58 && line.box.height < height * 1.3 &&
                !ResearchPDFLayout.endsCaptionSentence(line.text) && embedded.contains(where: { image in
                    image.width > height * 4 && image.height > height * 3 &&
                        (-height * 0.5...height * 1.65).contains(line.box.minY - image.maxY) &&
                        line.box.maxX > image.minX && line.box.minX < image.maxX
                }) { return true }
            let shortMarker = line.text.range(of: #"^(?:\d{1,3}|[A-Za-z]|\([A-Za-z]\))$"#,
                                             options: .regularExpression) != nil
            guard shortMarker else { return false }
            // For all-vector plots, no image placement exists. Verify an axis
            // by a sequence of numerical ticks at the same printed coordinate.
            let axisTicks = rows.filter { row in
                row.position != line.position && row.box.midY < line.box.midY &&
                row.box.midY > caption.maxY && row.box.midY > line.box.midY - height * 10 &&
                abs(row.box.maxX - line.box.maxX) <= max(2, line.box.height * 0.8) &&
                row.text.range(of: #"^[-−+]?\d+(?:[.,]\d+)?$"#, options: .regularExpression) != nil
            }
            if axisTicks.count >= 2 && line.box.height < height * 0.86 { return true }
            return embedded.contains { image in
                image.width > height * 3 && image.height > height * 3 &&
                    image.insetBy(dx: -height * 1.7, dy: -height * 1.7)
                        .contains(CGPoint(x: line.box.midX, y: line.box.midY))
            }
        }
        // A chart title may contain a whole English sentence. Its printed
        // block can also carry several scale values, unlike a prose paragraph.
        let tickBlockIDs = Dictionary(grouping: rows.filter {
            $0.text.range(of: #"^[-−+]?\d+(?:[.,]\d+)?(?:[%‰])?$"#, options: .regularExpression) != nil
        }, by: \.position.blockIndex).filter { $0.value.count >= 2 }.keys
        let proseBlocks = Set(rows.filter { $0.kind == .body && $0.isProse }
            .compactMap(\.position.blockIndex))
        let boundaries = rows.filter { line in
            if imageEdgeLabel(line) { return false }
            if line.kind == .header || line.kind == .footer {
                return true
            }
            let ticks = line.text.split(whereSeparator: \.isWhitespace)
            if ticks.count >= 4 && ticks.allSatisfy({ Double($0) != nil }) { return false }
            if line.kind == .body, line.position.blockIndex != nil, tickBlockIDs.contains(line.position.blockIndex),
               line.position.column != 0, !ResearchPDFLayout.endsCaptionSentence(line.text) { return false }
            let typicalWidth = spansColumns && line.position.column != 0 ? lane.width * 0.48 : lane.width
            return separateCaption(line) || line.kind == .caption || line.kind == .table ||
            line.kind == .body && (line.box.width > typicalWidth * 0.46 && (line.isProse || line.position.column == 0) ||
                line.position.blockIndex.map(proseBlocks.contains) == true && line.box.minX < lane.minX + height * 3.5 &&
                ResearchPDFLayout.endsCaptionSentence(line.text)) ||
            line.kind == .heading && line.box.width > lane.width * 0.55 ||
            line.box.midY > geometry.canvas.height * 0.94 && line.text.localizedCaseInsensitiveContains("doi.org/")
        }
        let above = boundaries.filter { $0.box.minY > caption.maxY }.map(\.box.minY).min() ?? lane.maxY
        let below = boundaries.filter { $0.box.maxY < caption.minY }.map(\.box.maxY).max() ?? lane.minY
        let cap = geometry.canvas.height * 0.78
        let bands = [(caption.maxY + 0.5, min(above - 0.5, caption.maxY + cap)),
                     (max(below + 0.5, caption.minY - cap), caption.minY - 0.5)]
        for (bottom, top) in bands where top - bottom > height * 3.0 {
            let box = CGRect(x: lane.minX, y: bottom, width: lane.width, height: top - bottom)
            let local = embedded.filter { rect in
                rect.minY >= bottom - height * 0.35 && rect.maxY <= top + height * 0.35 &&
                    rect.intersection(box).width > min(rect.width, box.width) * 0.55
            }.reduce(CGRect.null) { $0.union($1) }
            // A physical image placement can extend past the caption width.
            // Include nearby vector labels and axes, while stopping at known prose.
            var measured: CGRect
            if local.isNull || local.height < height * 2 {
                measured = box
            } else {
                // Borrow space from an adjacent lane only when actual image ink
                // crosses it. Text overlays can extend beyond the embedded tiles.
                let left = local.minX < box.minX
                    ? max(geometry.canvas.minX, local.minX - height * 0.7) : box.minX
                let right = local.maxX > box.maxX
                    ? min(geometry.canvas.maxX, local.maxX + height * 0.7) : box.maxX
                // Keep nearby vector overlays for a single-column image
                // without dragging unrelated distant front matter into it.
                // A confirmed full-width panel grid may include more than
                // the embedded bitmap and retains its separate lane limits.
                let aboveCaption = bottom > caption.maxY
                let upper = !spansColumns && aboveCaption ? min(top, local.maxY + height * 3.6) : top
                let lower = !spansColumns && !aboveCaption ? max(bottom, local.minY - height * 3.6) : bottom
                measured = CGRect(x: left, y: lower, width: right - left, height: upper - lower)
            }
            // Leave ordinary text in the opposite column outside a single-column crop.
            // An actual image that crosses the gutter still keeps its full placement.
            let objectWidth = caption.union(local)
            let occupied = adjacentProse.map(\.box).filter { $0.minY < measured.maxY && $0.maxY > measured.minY }
            let left = occupied.map(\.maxX).filter { $0 < objectWidth.minX }.max() ?? measured.minX
            let right = occupied.map(\.minX).filter { $0 > objectWidth.maxX }.min() ?? measured.maxX
            measured = measured.intersection(CGRect(x: left, y: measured.minY, width: right - left, height: measured.height))
            guard let image = Raster(native, area: measured, transform: geometry.display, maximumScale: 1.5) else { continue }
            // Prefer the illustrated ink run next to the caption. A full-band
            // bounding box can join a remote author block, running header, or
            // precisely the figure on the other side of a long blank interval.
            let graphicAbove = bottom > caption.maxY
            let embeddedInk = local.isNull ? nil : image.inkBounds(in: local)
            let allBands = image.bands
            let ordered = graphicAbove ? allBands : Array(allBands.reversed())
            var candidate = CGRect.null
            var connectedSparseInk = false
            for band in ordered {
                guard let ink = image.inkBounds(in: band) else { continue }
                let separation = candidate.isNull ? 0 :
                    (graphicAbove ? ink.minY - candidate.maxY : candidate.minY - ink.maxY)
                // Sparse nodes may be linked by a stroke too faint for the
                // sampled ink mask. A short symbol already inside the measured
                // horizontal extent can corroborate the neighbor, unlike bylines.
                let sparseNode = separation <= height * 5.0 && !candidate.isNull && rows.contains { line in
                    let token = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !token.isEmpty && token.count <= 2 && token.allSatisfy { $0.isLetter || $0.isNumber } &&
                        line.box.minX >= candidate.minX && line.box.maxX <= candidate.maxX &&
                        line.box.intersects(ink.insetBy(dx: -height * 0.7, dy: -height * 0.8))
                }
                let panelTitle = separation <= height * 4.3 && !candidate.isNull && panelTitles.contains { _, title in
                    pairedPanelTitles.contains(title.position) &&
                        title.box.intersects(candidate.insetBy(dx: 0, dy: -height * 4.3)) &&
                        title.box.intersects(ink.insetBy(dx: -height * 0.7, dy: -height * 0.8))
                }
                if separation > height * 2.45 && candidate.height >= height * 2.5 &&
                    (embeddedInk.map { candidate.minY <= $0.minY + 1 && candidate.maxY >= $0.maxY - 1 } ?? true) &&
                    !sparseNode && !panelTitle { break }
                connectedSparseInk = connectedSparseInk || separation > height * 2.45 && (sparseNode || panelTitle)
                candidate = candidate.union(ink)
            }
            guard !candidate.isNull else { continue }
            let verified = candidate.union(local.intersection(measured))
            guard verified.height > height * 2.5, verified.width > min(52, lane.width * 0.26) else { continue }
            return verified
                .insetBy(dx: -height * 0.52, dy: -height * (connectedSparseInk ? 0.95 : 0.38)).intersection(measured)
        }
        return nil
    }

    /// Audit the edge away from the caption. The initial layout cut can run
    /// through a figure when a short label was classified as a paragraph.
    /// Continue only an actual stroke crossing the edge, up to the next
    /// original blank band inside the same lane.
    private static func checkedGraphicEdge(_ proposal: CGRect, aboveOrBelow caption: CGRect,
                                           lane: CGRect, rows: [Line], height: CGFloat, native: PDFPage,
                                           geometry: ResearchPDFLayout.Geometry) -> (box: CGRect, uncertain: Bool) {
        let above = proposal.midY > caption.midY
        let edge = above ? proposal.maxY : proposal.minY
        let step: CGFloat = above ? 1 : -1
        let maximumTravel = min(geometry.canvas.height * 0.22, height * 15)
        let blockingEdges = rows.compactMap { row -> CGFloat? in
            let body = row.kind == .body && row.isProse
            let structural = [.caption, .table, .header, .footer].contains(row.kind) ||
                ResearchPDFLayout.paragraphRole(row.text) != .ordinary
            guard body || structural, row.box.intersection(lane).width >= row.box.width * 0.65 else { return nil }
            let boundary = above ? row.box.minY : row.box.maxY
            return (boundary - edge) * step > height * 0.5 ? boundary : nil
        }
        let nearest = blockingEdges.map { ($0 - edge) * step }.min() ?? maximumTravel
        let travel = min(maximumTravel, nearest - height * 0.25)
        guard travel > height * 0.55 else { return (proposal, false) }
        let exterior = edge + step * travel
        let area = proposal.union(CGRect(x: lane.minX, y: min(edge, exterior),
                                        width: lane.width, height: abs(edge - exterior)))
            .intersection(geometry.canvas)
        guard let raster = Raster(native, area: area, transform: geometry.display, maximumScale: 1.5) else {
            return (proposal, false)
        }
        let top = area.minY + CGFloat(raster.height) / raster.scale
        func ink(at y: CGFloat, inside limits: Range<Int>) -> Set<Int> {
            let row = Int(floor((top - y) * raster.scale))
            guard (0..<raster.height).contains(row) else { return [] }
            let offset = row * raster.width
            return Set(limits.filter { raster.pixels[offset + $0] < 155 })
        }
        let left = max(0, Int(floor((proposal.minX - area.minX) * raster.scale)))
        let right = min(raster.width, Int(ceil((proposal.maxX - area.minX) * raster.scale)))
        guard right > left else { return (proposal, false) }
        let inner = ink(at: edge - step, inside: left..<right)
        let outer = ink(at: edge + step, inside: left..<right)
        let continuing = inner.intersection(outer)
        guard continuing.count >= max(6, (right - left) / 24),
              let first = continuing.min(), let last = continuing.max(),
              last - first >= (right - left) / 4 else { return (proposal, false) }

        var empty = 0
        var end: CGFloat?
        let limit = Int(travel * raster.scale)
        let blankRows = max(3, Int(2.2 * raster.scale))
        for i in 1...max(1, limit) {
            let y = edge + step * CGFloat(i) / raster.scale
            if ink(at: y, inside: 0..<raster.width).count <= 1 {
                empty += 1
                if empty >= blankRows {
                    end = y - step * CGFloat(empty / 2) / raster.scale
                    break
                }
            } else { empty = 0 }
        }
        guard let end, abs(end - edge) >= 2 else { return (proposal, true) }
        let connected = CGRect(x: area.minX, y: min(edge, end), width: area.width, height: abs(end - edge))
        guard let added = raster.inkBounds(in: connected) else { return (proposal, true) }
        // Keep lateral panels connected by ink between the old edge and the
        // original blank band. The source coordinate map remains unchanged.
        let box = proposal.union(added.insetBy(dx: -height * 0.30, dy: 0)).intersection(area)
        // A blank band is a safe stopping point for connected ink. It
        // does not establish ownership of any separated labels or panels.
        return (box, true)
    }

    private static func figureMentions(_ id: ResearchPDFObjectID, around page: ResearchPDFIndex.Page,
                                       previous: ResearchPDFIndex.Page?, next: ResearchPDFIndex.Page?,
                                       excluding primary: [Line]) -> [Line] {
        func matches(_ candidate: String) -> Bool {
            ResearchPDFObjectID.addresses(in: candidate).contains { $0 == id || $0.parentFigure == id }
        }
        var found: [Line] = []
        for candidate in [page, previous, next].compactMap({ $0 }) {
            guard let geometry = candidate.geometry else { continue }
            let current = lines(on: candidate, geometry: geometry).filter { row in
                row.reliable && row.kind == .body && !primary.contains { $0.position == row.position }
            }
            let groups = Dictionary(grouping: current, by: { $0.position.blockIndex })
            for block in groups.keys.compactMap({ $0 }).sorted() {
                guard let group = groups[block], let position = group.firstIndex(where: { matches($0.text) }) else { continue }
                let lower = max(0, position - 1)
                let upper = min(group.count - 1, position + 1)
                found.append(contentsOf: group[lower...upper])
                if found.count >= 7 { return found }
            }
        }
        return found
    }

    private static func equation(_ id: ResearchPDFObjectID, at tag: Line, tagRange: NSRange, rows: [Line],
                                 lanes: [Int: [Line]], geometry: ResearchPDFLayout.Geometry, native: PDFPage?) -> Object? {
        let text = tag.text as NSString
        let inline = text.substring(to: tagRange.location).trimmingCharacters(in: .whitespaces)
        let attached = !inline.isEmpty
        guard !attached || (!tag.isProse && formulaCue.firstMatch(in: inline,
                  range: NSRange(location: 0, length: inline.utf16.count)) != nil &&
                  inline.range(of: #"\b(?:eq(?:uation)?\.?|as in|see|fig(?:ure)?\.?|figure|table|section)\b|参见|见公式"#,
                               options: [.regularExpression, .caseInsensitive]) == nil) else { return nil }
        let size = max(8, min(14, tag.box.height))
        let center = tag.box.midY
        let spanning = equationSpansLanes(at: tag, rows: rows, size: size, geometry: geometry)
        let column = spanning ? 0 : tag.position.column ?? 0
        let laneProse = lanes[column] ?? []
        let right = laneProse.map(\.box.maxX).max() ?? tag.box.maxX
        let left = laneProse.map(\.box.minX).min() ?? tag.box.minX
        guard tag.box.maxX >= left + (right - left) * 0.68 else { return nil }
        let lane = rows.filter { $0.kind != .footer && $0.kind != .header &&
            ($0.position.column == column || spanning && $0.box.minX >= left - 2 && $0.box.maxX <= right + 2)
        }
        let prose = lane.filter { $0.position.column == column && $0.isProse && abs($0.box.midY - center) > size * 0.5 &&
            abs($0.box.midY - center) <= 9 * size }
        let above = prose.filter { $0.box.midY > center }.sorted { $0.box.midY < $1.box.midY }
        let below = prose.filter { $0.box.midY < center }.sorted { $0.box.midY > $1.box.midY }
        let top = min(center + 2.7 * size, above.first.map { boundary(of: $0, toward: center) - 0.5 } ?? .infinity)
        let bottom = max(center - 2.5 * size, below.first.map { boundary(of: $0, toward: center) + 0.5 } ?? -.infinity)
        guard bottom < center, top > center else { return nil }
        let pieces = lane.filter { line in
            let alignedDisplay = !attached && abs(line.box.midY - center) < size * 0.34 &&
                line.box.minX > left + size * 1.5 && line.box.maxX < tag.box.minX - size &&
                line.text.contains("=") && line.text.filter { "()[]∼~∑∫".contains($0) }.count >= 4 &&
                !ResearchPDFLayout.endsCaptionSentence(line.text)
            return line.position != tag.position && (!line.isProse || alignedDisplay) &&
                line.kind != .footnote && line.kind != .table && line.kind != .caption && line.kind != .figureLabel &&
                line.box.midY > bottom && line.box.midY < top && !line.text.isEmpty &&
                tagRangeFor(line.text) == nil
        }
        let possibleMain = pieces.filter {
            formulaCue.firstMatch(in: $0.text, range: NSRange(location: 0, length: $0.text.utf16.count)) != nil
        }
        let alignedMain = possibleMain.contains { $0.box.maxX <= tag.box.minX - max(6, size * 0.55) }
        // An embedded mathematical font can drop the equals sign. Recognize
        // this isolated, numbered display from a centered mathematical row
        // and independently positioned numerator and denominator text.
        let spatialFraction = !attached && !alignedMain && pieces.contains { row in
            guard row.reliable, abs(row.box.midY - center) < size * 0.35,
                  row.box.minX > left + size * 2, row.box.maxX < tag.box.minX - size,
                  row.text.contains("("), row.text.contains(")"), row.text.filter({ $0 == "+" }).count >= 2 else { return false }
            let scripts = pieces.filter { line in
                line.position != row.position && line.reliable &&
                    line.text.count <= 6 && line.box.width < size * 1.8 &&
                    line.box.minX >= row.box.minX && line.box.maxX <= row.box.maxX &&
                    line.box.height < row.box.height * 0.64 && abs(line.baseline - row.baseline) <= size
            }
            return scripts.contains { numerator in
                numerator.baseline > row.baseline + size * 0.28 && scripts.contains { denominator in
                    denominator.baseline < row.baseline - size * 0.28 &&
                        abs(numerator.box.midX - denominator.box.midX) < size * 0.40
                }
            }
        }
        guard attached || alignedMain || spatialFraction else { return nil }
        var main = [tag] + pieces
        let area = main.reduce(CGRect.null) { $0.union($1.box) }
        var crop = CGRect(x: area.minX - 3, y: max(bottom, area.minY - 2), width: area.width + 6,
                          height: min(top, area.maxY + 2) - max(bottom, area.minY - 2))
        // The tag-centered band discovers the display. It is not a physical
        // limit on a multi-line display: scripts belonging to its first/last
        // rows can lie outside it. Stop at neighboring prose and numbered rows.
        let neighborTags = lane.filter { $0.position != tag.position && tagRangeFor($0.text) != nil }
        let displayRows = possibleMain.filter { $0.kind == .formula && $0.text.contains(where: { "=≔≡".contains($0) }) }
        if let highest = displayRows.map(\.baseline).max(), let lowest = displayRows.map(\.baseline).min(),
           highest - lowest > size * 1.4,
           !neighborTags.contains(where: { abs($0.baseline - center) < size * 3.5 }) {
            let sideHeadings = lane.filter { $0.kind == .heading && $0.box.minX < left + size * 0.9 }
            let aboveLimit = min(above.first.map { boundary(of: $0, toward: center) } ?? geometry.canvas.maxY,
                                 sideHeadings.filter { $0.box.midY > center }.map(\.box.minY).min() ?? geometry.canvas.maxY,
                                 neighborTags.filter { $0.box.midY > center }.map(\.box.minY).min() ?? geometry.canvas.maxY)
            let belowLimit = max(below.first.map { boundary(of: $0, toward: center) } ?? geometry.canvas.minY,
                                 sideHeadings.filter { $0.box.midY < center }.map(\.box.maxY).max() ?? geometry.canvas.minY,
                                 neighborTags.filter { $0.box.midY < center }.map(\.box.maxY).max() ?? geometry.canvas.minY)
            let lineExtent = displayRows.reduce(CGRect.null) { $0.union($1.box) }
            let members = lane.filter { line in
                let symbols = line.text.unicodeScalars.contains {
                    $0.properties.generalCategory == .mathSymbol || (0x1D400...0x1D7FF).contains($0.value)
                }
                let alignedFormula = abs(line.box.minX - lineExtent.minX) < size * 1.2 &&
                    line.box.maxX <= lineExtent.maxX + size * 2 && line.box.width >= size * 1.6 && symbols
                return !line.isProse && line.box.midY > belowLimit && line.box.midY < aboveLimit &&
                (line.kind == .formula || line.text.count <= 4 || alignedFormula) &&
                ![.caption, .table, .footnote, .figureLabel].contains(line.kind) &&
                line.box.intersects(lineExtent.insetBy(dx: -size * 0.75, dy: -size * 1.45)) &&
                !main.contains { $0.position == line.position } &&
                line.box.minX >= left - 2 && line.box.maxX < tag.box.minX
            }
            if aboveLimit > belowLimit, !members.isEmpty || area.minY < bottom || area.maxY > top {
                main += members
                let extent = members.reduce(area) { $0.union($1.box) }.insetBy(dx: -3, dy: -2)
                crop = extent.intersection(CGRect(x: extent.minX, y: belowLimit, width: extent.width,
                                                   height: aboveLimit - belowLimit))
            }
        }
        guard let visual = visualPosition(crop,
                                          page: tag.position.page, geometry: geometry) else { return nil }
        let heights = prose.map(\.box.height).sorted()
        let normalHeight = heights.isEmpty ? size : heights[heights.count / 2]
        let exact = spanning ? nil : linearEquation(inline: inline, attached: attached, main: possibleMain, pieces: pieces,
                                                    normalHeight: normalHeight, tag: tag)
        return Object(id: id, page: tag.position.page, primary: main, supporting: [], visual: visual,
                      exactEquation: exact, labels: [])

        func boundary(of line: Line, toward display: CGFloat) -> CGFloat {
            var box = line.box
            if spanning, let native, let raster = Raster(native, area: box, transform: geometry.display) {
                // PDFKit's typography rectangle may overlap a tall sub/superscript.
                // The actual neighboring line's ink bounds delimit the crop.
                let printed = raster.bands.compactMap { raster.inkBounds(in: $0) }
                    .filter { $0.width >= line.box.width * 0.35 }
                    .reduce(CGRect.null) { $0.union($1) }
                if !printed.isNull { box = printed }
            }
            return display < box.midY ? box.minY : box.maxY
        }
    }

    /// An isolated display can create a false gutter between mathematical expressions.
    /// Only join lanes when actual full-width prose brackets the display, with no
    /// local running prose supporting the competing column assignment.
    private static func equationSpansLanes(at tag: Line, rows: [Line], size: CGFloat,
                                           geometry: ResearchPDFLayout.Geometry) -> Bool {
        guard tag.position.column != 0 else { return false }
        let nearby = rows.filter { $0.isProse && $0.reliable && ($0.kind == .body || $0.kind == .heading) &&
            abs($0.box.midY - tag.box.midY) <= size * 4
        }
        guard nearby.allSatisfy({ $0.position.column == 0 }) else { return false }
        let fullWidth = nearby.filter { $0.box.width >= geometry.canvas.width * 0.55 }
        return fullWidth.contains { $0.box.midY > tag.box.midY } && fullWidth.contains { $0.box.midY < tag.box.midY }
    }

    private static func tagRangeFor(_ text: String) -> NSRange? {
        guard let (_, range) = tag(equationNumber, text), range.location == 0 else { return nil }
        return range
    }

    /// Recognize a simple horizontal equation, or a constrained operator whose single index
    /// sits directly below its printed name. More complex spatial math uses the original crop.
    private static func linearEquation(inline: String, attached: Bool, main: [Line], pieces: [Line],
                                       normalHeight: CGFloat, tag: Line) -> String? {
        if !attached, main.count == 1, pieces.count == 2, let base = main.first,
           let index = pieces.first(where: { $0.position != base.position }),
           index.text.range(of: #"^[\p{L}\p{N}]+$"#, options: .regularExpression) != nil,
           base.box.minY > index.box.minY, index.box.maxY < base.box.midY + 1,
           index.box.minX >= base.box.minX - 2, index.box.maxX < base.box.minX + 24,
           let parts = ResearchPDFAddress.captures(#"^(min|max)\s+([\p{L}])\(([\p{L}])\)([.,]?)$"#, in: base.text) {
            return "\\\(parts[1])_{\(index.text)} \(parts[2])(\(parts[3]))\(parts[4])"
        }
        let simple = attached ? inline : (pieces.count == 1 ? pieces[0].text : "")
        let box = attached ? tag.box : (pieces.first?.box ?? .zero)
        guard !simple.isEmpty, box.height <= 1.12 * normalHeight,
              simple.range(of: #"^[-\p{L}\p{N}\s()+−*=.]++$"#, options: .regularExpression) != nil,
              simple.range(of: #"\p{L}\p{N}|\p{L}{2,}"#, options: .regularExpression) == nil
        else { return nil }
        return simple
    }

    private func recoveryKey(_ id: ResearchPDFObjectID, _ page: Int) -> NSString {
        "\(id.kind):\(id.number):\(page)" as NSString
    }

    /// Fallback starts from the original page text's exact printed number, not links in prose
    /// or OCR guesses. Geometry is corroborated against the rendered ink on this page only.
    private func recover(_ id: ResearchPDFObjectID, on indexedPage: ResearchPDFIndex.Page,
                         document: PDFDocument) throws -> [Object] {
        let key = recoveryKey(id, indexedPage.number)
        guard let page = document.page(at: indexedPage.number - 1), let native = page.string,
              let geometry = indexedPage.geometry else { return [] }
        let ns = native as NSString
        let matches = Self.rawEquationNumber.matches(in: native, range: NSRange(location: 0, length: ns.length))
            .filter { ns.substring(with: $0.range(at: 1)).lowercased() == id.number }
        guard matches.count <= 8 else { return [] }
        let rows = Self.lines(on: indexedPage, geometry: geometry)
        var results: [Object] = []
        for item in matches {
            try Task.checkCancellation()
            let range = item.range
            // Most references are inline and explicitly named. A raw PDF can split the
            // glyphs of a printed tag, so do not require a normalized text-block boundary.
            let start = max(0, range.location - 44)
            let prefix = ns.substring(with: NSRange(location: start, length: range.location - start))
            guard Self.proseReference.firstMatch(in: prefix, range: NSRange(location: 0, length: prefix.utf16.count)) == nil,
                  let selection = page.selection(for: range), let selected = selection.string,
                  selected.filter({ !$0.isWhitespace }) == ns.substring(with: range).filter({ !$0.isWhitespace }) else { continue }
            let tag = selection.bounds(for: page).applying(geometry.display)
            guard !tag.isEmpty, !tag.isInfinite else { continue }
            // A damaged text map cannot authorize a cross-lane crop. Only a
            // physical lane independently delimited by broad running prose
            // can authorize the raw raster fallback.
            // Isolated math laid out in several fragments can be assigned artificial
            // columns. Only let a physical lane override them when running prose
            // independently establishes both its boundaries.
            let forcedLane = Self.physicalEquationLane(at: tag, rows: rows, geometry: geometry)
            guard indexedPage.state != .needsOCR || indexedPage.hasLocalOrderMap || forcedLane != nil,
                  let object = try Self.recoverRegion(id, page: page, pageNumber: indexedPage.number, tag: tag,
                                                     tagRange: range, rows: rows, geometry: geometry,
                                                     physicalLane: forcedLane) else { continue }
            if !results.contains(where: { $0.visual == object.visual }) { results.append(object) }
        }
        recovered.setObject(Recovered(results), forKey: key)
        return results
    }

    private static func physicalEquationLane(at tag: CGRect, rows: [Line], geometry: ResearchPDFLayout.Geometry) -> CGRect? {
        let middle = geometry.canvas.midX
        let width = geometry.canvas.width
        let localProse = rows.filter { $0.kind == .body && $0.reliable && $0.isProse &&
            abs($0.baseline - tag.midY) < geometry.canvas.height * 0.14 }
        let wideProse = localProse.filter { $0.position.column == 0 && $0.box.width > width * 0.55 }
        let before = wideProse.filter { $0.baseline > tag.midY }.min { $0.baseline < $1.baseline }
        let after = wideProse.filter { $0.baseline < tag.midY }.max { $0.baseline < $1.baseline }
        if let before, let after,
           !localProse.contains(where: { $0.position.column != 0 && $0.box.width > width * 0.31 &&
               $0.baseline > after.baseline && $0.baseline < before.baseline }) {
            let common = before.box.intersection(CGRect(x: after.box.minX, y: before.box.minY,
                                                        width: after.box.width, height: before.box.height))
            if !common.isNull, tag.minX > common.minX + common.width * 0.68, tag.maxX <= common.maxX + 2 {
                return CGRect(x: min(before.box.minX, after.box.minX) - 2, y: geometry.canvas.minY,
                              width: before.box.union(after.box).width + 4, height: geometry.canvas.height)
            }
        }
        let prose = rows.filter { line in
            line.kind == .body && line.reliable && line.isProse && line.box.width >= width * 0.27 &&
                line.box.width <= width * 0.48 &&
                abs(line.baseline - tag.midY) < geometry.canvas.height * 0.31
        }
        let left = prose.filter { $0.box.maxX < middle - 3 }
        let right = prose.filter { $0.box.minX > middle + 1 }
        guard left.count >= 4, right.count >= 4,
              let leftEdge = left.map(\.box.maxX).max(), let rightEdge = right.map(\.box.minX).min(),
              rightEdge - leftEdge >= 8 else { return nil }
        let neighbors = tag.minX >= rightEdge ? right : (tag.maxX <= leftEdge + 2 ? left : [])
        guard let minX = neighbors.map(\.box.minX).min(), let maxX = neighbors.map(\.box.maxX).max(),
              tag.minX >= minX + (maxX - minX) * 0.68, tag.maxX <= maxX + 2 else { return nil }
        return CGRect(x: minX - 2, y: geometry.canvas.minY, width: maxX - minX + 4, height: geometry.canvas.height)
    }

    private static func recoverRegion(_ id: ResearchPDFObjectID, page: PDFPage, pageNumber: Int, tag: CGRect,
                                      tagRange: NSRange, rows: [Line], geometry: ResearchPDFLayout.Geometry,
                                      physicalLane: CGRect?) throws -> Object? {
        let near = rows.filter { row in
            row.box.insetBy(dx: -2, dy: -2).contains(CGPoint(x: tag.midX, y: tag.midY)) &&
                row.kind != .header && row.kind != .footer && row.kind != .caption && row.kind != .table &&
                row.kind != .figureLabel && row.kind != .footnote && !row.position.ocr
        }
        let tagID = "(\(id.number))"
        let numbered = near.filter { $0.text.precomposedStringWithCompatibilityMapping.lowercased()
            .filter({ !$0.isWhitespace }).hasSuffix(tagID) }
        guard let address = numbered.first ?? near.min(by: { abs($0.box.midY-tag.midY) < abs($1.box.midY-tag.midY) }),
              numbered.count <= 1, physicalLane != nil ||
                near.allSatisfy({ $0.position.column == address.position.column }) else { return nil }

        let lane = rows.filter { !$0.position.ocr &&
            (physicalLane?.contains($0.box) ?? ($0.position.column == address.position.column)) }
        let proseBlocks = Set(lane.filter { $0.kind == .body && $0.isProse }.compactMap(\.position.blockIndex))
        // Short final lines of a paragraph still delimit the display, even when a line by
        // itself is too short for the prose test.
        let prose = lane.filter { line in
            let proseBlock = line.kind == .body && line.position.blockIndex.map { proseBlocks.contains($0) } == true
            return (proseBlock || line.isProse && (line.kind == .body || line.kind == .heading)) &&
                abs(line.box.midY - tag.midY) < geometry.canvas.height * 0.18
        }
        guard let left = prose.map(\.box.minX).min(), let right = prose.map(\.box.maxX).max(),
              right - left >= 65, tag.maxX >= left + (right - left) * 0.72,
              tag.maxX <= right + 16 else { return nil }
        let heights = prose.map(\.box.height).sorted()
        let height = max(7, min(16, heights[heights.count / 2]))
        guard tag.width < height * 4, tag.height < height * 5 else { return nil }
        let area = CGRect(x: left-1, y: tag.minY-height*0.7, width: max(tag.maxX, right)-left+4,
                          height: tag.height+height*1.4).intersection(physicalLane ?? geometry.canvas)
        guard let raster = Raster(page, area: area, transform: geometry.display) else { return nil }

        let proseRows = prose.filter { $0.box.height < height * 1.75 }
        func overlapsProse(_ band: CGRect) -> Bool {
            proseRows.contains { line in
                let overlap = line.box.intersection(band)
                return !overlap.isNull && overlap.height > min(band.height, line.box.height) * 0.32 &&
                    overlap.width > (right-left) * 0.14
            }
        }
        let isolated = raster.bands.filter { !overlapsProse($0) }
        let possible = isolated.filter { band in
            let tagArea = CGRect(x: tag.minX-1, y: band.minY, width: tag.width+2, height: band.height)
            guard band.midY >= tag.minY-1, band.midY <= tag.maxY+1,
                  raster.inkBounds(in: tagArea) != nil else { return false }
            let display = lane.filter { line in
                !line.isProse && [.body, .formula, .heading].contains(line.kind) &&
                    line.box.minX < tag.minX - height * 1.2 && line.box.intersects(band) &&
                    raster.inkBounds(in: band.intersection(line.box)) != nil
            }
            if !display.contains(where: { Self.matches(formulaCue, $0.text) }) {
                // Unmapped mathematical fonts can leave only private glyph
                // codes. Their values say nothing about the characters.
                // For this path require a separately confirmed number and
                // several distinct surviving printed glyphs inside the band.
                let codes = Set(display.flatMap { $0.text.unicodeScalars }
                    .filter { $0.properties.generalCategory == .privateUse })
                guard codes.count >= 4, numbered.count == 1, address.reliable else { return false }
            }
            return band.height >= height * 0.43
        }
        guard possible.count <= 3, !possible.isEmpty else { return nil }

        // If multiple raster rows could explain an over-large PDF selection rectangle,
        // use local OCR solely to corroborate the printed tag. OCR is never sent as the
        // formula, and failure to confirm a unique tag leaves the object unresolved.
        var row = possible[0]
        if possible.count > 1 {
            let verified = try possible.filter { band in
                try Task.checkCancellation()
                let area = CGRect(x: tag.minX-3, y: band.minY-2, width: tag.width+6, height: band.height+4)
                return recognizesNumber(id.number, in: area, page: page, geometry: geometry)
            }
            guard verified.count == 1 else { return nil }
            row = verified[0]
        }
        // Adjacent non-prose strokes on a script or a multiline equation can be disjoint.
        // Join them only inside this isolated display, up to the next proven text row.
        let before = proseRows.filter { $0.box.midY > row.midY }.map(\.box.minY).min() ?? row.maxY+height*0.65
        let after = proseRows.filter { $0.box.midY < row.midY }.map(\.box.maxY).max() ?? row.minY-height*0.65
        var region = row
        for band in isolated where band != row && band.minY >= after && band.maxY <= before {
            let distance = max(row.minY-band.maxY, band.minY-row.maxY)
            // A disjoint band with ink at the printed-tag margin may be another object.
            guard distance <= height * 0.75,
                  raster.inkBounds(in: CGRect(x: tag.minX-2, y: band.minY, width: tag.width+7, height: band.height)) == nil else { continue }
            region = region.union(band)
        }
        guard let ink = raster.inkBounds(in: region),
              ink.minX < tag.minX-height*1.2, ink.maxX >= tag.minX,
              let visual = visualPosition(ink.insetBy(dx: -3, dy: -1.25), page: pageNumber, geometry: geometry),
              let printed = raster.inkBounds(in: CGRect(x: tag.minX-1, y: row.minY, width: tag.width+2, height: row.height))
        else { return nil }
        let position = ResearchPDFSourcePosition(page: pageNumber, bounds: printed.applying(geometry.display.inverted()),
                         column: address.position.column, blockIndex: address.position.blockIndex,
                         sourceRange: tagRange)
        let proof = Line(position: position, box: printed, text: tagID, kind: .formula, reliable: true)
        var object = Object(id: id, page: pageNumber, primary: [proof], supporting: [],
                            visual: visual, exactEquation: nil, labels: [])
        object.physicalEquationLane = physicalLane
        // A definition whose variables were split into superscripts can be useful in
        // original visual form. Keep that neighboring line out of the primary formula.
        if let definition = lane.filter({ line in
            !line.reliable && line.box.midY < region.midY && region.minY-line.box.midY < height*2.5 &&
                definitionCue.firstMatch(in: line.text, range: NSRange(location: 0, length: line.text.utf16.count)) != nil
        }).max(by: { $0.box.midY < $1.box.midY }),
           let line = raster.bands.filter({ $0.maxY < region.minY && $0.intersects(definition.box) }).last,
           let actual = raster.inkBounds(in: line) {
            object.supportingVisual = visualPosition(actual.insetBy(dx: -2, dy: -1.25), page: pageNumber, geometry: geometry)
        }
        return object
    }

    private struct Raster {
        let area: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ page: PDFPage, area: CGRect, transform: CGAffineTransform, maximumScale: CGFloat = 4) {
            guard let original = page.pageRef, !area.isEmpty, !area.isInfinite else { return nil }
            let scale = min(maximumScale, 1600/area.width, 480/area.height)
            let width = Int(ceil(area.width*scale)), height = Int(ceil(area.height*scale))
            guard width > 0, height > 0 else { return nil }
            var pixels = [UInt8](repeating: 255, count: width*height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let canvas = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                canvas.scaleBy(x: scale, y: scale)
                canvas.translateBy(x: -area.minX, y: -area.minY)
                canvas.concatenate(transform)
                canvas.drawPDFPage(original)
                return true
            }
            guard drawn else { return nil }
            self.area = area
            self.scale = scale
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        func box(x0: Int, x1: Int, y0: Int, y1: Int) -> CGRect {
            CGRect(x: area.minX+CGFloat(x0)/scale, y: area.minY+CGFloat(height-y1)/scale,
                   width: CGFloat(x1-x0)/scale, height: CGFloat(y1-y0)/scale)
        }

        var bands: [CGRect] {
            var first: Int?
            var last = 0
            var result: [CGRect] = []
            let maxGap = max(1, Int(scale * 1.15))
            func flush() {
                if let first, last-first >= Int(scale*1.8) {
                    result.append(box(x0: 0, x1: width, y0: first, y1: last+1))
                }
                first = nil
            }
            for row in 0..<height {
                guard pixels[(row*width)..<((row+1)*width)].contains(where: { $0 < 165 }) else { continue }
                if row-last > maxGap { flush() }
                if first == nil { first = row }
                last = row
            }
            flush()
            return result.reversed()
        }

        func inkBounds(in rect: CGRect) -> CGRect? {
            let rect = rect.intersection(area)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            let x0 = max(0, Int(floor((rect.minX-area.minX)*scale)))
            let x1 = min(width, Int(ceil((rect.maxX-area.minX)*scale)))
            let y0 = max(0, height-Int(ceil((rect.maxY-area.minY)*scale)))
            let y1 = min(height, height-Int(floor((rect.minY-area.minY)*scale)))
            guard x0 < x1, y0 < y1 else { return nil }
            var l = x1, r = x0, t = y1, b = y0
            for y in y0..<y1 {
                for x in x0..<x1 where pixels[y*width+x] < 165 {
                    l = min(l,x); r = max(r,x+1); t = min(t,y); b = max(b,y+1)
                }
            }
            return l < r && t < b ? box(x0:l,x1:r,y0:t,y1:b) : nil
        }

        var image: CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                           decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// An edge passing through a printed stroke is observable on the original
    /// page, even if the PDF font's text box is too small. Find a clean
    /// scanline beyond the crossing within the surrounding local display. Never invent
    /// the fraction, script or label on the other side of an unresolved edge.
    private static func checkedEquationBoundary(_ object: Object, in native: PDFPage,
                                                on page: ResearchPDFIndex.Page, geometry: ResearchPDFLayout.Geometry) throws -> ResearchPDFSourcePosition? {
        guard let position = object.visual else { return nil }
        var rect = position.bounds.applying(geometry.display)
        let fontHeight = object.primary.map(\.printedHeight).filter { (4...30).contains($0) }.sorted()
        let distance = fontHeight.isEmpty ? 12 : fontHeight[fontHeight.count / 2]
        // A below-baseline printed number can seed only the bottom of a
        // tall display. Render to the surrounding line spacing so the first
        // blank scanline above the whole glyph can be verified locally.
        let area = rect.insetBy(dx: 0, dy: -distance * 3).intersection(geometry.canvas)
        guard let raster = Raster(native, area: area, transform: geometry.display, maximumScale: 2.5) else {
            throw ResearchMaterialError.message("\(object.id.label) 的原页像素未能读取，无法核实公式边缘。")
        }
        // A crop seeded by a tag may overlap the adjacent *numbered* equation.
        // In that case split at an actual blank scanline between the printed
        // numbers before repairing a stroke at either edge.
        if let anchor = object.primary.first {
            let neighbors = lines(on: page, geometry: geometry).filter {
                $0.position != anchor.position && abs($0.box.maxX - anchor.box.maxX) < distance &&
                    $0.baseline > area.minY && $0.baseline < area.maxY &&
                    !$0.isProse && tag(equationNumber, $0.text).map { $0.0 != object.id.number } == true
            }
            let ruler = area.minY + CGFloat(raster.height) / raster.scale
            for line in [neighbors.filter { $0.baseline > anchor.baseline }.min { $0.baseline < $1.baseline },
                         neighbors.filter { $0.baseline < anchor.baseline }.max { $0.baseline < $1.baseline }].compactMap({ $0 }) {
                let lower = min(anchor.baseline, line.baseline), upper = max(anchor.baseline, line.baseline)
                let midpoint = (lower + upper) / 2
                let gap = (0..<raster.height).compactMap { row -> CGFloat? in
                    let y = ruler - (CGFloat(row) + 0.5) / raster.scale
                    guard y > lower && y < upper else { return nil }
                    let offset = row * raster.width
                    return raster.pixels[offset..<(offset + raster.width)].contains { $0 < 155 } ? nil : y
                }.min { abs($0 - midpoint) < abs($1 - midpoint) }
                guard let gap else { continue }
                if line.baseline < anchor.baseline && gap > rect.minY {
                    rect = CGRect(x: rect.minX, y: gap, width: rect.width, height: rect.maxY - gap)
                } else if line.baseline > anchor.baseline && gap < rect.maxY {
                    rect.size.height = gap - rect.minY
                }
            }
        }
        if let anchor = object.primary.first {
            let rows = lines(on: page, geometry: geometry)
            let proseBlocks = Set(rows.filter { $0.kind == .body && $0.isProse }.compactMap(\.position.blockIndex))
            // A short final line belongs to the neighboring paragraph when
            // its block has verified prose. Protect it even if it is only a
            // hyphenated remainder, a citation or a few introductory words.
            let above = rows.filter { row in
                row.reliable && row.kind == .body && row.position.blockIndex.map(proseBlocks.contains) == true &&
                    row.position.column == anchor.position.column && row.baseline > anchor.baseline + distance * 0.9 &&
                    row.box.minY < rect.maxY + distance * 0.25 &&
                    row.box.intersection(area).width > min(row.box.width, rect.width) * 0.2
            }.min(by: { $0.baseline < $1.baseline })
            if let above {
                let low = max(anchor.baseline + distance * 0.65, above.box.minY - distance * 0.85)
                let high = min(rect.maxY, above.box.minY + distance * 0.16)
                let top = area.minY + CGFloat(raster.height) / raster.scale
                let edge = above.box.minY
                let gap = (0..<raster.height).compactMap { row -> CGFloat? in
                    let y = top - (CGFloat(row) + 0.5) / raster.scale
                    guard (low...max(low, high)).contains(y), y <= high else { return nil }
                    let start = row * raster.width
                    guard !raster.pixels[start..<(start + raster.width)].contains(where: { $0 < 155 }) else { return nil }
                    return y
                }.min(by: { abs($0 - edge) < abs($1 - edge) })
                if let gap { rect.size.height = gap - rect.minY }
            }
        }
        func extent(at edge: CGFloat, direction: Int) throws -> CGFloat {
            let rasterTop = area.minY + CGFloat(raster.height) / raster.scale
            let sample = (rasterTop - edge) * raster.scale - 0.5
            let inner = Int(direction > 0 ? ceil(sample) : floor(sample))
            let outer = inner - direction
            guard inner >= 0 && outer >= 0 && max(inner, outer) < raster.height else { return edge }
            let rowWidth = raster.width
            guard (0..<rowWidth).contains(where: { x in
                raster.pixels[inner * rowWidth + x] < 135 && raster.pixels[outer * rowWidth + x] < 135
            }) else { return edge }
            // The original edge has ink on both sides. A true whitespace row
            // separates the target glyphs from the neighboring prose or display.
            var row = outer
            while row > 0 && row < raster.height - 1 {
                let start = row * rowWidth
                if !raster.pixels[start..<(start + rowWidth)].contains(where: { $0 < 155 }) {
                    return rasterTop - (CGFloat(row) + 0.5) / raster.scale
                }
                row -= direction
            }
            throw ResearchMaterialError.message("\(object.id.label) 位于文件第 \(object.page) 页，原页笔画穿过局部裁图边缘，未找到与相邻内容分离的空白。请核对原页。")
        }
        let upper = try extent(at: rect.maxY, direction: 1), lower = try extent(at: rect.minY, direction: -1)
        return visualPosition(CGRect(x: rect.minX, y: min(lower, rect.minY), width: rect.width,
                                     height: max(upper, rect.maxY) - min(lower, rect.minY)),
                              page: object.page, geometry: geometry)
    }

    private static func recognizesNumber(_ number: String, in region: CGRect, page: PDFPage,
                                         geometry: ResearchPDFLayout.Geometry) -> Bool {
        guard let image = Raster(page, area: region, transform: geometry.display, maximumScale: 6)?.image else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return false }
        guard let results = request.results, results.count == 1,
              let candidate = results[0].topCandidates(1).first, candidate.confidence >= 0.8 else { return false }
        let exact = candidate.string.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
        return exact == "(\(number))"
    }

    /// Context follows the verified display in the existing reading lanes. Never
    /// mix the equation's original crop with the surrounding explanatory prose.
    private func equationContext(for object: Object, on page: ResearchPDFIndex.Page) -> [Line] {
        guard let geometry = page.geometry, let visual = object.visual, let anchor = object.primary.first,
              let anchorColumn = anchor.position.column else { return [] }
        let box = visual.bounds.applying(geometry.display)
        let rows = Self.lines(on: page, geometry: geometry)
        let spanning = Self.equationSpansLanes(at: anchor, rows: rows, size: max(8, min(14, anchor.box.height)),
                                               geometry: geometry)
        let column = spanning ? 0 : anchorColumn
        let lane = rows.filter {
            (object.physicalEquationLane?.contains($0.box) ?? ($0.position.column == column)) && !$0.box.intersects(box)
        }
        let distance = geometry.canvas.height * 0.17
        let lookBehind = lane.filter { $0.box.midY > box.maxY && $0.box.minY <= box.maxY + distance }
        let lookAhead = lane.filter { $0.box.midY < box.minY && $0.box.maxY >= box.minY - distance }
        var before = Self.equationParagraph(lookBehind, page: page, backwards: true)
        var after = Self.equationParagraph(lookAhead, page: page, backwards: false)
        let math = rows.filter { (spanning || $0.position.column == column) && $0.box.intersects(box) && !$0.isProse }
        let variables = Self.variables(in: math.map(\.text).joined(separator: " "))
        if let first = before.first {
            let preceding = lane.filter { $0.box.midY > first.box.midY && $0.box.minY <= box.maxY + distance * 1.75 }
            before = Self.displayPreamble(preceding, following: first, page: page, variables: variables) + before
        } else {
            before = Self.displayPreamble(lookBehind, following: anchor, page: page, variables: variables)
        }
        if after.isEmpty, let heading = lookAhead.max(by: { $0.baseline < $1.baseline }),
           heading.kind == .heading, box.minY - heading.box.maxY <= max(heading.printedHeight, 8) * 1.7 {
            // A new subsection can immediately define a matrix in the preceding
            // display. Cross one heading only if the first original paragraph
            // explicitly refers to the exact numbered equation.
            let following = lookAhead.filter { $0.baseline < heading.baseline }
            let candidate = Self.equationParagraph(following, page: page, backwards: false)
            let opening = candidate.prefix(2).map(\.text).joined(separator: " ")
            let referenced = ResearchPDFObjectID.addresses(in: opening).filter { $0.kind == .equation }
            if referenced == [object.id] { after = candidate }
        }

        // A transition must have an actual connection to this formula. Position
        // alone would mistakenly assign the next section's definitions to it.
        if before.isEmpty, geometry.canvas.maxY - box.maxY < distance {
            before = adjoiningEquationParagraph(on: page, rows: rows, from: column, backwards: true,
                                                 around: object.id, variables: variables)
        }
        if after.isEmpty, box.minY - geometry.canvas.minY < distance {
            after = adjoiningEquationParagraph(on: page, rows: rows, from: column, backwards: false,
                                                around: object.id, variables: variables)
        }
        return before + after
    }

    /// Connect two displays through the intervening author paragraph when it
    /// refers back to an expression and introduces the next step in the same
    /// physical reading lane. This does not require repeated equation numbers.
    func derivationBetween(_ displays: [Object]) -> [Line] {
        guard displays.count == 2, displays.allSatisfy({ $0.id.kind == .equation }),
              let first = displays.first, let last = displays.last, first.page == last.page,
              let page = graphicPages[first.page], let geometry = page.geometry,
              let left = first.visual, let right = last.visual,
              let column = first.primary.first?.position.column, last.primary.first?.position.column == column else { return [] }
        let boxes = [left, right].map { $0.bounds.applying(geometry.display) }.sorted { $0.midY > $1.midY }
        let lowerEdge = boxes[0].minY, upperEdge = boxes[1].maxY
        guard lowerEdge > upperEdge, lowerEdge - upperEdge < geometry.canvas.height * 0.30 else { return [] }
        let band = Self.lines(on: page, geometry: geometry).filter {
            $0.position.column == column && $0.baseline > upperEdge && $0.baseline < lowerEdge
        }.sorted(by: { $0.baseline > $1.baseline })
        guard !band.contains(where: {
            $0.kind == .heading || $0.kind == .caption || $0.kind == .table ||
                ResearchPDFLayout.paragraphRole($0.text) != .ordinary
        }) else { return [] }
        let prose = band.filter { $0.reliable && $0.kind == .body && $0.position.blockIndex.map {
            !page.blocks[$0].detachedCaption && page.blocks[$0].paragraphRole == .ordinary
        } == true }
        let text = prose.map(\.text).joined(separator: " ")
        let link = #"(?i)\b(?:previous|preceding|above)\s+(?:expression|equation|formula|inequality)\b|\b(?:to\s+(?:estimate|compute|approximate|evaluate|derive|obtain)\s+(?:this|it)|substitut(?:e|ing)\s+(?:this|it))\b|(?:由上式|代入上式|对该式)"#
        guard text.utf16.count <= 1600, text.range(of: link, options: .regularExpression) != nil else { return [] }
        return prose
    }

    /// A nearby definition may be ordinary prose with one damaged embedded
    /// math font. Preserve the original paragraph area whenever its linkage
    /// to the display and its sentence boundary are both visible.
    private static func adjacentDefinitionImage(for object: Object, page: ResearchPDFIndex.Page,
                                                geometry: ResearchPDFLayout.Geometry) -> ResearchPDFSourcePosition? {
        guard let visual = object.visual, let anchor = object.primary.first else { return nil }
        let edge = visual.bounds.applying(geometry.display).minY
        let rows = lines(on: page, geometry: geometry).filter { line in
            (object.physicalEquationLane?.contains(line.box) ?? (line.position.column == anchor.position.column)) &&
                line.baseline < edge && (line.kind == .body || line.kind == .heading || line.kind == .formula)
        }.sorted { $0.baseline > $1.baseline }
        // A definition with a large operator can be split horizontally by
        // PDFKit and classified as a formula. Verify its opening independently
        // of the reading order of the smaller text fragments on that line.
        if let opening = rows.prefix(5).first(where: { line in
            line.kind == .formula && !line.position.ocr && line.box.minY < edge &&
                edge - line.box.maxY < max(4, line.printedHeight * 1.3) &&
                line.text.range(of: #"(?i)^\s*(?:where|其中)\s+\p{L}[∗*′\p{N}]*\s*="#, options: .regularExpression) != nil
        }) {
            let height = min(max(opening.printedHeight, 8), 15)
            let matching = rows.filter { line in
                line.position != opening.position && line.box.minX >= opening.box.minX - height * 0.65 &&
                    line.box.maxY <= edge + height * 0.55 &&
                    line.box.midY >= opening.box.midY - height * 1.6 &&
                    line.box.midY <= opening.box.maxY + height * 0.25 &&
                    (line.kind == .body || line.kind == .formula)
            }
            if matching.contains(where: { $0.box.minX > opening.box.minX + height && $0.box.intersects(opening.box.insetBy(dx: -height, dy: 0)) }) {
                let bounds = matching.reduce(opening.box) { $0.union($1.box) }.insetBy(dx: -1.2, dy: -1)
                if let position = visualPosition(bounds, page: page.number, geometry: geometry) { return position }
            }
        }
        guard let opening = rows.first, opening.kind == .body, opening.reliable,
              edge - opening.box.maxY < opening.printedHeight * 1.8,
              let prefix = definitionOpening.firstMatch(in: opening.text, range: NSRange(location: 0, length: opening.text.utf16.count))
        else { return nil }
        let cue = (opening.text as NSString).substring(with: prefix.range).trimmingCharacters(in: .whitespaces).lowercased()
        guard cue == "where" || cue == "其中" || numberedEquations(in: opening.text) == [object.id.number] else { return nil }
        var bounds = opening.box
        var previous = opening
        var damaged = false
        for line in rows.dropFirst().prefix(7) {
            guard line.kind == .body, tagRangeFor(line.text) == nil,
                  previous.baseline - line.baseline <= opening.printedHeight * 1.7,
                  line.box.minX >= opening.box.minX - opening.printedHeight * 0.6,
                  line.box.maxX <= opening.box.maxX + opening.printedHeight * 1.5
            else { return nil }
            bounds = bounds.union(line.box)
            damaged = damaged || !line.reliable
            previous = line
            if damaged && (ResearchPDFLayout.endsCaptionSentence(line.text) ||
                           line.text.range(of: #"[.!?]\s+[\p{Lu}\p{Greek}\x{0}]"#, options: .regularExpression) != nil) {
                return visualPosition(bounds.insetBy(dx: -1, dy: -0.75), page: page.number, geometry: geometry)
            }
        }
        return nil
    }

    /// A derivation can introduce its variables before an unnumbered intermediate
    /// display. Cross one such display only if its verified notation is shared.
    private static func displayPreamble(_ rows: [Line], following first: Line, page: ResearchPDFIndex.Page,
                                        variables: Set<String>) -> [Line] {
        let ordered = rows.sorted { $0.box.midY < $1.box.midY }
        guard let nearest = ordered.first, nearest.kind == .formula, nearest.reliable,
              nearest.box.minY - first.box.maxY <= max(first.box.height, nearest.box.height) * 1.6 else { return [] }
        let display = ordered.prefix { row in
            guard row.position.blockIndex == nearest.position.blockIndex, row.reliable, !row.isProse else { return false }
            guard let (_, suffix) = tag(equationNumber, row.text) else { return true }
            // An attached function argument such as f(x1) is not the printed tag.
            let prefix = (row.text as NSString).substring(to: suffix.location)
            return prefix.last.map { !$0.isWhitespace } == true
        }
        guard let top = display.last,
              !variables.isDisjoint(with: Self.variables(in: display.map(\.text).joined(separator: " "))),
              !ordered.dropFirst(display.count).contains(where: { row in
                  tagRangeFor(row.text) != nil && row.box.midY <= top.box.maxY + top.box.height * 0.6
              }) else { return [] }
        let prose = equationParagraph(Array(ordered.dropFirst(display.count)), page: page, backwards: true, limit: 700)
        guard let last = prose.last, last.box.minY - top.box.maxY <= max(last.box.height, top.box.height) * 1.6 else { return [] }
        return prose
    }

    private func adjoiningEquationParagraph(on page: ResearchPDFIndex.Page, rows: [Line], from column: Int, backwards: Bool,
                                            around id: ResearchPDFObjectID, variables: Set<String>) -> [Line] {
        let adjoining: ResearchPDFIndex.Page
        let targetColumn: Int
        let otherColumn = backwards ? 1 : 2
        if column == (backwards ? 2 : 1), page.blocks.contains(where: { $0.column == otherColumn && $0.kind == .body }) {
            adjoining = page
            targetColumn = otherColumn
        } else {
            guard let neighbor = graphicPages[page.number + (backwards ? -1 : 1)] else { return [] }
            adjoining = neighbor
            let edge = backwards ? 2 : 1
            targetColumn = neighbor.blocks.contains { $0.kind == .body && $0.column == edge } ? edge : 0
        }
        guard page.reliableOrder, adjoining.reliableOrder, let geometry = adjoining.geometry else { return [] }
        let adjoiningRows = page.number == adjoining.number ? rows : Self.lines(on: adjoining, geometry: geometry)
        let lane = adjoiningRows.filter { $0.position.column == targetColumn }
        let candidate = Self.equationParagraph(lane, page: adjoining, backwards: backwards)
        let prose = candidate.map(\.text).joined(separator: " ")
        let equations = ResearchPDFObjectID.addresses(in: prose).filter { $0.kind == .equation }
        guard equations.allSatisfy({ $0 == id }) else { return [] }
        if equations.contains(id) { return candidate }
        let defined = Self.variables(in: prose, pattern: Self.definedVariable, captured: 1)
        guard !variables.isDisjoint(with: defined) else { return [] }
        return candidate
    }

    private static func equationParagraph(_ lane: [Line], page: ResearchPDFIndex.Page, backwards: Bool,
                                          limit: Int = 1_600) -> [Line] {
        let proseBlocks = Set(lane.filter { $0.reliable && $0.kind == .body && $0.isProse }
            .compactMap(\.position.blockIndex))
        let rows = lane.sorted { backwards ? $0.box.midY < $1.box.midY : $0.box.midY > $1.box.midY }
        let advances = zip(rows, rows.dropFirst()).compactMap { first, second -> CGFloat? in
            let advance = abs(first.baseline - second.baseline)
            return first.kind == .body && second.kind == .body && first.reliable && second.reliable &&
                first.position.blockIndex == second.position.blockIndex &&
                (6...24).contains(advance) ? advance : nil
        }.sorted()
        let leading = advances.isEmpty ? 0 : advances[advances.count / 2]
        var selected: [Line] = []
        var length = 0
        for row in rows {
            guard let block = row.position.blockIndex, !page.blocks[block].detachedCaption else { continue }
            if row.kind == .heading || ResearchPDFLayout.paragraphRole(row.text) != .ordinary ||
                tagRangeFor(row.text) != nil || matches(sectionStart, row.text) { break }
            if row.kind == .formula { break }
            // Floating objects are not in the running prose. Retain short tail
            // lines within a genuine prose block (e.g. a lone variable name).
            guard row.kind == .body, proseBlocks.contains(block) || matches(variableDefinition, row.text) else { continue }
            guard row.reliable else { break }
            if let previous = selected.last {
                let gap = backwards ? row.box.minY - previous.box.maxY : previous.box.minY - row.box.maxY
                let height = max(previous.box.height, row.box.height)
                // Some embedded fonts return much smaller ink boxes in the
                // same paragraph. Match its actual baselines before splitting it.
                let sameParagraph = row.position.blockIndex == previous.position.blockIndex &&
                    abs(row.box.minX - previous.box.minX) < max(height, leading) &&
                    abs(row.baseline - previous.baseline) <= leading * 1.55
                if gap > height * 1.35 && !sameParagraph { break }
            }
            length += row.text.utf16.count
            if length > limit { break }
            selected.append(row)
        }
        return backwards ? Array(selected.reversed()) : selected
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    private static func variables(in text: String, pattern: NSRegularExpression = variableName,
                                  captured: Int = 0) -> Set<String> {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let source = normalized as NSString
        return Set(pattern.matches(in: normalized, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: captured)) })
    }

    /// Find definitions for explicitly requested notation using the formula's
    /// reading lane and original spans. An adjacent paragraph or a token
    /// match alone does not establish that the publication defines a symbol.
    func requestedDefinitions(for object: Object, request: ResearchPDFRequest, glyphPage: ResearchPDFGlyphPage?) ->
        (lines: [Line], missing: [String], displays: [(symbol: String, cue: [Line], id: ResearchPDFObjectID)],
         corrections: [(original: ResearchPDFSourcePosition, line: Line)]) {
        let requirements = request.symbolRequirements
        let requested = requirements.map(\.name)
        guard object.id.kind == .equation, !requested.isEmpty,
              let page = graphicPages[object.page], let geometry = page.geometry,
              let anchor = object.primary.first, let column = anchor.position.column else { return ([], requested, [], []) }
        let initial = Self.lines(on: page, geometry: geometry)
        let spanning = Self.equationSpansLanes(at: anchor, rows: initial, size: max(8, min(14, anchor.box.height)),
                                               geometry: geometry)
        func isInLane(_ line: Line) -> Bool {
            return line.reliable && line.kind == .body &&
                line.position.blockIndex.map { !page.blocks[$0].detachedCaption } == true &&
                (object.physicalEquationLane?.contains(line.box) ??
                    (line.position.column == column || spanning && line.position.column == 0))
        }
        // A textual definition can be missing one visible symbol even when the
        // rest of its PDFKit line is reliable. Use the other engine's unchanged
        // row only when all remaining characters agree.
        var corrections: [(original: ResearchPDFSourcePosition, line: Line)] = []
        let simpleSymbols = Set(requested.filter { $0.unicodeScalars.count == 1 })
        let ordered = initial.map { line -> Line in
            guard isInLane(line), abs(line.baseline - anchor.baseline) <= geometry.canvas.height * 0.46,
                  Self.matches(Self.definitionCue, line.text),
                  let replacement = glyphPage?.recovering(line: line.text, within: line.position.bounds,
                                                          requiredSymbols: simpleSymbols) else { return line }
            let position = ResearchPDFSourcePosition(page: line.position.page, bounds: replacement.bounds,
                column: line.position.column, blockIndex: line.position.blockIndex, verifiedGlyphEngine: "pdfium")
            let supported = Line(position: position, box: replacement.bounds.applying(geometry.display),
                text: replacement.text, kind: line.kind, reliable: true, typeHeight: line.typeHeight,
                typeCenter: line.typeCenter)
            corrections.append((line.position, supported))
            return supported
        }
        let lane = ordered.filter(isInLane)
        let adjacent = request.requestsAdjacentDefinitions ? [object.page + 1, object.page - 1].compactMap { number
            -> [[Line]]? in
            guard let other = graphicPages[number], let geometry = other.geometry else { return nil }
            let rows = Self.lines(on: other, geometry: geometry)
            let blocks = Array(other.blocks.indices.filter {
                other.blocks[$0].kind == .body && !other.blocks[$0].detachedCaption &&
                    other.blocks[$0].paragraphRole == .ordinary
            })
            let window = number > object.page ? Array(blocks.prefix(20)) : Array(blocks.suffix(20))
            return window.map { index in rows.filter { $0.position.blockIndex == index && $0.reliable } }
        }.flatMap { $0 } : []
        let symbols = Array(requested.prefix(12))
        var collected: [Line] = []
        var missing = Array(requested.dropFirst(symbols.count))
        var displays: [(symbol: String, cue: [Line], id: ResearchPDFObjectID)] = []
        let nearby = object.supporting.map { line in
            corrections.first { $0.original == line.position }?.line.text ?? line.text
        }.joined(separator: " ").precomposedStringWithCompatibilityMapping
        for symbol in symbols {
            // A printed equation explicitly defining x is stronger evidence
            // than a later observation such as “x is small”.
            // An explicit author cue ("we define …") binds the
            // following display; a bare occurrence in a nearby equation does not.
            if let display = definitionDisplay(for: symbol, in: ordered, excluding: object.id) {
                displays.append((symbol, display.cue, display.id))
                missing.append(symbol)
                continue
            }
            let stem = NSRegularExpression.escapedPattern(for: symbol)
            let printed = requirements.first { $0.name == symbol }?.printed ?? symbol
            let superscript = printed.firstIndex(of: "^").flatMap { marker -> String? in
                let text = printed[printed.index(after: marker)...].trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                return !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber } ? text : nil
            }
            let script = superscript.map { "(?:\\s*" + NSRegularExpression.escapedPattern(for: $0) + ")?" } ?? ""
            let indices = printed.range(of: #"[,，]([a-zA-Z0-9]+)\}?(?:\^|$)"#, options: .regularExpression)
                .map { printed[$0].dropFirst().prefix { $0.isLetter || $0.isNumber } }
            let secondIndex = indices.map { "[,，]\\s*" + NSRegularExpression.escapedPattern(for: String($0)) } ?? ""
            let name = #"(?<![\p{Latin}\p{Greek}\p{N}])"# + stem + secondIndex + script +
                #"(?:[\p{Greek}])?[∗*′]*(?:\s*[(][^)]{1,24}[)])?(?![\p{Latin}\p{Greek}\p{N}])"#
            let paired = #"(?:\s*(?:,|and|与|和)\s*[\p{Latin}\p{Greek}](?:[\p{Greek}\d]*|\s?[a-z](?![a-z]))(?:[,，]\s*[a-z0-9])?)*"#
            let meaning = paired + #"\s*(?:>\s*0\s*)?(?:(?i:is|are|denotes?|represents?|describes?|means?|stands?\s+for)\b|表示|是指)"#
            let namedRole = #"(?i:\b(?:bias(?:es)?|variances?|parameters?|constants?|factors?|statistics?|functions?|variables?|coefficients?|vectors?|matri(?:x|ces)|measures?|divergences?|rates?|weight decay))\s*,?\s*\(?"# + name +
                #"(?![\p{Latin}\p{Greek}\p{N}])"#
            let assignedName = #"(?i:\b(?:denoted|designated|represented|written)\s+(?:by|as))\s+"# + name +
                #"(?![\p{Latin}\p{Greek}\p{N}])"#
            let role = #"(?:\bexpected return\b|\badvantage function\b|\bvalue function\b|\bdiscount factor\b)"#
            // Distributing a dataset “across P nodes” declares what the
            // count measures, even in the absence of a separate “P is” clause.
            let countedGroup = #"(?i:\b(?:across|among|over|between))\s+"# + name +
                #"\s+(?i:[a-z]{2,}(?:s|ies))\b"#
            // A declaration may specify a domain before the verb, e.g.
            // “Let h: ℝ → ℝ be …”. A nearby use of h is not a definition.
            let declaredType = name + #"\s*(?::\s*[^.,;:]{1,36}→[^.,;:]{1,30}\s+)?(?i:\bbe\s+(?:a|an|the)\b)"#
            let piecewiseCondition = #"(?i:\bwhere|其中)\s+"# + name +
                #"\s*=\s*[-−+]?\d+(?:\.\d+)?\s+(?i:if\b)[^;。]{4,180};\s*(?i:otherwise\b)\s+"# + name
            let declaration = #"(?i:\b(?:where|let)\s+)"# + name + #"\s*(?:∈|=)\s*[^,.;，。]{1,120}"#
            let assignedValue = name + #"\s*(?::=|≔)\s*\S"#
            let authorNotation = #"(?i:\bwith)\s+"# + name + #"\s+(?i:we\s+(?:indicate|denote|represent|mean))\b"#
            let authorProse = [name + meaning, namedRole, assignedName, countedGroup, declaredType,
                               authorNotation, name + #"[^.]{0,96}"# + role]
            let symbolDeclarations = request.requiresProseDefinitions ? [] : [declaration, assignedValue, piecewiseCondition]
            let definition = (authorProse + symbolDeclarations).joined(separator: "|")
            guard let expression = try? NSRegularExpression(pattern: definition) else { continue }
            if Self.matches(expression, nearby) { continue }
            if let glyphPage, let visual = object.visual {
                let fused = #"(?i:\bwhere)\s+"# + stem + #"(?i:is|are)\s+\p{L}"#
                if object.supporting.contains(where: { line in
                    line.text.range(of: fused, options: .regularExpression) != nil &&
                    glyphPage.containsSymbol(symbol, within: line.position.bounds)
                }) { continue }
                if symbol.unicodeScalars.count == 1,
                   glyphPage.glyphs(in: visual.bounds).contains(where: { String($0.scalar) == symbol }),
                   object.supporting.contains(where: { line in
                       let distance = visual.bounds.applying(geometry.display).minY - line.box.maxY
                       return (-line.printedHeight * 0.15...line.printedHeight * 2.6).contains(distance) &&
                           line.text.range(of: #"(?i)^\s*(?:this|the)\s+(?:quantity|term|value|variable|coefficient)\s+(?:essentially\s+)?(?:measures?|denotes?|represents?|is)\b"#,
                                           options: .regularExpression) != nil
                   }) { continue }
            }
            var matches: [(distance: CGFloat, rows: [Line])] = []
            for line in lane where abs(line.baseline - anchor.baseline) <= geometry.canvas.height * 0.46 {
                let neighbors = ordered.filter { next in
                    let delta = line.baseline - next.baseline
                    return next.reliable && [.body, .formula, .heading].contains(next.kind) &&
                        delta > line.printedHeight * 0.42 &&
                        delta <= max(line.printedHeight, next.printedHeight) * 2.8 &&
                        abs(next.box.minX - line.box.minX) <= line.printedHeight * 0.8 &&
                        next.box.maxX <= line.box.maxX + line.printedHeight * 0.8
                }.sorted { $0.baseline > $1.baseline }.prefix(2)
                let original = [line] + neighbors
                let text = original.map(\.text).joined(separator: " ").precomposedStringWithCompatibilityMapping
                if Self.matches(expression, text), Self.matches(expression, line.text.precomposedStringWithCompatibilityMapping) ||
                    line.text.contains(symbol) {
                    matches.append((abs(line.baseline - anchor.baseline), original))
                }
            }
            if let best = matches.min(by: { $0.distance < $1.distance }) {
                var definitionRows = best.rows
                // A wrapped definition can span several typeset lines. Finish
                // the original sentence in its verified block, retaining dimensions
                // and qualifiers after the first matching variable name.
                if let last = definitionRows.last, let block = last.position.blockIndex {
                    let continuation = lane.filter { $0.position.blockIndex == block && $0.baseline < last.baseline }
                        .sorted { $0.baseline > $1.baseline }
                    for row in continuation {
                        guard let previous = definitionRows.last, !ResearchPDFLayout.endsCaptionSentence(previous.text),
                              previous.baseline - row.baseline <= max(previous.printedHeight, row.printedHeight) * 2.1,
                              definitionRows.reduce(0, { $0 + $1.text.utf16.count }) + row.text.utf16.count <= 1400
                        else { break }
                        definitionRows.append(row)
                    }
                }
                for line in definitionRows where !collected.contains(where: { $0.position == line.position }) {
                    collected.append(line)
                }
            } else {
                let matched = adjacent.filter { paragraph in
                    let text = paragraph.map(\.text).joined(separator: " ").precomposedStringWithCompatibilityMapping
                    return text.utf16.count <= 1_600 && Self.matches(expression, text)
                }
                if matched.count == 1 {
                    collected += matched[0].filter { line in !collected.contains { $0.position == line.position } }
                } else {
                    missing.append(symbol)
                }
            }
        }
        return (collected, missing, displays, corrections)
    }

    /// A definition can be a separate numbered display introduced in the
    /// preceding column. Keep that equation as visual evidence: flattening
    /// a cases environment into prose would lose the conditions on each row.
    private func definitionDisplay(for symbol: String, in rows: [Line], excluding target: ResearchPDFObjectID)
        -> (cue: [Line], id: ResearchPDFObjectID)? {
        let name = NSRegularExpression.escapedPattern(for: symbol)
        let pattern = #"(?i:(?:\bdefine|\bdenote|定义|记))\s*"# + name + #"\s*[:：]\s*$"#
        let cues = rows.filter { $0.reliable && $0.kind == .body && $0.text.range(of: pattern, options: .regularExpression) != nil }
        guard cues.count == 1, let cue = cues.first else { return nil }
        let below = rows.filter {
            $0.reliable && $0.position.column == cue.position.column &&
                $0.baseline < cue.baseline && cue.baseline - $0.baseline < cue.printedHeight * 5
        }.sorted { $0.baseline > $1.baseline }
        let display = below.prefix { !$0.isProse && $0.kind != .caption && $0.kind != .heading }
        guard display.contains(where: { $0.text.range(of: #"^\s*"# + name + #"\s*[:=≔]"#, options: .regularExpression) != nil }) else { return nil }
        let tags = Set(display.compactMap { Self.tag(Self.equationNumber, $0.text)?.0 })
        guard tags.count == 1, let number = tags.first else { return nil }
        let id = ResearchPDFObjectID(kind: .equation, number: number)
        guard id != target else { return nil }
        // The definition cue may start mid-sentence after “ground-truth
        // label” or another essential condition. Follow its own text block.
        var introduction = [cue]
        if let block = cue.position.blockIndex {
            let previous = rows.filter { $0.position.blockIndex == block && $0.baseline > cue.baseline }
                .sorted { $0.baseline < $1.baseline }
            for row in previous {
                guard row.reliable, row.kind == .body, !ResearchPDFLayout.endsCaptionSentence(row.text),
                      introduction.reduce(0, { $0 + $1.text.utf16.count }) + row.text.utf16.count <= 700
                else { break }
                introduction.insert(row, at: 0)
            }
        }
        return (introduction, id)
    }

    func resolve(_ request: ResearchPDFObjectID, within pages: ClosedRange<Int>?,
                 reference: ResearchFileReference, document: inout PDFDocument?) throws -> Object {
        let existing = objects[request] ?? request.parentFigure.flatMap { objects[$0] } ?? []
        var matching = existing.filter { pages?.contains($0.page) ?? true }
        if matching.isEmpty, request.kind == .equation {
            let candidates = (equationPages[request.number] ?? []).filter { pages?.contains($0.number) ?? true }
            if candidates.count > 6 {
                let locations = ResearchPDFIndex.pageList(candidates.map(\.number))
                throw ResearchMaterialError.message("\(request.label) 的文本编号有多个可能页（\(locations)），请指定文件页进行局部核验。")
            }
            for page in candidates {
                if let cached = recovered.object(forKey: recoveryKey(request, page.number)) {
                    matching += cached.values
                    continue
                }
                if document == nil { document = reference.verifiedPDF().flatMap { PDFDocument(data: $0.1) } }
                guard let original = document else { throw ResearchMaterialError.message("附件已变更或无法重新打开。") }
                matching += try recover(request, on: page, document: original)
            }
        }
        guard matching.count <= 1 else {
            let locations = ResearchPDFIndex.pageList(matching.map(\.page))
            throw ResearchMaterialError.message("\(request.label) 有多个候选位置（文件第 \(locations) 页），请补充页码。")
        }
        guard var result = matching.first else {
            throw ResearchMaterialError.message("完整论文中未定位到可核对的 \(request.label) 本体，请核对编号或 PDF 中的页码。")
        }
        if result.id.kind == .figure, let page = graphicPages[result.page] {
            let key = recoveryKey(result.id, result.page)
            if let cached = recovered.object(forKey: key)?.values.first { return cached }
            if document == nil { document = reference.verifiedPDF().flatMap { PDFDocument(data: $0.1) } }
            guard let native = document?.page(at: result.page - 1) else {
                throw ResearchMaterialError.message("附件已变更或无法重新打开。")
            }
            let full = try Self.figure(result, on: page, previous: graphicPages[result.page - 1],
                                       next: graphicPages[result.page + 1], native: native)
            recovered.setObject(Recovered([full]), forKey: key)
            return full
        }
        if result.id.kind == .equation, let page = graphicPages[result.page] {
            let key = "context:\(recoveryKey(result.id, result.page))" as NSString
            if let existing = recovered.object(forKey: key)?.values.first { return existing }
            result.supporting = equationContext(for: result, on: page)
            if result.exactEquation == nil, result.visual != nil, let geometry = page.geometry {
                if document == nil { document = reference.verifiedPDF().flatMap { PDFDocument(data: $0.1) } }
                guard let native = document?.page(at: page.number - 1) else {
                    throw ResearchMaterialError.message("附件已变更或无法重新打开。")
                }
                result.visual = try Self.checkedEquationBoundary(result, in: native, on: page, geometry: geometry)
                if let visual = result.visual {
                    let crop = visual.bounds.applying(geometry.display)
                    result.primary = result.primary.filter { crop.contains(CGPoint(x: $0.box.midX, y: $0.baseline)) }
                }
                if let definition = Self.adjacentDefinitionImage(for: result, page: page, geometry: geometry) {
                    result.supportingVisual = definition
                }
            }
            recovered.setObject(Recovered([result]), forKey: key)
        }
        return result
    }

    func image(at position: ResearchPDFSourcePosition, reference: ResearchFileReference,
               document: inout PDFDocument?, graphic: Bool) throws -> Data? {
        let key = "\(position.page):\(position.bounds):\(graphic)" as NSString
        if let existing = images.object(forKey: key) { return existing as Data }
        try Task.checkCancellation()
        if document == nil { document = reference.verifiedPDF().flatMap { PDFDocument(data: $0.1) } }
        guard let page = document?.page(at: position.page - 1), let original = page.pageRef else { return nil }
        let geometry = ResearchPDFLayout.Geometry(page)
        let box = position.bounds.applying(geometry.display).intersection(geometry.canvas)
        let scale = min(graphic ? 2.8 : 4.5, 1480 / box.width, 1150 / box.height)
        guard !box.isEmpty, scale.isFinite else { return nil }
        let width = Int(ceil(box.width * scale)), height = Int(ceil(box.height * scale))
        guard width >= 8, height >= 8 else { return nil }
        let pixels: CGImage?
        if ResearchPDFCropRenderer.requiresAlternate(original) {
            guard let (_, bytes) = reference.verifiedPDF() else {
                throw ResearchMaterialError.message("PDF 已变化或无法访问，未生成原页裁图。")
            }
            pixels = try ResearchPDFCropRenderer.alternateImage(bytes: bytes, pageIndex: position.page - 1,
                canvas: geometry.canvas, display: geometry.display, crop: box, scale: scale)
        } else {
            guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            canvas.setFillColor(gray: 1, alpha: 1)
            canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
            canvas.scaleBy(x: scale, y: scale)
            canvas.translateBy(x: -box.minX, y: -box.minY)
            canvas.concatenate(geometry.display)
            canvas.drawPDFPage(original)
            pixels = canvas.makeImage()
        }
        try Task.checkCancellation()
        guard let pixels, let data = CFDataCreateMutable(nil, 0),
              let writer = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, pixels, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(writer), CFDataGetLength(data) <= 700_000 else { return nil }
        let out = data as Data
        images.setObject(out as NSData, forKey: key, cost: out.count)
        return out
    }
}

extension ResearchPDFIndex {
    /// The adjacent actual equation in physical order, with no arithmetic assumption about printed tags.
    func previousEquation(before id: ResearchPDFObjectID) -> ResearchPDFObjectID? {
        guard id.kind == .equation,
              let group = objects.objects[id], group.count == 1, let target = group.first else { return nil }
        let ordered = objects.objects.values.flatMap { $0 }.filter { $0.id.kind == .equation }
            .sorted { left, right in
                if left.page != right.page { return left.page < right.page }
                let a = left.primary[0], b = right.primary[0]
                if a.position.blockIndex != b.position.blockIndex {
                    return (a.position.blockIndex ?? 0) < (b.position.blockIndex ?? 0)
                }
                return (a.position.blockRange?.location ?? 0) < (b.position.blockRange?.location ?? 0)
            }
        guard let location = ordered.firstIndex(where: { $0.id == target.id }), location > 0 else { return nil }
        let preceding = ordered[location - 1].id
        return objects.objects[preceding]?.count == 1 ? preceding : nil
    }

    func objectEvidence(_ ids: [ResearchPDFObjectID], includeImages: Bool = false,
                        question: String = "", timing: ResearchTurnTiming? = nil,
                        parsed: ResearchPDFRequest? = nil) throws -> ResearchPDFObjectEvidence {
        guard !ids.isEmpty, ids.count <= 3 else {
            throw ResearchMaterialError.message("一次请指定一到三个文档对象。")
        }
        let request = parsed ?? ResearchPDFRequest(question)
        let page = ResearchPDFAddress.captures(#"(?:第\s*(\d+)\s*页|\bpage\s+(\d+)\b)"#, in: question)
            .flatMap { fields in fields.dropFirst().compactMap { Int($0) }.first }
        let captionOnly = request.output.captionOnly
        var primary: [ResearchPDFSourcePosition] = []
        var auxiliary: [ResearchPDFSourcePosition] = []
        var sourceGroups: [ResearchPDFSourceGroup] = []
        var body = ""
        var excerpts: [ResearchVerifiedExcerpt] = []
        let evidenceTitle = metadata.title ?? title
        let doi = ResearchVerifiedExcerpt.doi(from: metadata.link)
        var images: [Data] = []
        var document: PDFDocument?
        var needsVisual = false
        var attemptedCrop = false
        var evidenceChecks: [ResearchPDFEvidenceCheck] = []
        var resolvedObjects: [ResearchPDFObjectIndex.Object] = []
        var verifiedGlyphBytes: Data?
        func verify(_ kind: ResearchPDFEvidenceCheck.Kind, _ target: String,
                    _ status: ResearchPDFEvidenceCheck.Status) {
            evidenceChecks.append(.init(kind: kind, target: target, status: status))
        }
        @discardableResult
        func append(_ text: String) -> Int {
            if !body.isEmpty { body += "\n" }
            let offset = body.utf16.count
            body += text
            return offset
        }
        func appendOriginal(_ lines: [ResearchPDFObjectIndex.Line], kind: ResearchVerifiedExcerpt.Kind, partial: Bool = false) {
            for line in lines {
                let location = append(line.text)
                let length = line.text.utf16.count
                guard length > 0, line.reliable else { continue }
                let page = line.position.page
                if let last = excerpts.last, last.kind == kind, last.page == page,
                   NSMaxRange(last.range) == location - 1, last.partial == partial {
                    excerpts[excerpts.count - 1].range.length += length + 1
                } else {
                    excerpts.append(.init(kind: kind, range: NSRange(location: location, length: length),
                                          title: evidenceTitle, page: page, doi: doi, partial: partial))
                }
            }
        }
        defer { if attemptedCrop { timing?.mark(.cropCompleted) } }
        for id in ids {
            try Task.checkCancellation()
            let primaryStart = primary.count
            var visualContext: [ResearchPDFSourceGroup] = []
            timing?.mark(.objectLookupStarted)
            let object = try objects.resolve(id, within: page.map { $0...$0 }, reference: reference, document: &document)
            timing?.mark(.objectLookupCompleted)
            resolvedObjects.append(object)
            verify(.target, id.label, .verified)
            let requested = id.kind == .equation ? request.requestedSymbols : []
            let glyphPage: ResearchPDFGlyphPage?
            if !requested.isEmpty, let geometry = pages[object.page - 1].geometry {
                timing?.mark(.glyphStarted)
                glyphPage = try ResearchPDFCropRenderer.glyphPage(fingerprint: reference.fingerprint,
                    pageIndex: object.page - 1, canvas: geometry.canvas, display: geometry.display) {
                    if let verifiedGlyphBytes { return verifiedGlyphBytes }
                    let bytes = reference.verifiedPDF()?.1
                    verifiedGlyphBytes = bytes
                    return bytes
                }
                timing?.mark(.glyphCompleted)
            } else { glyphPage = nil }
            var definitions = objects.requestedDefinitions(for: object, request: request, glyphPage: glyphPage)
            let heading = "【\(id.label) · PDF 文件第 \(object.page) 页】"
            let isPanel = object.id != id
            let wantsGraphic = id.kind == .table || id.kind == .figure && (!captionOnly || isPanel)
            let wantsCaptionImage = id.kind == .figure && (captionOnly || object.captionNeedsVisual)
            let needsImage = wantsGraphic || object.captionNeedsVisual || id.kind == .equation && object.exactEquation == nil
            needsVisual = needsVisual || needsImage
            if includeImages,
               (object.visual != nil && (wantsGraphic || id.kind == .equation)) ||
                    wantsCaptionImage && object.captionVisual != nil {
                timing?.mark(.cropStarted)
                attemptedCrop = true
            }
            let rendered: Data?
            // For mathematics, a small authoritative crop also preserves typographic distinctions
            // (e.g. ordinary and calligraphic symbols) lost by a PDF's native encoding.
            if includeImages, wantsGraphic || id.kind == .equation, let visual = object.visual {
                rendered = try objects.image(at: visual, reference: reference, document: &document, graphic: id.kind != .equation)
            } else {
                rendered = nil
            }
            if let rendered { images.append(rendered) }
            let captionImage: Data?
            if includeImages, wantsCaptionImage, let visual = object.captionVisual {
                captionImage = try objects.image(at: visual, reference: reference, document: &document, graphic: false)
            } else {
                captionImage = nil
            }
            if let captionImage { images.append(captionImage) }
            var definitionImage = false
            if rendered != nil, ids.count == 1, let original = object.supportingVisual,
               let definition = try objects.image(at: original, reference: reference, document: &document, graphic: false) {
                let offset = auxiliary.count
                images.append(definition)
                auxiliary.append(original)
                visualContext.append(.init(role: .context, title: id.label + " · 邻近定义原图",
                                           range: offset..<(offset + 1)))
                definitionImage = true
            }

            if includeImages, id.kind == .equation {
                for binding in definitions.displays where images.count < 4 {
                    try Task.checkCancellation()
                    guard let display = try? objects.resolve(binding.id, within: object.page...object.page,
                                                            reference: reference, document: &document),
                          let original = display.visual,
                          let data = try objects.image(at: original, reference: reference, document: &document, graphic: false)
                    else { continue }
                    if !auxiliary.contains(original) {
                        let offset = auxiliary.count
                        auxiliary.append(original)
                        images.append(data)
                        visualContext.append(.init(role: .context,
                            title: "\(binding.id.label) · \(binding.symbol) 的定义", range: offset..<(offset + 1)))
                    }
                    definitions.lines.append(contentsOf: binding.cue)
                    definitions.missing.removeAll { $0 == binding.symbol }
                    definitionImage = true
                }
            }

            // A native figure crop is displayed before its caption; typography-heavy formulas use
            // their own original region, including the number and all graphical strokes.
            if let visual = object.visual, id.kind == .equation || rendered != nil {
                primary.append(visual)
            }
            let captionStart = primary.count
            if id.kind == .figure, captionImage != nil, let visual = object.captionVisual {
                primary.append(visual)
            }
            let sourceLines = id.kind == .figure ? object.caption ?? object.primary : object.primary
            primary.append(contentsOf: sourceLines.map(\.position))
            let targetEnd = id.kind == .figure ? captionStart : primary.count
            if primaryStart < targetEnd {
                let title = id.kind == .figure ? object.id.label + " · 原图" : id.label
                sourceGroups.append(.init(role: .object, title: title, range: primaryStart..<targetEnd))
            }
            if id.kind == .figure, captionStart < primary.count {
                let title = object.id.label + (object.captionBoundaryVerified ? " · 图注" : " · 已取得的图注")
                sourceGroups.append(.init(role: .caption, title: title, range: captionStart..<primary.count))
            }
            sourceGroups.append(contentsOf: visualContext)
            let proseStart = auxiliary.count
            var supporting: [ResearchPDFObjectIndex.Line] = []
            let context = object.supporting.map { line in
                definitions.corrections.first { $0.original == line.position }?.line ?? line
            }
            for line in context + definitions.lines where (!captionOnly || id.kind != .figure) &&
                !auxiliary.contains(line.position) && !primary.contains(line.position) {
                supporting.append(line)
                auxiliary.append(line.position)
            }
            if proseStart < auxiliary.count {
                let title = id.label + (id.kind == .equation ? " · 变量说明与上下文" : " · 辅助依据")
                sourceGroups.append(.init(role: .context, title: title, range: proseStart..<auxiliary.count))
            }

            if !body.isEmpty { body += "\n" }
            append(heading)
            if id.kind == .equation {
                verify(.content, id.label + " 原式", object.exactEquation != nil || rendered != nil ? .verified : .missing)
                if let exact = object.exactEquation {
                    append("已核对原式结构（原生文字采用 PDF 的字符编码）：")
                    let offset = append("\\(\(exact)\\)")
                    if object.primary.contains(where: { $0.reliable && $0.text.range(of: exact, options: .literal) != nil }) {
                        excerpts.append(.init(kind: .body, range: NSRange(location: offset + 2, length: exact.utf16.count),
                                              title: evidenceTitle, page: object.page, doi: doi))
                    }
                    if rendered != nil { append("另有原页局部可核对字形与字体样式。") }
                } else if rendered != nil {
                    append("原页裁图含完整原式主体和编号。")
                } else {
                    append("原式已定位。当前只取得局部字形，无法可靠转写全部上下标、横线及分组。")
                }
                if object.exactEquation == nil && rendered == nil {
                    append("原始字形片段（缺少完整公式）：\n" + object.primary.map(\.text).joined(separator: "\n"))
                }
            } else {
                let caption = object.caption ?? object.primary.filter { $0.kind == .caption || $0.kind == .table }
                let captionStatus: ResearchPDFEvidenceCheck.Status = caption.isEmpty ? .missing :
                    object.captionBoundaryVerified && (!object.captionEncodingUncertain || captionImage != nil) ? .verified : .ambiguous
                verify(.caption, id.label + " 图注", captionStatus)
                append("图表原注：")
                appendOriginal(caption, kind: .caption,
                               partial: !object.captionBoundaryVerified || object.captionEncodingUncertain)
                if wantsGraphic && !object.labels.isEmpty { append("图内原文标签：\n" + object.labels.joined(separator: "\n")) }
                if !object.captionBoundaryVerified {
                    append("本机未能核实整段图注边界。")
                }
                if object.captionEncodingUncertain {
                    append("图注的 PDF 文字编码可能缺失运算符。请按原页裁图核对这些符号。")
                }
                if captionImage != nil {
                    append("另附可核对上下标和排版的图注原页局部。")
                } else if object.captionNeedsVisual {
                    append("图注文字层可能无法表达符号位置。当前没有图注裁图。")
                }
                if rendered != nil {
                    append(isPanel ? "附原图供定位指定子图。" : "附图表原页局部裁图。")
                } else if wantsGraphic {
                    append("图表区域内的视觉内容尚未以可靠形式提供。")
                }
            }
            if needsImage {
                let visualProvided = (!wantsGraphic || rendered != nil) &&
                    (!object.captionNeedsVisual || captionImage != nil) &&
                    (id.kind != .equation || object.exactEquation != nil || rendered != nil)
                let visualStatus: ResearchPDFEvidenceCheck.Status = wantsGraphic && object.visualBoundaryUncertain ?
                    .ambiguous : visualProvided ? .verified : .missing
                verify(.visual, id.label + " 原页图像", visualStatus)
                if wantsGraphic && object.visualBoundaryUncertain {
                    append("原图边缘曾出现跨界笔画，尚不能确认全部子图和标签均在裁图内。")
                }
            }
            let newPositions = primary[primaryStart...]
            let validPositions = !newPositions.isEmpty && newPositions.allSatisfy { position in
                let rect = position.bounds
                return position.page == object.page && !rect.isEmpty && !rect.isNull && !rect.isInfinite &&
                    [rect.minX, rect.maxX, rect.minY, rect.maxY].allSatisfy(\.isFinite)
            }
            verify(.location, id.label + " 原页位置", validPositions ? .verified : .missing)
            for symbol in request.symbolRequirements where id.kind == .equation {
                verify(.definition, id.label + " 中 " + symbol.printed + " 的定义",
                       definitions.missing.contains(symbol.name) ? .missing : .verified)
                // Validate the author definition as requested even if the symbol
                // describes dimensions or context outside the numbered display.
                if let glyphPage, let visual = object.visual,
                   glyphPage.containsSymbol(symbol.name, within: visual.bounds) {
                    verify(.content, id.label + " 中的原页字形 " + symbol.printed, .verified)
                }
            }
            if definitionImage { append("另附原页变量定义裁图。") }
            if !supporting.isEmpty {
                let contextualLabel = id.kind == .figure ? "辅助依据（正文中的直接引用）" : "辅助依据（公式附近原文）"
                append(contextualLabel + "：")
                appendOriginal(supporting, kind: .context)
            }
            if !definitions.missing.isEmpty {
                let names = definitions.missing.joined(separator: "、")
                if definitionImage {
                    append("这些符号的定义没有可靠的文字转写：\(names)。请核对所附原页定义区，不要根据文字残片补齐。")
                } else {
                    append("已在原页定位公式；没有核实这些符号的定义：\(names)。")
                }
            }
        }
        if ids.count > 1, request.requiresObjectRelationship {
            var recorded = false
            if let relation = try supportingObjectRelation(ids, near: primary.map(\.page)) {
                let positions = (relation.pdfPositions ?? []).filter { !primary.contains($0) && !auxiliary.contains($0) }
                if !positions.isEmpty && body.utf16.count + relation.text.utf16.count + 30 <= ResearchMaterial.maximumLength {
                    recorded = true
                    let start = auxiliary.count
                    auxiliary.append(contentsOf: positions)
                    sourceGroups.append(.init(role: .context, title: "对象的共同正文依据", range: start..<auxiliary.count))
                    append("【共同正文依据】以下原文同段引用所问对象。")
                    let offset = append(relation.text)
                    excerpts += (relation.verifiedExcerpts ?? []).map { $0.shifted(by: offset) }
                } else if positions.isEmpty, relation.pdfPositions?.isEmpty == false,
                          body.utf16.count + relation.text.utf16.count + 30 <= ResearchMaterial.maximumLength {
                    recorded = true
                    if !body.contains(relation.text) {
                        append("【共同正文依据】")
                        let offset = append(relation.text)
                        excerpts += (relation.verifiedExcerpts ?? []).map { $0.shifted(by: offset) }
                    }
                }
            }
            if !recorded {
                let derivation = objects.derivationBetween(resolvedObjects)
                let newEvidence = derivation.filter { !auxiliary.contains($0.position) && !primary.contains($0.position) }
                if !derivation.isEmpty && body.utf16.count + newEvidence.reduce(0, { $0 + $1.text.utf16.count + 1 }) + 45 <= ResearchMaterial.maximumLength {
                    recorded = true
                    if !newEvidence.isEmpty {
                        let start = auxiliary.count
                        auxiliary += newEvidence.map(\.position)
                        sourceGroups.append(.init(role: .context, title: "两式之间的原文推导", range: start..<auxiliary.count))
                        append("【两式之间的原文推导】")
                        appendOriginal(newEvidence, kind: .context)
                    }
                    append("上述证据含有两条原式之间引用前式的正文。")
                }
            }
            if !recorded {
                append("已分别定位目标。未找到能核对的同段原文同时引用这些对象，请区分论文陈述与分析推断。")
            }
            verify(.relationship, "目标之间的共同正文依据", recorded ? .verified : .missing)
        }
        for target in request.objects where !ids.contains(target) {
            verify(.target, target.label, .missing)
            append("本轮未能核对明确要求的目标 \(target.label)。")
        }
        let hasGaps = evidenceChecks.contains { $0.status != .verified }
        timing?.mark(.coverageChecked)
        let label = ids.map(\.label).joined(separator: "、")
        let pageList = Self.pageList(primary.map(\.page))
        let scope = "文档对象 · \(label) · 文件页 \(pageList)" + (images.isEmpty ? "" : " · 附原页局部裁图") +
            (hasGaps ? " · 部分证据未核实" : "")
        let text = body
        guard images.count <= 4 else {
            throw ResearchMaterialError.message("这些图表和图注的原页裁图超过单次上限，请分次提问，保留每个目标的完整原图。")
        }
        guard text.utf16.count <= ResearchMaterial.maximumLength else {
            throw ResearchMaterialError.message("目标对象和辅助文字合计过长，可将请求分开。")
        }
        var material = ResearchMaterial(source: "PDF 文档对象", title: title, text: text, scope: scope,
            fileReference: reference, pdfPages: pageList)
        material.verifiedExcerpts = excerpts.isEmpty ? nil : excerpts
        material.objectLabels = ids.map(\.label)
        material.pdfPositions = primary
        material.sourceGroups = sourceGroups
        material.evidenceChecks = evidenceChecks
        if !auxiliary.isEmpty {
            material.backgroundPositions = auxiliary
            material.backgroundPages = Self.pageList(auxiliary.map(\.page))
            material.backgroundFile = reference
        }
        return ResearchPDFObjectEvidence(material: material, images: images, ids: ids, needsVisual: needsVisual)
    }
}
