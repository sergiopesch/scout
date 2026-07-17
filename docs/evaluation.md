# Scout evaluation gates

Scout is not ready because a demo looked convincing. Every intelligence boundary must pass a versioned evaluation set before its model, prompt, schema, or reducer version becomes the default.

## Golden sessions

Maintain consented, de-identified sessions representing:

- two and three speakers with interruptions and cross-talk;
- mixed microphone and system audio;
- introductions, ambiguous speaker identity, and later identity correction;
- acronyms, product names, non-native accents, and code-switching;
- conflicting stakeholder accounts;
- current-state, target-state, hypothetical, and historical statements;
- compliance constraints and deliberately missing information;
- whiteboards with dense handwriting and partial occlusion;
- network loss, pause/resume, provider retries, and late responses.

Every fixture includes immutable audio/image hashes, manually reviewed utterances, speaker segments, atomic claims, evidence spans, expected conflicts, graph patches, gaps, and forbidden inferences.

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
| System | p50/p95/p99 latency, reconnect recovery, replay hash stability, cost per meeting hour |

## Release-blocking properties

- A model cannot mutate graph state without a validated recorded proposal.
- Every active factual claim resolves to retained evidence.
- A compound claim is split or rejected.
- An invalid operation rejects its entire graph patch.
- Conflicting claims are retained and rendered contested.
- The same event bytes produce the same terminal graph hash across locale, timezone, and wall-clock changes.
- Replaying from a verified snapshot equals full replay.
- Duplicate provider deliveries are idempotent.
- Unsupported semantic event versions halt at the preceding verified sequence.
- Missing score inputs stay unknown; they cannot accidentally create a quick win.
- A compliance or security blocker prevents quick-win classification.
- Context-pack redaction failures block Codex handoff.

## Change protocol

Pin model snapshot, prompt version, JSON Schema version, reducer version, and scoring policy in every evaluation run. Compare candidates against the currently released baseline. Promote only when critical safety/trust metrics do not regress and the intended quality or latency gain is statistically meaningful.

Store raw model output hashes and refusal/error classes, not secrets. Replay tests consume recorded responses and never call OpenAI.
