import Foundation

public struct EventSchemaVersion: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    /// v1.1 adds model receipts; v1.2 adds reviewable visual observations; v1.3 records command
    /// authority; v1.4 commits exact model projections and authenticated local reviews. Older
    /// envelopes remain replayable under their historical rules.
    public static let current = EventSchemaVersion(major: 1, minor: 4)

    public static func < (lhs: EventSchemaVersion, rhs: EventSchemaVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var canonicalValue: CanonicalValue {
        .object(["major": .unsigned(UInt64(major)), "minor": .unsigned(UInt64(minor))])
    }
}

public struct SessionEnded: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let endedAt: ScoutTimestamp

    public init(endedAt: ScoutTimestamp) { self.endedAt = endedAt }

    public var canonicalValue: CanonicalValue {
        .object(["endedAt": endedAt.canonicalValue])
    }
}

public struct ClaimReviewed: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let claimID: ClaimID
    public let status: ClaimStatus
    public let trust: TrustAssessment

    public init(claimID: ClaimID, status: ClaimStatus, trust: TrustAssessment) {
        self.claimID = claimID
        self.status = status
        self.trust = trust
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "claimID": claimID.canonicalValue,
            "status": status.canonicalValue,
            "trust": trust.canonicalValue,
        ])
    }
}

/// Append-only device-owner attestation of a terminal review recorded by a legacy schema.
///
/// The target's exact terminal state and original review event are carried by the authenticated
/// authorization record. This payload deliberately does not repeat or replace the historical
/// decision.
public struct LocalReviewAttested: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let target: LocalReviewTarget

    public init(target: LocalReviewTarget) {
        self.target = target
    }

    public var canonicalValue: CanonicalValue {
        .object(["target": target.canonicalValue])
    }
}

public struct EntityRetired: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let entityID: EntityID
    public let reason: NonEmptyString

    public init(entityID: EntityID, reason: NonEmptyString) {
        self.entityID = entityID
        self.reason = reason
    }

    public var canonicalValue: CanonicalValue {
        .object(["entityID": entityID.canonicalValue, "reason": reason.canonicalValue])
    }
}

public struct RelationshipRemoved: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let relationshipID: RelationshipID
    public let reason: NonEmptyString

    public init(relationshipID: RelationshipID, reason: NonEmptyString) {
        self.relationshipID = relationshipID
        self.reason = reason
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "relationshipID": relationshipID.canonicalValue,
            "reason": reason.canonicalValue,
        ])
    }
}

/// All state-changing facts enter Scout through this closed, versioned union.
public enum ScoutEventPayload: Codable, Equatable, Sendable, CanonicalRepresentable {
    case sessionStarted(DiscoverySession)
    case sessionEnded(SessionEnded)
    case speakerUpserted(Speaker)
    case utteranceFinalized(Utterance)
    case evidenceRecorded(Evidence)
    case modelCallRecorded(ModelCallReceipt)
    case visualObservationProposed(VisualObservation)
    case visualObservationReviewed(VisualObservationReviewed)
    case entityUpserted(GraphEntity)
    case entityRetired(EntityRetired)
    case claimProposed(Claim)
    case claimReviewed(ClaimReviewed)
    case localReviewAttested(LocalReviewAttested)
    case relationshipUpserted(GraphRelationship)
    case relationshipRemoved(RelationshipRemoved)

    public var kind: String {
        switch self {
        case .sessionStarted: "session.started"
        case .sessionEnded: "session.ended"
        case .speakerUpserted: "speaker.upserted"
        case .utteranceFinalized: "utterance.finalized"
        case .evidenceRecorded: "evidence.recorded"
        case .modelCallRecorded: "modelCall.recorded"
        case .visualObservationProposed: "visualObservation.proposed"
        case .visualObservationReviewed: "visualObservation.reviewed"
        case .entityUpserted: "entity.upserted"
        case .entityRetired: "entity.retired"
        case .claimProposed: "claim.proposed"
        case .claimReviewed: "claim.reviewed"
        case .localReviewAttested: "localReview.attested"
        case .relationshipUpserted: "relationship.upserted"
        case .relationshipRemoved: "relationship.removed"
        }
    }

