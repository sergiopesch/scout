import type { IncomingMessage, Server as HTTPServer } from "node:http";
import type { Duplex } from "node:stream";
import WebSocket, { WebSocketServer, type RawData } from "ws";
import { z } from "zod/v4";
import { isGatewayAuthenticated } from "./auth.js";
import type { GatewayConfig } from "./config.js";
import { PublicError } from "./errors.js";
import { isLoopbackRequest, requestURL } from "./http.js";

const MAX_CLIENT_EVENT_BYTES = 512 * 1024;
const MAX_AUDIO_CHUNK_BYTES = 256 * 1024;
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024;

const Identifier = z.string().max(128).optional();
const Delay = z.enum(["minimal", "low", "medium", "high", "xhigh"]);
const Language = z.string().regex(/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$/).max(16);

const SessionUpdateSchema = z.object({
  type: z.literal("session.update"),
  event_id: Identifier,
  session: z.object({
    type: z.literal("transcription"),
    audio: z.object({
      input: z.object({
        format: z.object({
          type: z.literal("audio/pcm"),
          rate: z.literal(24_000),
        }).strict(),
        transcription: z.object({
          model: z.string().max(100).optional(),
          language: Language.optional(),
          delay: Delay.optional(),
        }).strict(),
      }).strict(),
    }).strict(),
  }).strict(),
}).strict();

const ControlEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("input_audio_buffer.commit"), event_id: Identifier }).strict(),
  z.object({ type: z.literal("input_audio_buffer.clear"), event_id: Identifier }).strict(),
]);

export function sanitizeRealtimeClientEvent(raw: RawData | string, model: string): string {
  const bytes = typeof raw === "string"
    ? Buffer.from(raw)
    : Buffer.isBuffer(raw)
      ? raw
      : Array.isArray(raw)
        ? Buffer.concat(raw)
        : Buffer.from(raw);
  if (bytes.length === 0 || bytes.length > MAX_CLIENT_EVENT_BYTES) {
    throw new PublicError(413, "realtime_event_too_large", "Realtime event is too large");
  }

  let value: unknown;
  try {
    value = JSON.parse(bytes.toString("utf8")) as unknown;
  } catch {
    throw new PublicError(400, "invalid_realtime_event", "Realtime event is not valid JSON");
  }

  if (value && typeof value === "object" && (value as { type?: unknown }).type === "input_audio_buffer.append") {
    const parsed = z.object({
      type: z.literal("input_audio_buffer.append"),
      event_id: Identifier,
      audio: z.string().min(4).max(Math.ceil(MAX_AUDIO_CHUNK_BYTES / 3) * 4 + 4),
    }).strict().safeParse(value);
    if (!parsed.success || parsed.data.audio.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(parsed.data.audio)) {
      throw new PublicError(400, "invalid_audio_chunk", "Realtime audio chunk is invalid");
    }
    if (Buffer.from(parsed.data.audio, "base64").length > MAX_AUDIO_CHUNK_BYTES) {
      throw new PublicError(413, "audio_chunk_too_large", "Realtime audio chunk is too large");
    }
    return JSON.stringify(parsed.data);
  }

  const control = ControlEventSchema.safeParse(value);
  if (control.success) return JSON.stringify(control.data);

  const update = SessionUpdateSchema.safeParse(value);
  if (update.success) {
    const transcription = update.data.session.audio.input.transcription;
    return JSON.stringify({
      type: "session.update",
      ...(update.data.event_id ? { event_id: update.data.event_id } : {}),
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: {
              model,
              ...(transcription.language ? { language: transcription.language } : {}),
            },
            noise_reduction: { type: "far_field" },
            turn_detection: null,
          },
        },
      },
    });
  }

  throw new PublicError(400, "realtime_event_not_allowed", "Realtime event type is not allowed");
}

export function realtimeUpstreamURL(
  config: Pick<GatewayConfig, "openAIBaseURL">,
): URL {
  const url = new URL(config.openAIBaseURL);
  url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
  url.pathname = `${url.pathname.replace(/\/$/, "")}/realtime`;
  url.search = "";
  // A transcription model configures audio.input.transcription inside the
  // session. It is not a top-level Realtime model. The explicit intent makes
  // OpenAI create a transcription session before Scout sends session.update.
  url.searchParams.set("intent", "transcription");
  return url;
}

function defaultSessionUpdate(model: string): string {
  return JSON.stringify({
    type: "session.update",
    session: {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24_000 },
          transcription: { model },
          noise_reduction: { type: "far_field" },
          turn_detection: null,
        },
      },
    },
  });
}

function rejectUpgrade(socket: Duplex, status: number, message: string): void {
  if (!socket.writable) return;
  const body = `${message}\n`;
  socket.end([
    `HTTP/1.1 ${status} ${message}`,
    "Connection: close",
    "Content-Type: text/plain; charset=utf-8",
    `Content-Length: ${Buffer.byteLength(body)}`,
    "",
    body,
  ].join("\r\n"));
}

export interface RealtimeProxy {
  close(): Promise<void>;
}

