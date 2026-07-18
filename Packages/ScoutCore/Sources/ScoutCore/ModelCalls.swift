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
    case derivedEventManifestTooLarge(Int)
    case invalidDerivedEventProjectionProgress(consumedCount: UInt16, eventCount: UInt16)
}

/// One adapter-derived event committed by a model-call receipt manifest.
///
/// Entries are not persisted in the receipt. The adapter reduces them into the manifest's rolling
/// root, and the reducer independently reconstructs that root from the canonical events it applies.
public struct DerivedEventManifestEntry: Equatable, Sendable, CanonicalRepresentable {
    public let eventID: EventID
    public let payloadKind: String
    public let payloadHash: SHA256Digest

    public init(eventID: EventID, payload: ScoutEventPayload) {
        self.init(
            eventID: eventID,
            payloadKind: payload.kind,
            payloadHash: .hash(payload.canonicalValue)
        )
    }

    public init(eventID: EventID, payloadKind: String, payloadHash: SHA256Digest) {
        self.eventID = eventID
        self.payloadKind = payloadKind
        self.payloadHash = payloadHash
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "eventID": eventID.canonicalValue,
            "payloadKind": .string(payloadKind),
            "payloadHash": payloadHash.canonicalValue,
        ])
    }
}

/// Bounded rolling commitment to the exact deterministic events derived from one model response.
///
/// The seed binds the receipt identity, provider output, projection base, adapter contract, and
/// expected count. Every step then binds its zero-based ordinal and the exact canonical event
/// payload. A receipt stores only the final root, keeping canonical provenance bounded while still
/// preventing a valid receipt from authorizing an undeclared extra payload.
public struct DerivedEventManifest: Codable, Equatable, Sendable, CanonicalRepresentable {
    public static let maximumEventCount = 512

    public let adapterID: NonEmptyString
    public let adapterVersion: NonEmptyString
    public let projectionBase: ModelInputEventBoundary
    public let eventCount: UInt16
    public let finalRoot: SHA256Digest

    public init(
        adapterID: NonEmptyString,
        adapterVersion: NonEmptyString,
        projectionBase: ModelInputEventBoundary,
        eventCount: UInt16,
        finalRoot: SHA256Digest
    ) throws {
        guard eventCount <= UInt16(Self.maximumEventCount) else {
            throw ModelCallReceiptValidationError.derivedEventManifestTooLarge(Int(eventCount))
        }
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.projectionBase = projectionBase
        self.eventCount = eventCount
        self.finalRoot = finalRoot
    }

    /// Builds the commitment an adapter must attach to the receipt before any derived event is
    /// appended. Event order is significant and is retained by the rolling ordinal.
    public static func committing(
        adapterID: NonEmptyString,
        adapterVersion: NonEmptyString,
        projectionBase: ModelInputEventBoundary,
        receiptID: ModelCallReceiptID,
        outputHash: SHA256Digest,
        entries: [DerivedEventManifestEntry]
    ) throws -> DerivedEventManifest {
        guard entries.count <= maximumEventCount else {
            throw ModelCallReceiptValidationError.derivedEventManifestTooLarge(entries.count)
        }
        let count = UInt16(entries.count)
        var root = seed(
            receiptID: receiptID,
            outputHash: outputHash,
            projectionBase: projectionBase,
            eventCount: count,
            adapterID: adapterID,
            adapterVersion: adapterVersion
        )
        for (index, entry) in entries.enumerated() {
            root = advance(root: root, ordinal: UInt16(index), entry: entry)
        }
        return try DerivedEventManifest(
            adapterID: adapterID,
            adapterVersion: adapterVersion,
            projectionBase: projectionBase,
            eventCount: count,
            finalRoot: root
        )
    }

    public func seed(receiptID: ModelCallReceiptID, outputHash: SHA256Digest) -> SHA256Digest {
        Self.seed(
            receiptID: receiptID,
            outputHash: outputHash,
            projectionBase: projectionBase,
            eventCount: eventCount,
            adapterID: adapterID,
            adapterVersion: adapterVersion
        )
    }

    public static func advance(
        root: SHA256Digest,
        ordinal: UInt16,
        entry: DerivedEventManifestEntry
    ) -> SHA256Digest {
        .hash(.object([
            "domain": .string("scout.derived-event-manifest.entry.v1"),
            "previousRoot": root.canonicalValue,
            "ordinal": .unsigned(UInt64(ordinal)),
            "eventID": entry.eventID.canonicalValue,
            "payloadKind": .string(entry.payloadKind),
            "payloadHash": entry.payloadHash.canonicalValue,
        ]))
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "adapterID": adapterID.canonicalValue,
            "adapterVersion": adapterVersion.canonicalValue,
            "projectionBase": projectionBase.canonicalValue,
            "eventCount": .unsigned(UInt64(eventCount)),
            "finalRoot": finalRoot.canonicalValue,
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case adapterID
        case adapterVersion
        case projectionBase
        case eventCount
        case finalRoot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            adapterID: container.decode(NonEmptyString.self, forKey: .adapterID),
            adapterVersion: container.decode(NonEmptyString.self, forKey: .adapterVersion),
            projectionBase: container.decode(ModelInputEventBoundary.self, forKey: .projectionBase),
            eventCount: container.decode(UInt16.self, forKey: .eventCount),
            finalRoot: container.decode(SHA256Digest.self, forKey: .finalRoot)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(adapterVersion, forKey: .adapterVersion)
        try container.encode(projectionBase, forKey: .projectionBase)
        try container.encode(eventCount, forKey: .eventCount)
        try container.encode(finalRoot, forKey: .finalRoot)
    }

