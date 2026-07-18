import CryptoKit
import Foundation
import ScoutCore
import ScoutPersistence

/// Converts finalized live transcript items into an immutable, hash-linked
/// event stream. Model output never writes tables directly; it can only become
/// a validated ScoutCore payload before this actor commits it.
actor LiveEventJournal {
    struct SpeakerDescriptor: Sendable {
        let id: String
        let displayName: String
        let role: String
        let affiliation: ScoutCore.Speaker.Affiliation
    }

    /// Durable boundary returned only after both the utterance and its evidence
    /// have committed atomically.
    struct FinalUtteranceReceipt: Equatable, Sendable {
        let utteranceID: UtteranceID
        let evidenceID: EvidenceID
        let committedEvidenceBoundary: AppendReceipt
        let speakerID: SpeakerID
        let text: String
        /// Milliseconds from the immutable discovery-session start.
        let startMilliseconds: Int64
        /// Milliseconds from the immutable discovery-session start.
        let endMilliseconds: Int64
    }

    /// Durable, hash-addressed reference to normalized visual evidence. Image bytes are
    /// deliberately excluded from the event log; the immutable content digest is canonical.
    struct ImageEvidenceReceipt: Equatable, Sendable {
        let evidenceID: EvidenceID
        let assetID: AssetID
        let assetSHA256: String
        let mediaType: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        let committedEvidenceBoundary: AppendReceipt
    }

    /// Provider provenance committed after image analysis and before any proposal reaches UI.
    struct ImageObservationReceipt: Equatable, Sendable {
        let modelCallReceiptID: ModelCallReceiptID
        let committedModelBoundary: AppendReceipt
        let observations: [ScoutCore.VisualObservation]
    }

    struct VisualObservationReviewReceipt: Equatable, Sendable {
        let observationID: VisualObservationID
        let disposition: VisualObservationDisposition
        let committedReviewBoundary: AppendReceipt
        let canonicalState: ScoutState
    }

    struct ClaimReviewReceipt: Equatable, Sendable {
        let claimID: ClaimID
        let status: ClaimStatus
        let committedReviewBoundary: AppendReceipt
        let canonicalState: ScoutState
    }

    /// The durable result of crossing a claim adapter projection into the canonical log.
    /// `canonicalState` is the only state callers may project into the workspace; the incoming
    /// UI-shaped proposal is deliberately not returned as an applyable result.
    struct ClaimProjectionCommitResult: Sendable {
        let appendedEventBoundaries: [AppendReceipt]
        let canonicalState: ScoutState

        var count: Int { appendedEventBoundaries.count }
        var isEmpty: Bool { appendedEventBoundaries.isEmpty }
        var first: AppendReceipt? { appendedEventBoundaries.first }
    }

    enum VisualObservationReviewPreparation: Equatable, Sendable {
        case alreadyCommitted(VisualObservationReviewReceipt)
        case authorizationRequired(LocalReviewIntent)
    }

    enum ClaimReviewPreparation: Equatable, Sendable {
        case alreadyCommitted(ClaimReviewReceipt)
        case authorizationRequired(LocalReviewIntent)
    }

    private let fileURL: URL
    private let encryptionKeyProvider: @Sendable () throws -> Data
    private var store: SQLiteEventStore?
    private var builders: [SessionID: EventChainBuilder] = [:]
    private var operationIsLocked = false
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var operationWaiters: [OperationWaiter] = []

    init(
        fileURL: URL = LiveEventJournal.defaultStoreURL,
        encryptionKeyProvider: @escaping @Sendable () throws -> Data = {
            try ScoutKeyStore.eventStoreKey()
        }
    ) {
        self.fileURL = fileURL
        self.encryptionKeyProvider = encryptionKeyProvider
    }

    func prepareSession(
        sessionID rawSessionID: String,
        title: String,
        speakers: [SpeakerDescriptor]
    ) async throws {
        try await acquireOperationLock()
        defer { releaseOperationLock() }
        try await prepareSessionLocked(
            sessionID: rawSessionID,
            title: title,
            speakers: speakers
        )
    }

    /// Flushes WAL state and releases the SQLite handle. Tests and controlled shutdown paths use
    /// this before removing a store; normal app termination may rely on process teardown.
    func close() async throws {
        try await acquireOperationLock()
        defer { releaseOperationLock() }
        guard let store else { return }
        try await store.close()
        self.store = nil
        builders.removeAll(keepingCapacity: false)
    }

    private func prepareSessionLocked(
        sessionID rawSessionID: String,
        title: String,
        speakers: [SpeakerDescriptor]
    ) async throws {
        let sessionID = try SessionID(validating: rawSessionID)
        let database = try database()
        let existing = try await database.events(for: sessionID)
        var builder = try Self.builder(for: sessionID, existing: existing)
        var additions: [ValidatedScoutEvent] = []
        let now = Self.timestamp()
        let systemComponent = try Self.systemComponent()

        if existing.isEmpty {
            additions.append(try builder.seal(
                id: try EventID(validating: "event-\(Self.digest("session|\(rawSessionID)"))-started"),
                occurredAt: now,
                recordedAt: now,
                command: .sessionLifecycle(
                    component: systemComponent,
                    operation: .start(DiscoverySession(
                        id: sessionID,
                        title: try NonEmptyString(validating: title),
                        startedAt: now
                    ))
                )
            ))
        }

        let existingSpeakerIDs = Set(existing.compactMap { event -> SpeakerID? in
            guard case let .speakerUpserted(speaker) = event.payload else { return nil }
            return speaker.id
        })

        for descriptor in speakers {
            let speakerID = try SpeakerID(validating: descriptor.id)
            guard !existingSpeakerIDs.contains(speakerID) else { continue }
            additions.append(try builder.seal(
                id: try EventID(validating: "event-\(Self.digest("speaker|\(rawSessionID)|\(descriptor.id)"))-upsert"),
                occurredAt: now,
                recordedAt: now,
                command: .sessionLifecycle(
                    component: systemComponent,
                    operation: .upsertSpeaker(ScoutCore.Speaker(
                        id: speakerID,
                        displayName: try NonEmptyString(validating: descriptor.displayName),
                        role: try NonEmptyString(validating: descriptor.role),
                        affiliation: descriptor.affiliation
                    ))
                )
            ))
        }

        if !additions.isEmpty {
            let expected = try Self.expectedVersion(before: additions[0])
            let additionDigest = Self.digest(
                additions.map(\.envelope.id.rawValue).joined(separator: "|")
            )
            let key = try IdempotencyKey("prepare-session:\(rawSessionID):\(additionDigest)")
            _ = try await database.append(additions, expecting: expected, idempotencyKey: key)
        }
        builders[sessionID] = builder
    }

    @discardableResult
    func recordFinalUtterance(
        sessionID rawSessionID: String,
        itemID: String,
        speakerID rawSpeakerID: String,
        text: String,
        confidenceBasisPoints: Int,
        languageCode: String = "en",
        startMilliseconds: Int64? = nil,
        endMilliseconds: Int64? = nil
    ) async throws -> FinalUtteranceReceipt {
        try await acquireOperationLock()
        defer { releaseOperationLock() }
        return try await recordFinalUtteranceLocked(
            sessionID: rawSessionID,
            itemID: itemID,
            speakerID: rawSpeakerID,
            text: text,
            confidenceBasisPoints: confidenceBasisPoints,
            languageCode: languageCode,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
    }

    private func recordFinalUtteranceLocked(
        sessionID rawSessionID: String,
        itemID: String,
        speakerID rawSpeakerID: String,
        text: String,
        confidenceBasisPoints: Int,
        languageCode: String,
        startMilliseconds: Int64?,
        endMilliseconds: Int64?
    ) async throws -> FinalUtteranceReceipt {
        let sessionID = try SessionID(validating: rawSessionID)
        guard var builder = builders[sessionID] else {
            throw JournalError.sessionNotPrepared
        }

        let normalizedText = try NonEmptyString(validating: text)
        let speakerID = try SpeakerID(validating: rawSpeakerID)
        let confidence = try Confidence(basisPoints: confidenceBasisPoints)
        try Self.validateRelativeTimeArguments(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
        let digest = Self.digest("utterance|\(rawSessionID)|\(itemID)")
        let utteranceID = try UtteranceID(validating: "utterance-\(digest)")
        let evidenceID = try EvidenceID(validating: "evidence-\(digest)")
        let utteranceEventID = try EventID(validating: "event-\(digest)-utterance")
        let evidenceEventID = try EventID(validating: "event-\(digest)-evidence")
        let database = try database()
        let persistedEvents = try await database.events(for: sessionID)
        let session = try Self.sessionStarted(in: persistedEvents)
        if let persistedReceipt = try Self.persistedReceipt(
            in: persistedEvents,
            session: session,
            utteranceEventID: utteranceEventID,
            evidenceEventID: evidenceEventID,
            utteranceID: utteranceID,
            evidenceID: evidenceID,
            speakerID: speakerID,
            text: normalizedText,
            confidence: confidence,
            languageCode: languageCode,
            requestedStartMilliseconds: startMilliseconds,
            requestedEndMilliseconds: endMilliseconds
        ) {
            builders[sessionID] = try Self.builder(for: sessionID, existing: persistedEvents)
            return persistedReceipt
        }

        let recordedAt = Self.timestamp()
        let relativeTime = try Self.relativeTime(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            sessionStartedAt: session.startedAt,
            recordedAt: recordedAt
        )
        let actor = EventActor.speaker(speakerID)

        let utteranceEvent = try builder.seal(
            id: utteranceEventID,
            occurredAt: relativeTime.endedAt,
            recordedAt: recordedAt,
            command: .capturePipeline(
                component: try NonEmptyString(validating: "scout-macos-capture"),
                operation: .finalizeUtterance(Utterance(
                    id: utteranceID,
                    speakerID: speakerID,
                    startedAt: relativeTime.startedAt,
                    endedAt: relativeTime.endedAt,
                    text: normalizedText,
                    transcriptionConfidence: confidence,
                    languageCode: languageCode
                ))
            )
        )
        let evidenceEvent = try builder.seal(
            id: evidenceEventID,
            occurredAt: relativeTime.endedAt,
            recordedAt: recordedAt,
            causationID: utteranceEventID,
            command: .capturePipeline(
                component: try NonEmptyString(validating: "scout-macos-capture"),
                operation: .recordEvidence(Evidence(
                    id: evidenceID,
                    source: .utterance(utteranceID),
                    excerpt: normalizedText,
                    capturedAt: relativeTime.endedAt,
                    capturedBy: actor
                ))
            )
        )

        let key = try IdempotencyKey("finalize-utterance:\(rawSessionID):\(digest)")
        do {
            let receipts = try await database.append(
                [utteranceEvent, evidenceEvent],
                expecting: try Self.expectedVersion(before: utteranceEvent),
                idempotencyKey: key
            )
            guard receipts.count == 2,
                  let evidenceBoundary = receipts.last,
                  evidenceBoundary.eventID == evidenceEventID
            else {
                throw JournalError.invalidCommitBoundary
            }
            builders[sessionID] = builder
            return FinalUtteranceReceipt(
                utteranceID: utteranceID,
                evidenceID: evidenceID,
                committedEvidenceBoundary: evidenceBoundary,
                speakerID: speakerID,
                text: normalizedText.rawValue,
                startMilliseconds: relativeTime.startMilliseconds,
                endMilliseconds: relativeTime.endMilliseconds
            )
        } catch SQLiteEventStoreError.duplicateEventID(let eventID) where eventID == utteranceEventID || eventID == evidenceEventID {
            let existing = try await database.events(for: sessionID)
            guard let receipt = try Self.persistedReceipt(
                in: existing,
                session: try Self.sessionStarted(in: existing),
                utteranceEventID: utteranceEventID,
                evidenceEventID: evidenceEventID,
                utteranceID: utteranceID,
                evidenceID: evidenceID,
                speakerID: speakerID,
                text: normalizedText,
                confidence: confidence,
                languageCode: languageCode,
                requestedStartMilliseconds: startMilliseconds,
                requestedEndMilliseconds: endMilliseconds
            ) else {
                throw JournalError.finalizedItemConflict
            }
            builders[sessionID] = try Self.builder(for: sessionID, existing: existing)
            return receipt
        }
    }

    /// Records the content-addressed visual evidence before normalized bytes leave the app.
    /// A retry of the same normalized image is idempotent; conflicting metadata fails closed.
    @discardableResult
    func recordImageEvidence(
        sessionID rawSessionID: String,
        image: PreparedImageEvidence
    ) async throws -> ImageEvidenceReceipt {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        let sessionID = try SessionID(validating: rawSessionID)
        guard var builder = builders[sessionID] else {
            throw JournalError.sessionNotPrepared
        }
        guard image.assetSHA256 == Self.digest(image.normalizedJPEG),
              image.pixelWidth > 0,
              image.pixelHeight > 0,
              image.byteCount > 0
        else {
            throw JournalError.invalidImageEvidence
        }

        let contentHash = try SHA256Digest(validating: image.assetSHA256)
        let localDigest = Self.digest("image|\(rawSessionID)|\(image.assetSHA256)")
        let assetID = try AssetID(validating: "asset-image-\(image.assetSHA256)")
        let evidenceID = try EvidenceID(validating: "evidence-image-\(localDigest)")
        let eventID = try EventID(validating: "event-\(localDigest)-image-evidence")
        let mediaType = try NonEmptyString(validating: image.mimeType)
        let excerpt = try NonEmptyString(validating: Self.imageEvidenceExcerpt(
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            byteCount: image.byteCount
        ))
        let source = EvidenceSource.image(AssetLocator(
            assetID: assetID,
            mediaType: mediaType,
            contentHash: contentHash
        ))
        let database = try database()
        let existing = try await database.events(for: sessionID)

        if let persisted = existing.first(where: { $0.id == eventID }) {
            guard case let .evidenceRecorded(evidence) = persisted.payload,
                  evidence.id == evidenceID,
                  evidence.source == source,
                  evidence.excerpt == excerpt
            else {
                throw JournalError.imageEvidenceConflict
            }
            builders[sessionID] = try Self.builder(for: sessionID, existing: existing)
            return ImageEvidenceReceipt(
                evidenceID: evidenceID,
                assetID: assetID,
                assetSHA256: image.assetSHA256,
                mediaType: image.mimeType,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight,
                byteCount: image.byteCount,
                committedEvidenceBoundary: AppendReceipt(event: persisted)
            )
        }

        let timestamp = Self.timestamp()
        let event = try builder.seal(
            id: eventID,
            occurredAt: timestamp,
            recordedAt: timestamp,
            command: .evidenceImport(
                component: try NonEmptyString(validating: "scout-macos-image-import"),
                operation: .record(Evidence(
                    id: evidenceID,
                    source: source,
                    excerpt: excerpt,
                    capturedAt: timestamp,
                    capturedBy: try Self.systemActor()
                ))
            )
        )
        let receipts = try await database.append(
            [event],
            expecting: try Self.expectedVersion(before: event),
            idempotencyKey: try IdempotencyKey("image-evidence:\(rawSessionID):\(image.assetSHA256)")
        )
        guard receipts.count == 1, let boundary = receipts.first, boundary.eventID == eventID else {
            throw JournalError.invalidCommitBoundary
        }
        builders[sessionID] = builder
        return ImageEvidenceReceipt(
            evidenceID: evidenceID,
            assetID: assetID,
            assetSHA256: image.assetSHA256,
            mediaType: image.mimeType,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            byteCount: image.byteCount,
            committedEvidenceBoundary: boundary
        )
    }

    /// Commits an immutable provider receipt for a validated image proposal. The exact image
    /// evidence event is the model-input boundary. No proposal is applied by this method.
    @discardableResult
    func recordImageObservation(
        sessionID rawSessionID: String,
        evidence: ImageEvidenceReceipt,
        result: ImageObservationResult
    ) async throws -> ImageObservationReceipt {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        let sessionID = try SessionID(validating: rawSessionID)
        guard evidence.committedEvidenceBoundary.sessionID == sessionID,
              evidence.assetSHA256 == result.proposal.evidenceAssetSHA256,
              evidence.assetSHA256 == result.modelCall.inputAssetSHA256
        else {
            throw JournalError.imageObservationConflict
        }

        let database = try database()
        let events = try await database.events(for: sessionID)
        guard let inputEvent = events.first(where: {
            $0.id == evidence.committedEvidenceBoundary.eventID
                && $0.sequence == evidence.committedEvidenceBoundary.sequence
                && $0.integrityHash == evidence.committedEvidenceBoundary.integrityHash
        }),
              case let .evidenceRecorded(persistedEvidence) = inputEvent.payload,
              persistedEvidence.id == evidence.evidenceID
        else {
            throw JournalError.missingModelInputBoundary
        }
        let suppliedContentHash: ScoutCore.SHA256Digest
        let suppliedMediaType: NonEmptyString
        do {
            suppliedContentHash = try ScoutCore.SHA256Digest(validating: evidence.assetSHA256)
            suppliedMediaType = try NonEmptyString(validating: evidence.mediaType)
        } catch {
            throw JournalError.imageObservationConflict
        }
        let expectedExcerpt = Self.imageEvidenceExcerpt(
            pixelWidth: evidence.pixelWidth,
            pixelHeight: evidence.pixelHeight,
            byteCount: evidence.byteCount
        )
        guard case let .image(persistedLocator) = persistedEvidence.source,
              persistedLocator.assetID == evidence.assetID,
              persistedLocator.mediaType == suppliedMediaType,
              persistedLocator.contentHash == suppliedContentHash,
              persistedLocator.page == nil,
              persistedEvidence.excerpt?.rawValue == expectedExcerpt
        else {
            throw JournalError.imageObservationConflict
        }

        let verifiedAssetSHA256 = suppliedContentHash.rawValue
        let verifiedPixelWidth = evidence.pixelWidth
        let verifiedPixelHeight = evidence.pixelHeight
        let verifiedByteCount = evidence.byteCount

        let receiptID = try ModelCallReceiptID(
            validating: "model-call-image-\(Self.digest("openai|\(rawSessionID)|\(result.modelCall.responseID)|\(result.modelCall.outputSHA256)"))"
        )
        let baseReceipt = try ModelCallReceipt(
            id: receiptID,
            provider: NonEmptyString(validating: "openai"),
            providerResponseID: NonEmptyString(validating: result.modelCall.responseID),
            purpose: .whiteboardExtraction,
            inputBoundary: ModelInputEventBoundary(inputEvent),
            promptVersion: NonEmptyString(validating: result.modelCall.promptVersion),
            outputSchemaVersion: NonEmptyString(validating: result.modelCall.schemaVersion),
            model: NonEmptyString(validating: result.modelCall.model),
            outputHash: SHA256Digest(validating: result.modelCall.outputSHA256),
            metadata: [
                "asset_sha256": .text(verifiedAssetSHA256),
                "byte_count": .integer(Int64(verifiedByteCount)),
                "pixel_height": .integer(Int64(verifiedPixelHeight)),
                "pixel_width": .integer(Int64(verifiedPixelWidth)),
            ]
        )
        let proposals = try ImageObservationProjector().project(
            result,
            sessionID: rawSessionID,
            evidenceID: evidence.evidenceID,
            modelCallReceiptID: receiptID
        ).sorted { $0.id < $1.id }
        guard let currentState = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }
        let persistedModelEvent = events.first(where: { event in
            guard case let .modelCallRecorded(existing) = event.payload else { return false }
            return existing.provider == baseReceipt.provider
                && existing.providerResponseID == baseReceipt.providerResponseID
        })
        if let persistedModelEvent {
            guard case let .modelCallRecorded(existingReceipt) = persistedModelEvent.payload,
                  existingReceipt.id == receiptID,
                  Self.sameModelProviderResponse(existingReceipt, baseReceipt),
                  existingReceipt.derivedEventManifest != nil,
                  let completed = currentState.completedDerivedEventProjections[
                      persistedModelEvent.id
                  ],
                  completed.isComplete
            else {
                throw JournalError.imageObservationConflict
            }
            let existingObservations = currentState.visualObservations.values.filter {
                $0.modelCallReceiptID == receiptID
            }
            guard existingObservations.count == proposals.count,
                  proposals.allSatisfy({ proposal in
                      currentState.visualObservations[proposal.id].map {
                          Self.sameVisualObservationProposal($0, proposal)
                      } ?? false
                  })
            else {
                throw JournalError.imageObservationConflict
            }
            builders[sessionID] = try Self.builder(for: sessionID, existing: events)
            return ImageObservationReceipt(
                modelCallReceiptID: receiptID,
                committedModelBoundary: AppendReceipt(event: persistedModelEvent),
                observations: existingObservations.sorted { $0.id < $1.id }
            )
        }

        guard currentState.visualObservations.values.allSatisfy({
            $0.modelCallReceiptID != receiptID
        }) else {
            // Schema v1.4 projections are indivisible. Never repair a receipt-less or partial
            // provider projection by appending a remainder later.
            throw JournalError.imageObservationConflict
        }
        guard let projectionBaseID = currentState.lastEventID,
              let projectionBase = currentState.eventBoundaries[projectionBaseID]
        else {
            throw JournalError.invalidCommitBoundary
        }

        let plannedObservations = try proposals.map { proposal in
            let eventID = try EventID(
                validating: "event-visual-proposal-\(Self.digest("\(rawSessionID)|\(proposal.id.rawValue)"))"
            )
            return (eventID, proposal)
        }
        let manifest = try DerivedEventManifest.committing(
            adapterID: NonEmptyString(validating: "scout-macos-image-observation"),
            adapterVersion: NonEmptyString(validating: "image-observation.v1"),
            projectionBase: projectionBase,
            receiptID: receiptID,
            outputHash: baseReceipt.outputHash,
            entries: plannedObservations.map { eventID, proposal in
                DerivedEventManifestEntry(
                    eventID: eventID,
                    payload: .visualObservationProposed(proposal)
                )
            }
        )
        let receipt = try Self.receipt(baseReceipt, attaching: manifest)
        let modelEventID = try EventID(
            validating: "event-model-image-\(Self.digest("\(rawSessionID)|\(result.modelCall.responseID)"))"
        )
        let modelIdentity = ModelIdentity(
            provider: try NonEmptyString(validating: "openai"),
            model: try NonEmptyString(validating: result.modelCall.model),
            operationVersion: try NonEmptyString(validating: result.modelCall.promptVersion)
        )
        let modelValidator = try NonEmptyString(validating: "scout-macos-image-observation-validator")
        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        var additions: [ValidatedScoutEvent] = [try builder.seal(
            id: modelEventID,
            occurredAt: timestamp,
            recordedAt: timestamp,
            causationID: inputEvent.id,
            command: .modelProjection(
                validator: modelValidator,
                model: modelIdentity,
                operation: .recordCall(receipt)
            )
        )]
        for (eventID, proposal) in plannedObservations {
            guard currentState.visualObservations[proposal.id] == nil else {
                throw JournalError.imageObservationConflict
            }
            additions.append(try builder.seal(
                id: eventID,
                occurredAt: timestamp,
                recordedAt: timestamp,
                correlationID: modelEventID,
                causationID: modelEventID,
                command: .modelProjection(
                    validator: modelValidator,
                    model: modelIdentity,
                    operation: .proposeVisualObservation(proposal)
                )
            ))
        }

        guard let first = additions.first else { throw JournalError.invalidCommitBoundary }
        let additionDigest = Self.digest(
            additions.map(\.envelope.id.rawValue).joined(separator: "|")
        )
        let receipts = try await database.append(
            additions,
            expecting: try Self.expectedVersion(before: first),
            idempotencyKey: try IdempotencyKey(
                "image-observation-v3:\(rawSessionID):\(additionDigest)"
            )
        )
        guard receipts.count == additions.count,
              let modelBoundary = receipts.first(where: { $0.eventID == modelEventID })
        else {
            throw JournalError.invalidCommitBoundary
        }
        builders[sessionID] = builder
        return ImageObservationReceipt(
            modelCallReceiptID: receiptID,
            committedModelBoundary: modelBoundary,
            observations: proposals
        )
    }

    /// Resolves the exact canonical object revision to review before authentication begins.
    ///
    /// The journal lock is released when this method returns so the macOS authentication prompt
    /// cannot stall transcript or evidence persistence.
    func prepareVisualObservationReview(
        sessionID rawSessionID: String,
        observationID rawObservationID: String,
        disposition: VisualObservationDisposition
    ) async throws -> VisualObservationReviewPreparation {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        let sessionID = try SessionID(validating: rawSessionID)
        let observationID = try VisualObservationID(validating: rawObservationID)
        let database = try database()
        let events = try await database.events(for: sessionID)
        guard let state = try await database.state(for: sessionID),
              let observation = state.visualObservations[observationID]
        else {
            throw JournalError.missingVisualObservation
        }

        if observation.status != .proposed {
            let expected: VisualObservationStatus = disposition == .confirmed ? .confirmed : .rejected
            guard observation.status == expected,
                  let attestation = state.visualObservationReviewAttestations[observationID]
            else {
                throw JournalError.visualObservationReviewConflict
            }
            builders[sessionID] = try Self.builder(for: sessionID, existing: events)
            switch attestation {
            case let .deviceOwnerAuthenticated(authorization):
                guard let persisted = events.first(where: { $0.id == authorization.eventID }) else {
                    throw JournalError.visualObservationReviewConflict
                }
                return .alreadyCommitted(VisualObservationReviewReceipt(
                    observationID: observationID,
                    disposition: disposition,
                    committedReviewBoundary: AppendReceipt(event: persisted),
                    canonicalState: state
                ))

            case .legacyUnattested:
                let eventID = try EventID(
                    validating: "event-visual-review-attestation-\(Self.digest("\(rawSessionID)|\(rawObservationID)|\(disposition.rawValue)"))"
                )
                let intent = try LocalReviewIntent.preparing(
                    eventID: eventID,
                    operation: .attestLegacyReview(LocalReviewAttested(
                        target: .visualObservation(observationID)
                    )),
                    in: state
                )
                return .authorizationRequired(intent)
            }
        }

        let eventID = try EventID(
            validating: "event-visual-review-\(Self.digest("\(rawSessionID)|\(rawObservationID)|\(disposition.rawValue)"))"
        )
        let intent = try LocalReviewIntent.preparing(
            eventID: eventID,
            operation: .reviewVisualObservation(VisualObservationReviewed(
                observationID: observationID,
                disposition: disposition,
                reviewer: .localOperator
            )),
            in: state
        )
        builders[sessionID] = try Self.builder(for: sessionID, existing: events)
        return .authorizationRequired(intent)
    }

    /// Commits a previously prepared review only after device-owner authentication succeeded.
    /// The reducer rechecks the exact target revision after the journal lock is reacquired.
    @discardableResult
    func recordVisualObservationReview(
        sessionID rawSessionID: String,
        authenticatedReview: AuthenticatedLocalReview
    ) async throws -> VisualObservationReviewReceipt {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        try Task.checkCancellation()
        let sessionID = try SessionID(validating: rawSessionID)
        let database = try database()
        let events = try await database.events(for: sessionID)
        guard let state = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }

        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        let event: ValidatedScoutEvent
        do {
            event = try builder.seal(
                occurredAt: timestamp,
                recordedAt: timestamp,
                authenticatedReview: authenticatedReview
            )
        } catch is LocalReviewAuthorizationError {
            throw JournalError.invalidReviewAuthorization
        }

        let observationID: VisualObservationID
        let disposition: VisualObservationDisposition
        switch event.envelope.payload {
        case let .visualObservationReviewed(review):
            observationID = review.observationID
            disposition = review.disposition
            guard state.visualObservations[observationID]?.status == .proposed else {
                throw JournalError.visualObservationReviewConflict
            }

        case let .localReviewAttested(attestation):
            guard case let .visualObservation(id) = attestation.target,
                  let observation = state.visualObservations[id],
                  case .legacyUnattested? = state.visualObservationReviewAttestations[id]
            else {
                throw JournalError.invalidReviewAuthorization
            }
            observationID = id
            switch observation.status {
            case .confirmed: disposition = .confirmed
            case .rejected: disposition = .rejected
            case .proposed: throw JournalError.visualObservationReviewConflict
            }

        default:
            throw JournalError.invalidReviewAuthorization
        }

        try Task.checkCancellation()
        let receipts = try await database.append(
            [event],
            expecting: try Self.expectedVersion(before: event),
            idempotencyKey: try IdempotencyKey(
                "visual-review-v3:\(rawSessionID):\(event.envelope.id.rawValue)"
            )
        )
        guard receipts.count == 1,
              let boundary = receipts.first,
              boundary.eventID == event.envelope.id
        else {
            throw JournalError.invalidCommitBoundary
        }
        guard let canonicalState = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }
        builders[sessionID] = builder
        return VisualObservationReviewReceipt(
            observationID: observationID,
            disposition: disposition,
            committedReviewBoundary: boundary,
            canonicalState: canonicalState
        )
    }

    /// Resolves either a new terminal claim decision or an append-only attestation of the exact
    /// legacy decision currently in canonical state. Authentication always happens after this
    /// method releases the journal lock.
    func prepareClaimReview(
        sessionID rawSessionID: String,
        claimID rawClaimID: String,
        status: ClaimStatus
    ) async throws -> ClaimReviewPreparation {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        guard status == .accepted || status == .rejected else {
            throw JournalError.claimReviewConflict
        }
        let sessionID = try SessionID(validating: rawSessionID)
        let claimID = try ClaimID(validating: rawClaimID)
        let database = try database()
        let events = try await database.events(for: sessionID)
        guard let state = try await database.state(for: sessionID),
              let claim = state.claims[claimID]
        else {
            throw JournalError.missingClaim
        }

        builders[sessionID] = try Self.builder(for: sessionID, existing: events)
        if claim.status != .proposed {
            guard claim.status == status,
                  let attestation = state.claimReviewAttestations[claimID]
            else {
                throw JournalError.claimReviewConflict
            }
            switch attestation {
            case let .deviceOwnerAuthenticated(authorization):
                guard let persisted = events.first(where: { $0.id == authorization.eventID }) else {
                    throw JournalError.claimReviewConflict
                }
                return .alreadyCommitted(ClaimReviewReceipt(
                    claimID: claimID,
                    status: status,
                    committedReviewBoundary: AppendReceipt(event: persisted),
                    canonicalState: state
                ))

            case .legacyUnattested:
                let eventID = try EventID(
                    validating: "event-claim-review-attestation-\(Self.digest("\(rawSessionID)|\(rawClaimID)|\(status.rawValue)"))"
                )
                return .authorizationRequired(try LocalReviewIntent.preparing(
                    eventID: eventID,
                    operation: .attestLegacyReview(LocalReviewAttested(
                        target: .claim(claimID)
                    )),
                    in: state
                ))
            }
        }

        let validationStatus: ValidationStatus = status == .accepted ? .validated : .rejected
        let eventID = try EventID(
            validating: "event-claim-review-\(Self.digest("\(rawSessionID)|\(rawClaimID)|\(status.rawValue)"))"
        )
        let operation = LocalReviewOperation.reviewClaim(ClaimReviewed(
            claimID: claimID,
            status: status,
            trust: TrustAssessment(
                origin: .confirmed,
                confidence: claim.trust.confidence,
                validationStatus: validationStatus,
                rationale: claim.trust.rationale
            )
        ))
        return .authorizationRequired(try LocalReviewIntent.preparing(
            eventID: eventID,
            operation: operation,
            in: state
        ))
    }

    /// Commits a prepared claim review or legacy re-attestation and returns only replayed canonical
    /// state for application projection.
    @discardableResult
    func recordClaimReview(
        sessionID rawSessionID: String,
        authenticatedReview: AuthenticatedLocalReview
    ) async throws -> ClaimReviewReceipt {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        try Task.checkCancellation()
        let sessionID = try SessionID(validating: rawSessionID)
        let database = try database()
        let events = try await database.events(for: sessionID)
        guard let state = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }
        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        let event: ValidatedScoutEvent
        do {
            event = try builder.seal(
                occurredAt: timestamp,
                recordedAt: timestamp,
                authenticatedReview: authenticatedReview
            )
        } catch is LocalReviewAuthorizationError {
            throw JournalError.invalidReviewAuthorization
        }

        let claimID: ClaimID
        let status: ClaimStatus
        switch event.envelope.payload {
        case let .claimReviewed(review):
            claimID = review.claimID
            status = review.status
            guard state.claims[claimID]?.status == .proposed else {
                throw JournalError.claimReviewConflict
            }

        case let .localReviewAttested(attestation):
            guard case let .claim(id) = attestation.target,
                  let claim = state.claims[id],
                  claim.status == .accepted || claim.status == .rejected,
                  case .legacyUnattested? = state.claimReviewAttestations[id]
            else {
                throw JournalError.invalidReviewAuthorization
            }
            claimID = id
            status = claim.status

        default:
            throw JournalError.invalidReviewAuthorization
        }

        try Task.checkCancellation()
        let receipts = try await database.append(
            [event],
            expecting: try Self.expectedVersion(before: event),
            idempotencyKey: try IdempotencyKey(
                "claim-review-v1:\(rawSessionID):\(event.envelope.id.rawValue)"
            )
        )
        guard receipts.count == 1,
              let boundary = receipts.first,
              boundary.eventID == event.envelope.id,
              let canonicalState = try await database.state(for: sessionID)
        else {
            throw JournalError.invalidCommitBoundary
        }
        builders[sessionID] = builder
        return ClaimReviewReceipt(
            claimID: claimID,
            status: status,
            committedReviewBoundary: boundary,
            canonicalState: canonicalState
        )
    }

    func verify(sessionID rawSessionID: String) async throws -> ChainVerificationReport {
        try await database().verifyChain(for: SessionID(validating: rawSessionID))
    }

    /// Returns the newest session only after SQLite decryption and the canonical reducer have
    /// successfully replayed it. Callers receive no mutable store handles and may discard the
    /// projection at any time.
    func latestReplayState() async throws -> ScoutState? {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        let database = try database()
        var newest: ScoutState?
        for sessionID in try await database.sessionIDs() {
            guard let candidate = try await database.state(for: sessionID),
                  candidate.session != nil
            else { continue }
            guard let current = newest else {
                newest = candidate
                continue
            }
            guard let candidateStart = candidate.session?.startedAt,
                  let currentStart = current.session?.startedAt
            else { continue }
            if candidateStart > currentStart
                || (candidateStart == currentStart && candidate.sessionID > current.sessionID) {
                newest = candidate
            }
        }
        return newest
    }

    /// Atomically records the validated provider receipt and every deterministic graph operation.
    /// The planner runs against the same verified stream prefix used for the append, under the FIFO
    /// journal gate, so the UI can never outrun durable provenance.
    @discardableResult
    func recordClaimProjection(
        sessionID rawSessionID: String,
        projection: ClaimProposalProjection
    ) async throws -> ClaimProjectionCommitResult {
        try await acquireOperationLock()
        defer { releaseOperationLock() }

        let sessionID = try SessionID(validating: rawSessionID)
        let database = try database()
        let events = try await database.events(for: sessionID)
        guard let currentState = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }
        let requestedBoundary = projection.modelCall.inputEventBoundary
        guard requestedBoundary > 0,
              let inputBoundary = events.first(where: {
                  $0.sequence.rawValue == UInt64(requestedBoundary)
              })
        else {
            throw JournalError.missingModelInputBoundary
        }

        let existingProviderResponses = currentState.modelCallReceipts.values.filter {
            $0.provider.rawValue == "openai"
                && $0.providerResponseID.rawValue == projection.modelCall.responseID
        }
        if !existingProviderResponses.isEmpty {
            guard existingProviderResponses.count == 1,
                  let existingReceipt = existingProviderResponses.first
            else {
                throw ClaimProjectionCommitPlanningError.conflictingModelResponse(
                    projection.modelCall.responseID
                )
            }
            try verifyExactClaimProjectionRetry(
                projection,
                inputBoundary: inputBoundary,
                existingReceipt: existingReceipt,
                events: events,
                currentState: currentState
            )
            builders[sessionID] = try Self.builder(for: sessionID, existing: events)
            return ClaimProjectionCommitResult(
                appendedEventBoundaries: [],
                canonicalState: currentState
            )
        }

        let plan = try ClaimProjectionCommitPlanner().plan(
            projection,
            inputBoundary: inputBoundary,
            currentState: currentState
        )

        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        let modelIdentity = ModelIdentity(
            provider: try NonEmptyString(validating: "openai"),
            model: try NonEmptyString(validating: projection.modelCall.model),
            operationVersion: try NonEmptyString(validating: projection.modelCall.promptVersion)
        )
        let modelValidator = try NonEmptyString(validating: "scout-macos-claim-projection-validator")
        var additions: [ValidatedScoutEvent] = []
        if plan.shouldRecordModelCall {
            additions.append(try builder.seal(
                id: plan.modelCallEventID,
                occurredAt: timestamp,
                recordedAt: timestamp,
                causationID: inputBoundary.id,
                command: .modelProjection(
                    validator: modelValidator,
                    model: modelIdentity,
                    operation: .recordCall(plan.modelCallReceipt)
                )
            ))
        }
        for operation in plan.derivedEvents {
            additions.append(try builder.seal(
                id: operation.id,
                occurredAt: timestamp,
                recordedAt: timestamp,
                correlationID: plan.modelCallEventID,
                causationID: plan.modelCallEventID,
                command: .modelProjection(
                    validator: modelValidator,
                    model: modelIdentity,
                    operation: try Self.modelProjectionCommand(for: operation.payload)
                )
            ))
        }
        guard let first = additions.first else {
            throw JournalError.invalidProjectionPlan
        }

        let key = try IdempotencyKey(
            // Receipt identity commits the provider response, exact input boundary, contract
            // versions, model, and output hash. Equal output bytes at different boundaries are
            // distinct model calls and must never share an append idempotency key.
            "claim-projection:\(rawSessionID):\(plan.modelCallReceipt.id.rawValue)"
        )
        let receipts = try await database.append(
            additions,
            expecting: try Self.expectedVersion(before: first),
            idempotencyKey: key
        )
        guard receipts.count == additions.count else {
            throw JournalError.invalidCommitBoundary
        }
        guard let canonicalState = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }
        builders[sessionID] = builder
        return ClaimProjectionCommitResult(
            appendedEventBoundaries: receipts,
            canonicalState: canonicalState
        )
    }

    /// A retry is safe only when the incoming projection regenerates the exact manifest-bearing
    /// plan from the original projection base and those exact events completed in the log.
    private func verifyExactClaimProjectionRetry(
        _ projection: ClaimProposalProjection,
        inputBoundary: ScoutEventEnvelope,
        existingReceipt: ModelCallReceipt,
        events: [ScoutEventEnvelope],
        currentState: ScoutState
    ) throws {
        let conflict = ClaimProjectionCommitPlanningError.conflictingModelResponse(
            projection.modelCall.responseID
        )
        guard let manifest = existingReceipt.derivedEventManifest,
              let modelCallEventID = currentState.modelCallEvents.first(where: {
                  $0.value == existingReceipt.id
              })?.key,
              let modelCallIndex = events.firstIndex(where: { $0.id == modelCallEventID }),
              case let .modelCallRecorded(persistedReceipt) = events[modelCallIndex].payload,
              persistedReceipt == existingReceipt,
              let projectionBaseIndex = events.firstIndex(where: {
                  ModelInputEventBoundary($0) == manifest.projectionBase
              }),
              projectionBaseIndex < modelCallIndex,
              let completed = currentState.completedDerivedEventProjections[modelCallEventID],
              completed.receiptID == existingReceipt.id,
              completed.modelCallEventID == modelCallEventID,
              completed.manifest == manifest,
              completed.isComplete
        else {
            throw conflict
        }

        let projectionBaseState: ScoutState
        do {
            projectionBaseState = try ScoutGraphReducer.replay(
                Array(events.prefix(through: projectionBaseIndex))
            )
        } catch {
            throw conflict
        }

        let regenerated: ClaimProjectionCommitPlan
        do {
            regenerated = try ClaimProjectionCommitPlanner().plan(
                projection,
                inputBoundary: inputBoundary,
                currentState: projectionBaseState
            )
        } catch {
            throw conflict
        }

        let derivedStart = modelCallIndex + 1
        let derivedEnd = derivedStart + Int(manifest.eventCount)
        guard regenerated.shouldRecordModelCall,
              regenerated.modelCallEventID == modelCallEventID,
              regenerated.modelCallReceipt == existingReceipt,
              regenerated.derivedEvents.count == Int(manifest.eventCount),
              derivedEnd <= events.endIndex
        else {
            throw conflict
        }

        let persistedDerivedEvents = events[derivedStart ..< derivedEnd]
        guard zip(regenerated.derivedEvents, persistedDerivedEvents).allSatisfy({ planned, persisted in
            planned.id == persisted.id
                && planned.payload == persisted.payload
                && persisted.correlationID == modelCallEventID
                && persisted.causationID == modelCallEventID
        }) else {
            throw conflict
        }
    }

    private func acquireOperationLock() async throws {
        try Task.checkCancellation()
        if !operationIsLocked {
            operationIsLocked = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    operationWaiters.append(OperationWaiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelOperationWaiter(waiterID) }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // The lock may already have been handed to this waiter. Pass it on before propagating
            // cancellation so no canceled task can strand the journal queue.
            releaseOperationLock()
            throw error
        }
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseOperationLock() {
        guard !operationWaiters.isEmpty else {
            operationIsLocked = false
            return
        }
        operationWaiters.removeFirst().continuation.resume()
    }

    private func database() throws -> SQLiteEventStore {
        if let store { return store }
        let opened = try SQLiteEventStore(
            fileURL: fileURL,
            encryptionKey: try encryptionKeyProvider()
        )
        store = opened
        return opened
    }

    private struct RelativeTime {
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        let startedAt: ScoutTimestamp
        let endedAt: ScoutTimestamp
    }

    private static func validateRelativeTimeArguments(
        startMilliseconds: Int64?,
        endMilliseconds: Int64?
    ) throws {
        switch (startMilliseconds, endMilliseconds) {
        case (nil, nil):
            return
        case let (.some(start), .some(end)) where start >= 0 && end >= start:
            return
        default:
            throw JournalError.invalidUtteranceTimeRange
        }
    }

    private static func relativeTime(
        startMilliseconds requestedStart: Int64?,
        endMilliseconds requestedEnd: Int64?,
        sessionStartedAt: ScoutTimestamp,
        recordedAt: ScoutTimestamp
    ) throws -> RelativeTime {
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        if let requestedStart, let requestedEnd {
            startMilliseconds = requestedStart
            endMilliseconds = requestedEnd
        } else {
            let elapsed = recordedAt.millisecondsSinceUnixEpoch.subtractingReportingOverflow(
                sessionStartedAt.millisecondsSinceUnixEpoch
            )
            guard !elapsed.overflow else {
                throw JournalError.invalidUtteranceTimeRange
            }
            startMilliseconds = max(0, elapsed.partialValue)
            endMilliseconds = startMilliseconds
        }

        let absoluteStart = sessionStartedAt.millisecondsSinceUnixEpoch
            .addingReportingOverflow(startMilliseconds)
        let absoluteEnd = sessionStartedAt.millisecondsSinceUnixEpoch
            .addingReportingOverflow(endMilliseconds)
        guard !absoluteStart.overflow, !absoluteEnd.overflow else {
            throw JournalError.invalidUtteranceTimeRange
        }
        return RelativeTime(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            startedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: absoluteStart.partialValue),
            endedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: absoluteEnd.partialValue)
        )
    }

    private static func sessionStarted(
        in events: [ScoutEventEnvelope]
    ) throws -> DiscoverySession {
        for event in events {
            guard case let .sessionStarted(session) = event.payload else { continue }
            return session
        }
        throw JournalError.missingSessionStart
    }

    private static func persistedReceipt(
        in events: [ScoutEventEnvelope],
        session: DiscoverySession,
        utteranceEventID: EventID,
        evidenceEventID: EventID,
        utteranceID: UtteranceID,
        evidenceID: EvidenceID,
        speakerID: SpeakerID,
        text: NonEmptyString,
        confidence: Confidence,
        languageCode: String,
        requestedStartMilliseconds: Int64?,
        requestedEndMilliseconds: Int64?
    ) throws -> FinalUtteranceReceipt? {
        let utteranceEvent = events.first { $0.id == utteranceEventID }
        let evidenceEvent = events.first { $0.id == evidenceEventID }
        guard utteranceEvent != nil || evidenceEvent != nil else { return nil }
        guard let utteranceEvent,
              let evidenceEvent,
              case let .utteranceFinalized(utterance) = utteranceEvent.payload,
              case let .evidenceRecorded(evidence) = evidenceEvent.payload,
              utterance.id == utteranceID,
              utterance.speakerID == speakerID,
              utterance.text == text,
              utterance.transcriptionConfidence == confidence,
              utterance.languageCode == languageCode,
              evidence.id == evidenceID,
              evidence.source == .utterance(utteranceID),
              evidence.excerpt == text,
              evidence.capturedAt == utterance.endedAt,
              evidenceEvent.causationID == utteranceEventID,
              evidenceEvent.sequence == (try? utteranceEvent.sequence.successor())
        else {
            throw JournalError.finalizedItemConflict
        }

        let start = utterance.startedAt.millisecondsSinceUnixEpoch.subtractingReportingOverflow(
            session.startedAt.millisecondsSinceUnixEpoch
        )
        let end = utterance.endedAt.millisecondsSinceUnixEpoch.subtractingReportingOverflow(
            session.startedAt.millisecondsSinceUnixEpoch
        )
        guard !start.overflow,
              !end.overflow,
              start.partialValue >= 0,
              end.partialValue >= start.partialValue
        else {
            throw JournalError.invalidPersistedUtteranceTime
        }
        if let requestedStartMilliseconds,
           let requestedEndMilliseconds,
           (start.partialValue != requestedStartMilliseconds
               || end.partialValue != requestedEndMilliseconds)
        {
            throw JournalError.finalizedItemConflict
        }

        return FinalUtteranceReceipt(
            utteranceID: utteranceID,
            evidenceID: evidenceID,
            committedEvidenceBoundary: AppendReceipt(event: evidenceEvent),
            speakerID: speakerID,
            text: text.rawValue,
            startMilliseconds: start.partialValue,
            endMilliseconds: end.partialValue
        )
    }

    private static func builder(
        for sessionID: SessionID,
        existing: [ScoutEventEnvelope]
    ) throws -> EventChainBuilder {
        guard let last = existing.last else { return EventChainBuilder(sessionID: sessionID) }
        return EventChainBuilder(
            sessionID: sessionID,
            nextSequence: try last.sequence.successor(),
            previousHash: last.integrityHash
        )
    }

    private static func sameVisualObservationProposal(
        _ existing: ScoutCore.VisualObservation,
        _ proposed: ScoutCore.VisualObservation
    ) -> Bool {
        existing.id == proposed.id
            && existing.evidenceID == proposed.evidenceID
            && existing.modelCallReceiptID == proposed.modelCallReceiptID
            && existing.kind == proposed.kind
            && existing.title == proposed.title
            && existing.detail == proposed.detail
            && existing.basis == proposed.basis
            && existing.confidence == proposed.confidence
    }

    private static func sameModelProviderResponse(
        _ existing: ModelCallReceipt,
        _ requested: ModelCallReceipt
    ) -> Bool {
        existing.id == requested.id
            && existing.provider == requested.provider
            && existing.providerResponseID == requested.providerResponseID
            && existing.purpose == requested.purpose
            && existing.inputBoundary == requested.inputBoundary
            && existing.promptVersion == requested.promptVersion
            && existing.outputSchemaVersion == requested.outputSchemaVersion
            && existing.model == requested.model
            && existing.outputHash == requested.outputHash
            && existing.metadata == requested.metadata
    }

    private static func receipt(
        _ base: ModelCallReceipt,
        attaching manifest: DerivedEventManifest
    ) throws -> ModelCallReceipt {
        try ModelCallReceipt(
            id: base.id,
            provider: base.provider,
            providerResponseID: base.providerResponseID,
            purpose: base.purpose,
            inputBoundary: base.inputBoundary,
            promptVersion: base.promptVersion,
            outputSchemaVersion: base.outputSchemaVersion,
            model: base.model,
            outputHash: base.outputHash,
            derivedEventManifest: manifest,
            metadata: base.metadata
        )
    }

    private static func expectedVersion(before event: ValidatedScoutEvent) throws -> ExpectedStreamVersion {
        let event = event.envelope
        if event.sequence.rawValue == 1 { return .empty }
        return .sequence(try EventSequence(event.sequence.rawValue - 1))
    }

    private static func timestamp(_ date: Date = .now) -> ScoutTimestamp {
        ScoutTimestamp(
            millisecondsSinceUnixEpoch: Int64(
                (date.timeIntervalSince1970 * 1_000).rounded(.down)
            )
        )
    }

    private static func systemActor() throws -> EventActor {
        .system(component: try systemComponent())
    }

    private static func systemComponent() throws -> NonEmptyString {
        try NonEmptyString(validating: "scout-macos")
    }

    private static func modelProjectionCommand(
        for payload: ScoutEventPayload
    ) throws -> ModelProjectionCommand {
        switch payload {
        case let .entityUpserted(entity): .upsertEntity(entity)
        case let .claimProposed(claim): .proposeClaim(claim)
        case let .relationshipUpserted(relationship): .upsertRelationship(relationship)
        default: throw JournalError.invalidProjectionPlan
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func imageEvidenceExcerpt(
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int
    ) -> String {
        "Imported visual evidence · normalized JPEG · \(pixelWidth)×\(pixelHeight) · \(byteCount) bytes"
    }

    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Scout", directoryHint: .isDirectory)
            .appending(path: "Scout.sqlite")
    }

    enum JournalError: LocalizedError, Equatable {
        case sessionNotPrepared
        case finalizedItemConflict
        case invalidUtteranceTimeRange
        case invalidPersistedUtteranceTime
        case missingSessionStart
        case invalidCommitBoundary
        case missingModelInputBoundary
        case invalidProjectionPlan
        case invalidImageEvidence
        case imageEvidenceConflict
        case imageObservationConflict
        case missingVisualObservation
        case visualObservationReviewConflict
        case missingClaim
        case claimReviewConflict
        case invalidReviewAuthorization

        var errorDescription: String? {
            switch self {
            case .sessionNotPrepared:
                "The live discovery session was not prepared in the event journal."
            case .finalizedItemConflict:
                "A finalized transcript item was reused with different evidence."
            case .invalidUtteranceTimeRange:
                "Utterance times must be a nonnegative, ordered session-relative range."
            case .invalidPersistedUtteranceTime:
                "Persisted utterance times do not resolve to the discovery-session timeline."
            case .missingSessionStart:
                "The event stream does not contain its required session-start boundary."
            case .invalidCommitBoundary:
                "The event store did not return the committed evidence boundary."
            case .missingModelInputBoundary:
                "The model proposal does not resolve to an exact persisted input boundary."
            case .invalidProjectionPlan:
                "The validated model proposal produced an invalid empty commit plan."
            case .invalidImageEvidence:
                "The normalized image does not satisfy Scout's durable evidence contract."
            case .imageEvidenceConflict:
                "This visual evidence digest is already recorded with different metadata."
            case .imageObservationConflict:
                "The image observation does not resolve to its exact durable evidence boundary."
            case .missingVisualObservation:
                "The visual observation does not exist in this discovery session."
            case .visualObservationReviewConflict:
                "This visual observation already has a different terminal review."
            case .missingClaim:
                "The claim does not exist in this discovery session."
            case .claimReviewConflict:
                "This claim already has a different terminal review."
            case .invalidReviewAuthorization:
                "Scout could not bind this authentication to the exact review decision."
            }
        }
    }
}
