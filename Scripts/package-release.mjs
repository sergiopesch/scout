#!/usr/bin/env node

import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  access,
  chmod,
  copyFile,
  cp,
  mkdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { constants } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import {
  parsePackagingMode,
  releasePaths,
  validateBuildNumber,
  validateReleaseVersion,
} from "./release-policy.mjs";

process.on("uncaughtException", (error) => {
  process.stderr.write(`${error instanceof Error ? error.message : "Scout release packaging failed"}\n`);
  process.exitCode = 1;
});

const runFile = promisify(execFile);
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workspace = dirname(scriptDirectory);
const version = validateReleaseVersion(process.env.SCOUT_RELEASE_VERSION ?? "0.1.0");
const buildNumber = validateBuildNumber(process.env.SCOUT_BUILD_NUMBER ?? "1");
const mode = parsePackagingMode(process.argv.slice(2));
const identity = mode === "notarize" ? process.env.SCOUT_SIGNING_IDENTITY : "-";
const notaryProfile = process.env.SCOUT_NOTARY_PROFILE;
const nodeSource = process.env.SCOUT_RELEASE_NODE;
const requiredReleaseNodeVersion = "v24.14.0";
const nodeLicense = process.env.SCOUT_NODE_LICENSE_PATH;
const {
  distRoot,
  outputRoot,
  zip,
  dmg,
  dmgStaging,
} = releasePaths(workspace, version);
const app = join(outputRoot, "Scout.app");
const contents = join(app, "Contents");
const resources = join(contents, "Resources");
const runtime = join(resources, "runtime");
const uiApp = join(resources, "ScoutUI.app");
const launcher = join(contents, "MacOS", "Scout");
const releaseScratch = join(workspace, ".build", "release", String(process.pid));
const releaseSBOM = join(releaseScratch, "gateway-sbom.cdx.json");
const notarization = {};

async function run(command, args, options = {}) {
  try {
    return await runFile(command, args, {
      cwd: workspace,
      maxBuffer: 32 * 1024 * 1024,
      ...options,
    });
  } catch (error) {
    const detail = error?.stderr?.trim() || error?.stdout?.trim() || error?.message || `${command} failed`;
    throw new Error(detail);
  }
}

async function assertSelfContainedNode(path) {
  await access(path, constants.X_OK);
  const { stdout: architectureOutput } = await run("lipo", ["-archs", path]);
  const architectures = architectureOutput.trim().split(/\s+/u).filter(Boolean);
  if (architectures.length !== 1 || architectures[0] !== "arm64") {
    throw new Error(`SCOUT_RELEASE_NODE must be arm64; observed ${architectures.join(", ") || "unknown"}`);
  }
  const { stdout } = await run("otool", ["-L", path]);
  const unsafe = stdout.split("\n").slice(1).map((line) => line.trim()).filter(Boolean).filter((line) => {
    const dependency = line.split(" ")[0];
    return !dependency.startsWith("/System/Library/") && !dependency.startsWith("/usr/lib/");
  });
  if (unsafe.length > 0) {
    throw new Error(`SCOUT_RELEASE_NODE is not self-contained: ${unsafe.join(", ")}`);
  }
  return architectures;
}

async function compileLauncher() {
  const launcherArguments = [
    "swiftc",
    "-parse-as-library",
    "-O",
    "-framework",
    "Security",
    "-framework",
    "LocalAuthentication",
    "-framework",
    "CryptoKit",
  ];
  if (mode === "adhoc") launcherArguments.push("-D", "SCOUT_ADHOC_PROVISIONING");
  launcherArguments.push(
    join(workspace, "Tools/ScoutLauncher/LauncherSecurityPolicy.swift"),
    join(workspace, "Tools/ScoutLauncher/main.swift"),
    "-o",
    launcher,
  );
  await run("xcrun", launcherArguments);
}

async function sign(path, entitlements) {
  const args = ["--force", "--sign", identity, "--options", "runtime"];
  if (identity !== "-") args.push("--timestamp");
  if (entitlements) args.push("--entitlements", entitlements);
  args.push(path);
  await run("codesign", args);
}

