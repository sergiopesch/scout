import Foundation

enum LauncherCommandAccess: Equatable {
    case ordinary
    case authenticationRequired
    case unavailable
}

/// Security policy shared by the packaged launcher and its focused regression harness.
///
/// The launcher deliberately starts children from a small environment instead of inheriting the
/// caller's process-loader, provider, proxy, or Scout configuration. Persistent credentials are
/// added only by the trusted launcher after this policy has discarded ambient values.
enum LauncherSecurityPolicy {
    static let productionOpenAIBaseURL = "https://api.openai.com/v1"
    static let productionRealtimeModel = "gpt-4o-mini-transcribe"
    static let productionDiarizationModel = "gpt-4o-transcribe-diarize"
    static let productionClaimsModel = "gpt-5.6-luna"

    private static let inheritedLocaleKeys: Set<String> = [
        "AppleLanguages",
        "AppleLocale",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TZ",
        "__CF_USER_TEXT_ENCODING",
    ]

    static func packagedGatewayEnvironment(
        parent: [String: String],
        trustedValues: [String: String]
    ) -> [String: String] {
        var environment = inheritedLocaleEnvironment(from: parent)
        environment.merge(trustedValues) { _, trusted in trusted }
        environment["OPENAI_BASE_URL"] = productionOpenAIBaseURL
        environment["OPENAI_REALTIME_MODEL"] = productionRealtimeModel
        environment["OPENAI_DIARIZATION_MODEL"] = productionDiarizationModel
        environment["OPENAI_CLAIMS_MODEL"] = productionClaimsModel
        return environment
    }

    static func packagedAppEnvironment(
        parent: [String: String],
        trustedValues: [String: String]
    ) -> [String: String] {
        var environment = inheritedLocaleEnvironment(from: parent)
        environment.merge(trustedValues) { _, trusted in trusted }
        return environment
    }

    static func commandAccess(
        arguments: [String],
        secretToolBuild: Bool,
        adHocProvisioningBuild: Bool
    ) -> LauncherCommandAccess {
        switch arguments {
        case ["secrets", "export"], ["secrets", "approval-export"]:
            return secretToolBuild ? .authenticationRequired : .unavailable
        case ["secrets", "import"]:
            return secretToolBuild || adHocProvisioningBuild
                ? .authenticationRequired
                : .unavailable
        case ["secrets", "rotate-approval"], ["secrets", "configure-openai"]:
            return .authenticationRequired
        case let values where values.count == 4
            && values[0] == "secrets"
            && values[1] == "revoke-approval"
            && values[3] == "--confirm-invalidates-packs":
            return .authenticationRequired
        default:
            return .ordinary
        }
    }

    private static func inheritedLocaleEnvironment(from parent: [String: String]) -> [String: String] {
        parent.reduce(into: [:]) { result, entry in
            if inheritedLocaleKeys.contains(entry.key) {
                result[entry.key] = entry.value
            }
        }
    }
}

enum LauncherManagedChild: Equatable {
    case gateway
    case app
}

/// Waits for either child without blocking exclusively on the UI process. Duplicate termination
/// notifications are harmless; the first observed child is the one the launcher treats as causal.
enum LauncherProcessSupervisor {
    static func firstExit(gateway: Process, app: Process) -> LauncherManagedChild {
        let race = TerminationRace()
        gateway.terminationHandler = { _ in race.record(.gateway) }
        app.terminationHandler = { _ in race.record(.app) }

        // A child can exit between `run()` and handler installation. Close that race explicitly.
        if !gateway.isRunning { race.record(.gateway) }
        if !app.isRunning { race.record(.app) }
        return race.wait()
    }
}

private final class TerminationRace: @unchecked Sendable {
    private let condition = NSCondition()
    private var winner: LauncherManagedChild?

    func record(_ child: LauncherManagedChild) {
        condition.lock()
        defer { condition.unlock() }
        guard winner == nil else { return }
        winner = child
        condition.signal()
    }

    func wait() -> LauncherManagedChild {
        condition.lock()
        defer { condition.unlock() }
        while winner == nil { condition.wait() }
        return winner!
    }
}
