import Foundation

/// The deterministic Scout capability that authorized an event commit.
///
/// `EventActor` remains provenance: Scout may attribute an utterance to a speaker or a proposal to
/// a model without granting either party mutation authority. This scope records which trusted Scout
/// command boundary accepted the operation.
public enum EventAuthorizationScope: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case sessionLifecycle
    case capturePipeline
    case evidenceImport
    case deterministicProjection
    case modelProjection
    case localReview
    case graphMaintenance

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public struct EventAuthorizationRecord: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let scope: EventAuthorizationScope
    public let component: NonEmptyString
    public let localReviewAuthorization: LocalReviewAuthorizationRecord?

    public init(
        scope: EventAuthorizationScope,
        component: NonEmptyString,
        localReviewAuthorization: LocalReviewAuthorizationRecord? = nil
    ) {
        self.scope = scope
        self.component = component
        self.localReviewAuthorization = localReviewAuthorization
    }

    public var canonicalValue: CanonicalValue {
        var object: [String: CanonicalValue] = [
            "scope": scope.canonicalValue,
            "component": component.canonicalValue,
        ]
        // Absence preserves the canonical bytes of schema 1.3 authorization records.
        if let localReviewAuthorization {
            object["localReviewAuthorization"] = localReviewAuthorization.canonicalValue
        }
        return .object(object)
    }
}

public enum SessionLifecycleCommand: Sendable {
    case start(DiscoverySession)
    case end(SessionEnded)
    case upsertSpeaker(Speaker)
}

public enum CapturePipelineCommand: Sendable {
    case finalizeUtterance(Utterance)
    case recordEvidence(Evidence)
}

public enum EvidenceImportCommand: Sendable {
    case record(Evidence)
}

public enum DeterministicProjectionCommand: Sendable {
    case upsertEntity(GraphEntity)
    case proposeClaim(Claim)
    case upsertRelationship(GraphRelationship)
}

public enum ModelProjectionCommand: Sendable {
    case recordCall(ModelCallReceipt)
    case proposeVisualObservation(VisualObservation)
    case upsertEntity(GraphEntity)
    case proposeClaim(Claim)
    case upsertRelationship(GraphRelationship)
}

public enum GraphMaintenanceCommand: Sendable {
    case retireEntity(EntityRetired)
    case removeRelationship(RelationshipRemoved)
}

/// Closed command union for all new canonical writes.
///
/// Callers choose a semantic capability, never an arbitrary actor/payload pair. The recorded actor
/// is derived from the command and is therefore attribution rather than the authorization credential.
public enum ScoutEventCommand: Sendable {
    case sessionLifecycle(
        component: NonEmptyString,
        operation: SessionLifecycleCommand
    )
    case capturePipeline(
        component: NonEmptyString,
        operation: CapturePipelineCommand
    )
    case evidenceImport(
        component: NonEmptyString,
        operation: EvidenceImportCommand
    )
    case deterministicProjection(
        component: NonEmptyString,
        operation: DeterministicProjectionCommand
    )
    case modelProjection(
        validator: NonEmptyString,
        model: ModelIdentity,
        operation: ModelProjectionCommand
    )
    case graphMaintenance(
        component: NonEmptyString,
        operation: GraphMaintenanceCommand
    )

