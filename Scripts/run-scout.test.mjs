import assert from "node:assert/strict";
import test from "node:test";
import {
  buildAppEnvironment,
  buildGatewayEnvironment,
  createLaunchCredentials,
  parseGatewayStartedLine,
} from "./run-scout-lib.mjs";

test("launch credentials are fresh, ephemeral, and keep provider secrets out of Scout.app", () => {
  const secrets = {
    openAIAPIKey: "test-openai-api-key-that-is-not-real",
    approvalKey: "test-approval-key-that-is-at-least-thirty-two-characters",
    approvalKeyID: "scout-test-v1",
    verificationKeys: {
      "scout-test-v0": "old-test-approval-key-that-is-at-least-thirty-two-characters",
    },
  };
  const first = createLaunchCredentials(secrets);
  const second = createLaunchCredentials(secrets);

  assert.equal(first.gatewayEnvironment.SCOUT_GATEWAY_HOST, "127.0.0.1");
  assert.equal(first.gatewayEnvironment.SCOUT_GATEWAY_PORT, "0");
  assert.notEqual(first.gatewayToken, second.gatewayToken);
  assert.notEqual(first.approvalToken, second.approvalToken);
  assert.notEqual(first.instanceID, second.instanceID);
  assert.equal(first.gatewayEnvironment.OPENAI_API_KEY, secrets.openAIAPIKey);
  assert.equal(first.gatewayEnvironment.SCOUT_APPROVAL_HMAC_KEY, secrets.approvalKey);

  const gatewayEnvironment = buildGatewayEnvironment({
    parentEnvironment: {
      PATH: "/usr/bin",
      NODE_OPTIONS: "--require=/tmp/attacker.js",
      NODE_PATH: "/tmp/attacker-modules",
      DYLD_INSERT_LIBRARIES: "/tmp/attacker.dylib",
      OPENAI_BASE_URL: "http://127.0.0.1:9999/v1",
      HTTPS_PROXY: "http://127.0.0.1:8888",
      SSLKEYLOGFILE: "/tmp/keys.log",
    },
    credentials: first,
  });
  assert.equal(gatewayEnvironment.PATH, "/usr/bin");
  assert.equal(gatewayEnvironment.OPENAI_API_KEY, secrets.openAIAPIKey);
  assert.equal(gatewayEnvironment.NODE_OPTIONS, undefined);
  assert.equal(gatewayEnvironment.NODE_PATH, undefined);
  assert.equal(gatewayEnvironment.DYLD_INSERT_LIBRARIES, undefined);
  assert.equal(gatewayEnvironment.OPENAI_BASE_URL, undefined);
  assert.equal(gatewayEnvironment.HTTPS_PROXY, undefined);
  assert.equal(gatewayEnvironment.SSLKEYLOGFILE, undefined);

  const appEnvironment = buildAppEnvironment({
    parentEnvironment: {
      PATH: "/usr/bin",
      OPENAI_API_KEY: "must-not-cross-the-native-boundary",
      OPENAI_BASE_URL: "https://provider.invalid/v1",
      NODE_OPTIONS: "--require=/tmp/attacker.js",
    },
    credentials: first,
    port: 49_123,
  });
  assert.equal(appEnvironment.SCOUT_BRIDGE_URL, "http://127.0.0.1:49123");
  assert.equal(appEnvironment.SCOUT_GATEWAY_SUPERVISED, "1");
  assert.equal(appEnvironment.SCOUT_GATEWAY_INSTANCE_ID, first.instanceID);
  assert.equal(appEnvironment.OPENAI_API_KEY, undefined);
  assert.equal(appEnvironment.OPENAI_BASE_URL, undefined);
  assert.equal(appEnvironment.NODE_OPTIONS, undefined);
  assert.equal(appEnvironment.SCOUT_APPROVAL_HMAC_KEY, undefined);
  assert.equal(appEnvironment.SCOUT_APPROVAL_VERIFICATION_KEYS, undefined);
});

test("launch credential creation rejects malformed Keychain output", () => {
  assert.throws(() => createLaunchCredentials({}), /invalid secret contract/);
});

test("Gateway readiness parser accepts only the supervised child event", () => {
  assert.deepEqual(
    parseGatewayStartedLine('{"event":"gateway_started","service":"scout-gateway","host":"127.0.0.1","port":49123}'),
    { host: "127.0.0.1", port: 49_123 },
  );
  assert.equal(parseGatewayStartedLine('{"event":"gateway_started","host":"0.0.0.0","port":49123}'), null);
  assert.equal(parseGatewayStartedLine("not-json"), null);
});
