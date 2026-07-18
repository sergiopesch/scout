import assert from "node:assert/strict";
import test from "node:test";
import {
  DiarizationService,
  probeDiarizationWAV,
  type DiarizationUpload,
} from "../src/diarization.js";
import { PublicError } from "../src/errors.js";

function canonicalWAV(
  frameCount = 24_000,
  overrides: { channels?: number; sampleRate?: number; bitsPerSample?: number; audioFormat?: number } = {},
): Buffer {
  const channels = overrides.channels ?? 1;
  const sampleRate = overrides.sampleRate ?? 24_000;
  const bitsPerSample = overrides.bitsPerSample ?? 16;
  const bytesPerFrame = channels * (bitsPerSample / 8);
  const pcm = Buffer.alloc(frameCount * bytesPerFrame);
  const wav = Buffer.alloc(44 + pcm.length);
  wav.write("RIFF", 0, "ascii");
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8, "ascii");
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(overrides.audioFormat ?? 1, 20);
  wav.writeUInt16LE(channels, 22);
  wav.writeUInt32LE(sampleRate, 24);
  wav.writeUInt32LE(sampleRate * bytesPerFrame, 28);
  wav.writeUInt16LE(bytesPerFrame, 32);
  wav.writeUInt16LE(bitsPerSample, 34);
  wav.write("data", 36, "ascii");
  wav.writeUInt32LE(pcm.length, 40);
  pcm.copy(wav, 44);
  return wav;
}

function expectPublicError(action: () => unknown, code: string): void {
  assert.throws(action, (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, code);
    return true;
  });
}

test("decoder-grade WAV admission accepts only Scout's exact PCM boundary", () => {
  assert.deepEqual(probeDiarizationWAV(canonicalWAV(), "audio/wav"), {
    container: "wav",
    codec: "pcm_s16le",
    channels: 1,
    sampleRate: 24_000,
    bitsPerSample: 16,
    frameCount: 24_000,
    durationSeconds: 1,
  });

  expectPublicError(() => probeDiarizationWAV(Buffer.from("RIFF-test"), "audio/wav"), "invalid_audio_container");
  expectPublicError(() => probeDiarizationWAV(canonicalWAV(), "audio/mpeg"), "unsupported_audio_format");
  expectPublicError(() => probeDiarizationWAV(canonicalWAV(24_000, { channels: 2 }), "audio/wav"), "unsupported_audio_encoding");
  expectPublicError(() => probeDiarizationWAV(canonicalWAV(24_000, { sampleRate: 48_000 }), "audio/wav"), "unsupported_audio_encoding");
  expectPublicError(() => probeDiarizationWAV(canonicalWAV(24_000, { audioFormat: 3 }), "audio/wav"), "unsupported_audio_encoding");

  const forgedLength = canonicalWAV();
  forgedLength.writeUInt32LE(forgedLength.length, 4);
  expectPublicError(() => probeDiarizationWAV(forgedLength, "audio/wav"), "invalid_audio_container");

  const extraChunk = Buffer.concat([canonicalWAV(), Buffer.from("JUNK\0\0\0\0", "binary")]);
  extraChunk.writeUInt32LE(extraChunk.length - 8, 4);
  expectPublicError(() => probeDiarizationWAV(extraChunk, "audio/wav"), "unsupported_audio_chunk");

  expectPublicError(() => probeDiarizationWAV(canonicalWAV(24_000 * 60 + 1), "audio/wav"), "invalid_audio_frames");
});

test("diarization rejects provider segments outside the probed audio duration", async () => {
  const bytes = canonicalWAV();
  const upload: DiarizationUpload = {
    bytes,
    filename: "turn.wav",
    mimeType: "audio/wav",
    probe: probeDiarizationWAV(bytes, "audio/wav"),
    language: "en",
  };
  const service = new DiarizationService({
    audio: {
      transcriptions: {
        create: async () => ({
          task: "transcribe",
          duration: 1,
          text: "hello",
          segments: [{
            id: "segment-1",
            type: "transcript.text.segment",
            start: 0,
            end: 1.1,
            speaker: "speaker_0",
            text: "hello",
          }],
        }),
      },
    },
  } as any, "gpt-test");

  await assert.rejects(() => service.transcribe(upload), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "provider_schema_violation");
    return true;
  });
});
