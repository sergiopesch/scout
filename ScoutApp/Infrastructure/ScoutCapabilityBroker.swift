import ApplicationServices
import CoreGraphics
import Foundation
import Observation

enum ScoutSystemCapability: String, CaseIterable, Identifiable, Sendable {
    case screenObservation
    case accessibilityControl

    var id: Self { self }

    var title: String {
        switch self {
        case .screenObservation: "See the screen"
        case .accessibilityControl: "Accessibility permission preflight"
        }
    }

    var detail: String {
        switch self {
        case .screenObservation:
            "Allows explicitly requested screen observations. Raw pixels stay local and out of handoff by default."
        case .accessibilityControl:
            "Checks or requests the macOS grant that a future, separately reviewed action adapter would require. Scout does not currently implement external Accessibility actions."
        }
    }

    var symbol: String {
        switch self {
        case .screenObservation: "eye"
        case .accessibilityControl: "cursorarrow.motionlines"
        }
    }
}

enum ScoutCapabilityStatus: String, Sendable {
    case authorized
    case permissionRequired

    var label: String {
        switch self {
        case .authorized: "Permission granted"
        case .permissionRequired: "Permission required"
        }
    }
}

/// Permission broker and preflight for future external perception/action adapters.
///
/// Merely constructing Scout never prompts. Each macOS consent prompt is reached only through the
/// corresponding explicit controller action, and the two grants remain independent. An authorized
/// Accessibility status means only that macOS granted permission; Scout has no external action
/// adapter today.
@MainActor
@Observable
final class ScoutCapabilityBroker {
    private(set) var statuses: [ScoutSystemCapability: ScoutCapabilityStatus] = [:]

    init() {
        refresh()
    }

    func refresh() {
        statuses[.screenObservation] = CGPreflightScreenCaptureAccess()
            ? .authorized
            : .permissionRequired
        statuses[.accessibilityControl] = AXIsProcessTrusted()
            ? .authorized
            : .permissionRequired
    }

    func request(_ capability: ScoutSystemCapability) {
        switch capability {
        case .screenObservation:
            _ = CGRequestScreenCaptureAccess()
        case .accessibilityControl:
            // The public constant's value is stable, while reading the imported CF global trips
            // Swift 6 strict-concurrency diagnostics. This dictionary is built and consumed on the
            // main actor only, after an explicit user action.
            _ = AXIsProcessTrustedWithOptions([
                "AXTrustedCheckOptionPrompt": true,
            ] as CFDictionary)
        }
        refresh()
    }

    func status(for capability: ScoutSystemCapability) -> ScoutCapabilityStatus {
        statuses[capability] ?? .permissionRequired
    }
}
