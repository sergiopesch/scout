import type { IncomingMessage } from "node:http";
import { basename, extname } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import Busboy from "busboy";
import OpenAI, { toFile } from "openai";
import { z } from "zod/v4";
import { PublicError } from "./errors.js";

const REQUIRED_SAMPLE_RATE = 24_000;
const REQUIRED_CHANNELS = 1;
const REQUIRED_BITS_PER_SAMPLE = 16;
const MAX_AUDIO_SECONDS = 60;
const MAX_PCM_BYTES = REQUIRED_SAMPLE_RATE * REQUIRED_CHANNELS * (REQUIRED_BITS_PER_SAMPLE / 8) * MAX_AUDIO_SECONDS;
export const MAX_AUDIO_BYTES = 44 + MAX_PCM_BYTES;
const MAX_MULTIPART_BYTES = MAX_AUDIO_BYTES + 128 * 1024;

const LanguageSchema = z.string().regex(/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$/).max(16);

export interface DiarizationAudioProbe {
  readonly container: "wav";
  readonly codec: "pcm_s16le";
  readonly channels: 1;
  readonly sampleRate: 24_000;
  readonly bitsPerSample: 16;
  readonly frameCount: number;
  readonly durationSeconds: number;
}

export interface DiarizationUpload {
  readonly bytes: Buffer;
  readonly filename: string;
  readonly mimeType: string;
  readonly probe: DiarizationAudioProbe;
  readonly language?: string;
}

function safeFilename(value: string): string {
  const name = basename(value).replace(/[^A-Za-z0-9._-]/g, "_").slice(-180);
  if (!name || extname(name).toLowerCase() !== ".wav") {
    throw new PublicError(415, "unsupported_audio_format", "Scout accepts only its canonical PCM16 WAV capture format");
  }
  return name;
}

export function probeDiarizationWAV(bytes: Buffer, mimeType: string): DiarizationAudioProbe {
  if (mimeType !== "audio/wav" && mimeType !== "audio/x-wav") {
    throw new PublicError(415, "unsupported_audio_format", "The diarization upload must be audio/wav");
  }
  if (bytes.length < 44
    || bytes.toString("ascii", 0, 4) !== "RIFF"
    || bytes.toString("ascii", 8, 12) !== "WAVE"
    || bytes.readUInt32LE(4) !== bytes.length - 8) {
    throw new PublicError(422, "invalid_audio_container", "The WAV container is incomplete or inconsistent");
  }

  let offset = 12;
  let formatSeen = false;
  let dataSeen = false;
  let frameCount = 0;
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) {
      throw new PublicError(422, "invalid_audio_container", "The WAV chunk table is truncated");
    }
    const chunkID = bytes.toString("ascii", offset, offset + 4);
    const chunkSize = bytes.readUInt32LE(offset + 4);
    const dataOffset = offset + 8;
    const dataEnd = dataOffset + chunkSize;
    const paddedEnd = dataEnd + (chunkSize % 2);
    if (dataEnd > bytes.length || paddedEnd > bytes.length) {
      throw new PublicError(422, "invalid_audio_container", "The WAV chunk length exceeds the upload");
    }

    if (chunkID === "fmt ") {
      if (formatSeen || chunkSize !== 16) {
        throw new PublicError(422, "invalid_audio_format", "The WAV format chunk must be canonical PCM");
      }
      formatSeen = true;
      const audioFormat = bytes.readUInt16LE(dataOffset);
      const channels = bytes.readUInt16LE(dataOffset + 2);
      const sampleRate = bytes.readUInt32LE(dataOffset + 4);
      const byteRate = bytes.readUInt32LE(dataOffset + 8);
      const blockAlign = bytes.readUInt16LE(dataOffset + 12);
      const bitsPerSample = bytes.readUInt16LE(dataOffset + 14);
      if (audioFormat !== 1
        || channels !== REQUIRED_CHANNELS
        || sampleRate !== REQUIRED_SAMPLE_RATE
        || bitsPerSample !== REQUIRED_BITS_PER_SAMPLE
        || blockAlign !== 2
        || byteRate !== REQUIRED_SAMPLE_RATE * 2) {
        throw new PublicError(
          422,
          "unsupported_audio_encoding",
          "Audio must be mono 24 kHz little-endian PCM16 with canonical frame metadata",
        );
      }
    } else if (chunkID === "data") {
      if (!formatSeen || dataSeen || chunkSize === 0 || chunkSize > MAX_PCM_BYTES || chunkSize % 2 !== 0) {
        throw new PublicError(422, "invalid_audio_frames", "The WAV data chunk is empty, duplicated, or out of bounds");
      }
      dataSeen = true;
      frameCount = chunkSize / 2;
    } else {
      throw new PublicError(422, "unsupported_audio_chunk", "The WAV upload contains a non-canonical chunk");
    }
    offset = paddedEnd;
  }

  if (!formatSeen || !dataSeen || offset !== bytes.length) {
    throw new PublicError(422, "invalid_audio_container", "The WAV upload lacks a complete format or data chunk");
  }
  const durationSeconds = frameCount / REQUIRED_SAMPLE_RATE;
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0 || durationSeconds > MAX_AUDIO_SECONDS) {
    throw new PublicError(422, "invalid_audio_duration", "Audio duration must be greater than zero and at most 60 seconds");
  }
  return {
    container: "wav",
    codec: "pcm_s16le",
    channels: 1,
    sampleRate: 24_000,
    bitsPerSample: 16,
    frameCount,
    durationSeconds,
  };
}

