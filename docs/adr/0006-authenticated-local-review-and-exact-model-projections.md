# ADR-0006: Authenticate exact local reviews and commit exact model projections

- Status: accepted
- Date: 2026-07-17
- Extends: [ADR-0005](0005-validated-event-command-boundary.md)

## Context

ADR-0005 closed the generic event-construction surface and made model writes propositional, but two
authorities were still broader than the action that reached the canonical log.

First, a schema-v1.3 model receipt committed the provider output hash but not the complete event
sequence produced by Scout's deterministic adapter. A valid receipt could therefore survive a
partial projection or be reused with an omitted, reordered, substituted, or additional derived
event unless each caller reproduced the same batching discipline.

Second, the v1.3 local-review command recorded a trusted component name, not proof that the device
owner had approved the exact decision. Authentication also cannot safely hold the journal actor's
operation lock while macOS presents a potentially long-running system prompt: capture and evidence
persistence must continue.

## Decision

### Exact model projections

- Every new schema-v1.4 model-call receipt carries a `DerivedEventManifest`, including receipts that
  intentionally derive zero events. Every v1.4 model-derived proposal binds to such a receipt.
- The manifest is bounded to at most 512 derived events. Its seed binds the receipt identifier,
  provider-output hash, exact projection-base event boundary, adapter identifier and version, and
  event count. Each rolling step binds the zero-based ordinal, event identifier, payload kind, and
  canonical payload hash. Only the final root and count are persisted with the receipt.
- The receipt and its declared events form one contiguous atomic append. Once a manifest-bearing
  receipt is reduced, no unrelated event may interrupt its declared sequence. The in-memory and
  SQLite stores validate terminal projection state on a cloned candidate before committing.
- Offline replay reconstructs the same rolling root and rejects an incomplete, extra, reordered, or
  substituted event sequence. It never calls the provider.
- An application retry replays the original projection-base prefix, regenerates the deterministic
  plan, and compares the persisted receipt, manifest, event identifiers, payloads, and terminal
  projection progress. The UI receives only a projection of canonical replay state; it never applies
  the retried adapter object directly.
- Image-observation receipts are rebuilt from the persisted evidence event. Asset identifier, media
  type, content hash, dimensions, byte count, provider response identifier, and normalized evidence
  excerpt must all match before an exact retry is accepted.

### Authenticated local reviews

- `ScoutEventCommand` no longer exposes a local-review case. Deterministic Core code prepares a
  `LocalReviewIntent` from current canonical state for one exact claim or visual-observation
  decision. The intent binds the session, future review event, operation, proposal event, and target
  state hash; the intent itself grants no write authority.
- The macOS authority creates a fresh `LAContext` and evaluates
  `deviceOwnerAuthentication` for that exact intent. Success mints a process-local,
  non-`Codable` `AuthenticatedLocalReview` capability. No reusable bearer, secret, or signing key is
  created.
- The application prepares the intent under the journal lock, releases the lock while the system
  authentication prompt is visible, and reacquires it for append. This keeps the capture hot path
  independent of a cold-path human decision. Cancellation invalidates the one-shot `LAContext`, and
  cancelled FIFO journal waiters cannot inherit or strand the operation lock.
- On append, Core revalidates the authorization component, session and review-event identifiers,
  exact operation hash, target and proposal-event identifiers, current target-state hash, proposed
  status, and terminal decision semantics. The review must have no correlation or causation link,
  must be recorded no more than five minutes after authentication, cannot predate authentication,
  and each authorization identifier is single-use.
- The store checks authorization freshness again against its actual append clock. Pre-sealing a
  validated event cannot preserve an expired grant, and future-dated event or authentication times
  fail closed.
- The non-secret `LocalReviewAuthorizationRecord` is hash-bound into the event authorization record.
  Replay deterministically validates that audit record against the state at the review event and
  rebuilds the consumed-authorization index.
- A legacy terminal review can be upgraded only by a new `localReview.attested` event. Its intent
  binds the original review event and exact current terminal state; the reducer updates only the
  assurance projection and never rewrites or repeats the historical decision. Proposed, missing,
  changed, or already-authenticated targets are rejected.

### Compatibility

- New appends use schema v1.4. Schema versions are monotonic within a stream, so a current stream
  cannot append a legacy envelope to bypass either policy.
- Schema v1.0-v1.3 histories remain integrity-checked and replayable under their historical rules.
  They are explicitly unattested for the new v1.4 guarantees: v1.3 local reviews have no
  device-owner authorization record and v1.3 model receipts may lack an exact projection manifest;
  v1.0-v1.2 events also predate the closed command-authorization record.
- Replay retains that assurance distinction. Legacy accepted claims and legacy-confirmed visual
  observations remain visibly validation-required and excluded from build-ready handoff until an
  append-only re-attestation succeeds.
- Scout rebuilds these replay-derived indexes from the full journal. Snapshot-plus-tail restoration
  remains disallowed until snapshot versions explicitly migrate the v1.3 and v1.4 indexes.

## Consequences

- A provider delivery becomes visible only with the exact bounded projection declared by its
  deterministic adapter. Partial commit and event-sequence substitution fail closed during append
  and replay.
- A local review event demonstrates that macOS successfully authenticated a device owner for one
  exact, still-current decision shortly before commit. A caller cannot construct equivalent write
  authority through ScoutCore's public command API.
- Re-attestation preserves append-only history: it authenticates the existing terminal decision and
  its exact review event without claiming that the legacy event originally carried v1.4 assurance.
- Device-owner authentication does **not** establish a named person's identity or organizational
  role. The durable record is not an independent cryptographic signature that resists malicious code
  already executing inside Scout's trusted application boundary.
- A derived-event manifest proves the exact events that the adapter declared and Scout committed. It
  does **not** prove that the adapter assigned a disposition to every item in the provider's source
  output; adapter validation and evaluation fixtures remain responsible for that completeness.
- Receipts and authorization records retain identifiers, bounded metadata, and hashes only. They do
  not persist raw provider output, authentication material, secrets, or signing keys.