    var resolved: ResolvedEventCommand {
        switch self {
        case let .sessionLifecycle(component, operation):
            let payload: ScoutEventPayload = switch operation {
            case let .start(session): .sessionStarted(session)
            case let .end(ended): .sessionEnded(ended)
            case let .upsertSpeaker(speaker): .speakerUpserted(speaker)
            }
            return systemResolved(scope: .sessionLifecycle, component: component, payload: payload)

        case let .capturePipeline(component, operation):
            switch operation {
            case let .finalizeUtterance(utterance):
                return ResolvedEventCommand(
                    actor: .speaker(utterance.speakerID),
                    authorization: .init(scope: .capturePipeline, component: component),
                    payload: .utteranceFinalized(utterance)
                )
            case let .recordEvidence(evidence):
                return systemResolved(
                    scope: .capturePipeline,
                    component: component,
                    payload: .evidenceRecorded(evidence)
                )
            }

        case let .evidenceImport(component, operation):
            let payload: ScoutEventPayload = switch operation {
            case let .record(evidence):
                .evidenceRecorded(Evidence(
                    id: evidence.id,
                    source: evidence.source,
                    excerpt: evidence.excerpt,
                    capturedAt: evidence.capturedAt,
                    capturedBy: .system(component: component)
                ))
            }
            return systemResolved(scope: .evidenceImport, component: component, payload: payload)

        case let .deterministicProjection(component, operation):
            let payload: ScoutEventPayload = switch operation {
            case let .upsertEntity(entity): .entityUpserted(entity)
            case let .proposeClaim(claim): .claimProposed(claim)
            case let .upsertRelationship(relationship): .relationshipUpserted(relationship)
            }
            return systemResolved(
                scope: .deterministicProjection,
                component: component,
                payload: payload
            )

        case let .modelProjection(validator, model, operation):
            let payload: ScoutEventPayload = switch operation {
            case let .recordCall(receipt): .modelCallRecorded(receipt)
            case let .proposeVisualObservation(observation):
                .visualObservationProposed(observation)
            case let .upsertEntity(entity): .entityUpserted(entity)
            case let .proposeClaim(claim): .claimProposed(claim)
            case let .upsertRelationship(relationship): .relationshipUpserted(relationship)
            }
            return ResolvedEventCommand(
                actor: .model(model),
                authorization: .init(scope: .modelProjection, component: validator),
                payload: payload
            )

        case let .graphMaintenance(component, operation):
            let payload: ScoutEventPayload = switch operation {
            case let .retireEntity(retirement): .entityRetired(retirement)
            case let .removeRelationship(removal): .relationshipRemoved(removal)
            }
            return systemResolved(scope: .graphMaintenance, component: component, payload: payload)
        }
    }

    private func systemResolved(
        scope: EventAuthorizationScope,
        component: NonEmptyString,
        payload: ScoutEventPayload
    ) -> ResolvedEventCommand {
        ResolvedEventCommand(
            actor: .system(component: component),
            authorization: .init(scope: scope, component: component),
            payload: payload
        )
    }
}

struct ResolvedEventCommand {
    let actor: EventActor
    let authorization: EventAuthorizationRecord
    let payload: ScoutEventPayload
}

/// Opaque proof that a new event originated from Scout's closed command boundary.
///
/// This value is deliberately not `Codable`. Persisted envelopes are decoded only for verified
/// replay and cannot be converted back into an appendable event through a public API.
public struct ValidatedScoutEvent: Equatable, Sendable {
    public let envelope: ScoutEventEnvelope

    init(envelope: ScoutEventEnvelope) {
        self.envelope = envelope
    }

    /// Verifies time-sensitive authority at the moment a canonical store will append the event.
    ///
    /// Replay checks the durable event timestamps. This separate live check prevents a caller from
    /// sealing a fresh review, retaining the validated value past its authorization window, and
    /// appending it later with an old `recordedAt` timestamp.
    public func validateAppendAuthorization(at appendTime: ScoutTimestamp) throws {
        guard envelope.authorization?.scope == .localReview,
              let authorization = envelope.authorization?.localReviewAuthorization
        else { return }

        func reject(_ failure: LocalReviewAuthorizationFailure) throws -> Never {
            throw ScoutEventAuthorizationError.localReviewAuthorization(
                eventID: envelope.id,
                failure: failure
            )
        }
        guard envelope.recordedAt <= appendTime else {
            try reject(.recordedInFuture)
        }
        guard authorization.authenticatedAt <= appendTime else {
            try reject(.authenticatedInFuture)
        }
        let elapsed = appendTime.millisecondsSinceUnixEpoch.subtractingReportingOverflow(
            authorization.authenticatedAt.millisecondsSinceUnixEpoch
        )
        guard !elapsed.overflow,
              elapsed.partialValue <= LocalReviewAuthorizationRules.maximumCommitDelayMilliseconds
        else {
            try reject(.expired)
        }
    }
}

public enum LocalReviewAuthorizationFailure: Equatable, Sendable {
    case missing
    case unexpected
    case componentMismatch
    case sessionMismatch
    case eventMismatch
    case targetMismatch
    case missingTargetEvent
    case targetEventMismatch
    case targetStateMismatch
    case targetIsNotProposed
    case targetIsNotTerminal
    case missingReviewAttestation
    case targetAlreadyAuthenticated
    case invalidDecision
    case operationMismatch
    case reused(ReviewAuthorizationID)
    case authenticatedInFuture
    case recordedInFuture
    case expired
    case unexpectedEventLinkage
}

