import XCTest
@testable import DSHPet

@MainActor
final class ResearchPanelPolicyTests: XCTestCase {
    func testExplicitResearchOpenCannotBeCollapsedByHoverOrQueuedTaskActions() {
        let model = DSHPetModel()
        model.openComposer(focus: true)
        XCTAssertTrue(model.isResearchPanelOpen)
        for hovering in [false, true, false, false] { model.setComposerHovering(hovering) }
        model.toggleTaskPanel(.active)
        model.toggleTaskPanel(.recent)
        model.closeTaskPanel()
        XCTAssertTrue(model.isResearchPanelOpen)
        XCTAssertEqual(model.barPhase, .composer)
        model.collapseComposer(reason: .test)
        XCTAssertFalse(model.isResearchPanelOpen)
        XCTAssertEqual(model.barPhase, .resting)
        model.setComposerHovering(true)
        XCTAssertEqual(model.barPhase, .hovering)
        model.setComposerHovering(false)
        XCTAssertEqual(model.barPhase, .resting)
    }
}
