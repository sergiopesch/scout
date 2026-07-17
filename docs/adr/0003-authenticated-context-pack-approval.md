# ADR-0003: Exact, authenticated context-pack approval

- Status: accepted
- Date: 2026-07-17

## Context

A handoff can leak unrelated discovery or change between UI review and server storage. A body hash alone
does not prove operator approval because any bearer-authenticated caller could recompute it.

## Decision

Scout stages immutable encoded bytes for exactly one selected POC dependency closure. The operator
reviews its content digest, journal head, revision, and previous pack head. The Gateway approval route
requires an independent per-launch token and mints an HMAC binding over exact content, scope, lineage,
identity, revision, and approval time. Approved reads revalidate the binding. Keychain owns a rotatable
active signer plus retained verification keys.

## Consequences

- Workspace changes after staging cannot expand an approved pack.
- Ordinary Gateway bearers cannot assert approval.
- Rotation preserves old immutable packs until a key is deliberately retired.
- Raw audio, unrestricted transcripts, source images, secrets, open questions, and unrelated records
  remain outside the Codex boundary by default.