export async function parseDiarizationMultipart(request: IncomingMessage): Promise<DiarizationUpload> {
  const contentType = request.headers["content-type"];
  if (!contentType?.toLowerCase().startsWith("multipart/form-data;")) {
    throw new PublicError(415, "unsupported_media_type", "Content-Type must be multipart/form-data");
  }
  const declaredLength = Number(request.headers["content-length"] ?? 0);
  if (declaredLength > MAX_MULTIPART_BYTES) {
    throw new PublicError(413, "payload_too_large", "The audio upload is too large");
  }

  let parser;
  try {
    parser = Busboy({
      headers: request.headers,
      limits: { fileSize: MAX_AUDIO_BYTES, files: 1, fields: 3, fieldSize: 128, parts: 5 },
    });
  } catch {
    throw new PublicError(400, "invalid_multipart", "The multipart request is invalid");
  }

  const chunks: Buffer[] = [];
  let fileBytes = 0;
  let filename: string | undefined;
  let mimeType = "application/octet-stream";
  let language: string | undefined;
  let violation: PublicError | undefined;
  let fileCount = 0;
  let truncated = false;

  parser.on("file", (fieldName, stream, info) => {
    fileCount += 1;
    if (fieldName !== "file" || fileCount > 1) {
      violation ??= new PublicError(400, "invalid_audio_upload", "Exactly one file field is required");
      stream.resume();
      return;
    }
    try {
      filename = safeFilename(info.filename);
    } catch (error) {
      violation = error instanceof PublicError ? error : new PublicError(415, "unsupported_audio_format", "The audio format is unsupported");
    }
    mimeType = info.mimeType.slice(0, 120);
    stream.on("limit", () => { truncated = true; });
    stream.on("data", (chunk: Buffer) => {
      if (truncated || violation) return;
      fileBytes += chunk.length;
      chunks.push(Buffer.from(chunk));
    });
  });

  parser.on("field", (name, value) => {
    if (name === "language") {
      const parsed = LanguageSchema.safeParse(value);
      if (!parsed.success) violation ??= new PublicError(400, "invalid_language", "Language must be an ISO language code");
      else language = parsed.data;
    } else if (name === "chunking_strategy" && value !== "auto") {
      violation ??= new PublicError(400, "invalid_chunking_strategy", "Diarization chunking_strategy must be auto");
    } else if (name !== "chunking_strategy") {
      violation ??= new PublicError(400, "unknown_multipart_field", "The multipart request contains an unknown field");
    }
  });
  parser.on("filesLimit", () => { violation ??= new PublicError(400, "too_many_files", "Only one audio file is accepted"); });
  parser.on("fieldsLimit", () => { violation ??= new PublicError(400, "too_many_fields", "Too many multipart fields were supplied"); });
  parser.on("partsLimit", () => { violation ??= new PublicError(400, "too_many_parts", "Too many multipart parts were supplied"); });

  let totalBytes = 0;
  const meter = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      totalBytes += chunk.length;
      if (totalBytes > MAX_MULTIPART_BYTES) {
        callback(new PublicError(413, "payload_too_large", "The audio upload is too large"));
        return;
      }
      callback(null, chunk);
    },
  });

  try {
    await pipeline(request, meter, parser);
  } catch (error) {
    if (error instanceof PublicError) throw error;
    throw new PublicError(400, "invalid_multipart", "The multipart request is invalid");
  }

  if (violation) throw violation;
  if (truncated || fileBytes > MAX_AUDIO_BYTES) {
    throw new PublicError(413, "audio_too_large", "The audio file is too large");
  }
  if (!filename || fileCount !== 1 || fileBytes === 0) {
    throw new PublicError(400, "missing_audio_file", "A non-empty audio file is required");
  }

  const bytes = Buffer.concat(chunks, fileBytes);
  const probe = probeDiarizationWAV(bytes, mimeType);
  return {
    bytes,
    filename,
    mimeType,
    probe,
    ...(language ? { language } : {}),
  };
}

const DiarizedResponseSchema = z.object({
  task: z.literal("transcribe"),
  duration: z.number().nonnegative(),
  text: z.string(),
  segments: z.array(z.object({
    id: z.string(),
    type: z.literal("transcript.text.segment"),
    start: z.number().nonnegative(),
    end: z.number().nonnegative(),
    speaker: z.string().min(1).max(120),
    text: z.string(),
  }).strict().refine((segment) => segment.end >= segment.start)).max(100_000),
  usage: z.unknown().optional(),
}).passthrough();

export class DiarizationService {
  constructor(
    private readonly openAI: Pick<OpenAI, "audio">,
    private readonly model: string,
  ) {}

  async transcribe(upload: DiarizationUpload): Promise<unknown> {
    const result = await this.openAI.audio.transcriptions.create({
      file: await toFile(upload.bytes, upload.filename, { type: upload.mimeType }),
      model: this.model,
      response_format: "diarized_json",
      chunking_strategy: "auto",
      stream: false,
      ...(upload.language ? { language: upload.language } : {}),
    });
    const parsed = DiarizedResponseSchema.safeParse(result);
    if (!parsed.success) {
      throw new PublicError(502, "provider_schema_violation", "The intelligence provider returned an invalid diarization proposal");
    }
    const tolerance = Math.max(0.05, upload.probe.durationSeconds * 0.01);
    let priorEnd = 0;
    if (Math.abs(parsed.data.duration - upload.probe.durationSeconds) > tolerance
      || parsed.data.segments.some((segment) => {
        const invalid = segment.start < priorEnd
          || segment.end > upload.probe.durationSeconds + 0.000_001;
        priorEnd = segment.end;
        return invalid;
      })) {
      throw new PublicError(502, "provider_schema_violation", "Diarization output exceeds the validated audio boundary");
    }
    return {
      revision_kind: "diarization_proposal",
      model_call: { model: this.model },
      input_audio: upload.probe,
      transcription: parsed.data,
    };
  }
}
