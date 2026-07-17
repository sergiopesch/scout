# ADR-0004: Native supervised runtime and stdio MCP

- Status: accepted
- Date: 2026-07-17

## Context

Fixed loopback ports and bearer files let ambient local listeners impersonate a trusted bridge or MCP
server. A portable Mac release also cannot depend on a Homebrew Node installation and its external
dylibs.

## Decision

The distributed app uses a native outer launcher containing a self-contained Node runtime, bundled
Gateway, and nested sandboxed UI. It generates a fresh port, bearer, approval token, and instance
identity for every launch. The UI attests the exact child before sending authorization or customer
content. Codex MCP runs as a plugin-owned stdio process with no HTTP listener. Components are signed
inside-out and notarization fails closed.

## Consequences

- Gateway/UI lifecycle is supervised as one unit.
- The package must carry the matching Node license and dependency SBOM.
- Node JIT requires its narrowly scoped hardened-runtime entitlement.
- Development and ad-hoc Keychain stores are explicitly provisioned; differently signed binaries do
  not silently inherit secrets.
