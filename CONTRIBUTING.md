# Contributing to Scout

## Start with the contract

Read `AGENTS.md`, `docs/architecture.md`, `docs/trust-model.md`, and `SECURITY.md` before changing a
state-bearing path. The append-only log, evidence provenance, deterministic reducer, approval closure,
and secret boundaries are product requirements rather than implementation suggestions.

## Development setup

These commands are for maintainers and other builders who already have written authorisation to use
the Scout-owned source. Public repository access does not itself grant that permission. Start with the
[builder guide](docs/development.md) for ownership boundaries and troubleshooting.

```sh
# Add an Apple account in Xcode > Settings > Accounts and create an Apple Development certificate.
# A Personal Team is sufficient for local work. The generated setting is ignored and is not secret.
make configure-development-signing

cp .env.example .env.local
# Add OPENAI_API_KEY once if live intelligence is required.
make bootstrap
make check
```

Most tests use deterministic fixtures and do not contact OpenAI. `make live-smoke` is explicitly
opt-in because it performs a small provider request.

Each collaborator uses their own Apple Development certificate and their own device-local Keychain
items. Never export an event-store key, provider key, or another developer's signing private key to
make setup easier. The first stable-signed launch on a Mac that previously ran an ad-hoc build may
request one final authorization for the existing event key; choose **Always Allow**. Subsequent builds
from that developer identity satisfy the same designated requirement.

## Builder lanes

- Domain and trust contracts: `Packages/ScoutCore`; keep this target pure and deterministic.
- Persistence: `Packages/ScoutPersistence`; preserve verified replay and append-only authority.
- Native experience: `ScoutApp`; adapters stay behind protocols and never receive the OpenAI key.
- Provider and handoff boundary: `Gateway`; authenticate before accepting customer bytes.
- Codex workflow: `Plugins/scout`; consume only approved context packs.
- Release, evaluation, and operations: `Scripts`, `Packaging`, `Evaluation`, and `docs`.

Coordinate before changing a contract owned by another lane. Never edit the generated
`Scout.xcodeproj`; change `project.yml` and regenerate it.

## Change workflow

1. Write the invariant and failure mode before editing a security- or state-bearing path.
2. Add a regression test that fails for the old behavior.
3. Keep `ScoutCore` pure and deterministic; service adapters belong in ScoutApp or Gateway.
4. Treat model responses, meeting content, files, HTTP input, and MCP arguments as untrusted data.
5. Run the smallest focused test while iterating, then `make check` before handoff.
6. Update the relevant operator, architecture, security, ADR, or release documentation in the same
   change.

## Verification commands

```sh
make core-test
make persistence-test
make bridge-test
make launch-test
make app-test
make check
```

For packaging changes, additionally run:

```sh
make package-smoke
```

Run `make live-smoke` when changing provider schemas, runtime bundling, Keychain provisioning, or the
packaged Gateway boundary.

## Pull requests

Explain the user impact, invariant, failure mode, implementation, test evidence, and remaining risk.
Do not include customer audio, transcripts, images, context packs, `.env.local`, Keychain exports,
release credentials, or generated runtime data.

## Public distribution

The repository is publicly viewable but Scout-owned source intentionally remains all rights reserved.
Public visibility is not permission to clone for use, modify, or redistribute Scout source or binaries.
Identified third-party components remain under their own terms. External contributions require written
authorisation; authorised builders should use pull requests and the repository template. Security
reports belong in GitHub private vulnerability reporting and must never be placed in a public issue.
Authorised release operators must
include the matching Node.js license, complete Gateway dependency licenses/notices, and the
build-specific SBOM.