    public var canonicalValue: CanonicalValue {
        let data: CanonicalValue = switch self {
        case let .sessionStarted(value): value.canonicalValue
        case let .sessionEnded(value): value.canonicalValue
        case let .speakerUpserted(value): value.canonicalValue
        case let .utteranceFinalized(value): value.canonicalValue
        case let .evidenceRecorded(value): value.canonicalValue
        case let .modelCallRecorded(value): value.canonicalValue
        case let .visualObservationProposed(value): value.canonicalValue
        case let .visualObservationReviewed(value): value.canonicalValue
        case let .entityUpserted(value): value.canonicalValue
        case let .entityRetired(value): value.canonicalValue
        case let .claimProposed(value): value.canonicalValue
        case let .claimReviewed(value): value.canonicalValue
        case let .localReviewAttested(value): value.canonicalValue
        case let .relationshipUpserted(value): value.canonicalValue
        case let .relationshipRemoved(value): value.canonicalValue
        }
        return .object(["type": .string(kind), "data": data])
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "session.started":
            self = .sessionStarted(try container.decode(DiscoverySession.self, forKey: .data))
        case "session.ended":
            self = .sessionEnded(try container.decode(SessionEnded.self, forKey: .data))
        case "speaker.upserted":
            self = .speakerUpserted(try container.decode(Speaker.self, forKey: .data))
        case "utterance.finalized":
            self = .utteranceFinalized(try container.decode(Utterance.self, forKey: .data))
        case "evidence.recorded":
            self = .evidenceRecorded(try container.decode(Evidence.self, forKey: .data))
        case "modelCall.recorded":
            self = .modelCallRecorded(try container.decode(ModelCallReceipt.self, forKey: .data))
        case "visualObservation.proposed":
            self = .visualObservationProposed(
                try container.decode(VisualObservation.self, forKey: .data)
            )
        case "visualObservation.reviewed":
            self = .visualObservationReviewed(
                try container.decode(VisualObservationReviewed.self, forKey: .data)
            )
        case "entity.upserted":
            self = .entityUpserted(try container.decode(GraphEntity.self, forKey: .data))
        case "entity.retired":
            self = .entityRetired(try container.decode(EntityRetired.self, forKey: .data))
        case "claim.proposed":
            self = .claimProposed(try container.decode(Claim.self, forKey: .data))
        case "claim.reviewed":
            self = .claimReviewed(try container.decode(ClaimReviewed.self, forKey: .data))
        case "localReview.attested":
            self = .localReviewAttested(
                try container.decode(LocalReviewAttested.self, forKey: .data)
            )
        case "relationship.upserted":
            self = .relationshipUpserted(
                try container.decode(GraphRelationship.self, forKey: .data)
            )
        case "relationship.removed":
            self = .relationshipRemoved(
                try container.decode(RelationshipRemoved.self, forKey: .data)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported Scout event payload type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case let .sessionStarted(value): try container.encode(value, forKey: .data)
        case let .sessionEnded(value): try container.encode(value, forKey: .data)
        case let .speakerUpserted(value): try container.encode(value, forKey: .data)
        case let .utteranceFinalized(value): try container.encode(value, forKey: .data)
        case let .evidenceRecorded(value): try container.encode(value, forKey: .data)
        case let .modelCallRecorded(value): try container.encode(value, forKey: .data)
        case let .visualObservationProposed(value): try container.encode(value, forKey: .data)
        case let .visualObservationReviewed(value): try container.encode(value, forKey: .data)
        case let .entityUpserted(value): try container.encode(value, forKey: .data)
        case let .entityRetired(value): try container.encode(value, forKey: .data)
        case let .claimProposed(value): try container.encode(value, forKey: .data)
        case let .claimReviewed(value): try container.encode(value, forKey: .data)
        case let .localReviewAttested(value): try container.encode(value, forKey: .data)
        case let .relationshipUpserted(value): try container.encode(value, forKey: .data)
        case let .relationshipRemoved(value): try container.encode(value, forKey: .data)
        }
    }
}

/// Immutable event envelope with content integrity and predecessor linkage.
public struct ScoutEventEnvelope: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let schemaVersion: EventSchemaVersion
    public let id: EventID
    public let sessionID: SessionID
    public let sequence: EventSequence
    public let occurredAt: ScoutTimestamp
    public let recordedAt: ScoutTimestamp
    public let actor: EventActor
    public let authorization: EventAuthorizationRecord?
    public let correlationID: EventID?
    public let causationID: EventID?
    public let payload: ScoutEventPayload
    public let previousHash: SHA256Digest?
    public let integrityHash: SHA256Digest

    private init(
        schemaVersion: EventSchemaVersion,
        id: EventID,
        sessionID: SessionID,
        sequence: EventSequence,
        occurredAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp,
        actor: EventActor,
        authorization: EventAuthorizationRecord?,
        correlationID: EventID?,
        causationID: EventID?,
        payload: ScoutEventPayload,
        previousHash: SHA256Digest?,
        integrityHash: SHA256Digest
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.actor = actor
        self.authorization = authorization
        self.correlationID = correlationID
        self.causationID = causationID
        self.payload = payload
        self.previousHash = previousHash
        self.integrityHash = integrityHash
    }

    static func seal(
        schemaVersion: EventSchemaVersion = .current,
        id: EventID,
        sessionID: SessionID,
        sequence: EventSequence,
        occurredAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp,
        actor: EventActor,
        authorization: EventAuthorizationRecord? = nil,
        correlationID: EventID? = nil,
        causationID: EventID? = nil,
        payload: ScoutEventPayload,
        previousHash: SHA256Digest?
    ) -> ScoutEventEnvelope {
        let unsigned = unsignedCanonicalValue(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            sequence: sequence,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            actor: actor,
            authorization: authorization,
            correlationID: correlationID,
            causationID: causationID,
            payload: payload,
            previousHash: previousHash
        )
        return ScoutEventEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            sequence: sequence,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            actor: actor,
            authorization: authorization,
            correlationID: correlationID,
            causationID: causationID,
            payload: payload,
            previousHash: previousHash,
            integrityHash: .hash(unsigned)
        )
    }

    public var hasValidIntegrity: Bool {
        integrityHash == SHA256Digest.hash(unsignedCanonicalValue)
    }

    public var unsignedCanonicalValue: CanonicalValue {
        Self.unsignedCanonicalValue(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            sequence: sequence,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            actor: actor,
            authorization: authorization,
            correlationID: correlationID,
            causationID: causationID,
            payload: payload,
            previousHash: previousHash
        )
    }

    public var canonicalValue: CanonicalValue {
        guard case var .object(object) = unsignedCanonicalValue else {
            preconditionFailure("Envelope canonical value must be an object")
        }
        object["integrityHash"] = integrityHash.canonicalValue
        return .object(object)
    }

    private static func unsignedCanonicalValue(
        schemaVersion: EventSchemaVersion,
        id: EventID,
        sessionID: SessionID,
        sequence: EventSequence,
        occurredAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp,
        actor: EventActor,
        authorization: EventAuthorizationRecord?,
        correlationID: EventID?,
        causationID: EventID?,
        payload: ScoutEventPayload,
        previousHash: SHA256Digest?
    ) -> CanonicalValue {
        var object: [String: CanonicalValue] = [
            "schemaVersion": schemaVersion.canonicalValue,
            "id": id.canonicalValue,
            "sessionID": sessionID.canonicalValue,
            "sequence": sequence.canonicalValue,
            "occurredAt": occurredAt.canonicalValue,
            "recordedAt": recordedAt.canonicalValue,
            "actor": actor.canonicalValue,
            "correlationID": correlationID.canonicalValue,
            "causationID": causationID.canonicalValue,
            "payload": payload.canonicalValue,
            "previousHash": previousHash.canonicalValue,
        ]
        if schemaVersion.major == 1, schemaVersion.minor >= 3 {
            object["authorization"] = authorization.canonicalValue
        }
        return .object(object)
    }
}

