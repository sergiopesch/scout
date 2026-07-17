# Verification record

## Milestone

- Date: 2026-07-17
- Version: 0.1.0 build 1
- Platform: macOS, Apple silicon
- Release mode exercised: ad-hoc local package
- Developer ID notarization: not run; no valid signing identity installed

## Deterministic repository gates

`make check` verifies:

- ScoutCore event, canonical encoding, reducer, replay, trust, and model-call contracts.
- ScoutPersistence encryption, append, concurrency, idempotency, and replay integrity.
- Gateway schemas, provider adapters, context-pack closure, approval authenticity, key rotation,
  session compare-and-swap, peer authentication, and stdio MCP.
- Native macOS bridge, capture timing, async generation gates, evidence journal, projection, visual
  import, approval staging, quick-win logic, and production-size render behavior.
- Native launcher compilation and per-launch credential tests.

The current verified suite counts are:

| Suite | Passing tests |
| --- | ---: |
| ScoutCore | 34 |
| ScoutPersistence | 11 |
| Gateway | 26 |
| Launcher JavaScript | 3 |
| macOS Scout app | 85 |

## Package verification

The package workflow successfully produced:

- A nested sandboxed Release Scout UI.
- A native outer launcher.
- A self-contained arm64 Node 24 runtime with system-only dylib dependencies.
- A bundled CommonJS Gateway runtime.
- A CycloneDX production-dependency SBOM and pinned package lock.
- Strictly verified ad-hoc signatures.
- ZIP and compressed DMG artifacts with SHA-256 manifest entries.

The offline packaged smoke passed and covered:

- Keychain provisioning in an isolated package namespace.
- Gateway startup on an OS-assigned loopback port.
- Exact instance-ID attestation.
- Bearer-authenticated approved-pack listing.
- Clean Gateway termination.

## Real provider boundary

The packaged live smoke passed in approximately eight seconds. It submitted two synthetic,
speaker-attributed discovery utterances through the packaged Gateway to OpenAI and required:

- a completed strict structured-output response;
- at least one extracted claim;
- a 64-character output SHA-256 receipt;
- every evidence reference to resolve to one of the two supplied utterance IDs.

No customer content, raw audio, source image, context pack, or repository secret was used.

## Security remediation record

The implementation and regression suites close these scanned paths:

- model output promoted to factual authority;
- relationship trust lost in projection;
- approved handoff serialized outside the selected POC closure;
- handoff approval rebuilt mutable state after review;
- bearer-only callers forged approved context packs;
- ambient loopback listener impersonated MCP;
- ambient loopback listener impersonated the native Gateway.

The durable scan-local remediation report is generated outside the repository and should remain an
audit artifact, not a source file.

## Manual gates still required

- Install a valid Developer ID Application identity and run `make notarize`.
- Install the resulting DMG on a clean Mac and verify Gatekeeper offline after stapling.
- Exercise real microphone and selected system-audio capture with informed participant consent.
- Perform manual VoiceOver, keyboard-only, reduced-motion, and high-contrast review.
- Confirm chosen retention/deletion policy with legal and security stakeholders.
