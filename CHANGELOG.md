# Changelog

All notable Scout milestones are recorded here. Dates use ISO 8601.

## 0.1.0 — 2026-07-17

### Added

- Native macOS live-discovery cockpit with microphone/system capture, transcript, customer graph,
  trust inspection, proactive questions, visual evidence, quick wins, and action-pack approval.
- Pure Swift event/evidence/claim/graph domain and encrypted hash-linked SQLite persistence.
- Trusted OpenAI Gateway for Realtime transcription, diarization, structured claim extraction, and
  bounded image observations.
- Immutable selected-POC context packs, Gateway HMAC approval, revision lineage, and read-only stdio
  MCP handoff to Codex.
- Device-local Keychain migration, approval-key rotation with retained verification keys, and
  per-package Keychain namespaces.
- Portable outer launcher app with embedded self-contained Node/Gateway runtime, sandboxed nested UI,
  ephemeral local credentials, peer attestation, ZIP/DMG generation, SBOM, signing, notarization, and
  stapling automation.
- Packaged offline boundary smoke and opt-in real OpenAI two-speaker synthetic-discovery smoke.
- Logo-derived, accessibility-aware Liquid Glass shell with a deterministic tab controller, command
  palette, exact Scout-window lifecycle controls, and dedicated transcript, evidence, action-pack,
  and controller scenes. Screen observation and Accessibility control remain separate, explicit
  opt-in capabilities and are not required to operate Scout-owned surfaces.
- Bounded verified SQLite replay snapshots with cross-process `data_version` invalidation and
  transactional head rechecks. An aggregate LRU caps snapshots at 8 streams, 8,192 events, and a
  conservative 64 MiB retained-byte proxy. The deterministic persistence workload reduced full graph
  replays from 42 to 1 while retaining force-verification and append-after-commit guarantees.
- Explicit transcript durability states (`Stabilising`, `Committed`, and `Uncommitted`) with an
  always-visible persistence warning, operation-bound diarization revisions, and regression coverage
  for detached/compact layouts.
- Authoritative archive navigation that cancels in-flight live startup or stops and drains active
  capture before the coordinator publishes paused; demo playback remains locally controlled.

### Operations

- Prepared the source repository for public security review under an all-rights-reserved Scout license
  with explicit third-party exceptions, complete pinned Gateway dependency license texts, private
  vulnerability reporting, and sanitized audit-host metadata.
- Pinned GitHub Actions and the Node/XcodeGen toolchain, added full-history Gitleaks CI, expanded
  CODEOWNERS, and added release linting for workflow syntax, action SHAs, package-script syntax, and
  generated legal notices.
- Hardened packaging with strict mode/version/build validation, output containment, clean-source
  checks both before build and before signing, ignored build-specific SBOM generation, deterministic
  dependency notices, and manifest hashes for every dependency/provenance resource.
- Closed launcher child environments, authenticated every secret mutation/export used by development,
  removed plaintext import/export from production launchers, and made Gateway/UI exit supervision
  bidirectional.

### Security

- Closed model trust promotion, relationship-provenance loss, overbroad handoff, approval TOCTOU,
  forged approved packs, MCP loopback impersonation, and native bridge impersonation findings.
- Added a schema-v1.3 command authorization boundary: canonical stores accept only opaque validated
  events, model projections require exact receipts and suggested trust, and legacy schemas are
  replay-only for new writes. Model evidence is input-boundary checked, and proposals cannot mutate
  reviewed, deterministic, retired, removed, or transitively protected graph state. Evidence recorder
  and model speaker attribution are now derived or verified against canonical state.
- Added schema v1.4 exact model projections and authenticated local review. Each new model receipt
  commits a contiguous atomic sequence of at most 512 derived events; append and offline replay reject
  missing, extra, reordered, or substituted entries. The public local-review command is removed:
  macOS device-owner authentication now mints an opaque capability for one current target revision and
  operation, and append revalidates its state binding, five-minute age, and single use. Store-time
  freshness checks, cancellation-safe authentication/journal locking, monotonic stream schemas, and
  append-only re-attestation close downgrade and delayed-commit paths. Schema v1.0-v1.3 history
  remains replayable but is visibly unattested and excluded from build-ready handoff until reviewed.
  Compatibility/demo claims now fail closed to legacy assurance, and in-flight review prompts recheck
  the active session before any authenticated append or UI projection.
- Provider retries now regenerate the exact projection from its original base and expose only
  canonical replay state to the UI. Image observation commits rebind persisted asset identity, media
  type, content hash, dimensions, byte count, and provider response identity before accepting a retry.
