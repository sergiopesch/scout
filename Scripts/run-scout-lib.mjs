import { randomBytes } from "node:crypto";

export function createLaunchCredentials(secretExport) {
  if (!secretExport || typeof secretExport.openAIAPIKey !== "string" || secretExport.openAIAPIKey.length < 20
    || typeof secretExport.approvalKey !== "string" || secretExport.approvalKey.length < 32
    || typeof secretExport.approvalKeyID !== "string"
    || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u.test(secretExport.approvalKeyID)
    || !secretExport.verificationKeys || typeof secretExport.verificationKeys !== "object"
    || Array.isArray(secretExport.verificationKeys)) {
    throw new Error("Scout Keychain returned an invalid secret contract");
  }
  const gatewayToken = randomBytes(48).toString("base64url");
  const approvalToken = randomBytes(48).toString("base64url");
  const instanceID = randomBytes(48).toString("base64url");
  return {
    gatewayToken,
    approvalToken,
    instanceID,
    gatewayEnvironment: {
      SCOUT_GATEWAY_HOST: "127.0.0.1",
      SCOUT_GATEWAY_PORT: "0",
      SCOUT_GATEWAY_TOKEN: gatewayToken,
      SCOUT_APPROVAL_TOKEN: approvalToken,
      SCOUT_GATEWAY_INSTANCE_ID: instanceID,
      OPENAI_API_KEY: secretExport.openAIAPIKey,
      SCOUT_APPROVAL_HMAC_KEY: secretExport.approvalKey,
      SCOUT_APPROVAL_KEY_ID: secretExport.approvalKeyID,
      SCOUT_APPROVAL_VERIFICATION_KEYS: JSON.stringify(secretExport.verificationKeys),
    },
  };
}

export function buildAppEnvironment({ parentEnvironment, credentials, port }) {
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("Scout Gateway returned an invalid ephemeral port");
  }
  const environment = {
    ...parentEnvironment,
    SCOUT_BRIDGE_URL: `http://127.0.0.1:${port}`,
    SCOUT_GATEWAY_TOKEN: credentials.gatewayToken,
    SCOUT_APPROVAL_TOKEN: credentials.approvalToken,
    SCOUT_GATEWAY_INSTANCE_ID: credentials.instanceID,
    SCOUT_GATEWAY_SUPERVISED: "1",
  };
  delete environment.OPENAI_API_KEY;
  delete environment.OPENAI_BASE_URL;
  delete environment.SCOUT_APPROVAL_HMAC_KEY;
  delete environment.SCOUT_APPROVAL_KEY_ID;
  delete environment.SCOUT_APPROVAL_VERIFICATION_KEYS;
  return environment;
}

export function parseGatewayStartedLine(line) {
  let value;
  try {
    value = JSON.parse(line);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object"
    || value.event !== "gateway_started"
    || value.service !== "scout-gateway"
    || value.host !== "127.0.0.1"
    || !Number.isInteger(value.port)
    || value.port < 1
    || value.port > 65_535) return null;
  return { host: value.host, port: value.port };
}
