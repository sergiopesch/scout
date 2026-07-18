import XCTest
@testable import Scout

@MainActor
final class ScoutControllerTests: XCTestCase {
    func testOpeningAndSelectingSurfaceDeduplicatesAndRestoresCanonicalOrder() {
        let controller = ScoutController()

        controller.open(.evidence)
        controller.select(.evidence)

        XCTAssertEqual(controller.tabs.map(\.surface), ScoutSurface.allCases)
        XCTAssertEqual(controller.tabs.filter { $0.surface == .evidence }.count, 1)
        XCTAssertEqual(controller.selectedSurface, .evidence)

        controller.close(.discovery)
        controller.open(.discovery)

        XCTAssertEqual(controller.tabs.map(\.surface), ScoutSurface.allCases)
        XCTAssertEqual(controller.tabs.filter { $0.surface == .discovery }.count, 1)
        XCTAssertEqual(controller.selectedSurface, .discovery)
    }

    func testClosingSelectedTabSelectsNearestOpenNeighbor() {
        let controller = ScoutController(selectedSurface: .evidence)

        controller.close(.evidence)

        XCTAssertEqual(controller.tabs.map(\.surface), [.discovery, .actionPack])
        XCTAssertEqual(controller.selectedSurface, .actionPack)

        controller.close(.actionPack)

        XCTAssertEqual(controller.selectedSurface, .discovery)
    }

    func testClosingBackgroundTabPreservesSelection() {
        let controller = ScoutController(selectedSurface: .actionPack)

        controller.close(.discovery)

        XCTAssertEqual(controller.selectedSurface, .actionPack)
        XCTAssertEqual(controller.tabs.map(\.surface), [.evidence, .actionPack])
    }

    func testMinimizeMovesTabOutOfOpenCollectionAndRestoreSelectsIt() {
        let controller = ScoutController(selectedSurface: .evidence)

        controller.minimize(.evidence)

        XCTAssertEqual(controller.openTabs.map(\.surface), [.discovery, .actionPack])
        XCTAssertEqual(controller.minimizedTabs.map(\.surface), [.evidence])
        XCTAssertNotEqual(controller.selectedSurface, .evidence)
        XCTAssertTrue(controller.openTabs.contains { $0.surface == controller.selectedSurface })

        controller.restore(.evidence)

        XCTAssertEqual(controller.openTabs.map(\.surface), ScoutSurface.allCases)
        XCTAssertTrue(controller.minimizedTabs.isEmpty)
        XCTAssertEqual(controller.selectedSurface, .evidence)
    }

    func testMinimizingBackgroundTabPreservesSelectedSurface() {
        let controller = ScoutController(selectedSurface: .discovery)

        controller.minimize(.actionPack)

        XCTAssertEqual(controller.selectedSurface, .discovery)
        XCTAssertEqual(controller.minimizedTabs.map(\.surface), [.actionPack])
    }

    func testClosingEveryTabLeavesNoSelectionAndOpeningRecovers() {
        let controller = ScoutController(selectedSurface: .discovery)

        for surface in ScoutSurface.allCases {
            controller.close(surface)
        }

        XCTAssertTrue(controller.tabs.isEmpty)
        XCTAssertTrue(controller.openTabs.isEmpty)
        XCTAssertTrue(controller.minimizedTabs.isEmpty)
        XCTAssertNil(controller.selectedTabID)
        XCTAssertNil(controller.selectedSurface)

        controller.open(.actionPack)

        XCTAssertEqual(controller.tabs.map(\.surface), [.actionPack])
        XCTAssertEqual(controller.selectedSurface, .actionPack)
    }

    func testSceneCommandsDispatchOnlyTheirExactWindowRole() {
        let controller = ScoutController()
        var opened: [ScoutWindowRole] = []
        var closed: [ScoutWindowRole] = []
        var minimized: [ScoutWindowRole] = []
        var focused: [ScoutWindowRole] = []
        controller.installSceneActions(
            open: { opened.append($0) },
            close: { closed.append($0) },
            minimize: { minimized.append($0) },
            focus: { focused.append($0) }
        )

        controller.openWindow(.controlCenter)
        controller.closeWindow(.transcript)
        controller.minimizeWindow(.evidence)
        controller.focusWindow(.actionPack)

        XCTAssertEqual(opened, [.controlCenter])
        XCTAssertEqual(closed, [.transcript])
        XCTAssertEqual(minimized, [.evidence])
        XCTAssertEqual(focused, [.actionPack])
    }

    func testWindowLifecycleUpdatesOnlyReportedWindow() {
        let controller = ScoutController()
        let evidenceState = ScoutManagedWindowState(
            role: .evidence,
            isOpen: true,
            isMinimized: true,
            isKey: false
        )

        controller.windowStateDidChange(evidenceState)

        XCTAssertEqual(controller.windows[.evidence], evidenceState)
        XCTAssertEqual(
            controller.windows[.transcript],
            ScoutManagedWindowState(role: .transcript)
        )
    }

    func testPresentationTogglesAreIndependent() {
        let controller = ScoutController()

        controller.toggleSidebar()
        XCTAssertFalse(controller.isSidebarVisible)
        XCTAssertFalse(controller.isInspectorVisible)

        controller.toggleInspector()
        XCTAssertFalse(controller.isSidebarVisible)
        XCTAssertTrue(controller.isInspectorVisible)
    }
}
