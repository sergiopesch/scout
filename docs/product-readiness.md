# Product readiness audit

Reviewed 2026-07-18. This is the source tree's operational ledger, not a certification, customer
reference, market-share study, or promise that every enterprise method and platform is implemented.

## Executive decision

Scout is a credible, production-shaped local product with strong deterministic trust boundaries and a
fully passing source gate. It is not yet a production-certified release. The append-only domain,
encrypted journal, model-proposal boundary, local review, bounded handoff, native cockpit, Gateway,
Codex plugin archive, and HTML story are implemented and tested. Ed25519 verification-only handoff,
decoder-grade WAV admission, and a versioned evaluation harness are now implemented. Current release
blockers are a fresh signed package/live-provider run, real capture/accessibility validation, and the
first consented, de-identified model-quality corpus run.

Health labels used below:

- **Operational** — implemented and exercised by the current automated gate.
- **Conditional** — implemented substantially, but an environment/manual boundary or material gap
  prevents a production claim.
- **Not implemented** — represented only in product direction, documentation, or a fictional demo.

## End-to-end product storyline

| Step | Customer experience | Health | Current evidence and boundary |
| ---: | --- | --- | --- |
| 1 | Create a discovery session | **Operational** | The sidebar creates one selected, clean draft with aligned session/evidence IDs; transition races are disabled and tested. Durable multi-session catalogue/reopen is still conditional. |
| 2 | Select in-room or meeting capture | **Conditional** | Microphone/system-audio adapters, permission copy, source scoping, cancellation, partial rollback, and drain are implemented. Real signed permission and ambient-capture tests were not run in this audit. |
| 3 | See low-latency transcription | **Conditional** | Exact PCM timing, bounded frames, stable item reconciliation, and `gpt-4o-mini-transcribe` configuration are tested. Current live-provider/reconnect evidence is missing. |
| 4 | Refine speakers with diarization | **Conditional** | The Gateway admits only exact mono 24 kHz PCM16 WAV, validates decoded frames/duration before provider use, and bounds returned segments. A dedicated durable diarization model-call receipt and real-session validation remain open. |
| 5 | Preserve immutable evidence | **Operational** | Canonical, hash-linked events and encrypted SQLite replay pass sequence, concurrency, corruption, idempotency, and restart tests. Per-engagement key shredding is not implemented. |
| 6 | Turn evidence into claims | **Operational** | Strict provider schemas, input boundaries, exact projection manifests, deterministic planning, and atomic append prevent model output from directly becoming trusted state. |
| 7 | Review claims and observations | **Operational** | Accept/reject/re-attest operations bind a fresh device-owner capability to one current target. Device-owner auth means the signed-in device owner, not a named participant. |
| 8 | Explore the customer graph | **Conditional** | Claims and relationships preserve provenance and contradictory scalar claims coexist. First-class contested/resolved state, collision-free edge labels, and exact source-region navigation are not complete. |
| 9 | Import visual evidence | **Conditional** | Native ImageIO normalization, metadata stripping, hashing, Gateway rechecks, and evidence-linked proposal cards are tested. Proposals intentionally cannot promote into graph truth yet. |
| 10 | Surface gaps and opportunities | **Conditional** | Deterministic questions and evidence-weighted quick wins are tested. Normal live refresh does not yet complete every action artifact; the full transformation is currently most visible in the fictional demo. |
| 11 | Select and approve one POC | **Operational** | Approved export fails closed unless every selected accepted claim carries canonical evidence IDs and an exact journal head; the Gateway signs the exact binding with its Keychain-backed Ed25519 seed. |
| 12 | Build from Scout in Codex | **Conditional** | The plugin validates, starts standalone, is read-only over stdio, and carries deterministic notices/SBOM. It verifies with published public keys only. A fresh packaged end-to-end run remains open. |
| 13 | Install a production release | **Not implemented as current evidence** | Packaging/notarization automation exists, but no post-fix Developer ID/notarized/clean-Mac package was produced during this audit. |

## Claims checked against implementation

| Foundation or capability | Assessment |
| --- | --- |
| Append-only event log is canonical | **Operational.** Stores accept validated events; replay verifies canonical bytes, sequence, previous hash, authorization, and reducer invariants. |
| OpenAI proposes; Scout commits | **Operational.** Strict adapters and exact manifests separate untrusted model responses from canonical writes. |
| Every active factual claim resolves to evidence | **Operational at canonical commit/handoff boundaries.** The UI now reports unresolved canonical evidence instead of claiming every displayed/demo claim is source-linked. The exporter still depends on replay-supplied evidence maps rather than independently querying the journal. |
| Contradictions coexist | **Partly operational.** Conflicting scalar claims remain append-only; automatic detection and a first-class contested/resolved projection do not exist. |
| Customer content is encrypted locally | **Operational in the product path.** The app supplies a device-bound key; the public persistence adapter still permits `nil` encryption for tests/other callers. |
| Gateway is a trusted local relay | **Operational.** Loopback/auth/schema boundaries and exact peer attestation are tested. Realtime upstream output needs a stricter allowlist. |
| Secrets never enter the app bundle/context | **Operational in tested launch/package code.** Child environments are closed and distributable plaintext export/import commands are unavailable. A fresh packaged inspection is still required. |
| Context packs are approved, immutable, and minimized | **Operational in the source gate.** Closure, hashes, session head, redaction fields, canonical evidence, immutable files, and Ed25519 signer/verifier separation are checked. |
| The product works across real meetings | **Not proven in this audit.** Automated lifecycle coverage is strong, but real mic/system audio, provider reconnect, duration, accents, crosstalk, and consent flows require the golden corpus and signed runtime. |

