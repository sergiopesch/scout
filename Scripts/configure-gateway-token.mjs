#!/usr/bin/env node

import { spawn } from "node:child_process";
import { chmod, mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workspace = dirname(scriptDirectory);
const target = join(workspace, ".env.local");
const temporary = join(workspace, `.env.local.${process.pid}.tmp`);
const source = join(workspace, "Tools", "ScoutLauncher", "main.swift");
const policySource = join(workspace, "Tools", "ScoutLauncher", "LauncherSecurityPolicy.swift");
const tool = join(workspace, ".build", "tools", "scout-launcher");

function run(executable, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      cwd: workspace,
      stdio: ["pipe", "pipe", "pipe"],
      ...options,
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code !== 0) {
        reject(new Error(Buffer.concat(stderr).toString("utf8").trim() || `${executable} failed`));
        return;
      }
      resolve(Buffer.concat(stdout).toString("utf8"));
    });
    if (options.input !== undefined) child.stdin.end(options.input);
    else child.stdin.end();
  });
}

async function compileSecretTool() {
  await mkdir(dirname(tool), { recursive: true });
  let rebuild = false;
  try {
    const toolModifiedAt = (await stat(tool)).mtimeMs;
    rebuild = (await stat(source)).mtimeMs > toolModifiedAt
      || (await stat(policySource)).mtimeMs > toolModifiedAt;
  } catch {
    rebuild = true;
  }
  if (!rebuild) return;
  await run("xcrun", [
    "swiftc",
    "-parse-as-library",
    "-O",
    "-D",
    "SCOUT_SECRET_TOOL",
    "-framework",
    "Security",
    "-framework",
    "LocalAuthentication",
    policySource,
    source,
    "-o",
    tool,
  ]);
}

function valueFor(contents, name) {
  const line = contents.split(/\r?\n/u).find((candidate) => candidate.startsWith(`${name}=`));
  if (!line) return undefined;
  const raw = line.slice(name.length + 1).trim();
  if ((raw.startsWith('"') && raw.endsWith('"')) || (raw.startsWith("'") && raw.endsWith("'"))) {
    return raw.slice(1, -1);
  }
  return raw;
}

await compileSecretTool();

let contents = "";
try {
  contents = await readFile(target, "utf8");
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}

const imported = {
  openAIAPIKey: valueFor(contents, "OPENAI_API_KEY"),
  approvalKey: valueFor(contents, "SCOUT_APPROVAL_HMAC_KEY"),
  approvalKeyID: valueFor(contents, "SCOUT_APPROVAL_KEY_ID"),
};
const statusJSON = await run(tool, ["secrets", "import"], {
  input: JSON.stringify(imported),
});
const status = JSON.parse(statusJSON);
if (!status.openAIConfigured) {
  throw new Error("OPENAI_API_KEY is not configured. Save it to .env.local once, then rerun make configure-secrets.");
}

const secretNames = new Set([
  "OPENAI_API_KEY",
  "SCOUT_GATEWAY_TOKEN",
  "SCOUT_APPROVAL_TOKEN",
  "SCOUT_APPROVAL_HMAC_KEY",
  "SCOUT_APPROVAL_KEY_ID",
  "SCOUT_APPROVAL_VERIFICATION_KEYS",
]);
const sanitized = contents
  .split(/\r?\n/u)
  .filter((line) => {
    const separator = line.indexOf("=");
    return separator < 0 || !secretNames.has(line.slice(0, separator).trim());
  });
while (sanitized.at(-1) === "") sanitized.pop();
sanitized.push("");

await writeFile(temporary, sanitized.join("\n"), { mode: 0o600 });
await chmod(temporary, 0o600);
await rename(temporary, target);
await chmod(target, 0o600);
process.stdout.write(
  `Scout secrets are stored in device-local Keychain; active approval key ${status.activeApprovalKeyID}.\n`,
);
