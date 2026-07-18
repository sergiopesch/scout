# Contributing to Scout

## Start with the contract

Read `AGENTS.md`, `docs/architecture.md`, `docs/trust-model.md`, and `SECURITY.md` before changing a
state-bearing path. The append-only log, evidence provenance, deterministic reducer, approval closure,
and secret boundaries are product requirements rather than implementation suggestions.

## Development setup

These commands are for maintainers and other collaborators who already have written authorisation to
use the Scout-owned source. Public repository access does not itself grant that permission.

```sh
cp .env.example .env.local
# Add OPENAI_API_KEY once if live intelligence is required.
make bootstrap
make check
```

Most tests use deterministic fixtures and do not contact OpenAI. `make live-smoke` is explicitly
opt-in because it performs a small provider request.

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
Identified third-party components remain under their own terms. External code contributions are not
accepted until contribution terms are published; security reports belong in GitHub private
vulnerability reporting and must never be placed in a public issue. Authorised release operators must
include the matching Node.js license, complete Gateway dependency licenses/notices, and the
build-specific SBOM.
