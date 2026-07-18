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
- the first stream read verifies envelope integrity, sequence, predecessor
  hashes, and the complete `ScoutGraphReducer` replay; subsequent same-process
  reads reuse a verified snapshot while SQLite `PRAGMA data_version` invalidates
  it after another connection commits;
- verified snapshots are aggregate-LRU bounded to 8 streams, 8,192 events, and
  a conservative 64 MiB retained-byte proxy; the proxy charges fixed snapshot
  and event overhead plus twice the canonical and hydration byte counts already
  produced during verification or insert, without re-encoding cache entries;
- a snapshot that cannot fit by itself is returned to its caller after normal
  verification but is not cached; cache diagnostics expose current stream,
  event, and estimated-byte gauges plus eviction and rejection counters;
- every append still rechecks the canonical stream head inside its
  `BEGIN IMMEDIATE` transaction, builds candidate snapshots privately, and
  publishes them only after `COMMIT` succeeds;
- explicit `verifyChain` calls always bypass the cache and refresh it only when
  the SQLite generation remains stable;
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