public enum ScoutEventAuthorizationError: Error, Equatable, Sendable {
    case missingAuthorization(EventID)
    case scopePayloadMismatch(scope: EventAuthorizationScope, payloadKind: String)
    case actorMismatch(EventID)
    case modelReceiptIdentityMismatch(EventID)
    case modelProposalRequiresSuggestedTrust(EventID)
    case modelProposalNotBoundToReceipt(EventID)
    case modelReceiptLinkageRequiresModelProjection(EventID)
    case modelProjectionManifestRequired(EventID)
    case modelProposalPurposeMismatch(EventID)
    case modelProposalEvidenceOutsideInputBoundary(eventID: EventID, evidenceID: EvidenceID)
    case modelProposalCannotModifyProtectedEntity(eventID: EventID, entityID: EntityID)
    case modelProposalCannotSupersedeProtectedClaim(eventID: EventID, claimID: ClaimID)
    case modelProposalCannotModifyProtectedRelationship(
        eventID: EventID,
        relationshipID: RelationshipID
    )
    case evidenceProvenanceMismatch(EventID)
    case modelClaimAttributionMismatch(EventID)
    case localReviewAuthorization(
        eventID: EventID,
        failure: LocalReviewAuthorizationFailure
    )
}

enum ScoutEventAuthorizationPolicy {
    private static let localReviewComponent = "scout-macos-review-ui"

    static func validate(_ event: ScoutEventEnvelope, in state: ScoutState) throws {
        guard let authorization = event.authorization else {
            throw ScoutEventAuthorizationError.missingAuthorization(event.id)
        }
        guard payload(event.payload, isAllowedFor: authorization.scope) else {
            throw ScoutEventAuthorizationError.scopePayloadMismatch(
                scope: authorization.scope,
                payloadKind: event.payload.kind
            )
        }
        if authorization.scope != .localReview,
           authorization.localReviewAuthorization != nil
        {
            throw ScoutEventAuthorizationError.localReviewAuthorization(
                eventID: event.id,
                failure: .unexpected
            )
        }
        if authorization.scope != .modelProjection,
           [event.correlationID, event.causationID].compactMap({ $0 }).contains(where: {
               state.modelCallEvents[$0] != nil
           })
        {
            throw ScoutEventAuthorizationError.modelReceiptLinkageRequiresModelProjection(event.id)
        }

        switch authorization.scope {
        case .sessionLifecycle:
            try requireSystemActor(event, component: authorization.component)

        case .capturePipeline:
            switch event.payload {
            case let .utteranceFinalized(utterance):
                guard event.actor == .speaker(utterance.speakerID) else {
                    throw ScoutEventAuthorizationError.actorMismatch(event.id)
                }
            case let .evidenceRecorded(evidence):
                try requireSystemActor(event, component: authorization.component)
                guard case let .utterance(utteranceID) = evidence.source else {
                    throw ScoutEventAuthorizationError.evidenceProvenanceMismatch(event.id)
                }
                if let utterance = state.utterances[utteranceID],
                   evidence.capturedBy != .speaker(utterance.speakerID)
                {
                    throw ScoutEventAuthorizationError.evidenceProvenanceMismatch(event.id)
                }
            default:
                throw ScoutEventAuthorizationError.scopePayloadMismatch(
                    scope: authorization.scope,
                    payloadKind: event.payload.kind
                )
            }

        case .evidenceImport:
            try requireSystemActor(event, component: authorization.component)
            guard case let .evidenceRecorded(evidence) = event.payload,
                  evidence.capturedBy == event.actor
            else {
                throw ScoutEventAuthorizationError.evidenceProvenanceMismatch(event.id)
            }
            if case .utterance = evidence.source {
                throw ScoutEventAuthorizationError.evidenceProvenanceMismatch(event.id)
            }

        case .deterministicProjection:
            try requireSystemActor(event, component: authorization.component)

        case .modelProjection:
            guard case let .model(identity) = event.actor else {
                throw ScoutEventAuthorizationError.actorMismatch(event.id)
            }
            try validateModelProjection(event, identity: identity, in: state)

        case .localReview:
            try requireSystemActor(event, component: authorization.component)
            if event.schemaVersion.minor < 4,
               authorization.localReviewAuthorization != nil
            {
                throw ScoutEventAuthorizationError.localReviewAuthorization(
                    eventID: event.id,
                    failure: .unexpected
                )
            } else if let proof = authorization.localReviewAuthorization {
                try validateLocalReview(
                    event,
                    authorization: authorization,
                    proof: proof,
                    in: state
                )
            } else if event.schemaVersion.minor >= 4 {
                throw ScoutEventAuthorizationError.localReviewAuthorization(
                    eventID: event.id,
                    failure: .missing
                )
            }

        case .graphMaintenance:
            try requireSystemActor(event, component: authorization.component)
        }
    }

