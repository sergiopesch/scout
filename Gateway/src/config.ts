import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, relative, resolve } from "node:path";
import { config as loadDotEnv } from "dotenv";
import { z } from "zod/v4";

function isBundledPluginRoot(candidate: string): boolean {
  return existsSync(resolve(candidate, ".codex-plugin/plugin.json"))
    && existsSync(resolve(candidate, "mcp/scout-mcp.cjs"));
}

const currentWorkingDirectory = resolve(process.cwd());
const bundledPluginRuntime = isBundledPluginRoot(currentWorkingDirectory);

function findGatewayRoot(): string {
  const configured = process.env.SCOUT_GATEWAY_ROOT;
  if (configured !== undefined) {
    const candidate = resolve(configured);
    if (!isAbsolute(configured) || !existsSync(candidate)) {
      throw new Error("SCOUT_GATEWAY_ROOT must name an existing absolute directory");
    }
    return candidate;
  }
  if (bundledPluginRuntime) return currentWorkingDirectory;
  const candidates = [
    currentWorkingDirectory,
    resolve(currentWorkingDirectory, "Gateway"),
    // Compatibility fallback for an incomplete repository checkout without plugin markers.
    resolve(currentWorkingDirectory, "../../Gateway"),
  ];
  const match = candidates.find((candidate) => existsSync(resolve(candidate, "package.json")));
  if (!match) {
    throw new Error("Unable to resolve the Scout Gateway root");
  }
  return match;
}

export const gatewayRoot = findGatewayRoot();
export const workspaceRoot = process.env.SCOUT_WORKSPACE_ROOT === undefined
  ? (bundledPluginRuntime ? currentWorkingDirectory : resolve(gatewayRoot, ".."))
  : resolve(process.env.SCOUT_WORKSPACE_ROOT);
const pluginRuntime = bundledPluginRuntime
  || currentWorkingDirectory === resolve(workspaceRoot, "Plugins/scout");
export const dataRoot = process.env.SCOUT_DATA_ROOT === undefined
  ? (pluginRuntime && process.platform === "darwin"
      ? resolve(homedir(), "Library/Application Support/Scout")
      : workspaceRoot)
  : resolve(process.env.SCOUT_DATA_ROOT);
export const workspaceEnvPath = resolve(workspaceRoot, ".env.local");

let environmentLoaded = false;

export function loadWorkspaceEnvironment(): void {
  if (environmentLoaded) return;
  if (!pluginRuntime) loadDotEnv({ path: workspaceEnvPath, override: false, quiet: true });
  environmentLoaded = true;
}

const EnvironmentSchema = z.object({
  OPENAI_API_KEY: z.string().trim().min(20),
  OPENAI_BASE_URL: z.string().url().default("https://api.openai.com/v1"),
  OPENAI_REALTIME_MODEL: z.string().trim().min(1).max(100).default("gpt-4o-mini-transcribe"),
  OPENAI_DIARIZATION_MODEL: z.string().trim().min(1).max(100).default("gpt-4o-transcribe-diarize"),
  OPENAI_CLAIMS_MODEL: z.string().trim().min(1).max(100).default("gpt-5.6-luna"),
  OPENAI_VISION_MODEL: z.string().trim().min(1).max(100).optional(),
  SCOUT_GATEWAY_HOST: z.string().trim().min(1).max(255).default("127.0.0.1"),
  SCOUT_GATEWAY_PORT: z.coerce.number().int().min(0).max(65_535).default(0),
  SCOUT_CONTEXT_PACK_DIR: z.string().trim().min(1).optional(),
  SCOUT_GATEWAY_TOKEN: z.string().min(32).max(512).optional(),
  SCOUT_GATEWAY_INSTANCE_ID: z.string().regex(/^[A-Za-z0-9_-]{32,128}$/).optional(),
  SCOUT_APPROVAL_TOKEN: z.string().min(32).max(512).optional(),
  SCOUT_APPROVAL_ED25519_PRIVATE_KEY: z.string().regex(/^[A-Za-z0-9_-]{43}$/).optional(),
  SCOUT_APPROVAL_KEY_ID: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/).default("scout-local-v1"),
  SCOUT_APPROVAL_PUBLIC_KEYS: z.string().max(32_768).optional(),
});

