import assert from "node:assert/strict";
import test from "node:test";
import { loadGatewayConfig } from "../src/config.js";

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
    SCOUT_APPROVAL_HMAC_KEY: "active-approval-key-that-is-at-least-thirty-two-bytes",
    SCOUT_APPROVAL_KEY_ID: "scout-local-v2",
    SCOUT_APPROVAL_VERIFICATION_KEYS: JSON.stringify({
      "scout-local-v1": "retained-approval-key-that-is-at-least-thirty-two-bytes",
    }),
  }, { loadWorkspaceEnv: false });
  assert.deepEqual(configuration.approvalVerificationKeys, {
    "scout-local-v1": "retained-approval-key-that-is-at-least-thirty-two-bytes",
  });

  assert.throws(
    () => loadGatewayConfig({
      ...baseEnvironment,
      SCOUT_APPROVAL_VERIFICATION_KEYS: "not-json",
    }, { loadWorkspaceEnv: false }),
    /SCOUT_APPROVAL_VERIFICATION_KEYS is invalid/,
  );
});