export function attachRealtimeProxy(server: HTTPServer, config: GatewayConfig): RealtimeProxy {
  const clients = new Set<WebSocket>();
  const webSocketServer = new WebSocketServer({
    noServer: true,
    maxPayload: MAX_CLIENT_EVENT_BYTES,
    perMessageDeflate: false,
    clientTracking: false,
  });

  server.on("upgrade", (request, socket, head) => {
    let url: URL;
    try {
      url = requestURL(request);
    } catch {
      rejectUpgrade(socket, 400, "Bad Request");
      return;
    }
    if (url.pathname !== "/realtime") {
      rejectUpgrade(socket, 404, "Not Found");
      return;
    }
    if (!isLoopbackRequest(request) || !isGatewayAuthenticated(request, config.ingestToken)) {
      rejectUpgrade(socket, 403, "Forbidden");
      return;
    }
    webSocketServer.handleUpgrade(request, socket, head, (client) => {
      webSocketServer.emit("connection", client, request);
    });
  });

  webSocketServer.on("connection", (client: WebSocket, _request: IncomingMessage) => {
    clients.add(client);
    let upstreamOpen = false;
    let alive = true;
    let rejectedEvents = 0;
    const pending: string[] = [];
    let pendingBytes = 0;

    const upstream = new WebSocket(realtimeUpstreamURL(config), {
      headers: { Authorization: `Bearer ${config.apiKey}` },
      handshakeTimeout: 15_000,
      maxPayload: 2 * 1024 * 1024,
      perMessageDeflate: false,
    });

    const sessionTimeout = setTimeout(() => {
      client.close(1000, "session_complete");
      upstream.close(1000, "session_complete");
    }, 59 * 60 * 1_000);
    sessionTimeout.unref();

    const heartbeat = setInterval(() => {
      if (!alive) {
        client.terminate();
        upstream.terminate();
        return;
      }
      alive = false;
      if (client.readyState === WebSocket.OPEN) client.ping();
    }, 30_000);
    heartbeat.unref();

    client.on("pong", () => { alive = true; });
    client.on("message", (data, isBinary) => {
      if (isBinary) {
        client.close(1003, "text_events_only");
        return;
      }
      let event: string;
      try {
        event = sanitizeRealtimeClientEvent(data, config.realtimeModel);
      } catch {
        rejectedEvents += 1;
        client.send(JSON.stringify({
          type: "error",
          error: { type: "gateway_error", code: "invalid_event", message: "Scout Gateway rejected a realtime event" },
        }));
        if (rejectedEvents >= 3) client.close(1008, "too_many_invalid_events");
        return;
      }

      if (!upstreamOpen) {
        pendingBytes += Buffer.byteLength(event);
        if (pending.length >= 32 || pendingBytes > MAX_BUFFERED_BYTES) {
          client.close(1013, "upstream_not_ready");
          return;
        }
        pending.push(event);
        return;
      }
      if (upstream.bufferedAmount > MAX_BUFFERED_BYTES) {
        client.close(1013, "upstream_backpressure");
        return;
      }
      upstream.send(event);
    });

    upstream.on("open", () => {
      upstreamOpen = true;
      upstream.send(defaultSessionUpdate(config.realtimeModel));
      for (const event of pending) upstream.send(event);
      pending.length = 0;
      pendingBytes = 0;
    });
    upstream.on("message", (data, isBinary) => {
      if (client.readyState !== WebSocket.OPEN) return;
      if (!isBinary) {
        try {
          const event = JSON.parse(data.toString("utf8")) as {
            type?: unknown;
            error?: { code?: unknown; param?: unknown };
          };
          if (event.type === "error") {
            console.error(JSON.stringify({
              event: "realtime_provider_event_error",
              code: typeof event.error?.code === "string" ? event.error.code.slice(0, 128) : "unknown",
              param: typeof event.error?.param === "string" ? event.error.param.slice(0, 128) : null,
            }));
          }
        } catch {
          // The provider frame is still forwarded; diagnostics never alter it.
        }
      }
      if (client.bufferedAmount > MAX_BUFFERED_BYTES) {
        client.close(1013, "client_backpressure");
        return;
      }
      client.send(data, { binary: isBinary });
    });
    upstream.on("error", (error) => {
      console.error(JSON.stringify({
        event: "realtime_upstream_error",
        message: error.message.replace(/[\r\n\t]/gu, " ").slice(0, 256),
      }));
      if (client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify({
          type: "error",
          error: { type: "gateway_error", code: "provider_unavailable", message: "Realtime transcription is unavailable" },
        }));
      }
    });
    upstream.on("close", (code, reason) => {
      if (code !== 1000) {
        console.error(JSON.stringify({
          event: "realtime_upstream_closed",
          code,
          reason: reason.toString("utf8").replace(/[\r\n\t]/gu, " ").slice(0, 128),
        }));
      }
      if (client.readyState === WebSocket.OPEN || client.readyState === WebSocket.CONNECTING) {
        client.close(1012, "provider_disconnected");
      }
    });
    client.on("close", () => {
      clearInterval(heartbeat);
      clearTimeout(sessionTimeout);
      clients.delete(client);
      if (upstream.readyState === WebSocket.OPEN || upstream.readyState === WebSocket.CONNECTING) {
        upstream.close(1000, "client_disconnected");
      }
    });
    client.on("error", () => {
      upstream.terminate();
    });
  });

  return {
    async close() {
      for (const client of clients) client.close(1001, "gateway_shutdown");
      await new Promise<void>((resolve) => webSocketServer.close(() => resolve()));
    },
  };
}
