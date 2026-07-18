#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, readFile, realpath } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

function assert(condition, message) {
  if (!condition) throw new Error(`Invalid Scout evaluation contract: ${message}`);
}

function words(value) {
  return value.toLocaleLowerCase("en-US").match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu) ?? [];
}

export function editDistance(left, right) {
  let prior = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
    const current = [leftIndex];
    for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
      current[rightIndex] = Math.min(
        current[rightIndex - 1] + 1,
        prior[rightIndex] + 1,
        prior[rightIndex - 1] + (left[leftIndex - 1] === right[rightIndex - 1] ? 0 : 1),
      );
    }
    prior = current;
  }
  return prior[right.length];
}

function ratioIntersection(expected, actual) {
  if (expected.length === 0) return 1;
  const actualSet = new Set(actual);
  return expected.filter((value) => actualSet.has(value)).length / expected.length;
}

function percentile95(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)];
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function validateManifest(manifest) {
  assert(manifest?.schema_version === 1, "manifest schema_version must be 1");
  assert(typeof manifest.corpus_id === "string" && manifest.corpus_id.length > 0, "corpus_id is required");
  assert(["synthetic_contract", "consented_deidentified"].includes(manifest.classification), "classification is invalid");
  assert(Array.isArray(manifest.cases) && manifest.cases.length > 0, "at least one case is required");
  const modelFields = [
    "realtime_model", "diarization_model", "claims_model", "prompt_version",
    "schema_version", "reducer_version", "scoring_policy",
  ];
  assert(manifest.model_contract && typeof manifest.model_contract === "object", "model_contract is required");
  for (const field of modelFields) {
    assert(typeof manifest.model_contract[field] === "string"
      && manifest.model_contract[field].length > 0, `model_contract.${field} is required`);
  }
  const thresholdFields = [
    "max_word_error_rate", "max_diarization_error_rate", "min_claim_precision",
    "min_claim_recall", "min_evidence_recall", "min_redaction_recall",
    "max_p95_latency_ms", "max_cost_per_case_usd",
  ];
  assert(manifest.thresholds && typeof manifest.thresholds === "object", "thresholds are required");
  for (const field of thresholdFields) {
    assert(Number.isFinite(manifest.thresholds[field]) && manifest.thresholds[field] >= 0,
      `thresholds.${field} is invalid`);
  }
  const identifiers = new Set();
  for (const fixture of manifest.cases) {
    assert(typeof fixture.id === "string" && !identifiers.has(fixture.id), "case IDs must be unique");
    identifiers.add(fixture.id);
    assert(typeof fixture.reference?.transcript === "string", `${fixture.id} transcript is required`);
    for (const field of ["speaker_frames", "claim_ids", "evidence_ids", "required_redactions"]) {
      assert(Array.isArray(fixture.reference[field]), `${fixture.id} ${field} must be an array`);
    }
    if (manifest.classification === "consented_deidentified") {
      assert(fixture.consent?.status === "approved", `${fixture.id} requires approved consent`);
      assert(typeof fixture.consent?.consent_record_id === "string"
        && fixture.consent.consent_record_id.length > 0, `${fixture.id} consent record is required`);
      assert(fixture.consent?.deidentified === true, `${fixture.id} must be de-identified`);
      assert(/^\d{4}-\d{2}-\d{2}$/u.test(fixture.consent?.retention_review_date ?? ""), `${fixture.id} retention review date is required`);
      assert(/^[a-f0-9]{64}$/u.test(fixture.media?.sha256 ?? ""), `${fixture.id} media hash is required`);
      assert(typeof fixture.media?.relative_path === "string", `${fixture.id} media path is required`);
      assert(["audio", "image"].includes(fixture.media?.kind), `${fixture.id} media kind is invalid`);
    }
  }
}

