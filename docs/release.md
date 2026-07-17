# macOS release, signing, and notarization

## Release shape

Scout is distributed as an outer launcher application:

```text
Scout.app
└── Contents
    ├── MacOS/Scout                    native Keychain and process supervisor
    └── Resources
        ├── ScoutUI.app                sandboxed SwiftUI application
        ├── runtime/node               self-contained Node runtime
        ├── runtime/scout-gateway.cjs  bundled trusted Gateway
        ├── gateway-sbom.cdx.json
        ├── gateway-package-lock.json
        └── THIRD_PARTY_NOTICES.md
```

The outer launcher reads secrets, generates per-launch credentials, starts Gateway, validates its
readiness contract, and starts the nested UI without provider or signing secrets. It supervises both
children as one failure domain.

## Prerequisites

- macOS 15+, Xcode/Swift 6, XcodeGen, Node/npm 22+.
- A self-contained arm64 Node executable. `otool -L` may list only `/System/Library` and `/usr/lib`
  dependencies; the package script reads the Mach-O architecture with `lipo` and rejects x86_64,
  universal, or Homebrew-style external-dylib runtimes.
- For distributable builds, the matching upstream Node `LICENSE` file.
- Developer ID Application certificate installed in the login Keychain.
- A `notarytool` Keychain profile.

Run `make bootstrap` once to install pinned Gateway dependencies. For a distributable runtime, download
the official macOS arm64 archive from `https://nodejs.org/download/release/`, verify it against the
PGP-signed `SHASUMS256.txt.asc` published for that exact release, and use its `bin/node` plus matching
`LICENSE`. Follow Node's release-key procedure rather than trusting a checksum downloaded from the same
location without signature verification. Do not substitute an unverified local package-manager binary.

Create the notary profile once through `notarytool`'s interactive prompts so the app-specific password
does not enter shell history or process arguments:

```sh
xcrun notarytool store-credentials scout-notary
```

## Ad-hoc validation package

```sh
export SCOUT_RELEASE_NODE=/absolute/path/to/self-contained/node
export SCOUT_RELEASE_VERSION=0.1.0
export SCOUT_BUILD_NUMBER=1
make package
make provision-package
make package-smoke
```

This produces `dist/Scout-<version>/Scout.app`, a ZIP, a compressed DMG, and a release manifest with
artifact byte sizes and SHA-256 digests. Ad-hoc output is for local validation only.

## Packaged live validation

```sh
make live-smoke
```

The signed/assembled launcher starts the embedded runtime, validates peer identity, sends two synthetic
speaker utterances through the real authenticated Gateway and OpenAI structured-output boundary, and
verifies that every returned claim references only supplied utterance IDs. It sends no customer data.

## Developer ID and notarization

```sh
export SCOUT_RELEASE_NODE=/absolute/path/to/self-contained/node
export SCOUT_NODE_LICENSE_PATH=/absolute/path/to/node/LICENSE
export SCOUT_SIGNING_IDENTITY='Developer ID Application: Example Company (TEAMID)'
export SCOUT_NOTARY_PROFILE=scout-notary
export SCOUT_RELEASE_VERSION=0.1.0
export SCOUT_BUILD_NUMBER=1
make notarize
```

The script:

1. Builds Release Scout UI without implicit signing.
2. Bundles Gateway and generates a production CycloneDX SBOM.
3. Builds the native launcher and assembles the outer app.
4. Signs Node with the JIT entitlement, the sandboxed nested UI with its least-privilege entitlements,
   then the launcher and outer app.
5. Runs strict deep code-sign verification.
6. Submits the ZIP to Apple, waits, downloads and requires a clean notarization log, then staples and
   validates the app.
7. Rebuilds, verifies, and signs the DMG; submits it; requires a clean log; staples it; and validates
   the ticket.
8. Runs Gatekeeper assessment and writes the release manifest.

Every failure stops the release. Never add `--deep` to the signing operation itself; components are
signed explicitly inside-out. `--deep` is used only for final verification.

After notarization, exercise the exact notarized app without rebuilding it:

```sh
make provision-package
make smoke-existing
make live-smoke-existing  # when provider-boundary code changed
```

`package-smoke` and `live-smoke` intentionally rebuild an ad-hoc package. The `*-existing` targets are
the release gates for bytes already produced by `make notarize`.

## Release checklist

- [ ] `git status` contains only intended release changes.
- [ ] `SCOUT_RELEASE_VERSION` and `SCOUT_BUILD_NUMBER` are unique and documented in `CHANGELOG.md`.
- [ ] `make check` passes.
- [ ] `make provision-package` and `make smoke-existing` pass against the exact notarized app.
- [ ] `make live-smoke-existing` passes against that app when provider-boundary code changed.
- [ ] Node executable is self-contained and its matching license is included.
- [ ] SBOM and package lock are present in the app resources.
- [ ] Developer ID identity is valid and not expired.
- [ ] ZIP and DMG notarization, stapling, validation, and Gatekeeper assessment pass.
- [ ] Release-manifest hashes match uploaded artifacts.
- [ ] A clean Mac installation and microphone/screen consent flow are manually tested.
- [ ] VoiceOver and keyboard-only action-pack approval are manually tested.
- [ ] Repository tag and release notes point to the exact commit.

## Signing readiness check

Before a release, verify this machine's current state rather than relying on an old workstation record:

```sh
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile "$SCOUT_NOTARY_PROFILE"
```

Historical machine state belongs in `docs/verification.md`.

## Primary references

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Node.js: Verifying release binaries](https://github.com/nodejs/node#verifying-binaries)
