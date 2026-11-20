import Foundation
import PDFKit

/// Bibliographic evidence is confined to PDF properties and the first page's front matter.
struct ResearchPDFMetadata: Equatable, Sendable {
    var title: String?
    var authors: [String] = []
    var link: URL?

    var authorDisplay: String? {
        guard let first = authors.first else { return nil }
        return authors.count > 2 ? first + " et al." : authors.joined(separator: "、")
    }

    private struct Row {
        var text: String
        var box: CGRect
    }

    private static func clean(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func rows(on page: PDFPage, limit: Int = 20_000) -> [Row] {
        let count = min(page.numberOfCharacters, limit)
        guard count > 0, let selections = page.selection(for: NSRange(location: 0, length: count))?.selectionsByLine() else { return [] }
        let pieces = selections.compactMap { selection -> Row? in
            let value = clean(selection.string ?? "")
            let box = selection.bounds(for: page)
            guard !value.isEmpty, !box.isEmpty, !box.isInfinite, box.height.isFinite else { return nil }
            return Row(text: value, box: box)
        }.sorted { $0.box.midY > $1.box.midY }

        // PDFKit can return a separate "line" for every superscript or author.
        // Coalesce fragments on the same baseline before interpreting individual names.
        var groups: [[Row]] = []
        for piece in pieces {
            if let first = groups.last?.first,
               abs(first.box.midY - piece.box.midY) < min(first.box.height, piece.box.height) * 0.48 {
                groups[groups.count - 1].append(piece)
            } else { groups.append([piece]) }
        }
        return groups.map { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            return Row(text: ordered.map(\.text).joined(separator: " "), box: ordered.reduce(.null) { $0.union($1.box) })
        }
    }

    private static func isTitle(_ value: String) -> Bool {
        (6...280).contains(value.count) && value.filter(\.isLetter).count >= 5 &&
        !matches(value, #"https?://|www\.|10\.\d{4,9}/|\.(?:docx?|rtf|pdf|tex)$|^\s*(?:abstract|references|bibliography|introduction|supplementary information|untitled|microsoft (?:word|powerpoint)|research article\s*$|article open access|open access\s*$|journal of\b|proceedings of\b|摘要|参考文献|引言|未命名)|\bet al\.|\b(?:vol\.|issn|copyright|published by)\b"#)
    }

    private static func names(_ text: String) -> [String]? {
        let cleaned = text
            .replacingOccurrences(of: #"[\d⁰¹²³⁴⁵⁶⁷⁸⁹]+(?:\s*[,–-]\s*[\d⁰¹²³⁴⁵⁶⁷⁸⁹]+)*|[†‡*✉]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?:\s+(?:and|&)\s+|[;；，、&])"#, with: ",", options: [.regularExpression, .caseInsensitive])
        let values = cleaned.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
        guard (1...150).contains(values.count) else { return nil }
        let forbidden = #"\b(?:university|department|institute|journal|college|faculty|school|anonymous|unknown|editor|administrator|scanner|workstation|user|placeholder|research|article|volume|figure|abstract|laboratory|united states|microsoft|adobe|press|conference)\b|大学|研究所|学院|摘要|作者单位"#
        guard values.allSatisfy({ value in
            let words = value.split(separator: " ")
            let person = value.range(of: #"^[\p{Han}]{2,5}$"#, options: .regularExpression) != nil ||
                ((2...7).contains(words.count) && value.range(of: #"^[\p{L}\p{M}.'’\- ]+$"#, options: .regularExpression) != nil &&
                 words.filter { $0.first?.isUppercase == true }.count >= 2)
            return value.count <= 65 && person && !matches(value, forbidden)
        }) else { return nil }
        return values
    }

    private static func identifier(in rows: [Row], page: PDFPage?, bottom: CGFloat) -> URL? {
        let excluded = #"\b(?:cited|citing|see also|related|supplementary|references)\b|参考文献"#
        let eligible = rows.filter { !matches($0.text, excluded) }
        // A DOI in prose may identify another paper. Accept byline/front-matter
        // identifiers and labeled publication links, never a sentence mentioning one.
        var texts = eligible.map(\.text).filter { line in
            matches(line, #"^(?:(?:digital object identifier|DOI|article (?:link|url)|网址)\s*[:：]?\s*)?(?:https?://|10\.\d{4,9}/)"#)
        }
        if let page {
            texts += page.annotations.compactMap { annotation in
                guard annotation.bounds.midY > bottom, let url = annotation.url,
                      let linkedRow = eligible.first(where: { $0.box.intersects(annotation.bounds) }),
                      linkedRow.text.count <= 180, !linkedRow.text.hasSuffix(".") else { return nil }
                // Header hyperlinks occasionally point to a journal home page or a license.
                return url.absoluteString
            }
        }
        let pattern = #"(?i)\b10\.\d{4,9}/[-._;()/:A-Z0-9]+"#
        let expression = try! NSRegularExpression(pattern: pattern)
        var dois = Set<String>()
        for value in texts {
            let ns = value as NSString
            for match in expression.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
                var doi = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                while doi.last == ")" && doi.filter({ $0 == ")" }).count > doi.filter({ $0 == "(" }).count { doi.removeLast() }
                dois.insert(doi.lowercased())
            }
        }
        if dois.count == 1, let doi = dois.first { return URL(string: "https://doi.org/" + doi) }
        guard dois.isEmpty else { return nil }
        // Only article-specific textual links, distinct from affiliations, licenses or dataset URLs.
        let urls = texts.flatMap { $0.split(whereSeparator: \.isWhitespace) }.compactMap { token -> URL? in
            guard let link = URL(string: String(token).trimmingCharacters(in: CharacterSet(charactersIn: "<>.,;"))),
                  let safe = ResearchSourceLocation.webURL(link),
                  matches(safe.path, #"/(?:articles?|abs|fulltext|papers?)/[^/\s]+"#) else { return nil }
            return safe
        }
        let unique = Set(urls)
        return unique.count == 1 ? unique.first : nil
    }

    static func read(_ document: PDFDocument) -> Self {
        let attributes = document.documentAttributes ?? [:]
        func attribute(_ key: PDFDocumentAttribute) -> String? {
            (attributes[key] as? String).map(clean).flatMap { $0.isEmpty ? nil : $0 }
        }
        let software = [attribute(.creatorAttribute), attribute(.producerAttribute)].compactMap { $0?.lowercased() }
        let declaredTitle = attribute(.titleAttribute).flatMap { isTitle($0) && !software.contains($0.lowercased()) ? $0 : nil }
        let declaredAuthors = attribute(.authorAttribute).flatMap { software.contains($0.lowercased()) ? nil : names($0) }
        guard let page = document.page(at: 0) else { return Self(title: declaredTitle, authors: declaredAuthors ?? []) }
        let box = page.bounds(for: .cropBox)
        let lines = rows(on: page)
        let bodyMarker = #"^(?:abstract|introduction|references|bibliography|[1I]\.?\s+introduction)\b|^(?:摘\s*要|引\s*言|参考文献)"#
        let front = Array(lines.prefix(while: {
            $0.box.midY > box.minY + box.height * 0.52 && !matches($0.text, bodyMarker)
        }))
        let sizes = lines.map(\.box.height).sorted()
        let baseline = sizes.isEmpty ? 12 : sizes[sizes.count / 2]
        // A prominent isolated line near the top can be a running journal header.
        // Require either a verifiable byline below it or corroborating PDF title metadata.
        var runningHeaders = Set<String>()
        if let second = document.page(at: 1) {
            let nextBox = second.bounds(for: .cropBox)
            runningHeaders = Set(rows(on: second, limit: 1_500).filter { $0.box.midY > nextBox.maxY - nextBox.height * 0.13 }
                .map { $0.text.lowercased() })
        }
        let candidates = front.indices.filter {
            let row = front[$0]
            let repeatsInMargin = row.box.midY > box.maxY - box.height * 0.13 && runningHeaders.contains(row.text.lowercased())
            return !repeatsInMargin && isTitle(row.text) && row.box.height >= baseline * 1.22
        }
            .sorted { front[$0].box.height > front[$1].box.height }
        var printedTitle: String?
        var printedAuthors: [String] = []
        for index in candidates {
            var start = index
            var end = index
            let size = front[index].box.height
            func continues(_ a: Row, _ b: Row) -> Bool {
                abs(b.box.height - size) <= size * 0.13 && a.box.minY - b.box.maxY < size * 0.85 &&
                    isTitle(b.text) && isTitle(a.text)
            }
            while start > 0, continues(front[start - 1], front[start]) { start -= 1 }
            while end + 1 < front.count, continues(front[end], front[end + 1]) { end += 1 }
            let title = clean(front[start...end].map(\.text).joined(separator: " "))
            guard isTitle(title) else { continue }
            let rest = front.dropFirst(end + 1)
            var byline: [String] = []
            var previous = front[end].box
            for line in rest.prefix(5) {
                guard previous.minY - line.box.maxY < size * 2, line.box.height < size * 0.87,
                      let parsed = names(line.text) else { break }
                byline.append(contentsOf: parsed)
                previous = line.box
            }
            if !byline.isEmpty || declaredTitle?.caseInsensitiveCompare(title) == .orderedSame {
                printedTitle = title
                printedAuthors = byline
                break
            }
        }
        let title = printedTitle ?? declaredTitle
        let authors = printedAuthors.isEmpty ? (declaredAuthors ?? []) : printedAuthors
        let bottom = front.last?.box.minY ?? box.maxY
        return Self(title: title, authors: authors, link: identifier(in: front, page: page, bottom: bottom))
    }
}
