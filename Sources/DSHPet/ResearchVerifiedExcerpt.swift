import Foundation

/// A quotation is a slice of the exact text sent, excluding planning, labels,
/// generated summaries, and visual evidence. Persist offsets beside its digest.
struct ResearchVerifiedExcerpt: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case selection, body, caption, context

        var label: String {
            switch self {
            case .selection: "选区"
            case .body: "文件原文"
            case .caption: "图表原注"
            case .context: "辅助原文"
            }
        }
    }

    let kind: Kind
    var range: NSRange
    let title: String
    var page: Int? = nil
    var doi: String? = nil
    var ocr: Bool? = nil
    var partial: Bool? = nil

    func text(in evidence: String) -> String? {
        guard range.location >= 0, range.length > 0,
              range.location <= evidence.utf16.count,
              range.length <= evidence.utf16.count - range.location,
              let range = Range(range, in: evidence) else { return nil }
        let excerpt = String(evidence[range])
        return excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt
    }

    func shifted(by offset: Int, kind newKind: Kind? = nil) -> Self {
        Self(kind: newKind ?? kind, range: NSRange(location: range.location + offset, length: range.length),
             title: title, page: page, doi: doi, ocr: ocr, partial: partial)
    }

    static func doi(from url: URL?) -> String? {
        guard let url, url.host?.lowercased() == "doi.org",
              url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return validatedDOI(String(url.path.dropFirst()))
    }

    static func validatedDOI(_ text: String?) -> String? {
        guard let text, text.utf16.count <= 255,
              text.range(of: #"^10\.\d{4,9}/[-._;()/:a-z0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return text
    }
}
