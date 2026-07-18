import CSQLite
import Foundation
import Testing

@testable import ScoutCore
@testable import ScoutPersistence

@Suite("SQLite event store")
struct SQLiteEventStoreTests {
    @Test("Canonical envelopes survive close and reopen")
    func reopenPersistence() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let validatedEvents = try ScoutFixtures.sampleValidatedEvents()
        let expectedEvents = validatedEvents.map(\.envelope)
        let expectedState = try ScoutGraphReducer.replay(expectedEvents)

        let firstStore = try SQLiteEventStore(fileURL: fixture.url)
        let receipts = try await firstStore.append(
            validatedEvents,
            expecting: .empty,
            idempotencyKey: try IdempotencyKey("discovery-import-1")
        )
        #expect(receipts.count == expectedEvents.count)
        try await firstStore.close()

        let reopened = try SQLiteEventStore(fileURL: fixture.url)
        #expect(try await reopened.events(for: ScoutFixtures.sessionID) == expectedEvents)
        #expect(try await reopened.state(for: ScoutFixtures.sessionID)?.digest == expectedState.digest)

        let report = try await reopened.verifyChain(for: ScoutFixtures.sessionID)
        #expect(report.eventCount == expectedEvents.count)
        #expect(report.lastSequence == expectedEvents.last?.sequence)
        #expect(report.lastHash == expectedEvents.last?.integrityHash)
        #expect(report.stateDigest == expectedState.digest)
    }

    @Test("Encrypted event blobs hide content, reopen with the key, and reject a wrong key")
    func encryptedEventBlobs() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let encryptionKey = Data((0 ..< 32).map(UInt8.init))
        let wrongKey = Data(repeating: 0xA5, count: 32)
        let validatedEvents = try ScoutFixtures.sampleValidatedEvents()
        let expectedEvents = validatedEvents.map(\.envelope)

        let firstStore = try SQLiteEventStore(
            fileURL: fixture.url,
            encryptionKey: encryptionKey
        )
        _ = try await firstStore.append(validatedEvents, expecting: .empty)
        try await firstStore.close()

        let marker = Data("session-acme-retail".utf8)
        let rawCanonicalBlob = try rawBlob(
            fixture.url,
            sql: "SELECT envelope FROM scout_events WHERE sequence = 1"
        )
        let rawHydrationBlob = try rawBlob(
            fixture.url,
            sql: "SELECT encoded_envelope FROM scout_events WHERE sequence = 1"
        )
        let canonicalBlob = try #require(rawCanonicalBlob)
        let hydrationBlob = try #require(rawHydrationBlob)
        #expect(canonicalBlob.prefix(5) == Data([0x53, 0x43, 0x54, 0x42, 0x01]))
        #expect(hydrationBlob.prefix(5) == Data([0x53, 0x43, 0x54, 0x42, 0x01]))
        #expect(canonicalBlob.range(of: marker) == nil)
        #expect(hydrationBlob.range(of: marker) == nil)

        let reopened = try SQLiteEventStore(
            fileURL: fixture.url,
            encryptionKey: encryptionKey
        )
        #expect(try await reopened.events(for: ScoutFixtures.sessionID) == expectedEvents)
        #expect(try await reopened.verifyChain(for: ScoutFixtures.sessionID).eventCount
            == expectedEvents.count)
        try await reopened.close()

        let wrongKeyStore = try SQLiteEventStore(
            fileURL: fixture.url,
            encryptionKey: wrongKey
        )
        do {
            _ = try await wrongKeyStore.verifyChain(for: ScoutFixtures.sessionID)
            Issue.record("Expected authenticated decryption with a wrong key to fail")
        } catch let error as SQLiteEventStoreError {
            guard case let .corruptEvent(eventID, reason) = error else {
                Issue.record("Expected corrupt-event error, got \(error)")
                return
            }
            #expect(eventID == expectedEvents.first?.id.rawValue)
            #expect(reason.contains("authentication failed"))
        }
    }

    @Test("Encryption keys must be exactly 256 bits")
    func invalidEncryptionKeyLength() throws {
        do {
            _ = try SQLiteEventStore(
                inMemoryWithBusyTimeoutMilliseconds: 5_000,
                encryptionKey: Data(repeating: 0, count: 31)
            )
            Issue.record("Expected a non-256-bit key to be rejected")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .invalidEncryptionKey)
        }
    }

    @Test("Expected sequence makes concurrent writers atomic")
    func concurrentExpectedVersion() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let storeA = try SQLiteEventStore(fileURL: fixture.url)
        let storeB = try SQLiteEventStore(fileURL: fixture.url)
        let first = try ScoutFixtures.sampleValidatedEvents()[0]
        let competing = reseal(first, id: try EventID(validating: "event-competing-start"))

        let outcomes = await withTaskGroup(
            of: ConcurrentAppendOutcome.self,
            returning: [ConcurrentAppendOutcome].self
        ) { group in
            group.addTask {
                do {
                    _ = try await storeA.append([first], expecting: .empty)
                    return .success
                } catch let error as SQLiteEventStoreError {
                    if case .versionConflict = error { return .versionConflict }
                    return .otherFailure
                } catch { return .otherFailure }
            }
            group.addTask {
                do {
                    _ = try await storeB.append([competing], expecting: .empty)
                    return .success
                } catch let error as SQLiteEventStoreError {
                    if case .versionConflict = error { return .versionConflict }
                    return .otherFailure
                } catch { return .otherFailure }
            }

            var results: [ConcurrentAppendOutcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }

        #expect(outcomes.filter { $0 == .success }.count == 1)
        #expect(outcomes.filter { $0 == .versionConflict }.count == 1)
        #expect(!outcomes.contains(.otherFailure))
        #expect(try await storeA.eventCount(for: ScoutFixtures.sessionID) == 1)
        #expect(try await storeA.verifyChain(for: ScoutFixtures.sessionID).eventCount == 1)
    }

    @Test("Idempotent retry returns original receipts and key reuse is rejected")
    func idempotency() async throws {
        let store = try SQLiteEventStore()
        let events = Array(try ScoutFixtures.sampleValidatedEvents().prefix(3))
        let key = try IdempotencyKey("meeting-command-42")

        let first = try await store.append(events, expecting: .empty, idempotencyKey: key)
        let retry = try await store.append(events, expecting: .empty, idempotencyKey: key)

        #expect(retry == first)
        #expect(try await store.eventCount(for: ScoutFixtures.sessionID) == events.count)

        do {
            _ = try await store.append(
                Array(events.prefix(2)),
                expecting: .empty,
                idempotencyKey: key
            )
            Issue.record("Expected idempotency-key conflict")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .idempotencyConflict(key))
        }
    }

    @Test("A reduction failure rolls an entire SQLite transaction back")
    func atomicRollback() async throws {
        let store = try SQLiteEventStore()
        let first = try ScoutFixtures.sampleValidatedEvents()[0]
        let firstEnvelope = first.envelope
        let invalidSecond = ScoutEventEnvelope.seal(
            id: try EventID(validating: "event-invalid-second"),
            sessionID: firstEnvelope.sessionID,
            sequence: firstEnvelope.sequence,
            occurredAt: firstEnvelope.occurredAt,
            recordedAt: firstEnvelope.recordedAt,
            actor: firstEnvelope.actor,
            authorization: firstEnvelope.authorization,
            payload: firstEnvelope.payload,
            previousHash: nil
        )

        do {
            _ = try await store.append(
                [first, ValidatedScoutEvent(envelope: invalidSecond)],
                expecting: .empty
            )
            Issue.record("Expected reduction failure")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .reduction(.unexpectedSequence(expected: 2, actual: 1)))
        }

        #expect(try await store.eventCount(for: firstEnvelope.sessionID) == 0)
        #expect(try await store.state(for: firstEnvelope.sessionID) == nil)
    }

    @Test("Same-connection reads and appends reuse one verified replay")
    func verifiedSnapshotFastPath() async throws {
        let store = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 1,
                maximumEventCount: 4,
                maximumEstimatedRetainedBytes: Int.max
            )
        )
        let fixtureEvents = try ScoutFixtures.sampleValidatedEvents()
        let prefix = Array(fixtureEvents.prefix(3))
        let prefixLast = try #require(prefix.last?.envelope)

        _ = try await store.append(prefix, expecting: .empty)
        let afterInitialAppend = await store.cacheStatistics()
        #expect(afterInitialAppend.fullStreamReplays == 1)
        #expect(afterInitialAppend.transactionalHeadChecks == 1)
        #expect(afterInitialAppend.cachedStreamCount == 1)
        #expect(afterInitialAppend.cachedEventCount == 3)
        #expect(afterInitialAppend.cachedEstimatedRetainedBytes > 0)

        // These 40 hot reads used to perform 40 complete decode/reducer
        // replays. They now resolve from the verified snapshot.
        for _ in 0 ..< 20 {
            #expect(try await store.state(for: ScoutFixtures.sessionID)?.lastSequence
                == prefixLast.sequence)
            #expect(try await store.events(for: ScoutFixtures.sessionID).count == prefix.count)
        }

        let next = fixtureEvents[3]
        _ = try await store.append([next], expecting: .sequence(prefixLast.sequence))
        let afterHotPath = await store.cacheStatistics()
        #expect(afterHotPath.fullStreamReplays == 1)
        #expect(afterHotPath.cacheHits == 41)
        #expect(afterHotPath.transactionalHeadChecks == 2)
        #expect(afterHotPath.cachedStreamCount == 1)
        #expect(afterHotPath.cachedEventCount == 4)
        #expect(afterHotPath.budgetEvictions == 0)
        #expect(afterHotPath.oversizedSnapshotRejections == 0)

        // Explicit audit verification must bypass the cache, and its verified
        // result should refresh the following read.
        #expect(try await store.verifyChain(for: ScoutFixtures.sessionID).eventCount == 4)
        _ = try await store.state(for: ScoutFixtures.sessionID)
        let afterVerification = await store.cacheStatistics()
        #expect(afterVerification.fullStreamReplays == 2)
        #expect(afterVerification.forcedVerifications == 1)
        #expect(afterVerification.cacheHits == 42)
        #expect(afterVerification.cachedStreamCount == 1)
        #expect(afterVerification.cachedEventCount == 4)
    }

    @Test("Replacing a cached snapshot releases its prior aggregate charge")
    func verifiedSnapshotReplacementAccounting() async throws {
        let store = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 1,
                maximumEventCount: 2,
                maximumEstimatedRetainedBytes: Int.max
            )
        )
        let events = Array(try ScoutFixtures.sampleValidatedEvents().prefix(2))
        let key = try IdempotencyKey("cache-replacement-accounting")

        let firstReceipts = try await store.append(
            events,
            expecting: .empty,
            idempotencyKey: key
        )
        let beforeReplacement = await store.cacheStatistics()

        let retryReceipts = try await store.append(
            events,
            expecting: .empty,
            idempotencyKey: key
        )
        let afterReplacement = await store.cacheStatistics()

        #expect(retryReceipts == firstReceipts)
        #expect(afterReplacement.cachedStreamCount == beforeReplacement.cachedStreamCount)
        #expect(afterReplacement.cachedEventCount == beforeReplacement.cachedEventCount)
        #expect(afterReplacement.cachedEstimatedRetainedBytes
            == beforeReplacement.cachedEstimatedRetainedBytes)
        #expect(afterReplacement.cachedStreamCount == 1)
        #expect(afterReplacement.cachedEventCount == 2)
        #expect(afterReplacement.budgetEvictions == 0)
        #expect(afterReplacement.oversizedSnapshotRejections == 0)
    }

    @Test("Aggregate budgets evict least recently used streams until all fit")
    func verifiedSnapshotAggregateBudgetEviction() async throws {
        let probe = try cacheTwoEventFixture(suffix: "p")
        let probeStore = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 1,
                maximumEventCount: 2,
                maximumEstimatedRetainedBytes: Int.max
            )
        )
        _ = try await probeStore.append(probe.events, expecting: .empty)
        let twoEventStreamByteCost = await probeStore.cacheStatistics()
            .cachedEstimatedRetainedBytes
        #expect(twoEventStreamByteCost > 0)

        let singleProbe = try cacheStartFixture(suffix: "q")
        let singleProbeStore = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 1,
                maximumEventCount: 1,
                maximumEstimatedRetainedBytes: Int.max
            )
        )
        _ = try await singleProbeStore.append([singleProbe.event], expecting: .empty)
        let oneEventStreamByteCost = await singleProbeStore.cacheStatistics()
            .cachedEstimatedRetainedBytes
        let aggregateByteBudget = max(
            twoEventStreamByteCost,
            oneEventStreamByteCost * 2
        )

        let first = try cacheStartFixture(suffix: "a")
        let second = try cacheStartFixture(suffix: "b")
        let third = try cacheTwoEventFixture(suffix: "c")
        let store = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 2,
                maximumEventCount: 2,
                maximumEstimatedRetainedBytes: aggregateByteBudget
            )
        )

        _ = try await store.append([first.event], expecting: .empty)
        _ = try await store.append([second.event], expecting: .empty)
        _ = try await store.state(for: first.sessionID)
        _ = try await store.append(third.events, expecting: .empty)

        let statistics = await store.cacheStatistics()
        #expect(statistics.budgetEvictions == 2)
        #expect(statistics.oversizedSnapshotRejections == 0)
        #expect(statistics.cachedStreamCount == 1)
        #expect(statistics.cachedEventCount == 2)
        #expect(statistics.cachedEstimatedRetainedBytes == twoEventStreamByteCost)
        #expect(await store.cachedSessionIDsInLRUOrder()
            == [third.sessionID])
    }

    @Test("A snapshot larger than one budget is verified but never cached")
    func oversizedVerifiedSnapshotIsRejected() async throws {
        let probe = try cacheStartFixture(suffix: "p")
        let probeStore = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 1,
                maximumEventCount: 1,
                maximumEstimatedRetainedBytes: Int.max
            )
        )
        _ = try await probeStore.append([probe.event], expecting: .empty)
        let oneStreamByteCost = await probeStore.cacheStatistics()
            .cachedEstimatedRetainedBytes

        let oversized = try cacheStartFixture(suffix: "z")
        let store = try SQLiteEventStore(
            inMemoryWithBusyTimeoutMilliseconds: 5_000,
            cacheBudgets: SQLiteEventStoreCacheBudgets(
                maximumStreamCount: 4,
                maximumEventCount: 4,
                maximumEstimatedRetainedBytes: oneStreamByteCost - 1
            )
        )
        _ = try await store.append([oversized.event], expecting: .empty)

        #expect(try await store.state(for: oversized.sessionID)?.lastSequence
            == oversized.event.envelope.sequence)
        #expect(try await store.state(for: oversized.sessionID)?.lastSequence
            == oversized.event.envelope.sequence)
        let statistics = await store.cacheStatistics()

        #expect(try await store.eventCount(for: oversized.sessionID) == 1)
        #expect(statistics.fullStreamReplays == 3)
        #expect(statistics.cacheHits == 0)
        #expect(statistics.oversizedSnapshotRejections == 3)
        #expect(statistics.budgetEvictions == 0)
        #expect(statistics.cachedStreamCount == 0)
        #expect(statistics.cachedEventCount == 0)
        #expect(statistics.cachedEstimatedRetainedBytes == 0)
        #expect(await store.cachedSessionIDsInLRUOrder().isEmpty)
    }

    @Test("Another SQLite connection invalidates a verified snapshot")
    func externalConnectionInvalidatesSnapshot() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let storeA = try SQLiteEventStore(fileURL: fixture.url)
        let storeB = try SQLiteEventStore(fileURL: fixture.url)
        let events = try ScoutFixtures.sampleValidatedEvents()
        let prefix = Array(events.prefix(2))
        let prefixLast = try #require(prefix.last?.envelope)

        _ = try await storeA.append(prefix, expecting: .empty)
        _ = try await storeA.state(for: ScoutFixtures.sessionID)
        let beforeExternalCommit = await storeA.cacheStatistics()

        _ = try await storeB.append(
            [events[2]],
            expecting: .sequence(prefixLast.sequence)
        )
        let refreshed = try #require(try await storeA.state(for: ScoutFixtures.sessionID))
        let afterExternalCommit = await storeA.cacheStatistics()

        #expect(refreshed.lastSequence == events[2].envelope.sequence)
        #expect(afterExternalCommit.externalInvalidations
            == beforeExternalCommit.externalInvalidations + 1)
        #expect(afterExternalCommit.fullStreamReplays
            == beforeExternalCommit.fullStreamReplays + 1)
    }

    @Test("A rolled-back candidate never poisons the verified snapshot")
    func rollbackDoesNotPublishCandidateSnapshot() async throws {
        let store = try SQLiteEventStore()
        let events = try ScoutFixtures.sampleValidatedEvents()
        let prefix = Array(events.prefix(3))
        let prefixLast = try #require(prefix.last?.envelope)
        _ = try await store.append(prefix, expecting: .empty)
        let beforeFailure = await store.cacheStatistics()

        let invalid = replacingPreviousHash(
            events[3],
            id: try EventID(validating: "event-cache-rollback-invalid"),
            previousHash: nil
        )
        do {
            _ = try await store.append(
                [invalid],
                expecting: .sequence(prefixLast.sequence)
            )
            Issue.record("Expected the invalid candidate to roll back")
        } catch let error as SQLiteEventStoreError {
            guard case .reduction = error else {
                Issue.record("Expected reducer rejection, got \(error)")
                return
            }
        }

        #expect(try await store.eventCount(for: ScoutFixtures.sessionID) == prefix.count)
        #expect(try await store.state(for: ScoutFixtures.sessionID)?.lastSequence
            == prefixLast.sequence)
        _ = try await store.append(
            [events[3]],
            expecting: .sequence(prefixLast.sequence)
        )
        let afterRecovery = await store.cacheStatistics()
        #expect(afterRecovery.fullStreamReplays == beforeFailure.fullStreamReplays)
        #expect(try await store.eventCount(for: ScoutFixtures.sessionID) == prefix.count + 1)
    }

    @Test("Concurrent cached writers recheck the canonical head in-transaction")
    func cachedConcurrentHeadConflict() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let storeA = try SQLiteEventStore(fileURL: fixture.url)
        let storeB = try SQLiteEventStore(fileURL: fixture.url)
        let events = try ScoutFixtures.sampleValidatedEvents()
        let prefix = Array(events.prefix(2))
        let prefixLast = try #require(prefix.last?.envelope)
        let competing = reseal(
            events[2],
            id: try EventID(validating: "event-cached-competing-third")
        )

        _ = try await storeA.append(prefix, expecting: .empty)
        // Both writers now hold a verified snapshot at the same canonical
        // head before racing for BEGIN IMMEDIATE.
        _ = try await storeB.state(for: ScoutFixtures.sessionID)

        let outcomes = await withTaskGroup(
            of: ConcurrentAppendOutcome.self,
            returning: [ConcurrentAppendOutcome].self
        ) { group in
            group.addTask {
                await appendOutcome(
                    store: storeA,
                    event: events[2],
                    expected: prefixLast.sequence
                )
            }
            group.addTask {
                await appendOutcome(
                    store: storeB,
                    event: competing,
                    expected: prefixLast.sequence
                )
            }

            var results: [ConcurrentAppendOutcome] = []
            for await result in group { results.append(result) }
            return results
        }

        #expect(outcomes.filter { $0 == .success }.count == 1)
        #expect(outcomes.filter { $0 == .versionConflict }.count == 1)
        #expect(!outcomes.contains(.otherFailure))
        #expect(try await storeA.verifyChain(for: ScoutFixtures.sessionID).eventCount == 3)
        let storeAInvalidations = await storeA.cacheStatistics().externalInvalidations
        let storeBInvalidations = await storeB.cacheStatistics().externalInvalidations
        let aggregateInvalidations = storeAInvalidations + storeBInvalidations
        #expect(aggregateInvalidations >= 1)
    }

    @Test("A manifested model projection is indivisible and survives reopen")
    func manifestedProjectionIsAtomic() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let prefix = Array(try ScoutFixtures.sampleValidatedEvents().prefix(8))
        let baseState = try ScoutGraphReducer.replay(prefix.map(\.envelope))
        let last = try #require(prefix.last?.envelope)
        let evidenceEventID = try #require(baseState.evidenceEvents[ScoutFixtures.evidenceID])
        let inputBoundary = try #require(baseState.eventBoundaries[evidenceEventID])
        let projectionBase = ModelInputEventBoundary(last)
        let receiptID = try ModelCallReceiptID(validating: "model-call-sqlite-manifest")
        let proposalID = try EventID(validating: "event-sqlite-manifest-proposal")
        let outputHash = SHA256Digest.hash(Data("sqlite-manifest-output".utf8))
        let trust = TrustAssessment(
            origin: .suggested,
            confidence: try Confidence(basisPoints: 8_000),
            validationStatus: .needsValidation
        )
        let claim = Claim(
            id: try ClaimID(validating: "claim-sqlite-manifest"),
            subject: .entity(ScoutFixtures.customerDataEntityID),
            predicate: .hasGoal,
            object: .value(.text("Commit the exact SQLite projection")),
            assertedBy: ScoutFixtures.speakerID,
            evidenceIDs: [ScoutFixtures.evidenceID],
            trust: trust
        )
        let manifest = try DerivedEventManifest.committing(
            adapterID: NonEmptyString(validating: "sqlite-persistence-test"),
            adapterVersion: NonEmptyString(validating: "v1"),
            projectionBase: projectionBase,
            receiptID: receiptID,
            outputHash: outputHash,
            entries: [.init(eventID: proposalID, payload: .claimProposed(claim))]
        )
        let receipt = try ModelCallReceipt(
            id: receiptID,
            provider: NonEmptyString(validating: "openai"),
            providerResponseID: NonEmptyString(validating: "resp_sqlite_manifest"),
            purpose: .claimExtraction,
            inputBoundary: inputBoundary,
            promptVersion: NonEmptyString(validating: "claim-extraction.v1"),
            outputSchemaVersion: NonEmptyString(validating: "claim-proposals.v1"),
            model: NonEmptyString(validating: "gpt-fixture"),
            outputHash: outputHash,
            derivedEventManifest: manifest
        )
        let identity = ModelIdentity(
            provider: try NonEmptyString(validating: "openai"),
            model: try NonEmptyString(validating: "gpt-fixture"),
            operationVersion: try NonEmptyString(validating: "claim-extraction.v1")
        )
        let validator = try NonEmptyString(validating: "sqlite-persistence-test")
        var chain = EventChainBuilder(
            sessionID: baseState.sessionID,
            nextSequence: try last.sequence.successor(),
            previousHash: last.integrityHash
        )
        let receiptEvent = try chain.seal(
            id: try EventID(validating: "event-sqlite-manifest-receipt"),
            occurredAt: last.recordedAt,
            recordedAt: last.recordedAt,
            causationID: inputBoundary.eventID,
            command: .modelProjection(
                validator: validator,
                model: identity,
                operation: .recordCall(receipt)
            )
        )
        let proposalEvent = try chain.seal(
            id: proposalID,
            occurredAt: last.recordedAt,
            recordedAt: last.recordedAt,
            correlationID: receiptEvent.envelope.id,
            causationID: receiptEvent.envelope.id,
            command: .modelProjection(
                validator: validator,
                model: identity,
                operation: .proposeClaim(claim)
            )
        )

        let store = try SQLiteEventStore(fileURL: fixture.url)
        _ = try await store.append(prefix, expecting: .empty)
        do {
            _ = try await store.append(
                [receiptEvent],
                expecting: .sequence(last.sequence)
            )
            Issue.record("Expected an incomplete manifested projection to roll back")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .reduction(.incompleteDerivedEventManifest(
                receiptID: receiptID,
                expectedCount: 1,
                actualCount: 0
            )))
        }
        #expect(try await store.eventCount(for: baseState.sessionID) == prefix.count)

        _ = try await store.append(
            [receiptEvent, proposalEvent],
            expecting: .sequence(last.sequence)
        )
        try await store.close()

        let reopened = try SQLiteEventStore(fileURL: fixture.url)
        let replayed = try #require(try await reopened.state(for: baseState.sessionID))
        #expect(replayed.claims[claim.id] == claim)
        #expect(replayed.pendingDerivedEventProjections.isEmpty)
        #expect(replayed.completedDerivedEventProjections[receiptEvent.envelope.id]?.isComplete == true)
    }

    @Test("Event identifiers are unique across all session streams")
    func globalEventIdentity() async throws {
        let store = try SQLiteEventStore()
        let original = try ScoutFixtures.sampleValidatedEvents()[0]
        _ = try await store.append(original)
        let originalEnvelope = original.envelope

        let secondSessionID = try SessionID(validating: "session-second")
        guard case let .sessionStarted(originalSession) = originalEnvelope.payload else {
            Issue.record("Fixture must start a session")
            return
        }
        let secondSession = DiscoverySession(
            id: secondSessionID,
            title: originalSession.title,
            startedAt: originalSession.startedAt
        )
        let duplicateID = ScoutEventEnvelope.seal(
            id: originalEnvelope.id,
            sessionID: secondSessionID,
            sequence: try EventSequence(1),
            occurredAt: originalEnvelope.occurredAt,
            recordedAt: originalEnvelope.recordedAt,
            actor: originalEnvelope.actor,
            authorization: originalEnvelope.authorization,
            payload: .sessionStarted(secondSession),
            previousHash: nil
        )

        do {
            _ = try await store.append(ValidatedScoutEvent(envelope: duplicateID))
            Issue.record("Expected globally duplicate event ID to fail")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .duplicateEventID(originalEnvelope.id))
        }
        #expect(try await store.eventCount(for: secondSessionID) == 0)
    }

    @Test("Database triggers reject event update and delete")
    func appendOnlyTriggers() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let store = try SQLiteEventStore(fileURL: fixture.url)
        _ = try await store.append(try ScoutFixtures.sampleValidatedEvents()[0])

        let update = try rawExecute(
            fixture.url,
            sql: "UPDATE scout_events SET event_kind = 'tampered'"
        )
        #expect(update.code & 0xFF == SQLITE_CONSTRAINT)
        #expect(update.message.contains("append-only"))

        let delete = try rawExecute(fixture.url, sql: "DELETE FROM scout_events")
        #expect(delete.code & 0xFF == SQLITE_CONSTRAINT)
        #expect(delete.message.contains("append-only"))
        #expect(try await store.eventCount(for: ScoutFixtures.sessionID) == 1)
    }

    @Test("Canonical envelope corruption is detected before replay")
    func corruptionDetection() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let store = try SQLiteEventStore(fileURL: fixture.url)
        _ = try await store.append(Array(try ScoutFixtures.sampleValidatedEvents().prefix(2)))
        try await store.close()

        _ = try rawExecute(
            fixture.url,
            sql: "DROP TRIGGER scout_events_reject_update"
        )
        let tamper = try rawExecute(
            fixture.url,
            sql: "UPDATE scout_events SET envelope = x'7b7d' WHERE sequence = 2"
        )
        #expect(tamper.code == SQLITE_OK)

        let reopened = try SQLiteEventStore(fileURL: fixture.url)
        do {
            _ = try await reopened.verifyChain(for: ScoutFixtures.sessionID)
            Issue.record("Expected corrupt canonical blob to fail verification")
        } catch let error as SQLiteEventStoreError {
            guard case let .corruptEvent(eventID, reason) = error else {
                Issue.record("Expected corruption error, got \(error)")
                return
            }
            #expect(eventID != nil)
            #expect(reason.contains("not canonical"))
        }

        let triggerWasRestored = try rawExecute(
            fixture.url,
            sql: "UPDATE scout_events SET event_kind = 'still-tampered' WHERE sequence = 2"
        )
        #expect(triggerWasRestored.code & 0xFF == SQLITE_CONSTRAINT)
        #expect(triggerWasRestored.message.contains("append-only"))
    }

    @Test("Replay stream yields a verified sequence after a cursor")
    func replayStream() async throws {
        let store = try SQLiteEventStore()
        let validatedEvents = try ScoutFixtures.sampleValidatedEvents()
        let events = validatedEvents.map(\.envelope)
        _ = try await store.append(validatedEvents)

        let cursor = try EventSequence(4)
        let stream = try await store.replayStream(
            for: ScoutFixtures.sessionID,
            after: cursor
        )
        var replayed: [ScoutEventEnvelope] = []
        for try await event in stream { replayed.append(event) }
        #expect(replayed == Array(events.dropFirst(4)))
    }

    @Test("Canonical bytes and migration record are persisted")
    func canonicalStorageAndMigration() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let store = try SQLiteEventStore(fileURL: fixture.url)
        let validatedEvent = try ScoutFixtures.sampleValidatedEvents()[0]
        let event = validatedEvent.envelope
        _ = try await store.append(validatedEvent)

        let persisted = try rawBlob(
            fixture.url,
            sql: "SELECT envelope FROM scout_events WHERE sequence = 1"
        )
        #expect(persisted == CanonicalJSON.encode(event.canonicalValue))

        let migration = try rawInteger(
            fixture.url,
            sql: "SELECT MAX(version) FROM scout_schema_migrations"
        )
        #expect(migration == 1)
    }

    @Test("Only an authenticated local-review capability can persist an accepted claim")
    func authorizedClaimReviewPersists() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let base = try ScoutFixtures.sampleValidatedEvents()
        let store = try SQLiteEventStore(fileURL: fixture.url)
        _ = try await store.append(base, expecting: .empty)
        let last = try #require(base.last?.envelope)
        let currentState = try #require(try await store.state(for: ScoutFixtures.sessionID))
        var chain = EventChainBuilder(
            sessionID: last.sessionID,
            nextSequence: try last.sequence.successor(),
            previousHash: last.integrityHash
        )
        let trust = TrustAssessment(
            origin: .confirmed,
            confidence: try Confidence(basisPoints: 10_000),
            validationStatus: .validated
        )
        let eventID = try EventID(validating: "event-persistence-local-review")
        let claim = try #require(currentState.claims[ScoutFixtures.claimID])
        let targetEventID = try #require(currentState.claimEvents[ScoutFixtures.claimID])
        let now = ScoutTimestamp(millisecondsSinceUnixEpoch: Int64(
            (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        ))
        let authorization = AuthenticatedLocalReview(
            intent: LocalReviewIntent(
                sessionID: currentState.sessionID,
                eventID: eventID,
                operation: .reviewClaim(.init(
                    claimID: ScoutFixtures.claimID,
                    status: .accepted,
                    trust: trust
                )),
                targetEventID: targetEventID,
                targetStateHash: .hash(claim.canonicalValue)
            ),
            authenticatedAt: now
        )
        let review = try chain.seal(
            occurredAt: now,
            recordedAt: now,
            authenticatedReview: authorization
        )
        _ = try await store.append(
            [review],
            expecting: .sequence(last.sequence),
            idempotencyKey: try IdempotencyKey("authorized-local-review")
        )
        try await store.close()

        let reopened = try SQLiteEventStore(fileURL: fixture.url)
        let state = try #require(try await reopened.state(for: ScoutFixtures.sessionID))
        #expect(state.claims[ScoutFixtures.claimID]?.status == .accepted)
        #expect(state.claims[ScoutFixtures.claimID]?.trust == trust)
        #expect(state.claimReviewAttestations[ScoutFixtures.claimID]
            == .deviceOwnerAuthenticated(authorization.authorization))
        let stored = try #require(
            try await reopened.events(for: ScoutFixtures.sessionID).last
        )
        #expect(stored.actor == .system(
            component: try NonEmptyString(validating: "scout-macos-review-ui")
        ))
        #expect(stored.authorization?.scope == .localReview)
    }

    @Test("A model-context system-actor spoof is rejected without a write")
    func modelCannotSpoofSystemActor() async throws {
        let store = try SQLiteEventStore()
        let base = try ScoutFixtures.sampleValidatedEvents()
        _ = try await store.append(base, expecting: .empty)
        let before = try #require(try await store.state(for: ScoutFixtures.sessionID))
        let last = try #require(base.last?.envelope)
        let proposal = Claim(
            id: try ClaimID(validating: "claim-persistence-forged-actor"),
            subject: .entity(ScoutFixtures.customerDataEntityID),
            predicate: .hasGoal,
            object: .value(.text("Forged actor proposal")),
            assertedBy: ScoutFixtures.speakerID,
            evidenceIDs: [ScoutFixtures.evidenceID],
            trust: TrustAssessment(
                origin: .suggested,
                confidence: try Confidence(basisPoints: 8_000),
                validationStatus: .needsValidation
            )
        )
        let forged = ScoutEventEnvelope.seal(
            id: try EventID(validating: "event-persistence-forged-review"),
            sessionID: last.sessionID,
            sequence: try last.sequence.successor(),
            occurredAt: last.recordedAt,
            recordedAt: last.recordedAt,
            actor: .system(component: try NonEmptyString(validating: "scout-macos-review-ui")),
            authorization: .init(
                scope: .modelProjection,
                component: try NonEmptyString(validating: "claim-projection-validator")
            ),
            correlationID: last.id,
            causationID: last.id,
            payload: .claimProposed(proposal),
            previousHash: last.integrityHash
        )

        do {
            _ = try await store.append(
                [ValidatedScoutEvent(envelope: forged)],
                expecting: .sequence(last.sequence)
            )
            Issue.record("Expected model-context actor spoof to be rejected")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .reduction(.authorization(.actorMismatch(forged.id))))
        }

        let after = try #require(try await store.state(for: ScoutFixtures.sessionID))
        #expect(after.digest == before.digest)
        #expect(after.claims[ScoutFixtures.claimID]?.status == .proposed)
        #expect(try await store.eventCount(for: ScoutFixtures.sessionID) == base.count)
    }
}

