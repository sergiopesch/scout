# Scout evaluation gates

Scout is not ready because a demo looked convincing. Every intelligence boundary must pass a versioned evaluation set before its model, prompt, schema, or reducer version becomes the default.

The repository now contains a deterministic scorer, schema/version checks, release thresholds, a
synthetic contract corpus, and a privacy-safe manifest template. Run the infrastructure gate with:

```sh
make evaluation-test
make evaluation-contract
```

The synthetic corpus proves scorer and fail-closed threshold behavior; it is not customer or
model-quality evidence. A real run must use a consented, de-identified manifest whose media entries
carry immutable SHA-256 digests and resolve through the explicit private media root:

```sh
node Scripts/run-evaluation.mjs \
  --manifest Evaluation/corpus/golden-v1/manifest.json \
  --results /private/path/results.json \
  --media-root /private/path/media
```

Raw audio and images remain ignored local inputs and must never enter Git, CI artifacts, context
packs, or Codex handoffs.

## Golden-session specification

The repository intentionally does not contain raw consented audio/image media. The versioned manifest
and expected annotations may be committed only after consent, de-identification, retention, and
licensing review; media stays in the approved private evaluation store. The deterministic and
synthetic suites are not a substitute for this corpus. Completing the first real manifest and signed
results run remains a production release gate.

Maintain consented, de-identified sessions representing:

- two and three speakers with interruptions and cross-talk;
- mixed microphone and system audio;
- introductions, ambiguous speaker identity, and later identity correction;
- acronyms, product names, non-native accents, and code-switching;
- conflicting stakeholder accounts;
- current-state, target-state, hypothetical, and historical statements;
- compliance constraints and deliberately missing information;
- whiteboards with dense handwriting and partial occlusion;
- network loss, pause/resume, provider retries, and late responses;
- omitted, extra, reordered, and substituted model-derived events;
- cancelled or delayed device-owner prompts, target changes during authentication, and attempted
  authorization reuse;
- legacy terminal claim and visual decisions that are re-attested without rewriting their original
  event, plus proposed and already-authenticated targets that must reject re-attestation;
- exact provider retries after unrelated later events, altered adapter projections using the same
  response metadata, and forged image evidence receipts.

Each future fixture must include immutable audio/image hashes, manually reviewed utterances, speaker
segments, atomic claims, evidence spans, expected conflicts, graph patches, gaps, and forbidden
inferences.

## Metrics

| Boundary | Primary measures |
| --- | --- |
| Live transcription | word error rate, entity recall, delta latency, finalization latency |
| Diarization | diarization error rate, speaker-count error, identity-resolution precision |
| Claim extraction | atomic-claim precision/recall, evidence-span precision, modality/world-scope accuracy |
| Entity resolution | merge precision, split recall, alias stability |
| Trust projection | label accuracy, missing-evidence rejection, conflict surfacing |
| Questions | gap coverage, redundancy, customer-rated usefulness |
| Opportunities | unsupported recommendation rate, rank agreement, blocker compliance |
| Context pack | redaction recall, manifest reproducibility, acceptance-criteria coverage |
| Canonical write authority | unauthorized-write rejection, manifest closure, review-grant binding |
| System | p50/p95/p99 latency, reconnect recovery, replay hash stability, cost per meeting hour |

## Release-blocking properties

- A model cannot mutate graph state without a validated recorded proposal.
- Every new schema-v1.4 model-call receipt carries a `DerivedEventManifest` for zero to 512 events.
  Its declared events must follow immediately in exact order and commit atomically with the receipt.
- Append and offline replay reject an incomplete, extra, reordered, or payload-substituted manifested
  projection without changing canonical state.
- Every active factual claim resolves to retained evidence.
- A compound claim is split or rejected.
- An invalid operation rejects its entire graph patch.
- Conflicting claims are retained and rendered contested. This property is not yet automated because
  the current domain model has no first-class conflict projection; it remains production-blocking.
- The same event bytes produce the same terminal graph hash across locale, timezone, and wall-clock changes.
- Replaying from a verified, schema-compatible snapshot equals full replay. Schema 1.3 and 1.4
  upgrades must use full journal replay until snapshot versions explicitly migrate command
  authorization, relationship tombstones, model-projection progress, proposal-event indexes, and
  consumed review authorizations.
- A schema-v1.4 local review without fresh macOS device-owner authentication is rejected. Mismatched
  event, session, target revision, state hash, operation, terminal decision, future timestamp, grant
  more than five minutes old, and reused authorization cases each fail closed.
- Freshness is checked at the actual store append boundary, not only when an event is sealed.
  Cancellation cannot mint a capability after the prompt completes or strand the journal's FIFO
  operation lock.
- Re-attesting a legacy terminal review appends a new event bound to the original review event and
  unchanged terminal state. It changes only the assurance projection. Proposed, missing, changed,
  or already-authenticated targets fail closed, and legacy acceptance remains excluded from a
  build-ready handoff until this event commits.
- Compatibility and demo claims without a replayed authorization project as legacy-unattested, never
  authenticated. If the active session changes or review work is cancelled while a device-owner
  prompt is suspended, the UI must not record the review or apply its projection to the new session.
- Schema-v1.0-v1.3 streams remain replayable under historical rules, while evaluation output labels
  them unattested for v1.4's exact-projection and device-owner-review guarantees.
- Event schemas never regress within a stream, and schema-v1.0-v1.2 authorization fields that were
  absent from their historical canonical hash are rejected rather than trusted.
- Duplicate provider deliveries are idempotent.
- A duplicate provider delivery is accepted only when regenerating from the original projection base
  yields the exact persisted receipt, manifest, event identifiers, payloads, and completed progress.
  Reusing a provider response identifier with altered claim or image output fails without changing
  canonical state.
- Unsupported semantic event versions halt at the preceding verified sequence.
- Missing score inputs stay unknown; they cannot accidentally create a quick win.
- A compliance or security blocker prevents quick-win classification.
- Context-pack redaction failures block Codex handoff.

## Change protocol

Pin model snapshot, prompt version, JSON Schema version, reducer version, and scoring policy in every evaluation run. Compare candidates against the currently released baseline. Promote only when critical safety/trust metrics do not regress and the intended quality or latency gain is statistically meaningful.

Store raw model output hashes and refusal/error classes, not secrets. Replay tests consume recorded responses and never call OpenAI.