/// Deterministic value-type helper for producing a correctly sequenced chain.
/// Callers provide event IDs and timestamps; no hidden clock or randomness enters
/// the domain core.
public struct EventChainBuilder: Sendable {
    public let sessionID: SessionID
    public private(set) var nextSequence: EventSequence
    public private(set) var previousHash: SHA256Digest?

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
        nextSequence = try! EventSequence(1)
        previousHash = nil
    }

    public init(
        sessionID: SessionID,
        nextSequence: EventSequence,
        previousHash: SHA256Digest?
    ) {
        self.sessionID = sessionID
        self.nextSequence = nextSequence
        self.previousHash = previousHash
    }

    mutating func seal(
        schemaVersion: EventSchemaVersion = .current,
        id: EventID,
        occurredAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp,
        actor: EventActor,
        authorization: EventAuthorizationRecord? = nil,
        correlationID: EventID? = nil,
        causationID: EventID? = nil,
        payload: ScoutEventPayload
    ) throws -> ScoutEventEnvelope {
        let envelope = ScoutEventEnvelope.seal(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            sequence: nextSequence,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            actor: actor,
            authorization: authorization,
            correlationID: correlationID,
            causationID: causationID,
            payload: payload,
            previousHash: previousHash
        )
        nextSequence = try nextSequence.successor()
        previousHash = envelope.integrityHash
        return envelope
    }

    /// Resolves one closed semantic command into an appendable event. Actor attribution and commit
    /// authority are derived from the command and cannot be supplied as an arbitrary pair. New
    /// writes always use the current schema; older schemas are replay-only compatibility surfaces.
    public mutating func seal(
        id: EventID,
        occurredAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp,
        correlationID: EventID? = nil,
        causationID: EventID? = nil,
        command: ScoutEventCommand
    ) throws -> ValidatedScoutEvent {
        let resolved = command.resolved
        let envelope = try seal(
            schemaVersion: .current,
            id: id,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            actor: resolved.actor,
            authorization: resolved.authorization,
            correlationID: correlationID,
            causationID: causationID,
            payload: resolved.payload
        )
        return ValidatedScoutEvent(envelope: envelope)
    }

    /// Seals one device-owner-authenticated review decision.
    ///
    /// The event ID, session, target revision, and exact payload are all carried by the opaque
    /// capability. Callers cannot substitute any of them at this boundary.
    public mutating func seal(
        occurredAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp,
        authenticatedReview: AuthenticatedLocalReview
    ) throws -> ValidatedScoutEvent {
        let intent = authenticatedReview.intent
        guard intent.sessionID == sessionID else {
            throw LocalReviewAuthorizationError.sessionMismatch(
                expected: sessionID,
                actual: intent.sessionID
            )
        }
        let component = try NonEmptyString(validating: "scout-macos-review-ui")
        let envelope = try seal(
            schemaVersion: .current,
            id: intent.eventID,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            actor: .system(component: component),
            authorization: EventAuthorizationRecord(
                scope: .localReview,
                component: component,
                localReviewAuthorization: authenticatedReview.authorization
            ),
            payload: intent.operation.payload
        )
        return ValidatedScoutEvent(envelope: envelope)
    }
}
