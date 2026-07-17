import { loadGatewayConfig } from "./config.js";
import { createGatewayRuntime } from "./server.js";

async function main(): Promise<void> {
  const config = loadGatewayConfig();
  const runtime = createGatewayRuntime(config);
  const address = await runtime.listen();
  process.stderr.write(`${JSON.stringify({
    event: "gateway_started",
    service: "scout-gateway",
    host: address.host,
    port: address.port,
  })}\n`);

  let shuttingDown = false;
  async function shutdown(): Promise<void> {
    if (shuttingDown) return;
    shuttingDown = true;
    await runtime.close();
  }

  process.once("SIGINT", () => { void shutdown(); });
  process.once("SIGTERM", () => { void shutdown(); });
}

void main().catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : "Scout Gateway could not start"}\n`);
  process.exitCode = 1;
});
