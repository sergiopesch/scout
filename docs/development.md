# Scout builder guide

This guide is for maintainers and builders with written authorisation to work on Scout-owned source.
The public repository remains all rights reserved; public visibility alone is not permission to use,
modify, or distribute Scout.

## First-day setup

Requirements:

- macOS 15 or newer on Apple silicon;
- Xcode 26 with Swift 6 and the command-line tools selected;
- XcodeGen 2.45.4;
- Node.js 24.14.0;
- an Apple Development certificate. A Personal Team works for local builds.

In Xcode, open **Settings → Accounts**, add an Apple account, select a team, open **Manage
Certificates**, and create an **Apple Development** certificate. Then run:

```sh
git clone https://github.com/sergiopesch/scout.git
cd scout
make configure-development-signing

cp .env.example .env.local
# Add OPENAI_API_KEY only when live provider work is required.
make bootstrap
make check
make run
```

`make configure-development-signing` records only the 10-character team identifier in the ignored
`.scout-development.mk` file. It never exports a certificate or private key. `make bootstrap` moves a
provider key from `.env.local` into device-local Keychain and removes the plaintext line after a
verified import.

Most work needs no OpenAI key: Core, persistence, Gateway, launcher, evaluation, and macOS tests use
deterministic fixtures. Live smoke is deliberately opt-in and incurs a small provider request.

## Signing and Keychain recovery

Check the installed identities with:

```sh
security find-identity -v -p codesigning
```

If Xcode reports that account login details were rejected, return to **Xcode → Settings → Accounts**,
sign in again, complete two-factor authentication, and create the certificate. Then rerun:

```sh
make configure-development-signing
make run
```

A Mac that previously ran an ad-hoc build may ask once for access to
`dev.scout.discovery.event-store`. Enter the login password and choose **Always Allow**. Do not delete
that item to remove the prompt: the current encrypted journal has no key export or recovery path.

Every builder owns a separate development certificate, provider credential, approval keyring, and
event-store key. Never share Keychain exports or signing private keys. Shared production distribution
uses the separately controlled Developer ID and notarization workflow in [release.md](release.md).

## Architecture and ownership

| Area | Owner boundary | Focused gate |
| --- | --- | --- |
| `Packages/ScoutCore` | Pure events, claims, reducer, replay, and trust rules | `make core-test` |
| `Packages/ScoutPersistence` | Encrypted append-only SQLite and verified replay | `make persistence-test` |
| `ScoutApp` | Native capture, projections, glass UI, and protocol-backed adapters | `make app-test` |
| `Gateway` | OpenAI relay, diarization, approvals, context packs, and MCP | `make bridge-test` |
| `Tools/ScoutLauncher`, `Scripts` | Keychain, supervision, packaging, and runtime boundaries | `make launch-test` |
| `Evaluation` | Versioned privacy-safe scoring contracts | `make evaluation-test evaluation-contract` |
| `Plugins/scout` | Codex workflow over approved context packs only | `make release-lint` |

Before changing a state-bearing path, read `AGENTS.md`, [architecture.md](architecture.md),
[trust-model.md](trust-model.md), and the root [security policy](../SECURITY.md). The append-only event
log remains canonical; models propose, while deterministic Scout code validates and commits.

Generated Xcode projects are disposable. Change `project.yml`, run `make generate`, and never commit
`Scout.xcodeproj` or DerivedData.

## Daily change loop

1. Pull `main` and create a focused branch.
2. Write down the invariant and failure mode.
3. Add a regression test that demonstrates the old failure.
4. Run the smallest focused gate while iterating.
5. Run `make check` before requesting review.
6. Update the relevant operator, architecture, security, evaluation, or release documentation.
7. Open a pull request using `.github/pull_request_template.md`.

Pull requests must explain user impact, the invariant, root cause, implementation, test evidence, and
remaining risk. Keep unrelated changes separate so review and rollback remain precise.

## Data and secret rules

Never commit or attach:

- customer audio, unrestricted transcripts, or original/normalized image bytes;
- context packs, encrypted journal databases, or runtime exports;
- `.env.local`, provider credentials, Keychain exports, signing keys, or notarization credentials;
- generated build products, coverage databases, or customer-specific logs.

Use synthetic fixtures for public tests. Security issues belong in GitHub private vulnerability
reporting, not public issues. See the [security policy](../SECURITY.md) for the reporting boundary.

## Definition of done

A change is ready for review when its focused gate and `make check` pass, documentation matches the
new behavior, generated legal/SBOM artifacts are current when affected, and the diff contains no
customer data, secret material, or unrelated workspace changes. Packaging changes additionally need
`make package-smoke`; provider changes need the explicitly authorised `make live-smoke` gate.

The current implementation status and remaining external gates are tracked in
[product-readiness.md](product-readiness.md) and [verification.md](verification.md).
