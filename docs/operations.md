# Scout operations guide

## Purpose

This guide covers local development, packaged execution, data locations, secret provisioning,
observability, recovery, and incident-safe shutdown. It deliberately avoids customer-specific content.

## Development lifecycle

```sh
make bootstrap
make run
```

The launcher performs this sequence:

1. Ensure the native Keychain tool and Gateway bundle are built.
2. Read the OpenAI key and approval keyring from device-local Keychain.
3. Generate a fresh Gateway bearer, independent approval token, and instance identifier.
4. Start Gateway on loopback port `0` and wait for a strict readiness event.
5. Start Scout UI without the OpenAI or approval HMAC keys.
6. Require an unauthenticated instance-ID health probe before adding the Gateway bearer.
7. Terminate Scout if Gateway exits and terminate Gateway when Scout exits.

The app must be started through `make run` during development. Opening the generated inner Scout app
directly intentionally fails closed because no supervised bridge identity exists.

## Secret setup

Put `OPENAI_API_KEY` in `.env.local` only for the first migration, then run:

```sh
make configure-secrets
```

The command imports the provider key, imports or creates the approval keyring, removes secret lines
from `.env.local`, and sets the file to owner-only permissions. Confirm configuration without exposing
values:

```sh
.build/tools/scout-launcher secrets status
```

See `docs/key-management.md` for rotation and recovery.

## Data locations

Development defaults:

- Event journal: `~/Library/Application Support/Scout/scout-events.sqlite3`.
- Context packs: `Gateway/context-packs/` unless `SCOUT_CONTEXT_PACK_DIR` is configured.
- Keychain service: `dev.scout.discovery.gateway-secrets`.

Packaged defaults:

- Event journal: the sandbox container selected by macOS for `dev.scout.discovery`.
- Context packs: `~/Library/Application Support/Scout/context-packs/`.
- Keychain service: `dev.scout.discovery.gateway-secrets.<ScoutKeychainNamespace>`.

Context packs and journals are customer data. Do not attach them to issues, commits, CI artifacts, or
support tickets. Raw audio is transient and is not retained by the current implementation.

## Capture operations

- Confirm meeting consent before starting capture.
- Select only the intended meeting window/application for system audio.
- Verify the visible capture state and pause when the conversation leaves approved scope.
- Treat diarized speaker labels as provisional until a participant confirms identity.
- Use Show Source before validating any claim that affects a POC or customer commitment.

## Health and failure behavior

`GET /health` is the sole unauthenticated Gateway route. A packaged/supervised instance returns
`X-Scout-Gateway-Instance-ID`; the UI compares it to the per-launch identity before sending a bearer or
customer payload. A mismatch, missing header, process exit, timeout, invalid readiness line, remote
bind attempt, or context-pack integrity error fails closed.

Gateway logs contain request IDs and bounded error metadata. They must never contain provider keys,
approval keys, raw audio, transcript bodies, source image bytes, or full context packs.

## Recovery

- Gateway interruption: stop capture, relaunch through the supervisor, and rely on journal replay.
- App interruption: relaunch; the encrypted append-only journal verifies and rebuilds projections.
- Provider interruption: the final uncommitted raw turn cannot be replayed because raw PCM is not
  retained. Resume capture and explicitly restate missing evidence.
- Context-pack conflict: refresh the session head, stage a new exact revision, and reapprove. Never
  overwrite a pack or skip a revision.
- Keychain failure: stop capture and handoff. Do not fall back to plaintext files; follow the recovery
  procedure in `docs/key-management.md`.

## Operator commands

```sh
make check                 # all deterministic repository gates
make package-smoke         # packaged runtime, Keychain, attestation, authenticated read
make live-smoke            # plus one real OpenAI two-speaker claim extraction
make rotate-approval-key   # retain old verification keys and activate a new signer
make clean                 # remove generated build/release output only
```

## Known operational boundaries

- A Developer ID identity and notary profile are external Apple account prerequisites.
- Per-engagement event-store key shredding is not implemented.
- Approval-key revocation is confirmation-gated and immediately invalidates packs signed by that key;
  inventory and reapproval remain operator responsibilities.
- Automatic migration of pre-encryption journals is not implemented.
- First-time release onboarding currently uses the signed launcher's hidden terminal prompt; a native
  onboarding UI is future work.
