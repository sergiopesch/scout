import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ContextPackStore } from "../src/context-packs.js";
import {
  makeContextPack,
  TEST_APPROVAL_OPTIONS,
  TEST_APPROVAL_PUBLIC_KEYS,
} from "./context-pack-fixture.js";

function textContent(result: unknown): string {
  if (!result || typeof result !== "object") throw new Error("MCP result is invalid");
  const content = (result as { content?: unknown }).content;
  if (!Array.isArray(content)) throw new Error("MCP result content is invalid");
  const first = content[0] as { type?: unknown; text?: unknown } | undefined;
  if (first?.type !== "text" || typeof first.text !== "string") {
    throw new Error("MCP result is not text");
  }
  return first.text;
}

test("archive-shaped Scout plugin launches the approved-pack MCP surface over owned stdio", async (context) => {
  const workspace = resolve(import.meta.dirname, "../..");
  const sourcePlugin = resolve(workspace, "Plugins/scout");
  const pluginRoot = await mkdtemp(join(tmpdir(), "scout-plugin-archive-"));
  const dataRoot = join(pluginRoot, "data");
  const directory = join(dataRoot, "context-packs");
  await mkdir(join(pluginRoot, ".codex-plugin"), { recursive: true });
  await mkdir(join(pluginRoot, "mcp"), { recursive: true });
  await copyFile(
    join(sourcePlugin, ".codex-plugin/plugin.json"),
    join(pluginRoot, ".codex-plugin/plugin.json"),
  );
  await copyFile(join(sourcePlugin, "mcp/scout-mcp.cjs"), join(pluginRoot, "mcp/scout-mcp.cjs"));
  context.after(() => rm(pluginRoot, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS, dataRoot);
  await store.put(makeContextPack({ context_pack_id: "pack-stdio" }));
  await writeFile(join(dataRoot, "approval-public-keyring-v1.json"), JSON.stringify({
    version: 1,
    generation: 1,
    active_key_id: TEST_APPROVAL_OPTIONS.signingKey?.keyID,
    keys: TEST_APPROVAL_PUBLIC_KEYS,
    revoked_key_ids: [],
  }));

  const client = new Client({ name: "scout-stdio-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["./mcp/scout-mcp.cjs"],
    cwd: pluginRoot,
    stderr: "pipe",
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      SCOUT_CONTEXT_PACK_DIR: directory,
      SCOUT_DATA_ROOT: dataRoot,
    },
  });
  context.after(() => client.close());

  await client.connect(transport);
  assert.ok(transport.pid);
  const tools = await client.listTools();
  assert.ok(tools.tools.some((tool) => tool.name === "scout_get_context_pack"));
  const result = await client.callTool({ name: "scout_list_context_packs", arguments: {} });
  assert.equal(JSON.parse(textContent(result)).context_packs[0].context_pack_id, "pack-stdio");

  await rm(join(dataRoot, "approval-public-keyring-v1.json"));
  const unconfiguredClient = new Client({ name: "scout-stdio-unconfigured-test", version: "1.0.0" });
  const unconfiguredTransport = new StdioClientTransport({
    command: process.execPath,
    args: ["./mcp/scout-mcp.cjs"],
    cwd: pluginRoot,
    stderr: "pipe",
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      SCOUT_CONTEXT_PACK_DIR: directory,
      SCOUT_DATA_ROOT: dataRoot,
    },
  });
  context.after(() => unconfiguredClient.close());
  await unconfiguredClient.connect(unconfiguredTransport);
  assert.ok(unconfiguredTransport.pid);
  assert.ok((await unconfiguredClient.listTools()).tools.some(
    (tool) => tool.name === "scout_get_context_pack",
  ));
  const blockedRead = await unconfiguredClient.callTool({
    name: "scout_get_context_pack",
    arguments: { context_pack_id: "pack-stdio" },
  });
  assert.equal(blockedRead.isError, true);
});
