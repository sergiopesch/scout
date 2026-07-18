# Scout security model

## Overview

Scout is a privacy-sensitive macOS discovery engine. It captures deliberately selected microphone,
meeting, and image evidence; sends bounded inputs through a loopback-only trusted gateway to OpenAI;
builds an append-only evidence and claim history; and exports an explicitly approved, redacted context
pack to a read-only MCP surface for Codex.

The primary assets are customer conversation evidence, organizational architecture and process data,
speaker attribution, model-call provenance, context-pack approvals, the device-bound event-store key,
the local bridge bearer token, and the OpenAI API key. A compromise that silently changes what the
customer said, expands what Codex receives, or exposes provider credentials is more serious than an
ordinary UI failure.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/sergiopesch/scout/security/advisories/new).
If GitHub does not offer the private form, contact the
[repository owner](https://github.com/sergiopesch) without exploit details and request a private
channel. Do not open a public issue containing exploit details, credentials, customer evidence,
context packs, database files, or Keychain material. Include a synthetic reproduction, affected
commit, impact, and suggested embargo window when possible.

## Supported versions and response targets

Scout is pre-1.0 and currently supports only the latest commit on `main`; no public binary release is
supported yet. Security fixes are not backported unless a release notes otherwise. The project aims to
acknowledge a private report within three business days, provide an initial triage decision within ten
business days, and coordinate disclosure only after a fix or explicit risk decision. These are
best-effort targets, not a service-level agreement.

## Threat Model, Trust Boundaries, and Assumptions

The repository has six runtime boundaries:

1. The native outer launcher reads provider and approval secrets from device-local Keychain, starts the
   bundled Gateway with fresh credentials and an OS-assigned port, then starts the UI without those
   persistent secrets. It constructs closed child environments, pins the production provider endpoint,
   and supervises both children as one failure domain.
2. `ScoutApp` is a sandboxed native client operated by the signed-in Mac user. It may access only the
   microphone, explicitly selected screen/audio sources, explicitly selected files, the app Keychain
   item, local application support, and either the bundled loopback bridge or an explicitly configured
   HTTPS-compatible bridge.
3. The bundled `Gateway` is the only network process that uses provider credentials. It binds to loopback, authenticates every
   non-health HTTP and WebSocket request, validates bounded schemas, and communicates with OpenAI over
   HTTPS. The native app must never inherit `OPENAI_API_KEY`.
4. OpenAI responses are untrusted proposals. Provider text and speaker labels pass through strict
   schemas and deterministic commit planning before they can affect durable state. Image observations
   are retained only as evidence-linked proposal cards in the current build and have no graph-promotion
   path.
5. The encrypted append-only journal is authoritative. UI diagrams, questions, quick wins, and action
   packs are disposable projections over verified events.
6. The Codex plugin and stdio MCP process expose approved, immutable, evidence-minimized context packs
   only. They do not fetch Keychain material or provider credentials. They receive a versioned,
   non-secret Ed25519 public keyring from Application Support and have no signing capability. Missing,
   malformed, revoked, or mismatched verification material fails approved reads closed.

Meeting speech, transcribed text, filenames, imported pixels, visible whiteboard text, model output,
HTTP bodies, WebSocket frames, MCP arguments, and context-pack files are attacker-controlled inputs.
Capture-mode selection, POC selection, validation decisions, approval, retention, and deletion are
operator-controlled inputs. Source code, schemas, prompts, entitlements, dependency pins, and release
signing are developer-controlled inputs.

Scout assumes the local macOS account and OS security boundary are not already fully compromised, the
user understands the meeting-consent obligations that apply to their jurisdiction, OpenAI credentials
are scoped and revocable, and the provider TLS boundary is trustworthy. A root-level local attacker,
malicious signed replacement binary, or compromised operating system is outside this repository's
defensive scope, though device-bound encryption should still limit casual offline disclosure.

Security invariants:

- The OpenAI key exists only transiently in the native launcher and Gateway process; the UI, logs,
  URLs, app state, context packs, and Codex prompts must never contain it.
- The bundled gateway remains loopback-only and bearer-authenticated. There is no production override
  that permits remote binding; an explicitly configured compatible remote bridge must use HTTPS/WSS,
  reject URL credentials, and preserve the same authentication and validation contract.
- The UI performs an unauthenticated health probe and verifies the exact per-launch instance identity
  before adding a bearer or sending customer content. Fixed ports and bearer files are forbidden.
- Capture is off by default, visibly active, explicitly scoped, pausable, and bounded in memory and
  duration. A selected online source never broadens silently.
- Every durable factual claim resolves to immutable evidence. Inferred and suggested outputs remain
  visibly distinct from heard or human-confirmed facts.
- Claim-extraction and image-observation responses are recorded with their exact input boundary,
  versions, provider response ID, model, and output hash before any derived projection is committed.
- All event bodies are hash-linked, canonically encoded, reducer-validated, encrypted at rest with a
  non-synchronizing device-bound key, and replayable without contacting OpenAI.
- Native captured PCM validation enforces frame shape, sample rate, ordering, byte, and exact-duration
  bounds. Native image import enforces byte, frame, dimension, pixel, and decompression limits before
  normalization. The Gateway independently parses the exact RIFF/WAV structure and accepts only mono
  24 kHz PCM16 with a one-minute decoded-frame budget before invoking diarization.
- Context-pack approval is explicit, immutable, hash-verified, evidence-linked, and fail-closed when
  POC scope, constraints, success criteria, redaction state, or current session head is missing/stale.
- Gateway-minted approval uses a Keychain-backed active Ed25519 private seed. Retired private seeds
  are destroyed on rotation; verifiers receive only retained non-revoked public keys. Ordinary
  transport authentication and verification-only MCP processes cannot assert approval.
- Raw audio, normalized source images, unrestricted transcripts, personal data, secrets, and hidden
  instructions are excluded from Codex exports by default.

Current deployment boundaries:

- The journal uses one non-synchronizing, device-bound Keychain key for the app's event store. Scout
  does not yet provide per-engagement key shredding.
- There is no automatic migration for a database created before encrypted persistence was enabled;
  such stores must be exported or replaced through a deliberate operator procedure.
- Visual observations deliberately stop at proposal cards. Authenticated human accept/reject is
  implemented as append-only review evidence; promotion into the canonical graph remains future work.
- Diarization results are bounded and evidence-linked, but a dedicated durable diarization model-call
  receipt is future work; speaker labels therefore remain unconfirmed identities.
- Production Developer ID notarization remains an external release gate until a signing identity and
  notary profile are installed. Ad-hoc packages are local validation artifacts only.

## Attack Surface, Mitigations, and Attacker Stories

- A meeting participant can speak prompt-injection text or display hostile instructions in a
  whiteboard. Scout treats content as evidence data, constrains provider instructions and schemas, and
  requires deterministic validation plus human approval. Any path that executes those instructions,
  changes policy, invokes tools, or bypasses approval is reportable.
- A local process can probe the bridge. OS-assigned ports, per-launch instance attestation before
  authorization, closed child environments, a pinned production provider endpoint, ephemeral tokens,
  loopback binding, strict methods/content types, bounded requests, WebSocket limits, and supervised
  shutdown reduce the surface. Authentication bypass, customer bytes sent before peer attestation,
  token leakage, or a remote-bind path is reportable.
- Malformed audio or images can target native/provider parsers or exhaust resources. Native ImageIO
  preflight and normalization, structural Gateway JPEG verification, bounded multipart streaming,
  exact PCM/WAV parsing, local PCM segmentation, request timeouts, and provider response limits reduce
  the surface. Alternative codecs, extra chunks, forged lengths, trailing bytes, and overlong audio
  reject before the provider boundary.
- A crash, retry, or concurrent callback can target event ordering. SQLite `BEGIN IMMEDIATE`, expected
  stream versions, canonical idempotency hashes, a FIFO journal boundary, reducer invariants, and full
  replay verification prevent silent forks or partial graph commits.
- A malicious or stale context-pack file can target Codex. Immutable identifiers, canonical body
  hashes, graph hashes, referential checks, approved-only MCP reads, session-head metadata, and skill
  staleness checks must prevent substitution or silent downgrade.
- Filesystem symlinks, path traversal, oversized stores, or permissions mistakes can target evidence
  and context-pack storage. Runtime paths stay within controlled roots, selected images reject symlinks,
  sensitive directories/files use owner-only permissions, and raw assets are omitted from exports.
- Dependency or build compromise can affect the release. Dependencies are pinned, generated Xcode
  projects are disposable, the package carries a production SBOM and self-contained runtime,
  components are signed inside-out, and notarization/stapling/Gatekeeper failures block release.

Out of scope as standalone reports: a participant intentionally supplying false business information
that Scout labels as attributed evidence; the expected cost of sending operator-approved content to
the configured OpenAI project; denial of service that requires controlling the signed-in user's entire
machine; and UI disagreement with a fact when the durable evidence, trust label, and correction path
remain accurate. These can become reportable when a trust label, authorization boundary, or durable
record is bypassed.

## Severity Calibration (Critical, High, Medium, Low)

**Critical** issues permit remote or untrusted meeting/image content to execute code or tools with the
user's authority; expose the OpenAI key or device encryption key remotely; bypass context-pack approval
to cause Codex to build from attacker-controlled instructions; or silently rewrite/delete the canonical
evidence history across sessions.

**High** issues expose customer evidence outside the selected session or EU/engagement boundary;
allow an unauthenticated local process or browser to use provider-backed endpoints; permit remote
gateway binding; accept a forged approved context pack; break AES-GCM, event-chain, or reducer integrity;
or present an inferred/model-generated claim as heard or confirmed.

**Medium** issues allow bounded denial of service from one imported file or session, retain sensitive
assets beyond documented policy, leak transcript excerpts to logs, lose model-call provenance while
preserving evidence, misattribute a provisional speaker as a named person, or accept stale build context
while clearly showing that it is stale.

**Low** issues disclose non-sensitive model/routing metadata, weaken owner-only permissions on data that
is otherwise encrypted, produce misleading but non-authoritative UI metrics, or create local-only
availability/recovery friction without violating evidence, credential, approval, or tenant boundaries.
