import Foundation

/// Stable reasons for invoking a model. Keeping purpose separate from a prompt
/// version lets Scout compare receipts across prompt and schema revisions.
public enum ModelCallPurpose: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case realtimeTranscription
    case transcriptionRefinement
    case speakerDiarization
    case claimExtraction
    case entityResolution
    case discoveryQuestionGeneration
    case whiteboardExtraction
    case actionPackGeneration

    public var canonicalValue: CanonicalValue {
        .string(rawValue)
    }
}

/// The exact event-log prefix supplied to a model call.
///
/// All three values are retained so the reducer can prove that the model did
/// not receive a future, missing, or differently hashed event boundary.
public struct ModelInputEventBoundary: Codable, Hashable, Sendable, CanonicalRepresentable {
    public let eventID: EventID
    public let sequence: EventSequence
    public let integrityHash: SHA256Digest

    public init(eventID: EventID, sequence: EventSequence, integrityHash: SHA256Digest) {
        self.eventID = eventID
        self.sequence = sequence
        self.integrityHash = integrityHash
    }

    public init(_ event: ScoutEventEnvelope) {
        self.init(
            eventID: event.id,
            sequence: event.sequence,
            integrityHash: event.integrityHash
        )
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "eventID": eventID.canonicalValue,
            "sequence": sequence.canonicalValue,
            "integrityHash": integrityHash.canonicalValue,
        ])
    }
}

public enum ModelCallReceiptValidationError: Error, Equatable, Sendable {
    case invalidProvider(String)
    case invalidToken(field: String, value: String)
    case tooManyMetadataEntries(Int)
    case invalidMetadataKey(String)
}

/// Immutable provenance for one provider response.
///
/// The receipt records identity and hashes, never raw prompts or model output.
/// `metadata` is intentionally bounded and is suitable for non-sensitive usage
/// counters, latency, and provider routing facts.
public struct ModelCallReceipt: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: ModelCallReceiptID
    public let provider: NonEmptyString
    public let providerResponseID: NonEmptyString
    public let purpose: ModelCallPurpose
    public let inputBoundary: ModelInputEventBoundary
    public let promptVersion: NonEmptyString
    public let outputSchemaVersion: NonEmptyString
    public let model: NonEmptyString
    public let outputHash: SHA256Digest
    public let metadata: [String: AttributeValue]

    public init(
        id: ModelCallReceiptID,
        provider: NonEmptyString,
        providerResponseID: NonEmptyString,
        purpose: ModelCallPurpose,
        inputBoundary: ModelInputEventBoundary,
        promptVersion: NonEmptyString,
        outputSchemaVersion: NonEmptyString,
        model: NonEmptyString,
        outputHash: SHA256Digest,
        metadata: [String: AttributeValue] = [:]
    ) throws {
        guard Self.isProvider(provider.rawValue) else {
            throw ModelCallReceiptValidationError.invalidProvider(provider.rawValue)
        }
        for (field, value) in [
            ("providerResponseID", providerResponseID.rawValue),
            ("promptVersion", promptVersion.rawValue),
            ("outputSchemaVersion", outputSchemaVersion.rawValue),
            ("model", model.rawValue),
        ] where !Self.isToken(value) {
            throw ModelCallReceiptValidationError.invalidToken(field: field, value: value)
        }
        guard metadata.count <= 32 else {
            throw ModelCallReceiptValidationError.tooManyMetadataEntries(metadata.count)
        }
        for key in metadata.keys where !Self.isMetadataKey(key) {
            throw ModelCallReceiptValidationError.invalidMetadataKey(key)
        }

        self.id = id
        self.provider = provider
        self.providerResponseID = providerResponseID
        self.purpose = purpose
        self.inputBoundary = inputBoundary
        self.promptVersion = promptVersion
        self.outputSchemaVersion = outputSchemaVersion
        self.model = model
        self.outputHash = outputHash
        self.metadata = metadata
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "provider": provider.canonicalValue,
            "providerResponseID": providerResponseID.canonicalValue,
            "purpose": purpose.canonicalValue,
            "inputBoundary": inputBoundary.canonicalValue,
            "promptVersion": promptVersion.canonicalValue,
            "outputSchemaVersion": outputSchemaVersion.canonicalValue,
            "model": model.canonicalValue,
            "outputHash": outputHash.canonicalValue,
            "metadata": .object(metadata.mapValues(\.canonicalValue)),
        ])
    }

    /// Compares provider-response content while deliberately ignoring Scout's
    /// local receipt ID. Used to distinguish a duplicate record from a conflict.
    func hasSameProviderResponse(as other: ModelCallReceipt) -> Bool {
        provider == other.provider
            && providerResponseID == other.providerResponseID
            && purpose == other.purpose
            && inputBoundary == other.inputBoundary
            && promptVersion == other.promptVersion
            && outputSchemaVersion == other.outputSchemaVersion
            && model == other.model
            && outputHash == other.outputHash
            && metadata == other.metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case providerResponseID
        case purpose
        case inputBoundary
        case promptVersion
        case outputSchemaVersion
        case model
        case outputHash
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ModelCallReceiptID.self, forKey: .id),
            provider: container.decode(NonEmptyString.self, forKey: .provider),
            providerResponseID: container.decode(NonEmptyString.self, forKey: .providerResponseID),
            purpose: container.decode(ModelCallPurpose.self, forKey: .purpose),
            inputBoundary: container.decode(ModelInputEventBoundary.self, forKey: .inputBoundary),
            promptVersion: container.decode(NonEmptyString.self, forKey: .promptVersion),
            outputSchemaVersion: container.decode(NonEmptyString.self, forKey: .outputSchemaVersion),
            model: container.decode(NonEmptyString.self, forKey: .model),
            outputHash: container.decode(SHA256Digest.self, forKey: .outputHash),
            metadata: container.decodeIfPresent(
                [String: AttributeValue].self,
                forKey: .metadata
            ) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(providerResponseID, forKey: .providerResponseID)
        try container.encode(purpose, forKey: .purpose)
        try container.encode(inputBoundary, forKey: .inputBoundary)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(outputSchemaVersion, forKey: .outputSchemaVersion)
        try container.encode(model, forKey: .model)
        try container.encode(outputHash, forKey: .outputHash)
        try container.encode(metadata, forKey: .metadata)
    }

    private static func isProvider(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (0x61 ... 0x7A).contains(first),
              value.utf8.count <= 64
        else { return false }
        return value.utf8.allSatisfy {
            (0x61 ... 0x7A).contains($0)
                || (0x30 ... 0x39).contains($0)
                || $0 == 0x2D
                || $0 == 0x2E
        }
    }

    private static func isToken(_ value: String) -> Bool {
        guard value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy {
            (0x41 ... 0x5A).contains($0)
                || (0x61 ... 0x7A).contains($0)
                || (0x30 ... 0x39).contains($0)
                || [0x2D, 0x2E, 0x2F, 0x3A, 0x5F].contains($0)
        }
    }

    private static func isMetadataKey(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (0x61 ... 0x7A).contains(first),
              value.utf8.count <= 64
        else { return false }
        return value.utf8.allSatisfy {
            (0x61 ... 0x7A).contains($0)
                || (0x30 ... 0x39).contains($0)
                || [0x2D, 0x2E, 0x5F].contains($0)
        }
    }
}
