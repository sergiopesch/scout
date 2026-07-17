# ScoutCore

ScoutCore is the deterministic, dependency-free domain spine for Scout. It turns
versioned discovery events into a trusted customer graph while retaining exact
provenance for every claim.

## Invariants

- The append-only event stream is the source of truth.
- Every envelope is sequence-checked and SHA-256 chained to its predecessor.
- The reducer is a pure function. Models propose typed events; they never mutate
  graph state directly.
- Claims and graph records must point to evidence already present in the stream.
- Every committed model response has a hash-only receipt tied to an exact,
  already-applied input event boundary.
- Canonical hashes use an explicit integer-only JSON representation, independent
  of `Codable` key ordering.
- Replaying the same event bytes produces the same graph and state digest.

## Package layout

- `CanonicalJSON.swift`: canonical encoding and SHA-256 digests.
- `Identifiers.swift`: type-safe IDs, timestamps, confidence, exact decimals.
- `DomainPrimitives.swift`: sessions, speakers, utterances, and universal model
  primitives.
- `ModelCalls.swift`: strict model-call purposes, input boundaries, and receipts.
- `TrustAndEvidence.swift`: evidence, claims, provenance, and trust states.
- `Graph.swift`: entity and relationship records plus deterministic state.
- `Events.swift`: versioned envelopes, payloads, and chain builder.
- `Reducer.swift`: the only state-transition authority.
- `EventStore.swift`: actor-isolated, atomic, append-only in-memory storage.
- `Fixtures.swift`: deterministic Acme Retail discovery fixture.

Run `swift test` from this directory.
