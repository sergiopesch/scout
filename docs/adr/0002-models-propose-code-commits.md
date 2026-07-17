# ADR-0002: Models propose and deterministic code commits

- Status: accepted
- Date: 2026-07-16

## Context

Meeting speech, transcripts, whiteboards, model output, and files can contain mistakes or adversarial
instructions. Allowing a model to mutate durable graph state or choose authoritative trust labels would
collapse evidence, reasoning, and authorization into one unverifiable operation.

## Decision

OpenAI responses are strict, bounded proposal objects with model, prompt, schema, input-boundary,
response-ID, and output-hash receipts. Deterministic Scout code validates foreign keys, evidence spans,
enums, idempotency, trust state, and atomic patch rules before appending events. Provider labels cannot
grant confirmed or heard authority by confidence alone.

## Consequences

- Every intelligence boundary requires schemas, negative fixtures, and replayable receipts.
- Invalid proposals reject atomically and never partially mutate the graph.
- Human review and deterministic evidence rules remain explicit product surfaces.
- Model upgrades can be evaluated without changing the canonical reducer contract.
