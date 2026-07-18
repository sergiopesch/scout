# Scout evaluation corpus

Scout promotes model, prompt, schema, reducer, or scoring changes only through a versioned evaluation
manifest. The committed manifest contains de-identified references, immutable media hashes, consent
record identifiers, model/version pins, thresholds, and expected outputs. Raw participant audio and
images stay in the ignored `Evaluation/private-media/` directory and never enter Git, Codex context
packs, or release bundles.

## What is ready

- `synthetic-contract-v1` proves the scorer, threshold behavior, and CI wiring without human media.
- `golden-v1/manifest.template.json` is the intake contract for the first consented manual pass.
- `Scripts/run-evaluation.mjs` calculates WER, frame-aligned diarization error, claim precision/recall,
  evidence recall, redaction recall, p95 latency, and cost per case. Any missing case or failed
  threshold makes the command fail closed.

The synthetic fixture is not product-quality evidence and must never be described as a real-meeting
benchmark.

## Run the contract gate

```sh
make evaluation-test
make evaluation-contract
```

## Record a consented run

1. Copy `corpus/golden-v1/manifest.template.json` to `corpus/golden-v1/manifest.json`.
2. Confirm informed consent, de-identification, retention, and permitted evaluation use outside Git.
3. Place raw media under `Evaluation/private-media/` and record its lowercase SHA-256 digest and
   relative path in the manifest.
4. Manually review the reference transcript, anonymous speaker frames, atomic claims, evidence IDs,
   conflicts, and required redactions.
5. Capture the candidate output in `Evaluation/runs/` using the same case IDs.
6. Run:

```sh
node Scripts/run-evaluation.mjs \
  --manifest Evaluation/corpus/golden-v1/manifest.json \
  --results Evaluation/runs/RESULT.json \
  --media-root Evaluation
```

Commit only the reviewed manifest and non-sensitive aggregate report. Never commit raw media,
participant names, unrestricted transcripts, secrets, or personal data.