private extension SQLiteEventStore {
    init() throws {
        try self.init(inMemoryWithBusyTimeoutMilliseconds: 5_000)
    }
}

private struct CacheStartFixture {
    let sessionID: SessionID
    let event: ValidatedScoutEvent
}

private struct CacheTwoEventFixture {
    let sessionID: SessionID
    let events: [ValidatedScoutEvent]
}

private func cacheStartFixture(suffix: String) throws -> CacheStartFixture {
    let sessionID = try SessionID(validating: "session-cache-\(suffix)")
    let occurredAt = ScoutFixtures.baseTimestamp
    let recordedAt = ScoutTimestamp(
        millisecondsSinceUnixEpoch: occurredAt.millisecondsSinceUnixEpoch + 1
    )
    var chain = EventChainBuilder(sessionID: sessionID)
    let event = try chain.seal(
        id: try EventID(validating: "event-cache-\(suffix)"),
        occurredAt: occurredAt,
        recordedAt: recordedAt,
        command: .sessionLifecycle(
            component: try NonEmptyString(validating: "cache-budget-tests"),
            operation: .start(DiscoverySession(
                id: sessionID,
                title: try NonEmptyString(validating: "Cache budget fixture"),
                startedAt: occurredAt
            ))
        )
    )
    return CacheStartFixture(sessionID: sessionID, event: event)
}

