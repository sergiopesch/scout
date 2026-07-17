import Foundation

public struct ScoutState: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let sessionID: SessionID
    public internal(set) var session: DiscoverySession?
    public internal(set) var speakers: [SpeakerID: Speaker]
    public internal(set) var utterances: [UtteranceID: Utterance]
    public internal(set) var evidence: [EvidenceID: Evidence]
    public internal(set) var modelCallReceipts: [ModelCallReceiptID: ModelCallReceipt]
    public internal(set) var visualObservations: [VisualObservationID: VisualObservation]
    public internal(set) var claims: [ClaimID: Claim]
    public internal(set) var graph: CustomerGraph
    public internal(set) var lastSequence: EventSequence?
    public internal(set) var lastEventHash: SHA256Digest?
    public internal(set) var appliedEventIDs: Set<EventID>
    public internal(set) var eventBoundaries: [EventID: ModelInputEventBoundary]

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
        session = nil
        speakers = [:]
        utterances = [:]
        evidence = [:]
        modelCallReceipts = [:]
        visualObservations = [:]
        claims = [:]
        graph = CustomerGraph()
        lastSequence = nil
        lastEventHash = nil
        appliedEventIDs = []
        eventBoundaries = [:]
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "sessionID": sessionID.canonicalValue,
            "session": session.canonicalValue,
            "speakers": .array(speakers.values.sorted { $0.id < $1.id }.map(\.canonicalValue)),
            "utterances": .array(
                utterances.values.sorted { $0.id < $1.id }.map(\.canonicalValue)
            ),
            "evidence": .array(evidence.values.sorted { $0.id < $1.id }.map(\.canonicalValue)),
            "modelCallReceipts": .array(
                modelCallReceipts.values.sorted { $0.id < $1.id }.map(\.canonicalValue)
            ),
            "visualObservations": .array(
                visualObservations.values.sorted { $0.id < $1.id }.map(\.canonicalValue)
            ),
            "claims": .array(claims.values.sorted { $0.id < $1.id }.map(\.canonicalValue)),
            "graph": graph.canonicalValue,
            "lastSequence": lastSequence.canonicalValue,
            "lastEventHash": lastEventHash.canonicalValue,
            "appliedEventIDs": .array(appliedEventIDs.sorted().map(\.canonicalValue)),
            "eventBoundaries": .array(
                eventBoundaries.values.sorted {
                    ($0.sequence, $0.eventID) < ($1.sequence, $1.eventID)
                }.map(\.canonicalValue)
            ),
        ])
    }

    public var digest: SHA256Digest { .hash(canonicalValue) }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case session
        case speakers
        case utterances
        case evidence
        case modelCallReceipts
        case visualObservations
        case claims
        case graph
        case lastSequence
        case lastEventHash
        case appliedEventIDs
        case eventBoundaries
    }

    /// v1.0 state snapshots decode with empty receipt and boundary projections.
    /// Replaying the canonical event log repopulates the boundary index.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        session = try container.decodeIfPresent(DiscoverySession.self, forKey: .session)
        speakers = try container.decode([SpeakerID: Speaker].self, forKey: .speakers)
        utterances = try container.decode([UtteranceID: Utterance].self, forKey: .utterances)
        evidence = try container.decode([EvidenceID: Evidence].self, forKey: .evidence)
        modelCallReceipts = try container.decodeIfPresent(
            [ModelCallReceiptID: ModelCallReceipt].self,
            forKey: .modelCallReceipts
        ) ?? [:]
        visualObservations = try container.decodeIfPresent(
            [VisualObservationID: VisualObservation].self,
            forKey: .visualObservations
        ) ?? [:]
        claims = try container.decode([ClaimID: Claim].self, forKey: .claims)
        graph = try container.decode(CustomerGraph.self, forKey: .graph)
        lastSequence = try container.decodeIfPresent(EventSequence.self, forKey: .lastSequence)
        lastEventHash = try container.decodeIfPresent(SHA256Digest.self, forKey: .lastEventHash)
        appliedEventIDs = try container.decode(Set<EventID>.self, forKey: .appliedEventIDs)
        eventBoundaries = try container.decodeIfPresent(
            [EventID: ModelInputEventBoundary].self,
            forKey: .eventBoundaries
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(session, forKey: .session)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(utterances, forKey: .utterances)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(modelCallReceipts, forKey: .modelCallReceipts)
        try container.encode(visualObservations, forKey: .visualObservations)
        try container.encode(claims, forKey: .claims)
        try container.encode(graph, forKey: .graph)
        try container.encodeIfPresent(lastSequence, forKey: .lastSequence)
        try container.encodeIfPresent(lastEventHash, forKey: .lastEventHash)
        try container.encode(appliedEventIDs, forKey: .appliedEventIDs)
        try container.encode(eventBoundaries, forKey: .eventBoundaries)
    }
}

