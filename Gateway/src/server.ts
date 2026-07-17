import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import OpenAI from "openai";
import { assertApprovalAuthenticated, assertGatewayAuthenticated } from "./auth.js";
import type { GatewayConfig } from "./config.js";
import { ContextPackStore, MAX_CONTEXT_PACK_BYTES } from "./context-packs.js";
import { ClaimsService, ExtractClaimsRequestSchema, type ExtractClaimsRequest } from "./claims.js";
import { DiarizationService, parseDiarizationMultipart, type DiarizationUpload } from "./diarization.js";
import { requestIdentifier, safeErrorMetadata, sendPublicError, PublicError } from "./errors.js";
import { isLoopbackRequest, readJsonBody, requestURL, sendEmpty, sendJson } from "./http.js";
import {
  ImageObservationsService,
  parseImageObservationMultipart,
  type ImageObservationUpload,
} from "./image-observations.js";
import { attachRealtimeProxy, type RealtimeProxy } from "./realtime-proxy.js";

export interface ClaimsAdapter {
  extract(input: ExtractClaimsRequest): Promise<unknown>;
}

export interface DiarizationAdapter {
  transcribe(upload: DiarizationUpload): Promise<unknown>;
}

export interface ImageObservationsAdapter {
  observe(upload: ImageObservationUpload): Promise<unknown>;
}

export interface GatewayDependencies {
  readonly claims: ClaimsAdapter;
  readonly diarization: DiarizationAdapter;
  readonly imageObservations: ImageObservationsAdapter;
  readonly contextPacks: ContextPackStore;
}

export interface GatewayRuntime {
  readonly server: Server;
  readonly realtime: RealtimeProxy;
  listen(): Promise<{ host: string; port: number }>;
  close(): Promise<void>;
}

function defaultDependencies(config: GatewayConfig): GatewayDependencies {
  const openAI = new OpenAI({
    apiKey: config.apiKey,
    baseURL: config.openAIBaseURL,
    timeout: config.requestTimeoutMs,
    maxRetries: 2,
  });
  return {
    claims: new ClaimsService(openAI, config.claimsModel),
    diarization: new DiarizationService(openAI, config.diarizationModel),
    imageObservations: new ImageObservationsService(openAI, config.visionModel),
    contextPacks: new ContextPackStore(
      config.contextPackDirectory,
      config.approvalKey === undefined
        ? undefined
        : {
            key: config.approvalKey,
            keyID: config.approvalKeyID,
            verificationKeys: config.approvalVerificationKeys,
          },
    ),
  };
}

function methodNotAllowed(response: ServerResponse, allow: string): void {
  sendEmpty(response, 405, { allow });
}

