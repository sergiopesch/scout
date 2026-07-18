import CSQLite
import CryptoKit
import Foundation
import ScoutCore

/// Internal counters used by persistence tests and performance diagnostics.
/// They deliberately describe verification work rather than elapsed time so
/// assertions remain deterministic on every machine.
struct SQLiteEventStoreCacheStatistics: Equatable, Sendable {
    fileprivate(set) var fullStreamReplays = 0
    fileprivate(set) var cacheHits = 0
    fileprivate(set) var transactionalHeadChecks = 0
    fileprivate(set) var externalInvalidations = 0
    fileprivate(set) var forcedVerifications = 0
    fileprivate(set) var budgetEvictions = 0
    fileprivate(set) var oversizedSnapshotRejections = 0
    fileprivate(set) var cachedStreamCount = 0
    fileprivate(set) var cachedEventCount = 0
    fileprivate(set) var cachedEstimatedRetainedBytes = 0
}

/// Deterministic aggregate bounds for verified stream snapshots. Internal
/// visibility keeps production policy out of the public API while allowing
/// focused tests to exercise each limit with tiny budgets.
struct SQLiteEventStoreCacheBudgets: Equatable, Sendable {
    static let standard = SQLiteEventStoreCacheBudgets(
        maximumStreamCount: 8,
        maximumEventCount: 8_192,
        maximumEstimatedRetainedBytes: 64 * 1_024 * 1_024
    )

    let maximumStreamCount: Int
    let maximumEventCount: Int
    let maximumEstimatedRetainedBytes: Int

    init(
        maximumStreamCount: Int,
        maximumEventCount: Int,
        maximumEstimatedRetainedBytes: Int
    ) {
        precondition(maximumStreamCount >= 0)
        precondition(maximumEventCount >= 0)
        precondition(maximumEstimatedRetainedBytes >= 0)
        self.maximumStreamCount = maximumStreamCount
        self.maximumEventCount = maximumEventCount
        self.maximumEstimatedRetainedBytes = maximumEstimatedRetainedBytes
    }
}

private struct VerifiedStreamSnapshot: Sendable {
    static let fixedEstimatedRetainedBytes = 512

    var events: [ScoutEventEnvelope]
    var state: ScoutState?
    var estimatedRetainedBytes: Int

    init(
        events: [ScoutEventEnvelope],
        state: ScoutState?,
        estimatedRetainedBytes: Int = fixedEstimatedRetainedBytes
    ) {
        self.events = events
        self.state = state
        self.estimatedRetainedBytes = estimatedRetainedBytes
    }

    var head: PersistedStreamHead {
        guard let last = events.last else { return .empty }
        return PersistedStreamHead(
            sequence: last.sequence,
            integrityHash: last.integrityHash
        )
    }
}

private struct DecodedPersistedEvent: Sendable {
    let envelope: ScoutEventEnvelope
    let estimatedRetainedBytes: Int
}

private struct PersistedStreamHead: Equatable, Sendable {
    let sequence: EventSequence?
    let integrityHash: ScoutCore.SHA256Digest?

    static let empty = PersistedStreamHead(sequence: nil, integrityHash: nil)
}

