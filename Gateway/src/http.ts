import type { IncomingMessage, ServerResponse } from "node:http";
import { PublicError } from "./errors.js";

export const JSON_BODY_LIMIT = 256 * 1024;

export function sendJson(response: ServerResponse, status: number, value: unknown): void {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  });
  response.end(body);
}

export function sendEmpty(response: ServerResponse, status: number, extraHeaders: Record<string, string> = {}): void {
  response.writeHead(status, { "cache-control": "no-store", ...extraHeaders });
  response.end();
}

export async function readBoundedBody(request: IncomingMessage, maximumBytes: number): Promise<Buffer> {
  const declaredLength = request.headers["content-length"];
  if (declaredLength !== undefined) {
    const length = Number(declaredLength);
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new PublicError(400, "invalid_content_length", "Content-Length is invalid");
    }
    if (length > maximumBytes) {
      throw new PublicError(413, "payload_too_large", "The request payload is too large");
    }
  }

  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > maximumBytes) {
      request.resume();
      throw new PublicError(413, "payload_too_large", "The request payload is too large");
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks, total);
}

export async function readJsonBody(request: IncomingMessage, maximumBytes = JSON_BODY_LIMIT): Promise<unknown> {
  const contentType = request.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new PublicError(415, "unsupported_media_type", "Content-Type must be application/json");
  }
  const body = await readBoundedBody(request, maximumBytes);
  if (body.length === 0) {
    throw new PublicError(400, "empty_body", "A JSON request body is required");
  }
  try {
    return JSON.parse(body.toString("utf8")) as unknown;
  } catch {
    throw new PublicError(400, "invalid_json", "The request body is not valid JSON");
  }
}

export function requestURL(request: IncomingMessage): URL {
  try {
    return new URL(request.url ?? "/", "http://127.0.0.1");
  } catch {
    throw new PublicError(400, "invalid_url", "The request URL is invalid");
  }
}

export function isLoopbackRequest(request: IncomingMessage): boolean {
  const remote = request.socket.remoteAddress;
  if (remote !== "127.0.0.1" && remote !== "::1" && remote !== "::ffff:127.0.0.1") return false;

  const host = request.headers.host?.toLowerCase();
  if (host && !/^(?:127\.0\.0\.1|localhost)(?::\d{1,5})?$/.test(host) && !/^\[::1\](?::\d{1,5})?$/.test(host)) {
    return false;
  }

  const origin = request.headers.origin;
  if (!origin) return true;
  try {
    const originHost = new URL(origin).hostname.toLowerCase();
    return originHost === "127.0.0.1" || originHost === "localhost" || originHost === "::1";
  } catch {
    return false;
  }
}
