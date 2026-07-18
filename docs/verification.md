# Verification record

## Current source gate

- Audit date: 2026-07-18
- Source version: `0.1.0` development tree
- Host: Apple silicon Mac, macOS 26.5.1
- Release mode exercised in this audit: debug/ad-hoc source build
- Developer ID notarization: not run; no signing identity or notary profile was installed
- Real customer data: not used

The repository gate completed successfully with compilation caching disabled to avoid an unrelated
low-disk Xcode cache expansion:

```sh
COMPILATION_CACHE_ENABLE_CACHING=NO make check
```

The current verified suite counts are:

| Suite | Passing tests |
| --- | ---: |
| ScoutCore | 80 across 9 suites |
| ScoutPersistence | 21 |
| Gateway | 28 |
| Launcher JavaScript | 7 |
| Launcher native security-policy harness | 4 cases |
| macOS Scout app | 122 |

There were no failed, skipped, cancelled, or expected-failure app tests. The macOS coverage report
after the consolidated gate measured 72.42% line coverage (14,971 of 20,672 lines). Coverage is a
diagnostic, not a release claim: real capture, OS permission, deep-link, and signed-package paths still
need manual and environment-backed evidence.

The app-test target retained a real ad-hoc signature and the shipping sandbox entitlements while
suppressing only Xcode's injected debug base entitlement. A repository lock serializes the
LaunchServices/signing-sensitive app-test phase at `.build/app-test.lock`.

## What the automated gate covers

- Canonical encoding, event sealing, authorization, exact model-projection manifests, append-only
  replay, reducer invariants, review capabilities, and legacy re-attestation.
- Encrypted SQLite append, concurrency, idempotency, replay verification, cache invalidation, and
  event-chain integrity.
- Gateway request schemas, provider adapters, loopback/auth boundaries, context-pack closure,
  approval verification, symlink-safe storage, session compare-and-swap, and stdio MCP.
- Closed launcher child environments, device-owner-gated secret operations, bidirectional process
  supervision, release path validation, and fresh per-launch credentials.
- Native bridge attestation, capture lifecycle cancellation/rollback/drain, transcript timing,
  evidence journaling, deterministic claim projection, visual import, exact claim selection, review,
  POC gating, canonical context-pack export, and production-size rendering.
- Release-workflow lint, full GitHub Action SHA pins, YAML parsing, and generated third-party notices.

A full-file security diff review covered all 59 assigned worklist entries. Four candidates were
reconciled against the implemented trust boundaries and test evidence; none met the threshold for a
reportable vulnerability (scan `3369901f-5cec-4484-906c-634a6e44ff41`).

## Plugin and presentation verification

The standalone `Plugins/scout` archive passed the Codex plugin validator and an archive-shaped MCP
startup test. The MCP bundle, exact nine-component CycloneDX SBOM, third-party notices, and archive
licence were generated twice with identical hashes. The normalized MCP bundle SHA-256 is
`eea34aa29ce4242c9173aac12564f9f37c5069a25bb30c0e79a95f9307790a0f`.

The 15-slide HTML presentation was exercised in the in-app browser at desktop and compact viewport
sizes. Slide navigation, Home/End keys, overview, notes, Escape/focus return, the discovery replay,
the current/proposed-state switch, active-slide accessibility state, and console logs were checked.
The story now labels Northstar Retail and every displayed statement/metric as fictional or proposed,
keeps unresolved PII validation visible, and distinguishes engineering assumptions from customer
evidence.

## Package and provider evidence

An earlier `0.1.0` ad-hoc package in `dist/` passed offline peer/authentication smoke and a small real
OpenAI synthetic-discovery extraction. That artifact predates this audit's launcher, MCP, and evidence
fixes, so it is historical evidence only and is not credited as current release verification.

This audit verified current provider model identifiers against official API documentation and ran all
provider adapters against deterministic fakes. It did not transmit live audio, images, or a new live
claims request. `gpt-5.6-luna` remains an account-specific claims-model setting that must be checked in
the target OpenAI project before packaging.

## Manual and external gates still required

- Replace the approval HMAC with asymmetric signatures so MCP holds verification-only public keys.
- Decode/probe uploaded audio under explicit codec, channel, frame, duration, and decompression
  limits; current Gateway validation is multipart/extension/byte bounded.
- Build and provision a fresh package, then run offline and live packaged smoke against that exact
  artifact.
- Sign with Developer ID, notarize, staple, validate Gatekeeper, and install on a clean Mac.
- Exercise informed-consent microphone and selected system-audio capture, reconnect, long-session,
  and real diarization paths.
- Complete VoiceOver, keyboard-only, reduced-motion, high-contrast, minimum-window, and text-legibility
  review. Automated render smoke is not a substitute.
- Approve retention/deletion, jurisdiction, enterprise-context licensing, and public distribution
  policy with the accountable legal/security owners.
- Build and version a consented, de-identified golden audio/image corpus for model-quality evaluation.

See [Product readiness](product-readiness.md), [Evaluation gates](evaluation.md), and
[Release and notarization](release.md) for the remaining acceptance boundary.
