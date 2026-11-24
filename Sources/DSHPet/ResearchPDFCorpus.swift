import Foundation

/// Locations refer to UTF-16 in the verbatim block, never to offsets in a folded string.
struct ResearchPDFSlice {
    let entry: Int
    let range: NSRange
}

struct ResearchPDFCorpus {
    struct Entry {
        let page: Int
        let block: Int
        let text: String
        let narrativeRange: NSRange?
    }

    struct Passage {
        let slice: ResearchPDFSlice
        let terms: [String: Int]
        let count: Int
    }

    let entries: [Entry]
    let passages: [Passage]
    let frequency: [String: Int]
    let narrative: ResearchPDFSearchText
    let narrativeSource: NSString

    init(pages: [ResearchPDFIndex.Page]) throws {
        var raw = ""
        var length = 0
        var entries: [Entry] = []
        var passages: [Passage] = []
        var frequency: [String: Int] = [:]
        for page in pages {
            for (blockIndex, block) in page.blocks.enumerated() where !block.text.isEmpty {
                try Task.checkCancellation()
                guard block.kind != .header, block.kind != .footer else { continue }
                let size = block.text.utf16.count
                // Floating captions, diagram labels and footnotes are independent of the running
                // prose across a page break. Keep them in search, page reads and full-document reads.
                var span: NSRange?
                if !block.detachedCaption && block.kind != .footnote && block.kind != .figureLabel &&
                    block.paragraphRole != .algorithm {
                    if !raw.isEmpty { raw += "\n\n"; length += 2 }
                    span = NSRange(location: length, length: size)
                    raw += block.text
                    length += size
                }
                let id = entries.count
                entries.append(Entry(page: page.number, block: blockIndex, text: block.text, narrativeRange: span))
                var offset = 0
                for part in try ResearchPDFIndex.split(block.text, limit: 1_500) {
                    let n = part.utf16.count
                    let words = ResearchPDFIndex.termCounts(part)
                    for term in words.keys { frequency[term, default: 0] += 1 }
                    passages.append(Passage(slice: ResearchPDFSlice(entry: id, range: NSRange(location: offset, length: n)),
                                            terms: words, count: words.values.reduce(0, +)))
                    offset += n
                }
            }
        }
        self.entries = entries
        self.passages = passages
        self.frequency = frequency
        self.narrative = try ResearchPDFSearchText(raw)
        self.narrativeSource = raw as NSString
    }

    func full(_ entry: Int) -> ResearchPDFSlice {
        ResearchPDFSlice(entry: entry, range: NSRange(location: 0, length: entries[entry].text.utf16.count))
    }

    func slices(intersecting span: NSRange) -> [ResearchPDFSlice] {
        entries.enumerated().compactMap { id, entry in
            guard let source = entry.narrativeRange else { return nil }
            let overlap = NSIntersectionRange(span, source)
            guard overlap.length > 0 else { return nil }
            return ResearchPDFSlice(entry: id, range: NSRange(location: overlap.location - source.location, length: overlap.length))
        }
    }
}

/// Page and column boundaries are synthetic newlines. Keep a special token for a
/// hyphen at an actual line wrap. A query may spell that word joined or hyphenated.
struct ResearchPDFSearchText {
    private static let wrappedHyphen: Character = "\u{E000}"
    private let folded: String
    private let starts: [Int]
    private let ends: [Int]

