# ADR-0005: Canonical writes require validated command authority

- Status: accepted
- Date: 2026-07-17

## Context

An event's actor answers who or what a fact is attributed to; it does not prove who authorized the
state change. A hash-linked envelope protects integrity after construction, but a public constructor
that accepts any actor and payload pair still lets a caller stamp a model operation as a system review.
Likewise, accepting decoded envelopes at the store boundary turns replay data into write authority.

ADR-0001 makes the event log canonical, and ADR-0002 makes model output propositional. The write API
must enforce both decisions rather than relying on each caller to remember them.

## Decision

- Event schema v1.3 hashes an authorization record containing a closed command scope and the trusted
  Scout component that validated it. `EventActor` remains provenance and is never treated as a
  credential.
- Every new event is created through `ScoutEventCommand`. The command boundary derives the allowed
  payload, actor, and authorization record together and returns a non-`Codable`, opaque
  `ValidatedScoutEvent`.
- In-memory and SQLite stores accept only `ValidatedScoutEvent`. Decoded `ScoutEventEnvelope` values
  are read/replay data and cannot be converted into appendable values through public API.
- New writes must use the current schema. Older envelopes remain replayable so existing hash chains
  do not need to be rewritten, but a caller cannot downgrade a new write to bypass v1.3 policy.
- Model projection commands may record a call or append proposed entities, claims, relationships, and
  visual observations only. Model-derived graph records must remain suggested and unreviewed, and
  every proposal must bind to the exact recorded call event, model identity, and allowed purpose.
  Cited evidence must already exist at that call's input boundary.
- Model proposals cannot overwrite reviewed or deterministic graph records, reactivate retired
  entities, recreate removed relationships, or supersede a reviewed claim. References from reviewed
  claims protect suggested entities and relationships transitively. Evidence and append-only claim
  linkage may continue so contradictory claims can coexist, but a model cannot rewrite relationship
  shape, label, attributes, or trust.
- Utterance evidence must retain the finalized utterance's speaker as `capturedBy`; imported evidence
  derives its recorder from the authorized import component. Model claim attribution must match the
  unique speaker resolved from its utterance evidence.
- Claim and visual-observation review, session lifecycle, graph maintenance, capture, evidence import,
  and deterministic projection are separate command scopes. The reducer revalidates the scope,
  actor, payload, trust state, and model receipt before any state transition.
- A batch is reduced against cloned state and becomes visible only if every event passes authorization
  and domain validation.

## Consequences

- Actor spoofing, model self-review, forged receipt binding, and partial mixed-authority batches fail
  before canonical state changes.
- Adding a state-bearing payload now requires an explicit command scope and policy decision.
- Persistence adapters and fixtures must carry validated events on write while continuing to expose
  ordinary envelopes on read.
- Schema 1.0–1.2 histories remain integrity-verified but authorization-unattested. The new evidence,
  receipt-event, and relationship-removal indexes require full event replay when upgrading an old
  snapshot; snapshot-plus-tail restoration is unsafe until snapshots are explicitly versioned and
  migrated. Scout currently restores from full journal replay.
- This is an in-process authority boundary: all linked Swift application code is trusted. Command
  component names are audit metadata, not caller authentication. Gateway responses, plugins, and
  other untrusted data must enter through narrow adapters that never expose privileged command choice.
  Authenticated reviewer identity, unforgeable cross-module capabilities, and signed review
  attestations remain separate product-security decisions.
- A receipt's `outputHash` is immutable provenance for the validated provider response; it is not yet
  a canonical manifest of every derived event. Deterministic adapters remain trusted to map that
  response into the bounded command batch. A projection-manifest commitment is follow-on hardening.
