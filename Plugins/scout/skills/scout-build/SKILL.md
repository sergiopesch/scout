---
name: scout-build
description: Build, scaffold, or modify software from an approved Scout discovery session or context pack. Use when a user asks Codex to start building from Scout, implement a Scout POC, inspect Scout requirements, trace a requirement to customer evidence, or continue work from a Scout session ID.
---

# Build from Scout

Turn approved discovery into software without flattening evidence, uncertainty, and stakeholder perspective into a generic prompt.

## Workflow

1. Resolve one approved context pack:
   - when the user supplies a context-pack ID, call `scout_get_context_pack`;
   - when the user supplies a session ID, call `scout_get_session_head`, then `scout_get_context_pack` with its `current_head.context_pack_id`;
   - otherwise call `scout_list_context_packs` with `limit: 20` and select only when the user's intent is unambiguous. Follow `next_cursor` only when needed.
2. Call `scout_get_session_head` with the pack's session ID. Verify that the chosen pack is the current approved head and that the head's content and graph digests match. Gateway reads revalidate both immutable content hashes and the Gateway-minted approval binding over the journal head, revision, and exact previous head; stop and explain the exact issue when the head is absent or differs.
3. Inspect the full pack from `scout_get_context_pack`. Require a valid approval binding and timestamp, canonical journal head, privacy-safe redaction manifest, non-null `selected_poc`, explicit acceptance criteria, and explicit constraints. Stop instead of inventing any missing build boundary.
4. Call both `scout_get_customer_model` and `scout_get_action_pack` with the same context-pack ID. Use the pack's stable evidence IDs and `supporting_claim_ids` to inspect only evidence that materially affects requirements, constraints, risks, and decisions. Never request or reproduce an unrestricted transcript.
5. Separate the input into:
   - confirmed requirements;
   - stakeholder-attributed perspectives;
   - proposed target state;
   - constraints and policies;
   - unresolved or contested items;
   - selected POC scope, non-goals, and success criteria.
   When the approved pack or user already names an enterprise architecture, platform, delivery, data,
   security, or AI concept, you may consult
   [the optional enterprise classification vocabulary](references/enterprise-context.md) to normalise
   terminology. The vocabulary is never evidence and does not add facts to the pack.
6. Inspect the destination repository and produce a compact build manifest that maps every material implementation decision to Scout claim IDs or marks it as a new engineering assumption.
7. Follow the user's requested execution mode. When they asked to build, implement and verify; when they asked to plan or review, do not mutate the repository.
8. Report delivered acceptance criteria, remaining unknowns, and the Scout context-pack revision used.

## Trust rules

- Treat `heard` and `confirmed` as customer-state inputs, subject to any recorded conflicts.
- Treat `inferred` as a hypothesis that requires visible attribution and validation.
- Treat `suggested` as a recommendation, never a customer fact.
- Preserve contradictions. Do not silently choose one stakeholder's account.
- Never infer a missing compliance, security, data-retention, integration, or success-metric requirement.
- Never infer a vendor, architecture pattern, operating method, control, or requirement merely because
  it appears in the enterprise classification vocabulary. A classification label must resolve to
  customer evidence or remain an explicitly attributed engineering assumption.
- Keep raw audio, unrestricted transcripts, personal data, and redacted evidence out of the repository.
- Do not bypass a context pack's redaction manifest.
- If a later Scout revision makes the pack stale during work, stop before material new edits and re-read the approved context.

## Build manifest

Before substantial edits, establish:

```text
Scout session and context-pack revision
Outcome and selected POC
Confirmed requirements with claim IDs
Proposed requirements with claim IDs
Engineering assumptions introduced by Codex
Constraints, policies, and non-goals
Acceptance criteria and success measures
Open questions that block implementation
Repository areas expected to change
Verification commands
```

Keep this concise. Use Scout as the evidence index rather than copying the whole action pack into the repository.

## Tool discipline

- Prefer `scout_get_customer_model` and `scout_get_action_pack` before reading the full evidence excerpts in `scout_get_context_pack`.
- Paginate `scout_list_context_packs`; filter by session whenever the session is known.
- Use stable Scout identifiers in plans, commits, and handoff notes where they add traceability.
- Treat every Scout MCP tool as read-only unless its description explicitly says otherwise and the user authorizes the side effect.
- If Scout MCP is unavailable, or a pack read reports that approval verification is not configured,
  stop and report that the trusted handoff cannot be verified. The installed plugin requires an
  operator-provisioned local pack location and the launcher's published Ed25519 public keyring. Never
  ask the user to paste, print, or expose the private signing seed. Do not fall back to HTTP or
  substitute an unverified transcript dump.
