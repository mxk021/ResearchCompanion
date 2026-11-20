import Foundation

enum ResearchWindowGeometry {
    static let minimumSize = NSSize(width: 428, height: 568)

    static func visibleFrame(for requested: NSRect, screens: [NSRect], fallback: NSRect) -> NSRect {
        let center = NSPoint(x: requested.midX, y: requested.midY)
        let originalScreen = screens.first { $0.contains(center) }
        let bounds = (originalScreen ?? fallback).insetBy(dx: 8, dy: 8)
        let width = min(max(requested.width, minimumSize.width), bounds.width)
        let height = min(max(requested.height, minimumSize.height), bounds.height)
        let x = originalScreen == nil ? bounds.midX - width / 2 : requested.minX
        let y = originalScreen == nil ? bounds.midY - height / 2 : requested.minY
        return NSRect(x: min(max(x, bounds.minX), bounds.maxX - width),
                      y: min(max(y, bounds.minY), bounds.maxY - height), width: width, height: height)
    }
}
