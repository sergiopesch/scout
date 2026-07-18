# ScoutCore

The `ScoutCore` target is Scout's deterministic, dependency-free domain spine. It turns versioned
discovery events into a trusted customer graph while retaining exact provenance for every claim. The
package also contains a separate macOS `ScoutLocalReviewAuthority` adapter for system authentication.

## Invariants

- The append-only event stream is the source of truth.
- Every envelope is sequence-checked and SHA-256 chained to its predecessor.
- New writes are produced by closed semantic commands. Actor attribution, authorization scope, and
  payload are derived together, and stores accept only opaque validated events.
- The reducer is a pure function. Models propose typed events; they never mutate
  graph state directly.
- Model proposals remain suggested and unreviewed and must bind to an exact model-call event,
  identity, and purpose before reduction.
- Schema-v1.4 model receipts commit a contiguous, atomic sequence of at most 512 derived events.
  Replay reconstructs the rolling commitment and rejects incomplete, extra, reordered, or
  substituted projections.
- Model evidence must predate the recorded input boundary, and model proposals cannot mutate
  protected graph records, reviewed claims, or retired entities.
- Evidence recorder and model speaker attribution are derived from canonical command/utterance state;
  relationship removals retain tombstones across replay.
- Local reviews use a process-local capability minted by macOS device-owner authentication for one
  exact current-state decision. Append and replay revalidate its target revision, operation, age,
  and single use; stores check freshness again at the actual append boundary.
- Legacy terminal decisions remain explicitly unattested until a separate authenticated event binds
  their original review event and unchanged terminal state. Re-attestation changes assurance only;
  it never rewrites the historical decision.
- Claims and graph records must point to evidence already present in the stream.
- Every committed model response has a hash-only receipt tied to exact input and projection
  boundaries. Raw provider output and authentication material are not canonical state.
- Canonical hashes use an explicit integer-only JSON representation, independent
  of `Codable` key ordering.
- Replaying the same event bytes produces the same graph and state digest.

## Package layout

- `CanonicalJSON.swift`: canonical encoding and SHA-256 digests.
- `Identifiers.swift`: type-safe IDs, timestamps, confidence, exact decimals.
- `DomainPrimitives.swift`: sessions, speakers, utterances, and universal model
  primitives.
- `ModelCalls.swift`: strict model-call purposes, input boundaries, receipts, and derived-event
  manifests.
- `TrustAndEvidence.swift`: evidence, claims, provenance, and trust states.
- `Graph.swift`: entity and relationship records plus deterministic state.
- `EventAuthorization.swift`: closed write commands, opaque validated events, and scope policy.
- `ReviewAuthorization.swift`: exact local-review intents, capabilities, and durable audit records.
- `Events.swift`: versioned envelopes, payloads, and chain builder.
- `Reducer.swift`: the only state-transition authority.
- `EventStore.swift`: actor-isolated, atomic, append-only in-memory storage.
- `ScoutLocalReviewAuthority`: macOS `LocalAuthentication` adapter, isolated from the pure Core
  target.
- `Fixtures.swift`: deterministic Acme Retail discovery fixture.

Run `swift test` from this directory.

Schema 1.0–1.3 logs remain replayable under their historical rules but are unattested for v1.4's
exact-projection and device-owner-review guarantees. Schema 1.0–1.2 also predate command
authorization. Stream schema versions cannot regress. Rebuild legacy snapshots from the full event
log before accepting v1.4 writes so all replay-derived indexes are complete.
