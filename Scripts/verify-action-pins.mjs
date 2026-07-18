#!/usr/bin/env node

import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptsDirectory = dirname(fileURLToPath(import.meta.url));
const workflowDirectory = join(dirname(scriptsDirectory), ".github", "workflows");
const failures = [];

for (const file of (await readdir(workflowDirectory)).filter((name) => /\.ya?ml$/u.test(name)).sort()) {
  const lines = (await readFile(join(workflowDirectory, file), "utf8")).split(/\r?\n/u);
  lines.forEach((line, index) => {
    const marker = line.match(/\buses:\s*([^\s#]+)/u)?.[1];
    if (!marker || marker.startsWith("./")) return;
    const separator = marker.lastIndexOf("@");
    const reference = separator >= 0 ? marker.slice(separator + 1) : "";
    if (!/^[0-9a-f]{40}$/u.test(reference)) {
      failures.push(`${file}:${index + 1}: ${marker}`);
    }
  });
}

if (failures.length > 0) {
  throw new Error(`GitHub Actions must use full commit SHAs:\n${failures.join("\n")}`);
}
process.stdout.write("GitHub Actions references are pinned to full commit SHAs\n");