export interface GatewayConfig {
  readonly apiKey: string;
  readonly openAIBaseURL: string;
  readonly realtimeModel: string;
  readonly diarizationModel: string;
  readonly claimsModel: string;
  readonly visionModel: string;
  readonly host: string;
  readonly port: number;
  readonly contextPackDirectory: string;
  readonly contextPackContainmentRoot: string;
  readonly ingestToken: string | undefined;
  readonly gatewayInstanceID: string | undefined;
  readonly approvalToken: string | undefined;
  readonly approvalPrivateKey: string | undefined;
  readonly approvalKeyID: string;
  readonly approvalPublicKeys: Readonly<Record<string, string>>;
  readonly requestTimeoutMs: number;
}

function assertSafeProviderURL(value: string): string {
  const url = new URL(value);
  const isLocal = url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "::1";
  if (url.protocol !== "https:" && !(isLocal && url.protocol === "http:")) {
    throw new Error("OPENAI_BASE_URL must use HTTPS (HTTP is permitted only for loopback tests)");
  }
  return value.replace(/\/$/, "");
}

function resolveContextPackDirectory(value: string | undefined): string {
  const candidate = value
    ? resolve(isAbsolute(value) ? value : resolve(workspaceRoot, value))
    : resolve(dataRoot, "context-packs");
  const pathFromDataRoot = relative(dataRoot, candidate);
  if (pathFromDataRoot === ".." || pathFromDataRoot.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) {
    throw new Error("SCOUT_CONTEXT_PACK_DIR must stay inside Scout's configured data root");
  }
  return candidate;
}

function parseApprovalPublicKeys(value: string | undefined): Readonly<Record<string, string>> {
  if (value === undefined) return {};
  let candidate: unknown;
  try {
    candidate = JSON.parse(value);
  } catch {
    throw new Error("SCOUT_APPROVAL_PUBLIC_KEYS is invalid");
  }
  const parsed = z.record(
    z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/),
    z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  ).safeParse(candidate);
  if (!parsed.success || Object.keys(parsed.data).length > 32) {
    throw new Error("SCOUT_APPROVAL_PUBLIC_KEYS is invalid");
  }
  return parsed.data;
}

const ApprovalPublicKeyringSchema = z.object({
  version: z.literal(1),
  generation: z.number().int().positive(),
  active_key_id: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/),
  keys: z.record(
    z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/),
    z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  ),
  revoked_key_ids: z.array(
    z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/),
  ).max(32),
}).strict();

function loadPublishedApprovalPublicKeys(
  environment: NodeJS.ProcessEnv,
): Readonly<Record<string, string>> {
  const configuredRoot = environment.SCOUT_DATA_ROOT;
  const root = configuredRoot === undefined ? dataRoot : resolve(configuredRoot);
  const keyringPath = resolve(root, "approval-public-keyring-v1.json");
  if (!existsSync(keyringPath)) return {};
  try {
    const metadata = lstatSync(keyringPath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 32_768) {
      throw new Error("unsafe approval public keyring file");
    }
    const canonicalRoot = realpathSync(root);
    const canonicalPath = realpathSync(keyringPath);
    const pathFromRoot = relative(canonicalRoot, canonicalPath);
    if (pathFromRoot === ".." || pathFromRoot.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) {
      throw new Error("approval public keyring escapes the data root");
    }
    const parsed = ApprovalPublicKeyringSchema.parse(
      JSON.parse(readFileSync(canonicalPath, "utf8")),
    );
    if (Object.keys(parsed.keys).length === 0
      || Object.keys(parsed.keys).length > 32
      || parsed.keys[parsed.active_key_id] === undefined
      || parsed.revoked_key_ids.some((keyID) => parsed.keys[keyID] !== undefined)) {
      throw new Error("inconsistent approval public keyring");
    }
    return parsed.keys;
  } catch {
    throw new Error("Scout's published approval public keyring is invalid");
  }
}

