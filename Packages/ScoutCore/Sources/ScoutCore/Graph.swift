import Foundation

public enum EntityLifecycle: Codable, Equatable, Sendable, CanonicalRepresentable {
    case active
    case retired(reason: NonEmptyString)

    public var canonicalValue: CanonicalValue {
        switch self {
        case .active: .object(["type": .string("active")])
        case let .retired(reason):
            .object(["type": .string("retired"), "reason": reason.canonicalValue])
        }
    }
}

public struct GraphEntity: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: EntityID
    public let kind: PrimitiveKind
    public let canonicalName: NonEmptyString
    public let aliases: [NonEmptyString]
    public let attributes: [String: AttributeValue]
    public let evidenceIDs: [EvidenceID]
    public let trust: TrustAssessment
    public let lifecycle: EntityLifecycle

    public init(
        id: EntityID,
        kind: PrimitiveKind,
        canonicalName: NonEmptyString,
        aliases: [NonEmptyString] = [],
        attributes: [String: AttributeValue] = [:],
        evidenceIDs: [EvidenceID],
        trust: TrustAssessment,
        lifecycle: EntityLifecycle = .active
    ) {
        self.id = id
        self.kind = kind
        self.canonicalName = canonicalName
        self.aliases = normalizedUnique(aliases)
        self.attributes = attributes
        self.evidenceIDs = normalizedUnique(evidenceIDs)
        self.trust = trust
        self.lifecycle = lifecycle
    }

    func merging(_ newer: GraphEntity) -> GraphEntity {
        GraphEntity(
            id: id,
            kind: kind,
            canonicalName: newer.canonicalName,
            aliases: aliases + newer.aliases,
            attributes: attributes.merging(newer.attributes) { _, new in new },
            evidenceIDs: evidenceIDs + newer.evidenceIDs,
            trust: newer.trust,
            lifecycle: newer.lifecycle
        )
    }

    func normalized() -> GraphEntity {
        GraphEntity(
            id: id,
            kind: kind,
            canonicalName: canonicalName,
            aliases: aliases,
            attributes: attributes,
            evidenceIDs: evidenceIDs,
            trust: trust,
            lifecycle: lifecycle
        )
    }

    func retiring(reason: NonEmptyString) -> GraphEntity {
        GraphEntity(
            id: id,
            kind: kind,
            canonicalName: canonicalName,
            aliases: aliases,
            attributes: attributes,
            evidenceIDs: evidenceIDs,
            trust: trust,
            lifecycle: .retired(reason: reason)
        )
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "kind": kind.canonicalValue,
            "canonicalName": canonicalName.canonicalValue,
            "aliases": .array(aliases.sorted().map(\.canonicalValue)),
            "attributes": .object(attributes.mapValues(\.canonicalValue)),
            "evidenceIDs": .array(evidenceIDs.sorted().map(\.canonicalValue)),
            "trust": trust.canonicalValue,
            "lifecycle": lifecycle.canonicalValue,
        ])
    }
}

public enum RelationshipKind: Codable, Hashable, Sendable, CanonicalRepresentable {
    case uses
    case stores
    case owns
    case dependsOn
    case governs
    case triggers
    case blocks
    case precedes
    case produces
    case consumes
    case measures
    case targets
    case custom(NonEmptyString)

    public var canonicalValue: CanonicalValue {
        switch self {
        case .uses: .string("uses")
        case .stores: .string("stores")
        case .owns: .string("owns")
        case .dependsOn: .string("dependsOn")
        case .governs: .string("governs")
        case .triggers: .string("triggers")
        case .blocks: .string("blocks")
        case .precedes: .string("precedes")
        case .produces: .string("produces")
        case .consumes: .string("consumes")
        case .measures: .string("measures")
        case .targets: .string("targets")
        case let .custom(value): .object(["custom": value.canonicalValue])
        }
    }
}

public struct GraphRelationship: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: RelationshipID
    public let sourceID: EntityID
    public let targetID: EntityID
    public let kind: RelationshipKind
    public let label: NonEmptyString?
    public let attributes: [String: AttributeValue]
    public let claimIDs: [ClaimID]
    public let evidenceIDs: [EvidenceID]
    public let trust: TrustAssessment

    public init(
        id: RelationshipID,
        sourceID: EntityID,
        targetID: EntityID,
        kind: RelationshipKind,
        label: NonEmptyString? = nil,
        attributes: [String: AttributeValue] = [:],
        claimIDs: [ClaimID],
        evidenceIDs: [EvidenceID],
        trust: TrustAssessment
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.label = label
        self.attributes = attributes
        self.claimIDs = normalizedUnique(claimIDs)
        self.evidenceIDs = normalizedUnique(evidenceIDs)
        self.trust = trust
    }

    func merging(_ newer: GraphRelationship) -> GraphRelationship {
        GraphRelationship(
            id: id,
            sourceID: sourceID,
            targetID: targetID,
            kind: kind,
            label: newer.label ?? label,
            attributes: attributes.merging(newer.attributes) { _, new in new },
            claimIDs: claimIDs + newer.claimIDs,
            evidenceIDs: evidenceIDs + newer.evidenceIDs,
            trust: newer.trust
        )
    }

    func normalized() -> GraphRelationship {
        GraphRelationship(
            id: id,
            sourceID: sourceID,
            targetID: targetID,
            kind: kind,
            label: label,
            attributes: attributes,
            claimIDs: claimIDs,
            evidenceIDs: evidenceIDs,
            trust: trust
        )
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "sourceID": sourceID.canonicalValue,
            "targetID": targetID.canonicalValue,
            "kind": kind.canonicalValue,
            "label": label.canonicalValue,
            "attributes": .object(attributes.mapValues(\.canonicalValue)),
            "claimIDs": .array(claimIDs.sorted().map(\.canonicalValue)),
            "evidenceIDs": .array(evidenceIDs.sorted().map(\.canonicalValue)),
            "trust": trust.canonicalValue,
        ])
    }
}

public struct CustomerGraph: Codable, Equatable, Sendable, CanonicalRepresentable {
    public internal(set) var entities: [EntityID: GraphEntity]
    public internal(set) var relationships: [RelationshipID: GraphRelationship]

    public init(
        entities: [EntityID: GraphEntity] = [:],
        relationships: [RelationshipID: GraphRelationship] = [:]
    ) {
        self.entities = entities
        self.relationships = relationships
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "entities": .array(entities.values.sorted { $0.id < $1.id }.map(\.canonicalValue)),
            "relationships": .array(
                relationships.values.sorted { $0.id < $1.id }.map(\.canonicalValue)
            ),
        ])
    }

    public var digest: SHA256Digest { .hash(canonicalValue) }
}
