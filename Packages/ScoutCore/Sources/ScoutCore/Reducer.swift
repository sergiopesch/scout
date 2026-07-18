import Foundation

public struct ScoutState: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let sessionID: SessionID
    public internal(set) var session: DiscoverySession?
    public internal(set) var speakers: [SpeakerID: Speaker]
    public internal(set) var utterances: [UtteranceID: Utterance]
    public internal(set) var evidence: [EvidenceID: Evidence]
    public internal(set) var evidenceEvents: [EvidenceID: EventID]
    public internal(set) var modelCallReceipts: [ModelCallReceiptID: ModelCallReceipt]
    public internal(set) var modelCallEvents: [EventID: ModelCallReceiptID]
    public internal(set) var pendingDerivedEventProjections: [EventID: DerivedEventProjectionProgress]
    public internal(set) var completedDerivedEventProjections: [EventID: DerivedEventProjectionProgress]
    public internal(set) var visualObservations: [VisualObservationID: VisualObservation]
    public internal(set) var visualObservationEvents: [VisualObservationID: EventID]
    public internal(set) var visualObservationReviewEvents: [VisualObservationID: EventID]
    public internal(set) var visualObservationReviewAttestations: [
        VisualObservationID: LocalReviewAttestation
    ]
    public internal(set) var claims: [ClaimID: Claim]
    public internal(set) var claimEvents: [ClaimID: EventID]
    public internal(set) var claimReviewEvents: [ClaimID: EventID]
    public internal(set) var claimReviewAttestations: [ClaimID: LocalReviewAttestation]
    public internal(set) var consumedReviewAuthorizationIDs: Set<ReviewAuthorizationID>
    public internal(set) var graph: CustomerGraph
    public internal(set) var removedRelationships: [RelationshipID: RelationshipRemoved]
    public internal(set) var lastSchemaVersion: EventSchemaVersion?
    public internal(set) var lastSequence: EventSequence?
    public internal(set) var lastEventID: EventID?
    public internal(set) var lastEventHash: SHA256Digest?
    public internal(set) var appliedEventIDs: Set<EventID>
    public internal(set) var eventBoundaries: [EventID: ModelInputEventBoundary]

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
        session = nil
        speakers = [:]
        utterances = [:]
        evidence = [:]
        evidenceEvents = [:]
        modelCallReceipts = [:]
        modelCallEvents = [:]
        pendingDerivedEventProjections = [:]
        completedDerivedEventProjections = [:]
        visualObservations = [:]
        visualObservationEvents = [:]
        visualObservationReviewEvents = [:]
        visualObservationReviewAttestations = [:]
        claims = [:]
        claimEvents = [:]
        claimReviewEvents = [:]
        claimReviewAttestations = [:]
        consumedReviewAuthorizationIDs = []
        graph = CustomerGraph()
        removedRelationships = [:]
        lastSchemaVersion = nil
        lastSequence = nil
        lastEventID = nil
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
            "evidenceEvents": .array(
                evidenceEvents.sorted { $0.key < $1.key }.map { evidenceID, eventID in
                    .object([
                        "evidenceID": evidenceID.canonicalValue,
                        "eventID": eventID.canonicalValue,
                    ])
                }
            ),
            "modelCallReceipts": .array(
                modelCallReceipts.values.sorted { $0.id < $1.id }.map(\.canonicalValue)
            ),
            "modelCallEvents": .array(
                modelCallEvents.sorted { $0.key < $1.key }.map { eventID, receiptID in
                    .object([
                        "eventID": eventID.canonicalValue,
                        "receiptID": receiptID.canonicalValue,
                    ])
                }
            ),
            "pendingDerivedEventProjections": .array(
                pendingDerivedEventProjections.values
                    .sorted { $0.modelCallEventID < $1.modelCallEventID }
                    .map(\.canonicalValue)
            ),
            "completedDerivedEventProjections": .array(
                completedDerivedEventProjections.values
                    .sorted { $0.modelCallEventID < $1.modelCallEventID }
                    .map(\.canonicalValue)
            ),
            "visualObservations": .array(
                visualObservations.values.sorted { $0.id < $1.id }.map(\.canonicalValue)
            ),
            "visualObservationEvents": .array(
                visualObservationEvents.sorted { $0.key < $1.key }.map { id, eventID in
                    .object([
                        "visualObservationID": id.canonicalValue,
                        "eventID": eventID.canonicalValue,
                    ])
                }
            ),
            "visualObservationReviewEvents": .array(
                visualObservationReviewEvents.sorted { $0.key < $1.key }.map { id, eventID in
                    .object([
                        "visualObservationID": id.canonicalValue,
                        "eventID": eventID.canonicalValue,
                    ])
                }
            ),
            "visualObservationReviewAttestations": .array(
                visualObservationReviewAttestations.sorted { $0.key < $1.key }.map {
                    id, attestation in
                    .object([
                        "visualObservationID": id.canonicalValue,
                        "attestation": attestation.canonicalValue,
                    ])
                }
            ),
            "claims": .array(claims.values.sorted { $0.id < $1.id }.map(\.canonicalValue)),
            "claimEvents": .array(
                claimEvents.sorted { $0.key < $1.key }.map { id, eventID in
                    .object([
                        "claimID": id.canonicalValue,
                        "eventID": eventID.canonicalValue,
                    ])
                }
            ),
            "claimReviewEvents": .array(
                claimReviewEvents.sorted { $0.key < $1.key }.map { id, eventID in
                    .object([
                        "claimID": id.canonicalValue,
                        "eventID": eventID.canonicalValue,
                    ])
                }
            ),
            "claimReviewAttestations": .array(
                claimReviewAttestations.sorted { $0.key < $1.key }.map { id, attestation in
                    .object([
                        "claimID": id.canonicalValue,
                        "attestation": attestation.canonicalValue,
                    ])
                }
            ),
            "consumedReviewAuthorizationIDs": .array(
                consumedReviewAuthorizationIDs.sorted().map(\.canonicalValue)
            ),
            "graph": graph.canonicalValue,
            "removedRelationships": .array(
                removedRelationships.sorted { $0.key < $1.key }.map { id, removal in
                    .object([
                        "relationshipID": id.canonicalValue,
                        "removal": removal.canonicalValue,
                    ])
                }
            ),
            "lastSchemaVersion": lastSchemaVersion.canonicalValue,
            "lastSequence": lastSequence.canonicalValue,
            "lastEventID": lastEventID.canonicalValue,
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
        case evidenceEvents
        case modelCallReceipts
        case modelCallEvents
        case pendingDerivedEventProjections
        case completedDerivedEventProjections
        case visualObservations
        case visualObservationEvents
        case visualObservationReviewEvents
        case visualObservationReviewAttestations
        case claims
        case claimEvents
        case claimReviewEvents
        case claimReviewAttestations
        case consumedReviewAuthorizationIDs
        case graph
        case removedRelationships
        case lastSchemaVersion
        case lastSequence
        case lastEventID
        case lastEventHash
        case appliedEventIDs
        case eventBoundaries
    }

    /// Legacy snapshots decode with empty replay-derived indexes and tombstones. They are readable for
    /// compatibility, but a schema 1.4 writer must rebuild them from the complete canonical event log.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        session = try container.decodeIfPresent(DiscoverySession.self, forKey: .session)
        speakers = try container.decode([SpeakerID: Speaker].self, forKey: .speakers)
        utterances = try container.decode([UtteranceID: Utterance].self, forKey: .utterances)
        evidence = try container.decode([EvidenceID: Evidence].self, forKey: .evidence)
        evidenceEvents = try container.decodeIfPresent(
            [EvidenceID: EventID].self,
            forKey: .evidenceEvents
        ) ?? [:]
        modelCallReceipts = try container.decodeIfPresent(
            [ModelCallReceiptID: ModelCallReceipt].self,
            forKey: .modelCallReceipts
        ) ?? [:]
        modelCallEvents = try container.decodeIfPresent(
            [EventID: ModelCallReceiptID].self,
            forKey: .modelCallEvents
        ) ?? [:]
        pendingDerivedEventProjections = try container.decodeIfPresent(
            [EventID: DerivedEventProjectionProgress].self,
            forKey: .pendingDerivedEventProjections
        ) ?? [:]
        completedDerivedEventProjections = try container.decodeIfPresent(
            [EventID: DerivedEventProjectionProgress].self,
            forKey: .completedDerivedEventProjections
        ) ?? [:]
        visualObservations = try container.decodeIfPresent(
            [VisualObservationID: VisualObservation].self,
            forKey: .visualObservations
        ) ?? [:]
        visualObservationEvents = try container.decodeIfPresent(
            [VisualObservationID: EventID].self,
            forKey: .visualObservationEvents
        ) ?? [:]
        visualObservationReviewEvents = try container.decodeIfPresent(
            [VisualObservationID: EventID].self,
            forKey: .visualObservationReviewEvents
        ) ?? [:]
        visualObservationReviewAttestations = try container.decodeIfPresent(
            [VisualObservationID: LocalReviewAttestation].self,
            forKey: .visualObservationReviewAttestations
        ) ?? [:]
        claims = try container.decode([ClaimID: Claim].self, forKey: .claims)
        claimEvents = try container.decodeIfPresent(
            [ClaimID: EventID].self,
            forKey: .claimEvents
        ) ?? [:]
        claimReviewEvents = try container.decodeIfPresent(
            [ClaimID: EventID].self,
            forKey: .claimReviewEvents
        ) ?? [:]
        claimReviewAttestations = try container.decodeIfPresent(
            [ClaimID: LocalReviewAttestation].self,
            forKey: .claimReviewAttestations
        ) ?? [:]
        consumedReviewAuthorizationIDs = try container.decodeIfPresent(
            Set<ReviewAuthorizationID>.self,
            forKey: .consumedReviewAuthorizationIDs
        ) ?? []
        graph = try container.decode(CustomerGraph.self, forKey: .graph)
        removedRelationships = try container.decodeIfPresent(
            [RelationshipID: RelationshipRemoved].self,
            forKey: .removedRelationships
        ) ?? [:]
        lastSchemaVersion = try container.decodeIfPresent(
            EventSchemaVersion.self,
            forKey: .lastSchemaVersion
        )
        lastSequence = try container.decodeIfPresent(EventSequence.self, forKey: .lastSequence)
        lastEventID = try container.decodeIfPresent(EventID.self, forKey: .lastEventID)
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
        try container.encode(evidenceEvents, forKey: .evidenceEvents)
        try container.encode(modelCallReceipts, forKey: .modelCallReceipts)
        try container.encode(modelCallEvents, forKey: .modelCallEvents)
        try container.encode(
            pendingDerivedEventProjections,
            forKey: .pendingDerivedEventProjections
        )
        try container.encode(
            completedDerivedEventProjections,
            forKey: .completedDerivedEventProjections
        )
        try container.encode(visualObservations, forKey: .visualObservations)
        try container.encode(visualObservationEvents, forKey: .visualObservationEvents)
        try container.encode(
            visualObservationReviewEvents,
            forKey: .visualObservationReviewEvents
        )
        try container.encode(
            visualObservationReviewAttestations,
            forKey: .visualObservationReviewAttestations
        )
        try container.encode(claims, forKey: .claims)
        try container.encode(claimEvents, forKey: .claimEvents)
        try container.encode(claimReviewEvents, forKey: .claimReviewEvents)
        try container.encode(claimReviewAttestations, forKey: .claimReviewAttestations)
        try container.encode(
            consumedReviewAuthorizationIDs,
            forKey: .consumedReviewAuthorizationIDs
        )
        try container.encode(graph, forKey: .graph)
        try container.encode(removedRelationships, forKey: .removedRelationships)
        try container.encodeIfPresent(lastSchemaVersion, forKey: .lastSchemaVersion)
        try container.encodeIfPresent(lastSequence, forKey: .lastSequence)
        try container.encodeIfPresent(lastEventID, forKey: .lastEventID)
        try container.encodeIfPresent(lastEventHash, forKey: .lastEventHash)
        try container.encode(appliedEventIDs, forKey: .appliedEventIDs)
        try container.encode(eventBoundaries, forKey: .eventBoundaries)
    }
}