function approvalPublicKeys(
  environment: NodeJS.ProcessEnv,
  configured: string | undefined,
): Readonly<Record<string, string>> {
  return configured === undefined
    ? loadPublishedApprovalPublicKeys(environment)
    : parseApprovalPublicKeys(configured);
}

export function loadGatewayConfig(
  environment: NodeJS.ProcessEnv = process.env,
  options: { loadWorkspaceEnv?: boolean } = {},
): GatewayConfig {
  if (options.loadWorkspaceEnv ?? environment === process.env) {
    loadWorkspaceEnvironment();
  }

  const parsed = EnvironmentSchema.safeParse(environment);
  if (!parsed.success) {
    throw new Error("Scout Gateway configuration is incomplete or invalid");
  }

  const loopbackHosts = new Set(["127.0.0.1", "::1", "localhost"]);
  if (!loopbackHosts.has(parsed.data.SCOUT_GATEWAY_HOST)) {
    throw new Error("Scout Gateway binds only to loopback");
  }

  return {
    apiKey: parsed.data.OPENAI_API_KEY,
    openAIBaseURL: assertSafeProviderURL(parsed.data.OPENAI_BASE_URL),
    realtimeModel: parsed.data.OPENAI_REALTIME_MODEL,
    diarizationModel: parsed.data.OPENAI_DIARIZATION_MODEL,
    claimsModel: parsed.data.OPENAI_CLAIMS_MODEL,
    visionModel: parsed.data.OPENAI_VISION_MODEL ?? parsed.data.OPENAI_CLAIMS_MODEL,
    host: parsed.data.SCOUT_GATEWAY_HOST,
    port: parsed.data.SCOUT_GATEWAY_PORT,
    contextPackDirectory: resolveContextPackDirectory(parsed.data.SCOUT_CONTEXT_PACK_DIR),
    contextPackContainmentRoot: dataRoot,
    ingestToken: parsed.data.SCOUT_GATEWAY_TOKEN,
    gatewayInstanceID: parsed.data.SCOUT_GATEWAY_INSTANCE_ID,
    approvalToken: parsed.data.SCOUT_APPROVAL_TOKEN,
    approvalPrivateKey: parsed.data.SCOUT_APPROVAL_ED25519_PRIVATE_KEY,
    approvalKeyID: parsed.data.SCOUT_APPROVAL_KEY_ID,
    approvalPublicKeys: approvalPublicKeys(environment, parsed.data.SCOUT_APPROVAL_PUBLIC_KEYS),
    requestTimeoutMs: 60_000,
  };
}

export function loadContextPackDirectory(environment: NodeJS.ProcessEnv = process.env): string {
  if (environment === process.env) loadWorkspaceEnvironment();
  return resolveContextPackDirectory(environment.SCOUT_CONTEXT_PACK_DIR);
}

export function loadContextPackApprovalOptions(
  environment: NodeJS.ProcessEnv = process.env,
): {
  signingKey?: { keyID: string; privateKey: string };
  verificationKeys: Readonly<Record<string, string>>;
} | undefined {
  if (environment === process.env) loadWorkspaceEnvironment();
  const privateKey = environment.SCOUT_APPROVAL_ED25519_PRIVATE_KEY;
  const keyID = environment.SCOUT_APPROVAL_KEY_ID ?? "scout-local-v1";
  const verificationKeys = approvalPublicKeys(environment, environment.SCOUT_APPROVAL_PUBLIC_KEYS);
  if (privateKey === undefined && Object.keys(verificationKeys).length === 0) return undefined;
  if (privateKey !== undefined && !/^[A-Za-z0-9_-]{43}$/.test(privateKey)) {
    throw new Error("SCOUT_APPROVAL_ED25519_PRIVATE_KEY is invalid");
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(keyID)) {
    throw new Error("SCOUT_APPROVAL_KEY_ID is invalid");
  }
  return {
    ...(privateKey === undefined ? {} : { signingKey: { keyID, privateKey } }),
    verificationKeys,
  };
}