public enum ScoutReducerError: Error, Equatable, Sendable {
    case emptyReplay
    case invalidIntegrity(EventID)
    case unsupportedSchema(EventSchemaVersion)
    case sessionMismatch(expected: SessionID, actual: SessionID)
    case unexpectedSequence(expected: UInt64, actual: UInt64)
    case previousHashMismatch(expected: SHA256Digest?, actual: SHA256Digest?)
    case duplicateEvent(EventID)
    case firstEventMustStartSession
    case sessionAlreadyStarted
    case sessionHasEnded
    case invalidSessionRecord
    case invalidSessionEnd
    case unknownSpeaker(SpeakerID)
    case duplicateUtterance(UtteranceID)
    case invalidUtteranceRange(UtteranceID)
    case duplicateEvidence(EvidenceID)
    case unknownUtterance(UtteranceID)
    case payloadUnavailableInSchema(kind: String, schemaVersion: EventSchemaVersion)
    case missingModelInputEvent(EventID)
    case modelInputBoundaryMismatch(
        expected: ModelInputEventBoundary,
        actual: ModelInputEventBoundary
    )
    case duplicateModelCallReceipt(ModelCallReceiptID)
    case modelCallReceiptConflict(ModelCallReceiptID)
    case duplicateModelResponse(provider: String, responseID: String)
    case modelResponseConflict(provider: String, responseID: String)
    case duplicateVisualObservation(VisualObservationID)
    case missingVisualObservation(VisualObservationID)
    case invalidInitialVisualObservationStatus(VisualObservationStatus)
    case missingVisualObservationModelCall(ModelCallReceiptID)
    case invalidVisualObservationModelPurpose(ModelCallPurpose)
    case visualObservationAlreadyReviewed(VisualObservationID)
    case emptyEvidence(subject: String)
    case missingEvidence(EvidenceID)
    case duplicateClaim(ClaimID)
    case missingClaim(ClaimID)
    case invalidInitialClaimStatus(ClaimStatus)
    case invalidClaimReview(claimID: ClaimID)
    case missingEntity(EntityID)
    case entityKindConflict(EntityID)
    case invalidAttributeKey(String)
    case missingRelationship(RelationshipID)
    case relationshipShapeConflict(RelationshipID)
    case emptyClaims(RelationshipID)
}

/// Pure state transition authority for the event-sourced customer model.
public enum ScoutGraphReducer {
    public static func replay(_ events: [ScoutEventEnvelope]) throws -> ScoutState {
        guard let first = events.first else { throw ScoutReducerError.emptyReplay }
        return try events.reduce(into: ScoutState(sessionID: first.sessionID)) { state, event in
            state = try reduce(state, event: event)
        }
    }