    private static func payload(
        _ payload: ScoutEventPayload,
        isAllowedFor scope: EventAuthorizationScope
    ) -> Bool {
        switch (scope, payload) {
        case (.sessionLifecycle, .sessionStarted),
             (.sessionLifecycle, .sessionEnded),
             (.sessionLifecycle, .speakerUpserted),
             (.capturePipeline, .utteranceFinalized),
             (.capturePipeline, .evidenceRecorded),
             (.evidenceImport, .evidenceRecorded),
             (.deterministicProjection, .entityUpserted),
             (.deterministicProjection, .claimProposed),
             (.deterministicProjection, .relationshipUpserted),
             (.modelProjection, .modelCallRecorded),
             (.modelProjection, .visualObservationProposed),
             (.modelProjection, .entityUpserted),
             (.modelProjection, .claimProposed),
             (.modelProjection, .relationshipUpserted),
             (.localReview, .visualObservationReviewed),
             (.localReview, .claimReviewed),
             (.localReview, .localReviewAttested),
             (.graphMaintenance, .entityRetired),
             (.graphMaintenance, .relationshipRemoved):
            true
        default:
            false
        }
    }

    private static func validateModelProjection(
        _ event: ScoutEventEnvelope,
        identity: ModelIdentity,
        in state: ScoutState
    ) throws {
        switch event.payload {
        case let .modelCallRecorded(receipt):
            guard receipt.provider == identity.provider,
                  receipt.model == identity.model,
                  receipt.promptVersion == identity.operationVersion,
                  event.causationID == receipt.inputBoundary.eventID
            else {
                throw ScoutEventAuthorizationError.modelReceiptIdentityMismatch(event.id)
            }
            if event.schemaVersion.minor >= 4, receipt.derivedEventManifest == nil {
                throw ScoutEventAuthorizationError.modelProjectionManifestRequired(event.id)
            }

        case let .visualObservationProposed(observation):
            guard observation.status == .proposed else {
                throw ScoutEventAuthorizationError.modelProposalRequiresSuggestedTrust(event.id)
            }
            let receipt = try boundReceipt(for: event, in: state)
            guard receipt.id == observation.modelCallReceiptID,
                  receipt.purpose == .whiteboardExtraction
            else {
                throw ScoutEventAuthorizationError.modelProposalPurposeMismatch(event.id)
            }
            try require(identity, matches: receipt, eventID: event.id)
            try requireEvidence(
                [observation.evidenceID],
                visibleTo: receipt,
                proposalEventID: event.id,
                in: state
            )

        case let .entityUpserted(entity):
            try requireSuggested(entity.trust, eventID: event.id)
            guard entity.lifecycle == .active else {
                throw ScoutEventAuthorizationError.modelProposalRequiresSuggestedTrust(event.id)
            }
            let receipt = try boundReceipt(for: event, in: state)
            guard receipt.purpose == .claimExtraction || receipt.purpose == .entityResolution else {
                throw ScoutEventAuthorizationError.modelProposalPurposeMismatch(event.id)
            }
            try require(identity, matches: receipt, eventID: event.id)
            try requireEvidence(
                entity.evidenceIDs,
                visibleTo: receipt,
                proposalEventID: event.id,
                in: state
            )
            if let existing = state.graph.entities[entity.id] {
                let independentlyProtected: Bool = if case .active = existing.lifecycle {
                    !isUnreviewedSuggestion(existing.trust)
                } else {
                    true
                }
                let unsafeTransitiveMutation = entityIsTransitivelyProtected(entity.id, in: state)
                    && !isSafeEnrichment(existing: existing, proposed: entity)
                if independentlyProtected || unsafeTransitiveMutation {
                    throw ScoutEventAuthorizationError.modelProposalCannotModifyProtectedEntity(
                        eventID: event.id,
                        entityID: entity.id
                    )
                }
            }

        case let .claimProposed(claim):
            try requireSuggested(claim.trust, eventID: event.id)
            guard claim.status == .proposed else {
                throw ScoutEventAuthorizationError.modelProposalRequiresSuggestedTrust(event.id)
            }
            let receipt = try boundReceipt(for: event, in: state)
            guard receipt.purpose == .claimExtraction else {
                throw ScoutEventAuthorizationError.modelProposalPurposeMismatch(event.id)
            }
            try require(identity, matches: receipt, eventID: event.id)
            try requireEvidence(
                claim.evidenceIDs,
                visibleTo: receipt,
                proposalEventID: event.id,
                in: state
            )
            guard claim.assertedBy == assertedSpeaker(for: claim.evidenceIDs, in: state) else {
                throw ScoutEventAuthorizationError.modelClaimAttributionMismatch(event.id)
            }
            if let supersededID = claim.supersedes,
               let superseded = state.claims[supersededID]
            {
                guard superseded.status == .proposed,
                      isUnreviewedSuggestion(superseded.trust)
                else {
                    throw ScoutEventAuthorizationError.modelProposalCannotSupersedeProtectedClaim(
                        eventID: event.id,
                        claimID: supersededID
                    )
                }
            }

        case let .relationshipUpserted(relationship):
            try requireSuggested(relationship.trust, eventID: event.id)
            let receipt = try boundReceipt(for: event, in: state)
            guard receipt.purpose == .claimExtraction || receipt.purpose == .entityResolution else {
                throw ScoutEventAuthorizationError.modelProposalPurposeMismatch(event.id)
            }
            try require(identity, matches: receipt, eventID: event.id)
            try requireEvidence(
                relationship.evidenceIDs,
                visibleTo: receipt,
                proposalEventID: event.id,
                in: state
            )
            if state.removedRelationships[relationship.id] != nil {
                throw ScoutEventAuthorizationError.modelProposalCannotModifyProtectedRelationship(
                    eventID: event.id,
                    relationshipID: relationship.id
                )
            }
            if let existing = state.graph.relationships[relationship.id] {
                let hasProtectedClaim = (existing.claimIDs + relationship.claimIDs).contains {
                    state.claims[$0].map(isProtectedClaim) ?? false
                }
                let unsafeTransitiveMutation = hasProtectedClaim
                    && !isSafeEnrichment(existing: existing, proposed: relationship)
                guard isUnreviewedSuggestion(existing.trust), !unsafeTransitiveMutation else {
                    throw ScoutEventAuthorizationError.modelProposalCannotModifyProtectedRelationship(
                        eventID: event.id,
                        relationshipID: relationship.id
                    )
                }
            }

        default:
            throw ScoutEventAuthorizationError.scopePayloadMismatch(
                scope: .modelProjection,
                payloadKind: event.payload.kind
            )
        }
    }