function validateResults(manifest, results) {
  assert(results?.schema_version === 1, "results schema_version must be 1");
  assert(results.corpus_id === manifest.corpus_id, "results target the wrong corpus");
  assert(typeof results.run_id === "string" && results.run_id.length > 0, "run_id is required");
  assert(stableJSON(results.model_contract) === stableJSON(manifest.model_contract), "model contract differs from the corpus pin");
  assert(Array.isArray(results.cases), "results cases must be an array");
  const expectedIDs = new Set(manifest.cases.map((fixture) => fixture.id));
  const actualIDs = new Set(results.cases.map((fixture) => fixture.id));
  assert(expectedIDs.size === actualIDs.size
    && [...expectedIDs].every((identifier) => actualIDs.has(identifier)), "results must cover every case exactly once");
  assert(results.cases.length === actualIDs.size, "result case IDs must be unique");
}

export function evaluate(manifest, results) {
  validateManifest(manifest);
  validateResults(manifest, results);
  const actualByID = new Map(results.cases.map((fixture) => [fixture.id, fixture]));
  let wordErrors = 0;
  let referenceWords = 0;
  let speakerErrors = 0;
  let speakerFrames = 0;
  let expectedClaims = 0;
  let actualClaims = 0;
  let matchedClaims = 0;
  let expectedEvidence = 0;
  let matchedEvidence = 0;
  let expectedRedactions = 0;
  let matchedRedactions = 0;
  const latencies = [];
  let totalCost = 0;

  for (const fixture of manifest.cases) {
    const actual = actualByID.get(fixture.id);
    assert(typeof actual.transcript === "string", `${fixture.id} result transcript is required`);
    for (const field of ["speaker_frames", "claim_ids", "evidence_ids", "redacted_tokens"]) {
      assert(Array.isArray(actual[field]), `${fixture.id} result ${field} must be an array`);
      assert(actual[field].every((value) => typeof value === "string"), `${fixture.id} result ${field} must contain strings`);
      if (field !== "speaker_frames") {
        assert(new Set(actual[field]).size === actual[field].length, `${fixture.id} result ${field} must not contain duplicates`);
      }
    }
    assert(Number.isFinite(actual.latency_ms) && actual.latency_ms >= 0, `${fixture.id} latency is invalid`);
    assert(Number.isFinite(actual.cost_usd) && actual.cost_usd >= 0, `${fixture.id} cost is invalid`);

    const expectedWordList = words(fixture.reference.transcript);
    wordErrors += editDistance(expectedWordList, words(actual.transcript));
    referenceWords += expectedWordList.length;

    const expectedSpeakers = fixture.reference.speaker_frames;
    assert(actual.speaker_frames.length === expectedSpeakers.length, `${fixture.id} speaker frame count differs`);
    speakerErrors += expectedSpeakers.filter((speaker, index) => actual.speaker_frames[index] !== speaker).length;
    speakerFrames += expectedSpeakers.length;

    const expectedClaimIDs = fixture.reference.claim_ids;
    const actualClaimIDs = actual.claim_ids;
    expectedClaims += expectedClaimIDs.length;
    actualClaims += actualClaimIDs.length;
    matchedClaims += ratioIntersection(expectedClaimIDs, actualClaimIDs) * expectedClaimIDs.length;

    const expectedEvidenceIDs = fixture.reference.evidence_ids;
    expectedEvidence += expectedEvidenceIDs.length;
    matchedEvidence += ratioIntersection(expectedEvidenceIDs, actual.evidence_ids) * expectedEvidenceIDs.length;

    const redactions = fixture.reference.required_redactions;
    expectedRedactions += redactions.length;
    matchedRedactions += ratioIntersection(redactions, actual.redacted_tokens) * redactions.length;
    latencies.push(actual.latency_ms);
    totalCost += actual.cost_usd;
  }

  const metrics = {
    word_error_rate: referenceWords === 0 ? 0 : wordErrors / referenceWords,
    diarization_error_rate: speakerFrames === 0 ? 0 : speakerErrors / speakerFrames,
    claim_precision: actualClaims === 0 ? (expectedClaims === 0 ? 1 : 0) : matchedClaims / actualClaims,
    claim_recall: expectedClaims === 0 ? 1 : matchedClaims / expectedClaims,
    evidence_recall: expectedEvidence === 0 ? 1 : matchedEvidence / expectedEvidence,
    redaction_recall: expectedRedactions === 0 ? 1 : matchedRedactions / expectedRedactions,
    p95_latency_ms: percentile95(latencies),
    cost_per_case_usd: totalCost / manifest.cases.length,
  };
  const thresholds = manifest.thresholds;
  const checks = {
    word_error_rate: metrics.word_error_rate <= thresholds.max_word_error_rate,
    diarization_error_rate: metrics.diarization_error_rate <= thresholds.max_diarization_error_rate,
    claim_precision: metrics.claim_precision >= thresholds.min_claim_precision,
    claim_recall: metrics.claim_recall >= thresholds.min_claim_recall,
    evidence_recall: metrics.evidence_recall >= thresholds.min_evidence_recall,
    redaction_recall: metrics.redaction_recall >= thresholds.min_redaction_recall,
    p95_latency_ms: metrics.p95_latency_ms <= thresholds.max_p95_latency_ms,
    cost_per_case_usd: metrics.cost_per_case_usd <= thresholds.max_cost_per_case_usd,
  };
  return {
    schema_version: 1,
    corpus_id: manifest.corpus_id,
    run_id: results.run_id,
    classification: manifest.classification,
    metrics,
    checks,
    passed: Object.values(checks).every(Boolean),
  };
}