    public static func reduce(_ state: ScoutState, event: ScoutEventEnvelope) throws -> ScoutState {
        guard event.hasValidIntegrity else {
            throw ScoutReducerError.invalidIntegrity(event.id)
        }
        guard event.schemaVersion.major == EventSchemaVersion.current.major,
              event.schemaVersion.minor <= EventSchemaVersion.current.minor
        else {
            throw ScoutReducerError.unsupportedSchema(event.schemaVersion)
        }
        if case .modelCallRecorded = event.payload, event.schemaVersion.minor < 1 {
            throw ScoutReducerError.payloadUnavailableInSchema(
                kind: event.payload.kind,
                schemaVersion: event.schemaVersion
            )
        }
        if event.schemaVersion.minor < 2 {
            switch event.payload {
            case .visualObservationProposed, .visualObservationReviewed:
                throw ScoutReducerError.payloadUnavailableInSchema(
                    kind: event.payload.kind,
                    schemaVersion: event.schemaVersion
                )
            default:
                break
            }
        }
        guard event.sessionID == state.sessionID else {
            throw ScoutReducerError.sessionMismatch(expected: state.sessionID, actual: event.sessionID)
        }
        guard !state.appliedEventIDs.contains(event.id) else {
            throw ScoutReducerError.duplicateEvent(event.id)
        }

        let expectedSequence: UInt64
        if let last = state.lastSequence {
            guard last.rawValue < UInt64.max else {
                throw ScoutReducerError.unexpectedSequence(
                    expected: UInt64.max,
                    actual: event.sequence.rawValue
                )
            }
            expectedSequence = last.rawValue + 1
        } else {
            expectedSequence = 1
        }
        guard event.sequence.rawValue == expectedSequence else {
            throw ScoutReducerError.unexpectedSequence(
                expected: expectedSequence,
                actual: event.sequence.rawValue
            )
        }
        guard event.previousHash == state.lastEventHash else {
            throw ScoutReducerError.previousHashMismatch(
                expected: state.lastEventHash,
                actual: event.previousHash
            )
        }
        if state.session == nil, case .sessionStarted = event.payload {
            // Valid first transition.
        } else if state.session == nil {
            throw ScoutReducerError.firstEventMustStartSession
        } else if state.session?.status == .ended {
            throw ScoutReducerError.sessionHasEnded
        }

        var next = state
        try apply(event.payload, to: &next)
        next.eventBoundaries[event.id] = ModelInputEventBoundary(event)
        next.lastSequence = event.sequence
        next.lastEventHash = event.integrityHash
        next.appliedEventIDs.insert(event.id)
        return next
    }

