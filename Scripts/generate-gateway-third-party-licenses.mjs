#!/usr/bin/env node

import { access, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const workspace = dirname(scriptDirectory);
const gatewayRoot = join(workspace, "Gateway");
const lockPath = join(gatewayRoot, "package-lock.json");
const outputPath = join(workspace, "Packaging", "GATEWAY_THIRD_PARTY_LICENSES.txt");
const arguments_ = process.argv.slice(2);
if (arguments_.some((argument) => argument !== "--check") || arguments_.length > 1) {
  throw new Error("Usage: generate-gateway-third-party-licenses.mjs [--check]");
}
const checkOnly = arguments_[0] === "--check";
const lock = JSON.parse(await readFile(lockPath, "utf8"));
const licenseNamePattern = /^(?:licen[cs]e|copying|notice|copyright)(?:$|[._-])/iu;

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function packageName(packagePath) {
  const marker = "node_modules/";
  return packagePath.slice(packagePath.lastIndexOf(marker) + marker.length);
}

const entries = Object.entries(lock.packages ?? {})
  .filter(([packagePath, metadata]) => (
    packagePath.startsWith("node_modules/")
      && metadata?.dev !== true
      && metadata?.devOptional !== true
  ))
  .sort(([leftPath, left], [rightPath, right]) => compare(
    `${packageName(leftPath)}@${left.version}`,
    `${packageName(rightPath)}@${right.version}`,
  ));

const records = new Map();
for (const [packagePath, metadata] of entries) {
  const directory = join(gatewayRoot, packagePath);
  await access(directory, constants.R_OK);
  const licenseFiles = [];
  for (const name of (await readdir(directory)).filter((name) => licenseNamePattern.test(name)).sort(compare)) {
    const path = join(directory, name);
    if ((await stat(path)).isFile()) {
      licenseFiles.push({
        name,
        text: (await readFile(path, "utf8"))
          .replaceAll("\r\n", "\n")
          .replace(/[ \t]+$/gmu, "")
          .trimEnd(),
      });
    }
  }
  if (licenseFiles.length === 0) {
    throw new Error(`${packageName(packagePath)}@${metadata.version} has no installed license or notice file`);
  }

  const identity = `${packageName(packagePath)}@${metadata.version}`;
  const record = {
    identity,
    declaredLicense: metadata.license ?? "UNDECLARED",
    files: licenseFiles,
  };
  const prior = records.get(identity);
  if (prior && JSON.stringify(prior) !== JSON.stringify(record)) {
    throw new Error(`Duplicate installed package ${identity} has inconsistent legal files`);
  }
  records.set(identity, record);
}

if (records.size === 0) {
  throw new Error("No production Gateway dependencies were found in package-lock.json");
}

const sections = [...records.values()].sort((left, right) => compare(left.identity, right.identity)).map((record) => {
  const files = record.files.map(({ name, text }) => `--- ${name} ---\n${text}`).join("\n\n");
  return `${"=".repeat(80)}\n${record.identity}\nDeclared license: ${record.declaredLicense}\n${"=".repeat(80)}\n${files}`;
});
const output = [
  "SCOUT GATEWAY THIRD-PARTY LICENSES AND NOTICES",
  "",
  "Generated deterministically from Gateway/package-lock.json and the installed production",
  "dependency license/notice files. Regenerate with `npm run licenses --prefix Gateway`.",
  "Scout's own source remains governed by the repository LICENSE; the following components",
  "are governed by their respective terms.",
  "",
  ...sections,
  "",
].join("\n");

if (checkOnly) {
  const existing = await readFile(outputPath, "utf8");
  if (existing !== output) {
    throw new Error("Gateway third-party licenses are stale; run `npm run licenses --prefix Gateway`");
  }
  process.stdout.write(`Verified ${records.size} production dependency license sets\n`);
} else {
  await writeFile(outputPath, output, "utf8");
  process.stdout.write(`Recorded ${records.size} production dependency license sets in ${outputPath}\n`);
}