async function routeRequest(
  request: IncomingMessage,
  response: ServerResponse,
  dependencies: GatewayDependencies,
  config: GatewayConfig,
): Promise<void> {
  const url = requestURL(request);
  const method = request.method ?? "GET";

  if (method === "GET" && url.pathname === "/health") {
    sendJson(response, 200, {
      status: "ok",
      service: "scout-gateway",
      version: "0.1.0",
      openai_configured: true,
      context_pack_ingest_configured: config.ingestToken !== undefined,
      capabilities: [
        "realtime_transcription",
        "diarization",
        "claim_proposals",
        "image_observation_proposals",
        "context_packs",
      ],
    });
    return;
  }

  assertGatewayAuthenticated(request, config.ingestToken);

  if (url.pathname === "/v1/claims/extract") {
    if (method !== "POST") {
      methodNotAllowed(response, "POST");
      return;
    }
    const body = await readJsonBody(request);
    const parsed = ExtractClaimsRequestSchema.safeParse(body);
    if (!parsed.success) {
      throw new PublicError(422, "invalid_claim_request", "Claim extraction input does not satisfy the Scout contract");
    }
    sendJson(response, 200, await dependencies.claims.extract(parsed.data));
    return;
  }

  if (url.pathname === "/v1/transcriptions/diarize") {
    if (method !== "POST") {
      methodNotAllowed(response, "POST");
      return;
    }
    const upload = await parseDiarizationMultipart(request);
    sendJson(response, 200, await dependencies.diarization.transcribe(upload));
    return;
  }

  if (url.pathname === "/v1/images/observe") {
    if (method !== "POST") {
      methodNotAllowed(response, "POST");
      return;
    }
    if (!isLoopbackRequest(request)) {
      throw new PublicError(403, "forbidden", "Image observation is available only on the local Scout boundary");
    }
    const upload = await parseImageObservationMultipart(request);
    sendJson(response, 200, await dependencies.imageObservations.observe(upload));
    return;
  }

  if (url.pathname === "/v1/context-packs") {
    if (method === "POST") {
      if (!isLoopbackRequest(request)) {
        throw new PublicError(403, "forbidden", "Context pack ingestion is available only on the local Scout boundary");
      }
      const body = await readJsonBody(request, MAX_CONTEXT_PACK_BYTES);
      const result = await dependencies.contextPacks.put(body);
      sendJson(response, result.created ? 201 : 200, { context_pack: result.contextPack });
      return;
    }
    if (method !== "GET") {
      methodNotAllowed(response, "GET, POST");
      return;
    }
    const sessionId = url.searchParams.get("session_id") ?? undefined;
    const cursor = url.searchParams.get("cursor") ?? undefined;
    const limitValue = url.searchParams.get("limit");
    const limit = limitValue === null ? undefined : Number(limitValue);
    const page = await dependencies.contextPacks.listPage({ sessionId, cursor, limit });
    sendJson(response, 200, {
      ...page,
      current_head: sessionId === undefined ? null : await dependencies.contextPacks.head(sessionId),
    });
    return;
  }

  if (url.pathname === "/v1/context-packs/approve") {
    if (method !== "POST") {
      methodNotAllowed(response, "POST");
      return;
    }
    if (!isLoopbackRequest(request)) {
      throw new PublicError(403, "forbidden", "Context-pack approval is available only to the local Scout app");
    }
    assertApprovalAuthenticated(request, config.approvalToken);
    const body = await readJsonBody(request, MAX_CONTEXT_PACK_BYTES);
    const result = await dependencies.contextPacks.approve(body);
    sendJson(response, result.created ? 201 : 200, { context_pack: result.contextPack });
    return;
  }

  const contextPackMatch = /^\/v1\/context-packs\/([^/]+)$/.exec(url.pathname);
  if (contextPackMatch) {
    if (method !== "GET") {
      methodNotAllowed(response, "GET");
      return;
    }
    let packId: string;
    try {
      packId = decodeURIComponent(contextPackMatch[1] ?? "");
    } catch {
      throw new PublicError(400, "invalid_context_pack_id", "Context pack ID is invalid");
    }
    sendJson(response, 200, await dependencies.contextPacks.get(packId));
    return;
  }

  sendJson(response, 404, { error: { code: "not_found", message: "Route not found" } });
}

export function createGatewayRuntime(
  config: GatewayConfig,
  overrides?: Partial<GatewayDependencies>,
): GatewayRuntime {
  const defaults = defaultDependencies(config);
  const dependencies: GatewayDependencies = { ...defaults, ...overrides };
  const server = createServer((request, response) => {
    const requestId = requestIdentifier();
    response.setHeader("x-scout-request-id", requestId);
    if (config.gatewayInstanceID !== undefined) {
      response.setHeader("x-scout-gateway-instance-id", config.gatewayInstanceID);
    }
    void routeRequest(request, response, dependencies, config).catch((error: unknown) => {
      const publicError = error instanceof PublicError ? error : undefined;
      if (!publicError || publicError.status >= 500) {
        process.stderr.write(`${JSON.stringify(safeErrorMetadata(error, requestId))}\n`);
      }
      sendPublicError(response, error, requestId);
    });
  });

  server.requestTimeout = 70_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 100;
  server.on("clientError", (_error, socket) => {
    if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
  });

  const realtime = attachRealtimeProxy(server, config);
  return {
    server,
    realtime,
    async listen() {
      await new Promise<void>((resolve, reject) => {
        const onError = (error: Error) => reject(error);
        server.once("error", onError);
        server.listen(config.port, config.host, () => {
          server.off("error", onError);
          resolve();
        });
      });
      const address = server.address();
      if (!address || typeof address === "string") throw new Error("Gateway did not bind a TCP address");
      return { host: config.host, port: address.port };
    },
    async close() {
      await realtime.close();
      if (!server.listening) return;
      await new Promise<void>((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
      });
    },
  };
}