public enum ScoutReducerError: Error, Equatable, Sendable {
    case emptyReplay
    case authorization(ScoutEventAuthorizationError)
    case writeSchemaMustBeCurrent(expected: EventSchemaVersion, actual: EventSchemaVersion)
    case invalidIntegrity(EventID)
    case unsupportedSchema(EventSchemaVersion)
    case authorizationUnavailableInSchema(eventID: EventID, schemaVersion: EventSchemaVersion)
    case schemaVersionRegression(previous: EventSchemaVersion, actual: EventSchemaVersion)
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
    case derivedEventManifestBaseMismatch(
        receiptID: ModelCallReceiptID,
        expected: ModelInputEventBoundary,
        actual: ModelInputEventBoundary?
    )
    case derivedEventManifestInterrupted(modelCallEventID: EventID, eventID: EventID)
    case derivedEventManifestUnexpectedEvent(modelCallEventID: EventID, eventID: EventID)
    case derivedEventManifestRootMismatch(
        receiptID: ModelCallReceiptID,
        expected: SHA256Digest,
        actual: SHA256Digest
    )
    case incompleteDerivedEventManifest(
        receiptID: ModelCallReceiptID,
        expectedCount: UInt16,
        actualCount: UInt16
    )
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
    case invalidLocalReviewAttestation(LocalReviewTarget)
    case protectedClaimCannotBeSuperseded(ClaimID)
    case missingEntity(EntityID)
    case entityKindConflict(EntityID)
    case entityWasRetired(EntityID)
    case invalidAttributeKey(String)
    case missingRelationship(RelationshipID)
    case relationshipShapeConflict(RelationshipID)
    case relationshipWasRemoved(RelationshipID)
    case emptyClaims(RelationshipID)
}

