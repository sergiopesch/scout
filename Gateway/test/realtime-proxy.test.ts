import assert from "node:assert/strict";
import test from "node:test";
import { PublicError } from "../src/errors.js";
import { realtimeUpstreamURL, sanitizeRealtimeClientEvent } from "../src/realtime-proxy.js";

test("transcription sessions use the provider intent route, not a transcription model as the session model", () => {
  const url = realtimeUpstreamURL({ openAIBaseURL: "https://api.openai.com/v1" });

  assert.equal(url.toString(), "wss://api.openai.com/v1/realtime?intent=transcription");
  assert.equal(url.searchParams.get("model"), null);
});

test("session updates are constrained to Scout transcription settings", () => {
  const result = JSON.parse(sanitizeRealtimeClientEvent(JSON.stringify({
    type: "session.update",
    session: {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24_000 },
          transcription: { model: "client-model", language: "en", delay: "minimal" },
        },
      },
    },
  }), "gpt-4o-mini-transcribe")) as any;

  assert.equal(result.session.audio.input.transcription.model, "gpt-4o-mini-transcribe");
  assert.equal(result.session.audio.input.transcription.language, "en");
  assert.equal(result.session.audio.input.transcription.delay, undefined);
  assert.equal(result.session.audio.input.turn_detection, null);
  assert.equal(result.session.audio.input.noise_reduction.type, "far_field");
});

test("audio events are accepted while unrestricted realtime events are rejected", () => {
  const audio = Buffer.from([0, 1, 2, 3]).toString("base64");
  assert.equal(
    JSON.parse(sanitizeRealtimeClientEvent(JSON.stringify({ type: "input_audio_buffer.append", audio }), "model")).type,
    "input_audio_buffer.append",
  );
  assert.throws(
    () => sanitizeRealtimeClientEvent(JSON.stringify({ type: "response.create" }), "model"),
    (error: unknown) => error instanceof PublicError && error.code === "realtime_event_not_allowed",
  );
});
