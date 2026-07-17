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

### Security

- Closed model trust promotion, relationship-provenance loss, overbroad handoff, approval TOCTOU,
  forged approved packs, MCP loopback impersonation, and native bridge impersonation findings.
