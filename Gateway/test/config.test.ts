import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { loadContextPackApprovalOptions, loadGatewayConfig } from "../src/config.js";

const baseEnvironment: NodeJS.ProcessEnv = {
  OPENAI_API_KEY: "test-api-key-not-a-real-secret",
  SCOUT_GATEWAY_TOKEN: "local-test-token-that-is-at-least-thirty-two-characters",
};

test("Gateway accepts only explicit loopback bind hosts", () => {
  for (const host of ["127.0.0.1", "::1", "localhost"]) {
    assert.equal(
      loadGatewayConfig({ ...baseEnvironment, SCOUT_GATEWAY_HOST: host }, { loadWorkspaceEnv: false }).host,
      host,
    );
  }
});

test("Gateway defaults realtime transcription to a supported production model", () => {
  assert.equal(
    loadGatewayConfig(baseEnvironment, { loadWorkspaceEnv: false }).realtimeModel,
    "gpt-4o-mini-transcribe",
  );
});

test("Gateway cannot be configured to bind off-host", () => {
  assert.throws(
    () => loadGatewayConfig({
      ...baseEnvironment,
      SCOUT_GATEWAY_HOST: "0.0.0.0",
      SCOUT_ALLOW_NON_LOOPBACK: "true",
    }, { loadWorkspaceEnv: false }),
    /binds only to loopback/,
  );
});

test("image observations use the claims model by default and accept an explicit model override", () => {
  assert.equal(
    loadGatewayConfig({ ...baseEnvironment, OPENAI_CLAIMS_MODEL: "gpt-claims" }, { loadWorkspaceEnv: false }).visionModel,
    "gpt-claims",
  );
  assert.equal(
    loadGatewayConfig({ ...baseEnvironment, OPENAI_VISION_MODEL: "gpt-vision" }, { loadWorkspaceEnv: false }).visionModel,
    "gpt-vision",
  );
});

test("Gateway accepts a bounded approval verification keyring and rejects malformed rotation state", () => {
  const configuration = loadGatewayConfig({
    ...baseEnvironment,
    SCOUT_APPROVAL_ED25519_PRIVATE_KEY: Buffer.alloc(32, 3).toString("base64url"),
    SCOUT_APPROVAL_KEY_ID: "scout-local-v2",
    SCOUT_APPROVAL_PUBLIC_KEYS: JSON.stringify({
      "scout-local-v1": Buffer.alloc(32, 4).toString("base64url"),
    }),
  }, { loadWorkspaceEnv: false });
  assert.deepEqual(configuration.approvalPublicKeys, {
    "scout-local-v1": Buffer.alloc(32, 4).toString("base64url"),
  });

  assert.throws(
    () => loadGatewayConfig({
      ...baseEnvironment,
      SCOUT_APPROVAL_PUBLIC_KEYS: "not-json",
    }, { loadWorkspaceEnv: false }),
    /SCOUT_APPROVAL_PUBLIC_KEYS is invalid/,
  );
});

test("standalone verification loads only the published public keyring and rejects unsafe state", (context) => {
  const root = mkdtempSync(join(tmpdir(), "scout-public-keyring-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(root, { recursive: true });
  const publicKey = Buffer.alloc(32, 8).toString("base64url");
  const keyringPath = join(root, "approval-public-keyring-v1.json");
  writeFileSync(keyringPath, JSON.stringify({
    version: 1,
    generation: 2,
    active_key_id: "scout-local-v2",
    keys: { "scout-local-v2": publicKey },
    revoked_key_ids: ["scout-local-v1"],
  }));
  assert.deepEqual(loadContextPackApprovalOptions({ SCOUT_DATA_ROOT: root }), {
    verificationKeys: { "scout-local-v2": publicKey },
  });

  writeFileSync(keyringPath, JSON.stringify({
    version: 1,
    generation: 2,
    active_key_id: "scout-local-v2",
    keys: { "scout-local-v2": publicKey, "scout-local-v1": publicKey },
    revoked_key_ids: ["scout-local-v1"],
  }));
  assert.throws(
    () => loadContextPackApprovalOptions({ SCOUT_DATA_ROOT: root }),
    /published approval public keyring is invalid/,
  );
});
