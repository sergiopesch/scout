# ADR-0001: Append-only event log is canonical

- Status: accepted
- Date: 2026-07-16

## Context

Live discovery produces provisional transcripts, identity refinements, contradictions, customer
corrections, model proposals, and approval decisions. Mutable tables would erase how the model changed
and make crash recovery, evidence tracing, and audit reconstruction ambiguous.

## Decision

The hash-linked append-only event log is Scout's canonical state. Events use monotonic stream sequence,
canonical encoding, expected-version append, and idempotency keys. Graphs, diagrams, questions,
opportunities, summaries, and action packs are disposable projections rebuilt by deterministic replay.
Corrections append revisions or validation events; they never rewrite transcript, speaker, evidence, or
claim history.

## Consequences

- Crash recovery and audit replay share one code path.
- Schema evolution and unsupported semantic versions must fail at the last verified boundary.
- Retention/deletion needs explicit tombstone or key-destruction policy rather than record mutation.
- Projection performance must be solved with snapshots/caches without promoting them to truth.
