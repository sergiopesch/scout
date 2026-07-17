# Scout engineering contract

Scout compiles live customer discovery into an evidence-linked customer model and a build-ready handoff for Codex.

## Non-negotiable invariants

- The append-only event log is canonical. Read models, diagrams, summaries, and action packs are rebuildable projections.
- Keep evidence, utterances, claims, graph state, and visual projections as separate layers.
- OpenAI may propose transcript refinements, claims, entity resolution, questions, and actions. Only deterministic Scout code validates and commits state.
- Every active factual claim resolves to immutable evidence. Recommendations remain explicitly proposed.
- Never rewrite speaker identity or transcript history. Append a revision or mapping event.
- Contradictions coexist until a recorded validation resolves them.
- Never put `OPENAI_API_KEY` in Swift source, an app bundle, Xcode settings, logs, or generated context packs.
- Raw customer audio, unrestricted transcripts, and original or normalized image bytes are excluded from Codex handoff by default.

## Module boundaries

- `Packages/ScoutCore`: pure domain types, event contracts, reducer, trust rules, replay, and tests. No UI or OpenAI networking.
- `ScoutApp`: native macOS capture and interaction surface. Keep service adapters behind protocols.
- `Gateway`: trusted local/server relay for OpenAI Realtime, diarization, structured extraction, and MCP.
- `Plugins/scout`: Codex workflow packaging. It consumes approved context packs; it never bypasses Scout trust policy.

## Verification

Run these before handing off changes:

```sh
make check
```

For focused work:

```sh
make core-test
make bridge-test
make build
```

Generated Xcode projects are disposable. Edit `project.yml`, then run `make generate`.
