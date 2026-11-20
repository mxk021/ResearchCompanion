import CryptoKit
import Foundation

/// Standalone local check, also usable on a Command Line Tools installation without XCTest.
@main
struct ResearchPDFQueryCheck {
    enum Failure: Error { case assertion(String) }
    static func main() throws {
        // Optional local-only oracle from an independent PDF reader. No PDF or
        // expected private text is part of the public test suite.
        if CommandLine.arguments.count == 4 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let question = CommandLine.arguments[2]
            let expected = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
            let index = try ResearchPDFIndex.read(url, title: url.lastPathComponent) { _ in }
            let chunks = try index.prepare(question)
            let wire = chunks.map { $0.fields["text"] ?? "" }.joined()
            func comparable(_ str: String) -> String {
                str.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
            }
            guard comparable(wire) == comparable(expected) else { throw Failure.assertion("Independent reader and prepared evidence differ") }
            let digest = SHA256.hash(data: Data(wire.utf8)).map { String(format: "%02x", $0) }.joined()
            let locations = chunks.flatMap { $0.pdfPositions ?? [] }
            print("PASS local oracle: \(chunks.count) payload(s), \(wire.utf16.count) UTF-16, \(comparable(wire).count) normalized nonspace characters, SHA-256 \(digest)")
            print("Mapped \(locations.count) lines on physical pages \(ResearchPDFIndex.pageList(locations.map(\.page))); first / last columns \(locations.first?.column ?? 0) / \(locations.last?.column ?? 0)")
            return
        }
        let check = Self()
        try check.testCrossColumnAndCrossPageReturnsExactVerbatimBoundsAndLocations()
        try check.testMissingReversedAmbiguousAndUnreliableNeverFallBackToRanking()
        try check.testCrossPageWordCanBeSearchedWithEitherPrintedSpelling()
        try check.testColumnParagraphAndSectionReadExcludeAdjacentEvidence()
        try check.testPlanReassemblesExactlyAcrossOverBudgetBlock()
        try check.testMultipleEvidenceLocationsAndNoInventedFallback()
        print("PASS exact source, same-height columns, range rejection, Unicode/cross-page words, paragraph/section addressing, multi-location evidence and complete chunks.")
    }

    private func check(_ condition: @autoclosure () throws -> Bool, line: Int = #line) throws {
        guard try condition() else { throw Failure.assertion("Failed query check at line \(line)") }
    }

    private func unwrap<T>(_ value: T?, line: Int = #line) throws -> T {
        guard let value else { throw Failure.assertion("Missing value at line \(line)") }
        return value
    }

    private func rejects<T>(_ attempt: @autoclosure () throws -> T, containing reason: String = "", line: Int = #line) throws {
        do { _ = try attempt() }
        catch {
            try check(reason.isEmpty || error.localizedDescription.contains(reason), line: line)
            return
        }
        throw Failure.assertion("Unexpected retrieval at line \(line)")
    }

    private typealias Page = ResearchPDFIndex.Page
    private func block(_ text: String, column: Int = 0, kind: ResearchPDFBlockKind = .body,
                       reliable: Bool = true, source: Int = 0) -> ResearchPDFBlock {
        var offset = source
        let lines = text.components(separatedBy: "\n").enumerated().map { i, text in
            let rect = CGRect(x: 10 + 200 * column, y: 500 - 15 * i, width: 180, height: 12)
            let range = NSRange(location: offset, length: text.utf16.count)
            offset = NSMaxRange(range) + 1
            return ResearchPDFLine(text: text, bounds: rect, sourceRanges: [range], confidence: reliable ? 1 : 0.3, ocr: false)
        }
        return ResearchPDFBlock(lines: lines, bounds: lines.reduce(.null) { $0.union($1.bounds) }, column: column,
                                kind: kind, reliable: reliable, text: text)
    }

    private func page(_ n: Int, _ blocks: [ResearchPDFBlock], state: ResearchPDFPageState = .native,
                      reliable: Bool = true) -> Page {
        Page(number: n, blocks: blocks, reliableOrder: reliable, state: state)
    }

    private func index(_ pages: [Page]) throws -> ResearchPDFIndex {
        try ResearchPDFIndex(pages: pages, metadata: ResearchPDFMetadata(),
            reference: ResearchFileReference(originalPath: "/synthetic.pdf", bookmark: nil, fingerprint: "synthetic"), title: "synthetic.pdf")
    }

    func testCrossColumnAndCrossPageReturnsExactVerbatimBoundsAndLocations() throws {
        let doc = try index([
            page(1, [block("Do not send. THE diffrac-\ntion to ＲＥＤ begins here.", column: 1, source: 10),
                     block("Right column runs to the page boundary.", column: 2, source: 80),
                     block("Synthetic copyright footnote.", kind: .footnote)]),
            page(2, [block("Running issue title", kind: .header),
                     block("Original formula α² = β, then sentinel near the final grating. Do not send.", column: 1)])
        ])
        let parts = try doc.prepare("翻译从 The diffraction to red 到 sentinel near the final grating 的全部内容。")
        try check(parts.count == 1)
        try check(parts[0].fields["text"] == "THE diffrac-\ntion to ＲＥＤ begins here.\n\nRight column runs to the page boundary.\n\nOriginal formula α² = β, then sentinel near the final grating")
        try check(try doc.prepare("Translate from The diffraction to red to sentinel near the final grating").first?.text == parts[0].text)
        let chinese = try index([page(1, [block("起点采用本文研究内容。其他。")])])
        try check(try chinese.prepare("从起点到研究内容").first?.text == "起点采用本文研究内容")
        try check(parts[0].pdfPages == "1–2")
        try check(parts[0].pdfPositions?.map(\.column) == [1, 1, 2, 1])
        try check(parts[0].pdfPositions?.first?.sourceRange == NSRange(location: 10 + "Do not send. ".utf16.count, length: "THE diffrac-".utf16.count))
        try check(parts[0].pdfPositions?.last?.blockRange?.length == "Original formula α² = β, then sentinel near the final grating".utf16.count)
    }

    func testMissingReversedAmbiguousAndUnreliableNeverFallBackToRanking() throws {
        let valid = page(1, [block("END occurs before START occurs before FINISH.")])
        func rejects(_ pages: [Page], _ query: String, _ why: String) throws {
            let d = try index(pages)
            try self.rejects(try d.prepare(query), containing: why)
        }
        try rejects([valid], "翻译从 START 到 ABSENT 的内容。", "终点未")
        try rejects([valid], "翻译从 START 到 END 的内容。", "之前")
        try rejects([valid], "请翻译从 START 到", "同时给出")
        let quoted = try index([page(1, [block("BEGIN contains an author's quoted phrase. NEXT")])])
        try check(try quoted.prepare("Translate from “BEGIN” to “author's quoted phrase”").first?.text == "BEGIN contains an author's quoted phrase")
        try rejects([valid, page(2, [block("START occurs in a citation.", kind: .reference)])], "从 START 到 FINISH", "至少出现两次")
        try rejects([valid, page(2, [], state: .needsOCR)], "从 START 到 FINISH", "第 2 页")
        try rejects([page(1, [block("START"), block("Uncertain OCR", reliable: false), block("FINISH")], state: .ocr)], "从 START 到 FINISH", "无法可靠")
        try rejects([page(1, [block("START here; FINISH there")], reliable: false)], "从 START 到 FINISH", "无法可靠")
    }

    func testCrossPageWordCanBeSearchedWithEitherPrintedSpelling() throws {
        let doc = try index([page(1, [block("Earlier. Beam current drives multi-")]), page(2, [block("layer ﬁlms with α. NEXT begins.")])])
        for start in ["multilayer films", "multi-layer ﬁlms"] {
            let single = try unwrap(doc.prepare("from “\(start)” through “with α”").first)
            try check(single.text == "multi-\n\nlayer ﬁlms with α")
        }
        try rejects(try doc.prepare("从 layer films 到 with α"))
    }

    func testColumnParagraphAndSectionReadExcludeAdjacentEvidence() throws {
        let doc = try index([page(1, [block("1. Methods", kind: .heading), block("One clean sample.")]),
                             page(2, [block("2. Results", kind: .heading), block("Measured output.")]),
                             page(3, [block("Left parallel text.", column: 1), block("Right first.", column: 2),
                                      block("Right last.", column: 2), block("Figure 1.", column: 2, kind: .caption)])])
        try check(try doc.prepare("第三页右栏最后一段是什么意思？").first?.text == "Right last.")
        try check(try doc.prepare("请翻译方法部分").first?.text == "1. Methods\n\nOne clean sample.")
        try check(try doc.prepare("读第2节").first?.pdfPages == "2–3")
        try rejects(try doc.prepare("第六页右栏"))
        try rejects(try doc.prepare("第3页右栏第5段"))
        try check(try doc.prepare("请翻译从第1页到第3页").first?.pdfPages == "1–3")
    }

    func testPlanReassemblesExactlyAcrossOverBudgetBlock() throws {
        let target = "START " + String(repeating: "Measured α² and near-ﬁeld. ", count: 1_900) + "FINISH"
        let doc = try index([page(1, [block("omit. " + target + ". omit.")])])
        let parts = try doc.prepare("翻译从 START 到 FINISH 的全部内容。")
        try check(parts.count > 1)
        try check(parts.allSatisfy { $0.text.utf16.count <= ResearchMaterial.maximumLength && $0.pdfPositions?.isEmpty == false })
        try check(parts.map(\.text).joined() == target)
    }

    func testMultipleEvidenceLocationsAndNoInventedFallback() throws {
        let doc = try index([page(1, [block("Abstract", kind: .heading), block("Proposed accelerator achieves a tenfold speedup.")]),
                             page(2, [block("Control spectrum and wavelength.")]),
                             page(3, [block("Experimental results", kind: .heading), block("Measured runtime drops by a factor of eight.")])])
        let m = try unwrap(doc.prepare("比较摘要中的加速结果和正文实验结果。").first)
        try check(m.text.contains("tenfold speedup"))
        try check(m.text.contains("factor of eight"))
        try check(!m.text.contains("Control spectrum"))
        try check(m.pdfPages == "1、3")
        try rejects(try doc.prepare("pyroelectric zebras"))
    }
}
