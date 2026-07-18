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
5. Shows source, confidence, epistemic state, missing information, and suggested next questions while
   the customer is present. Contradictory claims are retained; automatic conflict detection and a
   first-class contested/resolved view are not implemented yet.
6. Stages one exact POC dependency closure for approval, cryptographically binds it to journal and
   context-pack history, and exposes only the approved result to Codex over stdio MCP.

## Current status

The repository contains a production-shaped macOS slice, not a hosted multi-tenant service.

- Native SwiftUI cockpit, deterministic Swift domain core, encrypted SQLite journal, trusted Node
  Gateway, and Codex plugin are implemented.
- The cockpit now uses a logo-derived, accessibility-aware glass command shell with deterministic
  tabs, a command palette, dedicated workspace/controller/transcript/evidence/action-pack windows,
  and exact lifecycle control over registered Scout-owned windows.
- Screen observation and Accessibility control are separate, explicit opt-in capabilities. Scout's
  own tabs and windows need neither permission; external application automation remains outside the
  current validated action boundary.
- Canonical schema v1.4 commits each model response with its exact bounded derived-event sequence and
  requires a fresh macOS device-owner authentication capability for an exact local review decision.
- Device-local Keychain owns the OpenAI credential and approval signing keyring. Secrets are absent
  from `.env.local`, Scout.app, logs, context packs, and MCP output after migration.
- A portable outer app packages and supervises a self-contained Node/Gateway runtime and launches the
  sandboxed Scout UI with ephemeral local credentials. Closed child environments discard ambient
  loader, proxy, provider, and Scout overrides before trusted values are installed.
- Verified SQLite replay snapshots preserve the append-only journal as authority while avoiding
  redundant graph reduction; an aggregate LRU caps retention at 8 streams, 8,192 events, and a
  conservative 64 MiB proxy.
- Transcript rows distinguish `Stabilising`, `Committed`, and `Uncommitted` durability. Persistence
  failures stay visible even in compact/detached layouts, and archive navigation asks the authoritative
  live coordinator to cancel startup or stop and drain active capture before publishing a paused state.
- The current source gate passes 80 Core, 21 persistence, 28 Gateway, 7 launcher-script, native
  launcher-policy, and 122 macOS app tests. The app coverage report is approximately 72%.
- An earlier ad-hoc ZIP/DMG, packaged peer/auth smoke, and real OpenAI two-speaker synthetic smoke
  passed on Apple silicon. That artifact predates the current audit fixes and is historical evidence,
  not a current release certification.
- Developer ID notarization automation is implemented but cannot be executed on a machine without an
  installed Developer ID Application identity and notarytool Keychain profile.

## Quick start for authorised collaborators

Requirements: macOS 15+, Xcode/Swift 6, XcodeGen 2.45.4, and Node.js 24.14.0.

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

A release must use the verified Node.js 24.14.0 macOS arm64 binary whose non-system dylib list is
empty.

```sh
export SCOUT_RELEASE_NODE=/absolute/path/to/self-contained/node
export SCOUT_RELEASE_VERSION=0.1.0
export SCOUT_BUILD_NUMBER=1
make package
make provision-package
make smoke-existing
make live-smoke-existing  # makes a small real OpenAI request
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
# The signed release intentionally has no plaintext import/export command.
dist/Scout-0.1.0/Scout.app/Contents/MacOS/Scout secrets configure-openai
make smoke-existing
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
- [Product readiness audit](docs/product-readiness.md)
- [Evaluation gates](docs/evaluation.md)
- [Enterprise context and asset policy](docs/enterprise-context.md)
- [Asset provenance registry](docs/asset-registry.md)
- [Architecture decisions](docs/adr/README.md)
- [Contributing](CONTRIBUTING.md)

## Non-negotiable boundaries

- The append-only event log is canonical; every other view is rebuildable.
- Evidence, utterances, claims, graph state, and visual projections remain distinct layers.
- Models propose structured data. Deterministic Scout code validates and commits state.
- Model receipts commit the exact atomic projection Scout will append; replay fails closed on a
  partial, extra, reordered, or substituted derived event.
- Every active factual claim resolves to immutable evidence; contradictions coexist until reviewed.
- A local review is authorized for one current target revision and operation. Device-owner
  authentication is not a claim of named-person identity.
- Approval covers exact staged bytes and a selected POC closure, not a mutable workspace snapshot.
- Raw audio, unrestricted transcripts, and source image bytes are excluded from Codex handoff.
- Secrets never enter Swift source, app resources, generated context packs, or repository history.

## License and public repository status

Scout-owned source is publicly viewable for evaluation and security review, but the project is not
open source and publication grants no permission to copy, modify, redistribute, or ship it. These
build instructions are for authorised collaborators; public visibility alone is not permission to run
or package Scout. Identified dependencies remain under their own terms. See [LICENSE](LICENSE) and the
[Gateway dependency notices](Packaging/GATEWAY_THIRD_PARTY_LICENSES.txt). Release binaries remain gated
on Developer ID signing, notarization, stapling, Gatekeeper validation, complete notices, and the
documented clean-Mac checks.
