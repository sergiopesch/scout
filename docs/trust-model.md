# Trust is a product surface

Scout earns trust by making its epistemic state visible and correctable while the customer is still in the room.

## Independent dimensions

Scout never compresses trust into one opaque score. Each claim carries:

- **Mode:** explicit, inferred, proposed, imported, or manually entered.
- **Validation:** unreviewed, confirmed, disputed, superseded, rejected, or retracted.
- **Confidence:** capture/model certainty in integer basis points; never a truth score.
- **Evidence availability:** available, offline, removed by policy, or corrupt.
- **Speaker resolution:** resolved participant, candidate, or anonymous track.
- **Conflict state:** none, contested, or resolved.

## Deterministic customer-facing labels

Labels are a projection of those dimensions, in this precedence order:

1. Rejected, retracted, and superseded claims remain visible only as history.
2. An active contradiction is **contested**.
3. Human-confirmed, non-conflicting evidence is **confirmed**.
4. Direct evidence-backed statements are **heard**.
5. Derived evidence-backed claims are **inferred**.
6. Recommendations and hypotheses are **suggested**.
7. Missing evidence, low confidence, an unresolved speaker, or stale evidence adds **needs validation**.

Confidence alone can never produce **confirmed**.

Provider-selected labels and confidence remain proposal metadata. Claim extraction always enters the live projection and canonical journal as **suggested / needs validation**; only a deterministic evidence rule or an explicit Scout review event may promote it. Relationship projections retain the same origin, validation state, supporting claims, and evidence identifiers through replay, graph presentation, and Codex handoff.

## The correction loop

Every graph node, edge, insight, and opportunity can reveal its supporting claim and exact source. A customer correction appends a validation or revision event. It never deletes the original observation or silently changes the record.

The live experience must make these actions easy:

- “Show source” jumps to the exact utterance, audio range, or image region.
- “That is not what I meant” disputes the claim while preserving evidence.
- “That is correct” records confirmation and the confirming participant.
- “Speaker 2 is Priya” resolves identity without rewriting old utterances.
- “That was a future idea” changes world scope from current to proposed through a revision.

## Consent and retention

- Capture is visibly off by default and requires a deliberate start action.
- Recording state remains continuously visible; pausing creates an explicit gap event.
- The session records capture scope: microphone, selected system audio, images, and imported documents.
- Raw PCM is transient and memory-only in the current build; finalized evidence-linked utterances are
  encrypted locally and follow the engagement retention policy.
- Derived claims retain provenance tombstones when source evidence is deleted under policy.
- Context packs exclude raw audio, unrestricted transcripts, and personal data unless explicitly approved.
- Approved context packs contain only the selected POC, its factual claim and graph dependency closure, and explicit read-only guardrails. Unrelated claims, entities, relationships, questions, and opportunities stay in Scout.
- Context packs exclude original and normalized image bytes by default. Visual observations retain the SHA-256 of the exact normalized evidence asset, while asset retention remains a separate local policy.
- Per-engagement encryption keys and key-shredding deletion are a future requirement. The current
  journal uses one device-bound event-store key.