    init(_ raw: String) throws {
        var folded = ""
        var starts: [Int] = [], ends: [Int] = []
        var index = raw.startIndex
        var location = 0
        func append(_ text: String, end: Int) {
            folded += text
            let n = text.utf16.count
            starts.append(contentsOf: repeatElement(location, count: n))
            ends.append(contentsOf: repeatElement(end, count: n))
        }
        while index < raw.endIndex {
            if location.isMultiple(of: 8192) { try Task.checkCancellation() }
            let ch = raw[index]
            var next = raw.index(after: index)
            var end = location + ch.utf16.count
            if ch == "\u{00AD}" || ch == "\u{200B}" {
                // A discretionary hyphen plus a physical line break is one word.
                if ch == "\u{00AD}" {
                    let trailing = raw[next...].prefix(while: \.isWhitespace)
                    if trailing.contains(where: \.isNewline) {
                        next = trailing.endIndex
                        end += trailing.utf16.count
                    }
                }
            } else if ch == Self.wrappedHyphen {
                append("\u{FFFD}", end: end)
            } else if ch.isWhitespace {
                let trailing = raw[next...].prefix(while: \.isWhitespace)
                next = trailing.endIndex
                end += trailing.utf16.count
                append(" ", end: end)
            } else if ch == "−" {
                // Mathematical subtraction is not a hyphenated word break.
                append("-", end: end)
            } else if Self.hyphens.contains(ch) {
                let trailing = raw[next...].prefix(while: \.isWhitespace)
                if trailing.contains(where: \.isNewline), trailing.endIndex < raw.endIndex,
                   raw[trailing.endIndex].isLetter, index > raw.startIndex, raw[raw.index(before: index)].isLetter {
                    next = trailing.endIndex
                    end += trailing.utf16.count
                    append(String(Self.wrappedHyphen), end: end)
                } else {
                    append("-", end: end)
                }
            } else if "‘’".contains(ch) {
                append("'", end: end)
            } else if "“”".contains(ch) {
                append("\"", end: end)
            } else if let byte = ch.asciiValue {
                append(String(UnicodeScalar(byte >= 65 && byte <= 90 ? byte + 32 : byte)), end: end)
            } else {
                let compatible = String(ch).precomposedStringWithCompatibilityMapping
                append(compatible.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")), end: end)
            }
            index = next
            location = end
        }
        self.folded = folded
        self.starts = starts
        self.ends = ends
    }

    private static let hyphens: Set<Character> = ["-", "‐", "‑", "﹣", "－", "‒", "–"]

    /// Match only inside the requested source interval. Limit results after applying that
    /// constraint so a repeated header on an earlier page cannot hide a later exact match.
    func occurrences(_ anchor: String, within source: NSRange? = nil, limit: Int = 2,
                     allowOpeningInflection: Bool = false, beforeCitationNumber: Bool = false,
                     allowMathematicalTypography: Bool = false, startsAfterPrintedWrap: Bool = false) throws -> [NSRange] {
        let query = try ResearchPDFSearchText(anchor.trimmingCharacters(in: .whitespacesAndNewlines)).folded
        guard !query.isEmpty, query.utf16.count <= 2_048 else {
            throw ResearchMaterialError.message("请给出非空、可核对的原文短句（每处最多 2048 个字符）。")
        }
        let marker = String(Self.wrappedHyphen)
        var pattern = ""
        var previousLetter = false
        let firstWord = query.prefix { $0.isASCII && $0.isLetter }
        let inflect = allowOpeningInflection && firstWord.count >= 4 &&
            query.split(whereSeparator: \.isWhitespace).count >= 5 && query.dropFirst(firstWord.count).first == " "
        if allowOpeningInflection && !inflect { return [] }
        let characters = Array(query)
        let hasNotation = query.range(of: #"[=+×÷^|]|\b[a-z][(][a-z][)]|[\p{Greek}]\p{L}*[_^]|-\s*(?:log\b|\d)"#,
                                      options: .regularExpression) != nil
        if allowMathematicalTypography && !hasNotation { return [] }
        let operators: Set<Character> = ["=", "+", "-", "×", "÷", "(", ")", "|"]
        for (index, ch) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inflect && index == firstWord.count {
                pattern += "(?:" + marker + ")?(?:ing|ed|es|s)"
            }
            if allowMathematicalTypography {
                if ch == " ", previous.map(operators.contains) == true || next.map(operators.contains) == true {
                    pattern += " ?"
                    previousLetter = false
                    continue
                }
                if (ch == "_" || ch == "^"), let previous, let next, previous.isLetter, next.isLetter || next.isNumber {
                    // A superscript/subscript marker may be present only in the
                    // question. The adjacent printed symbol is still required.
                    pattern += "[\\_\\^]? ?"
                    previousLetter = false
                    continue
                }
            }
            if previousLetter && ch.isLetter { pattern += marker + "?" }
            if allowMathematicalTypography, operators.contains(ch), previous != nil, previous != " " { pattern += " ?" }
            if ch == "-" || ch == Self.wrappedHyphen { pattern += "[-" + marker + "]" + (ch == Self.wrappedHyphen ? "?" : "") }
            else { pattern += NSRegularExpression.escapedPattern(for: String(ch)) }
            if allowMathematicalTypography, operators.contains(ch), next != nil, next != " " { pattern += " ?" }
            previousLetter = ch.isLetter
        }
        // Avoid finding a whole English word inside a longer one. CJK users often
        // quote fragments without word separators.
        if startsAfterPrintedWrap {
            guard query.first?.isLetter == true, query.split(whereSeparator: \.isWhitespace).count >= 4 else { return [] }
            pattern = "(?<=" + marker + ")" + pattern
        } else if query.first?.isASCII == true, query.first?.isLetter == true {
            pattern = "(?<![a-zA-Z0-9" + marker + "])" + pattern
        }
        if beforeCitationNumber {
            guard query.split(whereSeparator: \.isWhitespace).count >= 3,
                  let lastWord = query.split(whereSeparator: \.isWhitespace).last,
                  lastWord.count >= 3, lastWord.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
            pattern += #"(?=[0-9]{1,3}[.,;:])"#
        } else if query.last?.isASCII == true, query.last?.isLetter == true {
            pattern += "(?![a-zA-Z0-9" + marker + "])"
        }
        let regex = try NSRegularExpression(pattern: "(?=(" + pattern + "))")
        var hits: [NSRange] = []
        func lowerBound(_ location: Int) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = low + (high - low) / 2
                if starts[mid] < location { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let searchRange = source.map { span in
            let lo = lowerBound(span.location)
            return NSRange(location: lo, length: lowerBound(NSMaxRange(span)) - lo)
        } ?? NSRange(location: 0, length: starts.count)
        regex.enumerateMatches(in: folded, options: .withTransparentBounds, range: searchRange) { match, _, stop in
            guard let span = match?.range(at: 1), span.length > 0, NSMaxRange(span) <= NSMaxRange(searchRange) else { return }
            let first = span.location, last = NSMaxRange(span) - 1
            // A ligature/case fold may expand into multiple units. Never return a
            // fraction of a source grapheme as a verified quotation.
            guard first == 0 || starts[first - 1] != starts[first],
                  last + 1 == starts.count || starts[last + 1] != starts[last] else { return }
            hits.append(NSRange(location: starts[first], length: ends[last] - starts[first]))
            if hits.count >= limit { stop.pointee = true }
        }
        return hits
    }
}
