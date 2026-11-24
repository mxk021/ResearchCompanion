import AppKit
import CoreText
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
        try check.testDocumentObjectIndex()
        try check.testFramedFigureWithFormulaAndCaptionContinuation()
        try check.testSpanningCaptionTerminalLine()
        try check.testRasterTickAndVectorPanelDoNotSplitFigure()
        try check.testNumberedSystemAndRaisedReference()
        try check.testSpatialEquationNumberRecovery()
        try check.testNumberedDisplayOnPageWithDamagedFont()
        try check.testEquationDefinitionsFollowTheReadingLanes()
        try check.testMixedLayoutsUseOnlyTheRequestedRoute()
        try check.testCrossColumnAndCrossPageReturnsExactVerbatimBoundsAndLocations()
        try check.testBodyCitationAtTheTopOfAPageIsNotARunningHeader()
        try check.testMissingReversedAmbiguousAndUnreliableNeverFallBackToRanking()
        try check.testRangeChecksMissingPagesAfterLocatingTheEndpoints()
        try check.testRangeUsesTheLocalMapWithoutSkippingDamagedGlyphs()
        try check.testPairedRangeCandidates()
        try check.testNaturalRangeCommandsAndCorrections()
        try check.testStructuredRequestCoverage()
        try check.testVerifiedRangePlanningAndScopedDuplicates()
        try check.testCrossPageWordCanBeSearchedWithEitherPrintedSpelling()
        try check.testColumnParagraphAndSectionReadExcludeAdjacentEvidence()
        try check.testScopedParagraphCountAndConcepts()
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

    func testRangeChecksMissingPagesAfterLocatingTheEndpoints() throws {
        let doc = try index([
            page(1, [], state: .needsOCR),
            page(2, [block("Earlier. START the requested first part and ends at STOP. Other.")]),
            page(3, [block("It continues here and ends at LATER.")]),
            page(4, [], state: .unreadable),
            page(5, [block("A different ending TAIL, after an unreadable page.")])
        ])
        let question = "从 START 到 STOP 的全部内容"
        let material = try unwrap(doc.prepare(question).first)
        try check(material.text == "START the requested first part and ends at STOP")
        try check(material.pdfPositions?.map(\.page) == [2] && material.scope.contains("范围外文件"))
        try rejects(try doc.prepare("从 START 到 LATER 的全部内容"), containing: "缺少可核对")
        try check(try doc.readRange(start: "START", end: "LATER", withinPages: 2...3).first?.pdfPages == "2–3")
        try rejects(try doc.readPages(1...3), containing: "第 1 页")
        try rejects(try doc.prepare("从 START 到 TAIL 的全部内容"), containing: "第 4 页")
        try rejects(try doc.prepare("从 START 到 MISSING 的全部内容"), containing: "缺少可核对")
        try rejects(try doc.segments(), containing: "无法核验整个文件")
    }

    func testRangeUsesTheLocalMapWithoutSkippingDamagedGlyphs() throws {
        let start = "The specimen passes the initial test"
        let end = "the final record has been verified"
        var first = page(1, [block("Unrelated damaged equation α=\u{0000}."),
                             block(start + " and moves to the observation cell.")], state: .needsOCR)
        first.hasLocalOrderMap = true
        var second = page(2, [block("Follow the observation procedure until " + end + "."),
                              block("The next formula x = \u{0000} comes before the appendix.")], state: .needsOCR)
        second.hasLocalOrderMap = true
        let doc = try index([first, second, page(3, [], state: .needsOCR)])
        let result = try unwrap(doc.readRange(start: start, end: end).first)
        try check(result.pdfPages == "1–2" && result.text.contains("observation procedure"))
        try check(result.scope.contains("范围外文件") && !result.text.contains("damaged"))
        try rejects(try doc.readRange(start: start, end: "before the appendix", withinPages: 1...2), containing: "原始字形")
        try rejects(try doc.segments(), containing: "无法核验整个文件")
    }

    func testBodyCitationAtTheTopOfAPageIsNotARunningHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-margin-citation-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &paper, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        func line(_ text: String, y: CGFloat) {
            let value = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
            canvas.textPosition = CGPoint(x: 45, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(value), canvas)
        }
        for lines in [
            [("Hale et al. – Journal of Materials", 766.0), ("The START protocol continues across the page", 125.0),
             ("*Both authors contributed equally to this work.", 108.0),
             ("Present affiliation: Synthetic Laboratory", 87.0),
             ("Proceedings of the Synthetic Meeting, pages 12–13", 51.0), ("Published by Synthetic Press", 32.0)],
            [("Hale et al. – Journal of Materials", 766.0), ("following the method in Reed et al., with independent controls.", 724.0),
             ("The final filter is applied at STOP. This sentence continues.", 710.0)]
        ] {
            canvas.beginPDFPage(nil)
            for (text, y) in lines { line(text, y: y) }
            canvas.endPDFPage()
        }
        canvas.closePDF()
        let index = try ResearchPDFIndex.read(url, title: "Margin citation") { _ in }
        try check(index.pages.allSatisfy { $0.blocks.first?.kind == .header })
        let output = try unwrap(index.readRange(start: "START", end: "STOP", withinPages: 1...2).first)
        try check(output.text.contains("following the method in Reed et al., with independent controls."))
        try check(!output.text.contains("Journal of Materials"))
        try check(!output.text.contains("authors contributed"))
        try check(!output.text.contains("Synthetic Meeting") && !output.text.contains("Synthetic Press") && !output.text.contains("Synthetic Laboratory"))
    }

    func testNaturalRangeCommandsAndCorrections() throws {
        let start = "The dark current is subtracted"
        let end = "before comparing the two channels."
        let doc = try index([
            page(1, [block("Earlier prose. " + start + " after calibration.")]),
            page(2, [block("The signals are aligned " + end + " Unrelated tail.")])
        ])
        let quoted = try unwrap(doc.prepare("请翻译从“\(start)”到“\(end)”的原文。").first)
        let questions = [
            "请把从 \(start) 到 \(end) 的原文逐段翻译成中文。",
            "从 \(start) 到 \(end) 的正文帮我连贯翻译。",
            "以 \(start) 开头，一直读到 \(end)，翻译全部中间正文。",
            "翻译从 \(start) 到 \(end) 的全部正文。",
            "从 \(start) 到 \(end) 的完整正文翻译为中文。",
            "从 \(start) 到 \(end)，这一整段请译成中文。",
            "翻译 \(start) 到 \(end) 的正文。",
            "请将从 \(start) 到 \(end) 的完整内容逐句译成中文。",
            "从 \(start) 到 \(end)，把这段原文完整译成中文。",
            "请以 \(start) 开头，\(end) 结束，请把整个范围译成中文。",
            "\(start) 起，到 \(end) 这段请翻为中文。",
            "请从 \(start) 起读，截止到 \(end) 开头的跨页原文，译为中文。",
            "从 \(start) 读到 \(end)，把原文跨页完整翻译成中文。",
            "请从 \(start) 一直读到 \(end)，只取这两处之间的正文。",
            "从“\(start)” 一直到 “\(end)” 的连续正文都翻译出来。",
            "从‘\(start)’截止到‘\(end)’，请把全文译出来。",
            "请翻译以 \(start) 开头、到 \(end) 为止的完整正文。",
            "Translate from \(start) to \(end), paragraph by paragraph."
        ]
        for question in questions {
            let result = try unwrap(doc.prepare(question).first)
            try check(result.text == quoted.text && result.pdfPositions == quoted.pdfPositions)
            try check(result.text.hasPrefix(start) && result.text.hasSuffix(end))
        }
        for request in ["解释图8从测量、校准到恢复的流程", "翻译表2的表注，从第一句到解释参数的最后一句。",
                        "请看图7，自相关结果和原图都需要给到。", "只要图 2 的完整图注，从图的标题直到最后一行模型说明。"] {
            try check(!ResearchPDFAddress.parse(request).addressesPassage)
        }
        let numberedFormula = ResearchPDFObjectID(kind: .equation, number: "1")
        for request in ["展示编号为 (1) 的完整公式。", "给出编号 (1) 的完整量化公式，保留分式内容。", "定位公式 (1)，展示从 Z 到右端 V 的完整算式和编号。"] {
            try check(ResearchPDFObjectID.addresses(in: request) == [numberedFormula])
            try check(!ResearchPDFAddress.parse(request).addressesPassage)
        }
        let two = [numberedFormula, .init(kind: .equation, number: "6")]
        try check(ResearchPDFObjectID.addresses(in: "请保留公式（1）和（6）的两条原式。") == two)
        try check(ResearchPDFObjectID.untypedEquationList(in: "用（1）和（6）说明变量的关系。") == two)
        try check(doc.addressedObjects(in: "用（1）和（6）说明变量的关系。", address: .none).isEmpty)
        for request in ["图8附近，从“边界”到“结构的完整流程”", "把从 the first result 到 see Fig. 3. 的原文逐句译为中文",
                        "图8旁的正文，从示例开头到实验终止的原文。"] {
            try check(ResearchPDFAddress.parse(request).addressesPassage)
        }
        let inflection = try index([page(1, [block("BEGIN. The records are stored by print-\ning both results in one trial. Omit.")])])
        let printed = try unwrap(inflection.readRange(start: "BEGIN", end: "print both results in one trial.").first)
        try check(printed.text.hasSuffix("print-\ning both results in one trial."))
        try check(printed.scope.contains("原页实际词形"))
        try rejects(try inflection.readRange(start: "BEGIN", end: "print both results"), containing: "终点")
        let wrong = "请把从 \(start) 到 absent terminal. 的原文逐段翻译成中文。"
        do {
            _ = try doc.prepare(wrong)
            throw Failure.assertion("Invalid endpoint was accepted")
        } catch let issue as ResearchPDFRangeAmbiguity {
            try check(issue.candidates.isEmpty && issue.anchors == .init(start: start, end: "absent terminal."))
        }
        let corrected = try unwrap(doc.prepare(wrong, correctedAnchors: .init(start: start, end: end)).first)
        try check(corrected.text == quoted.text && corrected.pdfPositions == quoted.pdfPositions)
        let edited = ResearchPDFAnchors(start: start, end: end)
        let original = ResearchPDFAnchors(start: start, end: "absent terminal.")
        try check(edited.updatingQuestion(wrong, from: original) == questions[0])
        let repeated = wrong + "补充说明：absent terminal. 仅用于对照。"
        let fallback = edited.updatingQuestion(repeated, from: original)
        try check(fallback.hasPrefix(repeated) && fallback.contains("【用户已校正并核验的范围】") && fallback.contains(end))
        let chinese = try index([page(1, [block("校准起点是研究如何翻译内容。文档另指出该段的原文逐段翻译成中文。")])])
        try check(try chinese.prepare("从校准起点到研究如何翻译内容").first?.text == "校准起点是研究如何翻译内容")
        try check(try chinese.prepare("从“校准起点”到“该段的原文逐段翻译成中文。”").first?.text.hasSuffix("该段的原文逐段翻译成中文。") == true)
        let scoped = try index([
            page(1, [block("START alpha FINISH")]),
            page(2, [block("START beta FINISH")])
        ])
        try check(try scoped.prepare("第2页中请把从 START 到 FINISH 的原文逐段翻译成中文。").first?.text == "START beta FINISH")
    }

    func testStructuredRequestCoverage() throws {
        let variable = ResearchPDFRequest("公式（2）里的 T 和 N 是什么？原文还如何定义 H^l 和 W^l？")
        try check(variable.requestedSymbols == ["T", "N", "H", "W"])
        try check(variable.symbolRequirements.map(\.printed) == ["T", "N", "H^l", "W^l"])
        try check(ResearchPDFRequest("解释变量 T").requestedSymbols == ["T"])
        try check(ResearchPDFRequest("解释符号 θ").requestedSymbols == ["θ"])
        try check(ResearchPDFRequest("逐字摘录 Fig.1 的完整图注。").output.captionOnly)
        try check(!ResearchPDFRequest("解释图3，逐句核对图注并包含所有子图。").output.captionOnly)
        try check(ResearchPDFRequest("为什么达到最优？结合公式（5）和（6），保留两条原式。").requiresObjectRelationship)

        let query = "从 Network output 到 C(G) reaches the value −log 4. 的原文逐段翻译成中文，中间图注不要混入。"
        let request = ResearchPDFRequest(query)
        guard case .anchors(let bounds) = request.address else { throw Failure.assertion("Bounded translation not parsed") }
        try check(bounds.endpoints == [.init(start: "Network output", end: "C(G) reaches the value −log 4.")])
        try check(!bounds.includeCaptions && request.output.action == .translate &&
                  request.output.unit == .paragraph && request.output.language == "中文")
        let figure = block("Figure 7. Floating explanation.", kind: .figureLabel)
        var algorithm = block("Algorithm 2. Unrelated data.")
        algorithm.paragraphRole = .algorithm
        let doc = try index([
            page(1, [block("Network output is reported. The result is photo-"), algorithm]),
            page(2, [figure, block("realistic as illustrated here. Then C(G) reaches the value−log 4. Omit.")])
        ])
        let math = try unwrap(try doc.prepare(request).first)
        try check(math.text == "Network output is reported. The result is photo-\n\nrealistic as illustrated here. Then C(G) reaches the value−log 4.")
        try check(math.evidenceChecks?.map(\.kind) == [.continuousRange, .location])
        try check(math.evidenceChecks?.allSatisfy { $0.status == .verified } == true)
        let wrapped = try unwrap(try doc.prepare("从 Network output 到 realistic as illustrated here. 连续读出原文。").first)
        try check(wrapped.text.hasSuffix("photo-\n\nrealistic as illustrated here."))
        try rejects(try doc.prepare("从 realistic as illustrated here 到 Omit"))
        try rejects(try doc.prepare("从 Network output 到 C(G) reaches the value +log 4."))
        let symbols = try index([page(1, [block("BEGIN lets ψc(xc) denote φc(xc|I). NEXT.")])])
        try check(try symbols.prepare("把 BEGIN 起，到 denote φ_c(x_c|I). 为止的连续定义原文摘出。").first?.text
                  == "BEGIN lets ψc(xc) denote φc(xc|I).")
    }

    func testEquationDefinitionsFollowTheReadingLanes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-eq-context-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = CGDataConsumer(url: url as CFURL)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: sink, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            let item = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font])
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(item), ctx)
        }
        ctx.beginPDFPage(nil)
        for row in 0..<7 {
            line("This earlier discussion belongs to the left column.", 43, CGFloat(710 - row * 13))
        }
        line("The raw readings define u for this calibration,", 43, 201)
        line("and the two measured traces are combined as follows.", 43, 188)
        line("u = f(x1)", 133, 166)
        line("The first calibration uses two measured terms,", 43, 144)
        line("so the reference input and output satisfy", 43, 131)
        line("s = u + v", 133, 87)
        line("(1)", 262, 87)

        line("For the reference case, u denotes the incident field", 326, 710)
        line("and v represents the measured background signal.", 326, 697)
        line("Their sum gives the total signal observed by the sensor.", 326, 684)
        line("2. Independent calibration", 326, 648)
        for row in 0..<5 {
            line("A separate experiment establishes another baseline.", 326, CGFloat(624 - row * 13))
        }
        line("The second calibration defines a separate output", 326, 144)
        line("using a measurement from an independent detector.", 326, 131)
        line("t = b + c", 415, 87)
        line("(2)", 552, 87)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        line("Here b denotes the offset in Equation (2).", 43, 710)
        line("The other term c represents the residual response", 43, 697)
        line("reported by the second detector during calibration.", 43, 684)
        line("3. Another measurement", 43, 649)
        line("The following section introduces unrelated values.", 43, 623)
        ctx.endPDFPage()
        ctx.closePDF()

        let pdf = try ResearchPDFIndex.read(url, title: "Equation definitions by reading lane") { _ in }
        let first = try pdf.objectEvidence([.init(kind: .equation, number: "1")], includeImages: true)
        try check(first.images.count == 1)
        try check(first.material.text.contains("The raw readings define u"))
        try check(first.material.text.contains("reference input"))
        try check(first.material.text.contains("u denotes the incident field"))
        try check(first.material.text.contains("v represents the measured background signal"))
        try check(!first.material.text.contains("second calibration") && !first.material.text.contains("residual response"))
        let firstSources = first.material.backgroundPositions ?? []
        try check(firstSources.contains { $0.page == 1 && $0.column == 1 })
        try check(firstSources.contains { $0.page == 1 && $0.column == 2 })

        let second = try pdf.objectEvidence([.init(kind: .equation, number: "2")], includeImages: true)
        try check(second.images.count == 1)
        try check(second.material.text.contains("b denotes the offset"))
        try check(second.material.text.contains("c represents the residual response"))
        try check(!second.material.text.contains("introduces unrelated values") && !second.material.text.contains("u denotes"))
        try check(second.material.backgroundPositions?.contains { $0.page == 2 } == true)
        try check(second.material.pdfPositions?.allSatisfy { $0.page == 1 } == true)
    }

    /// Permanent synthetic regression, independent of the researcher's papers. Text paint
    /// order is deliberately interleaved. An illustration interrupts the narrative across
    /// a page break, and a separate page mixes an unlabelled grid with ordinary prose.
    func testMixedLayoutsUseOnlyTheRequestedRoute() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-local-order-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = CGDataConsumer(url: url as CFURL)!
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let ctx = CGContext(consumer: sink, mediaBox: &box, nil)!
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ points: CGFloat = 10) {
            let font = CTFontCreateWithName("Helvetica" as CFString, points, nil)
            let run = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font])
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(run), ctx)
        }
        ctx.beginPDFPage(nil)
        for n in 0..<6 {
            line(n == 4 ? "COPPER RANGE starts in this column" :
                 n == 5 ? "and continues onto the following sheet." :
                 "Earlier prose in the right column.", 330, CGFloat(660 - n * 13))
            line("Unrelated prose from the first column.", 45, CGFloat(660 - n * 13))
        }
        line("1", 300, 20, 8)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        line("Input map", 58, 712, 8)
        line("Final map", 180, 712, 8)
        ctx.setFillColor(gray: 0.3, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 60, y: 648, width: 65, height: 34))
        ctx.fill(CGRect(x: 170, y: 644, width: 62, height: 40))
        ctx.setFillColor(gray: 0, alpha: 1)
        line("Fig. 8 Comparison between two test images.", 42, 605)
        line("The dark patches mark the synthetic response.", 42, 592)
        line("The narrative continues here", 42, 544)
        line("and concludes at COBALT STOP before this suffix.", 42, 531)
        for n in 0..<10 { line("Separate column of synthetic instructions.", 335, CGFloat(712 - n * 16)) }
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        for n in 0..<3 {
            line("West observation " + String(n), 28, CGFloat(700 - n * 18))
            line("Center observation " + String(n), 211, CGFloat(700 - n * 18))
            line("East observation " + String(n), 410, CGFloat(700 - n * 18))
        }
        line("LOCAL OPEN begins an independent paragraph under the grid, with its own normal reading order.", 43, 550)
        line("After a second complete line the verified paragraph reaches LOCAL CLOSE.", 43, 537)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        line("WILLOW BEGIN before an adjacent diagram.", 42, 712)
        ctx.setFillColor(gray: 0.6, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 48, y: 625, width: 100, height: 63))
        ctx.setFillColor(gray: 0, alpha: 1)
        line("Fig. 9 A compact caption.", 42, 592)
        line("A complete sentence of genuine running prose begins flush with that caption.", 42, 579)
        line("Additional body text follows without an indent or font change.", 42, 566)
        line("The final paragraph reaches WILLOW END.", 42, 518)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        line("BIRCH OPEN crosses a boxed illustration.", 42, 704)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(0.5)
        ctx.stroke(CGRect(x: 36, y: 363, width: 526, height: 294))
        line("Fragmented axis label inside the illustration", 220, 513)
        line("Another plot label", 351, 478)
        line("Fig. 10 The wide illustration has a numbered legend, surrounded by a printed border.", 43, 380)
        line("The paragraph after the box reaches BIRCH CLOSE.", 42, 322)
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try ResearchPDFIndex.read(url, title: "Synthetic mixed layout") { _ in }
        let result = try doc.readRange(start: "COPPER RANGE", end: "COBALT STOP")
        let expected = "COPPER RANGE starts in this column and continues onto the following sheet. " +
            "The narrative continues here and concludes at COBALT STOP"
        func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }
        try check(words(result.map(\.text).joined()) == words(expected))
        try check(result.flatMap { $0.pdfPositions ?? [] }.map(\.page) == [1, 1, 2, 2])
        try check(doc.pages[1].blocks.contains { $0.kind == .figureLabel && $0.text.contains("Final map") })
        let clean = try doc.readRange(start: "LOCAL OPEN", end: "LOCAL CLOSE")
        try check(clean.count == 1 && clean[0].text.hasSuffix("LOCAL CLOSE"))
        try check(!doc.pages[2].reliableOrder)
        do {
            _ = try doc.readRange(start: "West observation 0", end: "East observation 2")
            throw Failure.assertion("A multi-row, multi-column grid must request a visual check.")
        } catch let review as ResearchPDFReviewRequired {
            try check(review.pages == [3] && !review.materials.isEmpty)
            let grid = review.materials.map(\.text).joined()
            try check(!grid.contains("LOCAL OPEN") && !grid.contains("LOCAL CLOSE"))
            for index in 0..<3 {
                for column in ["West", "Center", "East"] {
                    try check(grid.components(separatedBy: column + " observation " + String(index)).count == 2)
                }
            }

            try check(review.materials.flatMap { $0.pdfPositions ?? [] }.allSatisfy { $0.page == 3 })
        }
        let adjacent: [ResearchMaterial]
        do {
            adjacent = try doc.readRange(start: "WILLOW BEGIN", end: "WILLOW END")
        } catch let review as ResearchPDFReviewRequired {
            try check(review.pages == [4])
            adjacent = review.materials
        }
        let retained = adjacent.map(\.text).joined()
        try check(retained.contains("genuine running prose") && retained.contains("Additional body text"))
        let framed = try doc.readRange(start: "BIRCH OPEN", end: "BIRCH CLOSE").map(\.text).joined()
        try check(words(framed) == words("BIRCH OPEN crosses a boxed illustration. The paragraph after the box reaches BIRCH CLOSE"))
        let framedWithCaption = try doc.readRange(start: "BIRCH OPEN", end: "BIRCH CLOSE",
            includeDetachedCaptions: true).map(\.text).joined()
        try check(framedWithCaption.contains("numbered legend") && !framedWithCaption.contains("axis label"))
        try check(doc.pages[4].blocks.contains { $0.kind == .figureLabel && $0.text.contains("axis label") })
    }

    /// Document object labels are not running-text mentions. The exact body is used in a
    /// text-only turn, while spatial notation uses an original local crop. Another version
    /// at the same path must produce a new object map and new source identity.
    func testDocumentObjectIndex() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-objects-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        func write(extraPage: Bool) {
            var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
            let sink = CGDataConsumer(url: url as CFURL)!
            let canvas = CGContext(consumer: sink, mediaBox: &paper, nil)!
            let normal = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let small = CTFontCreateWithName("Helvetica" as CFString, 7, nil)
            func line(_ text: String, _ x: CGFloat, _ y: CGFloat, font: CTFont? = nil) {
                let item = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font ?? normal
                ])
                canvas.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(item), canvas)
            }
            if extraPage {
                canvas.beginPDFPage(nil)
                line("Revised edition title page, independent of the object numbering.", 45, 650)
                canvas.endPDFPage()
            }
            canvas.beginPDFPage(nil)
            line("This text discusses Figure 4 without contributing to its caption.", 45, 741)
            canvas.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            canvas.fill(CGRect(x: 60, y: 594, width: 240, height: 107))
            canvas.setFillColor(gray: 0, alpha: 1)
            line("Fig. 4. Example diagram of two optical measurements.", 45, 563)
            line("The nearby paragraph mentions Eq. (6) and compares the reported outcomes of the measurements.", 45, 500)
            line("The main equation minimizes the cost over the chosen parameter:", 45, 470)
            line("min L(x).", 241, 445)
            line("x", 246, 438, font: small)
            line("(6)", 494, 445)
            line("The chosen variable ranges over a set of stable measurement conditions.", 45, 417)
            line("The next equation compares a value at two separate timesteps:", 45, 340)
            line("x = y", 243, 311)
            line("−1", 275, 318, font: small)
            line("(15)", 489, 311)
            line("The symbol here is defined using a matrix from the earlier section.", 45, 282)
            canvas.endPDFPage()
            canvas.closePDF()
        }
        write(extraPage: false)
        let a = try ResearchPDFIndex.read(url, title: "fixture") { _ in }
        let figure = ResearchPDFObjectID.addresses(in: "翻译图4 / show Fig.4")
        let graphic = try a.objectEvidence(figure, includeImages: true, question: "图内图形")
        try check(figure.count == 1 && graphic.needsVisual && graphic.images.count == 1)
        let components = graphic.material.text.components(separatedBy: "辅助依据")
        try check(components[0].contains("Example diagram") && !components[0].contains("without contributing"))
        let excerpts = try unwrap(graphic.material.verifiedExcerpts)
        let originalCaption = excerpts.filter { $0.kind == .caption }.compactMap { $0.text(in: graphic.material.text) }
        try check(originalCaption == ["Fig. 4. Example diagram of two optical measurements."])
        try check(excerpts.allSatisfy { $0.page == 1 })
        try check(graphic.material.backgroundPositions?.allSatisfy { $0.page == 1 && $0.bounds.minY > 730 } == true)
        try check(graphic.material.pdfPositions?.allSatisfy { $0.page == 1 } == true)
        try check(ResearchPDFObjectID.addresses(in: "Fig. 4(b)").first?.number == "4b")
        for q in ["解释编号为（2.1）的公式", "请定位（2.1）式", "Equation numbered (2.1)"] {
            try check(ResearchPDFObjectID.addresses(in: q) == [.init(kind: .equation, number: "2.1")])
        }
        try check(ResearchPDFObjectID.addresses(in: "实验编号为（2）时测量另一公式").isEmpty)
        try check(ResearchPDFObjectID.addresses(in: "比较编号 7 的图与公式编号为 (3)") ==
            [.init(kind: .figure, number: "7"), .init(kind: .equation, number: "3")])
        let sixth = try unwrap(ResearchPDFObjectID.addresses(in: "解释公式6").first)
        let fifteenth = try unwrap(ResearchPDFObjectID.addresses(in: "Eq. (15)").first)
        let textOnly = try a.objectEvidence([sixth], question: "解释公式6")
        try check(!textOnly.needsVisual && textOnly.images.isEmpty && textOnly.material.text.contains(#"\min_{x} L(x)"#))
        let missingSymbols = try a.objectEvidence([fifteenth], question: "解释公式15")
        try check(missingSymbols.needsVisual && missingSymbols.images.isEmpty && missingSymbols.material.text.contains("缺少完整公式"))
        try check(missingSymbols.material.verifiedExcerpts?.contains { $0.kind == .body } != true)
        let spatial = try a.objectEvidence([fifteenth], includeImages: true, question: "解释公式15")
        try check(spatial.images.count == 1 && spatial.images[0].starts(with: [0xff, 0xd8]))
        try check(spatial.material.pdfPositions != spatial.material.backgroundPositions)
        let mixed = try a.objectEvidence([fifteenth, figure[0]], includeImages: true,
                                         question: "解释公式15和图4").material
        let groups = try unwrap(mixed.sourceGroups)
        let primary = try unwrap(mixed.pdfPositions), supporting = try unwrap(mixed.backgroundPositions)
        let equation = try unwrap(groups.first { $0.role == .object && $0.title == fifteenth.label })
        let diagram = try unwrap(groups.first { $0.role == .object && $0.title.hasPrefix(figure[0].label) })
        let caption = try unwrap(groups.first { $0.role == .caption })
        let definition = try unwrap(groups.first { $0.role == .context && $0.title.hasPrefix(fifteenth.label) })
        func locations(_ group: ResearchPDFSourceGroup) throws -> [ResearchPDFSourcePosition] {
            try unwrap(group.positions(in: primary, background: supporting))
        }
        try check(try locations(equation).allSatisfy { $0.page == 1 && $0.bounds.midY < 333 })
        try check(try locations(diagram).allSatisfy { $0.page == 1 && $0.bounds.midY > 594 })
        try check(try locations(caption).allSatisfy { $0.page == 1 && (558..<573).contains($0.bounds.midY) })
        try check(try locations(definition).allSatisfy { $0.page == 1 && $0.bounds.midY < 360 })
        try check(a.previousEquation(before: fifteenth) == sixth)
        try check(try ResearchPDFIndex.read(url, title: "fixture") { _ in } === a)
        write(extraPage: true)
        let b = try ResearchPDFIndex.read(url, title: "fixture revised") { _ in }
        let moved = try b.objectEvidence(figure, question: "图注")
        try check(a.reference.fingerprint != b.reference.fingerprint)
        try check(moved.material.pdfPositions?.allSatisfy { $0.page == 2 } == true && graphic.material.pdfPositions?.first?.page == 1)
    }

    func testFramedFigureWithFormulaAndCaptionContinuation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-framed-graphic-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &paper, nil)!
        let normal = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let small = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let equation = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, font: CTFont) {
            canvas.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), canvas)
        }
        canvas.beginPDFPage(nil)
        for (i, text) in [
            "This paragraph motivates the calibration.",
            "The fixture prints both lanes in parallel.",
            "Figure 3a illustrates the control array.",
            "The output is sampled every five minutes.",
            "These measurements establish a reference."
        ].enumerated() {
            line(text, 48, 741 - CGFloat(14 * i), font: normal)
            line("Independent right column. " + text.prefix(17), 323, 741 - CGFloat(14 * i), font: normal)
        }
        canvas.setStrokeColor(gray: 0, alpha: 1)
        canvas.setLineWidth(1)
        canvas.stroke(CGRect(x: 46, y: 471, width: 253, height: 178))
        canvas.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        canvas.fill(CGRect(x: 55, y: 539, width: 105, height: 96))
        canvas.fill(CGRect(x: 176, y: 545, width: 113, height: 87))
        canvas.setFillColor(gray: 0, alpha: 1)
        line("(a) Control", 56, 642, font: small)
        line("(b) Measured", 177, 641, font: small)
        line("Fig. 3. A diagram with two panels and a formula.", 51, 527, font: small)
        line("The shaded bars show the complete reference and test grids.", 51, 516, font: small)
        line("The notation ∥u∥ = c.", 51, 500, font: equation)
        line("The last observation is the audited modulation signal.", 51, 480, font: small)
        line("The independent following paragraph is absent from the caption.", 48, 442, font: normal)
        canvas.endPDFPage()
        canvas.closePDF()

        let index = try ResearchPDFIndex.read(url, title: "boxed figure") { _ in }
        let ids = ResearchPDFObjectID.addresses(in: "解释图3")
        let evidence = try index.objectEvidence(ids, includeImages: true, question: "解释图3")
        let main = evidence.material.text.components(separatedBy: "辅助依据")[0]
        try check(main.contains("audited modulation signal") && main.contains("The notation"))
        try check(!main.contains("independent following paragraph") && !main.contains("Independent right column"))
        try check(evidence.images.count == 2)
        let mixedQuestion = "解释图3，并说明图注最后一句。"
        let mixed = try index.objectEvidence(ids, includeImages: true, question: mixedQuestion)
        try check(mixed.images == evidence.images)
        let captionOnly = try index.objectEvidence(ids, includeImages: true, question: "只看图3的图注")
        try check(captionOnly.images == Array(evidence.images.suffix(1)))
        let positions = try unwrap(evidence.material.pdfPositions)
        let visual = try unwrap(positions.first)
        try check(visual.bounds.minX < 55 && visual.bounds.maxX > 289 && visual.bounds.maxY > 643)
        try check(positions.contains { $0.bounds.minY < 483 && $0.bounds.minY > 475 })
        try check(evidence.material.backgroundPositions?.allSatisfy { $0.bounds.minY > 650 } == true)
        let caption = try unwrap(evidence.material.sourceGroups?.first { $0.role == .caption })
        let allCaption = try unwrap(caption.positions(in: positions, background: []))
        try check(allCaption.contains { $0.bounds.minY < 483 && $0.bounds.minY > 475 && $0.sourceRange != nil })
        try check(allCaption.allSatisfy { $0.bounds.minY > 470 && $0.bounds.maxY < 537 })
    }

    func testSpanningCaptionTerminalLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-spanning-caption-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &paper, nil)!
        let small = CTFontCreateWithName("Times-Roman" as CFString, 9, nil)
        let ordinary = CTFontCreateWithName("Times-Roman" as CFString, 10, nil)
        let terminal = "remain anchored to the calibrated reference."
        let following = "Independent left-column prose begins after the graphic."
        let competing = "another left-column line with no visible typographic break."
        func line(_ text: String, x: CGFloat = 48, y: CGFloat, font: CTFont, width: CGFloat? = nil) {
            let run = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            canvas.saveGState()
            canvas.translateBy(x: x, y: y)
            if let width {
                canvas.scaleBy(x: width / CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil)), y: 1)
            }
            canvas.textPosition = .zero
            CTLineDraw(run, canvas)
            canvas.restoreGState()
        }
        for (figure, ambiguous) in [(11, false), (12, true)] {
            canvas.beginPDFPage(nil)
            canvas.setFillColor(gray: 0.36, alpha: 1)
            canvas.fill([CGRect(x: 64, y: 632, width: 199, height: 86), CGRect(x: 324, y: 629, width: 194, height: 89)])
            canvas.setFillColor(gray: 0, alpha: 1)
            line("Figure \(figure). The calibration graphic spans the full width of a two-column page.",
                 y: 605, font: small, width: 492)
            line("The marks on either side of the illuminated region record the positions of both independent sensors and",
                 y: 594, font: small, width: 492)
            line("The instrument records the reference displacement and the two registered sensors",
                 y: 583, font: small, width: 492)
            line(terminal, y: 572, font: small)
            if ambiguous { line(competing, y: 561, font: small) }
            line(following, y: 548, font: ordinary)
            for row in 0..<7 {
                let y = CGFloat(534 - 13 * row)
                line("Running measurements are recorded without stimulus at this stage.", y: y, font: ordinary, width: 235)
                line("The right-hand lane documents a separate control experiment.", x: 323, y: y, font: ordinary, width: 235)
            }
            canvas.endPDFPage()
        }
        canvas.closePDF()

        let index = try ResearchPDFIndex.read(url, title: "Spanning caption and adjacent prose") { _ in }
        let fixed = try index.objectEvidence([.init(kind: .figure, number: "11")], question: "只看图11的图注")
        let confirmed = try unwrap(fixed.material.verifiedExcerpts?.first { $0.kind == .caption })
        try check(confirmed.text(in: fixed.material.text)?.hasSuffix(terminal) == true && confirmed.partial != true)
        try check(!fixed.material.text.contains(following) && !fixed.material.text.contains(competing))
        let group = try unwrap(fixed.material.sourceGroups?.first { $0.role == .caption })
        let positions = try unwrap(group.positions(in: fixed.material.pdfPositions ?? [], background: []))
        try check(positions.count == 4 && positions.allSatisfy { $0.column == 0 && $0.page == 1 && $0.sourceRange != nil })
        try check(index.pages[0].blocks.contains { $0.kind == .caption && $0.detachedCaption && $0.text.hasSuffix(terminal) })

        let unresolved = try index.objectEvidence([.init(kind: .figure, number: "12")], question: "只看图12的图注")
        let partial = try unwrap(unresolved.material.verifiedExcerpts?.first { $0.kind == .caption })
        try check(partial.partial == true && unresolved.material.text.contains("未能核实整段图注边界"))
        try check(!unresolved.material.text.contains(terminal) && !unresolved.material.text.contains(competing))
        try check(unresolved.material.pdfPositions?.first?.page == 2)
    }

    func testRasterTickAndVectorPanelDoNotSplitFigure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-mixed-figure-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &paper, nil)!
        let raster = CGContext(data: nil, width: 80, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        raster.setFillColor(red: 0.1, green: 0.34, blue: 0.65, alpha: 1)
        raster.fill(CGRect(x: 0, y: 0, width: 80, height: 32))
        func write(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            canvas.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), canvas)
        }
        canvas.beginPDFPage(nil)
        write("https://doi.org/10.0000/example", x: 385, y: 764)
        write("(a)", x: 66, y: 739)
        canvas.draw(raster.makeImage()!, in: CGRect(x: 454, y: 673, width: 82, height: 56))
        write("Signal plane", x: 162, y: 739)
        write("1", x: 538, y: 722, size: 6)
        write("(b)", x: 66, y: 641)
        canvas.setStrokeColor(gray: 0.2, alpha: 1)
        canvas.setLineWidth(1.5)
        canvas.stroke(CGRect(x: 73, y: 524, width: 469, height: 107))
        write("Fig. 8 | Surface image and the measured spectrum.", x: 55, y: 495)
        write("The independent paragraph below the two panels describes the experimental controls and notes the reconstruction tolerance.", x: 54, y: 420)
        canvas.endPDFPage()
        canvas.beginPDFPage(nil)
        write("Read the calibrated scale above the illustrated signals.", x: 52, y: 757)
        // This chart has no embedded image: the native top tick is also
        // classified as running page furniture by its location.
        canvas.stroke(CGRect(x: 91, y: 632, width: 210, height: 88))
        for (value, y) in [("9", 718), ("6", 690), ("3", 660)] {
            write(value, x: 82, y: CGFloat(y), size: 6)
        }
        write("Figure 9: A vector-only response curve.", x: 52, y: 610)
        write("To compare our experimental results, see", x: 52, y: 549)
        write("Figure 9. This paragraph introduces a different measurement.", x: 52, y: 536)
        canvas.endPDFPage()
        canvas.closePDF()
        let index = try ResearchPDFIndex.read(url, title: "mixed raster and vector") { _ in }
        let evidence = try index.objectEvidence(ResearchPDFObjectID.addresses(in: "解释 Fig. 8"),
                                                includeImages: true, question: "解释 Fig. 8")
        let visual = try unwrap(evidence.material.pdfPositions?.first?.bounds)
        try check(evidence.images.count == 1 && visual.maxY > 744 && visual.maxY < 756 && visual.minY < 525 && visual.maxX > 542)
        try check(evidence.material.text.contains("Signal plane") && !evidence.material.text.contains("10.0000/example"))
        let vector = try index.objectEvidence(ResearchPDFObjectID.addresses(in: "解释 Fig. 9"),
                                              includeImages: true, question: "解释 Fig. 9")
        let chart = try unwrap(vector.material.pdfPositions?.first?.bounds)
        try check(chart.maxY > 720 && chart.maxY < 747 && chart.minY < 633)
    }

    func testNumberedSystemAndRaisedReference() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-equation-rows-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &paper, nil)!
        @discardableResult func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ fontSize: CGFloat = 11) -> CGFloat {
            let run = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont(name: "Helvetica", size: fontSize)!
            ]))
            canvas.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(run, canvas)
            return x + CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil))
        }
        canvas.beginPDFPage(nil)
        line("The following isolated equations show the three stages of the verified optical measurement.", 48, 723)
        line("a(t) = u + v", 166, 687)
        line("2", 218, 695, 7)
        line("b(t) = a(t) + u", 166, 665)
        line("(12)", 500, 665)
        line("c(t) = b(t) + v", 166, 642)
        line("3", 173, 638, 7)
        line("The three rows share the number placed on the middle row of the printed display.", 48, 610)
        let markerX = line("At this checkpoint the original result was confirmed", 48, 560)
        let afterX = line("7", markerX, 563.5, 7)
        line(". Additional text follows.", afterX, 560)
        line("A similarly spelled ordinary token is control7. It must remain intact.", 48, 533)
        line("To set the calibration baseline, we define qt:", 48, 452)
        line("qt = a + u", 160, 427)
        line("(13)", 500, 427)
        line("The instrument then uses the squared deviation as its reading.", 48, 382)
        line("R = qt + f(x)", 160, 348)
        line("(14)", 500, 348)
        line("In this particular comparison qt is small relative to the noise.", 48, 311)
        canvas.endPDFPage()
        canvas.beginPDFPage(nil)
        line("This independent derivation defines the calibration matrix in the following three printed rows.", 48, 714)
        line("a(t) = u + v", 166, 670)
        line("b(t) = a(t) + u", 166, 650)
        line("(15)", 500, 659)
        // The last row can survive as mathematical glyphs with no decoded equality cue.
        line("c(t) × w", 166, 629)
        line("3.2 Local quantities", 48, 607, 13)
        line("The coefficient w in equation (15) is the calibrated power reference for this measurement.", 48, 588)
        line("Its stated unit is a watt in the original acquisition model.", 48, 575)
        canvas.endPDFPage()
        canvas.closePDF()
        let index = try ResearchPDFIndex.read(url, title: "Typeset system") { _ in }
        let equation = try index.objectEvidence(ResearchPDFObjectID.addresses(in: "解释式（12）"), includeImages: true)
        let box = try unwrap(equation.material.pdfPositions?.first?.bounds)
        try check(box.minY <= 639 && box.maxY >= 698 && box.minY > 628 && box.maxY < 718)
        let q = "读编号为（14）的公式时，qt 是什么意思？"
        let evidence = try index.objectEvidence(ResearchPDFObjectID.addresses(in: q), includeImages: true, question: q)
        try check(evidence.images.count == 2 && evidence.material.text.contains("we define qt"))
        try check(evidence.material.backgroundPositions?.contains { $0.sourceRange == nil && $0.bounds.contains(CGPoint(x: 185, y: 430)) } == true)
        let source = try unwrap(evidence.material.sourceGroups?.first { $0.title.contains("qt 的定义") })
        let destinations = source.positions(in: evidence.material.pdfPositions ?? [], background: evidence.material.backgroundPositions ?? [])
        try check(destinations?.count == 1 && destinations?.first?.bounds.contains(CGPoint(x: 185, y: 430)) == true)
        let extended = try index.objectEvidence([.init(kind: .equation, number: "15")], includeImages: true)
        let extendedBox = try unwrap(extended.material.pdfPositions?.first?.bounds)
        try check(extendedBox.minY < 632 && extendedBox.minY > 617)
        try check(extended.material.text.contains("calibrated power reference"))
        let captured = try index.readRange(start: "At this checkpoint", end: "result was confirmed")
        try check(captured.map(\.text).joined().hasSuffix("result was confirmed"))
        try rejects(try index.readRange(start: "A similarly spelled", end: "ordinary token is control"), containing: "终点")
    }

    func testSpatialEquationNumberRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-equation-ink-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        let canvas = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &paper, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        func line(_ text: String, at x: CGFloat, _ y: CGFloat) {
            let text = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            canvas.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), canvas)
        }
        canvas.beginPDFPage(nil)
        line("The following observations apply only to the present reconstruction and to the test area.", at: 45, 737)
        line("Short preceding prose.", at: 45, 724)
        line("J = alpha + beta", at: 160, 704)
        line("sub) (9)", at: 481, 704)
        line("Where the symbols represent a control variable and a measurement normalization factor.", at: 45, 680)
        line("The protocol cites Eq. (8)", at: 447, 641)
        line("Native math above stays independent of the inline citation in the paragraph.", at: 45, 606)
        canvas.endPDFPage()
        canvas.closePDF()

        let index = try ResearchPDFIndex.read(url, title: "Separated printed number") { _ in }
        let equation = try unwrap(ResearchPDFObjectID.addresses(in: "公式9").first)
        let reference = try unwrap(ResearchPDFObjectID.addresses(in: "公式8").first)
        try check(index.objects.objects[equation] == nil)
        let result = try index.objectEvidence([equation], includeImages: true)
        let primary = try unwrap(result.material.pdfPositions?.first)
        try check(primary.page == 1 && primary.bounds.minX < 164 && primary.bounds.maxX > 510)
        try check(primary.bounds.minY > 695 && primary.bounds.maxY < 721)
        try check(result.images.count == 1 && result.images[0].starts(with: [0xff, 0xd8]))
        try check(try index.objectEvidence([equation], includeImages: true).images == result.images)
        let textual = try index.objectEvidence([equation])
        try check(textual.needsVisual && textual.images.isEmpty && textual.material.text.contains("无法可靠转写"))
        try rejects(try index.objectEvidence([reference]), containing: "未定位")
    }

    func testNumberedDisplayOnPageWithDamagedFont() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-damaged-font-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // Map a visible X to U+0000 in just one font. PDFKit must use the positioning
        // of unaffected lines without treating the damaged page as verified narrative.
        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /BrokenGlyph def /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        1 beginbfchar <58> <0000> endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """
        let page = #"""
        BT /Ordinary 11 Tf 80 430 Td (The display below uses two expressions on one line of the physical document.) Tj ET
        BT /Ordinary 12 Tf 100 390 Td (u = x + y,) Tj ET
        BT /Ordinary 12 Tf 330 390 Td (v = u + 3) Tj ET
        BT /Ordinary 12 Tf 452 390 Td (\(1\)) Tj ET
        BT /Ordinary 11 Tf 80 350 Td (The next sentence continues the main text and does not form a third expression.) Tj ET
        BT /Broken 11 Tf 80 310 Td (X) Tj ET
        BT /Ordinary 11 Tf 80 270 Td (Ordinary prose cites Eq. \(2\) without displaying the corresponding expression.) Tj ET
        """#
        func stream(_ body: String) -> String {
            "<< /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 560 700] /Resources << /Font << /Ordinary 4 0 R /Broken 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 7 0 R >>",
            stream(page), stream(cmap)
        ]
        var contents = "%PDF-1.4\n"
        var entries = "0000000000 65535 f \n"
        for (offset, item) in objects.enumerated() {
            entries += String(format: "%010d 00000 n \n", contents.utf8.count)
            contents += "\(offset + 1) 0 obj\n\(item)\nendobj\n"
        }
        let xref = contents.utf8.count
        contents += "xref\n0 \(objects.count + 1)\n\(entries)trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(contents.utf8).write(to: url)

        let index = try ResearchPDFIndex.read(url, title: "Mixed font") { _ in }
        try check(index.unavailable == [1] && !index.pages[0].hasLocalOrderMap)
        let evidence = try index.objectEvidence([.init(kind: .equation, number: "1")], includeImages: true)
        let region = try unwrap(evidence.material.pdfPositions?.first?.bounds)
        try check(region.minX < 101 && region.maxX > 460 && region.minY > 380 && region.maxY < 412)
        try check(evidence.images.count == 1 && evidence.needsVisual)
        try rejects(try index.objectEvidence([.init(kind: .equation, number: "2")]), containing: "未定位")
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

    func testPairedRangeCandidates() throws {
        var caption = block("Fig. 1 An independent experiment.", kind: .caption)
        caption.detachedCaption = true
        let document = try index([
            page(1, [block("Background", kind: .heading), block("The conjecture is based on tempting approximations."),
                     block("The next paragraph begins. Based on three direct observations, we verified the first result.", column: 2)]),
            page(2, [caption, block("The second paragraph preserves the measured evidence. The first endpoint is final signal.", column: 1),
                     block("Next observations are ready. Based on a different design, we tested a separate case.", column: 2),
                     block("The second paragraph contradicts the old theory. The other endpoint is final signal.", column: 2)])
        ])
        let q = "翻译 Based on 到 final signal. 的内容"
        let alternatives: ResearchPDFRangeAmbiguity
        do {
            _ = try document.prepare(q)
            throw Failure.assertion("Three ordered pairs are genuinely possible")
        } catch let choices as ResearchPDFRangeAmbiguity {
            alternatives = choices
        }
        try check(alternatives.candidates.count == 3 && !alternatives.truncated)
        try check(alternatives.candidates.allSatisfy { $0.startPreview.hasPrefix("Based on") && $0.endPreview.hasSuffix("final signal.") })
        let first = try unwrap(alternatives.candidates.first { $0.startPage == 1 && $0.endPreview.contains("first endpoint") })
        let selected = try unwrap(try document.prepare(q, chosenRangeID: first.id).first)
        try check(selected.pdfPages == "1–2" && selected.text.hasPrefix("Based on three") && selected.text.hasSuffix("final signal."))
        try check(!selected.text.contains("Fig. 1") && !selected.text.contains("different design"))
        let given = try document.prepare(q, selectionHint: "The first endpoint is final signal.")
        try check(given.first?.text == selected.text)
        let uniqueEnd = try document.prepare("翻译 Based on 到 first endpoint 的内容")
        try check(uniqueEnd.first?.text.hasPrefix("Based on three") == true)
        let withCaption = try document.prepare(q + "，并包含图注", chosenRangeID: first.id)
        try check(withCaption.first?.text.contains("Fig. 1 An independent experiment.") == true)
        try rejects(try document.prepare(q, chosenRangeID: "1:2"), containing: "已变化")
        let noisy = try index([page(1, [block(Array(repeating: "BEGIN. ", count: 80).joined() + "The last word is END.")])])
        do {
            _ = try noisy.prepare("从 BEGIN 到 END")
            throw Failure.assertion("Incomplete matching cannot prove a winner")
        } catch let choices as ResearchPDFRangeAmbiguity {
            try check(choices.truncated && choices.candidates.count == 6)
        }
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
        // A second START after the only FINISH cannot be the requested ordered range.
        let ordered = try index([valid, page(2, [block("START occurs in a citation.", kind: .reference)])])
        try check(try ordered.prepare("从 START 到 FINISH").first?.text == "START occurs before FINISH")
        try rejects([page(1, [block("START one"), block("START two before FINISH")])], "从 START 到 FINISH", "至少出现两次")
        try rejects([page(1, [block("START occurs here.")]), page(2, [], state: .needsOCR),
                     page(3, [block("Then FINISH appears.")])], "从 START 到 FINISH", "第 2 页")
        try rejects([page(1, [block("START"), block("Uncertain OCR", reliable: false), block("FINISH")], state: .ocr)], "从 START 到 FINISH", "无法可靠")
        try rejects([page(1, [block("START here; FINISH there")], reliable: false)], "从 START 到 FINISH", "无法可靠")
    }

    func testVerifiedRangePlanningAndScopedDuplicates() throws {
        let passage = "The path to zinc spans two pages.\n\nA meter's reading reaches the XYZ method without bias"
        let doc = try index([page(1, [block("Keep out. The path to zinc spans two pages.", column: 2)]),
                             page(2, [block("A meter's reading reaches the XYZ method without bias. Omit.", column: 1)])])
        let variants = ["翻译从 The path to zinc 到 XYZ method without bias 的全部内容。",
                        "所选文章的The path to zinc到XYZ method without bias.这段内容翻译",
                        "请把以 The path to zinc 开头、到 XYZ method without bias 结束的原文翻译出来",
                        "Translate from The path to zinc through XYZ method without bias"]
        for q in variants { try check(try doc.prepare(q).map(\.text).joined() == passage) }
        try rejects(try doc.readRange(start: "The path to zinc", end: "FDTD method without bias"), containing: "FDTD")
        try check(try doc.readRange(start: "A meter’s reading", end: "XYZ method without bias", includeEnd: false).first?.text == "A meter's reading reaches the ")
        try check(try doc.prepare("从 “A meter’s reading” 到 “XYZ method without bias”，不含起点").first?.text == " reaches the XYZ method without bias")
        let quoted = try index([page(1, [block("Preface. The LMT model works. End marker. Omit.")])])
        for (l, r) in [("“", "”"), ("「", "」"), ("\"", "\""), ("‘", "’"), ("『", "』"), ("'", "'")] {
            let question = "Start with " + l + "LMT model works" + r + " and finish at " + l + "End marker" + r
            let plan = ResearchDocumentPlan(action: .range, start: "model", end: "End marker")
            try check(try plan.read(index: quoted, question: question, selection: nil, requireSelection: false).first?.text
                      == "LMT model works. End marker")
        }
        let repeated = try index([page(1, [block("1. Introduction", kind: .heading), block("START alpha FINISH")]),
                                  page(2, [block("2. Methods", kind: .heading), block("START beta FINISH")]),
                                  page(3, [block("3. Results", kind: .heading), block("START gamma FINISH")])])
        do {
            _ = try repeated.readRange(start: "START", end: "FINISH")
            throw Failure.assertion("Repeated endpoints need a page, section, or confirmed choice")
        } catch let choices as ResearchPDFRangeAmbiguity {
            try check(choices.candidates.contains { $0.startPage == 2 && $0.endPage == 2 && $0.section?.contains("methods") == true })
        }
        try check(try repeated.readRange(start: "START", end: "FINISH", withinPages: 2...2).first?.text == "START beta FINISH")
        try check(try repeated.readRange(start: "START", end: "FINISH", section: "methods").first?.text == "START beta FINISH")
        try check(try repeated.prepare("第2页中从 START 到 FINISH").first?.text == "START beta FINISH")
        try check(repeated.documentOutline.count == 3)
        try check(try repeated.readPages(2...2).first?.text == "2. Methods\n\nSTART beta FINISH")
        try check(try repeated.searchEvidence("gamma").text.contains("gamma"))
        let gap = try index([page(1, [block("OPEN text")]), page(2, [], state: .needsOCR), page(3, [block("CLOSE tick")])])
        try rejects(try gap.readRange(start: "OPEN", end: "CLOSE"), containing: "第 2 页")
        try check(try gap.readRange(start: "CLOSE", end: "tick", withinPages: 3...3).first?.text == "CLOSE tick")
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
        try check(parts.allSatisfy { $0.text.utf16.count <= 7_200 && $0.pdfPositions?.isEmpty == false })
        try check(parts.map(\.text).joined() == target)
    }

    func testScopedParagraphCountAndConcepts() throws {
        let doc = try index([
            page(1, [block("1. Introduction", kind: .heading), block("Unrelated introduction."),
                     block("2. Methods", kind: .heading), block("First paragraph of the procedure."),
                     block("The second paragraph explains Fig. 3 without resolving it as an object.")]),
            page(2, [block("The third paragraph describes the asymptotic complexity."),
                     block("Fig. 3. Unrelated caption.", kind: .caption),
                     block("3. Results", kind: .heading), block("The experiments are separate.")])
        ])
        let request = "翻译第二节最后两个自然段，其中提到 Fig. 3"
        try check(ResearchPDFAddress.parse(request).addressesPassage)
        let span = try unwrap(doc.prepare(request).first)
        try check(span.text == "The second paragraph explains Fig. 3 without resolving it as an object.\n\nThe third paragraph describes the asymptotic complexity.")
        try check(span.pdfPositions?.map(\.page) == [1, 2])
        let opening = try unwrap(doc.prepare("Read the first two paragraphs of section 2").first)
        try check(opening.text.hasPrefix("First paragraph of the procedure."))
        try check(!opening.text.contains("third paragraph"))
        try rejects(try doc.prepare("读方法部分最后四段"), containing: "没有足够")
        let evidence = try doc.searchEvidence("文中关于计算复杂度的主要结论是什么")
        try check(evidence.text.contains("asymptotic complexity"))
        try check(evidence.pdfPositions?.contains { $0.page == 2 } == true)
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
        let pair: [ResearchPDFObjectID] = [.init(kind: .figure, number: "2"), .init(kind: .equation, number: "3")]
        try check(doc.supportingObjectRelation(pair, near: [1, 3]) == nil)
        let link = "The geometry in Fig. 2 gives the boundary used in Eq. (3)."
        let connected = try index([
            page(1, [block("Unrelated description of Fig. 2."), block("Isolated equation Eq. (3)."),
                     block("Fig. 2. Wrong caption matches Eq. (3).", kind: .caption)]),
            page(2, [block(link)])
        ])
        let exact = try unwrap(connected.supportingObjectRelation(pair, near: [1]))
        try check(exact.pdfPositions?.map(\.page) == [2])
        try check(exact.verifiedExcerpts?.compactMap { $0.text(in: exact.text) } == [link])
        try check(!exact.text.contains("Wrong caption"))
    }
}
