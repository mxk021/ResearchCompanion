import Foundation

/// Reflows confidently continued prose in the preview while keeping a map to the captured text.
struct SelectionPreviewText: Sendable {
    private struct Replacement: Sendable {
        let source: NSRange
        let displayOffset: Int
        let displayLength: Int
    }

    private static let structuralPrefix = try! NSRegularExpression(
        pattern: #"^(?:[#>•▪]|[+–—-]\s|\d+(?:\.\d+)*[.)、]\s|[（(]\d+[）)]|\p{L}{1,4}\([^)]{1,36}\)(?:\s*\(\d+\))?\s*$)"#
    )
    private static let sentenceBoundary = ".!?;:。！？；：…"
    private static let closingPunctuation = "\"'”’」』）》】)]}"

    let displayed: String
    private let original: String
    private let replacements: [Replacement]

    init(_ text: String) {
        self.init(original: text, formatted: Self.reflow(text, cancelled: { false }) ?? (text, []))
    }

    static func prepare(_ text: String) -> Self? {
        guard let formatted = reflow(text, cancelled: { Task.isCancelled }) else { return nil }
        return Self(original: text, formatted: formatted)
    }

    private init(original: String, formatted: (String, [Replacement])) {
        self.original = original
        (displayed, replacements) = formatted
    }

    private static func reflow(_ text: String, cancelled: () -> Bool) -> (String, [Replacement])? {
        guard !cancelled() else { return nil }
        let utf16 = Array(text.utf16)
        var protectedUntil: String?
        func isProtected(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = protectedUntil {
                if trimmed.contains(end) { protectedUntil = nil }
                return true
            }
            for (opening, ending) in [("```", "```"), ("~~~", "~~~"), ("$$", "$$"), ("\\[", "\\]")] where trimmed.hasPrefix(opening) {
                if !trimmed.dropFirst(opening.count).contains(ending) { protectedUntil = ending }
                return true
            }
            if let opening = trimmed.range(of: "\\begin{"), let close = trimmed[opening.upperBound...].firstIndex(of: "}") {
                let ending = "\\end{" + trimmed[opening.upperBound...close]
                if !trimmed[close...].contains(ending) { protectedUntil = ending }
                return true
            }
            return line.first?.isWhitespace != false || line.contains("\t") || line.unicodeScalars.contains(where: {
                switch $0.value {
                case 36, 43, 60...62, 92, 94, 95, 124, 126: true  // $, +, <=>, backslash, ^, _, |, ~
                case 0..<128: false
                default: $0.properties.generalCategory == .mathSymbol
                }
            }) || Self.structuralPrefix.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
        }

        // Use the same UTF-16 line boundaries as NSString.getLineStart,
        // but advance a single cursor rather than repeatedly bridging ranges.
        func terminatesLine(_ codeUnit: UInt16) -> Bool {
            switch codeUnit {
            case 0x0a, 0x0d, 0x85, 0x2028, 0x2029: true
            default: false
            }
        }
        var display = ""
        var folds: [Replacement] = []
        var cursor = 0
        var originalStart = 0
        var removedLength = 0
        var previous: (text: String, protected: Bool, lineBreak: NSRange)?
        while cursor < utf16.count {
            guard !cancelled() else { return nil }
            let start = cursor
            while cursor < utf16.count, !terminatesLine(utf16[cursor]) { cursor += 1 }
            let bodyEnd = cursor
            if cursor < utf16.count {
                let terminator = utf16[cursor]
                cursor += 1
                if terminator == 0x0d, cursor < utf16.count, utf16[cursor] == 0x0a { cursor += 1 }
            }
            let line = String(decoding: utf16[start..<bodyEnd], as: UTF16.self)
            let protected = isProtected(line)
            if let previous, !previous.protected, !protected, previous.lineBreak.length > 0,
               [0x0a, 0x0d].contains(utf16[previous.lineBreak.location]),
               let joiner = Self.joiner(previous.text, line) {
                let range = previous.lineBreak
                display += String(decoding: utf16[originalStart..<range.location], as: UTF16.self)
                display += joiner
                folds.append(.init(source: range, displayOffset: range.location - removedLength, displayLength: joiner.utf16.count))
                removedLength += range.length - joiner.utf16.count
                originalStart = NSMaxRange(range)
            }
            previous = (line, protected, NSRange(location: bodyEnd, length: cursor - bodyEnd))
        }
        return (display + String(decoding: utf16[originalStart...], as: UTF16.self), folds)
    }

    private static func joiner(_ preceding: String, _ following: String) -> String? {
        guard let next = following.first, !next.isUppercase,
              let last = preceding.reversed().first(where: { !$0.isWhitespace && !closingPunctuation.contains($0) }),
              !sentenceBoundary.contains(last), !"-‐‑–—".contains(last) else { return nil }
        let cjkContinuation = isCJK(last) && (isCJK(next) || next.isPunctuation)
        guard cjkContinuation ? preceding.prefix(8).count == 8
            : next.isLetter && preceding.split(maxSplits: 2, whereSeparator: \.isWhitespace).count == 3 else { return nil }
        return cjkContinuation || preceding.last?.isWhitespace == true ? "" : " "
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
    }

    func originalText(for range: NSRange) -> String? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= displayed.utf16.count, range.length <= displayed.utf16.count - range.location else { return nil }
        let start = originalOffset(range.location, fromStart: true)
        let end = originalOffset(NSMaxRange(range), fromStart: false)
        return (original as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    private func originalOffset(_ offset: Int, fromStart: Bool) -> Int {
        var shift = 0
        for replacement in replacements {
            if offset == replacement.displayOffset, replacement.displayLength == 0 {
                return fromStart ? NSMaxRange(replacement.source) : replacement.source.location
            }
            if offset < replacement.displayOffset + replacement.displayLength { break }
            shift += replacement.source.length - replacement.displayLength
        }
        return offset + shift
    }
}
