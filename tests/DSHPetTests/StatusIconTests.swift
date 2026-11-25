import AppKit
import XCTest
@testable import DSHPet

@MainActor
final class StatusIconTests: XCTestCase {
    func testStatusBarUsesASizedTemplateWithoutChangingTheSharedArtwork() {
        let size = NSSize(width: 256, height: 256)
        let artwork = NSImage(size: size)
        let icon = ResearchBrandMark.statusImage(artwork: artwork)

        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 22, height: 22))
        XCTAssertFalse(artwork.isTemplate)
        XCTAssertEqual(artwork.size, size)
    }
}
