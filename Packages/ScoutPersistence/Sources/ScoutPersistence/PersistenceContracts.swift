import Foundation
import ScoutCore

/// The committed version of a session stream before an append begins.
///
/// Callers use this as an optimistic concurrency token. `.empty` is distinct
/// from omitting the check: an append expecting an empty stream must fail once
/// another writer has committed sequence one.
public enum ExpectedStreamVersion: Equatable, Sendable {
    case empty
    case sequence(EventSequence)
}

/// A stable key supplied by the command boundary for safe append retries.
public struct IdempotencyKey: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.utf8.count <= 256,
              !rawValue.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
            throw SQLiteEventStoreError.invalidIdempotencyKey
        }
        self.rawValue = rawValue
    }
}

public struct SQLiteFailure: Error, Equatable, Sendable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
}

public enum SQLiteEventStoreError: Error, Equatable, Sendable {
    case invalidFileURL
    case invalidBusyTimeout
    case invalidIdempotencyKey
    case invalidEncryptionKey
    case encryptionFailure
    case storeClosed
    case unsupportedSequence(UInt64)
    case mixedSessionBatch
    case duplicateEventID(EventID)
    case duplicateSequence(sessionID: SessionID, sequence: EventSequence)
    case versionConflict(
        sessionID: SessionID,
        expected: ExpectedStreamVersion,
        actual: ExpectedStreamVersion
    )
    case idempotencyConflict(IdempotencyKey)
    case reduction(ScoutReducerError)
    case corruptEvent(eventID: String?, reason: String)
    case sqlite(SQLiteFailure)
}

public struct ChainVerificationReport: Equatable, Sendable {
    public let sessionID: SessionID
    public let eventCount: Int
    public let lastSequence: EventSequence?
    public let lastHash: SHA256Digest?
    public let stateDigest: SHA256Digest?

    public init(
        sessionID: SessionID,
        eventCount: Int,
        lastSequence: EventSequence?,
        lastHash: SHA256Digest?,
        stateDigest: SHA256Digest?
    ) {
        self.sessionID = sessionID
        self.eventCount = eventCount
        self.lastSequence = lastSequence
        self.lastHash = lastHash
        self.stateDigest = stateDigest
    }
}

/// Persistence-level event-store contract.
///
/// ScoutCore currently provides a concrete `InMemoryEventStore`, not a public
/// protocol. This protocol is therefore the precise async adapter boundary for
/// persistent implementations. Method names and domain return types mirror the
/// core store; reads additionally throw because persisted bytes can be corrupt.
public protocol ScoutPersistentEventStore: Sendable {
    @discardableResult
    func append(_ event: ValidatedScoutEvent) async throws -> AppendReceipt

    @discardableResult
    func append(_ events: [ValidatedScoutEvent]) async throws -> [AppendReceipt]

    @discardableResult
    func append(
        _ events: [ValidatedScoutEvent],
        expecting version: ExpectedStreamVersion,
        idempotencyKey: IdempotencyKey?
    ) async throws -> [AppendReceipt]

    func events(
        for sessionID: SessionID,
        after sequence: EventSequence?
    ) async throws -> [ScoutEventEnvelope]

    func state(for sessionID: SessionID) async throws -> ScoutState?
    func eventCount(for sessionID: SessionID) async throws -> Int
    func sessionIDs() async throws -> [SessionID]
}
