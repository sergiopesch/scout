# Scout Gateway

The Gateway is Scout's trusted intelligence boundary. The supervised native launcher reads the provider
credential and approval keyring from device-local Keychain and passes them only to the Gateway child.
They are never returned to the macOS UI, logs, context packs, or Codex. `.env.local` contains only
non-secret development overrides after `make configure-secrets`.

## Run

The Gateway runtime supports Node.js 22 or later. Repository CI and release tooling deliberately pin
Node.js 24.14.0 so identical inputs use one recorded toolchain.

```sh
npm ci
npm run check
npm run build
```

Use `make run` from the repository root. It loads Keychain secrets, starts Gateway on an OS-assigned
loopback port, rotates both native credentials, passes the verified endpoint to Scout, and terminates
the app if its Gateway child exits. Running `npm run dev` directly does not provision the required
supervised credentials and is intended only for adapter-level debugging with an explicitly controlled
environment.

Supported configuration:

- `OPENAI_API_KEY` — required in the Gateway process; loaded from Keychain by the native launcher.
- `OPENAI_BASE_URL` — defaults to `https://api.openai.com/v1`; non-loopback HTTP is rejected.
- `OPENAI_REALTIME_MODEL` — transcription model inside the Realtime transcription session; defaults
  to `gpt-4o-mini-transcribe`. It is never used as the top-level Realtime session model.
- `OPENAI_DIARIZATION_MODEL` — defaults to `gpt-4o-transcribe-diarize`.
- `OPENAI_CLAIMS_MODEL` — defaults to the access-specific `gpt-5.6-luna` configuration exercised by
  the recorded packaged live smoke. Release operators must verify that exact model in the target OpenAI
  project; it is not presented here as a generally available public default.
- `OPENAI_VISION_MODEL` — optional image-observation model; defaults to `OPENAI_CLAIMS_MODEL`.
- `SCOUT_GATEWAY_TOKEN` — 32+ character local bearer token required for every non-health HTTP and WebSocket route.
- `SCOUT_GATEWAY_INSTANCE_ID` — per-launch identity returned only by the supervised Gateway instance and verified before the app adds its bearer or sends customer bytes.
- `SCOUT_APPROVAL_TOKEN` — independent, per-launch credential accepted only by the explicit approval route.
- `SCOUT_APPROVAL_ED25519_PRIVATE_KEY` and `SCOUT_APPROVAL_KEY_ID` — active Gateway-only Ed25519
  signer loaded from Keychain.
- `SCOUT_APPROVAL_PUBLIC_KEYS` — bounded JSON map of retained Ed25519 public verification keys. When
  absent, verification-only processes load `approval-public-keyring-v1.json` from `SCOUT_DATA_ROOT`.
- `SCOUT_CONTEXT_PACK_DIR` — must remain inside `SCOUT_DATA_ROOT`; development defaults to
  `Gateway/context-packs` and the packaged app uses Application Support.
- `SCOUT_GATEWAY_HOST` and `SCOUT_GATEWAY_PORT` — default to `127.0.0.1` and port `0` (OS assigned). The host is fail-closed to loopback; there is no non-loopback override for the desktop bridge.

## Boundaries

- `GET /health` is the only unauthenticated route. A supervised instance also returns its per-launch identity so the native app can authenticate the peer before sending a bearer or customer data.
- `WS /realtime` opens the provider's explicit transcription-intent session and proxies only
  transcription session updates and input-audio-buffer events. It enforces 24 kHz mono PCM, the
  server-selected transcription model, bounded frames, backpressure, and a 59-minute lifetime.
- `POST /v1/transcriptions/diarize` accepts only Scout's canonical mono 24 kHz PCM16 WAV, proves its
  RIFF/chunk/frame/duration structure within a one-minute decompression budget before the provider
  call, and returns a bounded diarization proposal. It always uses `diarized_json` and `chunking_strategy=auto`.
