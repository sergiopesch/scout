import assert from "node:assert/strict";
import test from "node:test";
import type OpenAI from "openai";
import {
  ImageObservationProposalSchema,
  ImageObservationsService,
  imageObservationJSONSchema,
  type ImageObservationUpload,
} from "../src/image-observations.js";
import { PublicError } from "../src/errors.js";

const assetSHA256 = "a".repeat(64);
const upload: ImageObservationUpload = {
  bytes: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
  mimeType: "image/jpeg",
  sessionId: "session-1",
  assetSHA256,
  pixelWidth: 10,
  pixelHeight: 20,
};

const validProposal = {
  schema_version: "1.0",
  evidence_asset_sha256: assetSHA256,
  entities: [
    {
      client_ref: "entity-crm",
      kind: "system",
      name: "CRM",
      detail: "Customer records",
      basis: "visible",
      confidence: 0.97,
      rationale: "The labelled CRM box is visible.",
    },
    {
      client_ref: "entity-orders",
      kind: "data",
      name: "Orders",
      detail: null,
      basis: "visible",
      confidence: 0.9,
      rationale: "Orders is written inside a data-store symbol.",
    },
  ],
  relationships: [{
    client_ref: "relationship-1",
    source_client_ref: "entity-crm",
    predicate: "writes_to",
    target_client_ref: "entity-orders",
    basis: "visible",
    confidence: 0.91,
    rationale: "A directed arrow connects the two visible boxes.",
  }],
  notes: [{
    client_ref: "note-1",
    category: "architecture",
    text: "A hand-drawn current-state architecture.",
    basis: "visible",
    confidence: 0.92,
  }],
};

function fakeOpenAI(
  output: unknown,
  capture?: (parameters: unknown) => void,
): Pick<OpenAI, "responses"> {
  return {
    responses: {
      create: async (parameters: unknown) => {
        capture?.(parameters);
        return {
          id: "resp_image_test",
          model: "gpt-test",
          status: "completed",
          output_text: JSON.stringify(output),
        };
      },
    },
  } as unknown as Pick<OpenAI, "responses">;
}

test("image observation schema is strict and all relationships resolve", () => {
  assert.equal(imageObservationJSONSchema.additionalProperties, false);
  assert.equal(imageObservationJSONSchema.properties.entities.items.additionalProperties, false);
  assert.equal(ImageObservationProposalSchema.safeParse(validProposal).success, true);
  assert.equal(ImageObservationProposalSchema.safeParse({
    ...validProposal,
    relationships: [{ ...validProposal.relationships[0], target_client_ref: "entity-missing" }],
  }).success, false);
});

test("ImageObservationsService uses a non-persistent Responses image input and returns a hashed proposal", async () => {
  let request: any;
  const service = new ImageObservationsService(fakeOpenAI(validProposal, (parameters) => {
    request = parameters;
  }), "gpt-test");

  const result = await service.observe(upload);

  assert.equal(result.proposal.evidence_asset_sha256, assetSHA256);
  assert.match(result.model_call.output_sha256, /^[a-f0-9]{64}$/);
  assert.equal(result.model_call.input_asset_sha256, assetSHA256);
  assert.equal(request.store, false);
  assert.equal(request.input[0].content[1].type, "input_image");
  assert.match(request.input[0].content[1].image_url, /^data:image\/jpeg;base64,/);
  assert.doesNotMatch(JSON.stringify(request), /session-1/);
  assert.match(request.instructions, /untrusted customer evidence/);
});

test("ImageObservationsService rejects a model response that changes the evidence digest", async () => {
  const service = new ImageObservationsService(fakeOpenAI({
    ...validProposal,
    evidence_asset_sha256: "b".repeat(64),
  }), "gpt-test");

  await assert.rejects(() => service.observe(upload), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "provider_evidence_violation");
    return true;
  });
});

test("ImageObservationsService rejects unknown state-bearing response fields", async () => {
  const service = new ImageObservationsService(fakeOpenAI({
    ...validProposal,
    unexpected: true,
  }), "gpt-test");

  await assert.rejects(() => service.observe(upload), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "provider_schema_violation");
    return true;
  });
});
