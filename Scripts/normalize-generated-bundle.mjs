import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptsDirectory = dirname(fileURLToPath(import.meta.url));
const bundlePath = join(
  scriptsDirectory,
  "..",
  "Plugins",
  "scout",
  "mcp",
  "scout-mcp.cjs",
);

const bundle = await readFile(bundlePath, "utf8");

// esbuild preserves indentation inside dependency template literals. That
// indentation is semantically irrelevant JavaScript whitespace, but it leaves
// generated lines with trailing spaces and makes Git's patch audit fail.
const normalizedBundle = bundle.replace(/[\t ]+(?=\r?\n)/gu, "");

if (normalizedBundle !== bundle) {
  await writeFile(bundlePath, normalizedBundle, "utf8");
}
