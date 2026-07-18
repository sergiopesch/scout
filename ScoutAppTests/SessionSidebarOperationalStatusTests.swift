import XCTest
@testable import Scout

@MainActor
final class SessionSidebarOperationalStatusTests: XCTestCase {
    func testPlayingDemoIsPresentedAsFictionalAndNeverAsActiveCapture() {
        let workspace = ScoutWorkspace()

        workspace.startDemoIfNeeded()

        XCTAssertTrue(workspace.isDemoWorkspace)
        XCTAssertEqual(workspace.captureState, .listening)

        let status = SessionSidebarOperationalStatus(workspace: workspace)

        XCTAssertEqual(status.title, "Fictional demo")
        XCTAssertEqual(status.detail, "No customer capture is active")
        XCTAssertEqual(status.tone, .gold)
        XCTAssertFalse(status.pulses)
        XCTAssertEqual(
            status.accessibilityLabel,
            "Fictional demo. No customer capture is active"
        )
    }
}
