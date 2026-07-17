import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ContextPackStore } from "../src/context-packs.js";
import { makeContextPack, TEST_APPROVAL_OPTIONS } from "./context-pack-fixture.js";

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

test("Scout plugin launches the approved-pack MCP surface over owned stdio", async (context) => {
  const workspace = resolve(import.meta.dirname, "../..");
  const pluginRoot = resolve(workspace, "Plugins/scout");
  const directory = await mkdtemp(resolve(workspace, "Gateway/.mcp-stdio-test-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  await store.put(makeContextPack({ context_pack_id: "pack-stdio" }));

  const client = new Client({ name: "scout-stdio-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["./mcp/scout-mcp.cjs"],
    cwd: pluginRoot,
    stderr: "pipe",
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      SCOUT_CONTEXT_PACK_DIR: directory,
      SCOUT_DATA_ROOT: workspace,
      SCOUT_APPROVAL_HMAC_KEY: TEST_APPROVAL_OPTIONS.key,
      SCOUT_APPROVAL_KEY_ID: TEST_APPROVAL_OPTIONS.keyID,
    },
  });
  context.after(() => client.close());

  await client.connect(transport);
  assert.ok(transport.pid);
  const tools = await client.listTools();
  assert.ok(tools.tools.some((tool) => tool.name === "scout_get_context_pack"));
  const result = await client.callTool({ name: "scout_list_context_packs", arguments: {} });
  assert.equal(JSON.parse(textContent(result)).context_packs[0].context_pack_id, "pack-stdio");
});