## Improvements completed in this audit

- Closed launcher environment/endpoint injection paths and authenticated all remaining secret mutation.
- Added bidirectional Gateway/UI supervision and safe packaged secret-tool boundaries.
- Made context-pack storage reject symlink/canonical escapes and repair owner-only permissions.
- Made the plugin start from an archive shape without repository source or Keychain shell-outs.
- Replaced the unsupported realtime transcription default with a currently documented model.
- Serialized capture start/stop, cancellation, rollback, and drain ownership.
- Made approved context export fail closed on missing canonical evidence.
- Added exact claim selection so two claims on one entity cannot silently show the wrong evidence.
- Replaced fabricated health/latency and unconditional source-link UI with derived operational states.
- Added explicit fictional-demo labeling and clean new-session behavior.
- Made Accessibility copy accurately describe permission preflight, not an implemented action adapter.
- Rewrote the HTML story so fictional evidence, proposed state, PII gaps, estimates, and approvals remain
  visually distinct; fixed responsive, focus, inert-slide, notes, overview, and replay behavior.
- Added deterministic plugin licence, third-party notices, exact SBOM, and archive verification.
- Added a sourced enterprise-context/asset policy that is optional vocabulary, never customer evidence.

## Prioritized remaining work

### Release blockers

1. Produce a fresh self-contained package, provision it through the authenticated flow, run offline
   and live synthetic smokes, inspect bundle/log/context outputs for secrets, then Developer ID sign,
   notarize, staple, Gatekeeper-test, and install on a clean Mac.
2. Run real microphone and explicitly selected system-audio sessions with informed consent, network
   interruption, pause/resume, long duration, and device-owner review.
3. Complete the consented, de-identified golden manifest and run the versioned scorer against privately
   held audio/image media as specified in `evaluation.md`.

### Product-quality blockers

1. Add a durable session index/completion/reopen workflow instead of the current seeded/static history.
2. Derive all action artifacts from current canonical state; remove demo-only readiness transitions.
3. Add collision-aware graph layout/edge labels, fit-to-content, and a nonvisual relationship ledger.
4. Add first-class conflict, evidence-availability, speaker mapping, world-scope, capture-gap, and
   retention-tombstone events before claiming those experiences.
5. Replace 7–11 point fixed typography with a legible semantic type scale; adapt Action Pack and
   evidence layouts to minimum windows; complete VoiceOver/focus/keyboard/contrast/reduced-motion QA.
6. Add a bounded external-action adapter before describing Accessibility permission as control.
7. Require an explicit plaintext-test mode in the public persistence adapter and add anti-rollback
   anchoring/freshness for restored encrypted databases.

## Product assets and enterprise context

The repository contains Scout-owned app icons, in-app mark variants, plugin logo/composer icon,
fictional product screenshots, licence/notice files, and an SBOM. The
[asset registry](asset-registry.md) records ownership, source, checksum, variants, alt text, permitted
surfaces, approval owner, and review triggers for every committed visual asset. Dedicated light,
dark, monochrome, and small-size optical variants remain a binary-release product-quality gate; they
do not block public inspection of the source tree. Do not generate a vendor-logo wall.

Enterprise knowledge belongs in a small, dated registry of original Scout summaries and authoritative
links. The current taxonomy covers outcomes, stakeholders, capabilities/domains, processes, systems,
integrations, data, architecture, security/privacy/AI, delivery/operations, commercial constraints,
and handoff. Representative platform names are discovery aliases only; they are not evidence that a
customer uses a product and not a claim about “most Fortune 500 companies.”

Methods such as medallion/progressive data quality, data mesh, domain-driven design, event-driven
architecture, C4-like views, DORA, SRE, FinOps, agile delivery, security frameworks, and AI governance
must remain conditional lenses. Bundle only Scout-owned/licensed assets; link third-party knowledge;
accept customer/vendor assets only with authority, provenance, retention, and redaction controls. See
[Enterprise context policy](enterprise-context.md) for the dated sources and legal posture.

## Evidence limits

Passing tests prove the checked contracts, not meeting-level comprehension, legal compliance,
production availability, market adoption, accessibility conformance, or certification. Fictional demo
content and presentation simulations are UX fixtures. Historical package/live-smoke results are not
substitutes for a newly built artifact from the current source.
