import Foundation
import Testing
@testable import ScoutCore

@Suite("Derived model-event manifests")
struct ModelProjectionManifestTests {
    @Test("An exact declared projection completes its rolling commitment")
    func exactProjectionCompletes() throws {
        let fixture = try makeFixture()
        let events = fixture.prefix.map(\.envelope) + [
            fixture.receiptEvent.envelope,
            fixture.proposalEvent.envelope,
        ]

        let state = try ScoutGraphReducer.replay(events)

        #expect(state.claims[fixture.claim.id] == fixture.claim)
        #expect(state.pendingDerivedEventProjections.isEmpty)
        let completed = try #require(
            state.completedDerivedEventProjections[fixture.receiptEvent.envelope.id]
        )
        #expect(completed.receiptID == fixture.receipt.id)
        #expect(completed.consumedCount == 1)
        #expect(completed.rollingRoot == fixture.manifest.finalRoot)
        #expect(completed.isComplete)

        let roundTripped = try JSONDecoder().decode(
            ScoutState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(roundTripped == state)
        #expect(roundTripped.digest == state.digest)
    }

    @Test("Schema v1.4 rejects a model receipt without an exact projection manifest")
    func currentReceiptRequiresManifest() throws {
        let fixture = try makeFixture()
        let receipt = try receiptWithoutManifest(fixture.receipt)
        let prefix = fixture.prefix.map(\.envelope)
        let state = try ScoutGraphReducer.replay(prefix)
        var chain = try chainContinuing(after: prefix)
        let event = try chain.seal(
            id: testID("event-model-without-manifest"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            causationID: receipt.inputBoundary.eventID,
            command: .modelProjection(
                validator: testText("manifest-test-validator"),
                model: modelIdentity(),
                operation: .recordCall(receipt)
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProjectionManifestRequired(event.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: event)
        }
    }

    @Test("A legacy receipt cannot authorize a schema v1.4 derived proposal")
    func legacyReceiptCannotAuthorizeCurrentProposal() throws {
        let legacySchema = EventSchemaVersion(major: 1, minor: 3)
        let sessionID: SessionID = testID("session-legacy-model-receipt")
        let evidenceID: EvidenceID = testID("evidence-legacy-model-receipt")
        let validator = testText("manifest-test-validator")
        let systemActor = EventActor.system(component: validator)
        var chain = EventChainBuilder(sessionID: sessionID)
        var prefix = [try chain.seal(
            schemaVersion: legacySchema,
            id: testID("event-legacy-model-session"),
            occurredAt: timestamp(),
            recordedAt: timestamp(),
            actor: systemActor,
            authorization: .init(scope: .sessionLifecycle, component: validator),
            payload: .sessionStarted(DiscoverySession(
                id: sessionID,
                title: testText("Legacy model receipt fixture"),
                startedAt: timestamp()
            ))
        )]
        let evidenceEvent = try chain.seal(
            schemaVersion: legacySchema,
            id: testID("event-legacy-model-evidence"),
            occurredAt: timestamp(1),
            recordedAt: timestamp(1),
            actor: systemActor,
            authorization: .init(scope: .evidenceImport, component: validator),
            payload: .evidenceRecorded(Evidence(
                id: evidenceID,
                source: .external(reference: testText("legacy-model-fixture")),
                excerpt: testText("Legacy model evidence"),
                capturedAt: timestamp(1),
                capturedBy: systemActor
            ))
        )
        prefix.append(evidenceEvent)
        let receipt = try ModelCallReceipt(
            id: testID("model-call-legacy-without-manifest"),
            provider: testText("openai"),
            providerResponseID: testText("resp_legacy_without_manifest"),
            purpose: .claimExtraction,
            inputBoundary: ModelInputEventBoundary(evidenceEvent),
            promptVersion: testText("claim-extraction.v1"),
            outputSchemaVersion: testText("claim-proposals.v1"),
            model: testText("gpt-fixture"),
            outputHash: SHA256Digest.hash(Data("legacy-provider-output".utf8))
        )
        let legacyEvent = try chain.seal(
            schemaVersion: legacySchema,
            id: testID("event-legacy-model-without-manifest"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(2),
            actor: .model(modelIdentity()),
            authorization: EventAuthorizationRecord(
                scope: .modelProjection,
                component: validator
            ),
            causationID: receipt.inputBoundary.eventID,
            payload: .modelCallRecorded(receipt)
        )
        let state = try ScoutGraphReducer.replay(prefix + [legacyEvent])
        let claim = Claim(
            id: testID("claim-current-from-legacy-receipt"),
            subject: .session(sessionID),
            predicate: .hasGoal,
            object: .value(.text("Must require a manifest")),
            evidenceIDs: [evidenceID],
            trust: TrustAssessment(
                origin: .suggested,
                confidence: try Confidence(basisPoints: 7_500),
                validationStatus: .needsValidation
            )
        )
        let proposal = try chain.seal(
            id: testID("event-current-proposal-from-legacy-receipt"),
            occurredAt: timestamp(3),
            recordedAt: timestamp(3),
            correlationID: legacyEvent.id,
            causationID: legacyEvent.id,
            command: .modelProjection(
                validator: validator,
                model: modelIdentity(),
                operation: .proposeClaim(claim)
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProjectionManifestRequired(proposal.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
    }

    @Test("No unrelated event can interrupt a pending manifested projection")
    func pendingProjectionMustRemainContiguous() throws {
        let fixture = try makeFixture()
        let prefix = fixture.prefix.map(\.envelope)
        let base = try ScoutGraphReducer.replay(prefix)
        let pending = try ScoutGraphReducer.reduce(base, event: fixture.receiptEvent)
        var chain = try chainContinuing(after: prefix + [fixture.receiptEvent.envelope])
        let interruption = try chain.seal(
            id: testID("event-interrupting-manifest"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            command: .sessionLifecycle(
                component: testText("manifest-test"),
                operation: .upsertSpeaker(Speaker(
                    id: testID("speaker-interrupting-manifest"),
                    displayName: testText("Interrupting speaker"),
                    affiliation: .internalTeam
                ))
            )
        )

        #expect(throws: ScoutReducerError.derivedEventManifestInterrupted(
            modelCallEventID: fixture.receiptEvent.envelope.id,
            eventID: interruption.envelope.id
        )) {
            _ = try ScoutGraphReducer.reduce(pending, event: interruption)
        }
    }

    @Test("A completed receipt cannot authorize an undeclared extra payload")
    func receiptCannotAuthorizeExtraPayload() throws {
        let fixture = try makeFixture()
        let committedEvents = fixture.prefix.map(\.envelope) + [
            fixture.receiptEvent.envelope,
            fixture.proposalEvent.envelope,
        ]
        let state = try ScoutGraphReducer.replay(committedEvents)
        let before = state.digest
        var chain = try chainContinuing(after: committedEvents)
        let extraClaim = proposedClaim(id: "claim-not-in-provider-output")
        let extra = try chain.seal(
            id: testID("event-not-in-derived-manifest"),
            occurredAt: timestamp(10),
            recordedAt: timestamp(11),
            correlationID: fixture.receiptEvent.envelope.id,
            causationID: fixture.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("manifest-test-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(extraClaim)
            )
        )

        #expect(throws: ScoutReducerError.derivedEventManifestUnexpectedEvent(
            modelCallEventID: fixture.receiptEvent.envelope.id,
            eventID: extra.envelope.id
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: extra)
        }
        #expect(state.digest == before)
        #expect(state.claims[extraClaim.id] == nil)
    }

    @Test("A derived payload cannot escape its manifest by relabeling its command scope")
    func deterministicScopeCannotReuseModelReceiptLinkage() throws {
        let fixture = try makeFixture()
        let committedEvents = fixture.prefix.map(\.envelope) + [
            fixture.receiptEvent.envelope,
            fixture.proposalEvent.envelope,
        ]
        let state = try ScoutGraphReducer.replay(committedEvents)
        var chain = try chainContinuing(after: committedEvents)
        let event = try chain.seal(
            id: testID("event-relabelled-model-derivation"),
            occurredAt: timestamp(10),
            recordedAt: timestamp(11),
            correlationID: fixture.receiptEvent.envelope.id,
            causationID: fixture.receiptEvent.envelope.id,
            command: .deterministicProjection(
                component: testText("not-a-model-projection"),
                operation: .proposeClaim(proposedClaim(id: "claim-relabelled-model-derivation"))
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelReceiptLinkageRequiresModelProjection(event.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: event)
        }
    }

    @Test("Changing one committed payload field fails the final root")
    func changedPayloadFailsRoot() throws {
        let fixture = try makeFixture()
        let base = try ScoutGraphReducer.replay(fixture.prefix.map(\.envelope))
        let withReceipt = try ScoutGraphReducer.reduce(base, event: fixture.receiptEvent)
        let changedClaim = Claim(
            id: fixture.claim.id,
            subject: fixture.claim.subject,
            predicate: fixture.claim.predicate,
            object: .value(.text("A payload that was not committed")),
            assertedBy: fixture.claim.assertedBy,
            evidenceIDs: fixture.claim.evidenceIDs,
            trust: fixture.claim.trust
        )
        var chain = try chainContinuing(after: fixture.prefix.map(\.envelope) + [
            fixture.receiptEvent.envelope,
        ])
        let changed = try chain.seal(
            id: fixture.proposalEvent.envelope.id,
            occurredAt: fixture.proposalEvent.envelope.occurredAt,
            recordedAt: fixture.proposalEvent.envelope.recordedAt,
            correlationID: fixture.receiptEvent.envelope.id,
            causationID: fixture.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("manifest-test-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(changedClaim)
            )
        )
        let seed = fixture.manifest.seed(
            receiptID: fixture.receipt.id,
            outputHash: fixture.receipt.outputHash
        )
        let changedRoot = DerivedEventManifest.advance(
            root: seed,
            ordinal: 0,
            entry: .init(eventID: changed.envelope.id, payload: changed.envelope.payload)
        )

        #expect(throws: ScoutReducerError.derivedEventManifestRootMismatch(
            receiptID: fixture.receipt.id,
            expected: fixture.manifest.finalRoot,
            actual: changedRoot
        )) {
            _ = try ScoutGraphReducer.reduce(withReceipt, event: changed)
        }
        #expect(withReceipt.claims[changedClaim.id] == nil)
        #expect(withReceipt.pendingDerivedEventProjections.count == 1)
    }

    @Test("The in-memory store atomically rejects an incomplete projection batch")
    func incompleteBatchRollsBack() async throws {
        let fixture = try makeFixture()
        let store = InMemoryEventStore()
        _ = try await store.append(fixture.prefix)
        let before = try #require(await store.state(for: ScoutFixtures.sessionID))

        do {
            _ = try await store.append(fixture.receiptEvent)
            Issue.record("Expected an incomplete manifest batch to fail")
        } catch let error as EventStoreError {
            #expect(error == .reduction(.incompleteDerivedEventManifest(
                receiptID: fixture.receipt.id,
                expectedCount: 1,
                actualCount: 0
            )))
        }

        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == fixture.prefix.count)
        #expect(await store.state(for: ScoutFixtures.sessionID)?.digest == before.digest)

        let receipts = try await store.append([
            fixture.receiptEvent,
            fixture.proposalEvent,
        ])
        #expect(receipts.count == 2)
        let committed = try #require(await store.state(for: ScoutFixtures.sessionID))
        #expect(committed.pendingDerivedEventProjections.isEmpty)
        #expect(committed.claims[fixture.claim.id] == fixture.claim)
    }

    @Test("An empty manifest completes at its seed and permits no derived payload")
    func emptyManifest() async throws {
        let fixture = try makeFixture(entries: [])
        let store = InMemoryEventStore()
        _ = try await store.append(fixture.prefix)
        _ = try await store.append(fixture.receiptEvent)

        let state = try #require(await store.state(for: ScoutFixtures.sessionID))
        let completed = try #require(
            state.completedDerivedEventProjections[fixture.receiptEvent.envelope.id]
        )
        #expect(completed.consumedCount == 0)
        #expect(completed.isComplete)
        #expect(state.pendingDerivedEventProjections.isEmpty)
    }

    @Test("Manifest construction is bounded to 512 ordered events")
    func manifestBound() throws {
        let prefix = Array(try ScoutFixtures.sampleEvents().prefix(8))
        let base = ModelInputEventBoundary(try #require(prefix.last))
        let outputHash = SHA256Digest.hash(Data("bounded-output".utf8))
        let receiptID: ModelCallReceiptID = testID("model-call-manifest-bound")
        let entries = (0 ... DerivedEventManifest.maximumEventCount).map { index in
            DerivedEventManifestEntry(
                eventID: testID("event-manifest-bound-\(index)"),
                payloadKind: "claim.proposed",
                payloadHash: SHA256Digest.hash(Data("payload-\(index)".utf8))
            )
        }

        #expect(throws: ModelCallReceiptValidationError.derivedEventManifestTooLarge(513)) {
            _ = try DerivedEventManifest.committing(
                adapterID: testText("claim-projection"),
                adapterVersion: testText("v1"),
                projectionBase: base,
                receiptID: receiptID,
                outputHash: outputHash,
                entries: entries
            )
        }
        let maximum = try DerivedEventManifest.committing(
            adapterID: testText("claim-projection"),
            adapterVersion: testText("v1"),
            projectionBase: base,
            receiptID: receiptID,
            outputHash: outputHash,
            entries: Array(entries.prefix(DerivedEventManifest.maximumEventCount))
        )
        #expect(maximum.eventCount == 512)

        var encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(maximum)) as? [String: Any]
        )
        encoded["eventCount"] = 513
        #expect(throws: ModelCallReceiptValidationError.derivedEventManifestTooLarge(513)) {
            _ = try JSONDecoder().decode(
                DerivedEventManifest.self,
                from: JSONSerialization.data(withJSONObject: encoded)
            )
        }
    }

    @Test("Seed and entry roots bind every required field and order")
    func rollingCommitmentBindings() throws {
        let prefix = Array(try ScoutFixtures.sampleEvents().prefix(8))
        let base = ModelInputEventBoundary(try #require(prefix.last))
        let receiptID: ModelCallReceiptID = testID("model-call-rolling-bindings")
        let outputHash = SHA256Digest.hash(Data("rolling-output".utf8))
        let first = DerivedEventManifestEntry(
            eventID: testID("event-rolling-a"),
            payloadKind: "claim.proposed",
            payloadHash: SHA256Digest.hash(Data("payload-a".utf8))
        )
        let second = DerivedEventManifestEntry(
            eventID: testID("event-rolling-b"),
            payloadKind: "entity.upserted",
            payloadHash: SHA256Digest.hash(Data("payload-b".utf8))
        )

        func manifest(
            adapterID: String = "adapter-a",
            adapterVersion: String = "v1",
            output: SHA256Digest = outputHash,
            entries: [DerivedEventManifestEntry] = [first, second]
        ) throws -> DerivedEventManifest {
            try .committing(
                adapterID: testText(adapterID),
                adapterVersion: testText(adapterVersion),
                projectionBase: base,
                receiptID: receiptID,
                outputHash: output,
                entries: entries
            )
        }

        let expected = try manifest()
        #expect(try manifest(adapterID: "adapter-b").finalRoot != expected.finalRoot)
        #expect(try manifest(adapterVersion: "v2").finalRoot != expected.finalRoot)
        #expect(try manifest(output: SHA256Digest.hash(Data("other-output".utf8))).finalRoot
            != expected.finalRoot)
        #expect(try manifest(entries: [second, first]).finalRoot != expected.finalRoot)
        #expect(try manifest(entries: [first]).finalRoot != expected.finalRoot)
        let changedEvent = DerivedEventManifestEntry(
            eventID: testID("event-rolling-changed"),
            payloadKind: first.payloadKind,
            payloadHash: first.payloadHash
        )
        let changedKind = DerivedEventManifestEntry(
            eventID: first.eventID,
            payloadKind: "relationship.upserted",
            payloadHash: first.payloadHash
        )
        let changedHash = DerivedEventManifestEntry(
            eventID: first.eventID,
            payloadKind: first.payloadKind,
            payloadHash: SHA256Digest.hash(Data("changed-payload".utf8))
        )
        #expect(try manifest(entries: [changedEvent, second]).finalRoot != expected.finalRoot)
        #expect(try manifest(entries: [changedKind, second]).finalRoot != expected.finalRoot)
        #expect(try manifest(entries: [changedHash, second]).finalRoot != expected.finalRoot)
    }

    @Test("The v1 rolling commitment matches its literal compatibility vector")
    func rollingCommitmentKnownAnswerVector() throws {
        let base = try ModelInputEventBoundary(
            eventID: testID("event-vector-base"),
            sequence: EventSequence(42),
            integrityHash: SHA256Digest(validating: String(repeating: "11", count: 32))
        )
        let receiptID: ModelCallReceiptID = testID("model-call-vector")
        let outputHash = try SHA256Digest(validating: String(repeating: "22", count: 32))
        let entries = [
            DerivedEventManifestEntry(
                eventID: testID("event-vector-a"),
                payloadKind: "claim.proposed",
                payloadHash: try SHA256Digest(validating: String(repeating: "33", count: 32))
            ),
            DerivedEventManifestEntry(
                eventID: testID("event-vector-b"),
                payloadKind: "relationship.upserted",
                payloadHash: try SHA256Digest(validating: String(repeating: "44", count: 32))
            ),
        ]
        let manifest = try DerivedEventManifest.committing(
            adapterID: testText("adapter-vector"),
            adapterVersion: testText("v1"),
            projectionBase: base,
            receiptID: receiptID,
            outputHash: outputHash,
            entries: entries
        )

        #expect(manifest.seed(receiptID: receiptID, outputHash: outputHash).rawValue
            == "8c3fb96c821cccbb33c3ff24ec045e2aaf0c2e90684d640450241e0641e47ea0")
        #expect(manifest.finalRoot.rawValue
            == "3a98629fca8fb3ba48b7906973662855f3b4c9544ed2739a10d39ff72fbfea6e")
    }

    @Test("Legacy state and receipts decode without manifest projections")
    func legacyDecodeDefaults() throws {
        let currentReceipt = try #require(
            ScoutFixtures.sampleState().modelCallReceipts[ScoutFixtures.modelCallReceiptID]
        )
        let receipt = try ModelCallReceipt(
            id: currentReceipt.id,
            provider: currentReceipt.provider,
            providerResponseID: currentReceipt.providerResponseID,
            purpose: currentReceipt.purpose,
            inputBoundary: currentReceipt.inputBoundary,
            promptVersion: currentReceipt.promptVersion,
            outputSchemaVersion: currentReceipt.outputSchemaVersion,
            model: currentReceipt.model,
            outputHash: currentReceipt.outputHash,
            metadata: currentReceipt.metadata
        )
        #expect(receipt.derivedEventManifest == nil)
        #expect(!CanonicalJSON.string(receipt.canonicalValue).contains("derivedEventManifest"))

        let state = try ScoutFixtures.sampleState()
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object.removeValue(forKey: "pendingDerivedEventProjections")
        object.removeValue(forKey: "completedDerivedEventProjections")
        object.removeValue(forKey: "lastSchemaVersion")
        let decoded = try JSONDecoder().decode(
            ScoutState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.pendingDerivedEventProjections.isEmpty)
        #expect(decoded.completedDerivedEventProjections.isEmpty)
        var expected = state
        expected.pendingDerivedEventProjections = [:]
        expected.completedDerivedEventProjections = [:]
        expected.lastSchemaVersion = nil
        #expect(decoded == expected)
    }

    @Test("Decoded projection progress cannot exceed its bounded manifest")
    func decodedProgressIsBounded() throws {
        let fixture = try makeFixture()
        let progress = DerivedEventProjectionProgress(
            receiptID: fixture.receipt.id,
            modelCallEventID: fixture.receiptEvent.envelope.id,
            manifest: fixture.manifest,
            consumedCount: 0,
            rollingRoot: fixture.manifest.seed(
                receiptID: fixture.receipt.id,
                outputHash: fixture.receipt.outputHash
            )
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any]
        )
        object["consumedCount"] = Int(UInt16.max)

        #expect(throws: ModelCallReceiptValidationError.invalidDerivedEventProjectionProgress(
            consumedCount: UInt16.max,
            eventCount: fixture.manifest.eventCount
        )) {
            _ = try JSONDecoder().decode(
                DerivedEventProjectionProgress.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    private struct Fixture {
        let prefix: [ValidatedScoutEvent]
        let receipt: ModelCallReceipt
        let manifest: DerivedEventManifest
        let receiptEvent: ValidatedScoutEvent
        let proposalEvent: ValidatedScoutEvent
        let claim: Claim
    }

    private func makeFixture(
        entries requestedEntries: [DerivedEventManifestEntry]? = nil
    ) throws -> Fixture {
        let prefix = Array(try ScoutFixtures.sampleValidatedEvents().prefix(8))
        let inputBoundary = ModelInputEventBoundary(prefix[3].envelope)
        let projectionBase = ModelInputEventBoundary(try #require(prefix.last?.envelope))
        let receiptID: ModelCallReceiptID = testID("model-call-derived-manifest")
        let outputHash = SHA256Digest.hash(Data("manifest-provider-output".utf8))
        let claim = proposedClaim(id: "claim-declared-by-manifest")
        let proposalID: EventID = testID("event-declared-by-manifest")
        let defaultEntries = [
            DerivedEventManifestEntry(
                eventID: proposalID,
                payload: .claimProposed(claim)
            ),
        ]
        let entries = requestedEntries ?? defaultEntries
        let manifest = try DerivedEventManifest.committing(
            adapterID: testText("claim-projection"),
            adapterVersion: testText("v1"),
            projectionBase: projectionBase,
            receiptID: receiptID,
            outputHash: outputHash,
            entries: entries
        )
        let receipt = try ModelCallReceipt(
            id: receiptID,
            provider: testText("openai"),
            providerResponseID: testText("resp_manifest_001"),
            purpose: .claimExtraction,
            inputBoundary: inputBoundary,
            promptVersion: testText("claim-extraction.v1"),
            outputSchemaVersion: testText("claim-proposals.v1"),
            model: testText("gpt-fixture"),
            outputHash: outputHash,
            derivedEventManifest: manifest
        )
        var chain = try chainContinuing(after: prefix.map(\.envelope))
        let receiptEvent = try chain.seal(
            id: testID("event-model-derived-manifest"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            causationID: inputBoundary.eventID,
            command: .modelProjection(
                validator: testText("manifest-test-validator"),
                model: modelIdentity(),
                operation: .recordCall(receipt)
            )
        )
        let proposalEvent = try chain.seal(
            id: proposalID,
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            correlationID: receiptEvent.envelope.id,
            causationID: receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("manifest-test-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(claim)
            )
        )
        return Fixture(
            prefix: prefix,
            receipt: receipt,
            manifest: manifest,
            receiptEvent: receiptEvent,
            proposalEvent: proposalEvent,
            claim: claim
        )
    }

    private func modelIdentity() -> ModelIdentity {
        ModelIdentity(
            provider: testText("openai"),
            model: testText("gpt-fixture"),
            operationVersion: testText("claim-extraction.v1")
        )
    }

    private func receiptWithoutManifest(_ receipt: ModelCallReceipt) throws -> ModelCallReceipt {
        try ModelCallReceipt(
            id: receipt.id,
            provider: receipt.provider,
            providerResponseID: receipt.providerResponseID,
            purpose: receipt.purpose,
            inputBoundary: receipt.inputBoundary,
            promptVersion: receipt.promptVersion,
            outputSchemaVersion: receipt.outputSchemaVersion,
            model: receipt.model,
            outputHash: receipt.outputHash,
            metadata: receipt.metadata
        )
    }

    private func proposedClaim(id: String) -> Claim {
        Claim(
            id: testID(id),
            subject: .entity(ScoutFixtures.customerDataEntityID),
            predicate: .hasGoal,
            object: .value(.text(id)),
            assertedBy: ScoutFixtures.speakerID,
            evidenceIDs: [ScoutFixtures.evidenceID],
            trust: TrustAssessment(
                origin: .suggested,
                confidence: try! Confidence(basisPoints: 8_000),
                validationStatus: .needsValidation
            )
        )
    }
}