/// Pure state transition authority for the event-sourced customer model.
public enum ScoutGraphReducer {
    public static func replay(_ events: [ScoutEventEnvelope]) throws -> ScoutState {
        guard let first = events.first else { throw ScoutReducerError.emptyReplay }
        let state = try events.reduce(into: ScoutState(sessionID: first.sessionID)) { state, event in
            state = try reducePersisted(state, event: event)
        }
        try validateBatchTerminal(state)
        return state
    }

    /// Ensures a write/replay batch did not stop after recording a manifest but before applying its
    /// exact committed derived-event sequence. Stores call this on cloned candidate state before
    /// making a batch visible.
    public static func validateBatchTerminal(_ state: ScoutState) throws {
        guard let progress = state.pendingDerivedEventProjections.values.sorted(by: {
            $0.modelCallEventID < $1.modelCallEventID
        }).first else { return }
        throw ScoutReducerError.incompleteDerivedEventManifest(
            receiptID: progress.receiptID,
            expectedCount: progress.manifest.eventCount,
            actualCount: progress.consumedCount
        )
    }

    /// Applies a newly authorized event. Canonical stores accept only this opaque write type.
    public static func reduce(
        _ state: ScoutState,
        event: ValidatedScoutEvent
    ) throws -> ScoutState {
        guard event.envelope.schemaVersion == .current else {
            throw ScoutReducerError.writeSchemaMustBeCurrent(
                expected: .current,
                actual: event.envelope.schemaVersion
            )
        }
        return try reducePersisted(state, event: event.envelope)
    }