/// Durable, append-only SQLite event storage.
///
/// The actor is the in-process serialization boundary. `BEGIN IMMEDIATE` and
/// expected stream versions extend that safety to other processes and other
/// `SQLiteEventStore` instances using the same database file.
public actor SQLiteEventStore: ScoutPersistentEventStore {
    public static let defaultBusyTimeoutMilliseconds: Int32 = 5_000

    private let blobCipher: EventBlobCipher?
    private let cacheBudgets: SQLiteEventStoreCacheBudgets
    private var database: SQLiteDatabase?
    private var verifiedStreamCache: [SessionID: VerifiedStreamSnapshot] = [:]
    private var cacheAccessOrder: [SessionID] = []
    private var cachedEventCount = 0
    private var cachedEstimatedRetainedBytes = 0
    private var cacheDataVersion: Int64?
    private var cacheStatisticsValue = SQLiteEventStoreCacheStatistics()

    public init(
        fileURL: URL,
        busyTimeoutMilliseconds: Int32 = defaultBusyTimeoutMilliseconds,
        encryptionKey: Data? = nil
    ) throws {
        guard fileURL.isFileURL else { throw SQLiteEventStoreError.invalidFileURL }
        guard busyTimeoutMilliseconds >= 0 else {
            throw SQLiteEventStoreError.invalidBusyTimeout
        }
        blobCipher = try EventBlobCipher.make(keyData: encryptionKey)
        cacheBudgets = .standard

        let parent = fileURL.standardizedFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )

        let opened = try SQLiteDatabase(
            path: fileURL.standardizedFileURL.path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        do {
            try Self.configure(opened)
            try SQLiteMigrations.migrate(opened)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.standardizedFileURL.path
            )
            database = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    /// A process-local store useful when durability across launches is not
    /// needed. The same schema, constraints, reducer, and integrity checks run.
    public init(
        inMemoryWithBusyTimeoutMilliseconds busyTimeoutMilliseconds: Int32 =
            defaultBusyTimeoutMilliseconds,
        encryptionKey: Data? = nil
    ) throws {
        guard busyTimeoutMilliseconds >= 0 else {
            throw SQLiteEventStoreError.invalidBusyTimeout
        }
        blobCipher = try EventBlobCipher.make(keyData: encryptionKey)
        cacheBudgets = .standard
        let opened = try SQLiteDatabase(
            path: ":memory:",
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        do {
            try Self.configure(opened, requireWAL: false)
            try SQLiteMigrations.migrate(opened)
            database = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    /// Test-visible initializer for exercising deterministic cache budgets
    /// without widening the production API.
    init(
        inMemoryWithBusyTimeoutMilliseconds busyTimeoutMilliseconds: Int32,
        encryptionKey: Data? = nil,
        cacheBudgets: SQLiteEventStoreCacheBudgets
    ) throws {
        guard busyTimeoutMilliseconds >= 0 else {
            throw SQLiteEventStoreError.invalidBusyTimeout
        }
        blobCipher = try EventBlobCipher.make(keyData: encryptionKey)
        self.cacheBudgets = cacheBudgets
        let opened = try SQLiteDatabase(
            path: ":memory:",
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        do {
            try Self.configure(opened, requireWAL: false)
            try SQLiteMigrations.migrate(opened)
            database = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    @discardableResult
    public func append(_ event: ValidatedScoutEvent) throws -> AppendReceipt {
        try append([event])[0]
    }

    /// Compatibility surface matching ScoutCore's in-memory store. This form
    /// derives current versions inside one immediate transaction. Command
    /// handlers should prefer the explicit expected-version overload.
    @discardableResult
    public func append(_ events: [ValidatedScoutEvent]) throws -> [AppendReceipt] {
        try appendInternal(events, expectation: nil, idempotencyKey: nil)
    }

    /// Atomically validates and appends a single-session batch.
    ///
    /// An idempotent retry with exactly the same key and canonical request
    /// returns the original receipts even though the expected version is now
    /// stale. Reusing the key for different bytes is rejected.
    @discardableResult
    public func append(
        _ events: [ValidatedScoutEvent],
        expecting version: ExpectedStreamVersion,
        idempotencyKey: IdempotencyKey? = nil
    ) throws -> [AppendReceipt] {
        guard !events.isEmpty else { return [] }
        guard let sessionID = events.first?.envelope.sessionID,
              events.allSatisfy({ $0.envelope.sessionID == sessionID })
        else {
            throw SQLiteEventStoreError.mixedSessionBatch
        }
        return try appendInternal(
            events,
            expectation: (sessionID, version),
            idempotencyKey: idempotencyKey
        )
    }

    public func events(
        for sessionID: SessionID,
        after sequence: EventSequence? = nil
    ) throws -> [ScoutEventEnvelope] {
        let allEvents = try verifiedSnapshot(for: sessionID).events
        guard let sequence else { return allEvents }
        return allEvents.filter { $0.sequence > sequence }
    }

    public func state(for sessionID: SessionID) throws -> ScoutState? {
        try verifiedSnapshot(for: sessionID).state
    }

    public func eventCount(for sessionID: SessionID) throws -> Int {
        let database = try requiredDatabase()
        let statement = try database.prepare(
            "SELECT COUNT(*) FROM scout_events WHERE session_id = ?"
        )
        defer { database.finalize(statement) }
        try database.bind(sessionID.rawValue, to: 1, in: statement)
        guard try database.step(statement) == SQLITE_ROW else { return 0 }
        return Int(database.int64(at: 0, in: statement))
    }

    public func sessionIDs() throws -> [SessionID] {
        let database = try requiredDatabase()
        let statement = try database.prepare(
            "SELECT DISTINCT session_id FROM scout_events ORDER BY session_id"
        )
        defer { database.finalize(statement) }

        var result: [SessionID] = []
        while try database.step(statement) == SQLITE_ROW {
            guard let rawValue = database.text(at: 0, in: statement) else {
                throw corruption(nil, "session_id is NULL")
            }
            do {
                result.append(try SessionID(validating: rawValue))
            } catch {
                throw corruption(nil, "invalid persisted session identifier: \(rawValue)")
            }
        }
        return result
    }

    /// Verifies canonical bytes, duplicated metadata, envelope integrity, hash
    /// linkage, event sequence, and all reducer invariants for one stream.
    public func verifyChain(for sessionID: SessionID) throws -> ChainVerificationReport {
        let database = try requiredDatabase()
        cacheStatisticsValue.forcedVerifications += 1

        // An explicit verification never accepts a prior cache entry. Remove
        // it first so a failed verification cannot leave an older snapshot
        // available to later callers.
        removeCachedSnapshot(for: sessionID)
        let startingDataVersion = try synchronizeCacheDataVersion(using: database)
        let snapshot = try loadVerifiedStreamFromSQLite(for: sessionID, using: database)
        let endingDataVersion = try currentDataVersion(using: database)
        if endingDataVersion == startingDataVersion {
            cache(snapshot, for: sessionID)
        } else {
            invalidateCache(forDataVersion: endingDataVersion)
        }

        let events = snapshot.events
        let state = snapshot.state
        return ChainVerificationReport(
            sessionID: sessionID,
            eventCount: events.count,
            lastSequence: state?.lastSequence,
            lastHash: state?.lastEventHash,
            stateDigest: state?.digest
        )
    }

    /// Verifies every persisted stream in stable session order.
    public func verifyAllChains() throws -> [ChainVerificationReport] {
        try sessionIDs().map { try verifyChain(for: $0) }
    }

    /// Returns an integrity-checked snapshot as an async replay sequence. The
    /// SQLite cursor never escapes the actor, so consumers cannot hold a read
    /// transaction open indefinitely and prevent checkpoints.
    public func replayStream(
        for sessionID: SessionID,
        after sequence: EventSequence? = nil
    ) throws -> AsyncThrowingStream<ScoutEventEnvelope, Error> {
        let snapshot = try events(for: sessionID, after: sequence)
        return AsyncThrowingStream { continuation in
            for event in snapshot { continuation.yield(event) }
            continuation.finish()
        }
    }

    /// Checkpoints WAL content and closes the connection. Further operations
    /// fail with `storeClosed`.
    public func close() throws {
        guard let database else { return }
        clearVerifiedStreamCache()
        cacheDataVersion = nil
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try database.close()
        self.database = nil
    }

    /// Test-visible, deterministic evidence of replay elimination. This is
    /// internal rather than API surface; production callers do not make
    /// correctness decisions from these counters.
    func cacheStatistics() -> SQLiteEventStoreCacheStatistics {
        cacheStatisticsValue
    }

    /// Test-visible LRU order, from next eviction candidate to hottest entry.
    func cachedSessionIDsInLRUOrder() -> [SessionID] {
        cacheAccessOrder
    }

    private func appendInternal(
        _ validatedEvents: [ValidatedScoutEvent],
        expectation: (sessionID: SessionID, version: ExpectedStreamVersion)?,
        idempotencyKey: IdempotencyKey?
    ) throws -> [AppendReceipt] {
        guard !validatedEvents.isEmpty else { return [] }
        let events = validatedEvents.map(\.envelope)
        let database = try requiredDatabase()

        var seenIDs = Set<EventID>()
        for event in events {
            guard seenIDs.insert(event.id).inserted else {
                throw SQLiteEventStoreError.duplicateEventID(event.id)
            }
            guard event.sequence.rawValue <= UInt64(Int64.max) else {
                throw SQLiteEventStoreError.unsupportedSequence(event.sequence.rawValue)
            }
        }

        let requestHash = Self.requestHash(events: events, expectation: expectation)
        try database.execute("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed { try? database.execute("ROLLBACK") }
        }

        // `data_version` changes when another connection commits. Reading it
        // only after BEGIN IMMEDIATE ensures that no writer can move the
        // canonical head between invalidation and the checks below.
        let transactionDataVersion = try synchronizeCacheDataVersion(using: database)

        if let idempotencyKey,
           let existingHash = try existingRequestHash(for: idempotencyKey, in: database)
        {
            guard existingHash == requestHash else {
                throw SQLiteEventStoreError.idempotencyConflict(idempotencyKey)
            }
            let replayed = try operationEvents(for: idempotencyKey, in: database)
            var verifiedSnapshots: [SessionID: VerifiedStreamSnapshot] = [:]
            for sessionID in Set(replayed.map(\.sessionID)) {
                verifiedSnapshots[sessionID] = try transactionSnapshot(
                    for: sessionID,
                    using: database
                )
            }
            try database.execute("COMMIT")
            committed = true
            publish(verifiedSnapshots, dataVersion: transactionDataVersion)
            return replayed.map(AppendReceipt.init(event:))
        }

        let appendTime = Self.timestamp()
        for event in validatedEvents {
            do {
                try event.validateAppendAuthorization(at: appendTime)
            } catch let error as ScoutEventAuthorizationError {
                throw SQLiteEventStoreError.reduction(.authorization(error))
            }
        }

        for event in events where try containsEvent(id: event.id, in: database) {
            throw SQLiteEventStoreError.duplicateEventID(event.id)
        }

        let affectedSessions = Set(events.map(\.sessionID))
        var candidateSnapshots: [SessionID: VerifiedStreamSnapshot] = [:]
        for sessionID in affectedSessions.sorted() {
            candidateSnapshots[sessionID] = try transactionSnapshot(
                for: sessionID,
                using: database
            )
        }

        if let expectation {
            let actual = Self.version(of: candidateSnapshots[expectation.sessionID]?.state)
            guard actual == expectation.version else {
                throw SQLiteEventStoreError.versionConflict(
                    sessionID: expectation.sessionID,
                    expected: expectation.version,
                    actual: actual
                )
            }
        }

        for (event, validatedEvent) in zip(events, validatedEvents) {
            var snapshot = candidateSnapshots[event.sessionID]
                ?? VerifiedStreamSnapshot(events: [], state: nil)
            let current = snapshot.state ?? ScoutState(sessionID: event.sessionID)
            do {
                snapshot.state = try ScoutGraphReducer.reduce(
                    current,
                    event: validatedEvent
                )
            } catch let error as ScoutReducerError {
                throw SQLiteEventStoreError.reduction(error)
            }
            snapshot.events.append(event)
            candidateSnapshots[event.sessionID] = snapshot
        }
        for sessionID in affectedSessions {
            guard let candidate = candidateSnapshots[sessionID]?.state else { continue }
            do {
                try ScoutGraphReducer.validateBatchTerminal(candidate)
            } catch let error as ScoutReducerError {
                throw SQLiteEventStoreError.reduction(error)
            }
        }

        do {
            for event in events {
                let retainedBytes = try insert(event, into: database)
                guard var snapshot = candidateSnapshots[event.sessionID] else {
                    throw corruption(
                        event.id.rawValue,
                        "candidate snapshot disappeared before insert"
                    )
                }
                snapshot.estimatedRetainedBytes = Self.saturatedSum(
                    snapshot.estimatedRetainedBytes,
                    retainedBytes
                )
                candidateSnapshots[event.sessionID] = snapshot
            }
        } catch let error as SQLiteEventStoreError {
            throw try translateConstraint(error, events: events, database: database)
        }

        if let idempotencyKey {
            try insertOperation(
                key: idempotencyKey,
                requestHash: requestHash,
                events: events,
                into: database
            )
        }

        try database.execute("COMMIT")
        committed = true
        publish(candidateSnapshots, dataVersion: transactionDataVersion)
        return events.map(AppendReceipt.init(event:))
    }

    private func loadVerifiedStreamFromSQLite(
        for sessionID: SessionID,
        using database: SQLiteDatabase
    ) throws -> VerifiedStreamSnapshot {
        cacheStatisticsValue.fullStreamReplays += 1
        let statement = try database.prepare(
            Self.eventSelect + " WHERE session_id = ? ORDER BY sequence"
        )
        defer { database.finalize(statement) }
        try database.bind(sessionID.rawValue, to: 1, in: statement)

        var events: [ScoutEventEnvelope] = []
        var state: ScoutState?
        var estimatedRetainedBytes = VerifiedStreamSnapshot.fixedEstimatedRetainedBytes
        while try database.step(statement) == SQLITE_ROW {
            let decoded = try decodeEvent(from: statement, database: database)
            let event = decoded.envelope
            let current = state ?? ScoutState(sessionID: sessionID)
            do {
                state = try ScoutGraphReducer.reducePersisted(current, event: event)
            } catch let error as ScoutReducerError {
                throw corruption(event.id.rawValue, "reducer rejected stream: \(error)")
            }
            events.append(event)
            estimatedRetainedBytes = Self.saturatedSum(
                estimatedRetainedBytes,
                decoded.estimatedRetainedBytes
            )
        }
        if let state {
            do {
                try ScoutGraphReducer.validateBatchTerminal(state)
            } catch let error as ScoutReducerError {
                throw corruption(
                    events.last?.id.rawValue,
                    "event stream ended inside a model projection: \(error)"
                )
            }
        }
        return VerifiedStreamSnapshot(
            events: events,
            state: state,
            estimatedRetainedBytes: estimatedRetainedBytes
        )
    }

    /// Returns a verified snapshot for a normal read. A cross-connection
    /// commit clears every entry before lookup. A replay that overlaps an
    /// external commit is safe to return as its own SQLite snapshot, but is
    /// deliberately not cached under the newer generation.
    private func verifiedSnapshot(for sessionID: SessionID) throws -> VerifiedStreamSnapshot {
        let database = try requiredDatabase()
        let startingDataVersion = try synchronizeCacheDataVersion(using: database)
        if let cached = verifiedStreamCache[sessionID] {
            cacheStatisticsValue.cacheHits += 1
            touchCachedSnapshot(for: sessionID)
            return cached
        }

        let snapshot = try loadVerifiedStreamFromSQLite(for: sessionID, using: database)
        let endingDataVersion = try currentDataVersion(using: database)
        if endingDataVersion == startingDataVersion {
            cache(snapshot, for: sessionID)
        } else {
            invalidateCache(forDataVersion: endingDataVersion)
        }
        return snapshot
    }

    /// Resolves a stream while the append transaction holds SQLite's write
    /// reservation. Even a generation-matching cache entry must match the
    /// canonical persisted head before its reducer state can seed a write.
    private func transactionSnapshot(
        for sessionID: SessionID,
        using database: SQLiteDatabase
    ) throws -> VerifiedStreamSnapshot {
        cacheStatisticsValue.transactionalHeadChecks += 1
        let canonicalHead = try persistedHead(for: sessionID, using: database)
        if let cached = verifiedStreamCache[sessionID], cached.head == canonicalHead {
            cacheStatisticsValue.cacheHits += 1
            touchCachedSnapshot(for: sessionID)
            return cached
        }

        removeCachedSnapshot(for: sessionID)
        let loaded = try loadVerifiedStreamFromSQLite(for: sessionID, using: database)
        guard loaded.head == canonicalHead else {
            throw corruption(
                nil,
                "stream head changed while an immediate append transaction was active"
            )
        }
        return loaded
    }

    private func persistedHead(
        for sessionID: SessionID,
        using database: SQLiteDatabase
    ) throws -> PersistedStreamHead {
        let statement = try database.prepare(
            """
            SELECT event_id, sequence, integrity_hash
            FROM scout_events
            WHERE session_id = ?
            ORDER BY sequence DESC
            LIMIT 1
            """
        )
        defer { database.finalize(statement) }
        try database.bind(sessionID.rawValue, to: 1, in: statement)
        guard try database.step(statement) == SQLITE_ROW else { return .empty }

        let eventID = database.text(at: 0, in: statement)
        let rawSequence = database.int64(at: 1, in: statement)
        guard rawSequence > 0,
              let rawHash = database.text(at: 2, in: statement)
        else {
            throw corruption(eventID, "persisted stream head is outside its domain")
        }
        do {
            return PersistedStreamHead(
                sequence: try EventSequence(UInt64(rawSequence)),
                integrityHash: try ScoutCore.SHA256Digest(validating: rawHash)
            )
        } catch {
            throw corruption(eventID, "persisted stream head is outside its domain")
        }
    }

    private func currentDataVersion(using database: SQLiteDatabase) throws -> Int64 {
        guard let version = try database.querySingleInt("PRAGMA data_version"), version >= 0 else {
            throw SQLiteEventStoreError.sqlite(
                SQLiteFailure(
                    code: SQLITE_ERROR,
                    message: "SQLite did not return a valid data_version"
                )
            )
        }
        return version
    }

    @discardableResult
    private func synchronizeCacheDataVersion(using database: SQLiteDatabase) throws -> Int64 {
        let version = try currentDataVersion(using: database)
        guard let cachedVersion = cacheDataVersion else {
            cacheDataVersion = version
            return version
        }
        if cachedVersion != version {
            invalidateCache(forDataVersion: version)
        }
        return version
    }

    private func invalidateCache(forDataVersion version: Int64) {
        if let cachedVersion = cacheDataVersion, cachedVersion != version {
            cacheStatisticsValue.externalInvalidations += 1
        }
        clearVerifiedStreamCache()
        cacheDataVersion = version
    }

    /// Cache candidates are built against an open transaction, but enter the
    /// actor cache only after its COMMIT has succeeded.
    private func publish(
        _ snapshots: [SessionID: VerifiedStreamSnapshot],
        dataVersion: Int64
    ) {
        guard cacheDataVersion == dataVersion else {
            invalidateCache(forDataVersion: dataVersion)
            return
        }
        for sessionID in snapshots.keys.sorted() {
            guard let snapshot = snapshots[sessionID] else { continue }
            cache(snapshot, for: sessionID)
        }
    }

    private func cache(_ snapshot: VerifiedStreamSnapshot, for sessionID: SessionID) {
        // Replacement must first release the old entry's aggregate charge. A
        // rejected replacement must not leave a stale verified head available.
        removeCachedSnapshot(for: sessionID)

        guard isIndividuallyCacheable(snapshot) else {
            cacheStatisticsValue.oversizedSnapshotRejections += 1
            return
        }

        while !hasCapacity(for: snapshot) {
            guard let evictionCandidate = cacheAccessOrder.first else {
                cacheStatisticsValue.oversizedSnapshotRejections += 1
                return
            }
            removeCachedSnapshot(for: evictionCandidate)
            cacheStatisticsValue.budgetEvictions += 1
        }

        verifiedStreamCache[sessionID] = snapshot
        cachedEventCount += snapshot.events.count
        cachedEstimatedRetainedBytes += snapshot.estimatedRetainedBytes
        touchCachedSnapshot(for: sessionID)
        updateCacheGauges()
    }

    private func touchCachedSnapshot(for sessionID: SessionID) {
        cacheAccessOrder.removeAll { $0 == sessionID }
        cacheAccessOrder.append(sessionID)
    }

    private func removeCachedSnapshot(for sessionID: SessionID) {
        if let removed = verifiedStreamCache.removeValue(forKey: sessionID) {
            cachedEventCount -= removed.events.count
            cachedEstimatedRetainedBytes -= removed.estimatedRetainedBytes
        }
        cacheAccessOrder.removeAll { $0 == sessionID }
        updateCacheGauges()
    }

    private func clearVerifiedStreamCache() {
        verifiedStreamCache.removeAll(keepingCapacity: true)
        cacheAccessOrder.removeAll(keepingCapacity: true)
        cachedEventCount = 0
        cachedEstimatedRetainedBytes = 0
        updateCacheGauges()
    }

    private func isIndividuallyCacheable(_ snapshot: VerifiedStreamSnapshot) -> Bool {
        cacheBudgets.maximumStreamCount > 0
            && snapshot.events.count <= cacheBudgets.maximumEventCount
            && snapshot.estimatedRetainedBytes
                <= cacheBudgets.maximumEstimatedRetainedBytes
    }

    private func hasCapacity(for snapshot: VerifiedStreamSnapshot) -> Bool {
        guard verifiedStreamCache.count < cacheBudgets.maximumStreamCount,
              cachedEventCount <= cacheBudgets.maximumEventCount,
              cachedEstimatedRetainedBytes
                <= cacheBudgets.maximumEstimatedRetainedBytes
        else { return false }

        return snapshot.events.count
                <= cacheBudgets.maximumEventCount - cachedEventCount
            && snapshot.estimatedRetainedBytes
                <= cacheBudgets.maximumEstimatedRetainedBytes
                    - cachedEstimatedRetainedBytes
    }

    private func updateCacheGauges() {
        cacheStatisticsValue.cachedStreamCount = verifiedStreamCache.count
        cacheStatisticsValue.cachedEventCount = cachedEventCount
        cacheStatisticsValue.cachedEstimatedRetainedBytes = cachedEstimatedRetainedBytes
    }

    private static func timestamp() -> ScoutTimestamp {
        ScoutTimestamp(millisecondsSinceUnixEpoch: Int64(
            (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        ))
    }

    private func operationEvents(
        for key: IdempotencyKey,
        in database: SQLiteDatabase
    ) throws -> [ScoutEventEnvelope] {
        let statement = try database.prepare(
            Self.eventSelectWithAlias
                + " FROM scout_append_operation_events AS operation "
                + "JOIN scout_events AS event ON event.event_id = operation.event_id "
                + "WHERE operation.idempotency_key = ? ORDER BY operation.ordinal"
        )
        defer { database.finalize(statement) }
        try database.bind(key.rawValue, to: 1, in: statement)

        var events: [ScoutEventEnvelope] = []
        while try database.step(statement) == SQLITE_ROW {
            events.append(try decodeEvent(from: statement, database: database).envelope)
        }

        let countStatement = try database.prepare(
            "SELECT event_count FROM scout_append_operations WHERE idempotency_key = ?"
        )
        defer { database.finalize(countStatement) }
        try database.bind(key.rawValue, to: 1, in: countStatement)
        guard try database.step(countStatement) == SQLITE_ROW else {
            throw corruption(nil, "idempotency operation disappeared during replay")
        }
        let expectedCount = Int(database.int64(at: 0, in: countStatement))
        guard events.count == expectedCount else {
            throw corruption(
                nil,
                "idempotency operation expected \(expectedCount) events but resolved \(events.count)"
            )
        }
        return events
    }

    private func decodeEvent(
        from statement: OpaquePointer,
        database: SQLiteDatabase
    ) throws -> DecodedPersistedEvent {
        let possibleStoredID = database.text(at: 0, in: statement)
        guard let storedID = possibleStoredID,
              let storedSessionID = database.text(at: 1, in: statement),
              let storedKind = database.text(at: 7, in: statement),
              let storedIntegrityHash = database.text(at: 9, in: statement),
              let storedCanonicalBlob = database.data(at: 10, in: statement),
              let storedEncodedBlob = database.data(at: 11, in: statement)
        else {
            throw corruption(possibleStoredID, "required event column is NULL")
        }

        let canonicalBlob = try decodeStoredBlob(
            storedCanonicalBlob,
            eventID: storedID,
            purpose: .canonicalEnvelope
        )
        let encodedBlob = try decodeStoredBlob(
            storedEncodedBlob,
            eventID: storedID,
            purpose: .hydrationEnvelope
        )

        let storedSequence = database.int64(at: 2, in: statement)
        let storedSchemaMajor = database.int64(at: 3, in: statement)
        let storedSchemaMinor = database.int64(at: 4, in: statement)
        guard storedSequence > 0,
              storedSchemaMajor >= 0,
              storedSchemaMajor <= Int64(UInt16.max),
              storedSchemaMinor >= 0,
              storedSchemaMinor <= Int64(UInt16.max)
        else {
            throw corruption(storedID, "numeric event metadata is outside its domain")
        }

        let event: ScoutEventEnvelope
        do {
            event = try JSONDecoder().decode(ScoutEventEnvelope.self, from: encodedBlob)
        } catch {
            throw corruption(storedID, "hydration envelope cannot be decoded: \(error)")
        }

        guard CanonicalJSON.encode(event.canonicalValue) == canonicalBlob else {
            throw corruption(storedID, "envelope blob is not canonical JSON")
        }
        guard event.hasValidIntegrity else {
            throw corruption(storedID, "envelope integrity hash is invalid")
        }

        let storedPreviousHash = database.text(at: 8, in: statement)
        let metadataMatches = event.id.rawValue == storedID
            && event.sessionID.rawValue == storedSessionID
            && event.sequence.rawValue == UInt64(storedSequence)
            && UInt64(event.schemaVersion.major) == UInt64(storedSchemaMajor)
            && UInt64(event.schemaVersion.minor) == UInt64(storedSchemaMinor)
            && event.occurredAt.millisecondsSinceUnixEpoch
                == database.int64(at: 5, in: statement)
            && event.recordedAt.millisecondsSinceUnixEpoch
                == database.int64(at: 6, in: statement)
            && event.payload.kind == storedKind
            && event.previousHash?.rawValue == storedPreviousHash
            && event.integrityHash.rawValue == storedIntegrityHash
        guard metadataMatches else {
            throw corruption(storedID, "indexed metadata does not match canonical envelope")
        }
        return DecodedPersistedEvent(
            envelope: event,
            estimatedRetainedBytes: Self.estimatedRetainedBytes(
                canonicalByteCount: canonicalBlob.count,
                hydrationByteCount: encodedBlob.count
            )
        )
    }

    private func insert(
        _ event: ScoutEventEnvelope,
        into database: SQLiteDatabase
    ) throws -> Int {
        let statement = try database.prepare(
            """
            INSERT INTO scout_events(
                event_id, session_id, sequence, schema_major, schema_minor,
                occurred_at_ms, recorded_at_ms, event_kind, previous_hash,
                integrity_hash, envelope, encoded_envelope, inserted_at_ms
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { database.finalize(statement) }

        try database.bind(event.id.rawValue, to: 1, in: statement)
        try database.bind(event.sessionID.rawValue, to: 2, in: statement)
        try database.bind(Int64(event.sequence.rawValue), to: 3, in: statement)
        try database.bind(Int64(event.schemaVersion.major), to: 4, in: statement)
        try database.bind(Int64(event.schemaVersion.minor), to: 5, in: statement)
        try database.bind(event.occurredAt.millisecondsSinceUnixEpoch, to: 6, in: statement)
        try database.bind(event.recordedAt.millisecondsSinceUnixEpoch, to: 7, in: statement)
        try database.bind(event.payload.kind, to: 8, in: statement)
        if let previousHash = event.previousHash {
            try database.bind(previousHash.rawValue, to: 9, in: statement)
        } else {
            try database.bindNull(to: 9, in: statement)
        }
        try database.bind(event.integrityHash.rawValue, to: 10, in: statement)
        let canonicalPlaintext = CanonicalJSON.encode(event.canonicalValue)
        let canonicalBlob = try encodeStoredBlob(
            canonicalPlaintext,
            eventID: event.id.rawValue,
            purpose: .canonicalEnvelope
        )
        try database.bind(canonicalBlob, to: 11, in: statement)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hydrationPlaintext = try encoder.encode(event)
        let encodedBlob = try encodeStoredBlob(
            hydrationPlaintext,
            eventID: event.id.rawValue,
            purpose: .hydrationEnvelope
        )
        try database.bind(encodedBlob, to: 12, in: statement)
        try database.bind(Self.nowMilliseconds(), to: 13, in: statement)
        _ = try database.step(statement)
        return Self.estimatedRetainedBytes(
            canonicalByteCount: canonicalPlaintext.count,
            hydrationByteCount: hydrationPlaintext.count
        )
    }

    /// The cache retains decoded envelopes plus a reducer projection, not the
    /// temporary SQLite blobs. Twice the combined canonical/hydration payload
    /// plus fixed per-event overhead is deliberately conservative and stable.
    private static func estimatedRetainedBytes(
        canonicalByteCount: Int,
        hydrationByteCount: Int
    ) -> Int {
        let payloadBytes = saturatedSum(canonicalByteCount, hydrationByteCount)
        return saturatedSum(saturatedProduct(payloadBytes, 2), 512)
    }

    private static func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func saturatedProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }

    private func encodeStoredBlob(
        _ plaintext: Data,
        eventID: String,
        purpose: EventBlobPurpose
    ) throws -> Data {
        guard let blobCipher else { return plaintext }
        do {
            return try blobCipher.seal(plaintext, eventID: eventID, purpose: purpose)
        } catch {
            throw SQLiteEventStoreError.encryptionFailure
        }
    }

    private func decodeStoredBlob(
        _ stored: Data,
        eventID: String,
        purpose: EventBlobPurpose
    ) throws -> Data {
        guard let blobCipher else {
            guard !EventBlobCipher.hasEncryptedHeader(stored) else {
                throw corruption(eventID, "encrypted event blob requires an encryption key")
            }
            return stored
        }

        do {
            return try blobCipher.open(stored, eventID: eventID, purpose: purpose)
        } catch let error as EventBlobCipher.Error {
            switch error {
            case .invalidHeader:
                throw corruption(eventID, "event blob is not in the encrypted Scout format")
            case let .unsupportedVersion(version):
                throw corruption(eventID, "event blob uses unsupported encryption version \(version)")
            case .authenticationFailed:
                throw corruption(eventID, "encrypted event blob authentication failed")
            }
        } catch {
            throw corruption(eventID, "encrypted event blob could not be opened")
        }
    }

    private func insertOperation(
        key: IdempotencyKey,
        requestHash: String,
        events: [ScoutEventEnvelope],
        into database: SQLiteDatabase
    ) throws {
        let operation = try database.prepare(
            """
            INSERT INTO scout_append_operations(
                idempotency_key, request_hash, event_count, committed_at_ms
            ) VALUES(?, ?, ?, ?)
            """
        )
        defer { database.finalize(operation) }
        try database.bind(key.rawValue, to: 1, in: operation)
        try database.bind(requestHash, to: 2, in: operation)
        try database.bind(Int64(events.count), to: 3, in: operation)
        try database.bind(Self.nowMilliseconds(), to: 4, in: operation)
        _ = try database.step(operation)

        for (ordinal, event) in events.enumerated() {
            try insertOperationEvent(
                key: key,
                ordinal: ordinal,
                event: event,
                into: database
            )
        }
    }

    private func insertOperationEvent(
        key: IdempotencyKey,
        ordinal: Int,
        event: ScoutEventEnvelope,
        into database: SQLiteDatabase
    ) throws {
        let link = try database.prepare(
            """
            INSERT INTO scout_append_operation_events(
                idempotency_key, ordinal, event_id
            ) VALUES(?, ?, ?)
            """
        )
        defer { database.finalize(link) }
        try database.bind(key.rawValue, to: 1, in: link)
        try database.bind(Int64(ordinal), to: 2, in: link)
        try database.bind(event.id.rawValue, to: 3, in: link)
        _ = try database.step(link)
    }

    private func existingRequestHash(
        for key: IdempotencyKey,
        in database: SQLiteDatabase
    ) throws -> String? {
        let statement = try database.prepare(
            "SELECT request_hash FROM scout_append_operations WHERE idempotency_key = ?"
        )
        defer { database.finalize(statement) }
        try database.bind(key.rawValue, to: 1, in: statement)
        guard try database.step(statement) == SQLITE_ROW else { return nil }
        return database.text(at: 0, in: statement)
    }

    private func containsEvent(id: EventID, in database: SQLiteDatabase) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM scout_events WHERE event_id = ? LIMIT 1"
        )
        defer { database.finalize(statement) }
        try database.bind(id.rawValue, to: 1, in: statement)
        return try database.step(statement) == SQLITE_ROW
    }

    private func translateConstraint(
        _ error: SQLiteEventStoreError,
        events: [ScoutEventEnvelope],
        database: SQLiteDatabase
    ) throws -> SQLiteEventStoreError {
        guard case let .sqlite(failure) = error,
              failure.code & 0xFF == SQLITE_CONSTRAINT
        else { return error }

        for event in events where try containsEvent(id: event.id, in: database) {
            return .duplicateEventID(event.id)
        }
        for event in events {
            if try containsSequence(
                event.sequence,
                sessionID: event.sessionID,
                in: database
            ) {
                return .duplicateSequence(sessionID: event.sessionID, sequence: event.sequence)
            }
        }
        return error
    }

    private func containsSequence(
        _ sequence: EventSequence,
        sessionID: SessionID,
        in database: SQLiteDatabase
    ) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM scout_events WHERE session_id = ? AND sequence = ? LIMIT 1"
        )
        defer { database.finalize(statement) }
        try database.bind(sessionID.rawValue, to: 1, in: statement)
        try database.bind(Int64(sequence.rawValue), to: 2, in: statement)
        return try database.step(statement) == SQLITE_ROW
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database, database.isOpen else {
            throw SQLiteEventStoreError.storeClosed
        }
        return database
    }

    private static func configure(
        _ database: SQLiteDatabase,
        requireWAL: Bool = true
    ) throws {
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA synchronous = FULL")
        try database.execute("PRAGMA temp_store = MEMORY")
        try database.execute("PRAGMA wal_autocheckpoint = 1000")
        if requireWAL {
            try database.execute("PRAGMA journal_mode = WAL")
            let mode = try database.querySingleText("PRAGMA journal_mode")?.lowercased()
            guard mode == "wal" else {
                throw SQLiteEventStoreError.sqlite(
                    SQLiteFailure(
                        code: SQLITE_ERROR,
                        message: "SQLite refused WAL journal mode (reported \(mode ?? "unknown"))"
                    )
                )
            }
        }
        let foreignKeys = try database.querySingleInt("PRAGMA foreign_keys")
        guard foreignKeys == 1 else {
            throw SQLiteEventStoreError.sqlite(
                SQLiteFailure(code: SQLITE_ERROR, message: "SQLite foreign keys are disabled")
            )
        }
        let foreignKeyCheck = try database.prepare("PRAGMA foreign_key_check")
        defer { database.finalize(foreignKeyCheck) }
        guard try database.step(foreignKeyCheck) == SQLITE_DONE else {
            throw SQLiteEventStoreError.corruptEvent(
                eventID: nil,
                reason: "database contains a foreign-key violation"
            )
        }
    }

    private static func requestHash(
        events: [ScoutEventEnvelope],
        expectation: (sessionID: SessionID, version: ExpectedStreamVersion)?
    ) -> String {
        let expectationValue: CanonicalValue
        if let expectation {
            switch expectation.version {
            case .empty:
                expectationValue = .object([
                    "sessionID": expectation.sessionID.canonicalValue,
                    "version": .string("empty"),
                ])
            case let .sequence(sequence):
                expectationValue = .object([
                    "sessionID": expectation.sessionID.canonicalValue,
                    "version": sequence.canonicalValue,
                ])
            }
        } else {
            expectationValue = .null
        }
        return SHA256Digest.hash(
            .object([
                "events": .array(events.map(\.canonicalValue)),
                "expectation": expectationValue,
            ])
        ).rawValue
    }

    private static func version(of state: ScoutState?) -> ExpectedStreamVersion {
        guard let sequence = state?.lastSequence else { return .empty }
        return .sequence(sequence)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static let eventSelect =
        """
        SELECT event_id, session_id, sequence, schema_major, schema_minor,
               occurred_at_ms, recorded_at_ms, event_kind, previous_hash,
               integrity_hash, envelope, encoded_envelope
        FROM scout_events
        """

    private static let eventSelectWithAlias =
        """
        SELECT event.event_id, event.session_id, event.sequence,
               event.schema_major, event.schema_minor, event.occurred_at_ms,
               event.recorded_at_ms, event.event_kind, event.previous_hash,
               event.integrity_hash, event.envelope, event.encoded_envelope
        """
}

private enum EventBlobPurpose: String {
    case canonicalEnvelope = "canonical-envelope"
    case hydrationEnvelope = "hydration-envelope"
}

/// Authenticated, versioned storage encoding for sensitive event bodies.
///
/// Indexed routing metadata remains queryable by SQLite, while both complete
/// envelope representations are encrypted. The authenticated data binds each
/// ciphertext to its event identifier and column purpose so blobs cannot be
/// substituted between rows or columns without detection.
private struct EventBlobCipher {
    enum Error: Swift.Error {
        case invalidHeader
        case unsupportedVersion(UInt8)
        case authenticationFailed
    }

    private static let magic = Data([0x53, 0x43, 0x54, 0x42]) // SCTB
    private static let version: UInt8 = 1

    private let key: SymmetricKey

    static func make(keyData: Data?) throws -> EventBlobCipher? {
        guard let keyData else { return nil }
        guard keyData.count == 32 else {
            throw SQLiteEventStoreError.invalidEncryptionKey
        }
        return EventBlobCipher(key: SymmetricKey(data: keyData))
    }

    static func hasEncryptedHeader(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    func seal(
        _ plaintext: Data,
        eventID: String,
        purpose: EventBlobPurpose
    ) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData(eventID: eventID, purpose: purpose)
        )
        guard let combined = sealed.combined else {
            throw Error.authenticationFailed
        }
        var result = Self.magic
        result.append(Self.version)
        result.append(combined)
        return result
    }

    func open(
        _ stored: Data,
        eventID: String,
        purpose: EventBlobPurpose
    ) throws -> Data {
        let headerCount = Self.magic.count + 1
        guard stored.count > headerCount,
              stored.prefix(Self.magic.count) == Self.magic
        else {
            throw Error.invalidHeader
        }

        let version = stored[stored.startIndex.advanced(by: Self.magic.count)]
        guard version == Self.version else {
            throw Error.unsupportedVersion(version)
        }

        do {
            let box = try AES.GCM.SealedBox(combined: Data(stored.dropFirst(headerCount)))
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(eventID: eventID, purpose: purpose)
            )
        } catch {
            throw Error.authenticationFailed
        }
    }

    private func authenticatedData(eventID: String, purpose: EventBlobPurpose) -> Data {
        Data("scout-event-blob|v1|\(eventID)|\(purpose.rawValue)".utf8)
    }
}

private func corruption(_ eventID: String?, _ reason: String) -> SQLiteEventStoreError {
    .corruptEvent(eventID: eventID, reason: reason)
}
