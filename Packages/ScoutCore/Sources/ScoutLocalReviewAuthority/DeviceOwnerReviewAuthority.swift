import Foundation
import LocalAuthentication
import ScoutCore

/// One-shot Sendable boundary around `LAContext` for Swift task cancellation.
///
/// LocalAuthentication owns the evaluation's internal synchronization, and `invalidate()` is its
/// documented cross-callback cancellation mechanism. The box exposes no mutable context state.
private final class CancellableAuthenticationContext: @unchecked Sendable {
    let value = LAContext()

    init() {
        value.localizedCancelTitle = "Cancel"
    }

    func invalidate() {
        value.invalidate()
    }
}

public enum DeviceOwnerReviewAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case authenticationFailed
    case authenticationUnavailable

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Scout could not authenticate the local device owner for this review."
        case .authenticationUnavailable:
            "Device-owner authentication is unavailable for Scout reviews."
        }
    }
}

/// Cold-path authority for explicit canonical review decisions.
///
/// A fresh `LAContext` evaluates every exact-bound request. No context, success Boolean, signing
/// material, or injectable evaluator is exposed through the public API.
public struct DeviceOwnerReviewAuthority: Sendable {
    package typealias Evaluator = @Sendable (String) async throws -> Bool
    package typealias Clock = @Sendable () -> ScoutTimestamp

    private let evaluator: Evaluator
    private let clock: Clock

    public init() {
        evaluator = { reason in
            let context = CancellableAuthenticationContext()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let authenticated = try await context.value.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
                try Task.checkCancellation()
                return authenticated
            } onCancel: {
                // LocalAuthentication does not promise Swift task cancellation propagation.
                // Invalidating the one-shot context terminates the system policy evaluation.
                context.invalidate()
            }
        }
        clock = {
            ScoutTimestamp(millisecondsSinceUnixEpoch: Int64(
                (Date().timeIntervalSince1970 * 1_000).rounded(.down)
            ))
        }
    }

    package init(
        evaluator: @escaping Evaluator,
        clock: @escaping Clock
    ) {
        self.evaluator = evaluator
        self.clock = clock
    }

    public func authorize(_ intent: LocalReviewIntent) async throws -> AuthenticatedLocalReview {
        try Task.checkCancellation()
        let authenticated: Bool
        do {
            authenticated = try await evaluator(
                Self.authenticationReason(for: intent.operation)
            )
        } catch let error as LAError where Self.isCancellation(error.code) {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeviceOwnerReviewAuthorizationError.authenticationUnavailable
        }
        guard authenticated else {
            throw DeviceOwnerReviewAuthorizationError.authenticationFailed
        }
        try Task.checkCancellation()
        return AuthenticatedLocalReview(intent: intent, authenticatedAt: clock())
    }

    private static func authenticationReason(for operation: LocalReviewOperation) -> String {
        switch operation {
        case let .reviewClaim(review):
            let decision = review.status == .accepted ? "accept" : "reject"
            return "Authenticate to \(decision) Scout claim \(review.claimID.rawValue)."
        case let .reviewVisualObservation(review):
            let decision = review.disposition == .confirmed ? "confirm" : "reject"
            return "Authenticate to \(decision) Scout visual observation \(review.observationID.rawValue)."
        case let .attestLegacyReview(attestation):
            switch attestation.target {
            case let .claim(id):
                return "Authenticate to attest the legacy review of Scout claim \(id.rawValue)."
            case let .visualObservation(id):
                return "Authenticate to attest the legacy review of Scout visual observation \(id.rawValue)."
            }
        }
    }

    private static func isCancellation(_ code: LAError.Code) -> Bool {
        switch code {
        case .userCancel, .appCancel, .systemCancel:
            true
        default:
            false
        }
    }
}
