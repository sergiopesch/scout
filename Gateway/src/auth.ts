import { createHash, timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";
import { PublicError } from "./errors.js";

export function isGatewayAuthenticated(request: IncomingMessage, token: string | undefined): boolean {
  if (!token) return false;
  const authorization = request.headers.authorization;
  const candidate = authorization?.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : undefined;
  if (typeof candidate !== "string" || candidate.length === 0) return false;
  const expectedDigest = createHash("sha256").update(token).digest();
  const candidateDigest = createHash("sha256").update(candidate).digest();
  return timingSafeEqual(expectedDigest, candidateDigest);
}

export function assertGatewayAuthenticated(request: IncomingMessage, token: string | undefined): void {
  if (!token) {
    throw new PublicError(503, "gateway_authentication_unconfigured", "Scout Gateway authentication is not configured");
  }
  if (!request.headers.authorization) {
    throw new PublicError(401, "authentication_required", "Scout Gateway requires authentication");
  }
  if (!isGatewayAuthenticated(request, token)) {
    throw new PublicError(403, "authentication_failed", "Scout Gateway authentication failed");
  }
}

export function assertApprovalAuthenticated(request: IncomingMessage, token: string | undefined): void {
  if (!token) {
    throw new PublicError(503, "approval_authentication_unconfigured", "Scout approval authentication is not configured");
  }
  const header = request.headers["x-scout-approval-token"];
  const candidate = Array.isArray(header) ? undefined : header;
  if (!candidate) {
    throw new PublicError(401, "approval_authentication_required", "Scout approval authentication is required");
  }
  const expectedDigest = createHash("sha256").update(token).digest();
  const candidateDigest = createHash("sha256").update(candidate).digest();
  if (!timingSafeEqual(expectedDigest, candidateDigest)) {
    throw new PublicError(403, "approval_authentication_failed", "Scout approval authentication failed");
  }
}
