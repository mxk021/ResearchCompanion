import AppKit
import SwiftUI

@MainActor
struct ResearchBrandMark: View {
    let size: CGFloat

    // The packager derives this mask from the same master as the Dock icon.
    private static let artwork = Bundle.main.url(forResource: "ResearchCompanionMark",
        withExtension: "png", subdirectory: "Transcript").flatMap(NSImage.init(contentsOf:))

    static func statusImage(artwork override: NSImage? = nil) -> NSImage {
        let artwork = override ?? Self.artwork
        let source = artwork ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let image = (source.copy() as? NSImage) ?? NSImage(size: NSSize(width: 22, height: 22))
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = artwork != nil
        image.accessibilityDescription = "Research Companion"
        return image
    }

    var body: some View {
        Image(nsImage: Self.artwork ?? NSApp.applicationIconImage)
            .renderingMode(Self.artwork == nil ? .original : .template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