    private static func seed(
        receiptID: ModelCallReceiptID,
        outputHash: SHA256Digest,
        projectionBase: ModelInputEventBoundary,
        eventCount: UInt16,
        adapterID: NonEmptyString,
        adapterVersion: NonEmptyString
    ) -> SHA256Digest {
        .hash(.object([
            "domain": .string("scout.derived-event-manifest.seed.v1"),
            "receiptID": receiptID.canonicalValue,
            "outputHash": outputHash.canonicalValue,
            "projectionBase": projectionBase.canonicalValue,
            "eventCount": .unsigned(UInt64(eventCount)),
            "adapterID": adapterID.canonicalValue,
            "adapterVersion": adapterVersion.canonicalValue,
        ]))
    }
}

/// Replay-derived progress for one manifest-bearing model response.
///
/// Pending and completed values live in separate ScoutState indexes. Keeping the complete rolling
/// state makes snapshot/replay equivalence explicit and lets a store reject a batch that stops
/// before the receipt's exact projection is exhausted.
public struct DerivedEventProjectionProgress: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let receiptID: ModelCallReceiptID
    public let modelCallEventID: EventID
    public let manifest: DerivedEventManifest
    public let consumedCount: UInt16
    public let rollingRoot: SHA256Digest

    public init(
        receiptID: ModelCallReceiptID,
        modelCallEventID: EventID,
        manifest: DerivedEventManifest,
        consumedCount: UInt16,
        rollingRoot: SHA256Digest
    ) {
        self.receiptID = receiptID
        self.modelCallEventID = modelCallEventID
        self.manifest = manifest
        self.consumedCount = consumedCount
        self.rollingRoot = rollingRoot
    }

    public var isComplete: Bool {
        consumedCount == manifest.eventCount && rollingRoot == manifest.finalRoot
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "receiptID": receiptID.canonicalValue,
            "modelCallEventID": modelCallEventID.canonicalValue,
            "manifest": manifest.canonicalValue,
            "consumedCount": .unsigned(UInt64(consumedCount)),
            "rollingRoot": rollingRoot.canonicalValue,
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case receiptID
        case modelCallEventID
        case manifest
        case consumedCount
        case rollingRoot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let manifest = try container.decode(DerivedEventManifest.self, forKey: .manifest)
        let consumedCount = try container.decode(UInt16.self, forKey: .consumedCount)
        guard consumedCount <= manifest.eventCount else {
            throw ModelCallReceiptValidationError.invalidDerivedEventProjectionProgress(
                consumedCount: consumedCount,
                eventCount: manifest.eventCount
            )
        }
        self.init(
            receiptID: try container.decode(ModelCallReceiptID.self, forKey: .receiptID),
            modelCallEventID: try container.decode(EventID.self, forKey: .modelCallEventID),
            manifest: manifest,
            consumedCount: consumedCount,
            rollingRoot: try container.decode(SHA256Digest.self, forKey: .rollingRoot)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(receiptID, forKey: .receiptID)
        try container.encode(modelCallEventID, forKey: .modelCallEventID)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(consumedCount, forKey: .consumedCount)
        try container.encode(rollingRoot, forKey: .rollingRoot)
    }
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
    public let derivedEventManifest: DerivedEventManifest?
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
        derivedEventManifest: DerivedEventManifest? = nil,
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
        if let derivedEventManifest {
            for (field, value) in [
                ("derivedEventManifest.adapterID", derivedEventManifest.adapterID.rawValue),
                ("derivedEventManifest.adapterVersion", derivedEventManifest.adapterVersion.rawValue),
            ] where !Self.isToken(value) {
                throw ModelCallReceiptValidationError.invalidToken(field: field, value: value)
            }
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
        self.derivedEventManifest = derivedEventManifest
        self.metadata = metadata
    }

    public var canonicalValue: CanonicalValue {
        var object: [String: CanonicalValue] = [
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
        ]
        // Absence must preserve the canonical bytes of schema 1.1-1.3 receipts.
        if let derivedEventManifest {
            object["derivedEventManifest"] = derivedEventManifest.canonicalValue
        }
        return .object(object)
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
            && derivedEventManifest == other.derivedEventManifest
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
        case derivedEventManifest
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
            derivedEventManifest: container.decodeIfPresent(
                DerivedEventManifest.self,
                forKey: .derivedEventManifest
            ),
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
        try container.encodeIfPresent(derivedEventManifest, forKey: .derivedEventManifest)
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
