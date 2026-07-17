import { loadContextPackApprovalOptions, loadContextPackDirectory } from "./config.js";
import { ContextPackStore } from "./context-packs.js";
import { runScoutMcpStdio } from "./mcp.js";

async function main(): Promise<void> {
  await runScoutMcpStdio(new ContextPackStore(
    loadContextPackDirectory(),
    loadContextPackApprovalOptions(),
  ));
}

void main().catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : "Scout MCP could not start"}\n`);
  process.exitCode = 1;
});
