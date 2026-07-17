import Foundation

public enum TrustOrigin: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case heard
    case observed
    case inferred
    case suggested
    case confirmed
    case corrected

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public enum ValidationStatus: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case unreviewed
    case needsValidation
    case validated
    case disputed
    case rejected

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

/// Trust is explicit domain data, rather than a UI decoration.
public struct TrustAssessment: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let origin: TrustOrigin
    public let confidence: Confidence
    public let validationStatus: ValidationStatus
    public let rationale: NonEmptyString?

    public init(
        origin: TrustOrigin,
        confidence: Confidence,
        validationStatus: ValidationStatus,
        rationale: NonEmptyString? = nil
    ) {
        self.origin = origin
        self.confidence = confidence
        self.validationStatus = validationStatus
        self.rationale = rationale
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "origin": origin.canonicalValue,
            "confidence": confidence.canonicalValue,
            "validationStatus": validationStatus.canonicalValue,
            "rationale": rationale.canonicalValue,
        ])
    }
}

public struct AssetLocator: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let assetID: AssetID
    public let mediaType: NonEmptyString
    public let contentHash: SHA256Digest?
    public let page: UInt64?

    public init(
        assetID: AssetID,
        mediaType: NonEmptyString,
        contentHash: SHA256Digest? = nil,
        page: UInt64? = nil
    ) {
        self.assetID = assetID
        self.mediaType = mediaType
        self.contentHash = contentHash
        self.page = page
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "assetID": assetID.canonicalValue,
            "mediaType": mediaType.canonicalValue,
            "contentHash": contentHash.canonicalValue,
            "page": page.map(CanonicalValue.unsigned) ?? .null,
        ])
    }
}

public enum EvidenceSource: Codable, Equatable, Sendable, CanonicalRepresentable {
    case utterance(UtteranceID)
    case image(AssetLocator)
    case document(AssetLocator)
    case manualNote(noteID: NonEmptyString)
    case external(reference: NonEmptyString)

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .utterance(id): tagged("utterance", id.canonicalValue)
        case let .image(locator): tagged("image", locator.canonicalValue)
        case let .document(locator): tagged("document", locator.canonicalValue)
        case let .manualNote(noteID): tagged("manualNote", noteID.canonicalValue)
        case let .external(reference): tagged("external", reference.canonicalValue)
        }
    }

    private func tagged(_ type: String, _ value: CanonicalValue) -> CanonicalValue {
        .object(["type": .string(type), "value": value])
    }
}

public struct Evidence: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: EvidenceID
    public let source: EvidenceSource
    public let excerpt: NonEmptyString?
    public let capturedAt: ScoutTimestamp
    public let capturedBy: EventActor

    public init(
        id: EvidenceID,
        source: EvidenceSource,
        excerpt: NonEmptyString? = nil,
        capturedAt: ScoutTimestamp,
        capturedBy: EventActor
    ) {
        self.id = id
        self.source = source
        self.excerpt = excerpt
        self.capturedAt = capturedAt
        self.capturedBy = capturedBy
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "source": source.canonicalValue,
            "excerpt": excerpt.canonicalValue,
            "capturedAt": capturedAt.canonicalValue,
            "capturedBy": capturedBy.canonicalValue,
        ])
    }
}

public enum ClaimSubject: Codable, Hashable, Sendable, CanonicalRepresentable {
    case entity(EntityID)
    case session(SessionID)

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .entity(id): .object(["type": .string("entity"), "value": id.canonicalValue])
        case let .session(id): .object(["type": .string("session"), "value": id.canonicalValue])
        }
    }
}

public enum ClaimPredicate: Codable, Hashable, Sendable, CanonicalRepresentable {
    case uses
    case storesDataIn
    case owns
    case participatesIn
    case dependsOn
    case governedBy
    case triggers
    case blocks
    case precedes
    case measures
    case targets
    case produces
    case consumes
    case hasPainPoint
    case hasGoal
    case custom(NonEmptyString)

    public var canonicalValue: CanonicalValue {
        switch self {
        case .uses: .string("uses")
        case .storesDataIn: .string("storesDataIn")
        case .owns: .string("owns")
        case .participatesIn: .string("participatesIn")
        case .dependsOn: .string("dependsOn")
        case .governedBy: .string("governedBy")
        case .triggers: .string("triggers")
        case .blocks: .string("blocks")
        case .precedes: .string("precedes")
        case .measures: .string("measures")
        case .targets: .string("targets")
        case .produces: .string("produces")
        case .consumes: .string("consumes")
        case .hasPainPoint: .string("hasPainPoint")
        case .hasGoal: .string("hasGoal")
        case let .custom(value): .object(["custom": value.canonicalValue])
        }
    }
}

public enum ClaimObject: Codable, Hashable, Sendable, CanonicalRepresentable {
    case entity(EntityID)
    case value(AttributeValue)

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .entity(id): .object(["type": .string("entity"), "value": id.canonicalValue])
        case let .value(value): .object(["type": .string("value"), "value": value.canonicalValue])
        }
    }
}

public enum ClaimStatus: String, Codable, Sendable, CanonicalRepresentable {
    case proposed
    case accepted
    case rejected
    case superseded

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public struct Claim: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: ClaimID
    public let subject: ClaimSubject
    public let predicate: ClaimPredicate
    public let object: ClaimObject
    public let assertedBy: SpeakerID?
    public let evidenceIDs: [EvidenceID]
    public let trust: TrustAssessment
    public let status: ClaimStatus
    public let supersedes: ClaimID?

    public init(
        id: ClaimID,
        subject: ClaimSubject,
        predicate: ClaimPredicate,
        object: ClaimObject,
        assertedBy: SpeakerID? = nil,
        evidenceIDs: [EvidenceID],
        trust: TrustAssessment,
        status: ClaimStatus = .proposed,
        supersedes: ClaimID? = nil
    ) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.assertedBy = assertedBy
        self.evidenceIDs = normalizedUnique(evidenceIDs)
        self.trust = trust
        self.status = status
        self.supersedes = supersedes
    }

    func reviewed(status: ClaimStatus, trust: TrustAssessment) -> Claim {
        Claim(
            id: id,
            subject: subject,
            predicate: predicate,
            object: object,
            assertedBy: assertedBy,
            evidenceIDs: evidenceIDs,
            trust: trust,
            status: status,
            supersedes: supersedes
        )
    }

    func normalized() -> Claim {
        Claim(
            id: id,
            subject: subject,
            predicate: predicate,
            object: object,
            assertedBy: assertedBy,
            evidenceIDs: evidenceIDs,
            trust: trust,
            status: status,
            supersedes: supersedes
        )
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "subject": subject.canonicalValue,
            "predicate": predicate.canonicalValue,
            "object": object.canonicalValue,
            "assertedBy": assertedBy.canonicalValue,
            "evidenceIDs": .array(evidenceIDs.sorted().map(\.canonicalValue)),
            "trust": trust.canonicalValue,
            "status": status.canonicalValue,
            "supersedes": supersedes.canonicalValue,
        ])
    }
}
