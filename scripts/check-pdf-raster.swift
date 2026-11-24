import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

// The production rasterizer only references this one error constructor.
enum ResearchMaterialError: Error { case message(String) }

@main
struct PDFRasterCheck {
    static func main() throws {
        for rotation in [0, 90, 180, 270] {
            let bytes = pdf(rotation: rotation, composite: true)
            let page = PDFDocument(data: bytes)!.page(at: 0)!
            let raw = page.bounds(for: .cropBox)
            let canvas = CGRect(origin: .zero, size: rotation % 180 == 90
                ? CGSize(width: raw.height, height: raw.width) : raw.size)
            let original = page.pageRef!
            let display = original.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
            precondition(ResearchPDFCropRenderer.requiresAlternate(original))
            let crop = CGRect(x: 45, y: 95, width: 225, height: 240).applying(display)
            let image = try ResearchPDFCropRenderer.alternateImage(bytes: bytes, pageIndex: 0, canvas: canvas,
                                                                   display: display, crop: crop, scale: 2)
            precondition(image.width == Int(crop.width * 2) && image.height == Int(crop.height * 2))
            let data = image.dataProvider!.data!
            func rgb(_ raw: CGPoint) -> [UInt8] {
                let point = raw.applying(display)
                let x = Int((point.x - crop.minX) * 2)
                let y = Int((crop.maxY - point.y) * 2)
                let i = y * image.bytesPerRow + x * 4
                let buffer = CFDataGetBytePtr(data)!
                return [buffer[i + 2], buffer[i + 1], buffer[i]]
            }
            precondition(rgb(CGPoint(x: 75, y: 135)) == [255, 0, 0])
            precondition(rgb(CGPoint(x: 226, y: 296)) == [0, 0, 255])
            precondition(rgb(CGPoint(x: 122, y: 222)) == [0, 255, 0])
            precondition(rgb(CGPoint(x: 128, y: 229)) == [255, 255, 255])
            let fingerprint = SHA256.hash(data: bytes).description
            guard let glyphs = try ResearchPDFCropRenderer.glyphPage(fingerprint: fingerprint, pageIndex: 0,
                canvas: canvas, display: display, verifiedBytes: { bytes })
            else { preconditionFailure("No independent glyphs for rotated crop \(rotation)") }
            let line = CGRect(x: 48, y: 175, width: 215, height: 20)
            let w = glyphs.glyphs(in: line).filter { $0.scalar == "T" }
            precondition(w.count == 1 && line.contains(w[0].bounds))
            precondition(glyphs.containsSymbol("T", within: line))
            precondition(!glyphs.containsSymbol("T", within: CGRect(x: 58, y: 198, width: 110, height: 20)))
            precondition(glyphs.containsSymbol("T", within: CGRect(x: 55, y: 233, width: 80, height: 30)))
            precondition(glyphs.glyphs(in: CGRect(x: 0, y: 5, width: 70, height: 20)).isEmpty)
            let cached = try ResearchPDFCropRenderer.glyphPage(fingerprint: fingerprint, pageIndex: 0,
                canvas: canvas, display: display, verifiedBytes: { preconditionFailure("Cached glyphs reopened PDF") })
            precondition(glyphs === cached)
            if rotation == 0 {
                let recovered = glyphs.recovering(line: "where is the coefficient", within: line, requiredSymbols: ["T"])
                precondition(recovered?.text == "where T is the coefficient" && recovered?.symbols == ["T"])
                precondition(glyphs.recovering(line: "where is the coefficient", within: line, requiredSymbols: ["X"]) == nil)
                precondition(glyphs.recovering(line: "where is the coefficie", within: line, requiredSymbols: ["T"]) == nil)
                precondition(glyphs.recovering(line: "where is the derivative", within: line, requiredSymbols: ["T"]) == nil)
                let missingPage = try ResearchPDFCropRenderer.glyphPage(fingerprint: fingerprint, pageIndex: 1,
                    canvas: canvas, display: display, verifiedBytes: { bytes })
                precondition(missingPage == nil)
                let wrongDisplay = try ResearchPDFCropRenderer.glyphPage(fingerprint: fingerprint, pageIndex: 0,
                    canvas: canvas, display: display.translatedBy(x: 3, y: 3), verifiedBytes: { bytes })
                precondition(wrongDisplay == nil)
            }
        }
        let ordinary = PDFDocument(data: pdf(rotation: 0, composite: false))!.page(at: 0)!
        precondition(!ResearchPDFCropRenderer.requiresAlternate(ordinary.pageRef!))
        print("PDF raster and glyphs: inherited resources, offset CropBox, four rotations, tiled pixels, native ordinary path, exact local Unicode recovery and cache isolation.")
    }

    private static func pdf(rotation: Int, composite: Bool) -> Data {
        func stream(_ dictionary: String, _ commands: String) -> String {
            "<< \(dictionary) /Length \(commands.utf8.count) >>\nstream\n\(commands)\nendstream"
        }
        let layer = composite ? "/XObject << /Layer 5 0 R >> " : ""
        let resources = "/Resources << /Font << /F1 7 0 R >> \(layer)>> "
        let shapes = "1 0 0 rg 65 120 35 35 re f\n0 0 1 rg 205 280 35 35 re f"
            + "\n0 0 0 rg BT /F1 12 Tf 60 185 Td (where T is the coefficient) Tj"
            + "\n0 24 Td (ATOMIC body text) Tj -55 -194 Td (T cropped out) Tj ET"
            + "\nBT /F1 12 Tf 62 243 Td (q) Tj /F1 9 Tf 7 7 Td (T) Tj /F1 12 Tf 8 -7 Td (r) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 \(resources)>>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 450] /CropBox [20 30 320 370] /Rotate \(rotation) /Contents 4 0 R >>",
            stream("", shapes + (composite ? "\n/Layer Do" : "")),
            stream("/Type /XObject /Subtype /Form /BBox [100 210 160 265] /Group << /S /Transparency /CS /DeviceRGB /I true >> /Resources << /Pattern << /Tile 6 0 R >> >>",
                   "/Pattern cs /Tile scn 100 210 60 55 re f"),
            stream("/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
                   "0 1 0 rg 0 0 4 4 re f"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let table = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(text.utf8)
    }
}
