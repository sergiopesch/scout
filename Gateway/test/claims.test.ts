import assert from "node:assert/strict";
import test from "node:test";
import type OpenAI from "openai";
import {
  ClaimsService,
  ExtractClaimsRequestSchema,
  claimProposalJSONSchema,
} from "../src/claims.js";
import { PublicError } from "../src/errors.js";

const input = ExtractClaimsRequestSchema.parse({
  session_id: "session-1",
  event_boundary: 42,
  utterances: [{
    utterance_id: "utterance-1",
    evidence_id: "evidence-1",
    speaker_id: "speaker-1",
    text: "Inventory lives in NetSuite.",
    start_ms: 100,
    end_ms: 2_000,
    source: "realtime",
  }],
});

function fakeOpenAI(output: unknown): Pick<OpenAI, "responses"> {
  return {
    responses: {
      create: async () => ({
        id: "resp_test",
        model: "gpt-test",
        status: "completed",
        output_text: JSON.stringify(output),
      }),
    },
  } as unknown as Pick<OpenAI, "responses">;
}

test("claim schema is strict at every state-bearing object", () => {
  assert.equal(claimProposalJSONSchema.additionalProperties, false);
  assert.equal(claimProposalJSONSchema.properties.claims.items.additionalProperties, false);
  assert.equal(claimProposalJSONSchema.properties.claims.items.properties.subject.additionalProperties, false);
});

test("ClaimsService returns a hashed evidence-linked proposal", async () => {
  const service = new ClaimsService(fakeOpenAI({
    schema_version: "1.0",
    claims: [{
      client_ref: "claim-1",
      subject: { kind: "system", name: "NetSuite" },
      predicate: "stores",
      object: { kind: "data", name: "Inventory", value: null },
      epistemic_status: "heard",
      confidence: 0.98,
      evidence_utterance_ids: ["utterance-1"],
      rationale: "The customer stated this directly.",
    }],
    unresolved_terms: [],
  }), "gpt-test");

  const result = await service.extract(input);
  assert.equal(result.proposal.claims[0]?.evidence_utterance_ids[0], "utterance-1");
  assert.match(result.model_call.output_sha256, /^[a-f0-9]{64}$/);
  assert.equal(result.model_call.input_event_boundary, 42);
});

test("ClaimsService rejects model references to unknown evidence", async () => {
  const service = new ClaimsService(fakeOpenAI({
    schema_version: "1.0",
    claims: [{
      client_ref: "claim-1",
      subject: { kind: "system", name: "NetSuite" },
      predicate: "stores",
      object: { kind: "data", name: "Inventory", value: null },
      epistemic_status: "heard",
      confidence: 0.9,
      evidence_utterance_ids: ["utterance-not-provided"],
      rationale: "Unsupported reference.",
    }],
    unresolved_terms: [],
  }), "gpt-test");

  await assert.rejects(() => service.extract(input), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "provider_evidence_violation");
    return true;
  });
});

test("request validation bounds total utterance text", () => {
  const oversized = {
    session_id: "session-1",
    event_boundary: 0,
    utterances: Array.from({ length: 20 }, (_, index) => ({
      utterance_id: `u-${index}`,
      evidence_id: `e-${index}`,
      speaker_id: null,
      text: "x".repeat(4_000),
      start_ms: index,
      end_ms: index,
      source: "manual",
    })),
  };
  assert.equal(ExtractClaimsRequestSchema.safeParse(oversized).success, false);
});
