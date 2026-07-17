import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { GatewayConfig } from "../src/config.js";
import { ContextPackStore } from "../src/context-packs.js";
import { createGatewayRuntime } from "../src/server.js";
import { makeContextPack, TEST_APPROVAL_OPTIONS } from "./context-pack-fixture.js";

function withoutJPEGMetadata(bytes: Buffer): Buffer {
  const parts = [bytes.subarray(0, 2)];
  let offset = 2;
  while (offset + 4 <= bytes.length) {
    const marker = bytes[offset + 1];
    if (bytes[offset] !== 0xff || marker === undefined) break;
    if (marker === 0xda) {
      parts.push(bytes.subarray(offset));
      break;
    }
    const length = bytes.readUInt16BE(offset + 2);
    if (!((marker >= 0xe1 && marker <= 0xef) || marker === 0xfe)) {
      parts.push(bytes.subarray(offset, offset + 2 + length));
    }
    offset += 2 + length;
  }
  return Buffer.concat(parts);
}

test("Gateway serves bounded REST, authenticated approval, and no ambient HTTP MCP", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-gateway-server-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const token = "local-test-token-that-is-at-least-thirty-two-characters";
  const approvalToken = "local-test-approval-token-that-is-at-least-thirty-two-characters";
  const gatewayInstanceID = "test-gateway-instance-id-000000000000000000000000";
  const config: GatewayConfig = {
    apiKey: "test-api-key-not-a-real-secret-000000000000",
    openAIBaseURL: "https://api.openai.com/v1",
    realtimeModel: "gpt-realtime-whisper",
    diarizationModel: "gpt-4o-transcribe-diarize",
    claimsModel: "gpt-test",
    visionModel: "gpt-test",
    host: "127.0.0.1",
    port: 0,
    contextPackDirectory: directory,
    ingestToken: token,
    gatewayInstanceID,
    approvalToken,
    approvalKey: TEST_APPROVAL_OPTIONS.key,
    approvalKeyID: TEST_APPROVAL_OPTIONS.keyID,
    approvalVerificationKeys: {},
    requestTimeoutMs: 1_000,
  };
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  let uploadedFilename = "";
  const runtime = createGatewayRuntime(config, {
    contextPacks: store,
    claims: { extract: async (input) => ({ accepted_boundary: input.event_boundary }) },
    diarization: {
      transcribe: async (upload) => {
        uploadedFilename = upload.filename;
        return { accepted_bytes: upload.bytes.length };
      },
    },
    imageObservations: {
      observe: async (upload) => ({
        accepted_asset_sha256: upload.assetSHA256,
        accepted_dimensions: [upload.pixelWidth, upload.pixelHeight],
      }),
    },
  });
  const address = await runtime.listen();
  context.after(() => runtime.close());
  const base = `http://${address.host}:${address.port}`;

  const health = await fetch(`${base}/health`);
  assert.equal(health.status, 200);
  assert.equal(health.headers.get("x-scout-gateway-instance-id"), gatewayInstanceID);
  assert.equal((await health.json() as any).status, "ok");

  const invalidClaims = await fetch(`${base}/v1/claims/extract`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({}),
  });
  assert.equal(invalidClaims.status, 422);

  const claims = await fetch(`${base}/v1/claims/extract`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({
      session_id: "session-1",
      event_boundary: 7,
      utterances: [{
        utterance_id: "u-1",
        evidence_id: "e-1",
        speaker_id: null,
        text: "We use Salesforce.",
        start_ms: 0,
        end_ms: 100,
        source: "manual",
      }],
    }),
  });
  assert.deepEqual(await claims.json(), { accepted_boundary: 7 });

  const form = new FormData();
  form.set("file", new Blob([Buffer.from("RIFF-test")], { type: "audio/wav" }), "meeting.wav");
  form.set("language", "en");
  const diarization = await fetch(`${base}/v1/transcriptions/diarize`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: form,
  });
  assert.equal(diarization.status, 200);
  assert.equal(uploadedFilename, "meeting.wav");

  const jpeg = withoutJPEGMetadata(Buffer.from(
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAEKADAAQAAAABAAAAEAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAEAAQAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A+HfjZ8evix4u+LHjDVdW8X6ojDVLyKGGG9mihghimZI4o40YKiIoAGBz1OSSa3/AvxC+MPwa+Jvw310fEDVP7d1TUbF7vRpbqWZEsLmVQq3WZWQ+fGc+WyBkBBOGwab8R/Cvxb+BPxM8a2MPw51E+L3128nsdde0e8tU0+SQujWcLQtCzydfOLMVUlAqvkjy/wCCnwa+OHxN+OXhWC18Laxc3U+s2l1eXlzazrHFGs6ySzzzSLhVUBmJZsk8DJIFfXSxVD2Di43bWnZefm/w+e3lUvaOo7qy/P8A4H4+R//Z",
    "base64",
  ));
  const imageHash = createHash("sha256").update(jpeg).digest("hex");
  const imageForm = new FormData();
  imageForm.set("session_id", "session-1");
  imageForm.set("asset_sha256", imageHash);
  imageForm.set("pixel_width", "16");
  imageForm.set("pixel_height", "16");
  imageForm.set("file", new Blob([jpeg], { type: "image/jpeg" }), "evidence.jpg");
  const imageObservation = await fetch(`${base}/v1/images/observe`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: imageForm,
  });
  const imageObservationBody = await imageObservation.json();
  assert.equal(imageObservation.status, 200, JSON.stringify(imageObservationBody));
  assert.deepEqual(imageObservationBody, {
    accepted_asset_sha256: imageHash,
    accepted_dimensions: [16, 16],
  });

  const metadataSegment = Buffer.from([0xff, 0xe1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00]);
  const jpegWithMetadata = Buffer.concat([jpeg.subarray(0, 2), metadataSegment, jpeg.subarray(2)]);
  const metadataForm = new FormData();
  metadataForm.set("session_id", "session-1");
  metadataForm.set("asset_sha256", createHash("sha256").update(jpegWithMetadata).digest("hex"));
  metadataForm.set("pixel_width", "16");
  metadataForm.set("pixel_height", "16");
  metadataForm.set("file", new Blob([jpegWithMetadata], { type: "image/jpeg" }), "evidence.jpg");
  const metadataUpload = await fetch(`${base}/v1/images/observe`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: metadataForm,
  });
  assert.equal(metadataUpload.status, 422);
  assert.equal((await metadataUpload.json() as any).error.code, "image_metadata_not_stripped");

  const wrongHashForm = new FormData();
  wrongHashForm.set("session_id", "session-1");
  wrongHashForm.set("asset_sha256", "0".repeat(64));
  wrongHashForm.set("pixel_width", "16");
  wrongHashForm.set("pixel_height", "16");
  wrongHashForm.set("file", new Blob([jpeg], { type: "image/jpeg" }), "evidence.jpg");
  const wrongHash = await fetch(`${base}/v1/images/observe`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: wrongHashForm,
  });
  assert.equal(wrongHash.status, 422);
  assert.equal((await wrongHash.json() as any).error.code, "image_hash_mismatch");

  const foreignOriginForm = new FormData();
  foreignOriginForm.set("session_id", "session-1");
  foreignOriginForm.set("asset_sha256", imageHash);
  foreignOriginForm.set("pixel_width", "16");
  foreignOriginForm.set("pixel_height", "16");
  foreignOriginForm.set("file", new Blob([jpeg], { type: "image/jpeg" }), "evidence.jpg");
  const foreignOrigin = await fetch(`${base}/v1/images/observe`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, origin: "https://example.invalid" },
    body: foreignOriginForm,
  });
  assert.equal(foreignOrigin.status, 403);

  const contextPack = structuredClone(makeContextPack({ context_pack_id: "pack-server-1" })) as any;
  delete contextPack.approval;

  const unauthenticated = await fetch(`${base}/v1/context-packs`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(contextPack),
  });
  assert.equal(unauthenticated.status, 401);

  const selfApproved = await fetch(`${base}/v1/context-packs`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(contextPack),
  });
  assert.equal(selfApproved.status, 422);

  const approvalWithoutOperatorCredential = await fetch(`${base}/v1/context-packs/approve`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(contextPack),
  });
  assert.equal(approvalWithoutOperatorCredential.status, 401);

  const created = await fetch(`${base}/v1/context-packs/approve`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
      "x-scout-approval-token": approvalToken,
    },
    body: JSON.stringify(contextPack),
  });
  assert.equal(created.status, 201);
  const approvedContextPack = (await created.json() as any).context_pack;
  assert.equal(approvedContextPack.body.context_pack_id, "pack-server-1");
  assert.equal(approvedContextPack.approval.content_sha256, contextPack.content_sha256);

  const duplicate = await fetch(`${base}/v1/context-packs/approve`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
      "x-scout-approval-token": approvalToken,
    },
    body: JSON.stringify(contextPack),
  });
  assert.equal(duplicate.status, 200);

  const collisionPack = structuredClone(makeContextPack({
    context_pack_id: "pack-server-1",
    organization: "A different immutable context pack body.",
  })) as any;
  delete collisionPack.approval;
  const collision = await fetch(`${base}/v1/context-packs/approve`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
      "x-scout-approval-token": approvalToken,
    },
    body: JSON.stringify(collisionPack),
  });
  assert.equal(collision.status, 409);

  const read = await fetch(`${base}/v1/context-packs/pack-server-1`, {
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(read.status, 200);
  assert.equal((await read.json() as any).content_sha256, contextPack.content_sha256);

  const page = await fetch(`${base}/v1/context-packs?session_id=session-001&limit=1`, {
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(page.status, 200);
  const pageBody = await page.json() as any;
  assert.equal(pageBody.limit, 1);
  assert.equal(pageBody.context_packs.length, 1);
  assert.equal(pageBody.current_head.context_pack_id, "pack-server-1");
  assert.equal(pageBody.current_head.graph_state_sha256, contextPack.body.graph_state_sha256);

  const retiredHTTPMCP = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
  });
  assert.equal(retiredHTTPMCP.status, 404);
});
