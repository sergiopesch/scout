import { createHash } from "node:crypto";
import { readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptsDirectory = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(scriptsDirectory, "..");
const gatewayRoot = join(workspaceRoot, "Gateway");
const pluginRoot = join(workspaceRoot, "Plugins", "scout");
const bundlePath = join(pluginRoot, "mcp", "scout-mcp.cjs");
const metafilePath = join(pluginRoot, "mcp", "scout-mcp.meta.json");
const externalLegalPath = `${bundlePath}.LEGAL.txt`;
const sbomPath = join(pluginRoot, "SBOM.cdx.json");
const noticesPath = join(pluginRoot, "THIRD_PARTY_NOTICES.md");
const pluginLicensePath = join(pluginRoot, "LICENSE");

const licenseCandidates = [
  "LICENSE",
  "LICENSE.md",
  "LICENSE.txt",
  "LICENCE",
  "LICENCE.md",
  "LICENCE.txt",
];

function packageRootForInput(inputPath) {
  const parts = inputPath.split("/");
  const nodeModulesIndex = parts.lastIndexOf("node_modules");
  if (nodeModulesIndex < 0 || nodeModulesIndex + 1 >= parts.length) return undefined;
  const first = parts[nodeModulesIndex + 1];
  const length = first.startsWith("@") ? 3 : 2;
  if (nodeModulesIndex + length > parts.length) return undefined;
  return parts.slice(0, nodeModulesIndex + length).join("/");
}

function npmPackageURL(name, version) {
  if (name.startsWith("@")) {
    const [scope, packageName] = name.split("/");
    return `pkg:npm/${encodeURIComponent(scope)}/${encodeURIComponent(packageName)}@${version}`;
  }
  return `pkg:npm/${encodeURIComponent(name)}@${version}`;
}

function integrityHash(integrity) {
  const match = /^(sha(?:256|384|512))-(.+)$/u.exec(integrity ?? "");
  if (!match) throw new Error(`Unsupported or missing package integrity: ${integrity ?? "<missing>"}`);
  return {
    alg: match[1].toUpperCase().replace("SHA", "SHA-"),
    content: Buffer.from(match[2], "base64").toString("hex"),
  };
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function deterministicText(content) {
  return `${content.replace(/\r\n?/gu, "\n").replace(/\n*$/u, "")}\n`;
}

async function readJSON(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function packageInformation(packageRoot, inputPaths, packageLock) {
  const absoluteRoot = join(gatewayRoot, packageRoot);
  const manifest = await readJSON(join(absoluteRoot, "package.json"));
  const lockEntry = packageLock.packages?.[packageRoot];
  if (!lockEntry) throw new Error(`Bundled package is absent from package-lock.json: ${packageRoot}`);
  if (lockEntry.version !== manifest.version) {
    throw new Error(`Bundled package version differs from package-lock.json: ${manifest.name}`);
  }
  let resolvedLicenseFile;
  let licenseText;
  for (const candidate of licenseCandidates) {
    try {
      licenseText = await readFile(join(absoluteRoot, candidate), "utf8");
      resolvedLicenseFile = candidate;
      break;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  if (!resolvedLicenseFile || !licenseText) {
    throw new Error(`Bundled package has no recognised license file: ${manifest.name}`);
  }
  const license = lockEntry.license ?? manifest.license;
  if (typeof license !== "string" || license.length === 0) {
    throw new Error(`Bundled package has no declared license: ${manifest.name}`);
  }
  if (typeof lockEntry.resolved !== "string" || lockEntry.resolved.length === 0) {
    throw new Error(`Bundled package has no locked distribution URL: ${manifest.name}`);
  }
  const integrity = integrityHash(lockEntry.integrity);
  return {
    name: manifest.name,
    version: manifest.version,
    license,
    licenseFile: resolvedLicenseFile,
    licenseText: deterministicText(licenseText),
    resolved: lockEntry.resolved,
    integrity,
    author: typeof manifest.author === "string" ? manifest.author : undefined,
    declaredDependencies: {
      ...(manifest.dependencies ?? {}),
      ...(manifest.peerDependencies ?? {}),
    },
    inputCount: inputPaths.length,
    purl: npmPackageURL(manifest.name, manifest.version),
  };
}

const [metafile, packageLock, pluginManifest, esbuildManifest, bundle, scoutLicense] = await Promise.all([
  readJSON(metafilePath),
  readJSON(join(gatewayRoot, "package-lock.json")),
  readJSON(join(pluginRoot, ".codex-plugin", "plugin.json")),
  readJSON(join(gatewayRoot, "node_modules", "esbuild", "package.json")),
  readFile(bundlePath),
  readFile(join(workspaceRoot, "LICENSE"), "utf8"),
]);

const packageInputs = new Map();
for (const inputPath of Object.keys(metafile.inputs ?? {})) {
  const packageRoot = packageRootForInput(inputPath);
  if (!packageRoot) continue;
  const inputs = packageInputs.get(packageRoot) ?? [];
  inputs.push(inputPath);
  packageInputs.set(packageRoot, inputs);
}
if (packageInputs.size === 0) throw new Error("MCP bundle metafile contains no third-party packages");

const packages = await Promise.all(
  [...packageInputs.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([packageRoot, inputPaths]) => packageInformation(packageRoot, inputPaths, packageLock)),
);
packages.sort((left, right) => left.name.localeCompare(right.name));

const packageReferences = new Map(packages.map((entry) => [entry.name, entry.purl]));
const bundleHash = sha256(bundle);
const rootReference = `scout-plugin-mcp@${pluginManifest.version}`;
const components = packages.map((entry) => ({
  "bom-ref": entry.purl,
  type: "library",
  name: entry.name,
  version: entry.version,
  scope: "required",
  ...(entry.author ? { author: entry.author } : {}),
  purl: entry.purl,
  hashes: [entry.integrity],
  licenses: [{ license: { id: entry.license } }],
  externalReferences: [{ type: "distribution", url: entry.resolved }],
  properties: [
    { name: "scout:bundle:input-count", value: String(entry.inputCount) },
    { name: "scout:bundle:license-file", value: entry.licenseFile },
  ],
}));

const dependencies = [
  { ref: rootReference, dependsOn: packages.map((entry) => entry.purl).sort() },
  ...packages.map((entry) => ({
    ref: entry.purl,
    dependsOn: Object.keys(entry.declaredDependencies)
      .filter((name) => packageReferences.has(name))
      .map((name) => packageReferences.get(name))
      .sort(),
  })),
];

const sbom = {
  $schema: "http://cyclonedx.org/schema/bom-1.5.schema.json",
  bomFormat: "CycloneDX",
  specVersion: "1.5",
  version: 1,
  metadata: {
    tools: [{ vendor: "evanw", name: "esbuild", version: esbuildManifest.version }],
    component: {
      "bom-ref": rootReference,
      type: "application",
      name: "Scout plugin MCP bundle",
      version: pluginManifest.version,
      hashes: [{ alg: "SHA-256", content: bundleHash }],
      properties: [
        { name: "scout:bundle:entrypoint", value: "mcp/scout-mcp.cjs" },
        { name: "scout:bundle:node-target", value: "node22" },
        { name: "scout:bundle:generator", value: "Scripts/generate-plugin-release-metadata.mjs" },
      ],
    },
  },
  components,
  dependencies,
};

let externalLegalText;
const outputPaths = Object.keys(metafile.outputs ?? {});
const generatedExternalLegal = outputPaths.some((output) => output.endsWith("scout-mcp.cjs.LEGAL.txt"));
if (generatedExternalLegal) {
  externalLegalText = deterministicText(await readFile(externalLegalPath, "utf8"));
} else {
  await rm(externalLegalPath, { force: true });
}

const packageTable = packages
  .map((entry) => `| ${entry.name} | ${entry.version} | ${entry.license} | [npm archive](${entry.resolved}) |`)
  .join("\n");
const licenseSections = packages.map((entry) => [
  `## ${entry.name} ${entry.version} — ${entry.license}`,
  "",
  `Locked source: ${entry.resolved}`,
  "",
  "```text",
  entry.licenseText.trimEnd(),
  "```",
].join("\n")).join("\n\n");
const externalLegalSection = externalLegalText
  ? `\n\n## esbuild external legal comments\n\n\`\`\`text\n${externalLegalText.trimEnd()}\n\`\`\``
  : "";
const notices = deterministicText(`# Scout plugin third-party notices

Generated deterministically from the esbuild metafile, locked npm metadata, and package license files.
Do not edit this file by hand.

This notice covers third-party code embedded in \`mcp/scout-mcp.cjs\`. The bundle SHA-256 is
\`${bundleHash}\`; exact component hashes and dependency edges are recorded in \`SBOM.cdx.json\`.
Scout itself remains all rights reserved under the adjacent \`LICENSE\` file.

| Package | Version | License | Locked source |
| --- | --- | --- | --- |
${packageTable}

${licenseSections}${externalLegalSection}`);

await Promise.all([
  writeFile(sbomPath, `${JSON.stringify(sbom, null, 2)}\n`, "utf8"),
  writeFile(noticesPath, notices, "utf8"),
  writeFile(pluginLicensePath, deterministicText(scoutLicense), "utf8"),
]);
await rm(metafilePath, { force: true });
