# ScoutPersistence

`ScoutPersistence` is Scout's durable append-only event-store adapter. It is a
standalone Swift package that depends only on `ScoutCore` and the platform
SQLite library.

## Guarantees

- `SQLiteEventStore` is actor-isolated and uses `BEGIN IMMEDIATE` transactions.
- explicit `ExpectedStreamVersion` checks provide optimistic concurrency across
  processes, not only within one actor;
- event IDs are globally unique and `(session_id, sequence)` is unique;
- command-scoped idempotency keys are immutable and safe for batch retries;
- update and delete triggers protect events, append operations, operation links,
  and migration history;
- WAL, full synchronous durability, foreign keys, and a bounded busy timeout are
  enabled for file stores;
- the exact `CanonicalJSON` envelope bytes are stored for audit and hashing;
- a separate sorted Codable blob hydrates the Swift type, after which the store
  recomputes and byte-compares the canonical envelope;
- every stream read verifies envelope integrity, sequence, predecessor hashes,
  and the complete `ScoutGraphReducer` replay;
- read models are never persisted as authority and remain rebuildable.

ScoutCore currently exposes `InMemoryEventStore` as a concrete actor rather
than a protocol. `ScoutPersistentEventStore` is the throwing async adapter
contract until a shared protocol can be introduced in ScoutCore. Its method
names and domain return types intentionally mirror the core store.

## Use

```swift
let store = try SQLiteEventStore(fileURL: databaseURL)
let key = try IdempotencyKey("meeting-123/extraction-7")

let receipts = try await store.append(
    proposedEvents,
    expecting: .sequence(lastCommittedSequence),
    idempotencyKey: key
)
```

Use `.empty` when creating a new session stream. Treat a
`versionConflict` as a signal to reload, reconcile, and propose a new batch.

## Verification

```sh
swift test
```
