import Foundation

public enum LocalReviewAuthorizationError: Error, Equatable, Sendable {
    case sessionMismatch(expected: SessionID, actual: SessionID)
    case missingTarget(LocalReviewTarget)
    case missingTargetEvent(LocalReviewTarget)
    case targetIsNotProposed(LocalReviewTarget)
    case targetIsNotTerminal(LocalReviewTarget)
    case missingReviewAttestation(LocalReviewTarget)
    case targetAlreadyAuthenticated(LocalReviewTarget)
    case invalidClaimDecision(ClaimID)
}

/// The exact canonical object whose state is being reviewed.
public enum LocalReviewTarget: Codable, Equatable, Sendable, CanonicalRepresentable {
    case claim(ClaimID)
    case visualObservation(VisualObservationID)

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .claim(id):
            .object(["type": .string("claim"), "id": id.canonicalValue])
        case let .visualObservation(id):
            .object(["type": .string("visualObservation"), "id": id.canonicalValue])
        }
    }
}

/// A deterministic request for a review. This is intent, not write authority.
public enum LocalReviewOperation: Equatable, Sendable, CanonicalRepresentable {
    case reviewClaim(ClaimReviewed)
    case reviewVisualObservation(VisualObservationReviewed)
    case attestLegacyReview(LocalReviewAttested)

    public var target: LocalReviewTarget {
        switch self {
        case let .reviewClaim(review): .claim(review.claimID)
        case let .reviewVisualObservation(review): .visualObservation(review.observationID)
        case let .attestLegacyReview(attestation): attestation.target
        }
    }

    public var canonicalValue: CanonicalValue { payload.canonicalValue }

    package var payload: ScoutEventPayload {
        switch self {
        case let .reviewClaim(review): .claimReviewed(review)
        case let .reviewVisualObservation(review): .visualObservationReviewed(review)
        case let .attestLegacyReview(attestation): .localReviewAttested(attestation)
        }
    }
}

/// Exact-bound input to the device-owner authentication surface.
///
/// The target event and state digest let the reducer reject a valid authentication grant if the
/// reviewed object changed while the system authentication prompt was visible. Unrelated capture
/// events do not invalidate the grant.
public struct LocalReviewIntent: Equatable, Sendable, CanonicalRepresentable {
    public let sessionID: SessionID
    public let eventID: EventID
    public let operation: LocalReviewOperation
    public let targetEventID: EventID
    public let targetStateHash: SHA256Digest

    package init(
        sessionID: SessionID,
        eventID: EventID,
        operation: LocalReviewOperation,
        targetEventID: EventID,
        targetStateHash: SHA256Digest
    ) {
        self.sessionID = sessionID
        self.eventID = eventID
        self.operation = operation
        self.targetEventID = targetEventID
        self.targetStateHash = targetStateHash
    }

    /// Builds an exact review intent from the canonical projection currently visible to Scout.
    ///
    /// The returned value still grants no write authority. It is safe to show to an authentication
    /// surface, which may exchange it for an opaque capability after device-owner authentication.
    public static func preparing(
        eventID: EventID,
        operation: LocalReviewOperation,
        in state: ScoutState
    ) throws -> LocalReviewIntent {
        let targetEventID: EventID
        let targetStateHash: SHA256Digest

        switch operation {
        case let .reviewClaim(review):
            let target = LocalReviewTarget.claim(review.claimID)
            guard let claim = state.claims[review.claimID] else {
                throw LocalReviewAuthorizationError.missingTarget(target)
            }
            guard claim.status == .proposed else {
                throw LocalReviewAuthorizationError.targetIsNotProposed(target)
            }
            let isTerminalDecision = switch (
                review.status,
                review.trust.validationStatus
            ) {
            case (.accepted, .validated), (.rejected, .rejected): true
            default: false
            }
            guard isTerminalDecision else {
                throw LocalReviewAuthorizationError.invalidClaimDecision(review.claimID)
            }
            guard let proposalEventID = state.claimEvents[review.claimID] else {
                throw LocalReviewAuthorizationError.missingTargetEvent(target)
            }
            targetEventID = proposalEventID
            targetStateHash = .hash(claim.canonicalValue)

        case let .reviewVisualObservation(review):
            let target = LocalReviewTarget.visualObservation(review.observationID)
            guard let observation = state.visualObservations[review.observationID] else {
                throw LocalReviewAuthorizationError.missingTarget(target)
            }
            guard observation.status == .proposed else {
                throw LocalReviewAuthorizationError.targetIsNotProposed(target)
            }
            guard let proposalEventID = state.visualObservationEvents[review.observationID] else {
                throw LocalReviewAuthorizationError.missingTargetEvent(target)
            }
            targetEventID = proposalEventID
            targetStateHash = .hash(observation.canonicalValue)

        case let .attestLegacyReview(attestation):
            switch attestation.target {
            case let .claim(claimID):
                let target = LocalReviewTarget.claim(claimID)
                guard let claim = state.claims[claimID] else {
                    throw LocalReviewAuthorizationError.missingTarget(target)
                }
                guard Self.isTerminalReviewedClaim(claim) else {
                    throw LocalReviewAuthorizationError.targetIsNotTerminal(target)
                }
                guard let reviewAttestation = state.claimReviewAttestations[claimID] else {
                    throw LocalReviewAuthorizationError.missingReviewAttestation(target)
                }
                guard case .legacyUnattested = reviewAttestation else {
                    throw LocalReviewAuthorizationError.targetAlreadyAuthenticated(target)
                }
                guard let reviewEventID = state.claimReviewEvents[claimID] else {
                    throw LocalReviewAuthorizationError.missingTargetEvent(target)
                }
                targetEventID = reviewEventID
                targetStateHash = .hash(claim.canonicalValue)

            case let .visualObservation(observationID):
                let target = LocalReviewTarget.visualObservation(observationID)
                guard let observation = state.visualObservations[observationID] else {
                    throw LocalReviewAuthorizationError.missingTarget(target)
                }
                guard observation.status == .confirmed || observation.status == .rejected else {
                    throw LocalReviewAuthorizationError.targetIsNotTerminal(target)
                }
                guard let reviewAttestation = state.visualObservationReviewAttestations[observationID]
                else {
                    throw LocalReviewAuthorizationError.missingReviewAttestation(target)
                }
                guard case .legacyUnattested = reviewAttestation else {
                    throw LocalReviewAuthorizationError.targetAlreadyAuthenticated(target)
                }
                guard let reviewEventID = state.visualObservationReviewEvents[observationID] else {
                    throw LocalReviewAuthorizationError.missingTargetEvent(target)
                }
                targetEventID = reviewEventID
                targetStateHash = .hash(observation.canonicalValue)
            }
        }

        return LocalReviewIntent(
            sessionID: state.sessionID,
            eventID: eventID,
            operation: operation,
            targetEventID: targetEventID,
            targetStateHash: targetStateHash
        )
    }