    /// Verifies and replays a persisted envelope. This API cannot create an appendable event.
    public static func reducePersisted(
        _ state: ScoutState,
        event: ScoutEventEnvelope
    ) throws -> ScoutState {
        guard event.hasValidIntegrity else {
            throw ScoutReducerError.invalidIntegrity(event.id)
        }
        guard event.schemaVersion.major == EventSchemaVersion.current.major,
              event.schemaVersion.minor <= EventSchemaVersion.current.minor
        else {
            throw ScoutReducerError.unsupportedSchema(event.schemaVersion)
        }
        if event.schemaVersion.minor < 3, event.authorization != nil {
            throw ScoutReducerError.authorizationUnavailableInSchema(
                eventID: event.id,
                schemaVersion: event.schemaVersion
            )
        }
        if let previous = state.lastSchemaVersion, event.schemaVersion < previous {
            throw ScoutReducerError.schemaVersionRegression(
                previous: previous,
                actual: event.schemaVersion
            )
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
        if event.schemaVersion.minor < 4,
           case .localReviewAttested = event.payload
        {
            throw ScoutReducerError.payloadUnavailableInSchema(
                kind: event.payload.kind,
                schemaVersion: event.schemaVersion
            )
        }
        if event.schemaVersion.minor >= 3 {
            do {
                try ScoutEventAuthorizationPolicy.validate(event, in: state)
            } catch let error as ScoutEventAuthorizationError {
                throw ScoutReducerError.authorization(error)
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

        try requirePendingManifestContinuation(event, in: state)

        var next = state
        try apply(event, to: &next)
        try advanceDerivedEventManifest(for: event, in: &next)
        next.eventBoundaries[event.id] = ModelInputEventBoundary(event)
        next.lastSchemaVersion = event.schemaVersion
        next.lastSequence = event.sequence
        next.lastEventID = event.id
        next.lastEventHash = event.integrityHash
        next.appliedEventIDs.insert(event.id)
        return next
    }

    private static func apply(_ event: ScoutEventEnvelope, to state: inout ScoutState) throws {
        switch event.payload {
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
            state.evidenceEvents[evidence.id] = event.id

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
            state.modelCallEvents[event.id] = receipt.id
            try registerDerivedEventManifest(
                receipt,
                modelCallEventID: event.id,
                in: &state
            )

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
            state.visualObservationEvents[observation.id] = event.id

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
            state.visualObservationReviewAttestations[review.observationID] = reviewAttestation(
                for: event
            )
            state.visualObservationReviewEvents[review.observationID] = event.id
            if let authorizationID = event.authorization?.localReviewAuthorization?.id {
                state.consumedReviewAuthorizationIDs.insert(authorizationID)
            }

        case let .entityUpserted(entity):
            let entity = entity.normalized()
            try validateAttributeKeys(entity.attributes)
            try requireEvidence(entity.evidenceIDs, subject: entity.id.rawValue, in: state)
            if let existing = state.graph.entities[entity.id] {
                if event.schemaVersion.minor >= 3,
                   case .retired = existing.lifecycle
                {
                    throw ScoutReducerError.entityWasRetired(entity.id)
                }
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
                if event.schemaVersion.minor >= 3 {
                    let canSupersede = superseded.status == .proposed
                        && (superseded.trust.validationStatus == .unreviewed
                            || superseded.trust.validationStatus == .needsValidation)
                    guard canSupersede else {
                        throw ScoutReducerError.protectedClaimCannotBeSuperseded(supersededID)
                    }
                }
                state.claims[supersededID] = superseded.reviewed(
                    status: .superseded,
                    trust: superseded.trust
                )
            }
            state.claims[claim.id] = claim
            state.claimEvents[claim.id] = event.id

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
            state.claimReviewAttestations[review.claimID] = reviewAttestation(for: event)
            state.claimReviewEvents[review.claimID] = event.id
            if let authorizationID = event.authorization?.localReviewAuthorization?.id {
                state.consumedReviewAuthorizationIDs.insert(authorizationID)
            }

        case let .localReviewAttested(attestation):
            guard let authorization = event.authorization?.localReviewAuthorization else {
                throw ScoutReducerError.invalidLocalReviewAttestation(attestation.target)
            }
            switch attestation.target {
            case let .claim(claimID):
                guard let claim = state.claims[claimID],
                      LocalReviewIntent.isTerminalReviewedClaim(claim),
                      state.claimReviewEvents[claimID] != nil,
                      case .legacyUnattested? = state.claimReviewAttestations[claimID]
                else {
                    throw ScoutReducerError.invalidLocalReviewAttestation(attestation.target)
                }
                state.claimReviewAttestations[claimID] = .deviceOwnerAuthenticated(authorization)

            case let .visualObservation(observationID):
                guard let observation = state.visualObservations[observationID],
                      observation.status == .confirmed || observation.status == .rejected,
                      state.visualObservationReviewEvents[observationID] != nil,
                      case .legacyUnattested? = state.visualObservationReviewAttestations[observationID]
                else {
                    throw ScoutReducerError.invalidLocalReviewAttestation(attestation.target)
                }
                state.visualObservationReviewAttestations[observationID] =
                    .deviceOwnerAuthenticated(authorization)
            }
            state.consumedReviewAuthorizationIDs.insert(authorization.id)

        case let .relationshipUpserted(relationship):
            let relationship = relationship.normalized()
            if event.schemaVersion.minor >= 3,
               state.removedRelationships[relationship.id] != nil
            {
                throw ScoutReducerError.relationshipWasRemoved(relationship.id)
            }
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
            state.removedRelationships[removal.relationshipID] = removal
        }
    }

    private static func registerDerivedEventManifest(
        _ receipt: ModelCallReceipt,
        modelCallEventID: EventID,
        in state: inout ScoutState
    ) throws {
        guard let manifest = receipt.derivedEventManifest else { return }
        let actualBase = currentBoundary(in: state)
        guard actualBase == manifest.projectionBase else {
            throw ScoutReducerError.derivedEventManifestBaseMismatch(
                receiptID: receipt.id,
                expected: manifest.projectionBase,
                actual: actualBase
            )
        }

        let seed = manifest.seed(receiptID: receipt.id, outputHash: receipt.outputHash)
        let progress = DerivedEventProjectionProgress(
            receiptID: receipt.id,
            modelCallEventID: modelCallEventID,
            manifest: manifest,
            consumedCount: 0,
            rollingRoot: seed
        )
        if manifest.eventCount == 0 {
            guard seed == manifest.finalRoot else {
                throw ScoutReducerError.derivedEventManifestRootMismatch(
                    receiptID: receipt.id,
                    expected: manifest.finalRoot,
                    actual: seed
                )
            }
            state.completedDerivedEventProjections[modelCallEventID] = progress
        } else {
            state.pendingDerivedEventProjections[modelCallEventID] = progress
        }
    }

    private static func requirePendingManifestContinuation(
        _ event: ScoutEventEnvelope,
        in state: ScoutState
    ) throws {
        guard let pending = state.pendingDerivedEventProjections.values.sorted(by: {
            $0.modelCallEventID < $1.modelCallEventID
        }).first else { return }
        guard event.authorization?.scope == .modelProjection,
              event.correlationID == pending.modelCallEventID,
              event.causationID == pending.modelCallEventID,
              isDerivedModelPayload(event.payload)
        else {
            throw ScoutReducerError.derivedEventManifestInterrupted(
                modelCallEventID: pending.modelCallEventID,
                eventID: event.id
            )
        }
    }

    private static func advanceDerivedEventManifest(
        for event: ScoutEventEnvelope,
        in state: inout ScoutState
    ) throws {
        guard event.authorization?.scope == .modelProjection,
              isDerivedModelPayload(event.payload),
              let modelCallEventID = event.correlationID,
              modelCallEventID == event.causationID,
              let receiptID = state.modelCallEvents[modelCallEventID],
              let receipt = state.modelCallReceipts[receiptID],
              receipt.derivedEventManifest != nil
        else { return }

        if state.completedDerivedEventProjections[modelCallEventID] != nil {
            throw ScoutReducerError.derivedEventManifestUnexpectedEvent(
                modelCallEventID: modelCallEventID,
                eventID: event.id
            )
        }
        guard let progress = state.pendingDerivedEventProjections[modelCallEventID] else {
            throw ScoutReducerError.derivedEventManifestUnexpectedEvent(
                modelCallEventID: modelCallEventID,
                eventID: event.id
            )
        }

        let entry = DerivedEventManifestEntry(eventID: event.id, payload: event.payload)
        let nextRoot = DerivedEventManifest.advance(
            root: progress.rollingRoot,
            ordinal: progress.consumedCount,
            entry: entry
        )
        let advancedCount = progress.consumedCount.addingReportingOverflow(1)
        guard !advancedCount.overflow,
              advancedCount.partialValue <= progress.manifest.eventCount
        else {
            throw ScoutReducerError.derivedEventManifestUnexpectedEvent(
                modelCallEventID: modelCallEventID,
                eventID: event.id
            )
        }
        let nextCount = advancedCount.partialValue
        let next = DerivedEventProjectionProgress(
            receiptID: progress.receiptID,
            modelCallEventID: progress.modelCallEventID,
            manifest: progress.manifest,
            consumedCount: nextCount,
            rollingRoot: nextRoot
        )

        if nextCount == progress.manifest.eventCount {
            guard nextRoot == progress.manifest.finalRoot else {
                throw ScoutReducerError.derivedEventManifestRootMismatch(
                    receiptID: progress.receiptID,
                    expected: progress.manifest.finalRoot,
                    actual: nextRoot
                )
            }
            state.pendingDerivedEventProjections.removeValue(forKey: modelCallEventID)
            state.completedDerivedEventProjections[modelCallEventID] = next
        } else {
            state.pendingDerivedEventProjections[modelCallEventID] = next
        }
    }

    private static func isDerivedModelPayload(_ payload: ScoutEventPayload) -> Bool {
        switch payload {
        case .visualObservationProposed,
             .entityUpserted,
             .claimProposed,
             .relationshipUpserted:
            true
        default:
            false
        }
    }

    private static func reviewAttestation(for event: ScoutEventEnvelope) -> LocalReviewAttestation {
        if let authorization = event.authorization?.localReviewAuthorization {
            return .deviceOwnerAuthenticated(authorization)
        }
        return .legacyUnattested(schemaVersion: event.schemaVersion)
    }

    private static func currentBoundary(in state: ScoutState) -> ModelInputEventBoundary? {
        guard let lastEventID = state.lastEventID else { return nil }
        return state.eventBoundaries[lastEventID]
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
