import Foundation

public enum AttributeValue: Codable, Hashable, Sendable, CanonicalRepresentable {
    case text(String)
    case integer(Int64)
    case boolean(Bool)
    case decimal(ExactDecimal)
    case timestamp(ScoutTimestamp)
    case durationMilliseconds(Int64)
    case strings([String])

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .text(value): tagged("text", .string(value))
        case let .integer(value): tagged("integer", .integer(value))
        case let .boolean(value): tagged("boolean", .bool(value))
        case let .decimal(value): tagged("decimal", value.canonicalValue)
        case let .timestamp(value): tagged("timestamp", value.canonicalValue)
        case let .durationMilliseconds(value): tagged("durationMilliseconds", .integer(value))
        case let .strings(values): tagged("strings", .array(values.map(CanonicalValue.string)))
        }
    }

    private func tagged(_ type: String, _ value: CanonicalValue) -> CanonicalValue {
        .object(["type": .string(type), "value": value])
    }
}

/// Universal enterprise primitives. Architecture and process diagrams are
/// projections over these shared building blocks, not independent truth stores.
public enum PrimitiveKind: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case person
    case team
    case organization
    case system
    case dataAsset
    case process
    case policy
    case regulation
    case action
    case temporalConstraint
    case goal
    case valueDriver
    case metric
    case capability
    case constraint
    case risk

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public struct DiscoverySession: Codable, Equatable, Sendable, CanonicalRepresentable {
    public enum Status: String, Codable, Sendable, CanonicalRepresentable {
        case active
        case ended

        public var canonicalValue: CanonicalValue { .string(rawValue) }
    }

    public let id: SessionID
    public let title: NonEmptyString
    public let startedAt: ScoutTimestamp
    public let endedAt: ScoutTimestamp?
    public let status: Status

    public init(
        id: SessionID,
        title: NonEmptyString,
        startedAt: ScoutTimestamp,
        endedAt: ScoutTimestamp? = nil,
        status: Status = .active
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
    }

    func ending(at timestamp: ScoutTimestamp) -> DiscoverySession {
        DiscoverySession(id: id, title: title, startedAt: startedAt, endedAt: timestamp, status: .ended)
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "title": title.canonicalValue,
            "startedAt": startedAt.canonicalValue,
            "endedAt": endedAt.canonicalValue,
            "status": status.canonicalValue,
        ])
    }
}

public struct Speaker: Codable, Equatable, Sendable, CanonicalRepresentable {
    public enum Affiliation: String, Codable, Sendable, CanonicalRepresentable {
        case customer
        case internalTeam
        case partner
        case unknown

        public var canonicalValue: CanonicalValue { .string(rawValue) }
    }

    public let id: SpeakerID
    public let displayName: NonEmptyString
    public let role: NonEmptyString?
    public let organization: NonEmptyString?
    public let affiliation: Affiliation
    public let voiceprintReference: String?

    public init(
        id: SpeakerID,
        displayName: NonEmptyString,
        role: NonEmptyString? = nil,
        organization: NonEmptyString? = nil,
        affiliation: Affiliation = .unknown,
        voiceprintReference: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.organization = organization
        self.affiliation = affiliation
        self.voiceprintReference = voiceprintReference
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "displayName": displayName.canonicalValue,
            "role": role.canonicalValue,
            "organization": organization.canonicalValue,
            "affiliation": affiliation.canonicalValue,
            "voiceprintReference": voiceprintReference.canonicalStringValue,
        ])
    }
}

public struct Utterance: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: UtteranceID
    public let speakerID: SpeakerID
    public let startedAt: ScoutTimestamp
    public let endedAt: ScoutTimestamp
    public let text: NonEmptyString
    public let transcriptionConfidence: Confidence
    public let languageCode: String?

    public init(
        id: UtteranceID,
        speakerID: SpeakerID,
        startedAt: ScoutTimestamp,
        endedAt: ScoutTimestamp,
        text: NonEmptyString,
        transcriptionConfidence: Confidence,
        languageCode: String? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.text = text
        self.transcriptionConfidence = transcriptionConfidence
        self.languageCode = languageCode
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "speakerID": speakerID.canonicalValue,
            "startedAt": startedAt.canonicalValue,
            "endedAt": endedAt.canonicalValue,
            "text": text.canonicalValue,
            "transcriptionConfidence": transcriptionConfidence.canonicalValue,
            "languageCode": languageCode.canonicalStringValue,
        ])
    }
}

public struct ModelIdentity: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let provider: NonEmptyString
    public let model: NonEmptyString
    public let operationVersion: NonEmptyString

    public init(provider: NonEmptyString, model: NonEmptyString, operationVersion: NonEmptyString) {
        self.provider = provider
        self.model = model
        self.operationVersion = operationVersion
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "provider": provider.canonicalValue,
            "model": model.canonicalValue,
            "operationVersion": operationVersion.canonicalValue,
        ])
    }
}

public enum EventActor: Codable, Equatable, Sendable, CanonicalRepresentable {
    case speaker(SpeakerID)
    case model(ModelIdentity)
    case system(component: NonEmptyString)

    public var canonicalValue: CanonicalValue {
        switch self {
        case let .speaker(id):
            .object(["type": .string("speaker"), "value": id.canonicalValue])
        case let .model(identity):
            .object(["type": .string("model"), "value": identity.canonicalValue])
        case let .system(component):
            .object(["type": .string("system"), "value": component.canonicalValue])
        }
    }
}