    private static func apply(_ payload: ScoutEventPayload, to state: inout ScoutState) throws {
        switch payload {
        case let .sessionStarted(session):
            guard state.session == nil else { throw ScoutReducerError.sessionAlreadyStarted }
            guard session.id == state.sessionID,
                  session.status == .active,
                  session.endedAt == nil
            else {
                throw ScoutReducerError.invalidSessionRecord
            }
            state.session = session

        case let .sessionEnded(ended):
            guard let session = state.session,
                  ended.endedAt >= session.startedAt
            else {
                throw ScoutReducerError.invalidSessionEnd
            }
            state.session = session.ending(at: ended.endedAt)

        case let .speakerUpserted(speaker):
            state.speakers[speaker.id] = speaker

        case let .utteranceFinalized(utterance):
            guard state.speakers[utterance.speakerID] != nil else {
                throw ScoutReducerError.unknownSpeaker(utterance.speakerID)
            }
            guard state.utterances[utterance.id] == nil else {
                throw ScoutReducerError.duplicateUtterance(utterance.id)
            }
            guard utterance.startedAt <= utterance.endedAt else {
                throw ScoutReducerError.invalidUtteranceRange(utterance.id)
            }
            state.utterances[utterance.id] = utterance

        case let .evidenceRecorded(evidence):
            guard state.evidence[evidence.id] == nil else {
                throw ScoutReducerError.duplicateEvidence(evidence.id)
            }
            if case let .utterance(utteranceID) = evidence.source,
               state.utterances[utteranceID] == nil
            {
                throw ScoutReducerError.unknownUtterance(utteranceID)
            }
            state.evidence[evidence.id] = evidence

        case let .modelCallRecorded(receipt):
            guard let actualBoundary = state.eventBoundaries[receipt.inputBoundary.eventID] else {
                throw ScoutReducerError.missingModelInputEvent(receipt.inputBoundary.eventID)
            }
            guard actualBoundary == receipt.inputBoundary else {
                throw ScoutReducerError.modelInputBoundaryMismatch(
                    expected: actualBoundary,
                    actual: receipt.inputBoundary
                )
            }
            if let existing = state.modelCallReceipts[receipt.id] {
                guard existing != receipt else {
                    throw ScoutReducerError.duplicateModelCallReceipt(receipt.id)
                }
                throw ScoutReducerError.modelCallReceiptConflict(receipt.id)
            }
            if let existing = state.modelCallReceipts.values.first(where: {
                $0.provider == receipt.provider
                    && $0.providerResponseID == receipt.providerResponseID
            }) {
                let provider = receipt.provider.rawValue
                let responseID = receipt.providerResponseID.rawValue
                guard !existing.hasSameProviderResponse(as: receipt) else {
                    throw ScoutReducerError.duplicateModelResponse(
                        provider: provider,
                        responseID: responseID
                    )
                }
                throw ScoutReducerError.modelResponseConflict(
                    provider: provider,
                    responseID: responseID
                )
            }
            state.modelCallReceipts[receipt.id] = receipt

        case let .visualObservationProposed(observation):
            guard observation.status == .proposed else {
                throw ScoutReducerError.invalidInitialVisualObservationStatus(observation.status)
            }
            guard state.visualObservations[observation.id] == nil else {
                throw ScoutReducerError.duplicateVisualObservation(observation.id)
            }
            guard state.evidence[observation.evidenceID] != nil else {
                throw ScoutReducerError.missingEvidence(observation.evidenceID)
            }
            guard let receipt = state.modelCallReceipts[observation.modelCallReceiptID] else {
                throw ScoutReducerError.missingVisualObservationModelCall(
                    observation.modelCallReceiptID
                )
            }
            guard receipt.purpose == .whiteboardExtraction else {
                throw ScoutReducerError.invalidVisualObservationModelPurpose(receipt.purpose)
            }
            state.visualObservations[observation.id] = observation

        case let .visualObservationReviewed(review):
            guard let observation = state.visualObservations[review.observationID] else {
                throw ScoutReducerError.missingVisualObservation(review.observationID)
            }
            guard observation.status == .proposed else {
                throw ScoutReducerError.visualObservationAlreadyReviewed(review.observationID)
            }
            state.visualObservations[review.observationID] = observation.reviewed(
                review.disposition
            )

        case let .entityUpserted(entity):
            let entity = entity.normalized()
            try validateAttributeKeys(entity.attributes)
            try requireEvidence(entity.evidenceIDs, subject: entity.id.rawValue, in: state)
            if let existing = state.graph.entities[entity.id] {
                guard existing.kind == entity.kind else {
                    throw ScoutReducerError.entityKindConflict(entity.id)
                }
                state.graph.entities[entity.id] = existing.merging(entity)
            } else {
                state.graph.entities[entity.id] = entity
            }

        case let .entityRetired(retirement):
            guard let entity = state.graph.entities[retirement.entityID] else {
                throw ScoutReducerError.missingEntity(retirement.entityID)
            }
            state.graph.entities[retirement.entityID] = entity.retiring(reason: retirement.reason)

        case let .claimProposed(claim):
            let claim = claim.normalized()
            guard state.claims[claim.id] == nil else {
                throw ScoutReducerError.duplicateClaim(claim.id)
            }
            guard claim.status == .proposed else {
                throw ScoutReducerError.invalidInitialClaimStatus(claim.status)
            }
            try requireEvidence(claim.evidenceIDs, subject: claim.id.rawValue, in: state)
            try validate(claim.subject, in: state)
            try validate(claim.object, in: state)
            if let speakerID = claim.assertedBy, state.speakers[speakerID] == nil {
                throw ScoutReducerError.unknownSpeaker(speakerID)
            }
            if let supersededID = claim.supersedes {
                guard let superseded = state.claims[supersededID] else {
                    throw ScoutReducerError.missingClaim(supersededID)
                }
                state.claims[supersededID] = superseded.reviewed(
                    status: .superseded,
                    trust: superseded.trust
                )
            }
            state.claims[claim.id] = claim

        case let .claimReviewed(review):
            guard let claim = state.claims[review.claimID] else {
                throw ScoutReducerError.missingClaim(review.claimID)
            }
            let validPair = switch (review.status, review.trust.validationStatus) {
            case (.accepted, .validated), (.rejected, .rejected): true
            case (.proposed, .unreviewed), (.proposed, .needsValidation), (.proposed, .disputed): true
            default: false
            }
            guard validPair else {
                throw ScoutReducerError.invalidClaimReview(claimID: review.claimID)
            }
            state.claims[review.claimID] = claim.reviewed(
                status: review.status,
                trust: review.trust
            )

        case let .relationshipUpserted(relationship):
            let relationship = relationship.normalized()
            try validateAttributeKeys(relationship.attributes)
            guard state.graph.entities[relationship.sourceID] != nil else {
                throw ScoutReducerError.missingEntity(relationship.sourceID)
            }
            guard state.graph.entities[relationship.targetID] != nil else {
                throw ScoutReducerError.missingEntity(relationship.targetID)
            }
            guard !relationship.claimIDs.isEmpty else {
                throw ScoutReducerError.emptyClaims(relationship.id)
            }
            for claimID in relationship.claimIDs where state.claims[claimID] == nil {
                throw ScoutReducerError.missingClaim(claimID)
            }
            try requireEvidence(
                relationship.evidenceIDs,
                subject: relationship.id.rawValue,
                in: state
            )
            if let existing = state.graph.relationships[relationship.id] {
                guard existing.sourceID == relationship.sourceID,
                      existing.targetID == relationship.targetID,
                      existing.kind == relationship.kind
                else {
                    throw ScoutReducerError.relationshipShapeConflict(relationship.id)
                }
                state.graph.relationships[relationship.id] = existing.merging(relationship)
            } else {
                state.graph.relationships[relationship.id] = relationship
            }

        case let .relationshipRemoved(removal):
            guard state.graph.relationships.removeValue(forKey: removal.relationshipID) != nil else {
                throw ScoutReducerError.missingRelationship(removal.relationshipID)
            }
        }
    }

    private static func requireEvidence(
        _ evidenceIDs: [EvidenceID],
        subject: String,
        in state: ScoutState
    ) throws {
        guard !evidenceIDs.isEmpty else {
            throw ScoutReducerError.emptyEvidence(subject: subject)
        }
        for id in evidenceIDs where state.evidence[id] == nil {
            throw ScoutReducerError.missingEvidence(id)
        }
    }

    private static func validate(_ subject: ClaimSubject, in state: ScoutState) throws {
        switch subject {
        case let .entity(id):
            guard state.graph.entities[id] != nil else { throw ScoutReducerError.missingEntity(id) }
        case let .session(id):
            guard id == state.sessionID else {
                throw ScoutReducerError.sessionMismatch(expected: state.sessionID, actual: id)
            }
        }
    }

    private static func validate(_ object: ClaimObject, in state: ScoutState) throws {
        if case let .entity(id) = object, state.graph.entities[id] == nil {
            throw ScoutReducerError.missingEntity(id)
        }
    }

    private static func validateAttributeKeys(_ attributes: [String: AttributeValue]) throws {
        for key in attributes.keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == key else {
                throw ScoutReducerError.invalidAttributeKey(key)
            }
        }
    }
}
