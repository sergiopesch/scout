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
    }

    private let fileURL: URL
    private let encryptionKeyProvider: @Sendable () throws -> Data
    private var store: SQLiteEventStore?
    private var builders: [SessionID: EventChainBuilder] = [:]
    private var operationIsLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

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
        await acquireOperationLock()
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
        await acquireOperationLock()
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
        var additions: [ScoutEventEnvelope] = []
        let now = Self.timestamp()
        let systemActor = try Self.systemActor()

        if existing.isEmpty {
            additions.append(try builder.seal(
                id: try EventID(validating: "event-\(Self.digest("session|\(rawSessionID)"))-started"),
                occurredAt: now,
                recordedAt: now,
                actor: systemActor,
                payload: .sessionStarted(DiscoverySession(
                    id: sessionID,
                    title: try NonEmptyString(validating: title),
                    startedAt: now
                ))
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
                actor: systemActor,
                payload: .speakerUpserted(ScoutCore.Speaker(
                    id: speakerID,
                    displayName: try NonEmptyString(validating: descriptor.displayName),
                    role: try NonEmptyString(validating: descriptor.role),
                    affiliation: descriptor.affiliation
                ))
            ))
        }

        if !additions.isEmpty {
            let expected = try Self.expectedVersion(before: additions[0])
            let additionDigest = Self.digest(additions.map(\.id.rawValue).joined(separator: "|"))
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
        await acquireOperationLock()
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
            actor: actor,
            payload: .utteranceFinalized(Utterance(
                id: utteranceID,
                speakerID: speakerID,
                startedAt: relativeTime.startedAt,
                endedAt: relativeTime.endedAt,
                text: normalizedText,
                transcriptionConfidence: confidence,
                languageCode: languageCode
            ))
        )
        let evidenceEvent = try builder.seal(
            id: evidenceEventID,
            occurredAt: relativeTime.endedAt,
            recordedAt: recordedAt,
            actor: try Self.systemActor(),
            causationID: utteranceEventID,
            payload: .evidenceRecorded(Evidence(
                id: evidenceID,
                source: .utterance(utteranceID),
                excerpt: normalizedText,
                capturedAt: relativeTime.endedAt,
                capturedBy: actor
            ))
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
        await acquireOperationLock()
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
        let excerpt = try NonEmptyString(
            validating: "Imported visual evidence · normalized JPEG · \(image.pixelWidth)×\(image.pixelHeight) · \(image.byteCount) bytes"
        )
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
            actor: try Self.systemActor(),
            payload: .evidenceRecorded(Evidence(
                id: evidenceID,
                source: source,
                excerpt: excerpt,
                capturedAt: timestamp,
                capturedBy: try Self.systemActor()
            ))
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
        await acquireOperationLock()
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

        let receiptID = try ModelCallReceiptID(
            validating: "model-call-image-\(Self.digest("openai|\(rawSessionID)|\(result.modelCall.responseID)|\(result.modelCall.outputSHA256)"))"
        )
        let receipt = try ModelCallReceipt(
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
                "asset_sha256": .text(evidence.assetSHA256),
                "byte_count": .integer(Int64(evidence.byteCount)),
                "pixel_height": .integer(Int64(evidence.pixelHeight)),
                "pixel_width": .integer(Int64(evidence.pixelWidth)),
            ]
        )
        let proposals = try ImageObservationProjector().project(
            result,
            sessionID: rawSessionID,
            evidenceID: evidence.evidenceID,
            modelCallReceiptID: receiptID
        )
        guard let currentState = try await database.state(for: sessionID) else {
            throw JournalError.sessionNotPrepared
        }
        let persistedModelEvent = events.first(where: { event in
            guard case let .modelCallRecorded(existing) = event.payload else { return false }
            return existing.id == receiptID
        })
        if let persistedModelEvent {
            let persisted = persistedModelEvent
            guard case let .modelCallRecorded(existing) = persisted.payload, existing == receipt else {
                throw JournalError.imageObservationConflict
            }
        }

        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        let modelEventID = try EventID(
            validating: "event-model-image-\(Self.digest("\(rawSessionID)|\(result.modelCall.responseID)"))"
        )
        let modelActor = EventActor.model(ModelIdentity(
            provider: try NonEmptyString(validating: "openai"),
            model: try NonEmptyString(validating: result.modelCall.model),
            operationVersion: try NonEmptyString(validating: result.modelCall.promptVersion)
        ))
        var additions: [ScoutEventEnvelope] = []
        if persistedModelEvent == nil {
            additions.append(try builder.seal(
                id: modelEventID,
                occurredAt: timestamp,
                recordedAt: timestamp,
                actor: modelActor,
                causationID: inputEvent.id,
                payload: .modelCallRecorded(receipt)
            ))
        }

        var projectedObservations: [ScoutCore.VisualObservation] = []
        for proposal in proposals {
            if let existing = currentState.visualObservations[proposal.id] {
                guard Self.sameVisualObservationProposal(existing, proposal) else {
                    throw JournalError.imageObservationConflict
                }
                projectedObservations.append(existing)
                continue
            }
            let eventID = try EventID(
                validating: "event-visual-proposal-\(Self.digest("\(rawSessionID)|\(proposal.id.rawValue)"))"
            )
            additions.append(try builder.seal(
                id: eventID,
                occurredAt: timestamp,
                recordedAt: timestamp,
                actor: modelActor,
                correlationID: modelEventID,
                causationID: modelEventID,
                payload: .visualObservationProposed(proposal)
            ))
            projectedObservations.append(proposal)
        }

        if additions.isEmpty {
            guard let persistedModelEvent else {
                throw JournalError.invalidCommitBoundary
            }
            builders[sessionID] = builder
            return ImageObservationReceipt(
                modelCallReceiptID: receiptID,
                committedModelBoundary: AppendReceipt(event: persistedModelEvent),
                observations: projectedObservations.sorted { $0.id < $1.id }
            )
        }

        guard let first = additions.first else { throw JournalError.invalidCommitBoundary }
        let additionDigest = Self.digest(additions.map(\.id.rawValue).joined(separator: "|"))
        let receipts = try await database.append(
            additions,
            expecting: try Self.expectedVersion(before: first),
            idempotencyKey: try IdempotencyKey("image-observation-v2:\(rawSessionID):\(additionDigest)")
        )
        guard receipts.count == additions.count else {
            throw JournalError.invalidCommitBoundary
        }
        builders[sessionID] = builder
        let modelBoundary: AppendReceipt
        if let persistedModelEvent {
            modelBoundary = AppendReceipt(event: persistedModelEvent)
        } else if let boundary = receipts.first(where: { $0.eventID == modelEventID }) {
            modelBoundary = boundary
        } else {
            throw JournalError.invalidCommitBoundary
        }
        return ImageObservationReceipt(
            modelCallReceiptID: receiptID,
            committedModelBoundary: modelBoundary,
            observations: projectedObservations.sorted { $0.id < $1.id }
        )
    }

    /// Records the local operator's explicit disposition before the evidence-layer UI changes.
    /// Reviews are terminal and idempotent; confirmation never creates graph or claim events.
    @discardableResult
    func recordVisualObservationReview(
        sessionID rawSessionID: String,
        observationID rawObservationID: String,
        disposition: VisualObservationDisposition
    ) async throws -> VisualObservationReviewReceipt {
        await acquireOperationLock()
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
                  let persisted = events.first(where: { event in
                      guard case let .visualObservationReviewed(review) = event.payload else {
                          return false
                      }
                      return review.observationID == observationID
                          && review.disposition == disposition
                  })
            else {
                throw JournalError.visualObservationReviewConflict
            }
            builders[sessionID] = try Self.builder(for: sessionID, existing: events)
            return VisualObservationReviewReceipt(
                observationID: observationID,
                disposition: disposition,
                committedReviewBoundary: AppendReceipt(event: persisted)
            )
        }

        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        let eventID = try EventID(
            validating: "event-visual-review-\(Self.digest("\(rawSessionID)|\(rawObservationID)|\(disposition.rawValue)"))"
        )
        let event = try builder.seal(
            id: eventID,
            occurredAt: timestamp,
            recordedAt: timestamp,
            actor: .system(component: try NonEmptyString(validating: "scout-macos-review-ui")),
            payload: .visualObservationReviewed(VisualObservationReviewed(
                observationID: observationID,
                disposition: disposition,
                reviewer: .localOperator
            ))
        )
        let receipts = try await database.append(
            [event],
            expecting: try Self.expectedVersion(before: event),
            idempotencyKey: try IdempotencyKey(
                "visual-review:\(rawSessionID):\(rawObservationID):\(disposition.rawValue)"
            )
        )
        guard receipts.count == 1, let boundary = receipts.first, boundary.eventID == eventID else {
            throw JournalError.invalidCommitBoundary
        }
        builders[sessionID] = builder
        return VisualObservationReviewReceipt(
            observationID: observationID,
            disposition: disposition,
            committedReviewBoundary: boundary
        )
    }

    func verify(sessionID rawSessionID: String) async throws -> ChainVerificationReport {
        try await database().verifyChain(for: SessionID(validating: rawSessionID))
    }

    /// Returns the newest session only after SQLite decryption and the canonical reducer have
    /// successfully replayed it. Callers receive no mutable store handles and may discard the
    /// projection at any time.
    func latestReplayState() async throws -> ScoutState? {
        await acquireOperationLock()
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
    ) async throws -> [AppendReceipt] {
        await acquireOperationLock()
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

        let plan = try ClaimProjectionCommitPlanner().plan(
            projection,
            inputBoundary: inputBoundary,
            currentState: currentState
        )
        guard !plan.isNoOp else {
            builders[sessionID] = try Self.builder(for: sessionID, existing: events)
            return []
        }

        var builder = try Self.builder(for: sessionID, existing: events)
        let timestamp = Self.timestamp()
        let actor = EventActor.model(ModelIdentity(
            provider: try NonEmptyString(validating: "openai"),
            model: try NonEmptyString(validating: projection.modelCall.model),
            operationVersion: try NonEmptyString(validating: projection.modelCall.promptVersion)
        ))
        var additions: [ScoutEventEnvelope] = []
        if plan.shouldRecordModelCall {
            additions.append(try builder.seal(
                id: plan.modelCallEventID,
                occurredAt: timestamp,
                recordedAt: timestamp,
                actor: actor,
                causationID: inputBoundary.id,
                payload: .modelCallRecorded(plan.modelCallReceipt)
            ))
        }
        for operation in plan.derivedEvents {
            additions.append(try builder.seal(
                id: operation.id,
                occurredAt: timestamp,
                recordedAt: timestamp,
                actor: actor,
                correlationID: plan.modelCallEventID,
                causationID: plan.modelCallEventID,
                payload: operation.payload
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
        builders[sessionID] = builder
        return receipts
    }

    private func acquireOperationLock() async {
        if !operationIsLocked {
            operationIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationLock() {
        guard !operationWaiters.isEmpty else {
            operationIsLocked = false
            return
        }
        operationWaiters.removeFirst().resume()
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

    private static func expectedVersion(before event: ScoutEventEnvelope) throws -> ExpectedStreamVersion {
        if event.sequence.rawValue == 1 { return .empty }
        return .sequence(try EventSequence(event.sequence.rawValue - 1))
    }

    private static func timestamp(_ date: Date = .now) -> ScoutTimestamp {
        ScoutTimestamp(millisecondsSinceUnixEpoch: Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    private static func systemActor() throws -> EventActor {
        .system(component: try NonEmptyString(validating: "scout-macos"))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
            }
        }
    }
}
