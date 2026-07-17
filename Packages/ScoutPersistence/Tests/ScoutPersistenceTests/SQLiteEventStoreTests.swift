import CSQLite
import Foundation
import ScoutCore
import Testing

@testable import ScoutPersistence

@Suite("SQLite event store")
struct SQLiteEventStoreTests {
    @Test("Canonical envelopes survive close and reopen")
    func reopenPersistence() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let expectedEvents = try ScoutFixtures.sampleEvents()
        let expectedState = try ScoutGraphReducer.replay(expectedEvents)

        let firstStore = try SQLiteEventStore(fileURL: fixture.url)
        let receipts = try await firstStore.append(
            expectedEvents,
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
        let expectedEvents = try ScoutFixtures.sampleEvents()

        let firstStore = try SQLiteEventStore(
            fileURL: fixture.url,
            encryptionKey: encryptionKey
        )
        _ = try await firstStore.append(expectedEvents, expecting: .empty)
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
        let first = try ScoutFixtures.sampleEvents()[0]
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
        let events = Array(try ScoutFixtures.sampleEvents().prefix(3))
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
        let first = try ScoutFixtures.sampleEvents()[0]
        let invalidSecond = ScoutEventEnvelope.seal(
            id: try EventID(validating: "event-invalid-second"),
            sessionID: first.sessionID,
            sequence: first.sequence,
            occurredAt: first.occurredAt,
            recordedAt: first.recordedAt,
            actor: first.actor,
            payload: first.payload,
            previousHash: nil
        )

        do {
            _ = try await store.append([first, invalidSecond], expecting: .empty)
            Issue.record("Expected reduction failure")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .reduction(.unexpectedSequence(expected: 2, actual: 1)))
        }

        #expect(try await store.eventCount(for: first.sessionID) == 0)
        #expect(try await store.state(for: first.sessionID) == nil)
    }

    @Test("Event identifiers are unique across all session streams")
    func globalEventIdentity() async throws {
        let store = try SQLiteEventStore()
        let original = try ScoutFixtures.sampleEvents()[0]
        _ = try await store.append(original)

        let secondSessionID = try SessionID(validating: "session-second")
        guard case let .sessionStarted(originalSession) = original.payload else {
            Issue.record("Fixture must start a session")
            return
        }
        let secondSession = DiscoverySession(
            id: secondSessionID,
            title: originalSession.title,
            startedAt: originalSession.startedAt
        )
        let duplicateID = ScoutEventEnvelope.seal(
            id: original.id,
            sessionID: secondSessionID,
            sequence: try EventSequence(1),
            occurredAt: original.occurredAt,
            recordedAt: original.recordedAt,
            actor: original.actor,
            payload: .sessionStarted(secondSession),
            previousHash: nil
        )

        do {
            _ = try await store.append(duplicateID)
            Issue.record("Expected globally duplicate event ID to fail")
        } catch let error as SQLiteEventStoreError {
            #expect(error == .duplicateEventID(original.id))
        }
        #expect(try await store.eventCount(for: secondSessionID) == 0)
    }

    @Test("Database triggers reject event update and delete")
    func appendOnlyTriggers() async throws {
        let fixture = try TemporaryDatabase()
        defer { fixture.remove() }
        let store = try SQLiteEventStore(fileURL: fixture.url)
        _ = try await store.append(try ScoutFixtures.sampleEvents()[0])

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
        _ = try await store.append(Array(try ScoutFixtures.sampleEvents().prefix(2)))
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
        let events = try ScoutFixtures.sampleEvents()
        _ = try await store.append(events)

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
        let event = try ScoutFixtures.sampleEvents()[0]
        _ = try await store.append(event)

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
}

private extension SQLiteEventStore {
    init() throws {
        try self.init(inMemoryWithBusyTimeoutMilliseconds: 5_000)
    }
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

private func reseal(_ event: ScoutEventEnvelope, id: EventID) -> ScoutEventEnvelope {
    ScoutEventEnvelope.seal(
        schemaVersion: event.schemaVersion,
        id: id,
        sessionID: event.sessionID,
        sequence: event.sequence,
        occurredAt: event.occurredAt,
        recordedAt: event.recordedAt,
        actor: event.actor,
        correlationID: event.correlationID,
        causationID: event.causationID,
        payload: event.payload,
        previousHash: event.previousHash
    )
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