private func cacheTwoEventFixture(suffix: String) throws -> CacheTwoEventFixture {
    let sessionID = try SessionID(validating: "session-cache-\(suffix)")
    let occurredAt = ScoutFixtures.baseTimestamp
    let recordedAt = ScoutTimestamp(
        millisecondsSinceUnixEpoch: occurredAt.millisecondsSinceUnixEpoch + 1
    )
    let component = try NonEmptyString(validating: "cache-budget-tests")
    var chain = EventChainBuilder(sessionID: sessionID)
    let start = try chain.seal(
        id: try EventID(validating: "event-cache-\(suffix)"),
        occurredAt: occurredAt,
        recordedAt: recordedAt,
        command: .sessionLifecycle(
            component: component,
            operation: .start(DiscoverySession(
                id: sessionID,
                title: try NonEmptyString(validating: "Cache budget fixture"),
                startedAt: occurredAt
            ))
        )
    )
    let speaker = try chain.seal(
        id: try EventID(validating: "event-cache-\(suffix)-speaker"),
        occurredAt: recordedAt,
        recordedAt: ScoutTimestamp(
            millisecondsSinceUnixEpoch: recordedAt.millisecondsSinceUnixEpoch + 1
        ),
        command: .sessionLifecycle(
            component: component,
            operation: .upsertSpeaker(Speaker(
                id: try SpeakerID(validating: "speaker-cache-\(suffix)"),
                displayName: try NonEmptyString(validating: "Cache Speaker"),
                affiliation: .customer
            ))
        )
    )
    return CacheTwoEventFixture(sessionID: sessionID, events: [start, speaker])
}

