import XCTest
@testable import Scout

@MainActor
final class ScoutCapabilityBrokerTests: XCTestCase {
    func testInitializationAndRefreshUsePreflightStatusesWithoutRequestingPermission() {
        let broker = ScoutCapabilityBroker()

        XCTAssertEqual(Set(broker.statuses.keys), Set(ScoutSystemCapability.allCases))
        assertKnownPreflightStatuses(in: broker)

        broker.refresh()

        XCTAssertEqual(Set(broker.statuses.keys), Set(ScoutSystemCapability.allCases))
        assertKnownPreflightStatuses(in: broker)
    }

    func testAccessibilityCopyDescribesPermissionPreflightRatherThanImplementedActions() {
        XCTAssertEqual(
            ScoutSystemCapability.accessibilityControl.title,
            "Accessibility permission preflight"
        )
        XCTAssertTrue(
            ScoutSystemCapability.accessibilityControl.detail.contains(
                "does not currently implement external Accessibility actions"
            )
        )
        XCTAssertEqual(ScoutCapabilityStatus.authorized.label, "Permission granted")
    }

    private func assertKnownPreflightStatuses(in broker: ScoutCapabilityBroker) {
        for capability in ScoutSystemCapability.allCases {
            XCTAssertTrue(
                [ScoutCapabilityStatus.authorized, .permissionRequired]
                    .contains(broker.status(for: capability))
            )
        }
    }
}
