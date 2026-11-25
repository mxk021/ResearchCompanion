import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count > 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[0]) as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil),
      master.width == 1024, master.height == 1024 else {
    fputs("Usage: render-app-icon.swift 1024px-master.png output-directory pixel-size ...\n", stderr)
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func writePNG(_ image: CGImage, named name: String) -> Bool {
    let url = directory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// Derive the chrome glyph from the approved Dock art. Keep the original silhouette
/// and antialiased edges while turning the white tile and the two openings transparent.
func monochromeMark(from master: CGImage) -> CGImage? {
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let width = master.width
    let height = master.height
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo),
          let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self)
    else { return nil }
    bitmap.draw(master, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let pixel = pixels + y * bitmap.bytesPerRow + x * 4
            let luminance = 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
            let ink = (Double(pixel[3]) - luminance) / 255
            // Premultiplied colour makes the transparent corners contribute no ink.
            // A short soft threshold removes near-white tile noise and keeps the waist solid.
            let t = min(1, max(0, (ink - 0.04) / 0.55))
            let coverage = UInt8((255 * t * t * (3 - 2 * t)).rounded())
            pixel[0] = 0
            pixel[1] = 0
            pixel[2] = 0
            pixel[3] = coverage
            if coverage > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    let size = 256
    let edgeRadius = 5
    let glyphSide = CGFloat(210 - 2 * edgeRadius)
    guard minX < maxX, minY < maxY,
          let silhouette = bitmap.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1,
                                                                     height: maxY - minY + 1)),
          let output = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)
    else { return nil }
    let scale = glyphSide / CGFloat(max(silhouette.width, silhouette.height))
    let glyphWidth = CGFloat(silhouette.width) * scale
    let glyphHeight = CGFloat(silhouette.height) * scale
    output.interpolationQuality = .high
    output.draw(silhouette, in: CGRect(x: (CGFloat(size) - glyphWidth) / 2, y: (CGFloat(size) - glyphHeight) / 2,
                                      width: glyphWidth, height: glyphHeight))

    // Five 256px template pixels add less than half a point at 22pt and keep
    // the narrow inner edges connected in 1× menu-bar rasterization.
    guard let outputPixels = output.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let rowBytes = output.bytesPerRow
    let original = Array(UnsafeBufferPointer(start: outputPixels, count: rowBytes * size))
    var neighbours: [Int] = []
    for dy in -edgeRadius...edgeRadius {
        for dx in -edgeRadius...edgeRadius where dx * dx + dy * dy <= edgeRadius * edgeRadius {
            neighbours.append(dy * rowBytes + dx * 4)
        }
    }
    for y in edgeRadius..<(size - edgeRadius) {
        for x in edgeRadius..<(size - edgeRadius) {
            let index = y * rowBytes + x * 4 + 3
            var coverage = original[index]
            for offset in neighbours {
                if coverage == 255 { break }
                coverage = max(coverage, original[index + offset])
            }
            outputPixels[index] = coverage
        }
    }
    return output.makeImage()
}

guard let mark = monochromeMark(from: master), writePNG(mark, named: "ResearchCompanionMark.png") else { exit(1) }

for argument in arguments.dropFirst(2) {
    guard let size = Int(argument), (16...1024).contains(size),
          let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { exit(2) }
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage(), writePNG(image, named: "icon-\(size).png") else { exit(1) }
}
