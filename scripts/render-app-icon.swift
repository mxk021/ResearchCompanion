import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original Research Companion artwork. Coordinates are in a bottom-up
// 1024-point design space. Every icon representation is drawn at its own size.
private let palette = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
        green: CGFloat((rgb >> 8) & 0xff) / 255,
        blue: CGFloat(rgb & 0xff) / 255,
        alpha: alpha
    )
}

private func shape(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

private func fill(_ context: CGContext, _ path: CGPath, _ rgb: UInt32) {
    context.setFillColor(color(rgb))
    context.addPath(path)
    context.fillPath()
}

private func render(_ pixels: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: palette, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 74, y: 74, width: 876, height: 876),
                      cornerWidth: 210, cornerHeight: 210, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let tint = CGGradient(colorsSpace: palette, colors: [color(0x284c68), color(0x142639)] as CFArray,
                          locations: [0, 1])!
    context.drawLinearGradient(tint, start: CGPoint(x: 200, y: 950), end: CGPoint(x: 790, y: 170),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0x93b0c6, alpha: 0.40))
    context.setLineWidth(8)
    context.strokePath()

    // A page with a large fold and one marked passage. The silhouette and the
    // accent carry the design at 16 px, where fine details disappear.
    fill(context, shape([
        CGPoint(x: 310, y: 251), CGPoint(x: 718, y: 251), CGPoint(x: 718, y: 658),
        CGPoint(x: 583, y: 793), CGPoint(x: 310, y: 793),
    ]), 0xf4f5ee)
    fill(context, shape([
        CGPoint(x: 583, y: 793), CGPoint(x: 718, y: 658), CGPoint(x: 583, y: 658),
    ]), 0x9ab6c3)
    for (bounds, rgb) in [
        (CGRect(x: 366, y: 550, width: 175, height: 42), UInt32(0x547588)),
        (CGRect(x: 280, y: 442, width: 369, height: 70), UInt32(0x62c9b3)),
        (CGRect(x: 366, y: 341, width: 229, height: 42), UInt32(0x547588)),
    ] {
        fill(context, CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2,
                            cornerHeight: bounds.height / 2, transform: nil), rgb)
    }
    return context.makeImage()
}

let arguments = CommandLine.arguments.dropFirst()
guard let directory = arguments.first, arguments.count > 1 else {
    fputs("Usage: render-app-icon.swift output-directory pixel-size ...\n", stderr)
    exit(2)
}
for argument in arguments.dropFirst() {
    guard let size = Int(argument), (16...1024).contains(size), let image = render(size) else { exit(2) }
    let output = URL(fileURLWithPath: directory).appendingPathComponent("icon-\(size).png")
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString,
                                                          1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}
