import AppKit
import CoreText
import PDFKit

/// Draw each row's RIGHT column before its LEFT column. The PDF paint order deliberately
/// disagrees with both the visual order and the paragraphs expected by the test.
@main
struct PDFLayoutCheck {
    static func main() throws {
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes)!
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: consumer, mediaBox: &media, nil)!
        func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 12) {
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), context)
        }
        context.beginPDFPage(nil)
        line("A spanning title for the geometry study", x: 115, y: 735, size: 20)
        let left = ["Left one opens a sentence.", "Left two extends that sentence.", "Left three finishes the paragraph."]
        let right = ["Right one opens a new sentence.", "Right two follows the first.", "Right three finishes on this page."]
        for n in left.indices {
            let y = CGFloat(650 - 17 * n)
            line(right[n], x: 327, y: y)
            line(left[n], x: 48, y: y)
        }
        line("A full-width band introducing the equations", x: 145, y: 548, size: 16)
        line("Table 3. Stable coefficients", x: 48, y: 500)
        line("Right four resumes below the band.", x: 327, y: 500)
        line("y = a + b", x: 48, y: 480)
        line("Right five concludes the table.", x: 327, y: 480)
        line("Copyright: Synthetic publication.", x: 48, y: 190, size: 10)
        line("Terms of distribution follow the copyright notice.", x: 48, y: 174, size: 8)
        line("The main article continues in the opposite column.", x: 327, y: 167, size: 10)
        line("Correspondence: Test editor", x: 48, y: 130, size: 8)
        line("14", x: 300, y: 25, size: 8)
        context.endPDFPage()
        context.beginPDFPage(nil)
        for y: CGFloat in [700, 682, 664] {
            line("Left lane observation", x: 28, y: y)
            line("Middle lane observation", x: 211, y: y)
            line("Right lane observation", x: 410, y: y)
        }
        context.endPDFPage()
        context.beginPDFPage(nil)
        line("References", x: 48, y: 713, size: 18)
        line("1. Author. Synthetic experiment.", x: 48, y: 672)
        context.endPDFPage()
        context.beginPDFPage(nil)
        line("2. Author. Additional experiment.", x: 48, y: 680)
        context.endPDFPage()
        context.beginPDFPage(nil)
        let leftBody = [
            "The setup uses two calibrated light detectors.",
            "The first trial is used to measure the noise floor.",
            "Each iteration collects a forward measurement",
        ]
        let rightBody = [
            "with the initial bias, then one reverse reading.",
            "Both signals are kept for comparison after the run.",
            "The deviation is computed at the end of each trial.",
        ]
        for n in leftBody.indices {
            line(rightBody[n], x: 320, y: CGFloat(501 - 15 * n))
            line(leftBody[n], x: 48, y: CGFloat(501 - 15 * n))
        }
        let picture = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 32,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        picture.setFillColor(gray: 0.6, alpha: 1)
        picture.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        context.draw(picture.makeImage()!, in: CGRect(x: 54, y: 128, width: 208, height: 305))
        let graphicLabels = ["Detector layout", "Measured field", "Probe", "Bias"]
        line(graphicLabels[0], x: 116, y: 444, size: 10)
        line(graphicLabels[1], x: 57, y: 350, size: 10)
        line(graphicLabels[2], x: 192, y: 350, size: 10)
        line(graphicLabels[3], x: 117, y: 196, size: 10)
        let captionLines = [
            "Fig. 4. Geometry of the two detector configurations.",
            "Each thermometer is mounted on a separate",
            "fixture that isolates its response when the driver",
            "is connected to the circuit.",
        ]
        for (n, text) in captionLines.enumerated() {
            line(text, x: 48, y: CGFloat(94 - 12 * n), size: 11)
        }
        line("17", x: 48, y: 25, size: 8)
        context.endPDFPage()
        context.closePDF()
        let pdf = PDFDocument(data: bytes as Data)!
        var inReferences = false
        func read(_ i: Int, checkGraphics: Bool = false) throws -> (blocks: [ResearchPDFBlock], reliableOrder: Bool) {
            let page = pdf.page(at: i)!
            let geometry = ResearchPDFLayout.Geometry(page)
            let fragments = try ResearchPDFLayout.native(page, text: page.string!, geometry: geometry)
            let output = ResearchPDFLayout.blocks(fragments, geometry: geometry, pageNumber: i + 1,
                                                 inReferences: &inReferences, page: checkGraphics ? page : nil)
            let raw = page.string! as NSString
            for item in output.blocks.flatMap(\.lines) {
                precondition(!item.bounds.isEmpty && !item.sourceRanges.isEmpty && !item.ocr)
                let ranges = item.sourceRanges.map { raw.substring(with: $0) }
                precondition(ranges.allSatisfy { item.text.contains($0) })
            }
            return output
        }
        let first = try read(0)
        precondition(first.reliableOrder)
        let labels = first.blocks.flatMap { b in b.lines.map { ($0.text, b.column, b.kind) } }
        precondition(labels.filter { $0.0.hasPrefix("Left") || $0.0.hasPrefix("Right") }.map { $0.0 } ==
            left + right + ["Right four resumes below the band.", "Right five concludes the table."])
        for (text, column, _) in labels {
            if left.contains(text) { precondition(column == 1) }
            if right.contains(text) { precondition(column == 2) }
        }
        precondition(labels.contains { $0.0.hasPrefix("A full-width band") && $0.1 == 0 })
        precondition(labels.contains { $0.0 == "y = a + b" && $0.2 == .formula })
        precondition(labels.contains { $0.0.hasPrefix("Table 3.") && $0.2 == .table })
        precondition(labels.contains { $0.0.hasPrefix("Terms of distribution") && $0.1 == 1 && $0.2 == .footnote })
        precondition(labels.contains { $0.0.hasPrefix("The main article continues") && $0.1 == 2 && $0.2 == .body })
        precondition(labels.contains { $0.0.hasPrefix("Correspondence:") && $0.2 == .footnote })
        precondition(labels.contains { $0.0 == "14" && $0.2 == .footer })
        let threeColumns = try read(1)
        precondition(!threeColumns.reliableOrder)
        let references = try read(2)
        let continued = try read(3)
        precondition(references.blocks.contains { $0.kind == .reference } && continued.blocks.first?.kind == .reference)
        inReferences = false
        let floating = try read(4, checkGraphics: true)
        precondition(floating.reliableOrder)
        precondition(floating.blocks.filter { $0.kind == .figureLabel }.flatMap(\.lines).map(\.text) == graphicLabels)
        precondition(floating.blocks.filter { $0.kind == .caption && $0.detachedCaption }
            .flatMap(\.lines).map(\.text) == captionLines)
        precondition(floating.blocks.filter { $0.kind == .body }.flatMap(\.lines).map(\.text) == leftBody + rightBody)
        print("PASS synthetic spanning bands, column order, detached raster figure and caption continuation, native ranges, formulas, footnotes, references and ambiguous three-column layout.")
    }
}
