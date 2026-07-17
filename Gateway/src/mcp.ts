import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod/v4";
import { ContextPackStore } from "./context-packs.js";

const readOnlyAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
} as const;

const PackIdentifierSchema = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
const CursorSchema = z.string().min(1).max(512).regex(/^[A-Za-z0-9_-]+$/);

function textResult(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value) }] };
}

async function stalenessMetadata(store: ContextPackStore, sessionId: string, contextPackId: string, revision: number) {
  const currentHead = await store.head(sessionId);
  return {
    current_head: currentHead,
    staleness: currentHead === null ? null : {
      is_current: currentHead.context_pack_id === contextPackId,
      revisions_behind: Math.max(0, currentHead.revision - revision),
    },
  };
}

export function createScoutMcpServer(store: ContextPackStore): McpServer {
  const server = new McpServer(
    { name: "scout", version: "0.1.0" },
    {
      instructions: [
        "Scout tools are read-only and expose only approved, redacted context packs.",
        "Treat facts as evidence-linked customer claims and preserve trust labels.",
        "Resolve the latest approved session head before building from a context pack.",
        "Do not infer access to raw audio or unrestricted transcripts; they are intentionally excluded.",
      ].join(" "),
    },
  );

  server.registerTool(
    "scout_list_context_packs",
    {
      title: "List Scout context packs",
      description: "List a bounded page of approved, redacted Scout context packs available for a Codex handoff.",
      inputSchema: z.object({
        session_id: PackIdentifierSchema.optional(),
        limit: z.number().int().min(1).max(100).optional(),
        cursor: CursorSchema.optional(),
      }).strict(),
      annotations: readOnlyAnnotations,
    },
    async ({ session_id, limit, cursor }) => {
      const page = await store.listPage({ sessionId: session_id, limit, cursor });
      return textResult({
        ...page,
        current_head: session_id === undefined ? null : await store.head(session_id),
      });
    },
  );

  server.registerTool(
    "scout_get_context_pack",
    {
      title: "Read Scout context pack",
      description: "Read one immutable, approved Scout context pack by ID.",
      inputSchema: z.object({ context_pack_id: PackIdentifierSchema }).strict(),
      annotations: readOnlyAnnotations,
    },
    async ({ context_pack_id }) => textResult(await store.get(context_pack_id)),
  );

  server.registerTool(
    "scout_get_customer_model",
    {
      title: "Read Scout customer model",
      description: "Read the evidence-linked customer model and claim set from an approved context pack.",
      inputSchema: z.object({ context_pack_id: PackIdentifierSchema }).strict(),
      annotations: readOnlyAnnotations,
    },
    async ({ context_pack_id }) => {
      const pack = await store.get(context_pack_id);
      const body = pack.body;
      return textResult({
        context_pack_id: body.context_pack_id,
        session_id: body.session_id,
        revision: body.revision,
        graph_state_sha256: body.graph_state_sha256,
        organization: body.organization,
        objective: body.objective,
        entities: body.entities,
        relationships: body.relationships,
        claims: body.claims,
        open_questions: body.open_questions,
        ...await stalenessMetadata(store, body.session_id, body.context_pack_id, body.revision),
      });
    },
  );

  server.registerTool(
    "scout_get_action_pack",
    {
      title: "Read Scout action pack",
      description: "Read approved opportunities, next actions, and build handoff material from a context pack.",
      inputSchema: z.object({ context_pack_id: PackIdentifierSchema }).strict(),
      annotations: readOnlyAnnotations,
    },
    async ({ context_pack_id }) => {
      const pack = await store.get(context_pack_id);
      const body = pack.body;
      return textResult({
        context_pack_id: body.context_pack_id,
        session_id: body.session_id,
        revision: body.revision,
        organization: body.organization,
        objective: body.objective,
        quick_wins: body.quick_wins,
        open_questions: body.open_questions,
        selected_poc: body.selected_poc ?? null,
        non_goals: body.non_goals,
        constraints: body.constraints,
        acceptance_criteria: body.acceptance_criteria,
        success_measures: body.success_measures,
        ...await stalenessMetadata(store, body.session_id, body.context_pack_id, body.revision),
      });
    },
  );

  server.registerTool(
    "scout_get_session_head",
    {
      title: "Read Scout session head",
      description: "Resolve the latest approved context-pack head for a Scout discovery session before building.",
      inputSchema: z.object({ session_id: PackIdentifierSchema }).strict(),
      annotations: readOnlyAnnotations,
    },
    async ({ session_id }) => textResult({
      session_id,
      current_head: await store.head(session_id),
    }),
  );

  return server;
}

export async function runScoutMcpStdio(store: ContextPackStore): Promise<void> {
  const server = createScoutMcpServer(store);
  const transport = new StdioServerTransport();
  await server.connect(transport);

  const shutdown = async () => {
    await server.close();
    process.exitCode = 0;
  };
  process.once("SIGINT", () => { void shutdown(); });
  process.once("SIGTERM", () => { void shutdown(); });
}