    private static func boundReceipt(
        for event: ScoutEventEnvelope,
        in state: ScoutState
    ) throws -> ModelCallReceipt {
        guard let correlationID = event.correlationID,
              correlationID == event.causationID,
              let receiptID = state.modelCallEvents[correlationID],
              let receipt = state.modelCallReceipts[receiptID]
        else {
            throw ScoutEventAuthorizationError.modelProposalNotBoundToReceipt(event.id)
        }
        if event.schemaVersion.minor >= 4, receipt.derivedEventManifest == nil {
            throw ScoutEventAuthorizationError.modelProjectionManifestRequired(event.id)
        }
        return receipt
    }

    private static func validateLocalReview(
        _ event: ScoutEventEnvelope,
        authorization: EventAuthorizationRecord,
        proof: LocalReviewAuthorizationRecord,
        in state: ScoutState
    ) throws {
        func reject(_ failure: LocalReviewAuthorizationFailure) throws -> Never {
            throw ScoutEventAuthorizationError.localReviewAuthorization(
                eventID: event.id,
                failure: failure
            )
        }

        guard authorization.component.rawValue == localReviewComponent else {
            try reject(.componentMismatch)
        }
        guard event.correlationID == nil, event.causationID == nil else {
            try reject(.unexpectedEventLinkage)
        }
        guard proof.sessionID == event.sessionID else {
            try reject(.sessionMismatch)
        }
        guard proof.eventID == event.id else {
            try reject(.eventMismatch)
        }
        guard !state.consumedReviewAuthorizationIDs.contains(proof.id) else {
            try reject(.reused(proof.id))
        }
        guard proof.operationHash == .hash(event.payload.canonicalValue) else {
            try reject(.operationMismatch)
        }

        let expectedTarget: LocalReviewTarget
        let expectedTargetEventID: EventID
        let expectedTargetStateHash: SHA256Digest
        switch event.payload {
        case let .claimReviewed(review):
            expectedTarget = .claim(review.claimID)
            let isTerminalDecision = switch (
                review.status,
                review.trust.validationStatus
            ) {
            case (.accepted, .validated), (.rejected, .rejected): true
            default: false
            }
            guard isTerminalDecision else {
                try reject(.invalidDecision)
            }
            guard let claim = state.claims[review.claimID],
                  let proposalEventID = state.claimEvents[review.claimID]
            else {
                try reject(.targetMismatch)
            }
            guard claim.status == .proposed else {
                try reject(.targetIsNotProposed)
            }
            expectedTargetEventID = proposalEventID
            expectedTargetStateHash = .hash(claim.canonicalValue)

        case let .visualObservationReviewed(review):
            expectedTarget = .visualObservation(review.observationID)
            guard let observation = state.visualObservations[review.observationID],
                  let proposalEventID = state.visualObservationEvents[review.observationID]
            else {
                try reject(.targetMismatch)
            }
            guard observation.status == .proposed else {
                try reject(.targetIsNotProposed)
            }
            expectedTargetEventID = proposalEventID
            expectedTargetStateHash = .hash(observation.canonicalValue)

        case let .localReviewAttested(attestation):
            expectedTarget = attestation.target
            switch attestation.target {
            case let .claim(claimID):
                guard let claim = state.claims[claimID] else {
                    try reject(.targetMismatch)
                }
                guard LocalReviewIntent.isTerminalReviewedClaim(claim) else {
                    try reject(.targetIsNotTerminal)
                }
                guard let currentAttestation = state.claimReviewAttestations[claimID] else {
                    try reject(.missingReviewAttestation)
                }
                guard case .legacyUnattested = currentAttestation else {
                    try reject(.targetAlreadyAuthenticated)
                }
                guard let reviewEventID = state.claimReviewEvents[claimID] else {
                    try reject(.missingTargetEvent)
                }
                expectedTargetEventID = reviewEventID
                expectedTargetStateHash = .hash(claim.canonicalValue)

            case let .visualObservation(observationID):
                guard let observation = state.visualObservations[observationID] else {
                    try reject(.targetMismatch)
                }
                guard observation.status == .confirmed || observation.status == .rejected else {
                    try reject(.targetIsNotTerminal)
                }
                guard let currentAttestation =
                    state.visualObservationReviewAttestations[observationID]
                else {
                    try reject(.missingReviewAttestation)
                }
                guard case .legacyUnattested = currentAttestation else {
                    try reject(.targetAlreadyAuthenticated)
                }
                guard let reviewEventID = state.visualObservationReviewEvents[observationID] else {
                    try reject(.missingTargetEvent)
                }
                expectedTargetEventID = reviewEventID
                expectedTargetStateHash = .hash(observation.canonicalValue)
            }

        default:
            try reject(.operationMismatch)
        }

        guard proof.target == expectedTarget else {
            try reject(.targetMismatch)
        }
        guard proof.targetEventID == expectedTargetEventID else {
            try reject(.targetEventMismatch)
        }
        guard proof.targetStateHash == expectedTargetStateHash else {
            try reject(.targetStateMismatch)
        }
        guard proof.authenticatedAt <= event.recordedAt else {
            try reject(.authenticatedInFuture)
        }
        let elapsed = event.recordedAt.millisecondsSinceUnixEpoch
            .subtractingReportingOverflow(proof.authenticatedAt.millisecondsSinceUnixEpoch)
        guard !elapsed.overflow,
              elapsed.partialValue <= LocalReviewAuthorizationRules.maximumCommitDelayMilliseconds
        else {
            try reject(.expired)
        }
    }

