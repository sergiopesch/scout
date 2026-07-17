#!/usr/bin/env node

import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workspace = dirname(scriptDirectory);
const version = process.env.SCOUT_RELEASE_VERSION ?? "0.1.0";
const developerTool = join(workspace, ".build", "tools", "scout-launcher");
const packagedTool = join(
  workspace,
  "dist",
  `Scout-${version}`,
  "Scout.app",
  "Contents",
  "MacOS",
  "Scout",
);

function run(executable, args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      cwd: workspace,
      stdio: ["pipe", "pipe", "pipe"],
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
    if (input === undefined) child.stdin.end();
    else child.stdin.end(input);
  });
}

const source = JSON.parse(await run(developerTool, ["secrets", "export"]));
const imported = {
  openAIAPIKey: source.openAIAPIKey,
  approvalKey: source.approvalKey,
  approvalKeyID: source.approvalKeyID,
};
const status = JSON.parse(await run(packagedTool, ["secrets", "import"], JSON.stringify(imported)));
if (!status.openAIConfigured || status.activeApprovalKeyID !== source.approvalKeyID) {
  throw new Error("Packaged Scout Keychain provisioning did not preserve the active secret boundary");
}
process.stdout.write(`Packaged Scout secrets provisioned in isolated Keychain namespace; active approval key ${status.activeApprovalKeyID}.\n`);
