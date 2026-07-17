import { randomUUID } from "node:crypto";
import type { ServerResponse } from "node:http";

export class PublicError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "PublicError";
  }
}

interface ProviderLikeError {
  readonly status?: unknown;
  readonly request_id?: unknown;
  readonly name?: unknown;
}

export interface PublicErrorBody {
  readonly error: {
    readonly code: string;
    readonly message: string;
  };
  readonly request_id: string;
}

export function requestIdentifier(): string {
  return `gw_${randomUUID()}`;
}

export function toPublicError(error: unknown): PublicError {
  if (error instanceof PublicError) return error;

  const provider = error as ProviderLikeError;
  if (typeof provider?.status === "number") {
    if (provider.status === 429) {
      return new PublicError(503, "provider_rate_limited", "The intelligence provider is temporarily busy");
    }
    if (provider.status === 401 || provider.status === 403) {
      return new PublicError(503, "provider_authentication_failed", "The intelligence provider is unavailable");
    }
    return new PublicError(502, "provider_request_failed", "The intelligence provider could not complete the request");
  }

  return new PublicError(500, "internal_error", "Scout Gateway could not complete the request");
}

export function safeErrorMetadata(error: unknown, requestId: string): Record<string, unknown> {
  const provider = error as ProviderLikeError;
  return {
    event: "gateway_request_failed",
    request_id: requestId,
    error_type: typeof provider?.name === "string" ? provider.name : "UnknownError",
    provider_status: typeof provider?.status === "number" ? provider.status : undefined,
    provider_request_id: typeof provider?.request_id === "string" ? provider.request_id : undefined,
  };
}

export function sendPublicError(response: ServerResponse, error: unknown, requestId: string): void {
  const publicError = toPublicError(error);
  if (!response.headersSent) {
    response.writeHead(publicError.status, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    });
  }
  if (!response.writableEnded) {
    const body: PublicErrorBody = {
      error: { code: publicError.code, message: publicError.message },
      request_id: requestId,
    };
    response.end(JSON.stringify(body));
  }
}
