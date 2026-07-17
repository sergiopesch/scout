import type { IncomingMessage } from "node:http";
import { basename, extname } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import Busboy from "busboy";
import OpenAI, { toFile } from "openai";
import { z } from "zod/v4";
import { PublicError } from "./errors.js";

export const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const MAX_MULTIPART_BYTES = MAX_AUDIO_BYTES + 128 * 1024;

const supportedExtensions = new Set([".flac", ".mp3", ".mp4", ".mpeg", ".mpga", ".m4a", ".ogg", ".wav", ".webm"]);
const LanguageSchema = z.string().regex(/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?$/).max(16);

export interface DiarizationUpload {
  readonly bytes: Buffer;
  readonly filename: string;
  readonly mimeType: string;
  readonly language?: string;
}

function safeFilename(value: string): string {
  const name = basename(value).replace(/[^A-Za-z0-9._-]/g, "_").slice(-180);
  if (!name || !supportedExtensions.has(extname(name).toLowerCase())) {
    throw new PublicError(415, "unsupported_audio_format", "The audio file format is not supported");
  }
  return name;
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

  return {
    bytes: Buffer.concat(chunks, fileBytes),
    filename,
    mimeType,
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
    return {
      revision_kind: "diarization_proposal",
      model_call: { model: this.model },
      transcription: parsed.data,
    };
  }
}