async function sha256(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function fileRecord(path, packagedPath) {
  return {
    path: packagedPath,
    sha256: await sha256(path),
    bytes: (await stat(path)).size,
  };
}

async function gitStatus() {
  return (await run("git", ["status", "--porcelain=v1", "--untracked-files=normal"]))
    .stdout.trim();
}

async function notarize(path, label) {
  const { stdout } = await run("xcrun", [
    "notarytool", "submit", path,
    "--keychain-profile", notaryProfile,
    "--wait",
    "--output-format", "json",
  ]);
  let submission;
  try {
    submission = JSON.parse(stdout);
  } catch {
    throw new Error(`Apple returned an invalid ${label} notarization response`);
  }
  if (submission.status !== "Accepted" || typeof submission.id !== "string") {
    throw new Error(`${label} notarization was not accepted`);
  }
  const logPath = join(distRoot, `notarization-${label}.json`);
  await run("xcrun", [
    "notarytool", "log", submission.id,
    "--keychain-profile", notaryProfile,
    logPath,
  ]);
  const log = JSON.parse(await readFile(logPath, "utf8"));
  if (Array.isArray(log.issues) && log.issues.length > 0) {
    throw new Error(`${label} notarization log contains ${log.issues.length} issue(s); inspect ${logPath}`);
  }
  return { id: submission.id, log: basename(logPath) };
}

if (mode === "notarize") {
  if (!identity?.startsWith("Developer ID Application:")) {
    throw new Error("SCOUT_SIGNING_IDENTITY must name a Developer ID Application identity");
  }
  if (!notaryProfile) throw new Error("SCOUT_NOTARY_PROFILE is required for notarization");
  if (!nodeLicense) throw new Error("SCOUT_NODE_LICENSE_PATH is required for a distributable release");
  if (process.version !== requiredReleaseNodeVersion) {
    throw new Error(
      `Distributable packaging must run under Node ${requiredReleaseNodeVersion}; observed ${process.version}`,
    );
  }
  await access(nodeLicense, constants.R_OK);
}

if (process.arch !== "arm64") throw new Error(`Scout macOS packaging requires an arm64 host process; observed ${process.arch}`);
if (!nodeSource) {
  throw new Error(
    "SCOUT_RELEASE_NODE is required and must point to a verified, self-contained arm64 Node binary; see docs/release.md",
  );
}
const nodeArchitectures = await assertSelfContainedNode(nodeSource);
const nodeVersion = (await run(nodeSource, ["--version"])).stdout.trim();
if (nodeVersion !== requiredReleaseNodeVersion) {
  throw new Error(
    `SCOUT_RELEASE_NODE must be ${requiredReleaseNodeVersion}; observed ${nodeVersion || "unknown"}`,
  );
}
const sourceCommit = (await run("git", ["rev-parse", "HEAD"])).stdout.trim();
const sourceStatusBeforeBuild = await gitStatus();
const sourceDirtyBeforeBuild = sourceStatusBeforeBuild.length > 0;
if (mode === "notarize" && sourceDirtyBeforeBuild) {
  throw new Error("Distributable Scout builds require a clean Git worktree");
}
const requiredXcodeGenVersion = (await readFile(join(workspace, ".xcodegen-version"), "utf8")).trim();
const xcodegenVersion = (await run("xcodegen", ["--version"])).stdout.trim();
if (mode === "notarize" && xcodegenVersion !== `Version: ${requiredXcodeGenVersion}`) {
  throw new Error(
    `Distributable packaging requires XcodeGen ${requiredXcodeGenVersion}; observed ${xcodegenVersion}`,
  );
}
const toolchain = {
  xcode: (await run("xcodebuild", ["-version"])).stdout.trim().replaceAll("\n", " · "),
  swift: (await run("xcrun", ["swift", "--version"])).stdout.trim().replaceAll("\n", " · "),
  xcodegen: xcodegenVersion,
  node: process.version,
  npm: (await run("npm", ["--version"])).stdout.trim(),
};
await rm(outputRoot, { recursive: true, force: true });
await rm(zip, { force: true });
await rm(dmg, { force: true });
await rm(releaseScratch, { recursive: true, force: true });
await mkdir(runtime, { recursive: true });
await mkdir(join(contents, "MacOS"), { recursive: true });
await mkdir(releaseScratch, { recursive: true });

await run("npm", ["ci"], { cwd: join(workspace, "Gateway") });
await run("xcodegen", ["generate"]);
await run("xcodebuild", [
  "-project", "Scout.xcodeproj",
  "-scheme", "Scout",
  "-configuration", "Release",
  "-destination", "platform=macOS",
  "-derivedDataPath", ".build/DerivedData",
  "CODE_SIGNING_ALLOWED=NO",
  "build",
]);
await run("npm", ["run", "build"], { cwd: join(workspace, "Gateway") });
await run("npm", ["sbom", "--sbom-format", "cyclonedx", "--omit", "dev"], {
  cwd: join(workspace, "Gateway"),
}).then(({ stdout }) => writeFile(releaseSBOM, stdout));

await cp(join(workspace, ".build/DerivedData/Build/Products/Release/Scout.app"), uiApp, { recursive: true });
await copyFile(nodeSource, join(runtime, "node"));
await chmod(join(runtime, "node"), 0o755);
await copyFile(join(workspace, "Gateway/dist/scout-gateway.cjs"), join(runtime, "scout-gateway.cjs"));
await copyFile(join(workspace, "Packaging/Launcher-Info.plist"), join(contents, "Info.plist"));
await run("plutil", ["-replace", "CFBundleShortVersionString", "-string", version, join(contents, "Info.plist")]);
await run("plutil", ["-replace", "CFBundleVersion", "-string", buildNumber, join(contents, "Info.plist")]);
await run("plutil", [
  "-replace", "ScoutKeychainNamespace", "-string",
  mode === "notarize" ? "release-v1" : `adhoc-${randomUUID()}`,
  join(contents, "Info.plist"),
]);
await copyFile(join(workspace, "ScoutApp/Resources/Assets.xcassets/AppIcon.appiconset/icon-512.png"), join(resources, "Scout.png"));
await copyFile(join(workspace, "Packaging/THIRD_PARTY_NOTICES.md"), join(resources, "THIRD_PARTY_NOTICES.md"));
await copyFile(join(workspace, "Packaging/GATEWAY_THIRD_PARTY_LICENSES.txt"), join(resources, "GATEWAY_THIRD_PARTY_LICENSES.txt"));
await copyFile(releaseSBOM, join(resources, "gateway-sbom.cdx.json"));
await copyFile(join(workspace, "Gateway/package-lock.json"), join(resources, "gateway-package-lock.json"));
if (nodeLicense) await copyFile(nodeLicense, join(resources, "NODE-LICENSE"));
await compileLauncher();

const sourceStatusBeforeSigning = await gitStatus();
const sourceDirtyBeforeSigning = sourceStatusBeforeSigning.length > 0;
if (mode === "notarize" && sourceDirtyBeforeSigning) {
  throw new Error(
    "Distributable build steps changed tracked source; commit deterministic generated artifacts before signing",
  );
}

await sign(join(runtime, "node"), join(workspace, "Packaging/Node.entitlements"));
await sign(uiApp, join(workspace, "ScoutApp/Resources/Scout.entitlements"));
await sign(launcher, join(workspace, "Packaging/Launcher.entitlements"));
await sign(app, join(workspace, "Packaging/Launcher.entitlements"));
await run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", app]);

await mkdir(distRoot, { recursive: true });
await run("ditto", ["-c", "-k", "--keepParent", app, zip]);

if (mode === "notarize") {
  notarization.app_zip = await notarize(zip, "app-zip");
  await run("xcrun", ["stapler", "staple", app]);
  await run("xcrun", ["stapler", "validate", app]);
  await rm(zip, { force: true });
  await run("ditto", ["-c", "-k", "--keepParent", app, zip]);
}

await rm(dmgStaging, { recursive: true, force: true });
await mkdir(dmgStaging, { recursive: true });
await cp(app, join(dmgStaging, "Scout.app"), { recursive: true });
await run("hdiutil", [
  "create", "-volname", "Scout", "-srcfolder", dmgStaging,
  "-ov", "-format", "UDZO", dmg,
]);
await rm(dmgStaging, { recursive: true, force: true });
await run("hdiutil", ["verify", dmg]);

if (mode === "notarize") {
  await sign(dmg);
  notarization.dmg = await notarize(dmg, "dmg");
  await run("xcrun", ["stapler", "staple", dmg]);
  await run("xcrun", ["stapler", "validate", dmg]);
  await run("spctl", ["--assess", "--type", "execute", "--verbose=4", app]);
}

const manifest = {
  schema_version: 1,
  version,
  build_number: buildNumber,
  signing_mode: mode,
  source: {
    commit: sourceCommit,
    dirty_before_build: sourceDirtyBeforeBuild,
    dirty_before_signing: sourceDirtyBeforeSigning,
  },
  toolchain,
  notarization: mode === "notarize" ? notarization : null,
  architecture: process.arch,
  node: { version: nodeVersion, architectures: nodeArchitectures, sha256: await sha256(join(runtime, "node")) },
  dependencies: {
    gateway_sbom: await fileRecord(
      join(resources, "gateway-sbom.cdx.json"),
      "Scout.app/Contents/Resources/gateway-sbom.cdx.json",
    ),
    gateway_package_lock: await fileRecord(
      join(resources, "gateway-package-lock.json"),
      "Scout.app/Contents/Resources/gateway-package-lock.json",
    ),
    gateway_licenses: await fileRecord(
      join(resources, "GATEWAY_THIRD_PARTY_LICENSES.txt"),
      "Scout.app/Contents/Resources/GATEWAY_THIRD_PARTY_LICENSES.txt",
    ),
    node_license: nodeLicense
      ? await fileRecord(
        join(resources, "NODE-LICENSE"),
        "Scout.app/Contents/Resources/NODE-LICENSE",
      )
      : null,
  },
  artifacts: {
    zip: { path: `Scout-${version}-macOS.zip`, sha256: await sha256(zip), bytes: (await stat(zip)).size },
    dmg: { path: `Scout-${version}-macOS.dmg`, sha256: await sha256(dmg), bytes: (await stat(dmg)).size },
  },
};
await writeFile(join(outputRoot, "release-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
await rm(releaseScratch, { recursive: true, force: true });
process.stdout.write(`${JSON.stringify({ event: "scout_release_packaged", ...manifest })}\n`);
