#!/usr/bin/env node

import { constants } from "node:fs";
import { access, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import {
  buildAppEnvironment,
  buildGatewayEnvironment,
  createLaunchCredentials,
  parseGatewayStartedLine,
} from "./run-scout-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workspace = dirname(scriptDirectory);
const envFile = join(workspace, ".env.local");
const gatewayDirectory = join(workspace, "Gateway");
const gatewayEntry = join(gatewayDirectory, "dist", "main.js");
const secretTool = join(workspace, ".build", "tools", "scout-launcher");
const executable = join(
  workspace,
  ".build",
  "DerivedData",
  "Build",
  "Products",
  "Debug",
  "Scout.app",
  "Contents",
  "MacOS",
  "Scout",
);

function waitForGateway(gateway, timeoutMs = 15_000) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({ input: gateway.stderr });
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("Scout Gateway did not become ready in time"));
    }, timeoutMs);
    timeout.unref();

    const onExit = () => {
      cleanup();
      reject(new Error("Scout Gateway exited before readiness"));
    };
    const onLine = (line) => {
      const address = parseGatewayStartedLine(line);
      if (!address) {
        process.stderr.write(`${line}\n`);
        return;
      }
      // Keep forwarding bounded Gateway diagnostics after readiness. Provider
      // failures otherwise disappear while the supervised child stays alive.
      cleanup(true);
      resolve(address);
    };
    const cleanup = (keepReading = false) => {
      clearTimeout(timeout);
      gateway.off("exit", onExit);
      if (!keepReading) lines.off("line", onLine);
    };
    gateway.once("exit", onExit);
    lines.on("line", onLine);
  });
}

function readKeychainSecrets() {
  return new Promise((resolve, reject) => {
    const child = spawn(secretTool, ["secrets", "export"], {
      cwd: workspace,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code !== 0) {
        reject(new Error(Buffer.concat(stderr).toString("utf8").trim() || "Scout Keychain access failed"));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(stdout).toString("utf8")));
      } catch {
        reject(new Error("Scout Keychain returned an invalid response"));
      }
    });
  });
}

async function main() {
  await access(executable, constants.X_OK);
  await access(gatewayEntry, constants.R_OK);
  await access(secretTool, constants.X_OK);
  const metadata = await stat(envFile);
  if ((metadata.mode & 0o077) !== 0) {
    throw new Error(".env.local must not be accessible to group or other users");
  }

  const credentials = createLaunchCredentials(await readKeychainSecrets());
  const gateway = spawn(process.execPath, [gatewayEntry], {
    cwd: gatewayDirectory,
    stdio: ["ignore", "ignore", "pipe"],
    env: buildGatewayEnvironment({
      parentEnvironment: process.env,
      credentials,
    }),
  });
  gateway.on("error", (error) => {
    process.stderr.write(`Scout Gateway could not start: ${error.message}\n`);
  });

  let app;
  try {
    const address = await waitForGateway(gateway);
    const appEnvironment = buildAppEnvironment({
      parentEnvironment: process.env,
      credentials,
      port: address.port,
    });
    app = spawn(executable, [], {
      stdio: "inherit",
      env: appEnvironment,
    });

    const terminate = () => {
      if (app && app.exitCode === null) app.kill("SIGTERM");
      if (gateway.exitCode === null) gateway.kill("SIGTERM");
    };
    process.once("SIGINT", terminate);
    process.once("SIGTERM", terminate);

    gateway.once("exit", () => {
      if (app && app.exitCode === null) {
        process.stderr.write("Scout Gateway stopped; closing Scout before its verified channel can be replaced.\n");
        app.kill("SIGTERM");
      }
    });

    const result = await new Promise((resolve, reject) => {
      app.once("error", reject);
      app.once("exit", (code, signal) => resolve({ code, signal }));
    });
    if (gateway.exitCode === null) gateway.kill("SIGTERM");
    process.exitCode = result.signal ? 1 : (result.code ?? 1);
  } catch (error) {
    if (app && app.exitCode === null) app.kill("SIGTERM");
    if (gateway.exitCode === null) gateway.kill("SIGTERM");
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : "Scout could not start"}\n`);
  process.exitCode = 1;
});
