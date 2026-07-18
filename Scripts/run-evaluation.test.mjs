import assert from "node:assert/strict";
import test from "node:test";
import { editDistance, evaluate } from "./run-evaluation.mjs";

const manifest = {
  schema_version: 1,
  corpus_id: "scout-synthetic-contract-v1",
  classification: "synthetic_contract",
  model_contract: {
    realtime_model: "test-realtime",
    diarization_model: "test-diarization",
    claims_model: "test-claims",
    prompt_version: "test-prompt",
    schema_version: "1.4",
    reducer_version: "test-commit",
    scoring_policy: "scout-evaluation-v1",
  },
  thresholds: {
    max_word_error_rate: 0.1,
    max_diarization_error_rate: 0.1,
    min_claim_precision: 0.9,
    min_claim_recall: 0.9,
    min_evidence_recall: 0.9,
    min_redaction_recall: 1,
    max_p95_latency_ms: 2_000,
    max_cost_per_case_usd: 0.1,
  },
  cases: [{
    id: "contract-001",
    reference: {
      transcript: "Inventory reconciliation runs nightly.",
      speaker_frames: ["speaker-a", "speaker-a"],
      claim_ids: ["claim-nightly"],
      evidence_ids: ["evidence-nightly"],
      required_redactions: ["customer-email"],
    },
  }],
};

const perfectResults = {
  schema_version: 1,
  corpus_id: manifest.corpus_id,
  run_id: "synthetic-perfect",
  model_contract: manifest.model_contract,
  cases: [{
    id: "contract-001",
    transcript: "Inventory reconciliation runs nightly.",
    speaker_frames: ["speaker-a", "speaker-a"],
    claim_ids: ["claim-nightly"],
    evidence_ids: ["evidence-nightly"],
    redacted_tokens: ["customer-email"],
    latency_ms: 500,
    cost_usd: 0.01,
  }],
};

test("evaluation metrics use deterministic edit distance", () => {
  assert.equal(editDistance(["one", "two", "three"], ["one", "too", "three"]), 1);
  assert.equal(editDistance([], ["one"]), 1);
  assert.equal(editDistance(["one"], []), 1);
});

test("a complete synthetic evaluation contract passes every gate", () => {
  const report = evaluate(manifest, perfectResults);
  assert.equal(report.passed, true);
  assert.deepEqual(report.metrics, {
    word_error_rate: 0,
    diarization_error_rate: 0,
    claim_precision: 1,
    claim_recall: 1,
    evidence_recall: 1,
    redaction_recall: 1,
    p95_latency_ms: 500,
    cost_per_case_usd: 0.01,
  });
});

test("missing words, speakers, evidence, and redactions fail closed", () => {
  const degraded = structuredClone(perfectResults);
  degraded.run_id = "synthetic-degraded";
  degraded.cases[0].transcript = "Inventory fails.";
  degraded.cases[0].speaker_frames = ["speaker-b", "speaker-a"];
  degraded.cases[0].claim_ids = ["claim-unsupported"];
  degraded.cases[0].evidence_ids = [];
  degraded.cases[0].redacted_tokens = [];
  degraded.cases[0].latency_ms = 3_000;
  degraded.cases[0].cost_usd = 0.2;
  const report = evaluate(manifest, degraded);
  assert.equal(report.passed, false);
  assert.ok(Object.values(report.checks).every((passed) => passed === false));
});

test("consented corpus cases require approved de-identification and immutable media hashes", () => {
  const consented = structuredClone(manifest);
  consented.classification = "consented_deidentified";
  assert.throws(() => evaluate(consented, perfectResults), /requires approved consent/);
});