    private static func require(
        _ identity: ModelIdentity,
        matches receipt: ModelCallReceipt,
        eventID: EventID
    ) throws {
        guard identity.provider == receipt.provider,
              identity.model == receipt.model,
              identity.operationVersion == receipt.promptVersion
        else {
            throw ScoutEventAuthorizationError.modelReceiptIdentityMismatch(eventID)
        }
    }

    private static func requireSuggested(
        _ trust: TrustAssessment,
        eventID: EventID
    ) throws {
        guard trust.origin == .suggested,
              trust.validationStatus == .unreviewed || trust.validationStatus == .needsValidation
        else {
            throw ScoutEventAuthorizationError.modelProposalRequiresSuggestedTrust(eventID)
        }
    }

    private static func isUnreviewedSuggestion(_ trust: TrustAssessment) -> Bool {
        guard trust.origin == .suggested else { return false }
        return trust.validationStatus == .unreviewed
            || trust.validationStatus == .needsValidation
    }

    private static func isProtectedClaim(_ claim: Claim) -> Bool {
        claim.status != .proposed || !isUnreviewedSuggestion(claim.trust)
    }

    private static func entityIsTransitivelyProtected(
        _ entityID: EntityID,
        in state: ScoutState
    ) -> Bool {
        let referencedByProtectedClaim = state.claims.values.contains { claim in
            let referencesEntity = switch (claim.subject, claim.object) {
            case let (.entity(subjectID), .entity(objectID)):
                subjectID == entityID || objectID == entityID
            case let (.entity(subjectID), _):
                subjectID == entityID
            default:
                false
            }
            return referencesEntity && isProtectedClaim(claim)
        }
        if referencedByProtectedClaim { return true }

        return state.graph.relationships.values.contains { relationship in
            (relationship.sourceID == entityID || relationship.targetID == entityID)
                && !isUnreviewedSuggestion(relationship.trust)
        }
    }

