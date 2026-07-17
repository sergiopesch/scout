import OpenAI from "openai";
import { ClaimsService, ExtractClaimsRequestSchema } from "../src/claims.js";
import { loadGatewayConfig } from "../src/config.js";

const config = loadGatewayConfig();
const openAI = new OpenAI({
  apiKey: config.apiKey,
  baseURL: config.openAIBaseURL,
  timeout: config.requestTimeoutMs,
  maxRetries: 1,
});
const service = new ClaimsService(openAI, config.claimsModel);
const result = await service.extract(ExtractClaimsRequestSchema.parse({
  session_id: "live-smoke-session",
  event_boundary: 1,
  utterances: [{
    utterance_id: "live-smoke-utterance",
    evidence_id: "live-smoke-evidence",
    speaker_id: "live-smoke-speaker",
    text: "Our support team uses a CRM to answer customer questions.",
    start_ms: 0,
    end_ms: 2_000,
    source: "manual",
  }],
}));

process.stdout.write(`${JSON.stringify({
  status: "ok",
  claims: result.proposal.claims.length,
  unresolved_terms: result.proposal.unresolved_terms.length,
  output_hash_verified: /^[a-f0-9]{64}$/.test(result.model_call.output_sha256),
})}\n`);
