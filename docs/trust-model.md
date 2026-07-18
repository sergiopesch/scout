# Trust is a product surface

Scout earns trust only when the state shown to an operator matches the state the deterministic domain
model can validate and replay. This document separates the current contract from the intended product
direction so that future-facing UX copy is not mistaken for an implemented guarantee.

## Implemented trust contract

Each canonical claim currently records:

- **Origin:** heard, observed, inferred, suggested, confirmed, or corrected.
- **Validation:** unreviewed, needs validation, validated, disputed, or rejected.
- **Confidence:** capture or model certainty in integer basis points; never a truth score.
- **Rationale:** an optional explanation for the trust assessment.
- **Lifecycle:** proposed, accepted, rejected, or superseded.
- **Provenance:** zero or more evidence identifiers and an optional asserted-by speaker identifier.

The reducer and command-authorisation boundary enforce the combinations that can be committed by each
actor. Model projections enter as suggested proposals, bind to a recorded model-call receipt, and may
not manufacture human confirmation. Accepting or rejecting a claim or visual observation requires a
fresh device-owner review capability for that exact, still-current decision. Legacy terminal reviews
remain replayable but are visibly unauthenticated until separately attested.

The customer-facing label is a projection of this data. Confidence alone never produces
**confirmed**. Rejected and superseded material remains in the append-only history, even when it is not
part of the active projection. Relationships retain their supporting claim and evidence identifiers
through replay and handoff.

## Implemented correction loop

The current native review surface supports authenticated accept/reject decisions for claims and visual
observations. Corrections append new events; they never rewrite an earlier utterance, evidence record,
model receipt, or review. A new proposal can explicitly supersede an older claim while preserving both
records.

Evidence navigation currently resolves a claim to its immutable evidence identifiers and stored
excerpt/source locator. Utterance, image, document, manual-note, and external-reference sources are
represented, but exact audio time ranges and image-region coordinates are not yet first-class evidence
fields.

## Transcript durability is explicit

Transcript finality and durable evidence are separate states. A final provider candidate first appears
as **Stabilising** while Scout validates immutable capture timing and appends it. **Committed** means the
exact utterance revision is present in the encrypted canonical journal. **Uncommitted** means timing or
append failed: the row remains visible for operator recovery, never feeds claims or handoff, and an
always-visible warning remains present even when destination controls are hidden. A later diarization
revision receives its own operation identity so a stale persistence completion cannot relabel a newer
row.

Archive navigation also follows the authoritative lifecycle rather than optimistic UI state. It asks
the live coordinator to cancel an in-flight start or stop producers and drain active transcripts; the
UI remains listening until the coordinator completes. Demo playback is the only locally stopped path.

## Product targets that are not yet implemented end to end

The following are design requirements, not current operational claims:

- a first-class conflict state with deterministic contested/resolved projection;
- evidence-availability states such as offline, policy-removed, or corrupt;
- participant/candidate/anonymous speaker-resolution state and append-only speaker mapping;
- a dispute/retract interaction in the native review surface;
- world-scope revisions for current, proposed, hypothetical, and historical statements;
- exact “show source” navigation to an audio range or image region;
- durable capture-scope and pause-gap events;
- retention tombstones for evidence removed under policy; and
- participant identity attached to a confirmation event.

Until those contracts exist in `ScoutCore`, presentation copy, evaluations, and handoffs must describe
them as proposed capabilities. They must not infer a conflict from confidence, silently resolve
stakeholder disagreement, or claim that an operator action was recorded when no canonical event exists.

## Consent, retention, and export boundaries

- Capture starts only after a deliberate operator action and its active state remains visible.
- Raw PCM is transient and memory-only in the current implementation.
- Successfully committed finalized utterance revisions and evidence excerpts are encrypted in the
  local append-only journal; uncommitted transcript rows are UI recovery state, not evidence.
- Approved context packs exclude raw audio, unrestricted transcripts, original or normalized image
  bytes, secrets, and personal data by default.
- An approved pack must contain only the selected POC and its validated dependency closure, with
  explicit acceptance criteria, constraints, redaction metadata, and canonical evidence references.
- Visual observations retain the hash of the normalized evidence asset; asset retention remains a
  separate local policy.
- Per-engagement encryption keys, key-shredding deletion, and automated migration of pre-encryption
  journals remain future requirements. The current journal uses one device-bound event-store key.