    private static func isSafeEnrichment(
        existing: GraphEntity,
        proposed: GraphEntity
    ) -> Bool {
        existing.kind == proposed.kind
            && existing.canonicalName == proposed.canonicalName
            && existing.lifecycle == proposed.lifecycle
            && existing.trust == proposed.trust
            && proposed.aliases.allSatisfy(existing.aliases.contains)
            && proposed.attributes.allSatisfy { key, value in
                existing.attributes[key] == value
            }
    }

    private static func isSafeEnrichment(
        existing: GraphRelationship,
        proposed: GraphRelationship
    ) -> Bool {
        existing.sourceID == proposed.sourceID
            && existing.targetID == proposed.targetID
            && existing.kind == proposed.kind
            && (proposed.label == nil || proposed.label == existing.label)
            && existing.trust == proposed.trust
            && proposed.attributes.allSatisfy { key, value in
                existing.attributes[key] == value
            }
    }

    private static func assertedSpeaker(
        for evidenceIDs: [EvidenceID],
        in state: ScoutState
    ) -> SpeakerID? {
        let speakers = Set(evidenceIDs.compactMap { evidenceID -> SpeakerID? in
            guard let evidence = state.evidence[evidenceID],
                  case let .utterance(utteranceID) = evidence.source
            else { return nil }
            return state.utterances[utteranceID]?.speakerID
        })
        return speakers.count == 1 ? speakers.first : nil
    }

    private static func requireEvidence(
        _ evidenceIDs: [EvidenceID],
        visibleTo receipt: ModelCallReceipt,
        proposalEventID: EventID,
        in state: ScoutState
    ) throws {
        for evidenceID in evidenceIDs {
            guard let evidenceEventID = state.evidenceEvents[evidenceID],
                  let boundary = state.eventBoundaries[evidenceEventID],
                  boundary.sequence <= receipt.inputBoundary.sequence
            else {
                throw ScoutEventAuthorizationError.modelProposalEvidenceOutsideInputBoundary(
                    eventID: proposalEventID,
                    evidenceID: evidenceID
                )
            }
        }
    }

    private static func requireSystemActor(
        _ event: ScoutEventEnvelope,
        component: NonEmptyString
    ) throws {
        guard event.actor == .system(component: component) else {
            throw ScoutEventAuthorizationError.actorMismatch(event.id)
        }
    }

}

enum LocalReviewAuthorizationRules {
    static let maximumCommitDelayMilliseconds: Int64 = 5 * 60 * 1_000
}
