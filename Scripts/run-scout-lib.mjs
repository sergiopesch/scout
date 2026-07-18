import { createPrivateKey, createPublicKey, randomBytes } from "node:crypto";

const inheritedDevelopmentChildKeys = new Set([
  "AppleLanguages",
  "AppleLocale",
  "HOME",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "PATH",
  "TMPDIR",
  "TZ",
  "__CF_USER_TEXT_ENCODING",
]);

function inheritedDevelopmentEnvironment(parentEnvironment) {
  return Object.fromEntries(
    Object.entries(parentEnvironment).filter(([key]) => inheritedDevelopmentChildKeys.has(key)),
  );
}

export function createLaunchCredentials(secretExport) {
  if (!secretExport || typeof secretExport.openAIAPIKey !== "string" || secretExport.openAIAPIKey.length < 20
    || typeof secretExport.approvalPrivateKey !== "string"
    || !/^[A-Za-z0-9_-]{43}$/u.test(secretExport.approvalPrivateKey)
    || typeof secretExport.approvalKeyID !== "string"
    || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u.test(secretExport.approvalKeyID)
    || !secretExport.verificationKeys || typeof secretExport.verificationKeys !== "object"
    || Array.isArray(secretExport.verificationKeys)
    || !Array.isArray(secretExport.revokedKeyIDs)) {
    throw new Error("Scout Keychain returned an invalid secret contract");
  }
  const entries = Object.entries(secretExport.verificationKeys);
  const revoked = new Set(secretExport.revokedKeyIDs);
  if (entries.length > 32 || revoked.size > 256 || revoked.size !== secretExport.revokedKeyIDs.length
    || entries.some(([keyID, key]) => !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u.test(keyID)
      || typeof key !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(key))
    || [...revoked].some((keyID) => typeof keyID !== "string"
      || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u.test(keyID)
      || secretExport.verificationKeys[keyID] !== undefined)
    || revoked.has(secretExport.approvalKeyID)) {
    throw new Error("Scout Keychain returned an invalid secret contract");
  }
  const privateObject = createPrivateKey({
    key: Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"),
      Buffer.from(secretExport.approvalPrivateKey, "base64url"),
    ]),
    format: "der",
    type: "pkcs8",
  });
  const activePublic = createPublicKey(privateObject).export({ format: "der", type: "spki" })
    .subarray(-32).toString("base64url");
  if (secretExport.verificationKeys[secretExport.approvalKeyID] !== activePublic) {
    throw new Error("Scout Keychain returned an invalid secret contract");
  }
  const verificationKeys = Object.fromEntries(entries);
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
      SCOUT_APPROVAL_ED25519_PRIVATE_KEY: secretExport.approvalPrivateKey,
      SCOUT_APPROVAL_KEY_ID: secretExport.approvalKeyID,
      SCOUT_APPROVAL_PUBLIC_KEYS: JSON.stringify(verificationKeys),
    },
  };
}

export function buildGatewayEnvironment({ parentEnvironment, credentials }) {
  return {
    ...inheritedDevelopmentEnvironment(parentEnvironment),
    ...credentials.gatewayEnvironment,
  };
}

export function buildAppEnvironment({ parentEnvironment, credentials, port }) {
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("Scout Gateway returned an invalid ephemeral port");
  }
  const environment = {
    ...inheritedDevelopmentEnvironment(parentEnvironment),
    SCOUT_BRIDGE_URL: `http://127.0.0.1:${port}`,
    SCOUT_GATEWAY_TOKEN: credentials.gatewayToken,
    SCOUT_APPROVAL_TOKEN: credentials.approvalToken,
    SCOUT_GATEWAY_INSTANCE_ID: credentials.instanceID,
    SCOUT_GATEWAY_SUPERVISED: "1",
  };
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