    public var operationHash: SHA256Digest { .hash(operation.canonicalValue) }

    static func isTerminalReviewedClaim(_ claim: Claim) -> Bool {
        switch (claim.status, claim.trust.validationStatus) {
        case (.accepted, .validated), (.rejected, .rejected): true
        default: false
        }
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "sessionID": sessionID.canonicalValue,
            "eventID": eventID.canonicalValue,
            "operation": operation.canonicalValue,
            "targetEventID": targetEventID.canonicalValue,
            "targetStateHash": targetStateHash.canonicalValue,
        ])
    }
}

/// Honest assurance label for the local review boundary.
///
/// This proves successful macOS device-owner authentication. It does not claim a named account or
/// organizational identity.
public enum LocalReviewAssurance: String, Codable, Sendable, CanonicalRepresentable {
    case deviceOwnerAuthentication

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public enum AuthenticatedReviewer: String, Codable, Sendable, CanonicalRepresentable {
    case localDeviceOwner

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

/// Non-secret audit record persisted with a review event.
public struct LocalReviewAuthorizationRecord: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: ReviewAuthorizationID
    public let assurance: LocalReviewAssurance
    public let reviewer: AuthenticatedReviewer
    public let sessionID: SessionID
    public let eventID: EventID
    public let target: LocalReviewTarget
    public let targetEventID: EventID
    public let targetStateHash: SHA256Digest
    public let operationHash: SHA256Digest
    public let authenticatedAt: ScoutTimestamp

    package init(intent: LocalReviewIntent, authenticatedAt: ScoutTimestamp) {
        let identity = SHA256Digest.hash(.object([
            "domain": .string("scout.local-review-authorization.v1"),
            "intent": intent.canonicalValue,
            "authenticatedAt": authenticatedAt.canonicalValue,
        ]))
        id = try! ReviewAuthorizationID(
            validating: "review-authorization-\(identity.rawValue)"
        )
        assurance = .deviceOwnerAuthentication
        reviewer = .localDeviceOwner
        sessionID = intent.sessionID
        eventID = intent.eventID
        target = intent.operation.target
        targetEventID = intent.targetEventID
        targetStateHash = intent.targetStateHash
        operationHash = intent.operationHash
        self.authenticatedAt = authenticatedAt
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "assurance": assurance.canonicalValue,
            "reviewer": reviewer.canonicalValue,
            "sessionID": sessionID.canonicalValue,
            "eventID": eventID.canonicalValue,
            "target": target.canonicalValue,
            "targetEventID": targetEventID.canonicalValue,
            "targetStateHash": targetStateHash.canonicalValue,
            "operationHash": operationHash.canonicalValue,
            "authenticatedAt": authenticatedAt.canonicalValue,
        ])
    }
}

/// Replay-visible assurance for a terminal local-review decision.
///
/// Legacy reviews remain canonical history, but callers must not treat them as equivalent to a
/// schema-v1.4 device-owner-authenticated decision.
public enum LocalReviewAttestation: Codable, Equatable, Sendable, CanonicalRepresentable {
    case legacyUnattested(schemaVersion: EventSchemaVersion)
    case deviceOwnerAuthenticated(LocalReviewAuthorizationRecord)

    public var isDeviceOwnerAuthenticated: Bool {
        if case .deviceOwnerAuthenticated = self { return true }
        return false
    }

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .legacyUnattested(schemaVersion):
            .object([
                "type": .string("legacyUnattested"),
                "schemaVersion": schemaVersion.canonicalValue,
            ])
        case let .deviceOwnerAuthenticated(record):
            .object([
                "type": .string("deviceOwnerAuthenticated"),
                "authorization": record.canonicalValue,
            ])
        }
    }
}

/// Runtime-only proof returned after successful device-owner authentication.
///
/// The initializer is package-scoped so clients importing `ScoutCore` cannot self-mint review
/// authority. The value is deliberately not `Codable` and contains no reusable bearer secret.
public struct AuthenticatedLocalReview: Equatable, Sendable {
    package let intent: LocalReviewIntent
    package let authorization: LocalReviewAuthorizationRecord

    package init(intent: LocalReviewIntent, authenticatedAt: ScoutTimestamp) {
        self.intent = intent
        authorization = LocalReviewAuthorizationRecord(
            intent: intent,
            authenticatedAt: authenticatedAt
        )
    }
}