private struct TemporaryDatabase {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-persistence-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("events.sqlite")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func reseal(_ event: ValidatedScoutEvent, id: EventID) -> ValidatedScoutEvent {
    let envelope = event.envelope
    return ValidatedScoutEvent(envelope: ScoutEventEnvelope.seal(
        schemaVersion: envelope.schemaVersion,
        id: id,
        sessionID: envelope.sessionID,
        sequence: envelope.sequence,
        occurredAt: envelope.occurredAt,
        recordedAt: envelope.recordedAt,
        actor: envelope.actor,
        authorization: envelope.authorization,
        correlationID: envelope.correlationID,
        causationID: envelope.causationID,
        payload: envelope.payload,
        previousHash: envelope.previousHash
    ))
}

private func replacingPreviousHash(
    _ event: ValidatedScoutEvent,
    id: EventID,
    previousHash: SHA256Digest?
) -> ValidatedScoutEvent {
    let envelope = event.envelope
    return ValidatedScoutEvent(envelope: ScoutEventEnvelope.seal(
        schemaVersion: envelope.schemaVersion,
        id: id,
        sessionID: envelope.sessionID,
        sequence: envelope.sequence,
        occurredAt: envelope.occurredAt,
        recordedAt: envelope.recordedAt,
        actor: envelope.actor,
        authorization: envelope.authorization,
        correlationID: envelope.correlationID,
        causationID: envelope.causationID,
        payload: envelope.payload,
        previousHash: previousHash
    ))
}

private func appendOutcome(
    store: SQLiteEventStore,
    event: ValidatedScoutEvent,
    expected: EventSequence
) async -> ConcurrentAppendOutcome {
    do {
        _ = try await store.append([event], expecting: .sequence(expected))
        return .success
    } catch let error as SQLiteEventStoreError {
        if case .versionConflict = error { return .versionConflict }
        return .otherFailure
    } catch {
        return .otherFailure
    }
}

private struct RawSQLiteResult {
    let code: Int32
    let message: String
}

private func rawExecute(_ url: URL, sql: String) throws -> RawSQLiteResult {
    try withRawDatabase(url) { database in
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        let message: String
        if let errorMessage {
            message = String(cString: errorMessage)
            sqlite3_free(errorMessage)
        } else {
            message = String(cString: sqlite3_errmsg(database))
        }
        return RawSQLiteResult(code: code, message: message)
    }
}

private func rawBlob(_ url: URL, sql: String) throws -> Data? {
    try withRawDatabase(url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw RawSQLiteTestError.failure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

private func rawInteger(_ url: URL, sql: String) throws -> Int64? {
    try withRawDatabase(url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw RawSQLiteTestError.failure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else { return nil }
        return sqlite3_column_int64(statement, 0)
    }
}

private func withRawDatabase<T>(
    _ url: URL,
    body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard result == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw RawSQLiteTestError.failure
    }
    defer { sqlite3_close_v2(database) }
    _ = sqlite3_busy_timeout(database, 5_000)
    return try body(database)
}

private enum RawSQLiteTestError: Error {
    case failure
}

private enum ConcurrentAppendOutcome: Equatable, Sendable {
    case success
    case versionConflict
    case otherFailure
}