async function sha256File(path) {
  const digest = createHash("sha256");
  await new Promise((resolveStream, rejectStream) => {
    const stream = createReadStream(path);
    stream.on("data", (chunk) => digest.update(chunk));
    stream.once("error", rejectStream);
    stream.once("end", resolveStream);
  });
  return digest.digest("hex");
}

async function verifyConsentedMedia(manifest, mediaRoot) {
  if (manifest.classification !== "consented_deidentified") return;
  assert(mediaRoot, "--media-root is required for a consented corpus");
  const root = await realpath(resolve(mediaRoot));
  const rootMetadata = await lstat(root);
  assert(rootMetadata.isDirectory() && !rootMetadata.isSymbolicLink(), "media root must be a real directory");
  for (const fixture of manifest.cases) {
    const relativePath = fixture.media.relative_path;
    assert(!isAbsolute(relativePath), `${fixture.id} media path must be relative`);
    const candidate = resolve(root, relativePath);
    const boundary = relative(root, candidate);
    assert(boundary !== ".." && !boundary.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`), `${fixture.id} media path escapes its root`);
    const metadata = await lstat(candidate);
    assert(metadata.isFile() && !metadata.isSymbolicLink(), `${fixture.id} media must be a regular file`);
    assert(metadata.size > 0 && metadata.size <= 1024 * 1024 * 1024, `${fixture.id} media size is out of bounds`);
    const canonical = await realpath(candidate);
    const canonicalBoundary = relative(root, canonical);
    assert(canonicalBoundary !== ".." && !canonicalBoundary.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`), `${fixture.id} media resolves outside its root`);
    assert(await sha256File(canonical) === fixture.media.sha256, `${fixture.id} media hash differs from the manifest`);
  }
}

async function main() {
  const manifestIndex = process.argv.indexOf("--manifest");
  const resultsIndex = process.argv.indexOf("--results");
  assert(manifestIndex >= 0 && process.argv[manifestIndex + 1], "--manifest is required");
  assert(resultsIndex >= 0 && process.argv[resultsIndex + 1], "--results is required");
  const manifest = JSON.parse(await readFile(process.argv[manifestIndex + 1], "utf8"));
  const results = JSON.parse(await readFile(process.argv[resultsIndex + 1], "utf8"));
  const mediaRootIndex = process.argv.indexOf("--media-root");
  await verifyConsentedMedia(manifest, mediaRootIndex < 0 ? undefined : process.argv[mediaRootIndex + 1]);
  const report = evaluate(manifest, results);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!report.passed) process.exitCode = 1;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Scout evaluation failed"}\n`);
    process.exitCode = 1;
  });
}
