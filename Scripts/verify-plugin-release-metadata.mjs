import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptsDirectory = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(scriptsDirectory, "..");
const pluginRoot = join(workspaceRoot, "Plugins", "scout");
const bundlePath = join(pluginRoot, "mcp", "scout-mcp.cjs");
const sbomPath = join(pluginRoot, "SBOM.cdx.json");
const noticesPath = join(pluginRoot, "THIRD_PARTY_NOTICES.md");
const pluginLicensePath = join(pluginRoot, "LICENSE");

function fail(message) {
  throw new Error(`Scout plugin release metadata is invalid: ${message}`);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

const [bundle, sbomText, notices, pluginLicense, repositoryLicense, manifestText] = await Promise.all([
  readFile(bundlePath),
  readFile(sbomPath, "utf8"),
  readFile(noticesPath, "utf8"),
  readFile(pluginLicensePath, "utf8"),
  readFile(join(workspaceRoot, "LICENSE"), "utf8"),
  readFile(join(pluginRoot, ".codex-plugin", "plugin.json"), "utf8"),
]);

const sbom = JSON.parse(sbomText);
const manifest = JSON.parse(manifestText);
if (sbom.bomFormat !== "CycloneDX" || sbom.specVersion !== "1.5") {
  fail("SBOM must be CycloneDX 1.5");
}
if (manifest.license === "MIT") fail("plugin manifest contradicts Scout's all-rights-reserved license");
if (`${pluginLicense.trim()}\n` !== `${repositoryLicense.trim()}\n`) {
  fail("archive LICENSE differs from the repository LICENSE");
}

const bundleHash = sha256(bundle);
const rootComponent = sbom.metadata?.component;
const recordedHash = rootComponent?.hashes?.find((entry) => entry.alg === "SHA-256")?.content;
if (recordedHash !== bundleHash) fail("SBOM bundle hash does not match mcp/scout-mcp.cjs");
if (!notices.includes(bundleHash)) fail("third-party notices do not identify the bundled bytes");

const components = sbom.components;
if (!Array.isArray(components) || components.length === 0) fail("SBOM has no bundled components");
const componentNames = components.map((component) => component.name);
const sortedNames = [...componentNames].sort((left, right) => left.localeCompare(right));
if (componentNames.join("\n") !== sortedNames.join("\n")) fail("SBOM components are not sorted");
if (new Set(components.map((component) => component["bom-ref"])).size !== components.length) {
  fail("SBOM contains duplicate component references");
}

for (const component of components) {
  const license = component.licenses?.[0]?.license?.id;
  const hash = component.hashes?.[0];
  const distribution = component.externalReferences?.find((entry) => entry.type === "distribution")?.url;
  if (!component.name || !component.version || !component.purl) fail("component identity is incomplete");
  if (!license || !hash?.alg || !hash?.content || !distribution) {
    fail(`component provenance is incomplete: ${component.name}`);
  }
  if (!notices.includes(`## ${component.name} ${component.version} — ${license}`)) {
    fail(`license text is absent from notices: ${component.name}`);
  }
}

const componentReferences = new Set(components.map((component) => component["bom-ref"]));
const dependencies = sbom.dependencies;
if (!Array.isArray(dependencies)) fail("SBOM dependency graph is absent");
const rootDependency = dependencies.find((entry) => entry.ref === rootComponent?.["bom-ref"]);
if (!rootDependency || rootDependency.dependsOn.length !== components.length) {
  fail("root dependency closure does not cover every bundled component");
}
for (const dependency of dependencies) {
  for (const reference of dependency.dependsOn ?? []) {
    if (!componentReferences.has(reference)) fail(`dependency references an unknown component: ${reference}`);
  }
}

if (bundle.includes(Buffer.from(workspaceRoot))) fail("bundle contains an absolute workspace path");
try {
  await access(join(pluginRoot, "mcp", "scout-mcp.meta.json"));
  fail("temporary esbuild metafile leaked into the plugin archive");
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}

process.stdout.write(
  `Scout plugin release metadata verified: ${components.length} components, bundle sha256 ${bundleHash}\n`,
);