- `POST /v1/claims/extract` accepts bounded stabilized utterances and returns strict evidence-linked proposals. Model output is revalidated and unknown evidence references are rejected.
- `POST /v1/images/observe` is loopback-only and bearer-authenticated. It accepts one metadata-stripped JPEG (8 MiB, 4096 px per side, 16.7 MP), verifies the declared dimensions and SHA-256 against the bytes, and returns strict entity, relationship, and note proposals. Image text is treated as untrusted evidence, model persistence is disabled, sensitive attributes and face identification are prohibited, and no proposal mutates Scout state directly.
- `POST /v1/context-packs` is loopback-only and bearer-authenticated for drafts and already authenticated artifacts. It cannot turn `approved_at` into authority by itself.
- `POST /v1/context-packs/approve` additionally requires the independent per-launch approval credential. It verifies the immutable body and journal head, binds the exact revision and previous head, mints the Gateway Ed25519 signature, and then performs the per-session compare-and-swap write.
- `GET /v1/context-packs` exposes approved artifacts only, with optional `session_id`, `limit` (1–100), and opaque `cursor` pagination parameters. `GET /v1/context-packs/:context_pack_id` reads one approved artifact.
- MCP is stdio-only. The Scout plugin launches the archive-bundled process and owns its pipes; there
  is no pre-bindable TCP endpoint or MCP bearer. The archive resolves without repository files and does
  not query Keychain. It loads the launcher's non-secret published public keyring and therefore can
  verify approved reads but cannot mint an approval. Missing, malformed, or revoked verification
  material fails approved reads closed.

MCP tools are read-only: `scout_list_context_packs`, `scout_get_context_pack`, `scout_get_customer_model`, `scout_get_action_pack`, and `scout_get_session_head`. The session-head tool resolves the latest approved revision and graph digest so Codex can detect a stale handoff before building.

## Context-pack digest

The wire shape is `{ "schema_version": 1, "content_sha256": "…", "body": { … }, "approval": { … } }`. `content_sha256` is the lowercase SHA-256 of the `body` object alone, encoded exactly as Scout does: snake-case keys, recursively sorted object keys, preserved array order, no insignificant whitespace, and standard JSON scalar encoding. The Gateway recalculates the digest both on ingest and read. Approved packs additionally require a Gateway-authenticated binding over that digest, the canonical journal head, exact revision, approval timestamp, and previous context-pack head.

The body contract is closed. Trust and epistemic modes are `heard`, `inferred`, `suggested`, or `confirmed`; selected POCs are explicitly `suggested` or `confirmed`. Claims carry a stable evidence ID and optional related entity. Relationships carry their own epistemic mode, validation state, supporting claim IDs, and source evidence IDs; those references must resolve inside the pack. IDs are unique within each collection, and `graph_state_sha256` must match the canonical entities-and-relationships projection.

Approved handoffs are an exact authorization closure, not workspace snapshots. Their claims must equal the selected POC support set, relationships and entities must resolve from that set, open questions are excluded, and the only exported opportunity is the selected POC. The Gateway rejects any broader approved body even when its content hash is otherwise valid. Rotation signs new packs with the active private key, deletes the former private seed, and continues verifying old packs with retained public keys until an operator deliberately revokes one. Legacy HMAC approvals are not accepted and must be explicitly reapproved.

Raw audio, unrestricted transcript fields, API keys, and bundles claiming to include raw audio or unrestricted transcripts are rejected. Unapproved packs may be retained locally but are hidden from REST and MCP reads by default. Approved excerpts are represented as minimal evidence-linked claim excerpts, not unrestricted transcript dumps.

Raw whiteboard/photo bytes are deliberately absent from context packs. The macOS app normalizes an explicitly user-selected local image, strips metadata, corrects orientation, bounds decoded size, and hashes the exact normalized bytes before this endpoint sees them. Codex handoff may later include approved observations and the evidence digest, but not the original or normalized image payload by default.
