# Scout

Scout is a Mac-first real-time discovery engine for forward-deployed teams. It turns a live customer
conversation into an evidence-linked model of the organisation, then hands a deliberately approved,
build-ready context pack to Codex.

Scout is not a meeting note taker or a copilot persona. Its governing rule is:

> OpenAI proposes. Scout validates, versions, stores, and explains. Codex builds from approved context.

## What Scout does

1. Captures an explicitly selected microphone and, for online meetings, system-audio source.
2. Produces low-latency transcription and versioned diarization refinements.
3. Records immutable evidence before accepting structured claim proposals.
4. Reduces valid claims into a replayable customer graph covering people, systems, data, processes,
   policies, constraints, goals, actions, and value.
5. Shows source, confidence, epistemic state, contradictions, missing information, and suggested next
   questions while the customer is present.
6. Stages one exact POC dependency closure for approval, cryptographically binds it to journal and
   context-pack history, and exposes only the approved result to Codex over stdio MCP.

## Current status

The repository contains a production-shaped macOS slice, not a hosted multi-tenant service.

- Native SwiftUI cockpit, deterministic Swift domain core, encrypted SQLite journal, trusted Node
  Gateway, and Codex plugin are implemented.
- Device-local Keychain owns the OpenAI credential and approval signing keyring. Secrets are absent
  from `.env.local`, Scout.app, logs, context packs, and MCP output after migration.
- A portable outer app packages and supervises a self-contained Node/Gateway runtime and launches the
  sandboxed Scout UI with ephemeral local credentials.
- Ad-hoc ZIP and DMG packaging, code-sign verification, packaged peer/auth smoke, and a real OpenAI
  two-speaker synthetic-discovery smoke pass on Apple silicon.
- Developer ID notarization automation is implemented but cannot be executed on a machine without an
  installed Developer ID Application identity and notarytool Keychain profile.

## Quick start

Requirements: macOS 15+, Xcode/Swift 6, XcodeGen, and Node.js 22+.

```sh
cp .env.example .env.local
# Add OPENAI_API_KEY to .env.local once.
make bootstrap
make run
```

`make bootstrap` installs pinned Gateway dependencies, migrates the OpenAI key into device-local
Keychain, creates the approval keyring, removes secret lines from `.env.local`, and generates the
disposable Xcode project. `make run` starts a Gateway on an OS-assigned loopback port with fresh
credentials, authenticates that exact child before customer bytes leave the app, and supervises both
processes as one lifetime.

Run the complete local gate with:

```sh
make check
```

## Packaging

A release must use a self-contained arm64 Node binary whose non-system dylib list is empty.

```sh
export SCOUT_RELEASE_NODE=/absolute/path/to/self-contained/node
export SCOUT_RELEASE_VERSION=0.1.0
export SCOUT_BUILD_NUMBER=1
make package
make provision-package
make package-smoke
make live-smoke       # makes a small real OpenAI request
```

For Developer ID signing and notarization:

```sh
export SCOUT_RELEASE_NODE=/absolute/path/to/self-contained/node
export SCOUT_NODE_LICENSE_PATH=/absolute/path/to/node/LICENSE
export SCOUT_SIGNING_IDENTITY='Developer ID Application: Example Company (TEAMID)'
export SCOUT_NOTARY_PROFILE=scout-notary
export SCOUT_RELEASE_VERSION=0.1.0
export SCOUT_BUILD_NUMBER=1
make notarize
```

The release workflow fails closed if the Node runtime has external non-system dylibs, the signing
identity/profile is missing, notarization fails, stapling fails, Gatekeeper rejects the app, or strict
code-sign verification fails. See [the release guide](docs/release.md).

## Repository map

- `ScoutApp/` — native capture, trust experience, graph, evidence review, and handoff UI.
- `Packages/ScoutCore/` — pure event, evidence, claim, graph, trust, replay, and reducer contracts.
- `Packages/ScoutPersistence/` — encrypted append-only SQLite storage and verified replay.
- `Gateway/` — OpenAI relay, approval authority, context-pack store, and stdio MCP implementation.
- `Tools/ScoutLauncher/` — native Keychain, runtime supervision, package smoke, and live-smoke boundary.
- `Plugins/scout/` — Codex plugin and build-from-approved-discovery workflow.
- `Scripts/` and `Packaging/` — development launch, portable packaging, signing, and provisioning.

## Documentation

- [Architecture](docs/architecture.md)
- [Trust model](docs/trust-model.md)
- [Security policy and threat model](SECURITY.md)
- [Operations guide](docs/operations.md)
- [Key management and rotation](docs/key-management.md)
- [Release and notarization](docs/release.md)
- [Verification record](docs/verification.md)
- [Evaluation gates](docs/evaluation.md)
- [Architecture decisions](docs/adr/README.md)
- [Contributing](CONTRIBUTING.md)

## Non-negotiable boundaries

- The append-only event log is canonical; every other view is rebuildable.
- Evidence, utterances, claims, graph state, and visual projections remain distinct layers.
- Models propose structured data. Deterministic Scout code validates and commits state.
- Every active factual claim resolves to immutable evidence; contradictions coexist until reviewed.
- Approval covers exact staged bytes and a selected POC closure, not a mutable workspace snapshot.
- Raw audio, unrestricted transcripts, and source image bytes are excluded from Codex handoff.
- Secrets never enter Swift source, app resources, generated context packs, or repository history.

No public project license has been selected. Keep the repository private until the owner chooses one.
