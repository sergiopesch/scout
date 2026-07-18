import {
  createHash,
  createPrivateKey,
  createPublicKey,
  randomUUID,
  sign as signEd25519,
  verify as verifyEd25519,
  type KeyObject,
} from "node:crypto";
import { chmod, link, lstat, mkdir, open, readFile, readdir, realpath, unlink } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve, sep } from "node:path";
import { z } from "zod/v4";
import { PublicError } from "./errors.js";

export const MAX_CONTEXT_PACK_BYTES = 2 * 1024 * 1024;
const MAX_COLLECTION_ITEMS = 20_000;
const MAX_CONTEXT_PACK_FILES = 10_000;
const Identifier = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
const SHA256 = z.string().regex(/^[a-f0-9]{64}$/);
const Ed25519RawKey = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const Ed25519Signature = z.string().regex(/^[A-Za-z0-9_-]{86}$/);
const Timestamp = z.string().datetime({ offset: true });
const DetailText = z.string().max(40_000);
const BasisPoints = z.number().int().min(0).max(10_000);
const EpistemicMode = z.enum(["heard", "inferred", "suggested", "confirmed"]);
const RecommendationMode = z.enum(["suggested", "confirmed"]);
const EntityKind = z.enum(["person", "system", "data", "process", "goal", "guardrail", "friction", "action"]);
const QuestionPriority = z.enum(["critical", "high", "explore"]);
const ConstraintCategory = z.enum(["data_boundary", "system_mutation", "integration", "operational"]);
const SupportingClaimIDs = z.array(Identifier).max(MAX_COLLECTION_ITEMS);

const EntitySchema = z.object({
  id: Identifier,
  kind: EntityKind,
  title: z.string().min(1).max(2_000),
  detail: DetailText,
  trust: EpistemicMode,
  confidence_basis_points: BasisPoints,
}).strict();

const RelationshipSchema = z.object({
  id: Identifier,
  source_id: Identifier,
  target_id: Identifier,
  predicate: z.string().min(1).max(2_000),
  epistemic_mode: EpistemicMode,
  confidence_basis_points: BasisPoints,
  needs_validation: z.boolean(),
  supporting_claim_ids: SupportingClaimIDs.min(1),
  source_evidence_ids: z.array(Identifier).min(1).max(MAX_COLLECTION_ITEMS),
}).strict();

const EvidenceSchema = z.object({
  id: Identifier,
  source_evidence_ids: z.array(Identifier).min(1).max(32),
  speaker: z.string().min(1).max(1_000),
  timestamp: z.string().min(1).max(128),
  excerpt: z.string().min(1).max(8_000),
}).strict();

const ClaimSchema = z.object({
  id: Identifier,
  title: z.string().min(1).max(2_000),
  detail: DetailText,
  epistemic_mode: EpistemicMode,
  confidence_basis_points: BasisPoints,
  needs_validation: z.boolean(),
  related_entity_id: Identifier.optional(),
  evidence: EvidenceSchema,
}).strict();

const QuestionSchema = z.object({
  id: Identifier,
  priority: QuestionPriority,
  topic: z.string().min(1).max(2_000),
  question: z.string().min(1).max(8_000),
  rationale: DetailText,
}).strict();

const OpportunitySchema = z.object({
  id: Identifier,
  title: z.string().min(1).max(2_000),
  detail: DetailText,
  impact: z.number().int().min(0).max(10_000),
  effort: z.number().int().min(0).max(10_000),
  readiness: z.number().int().min(0).max(10_000),
  time_to_value: z.string().min(1).max(512),
  evidence_count: z.number().int().nonnegative().max(1_000_000),
  supporting_claim_ids: SupportingClaimIDs,
}).strict();

const SelectedPOCSchema = z.object({
  id: Identifier,
  title: z.string().min(1).max(2_000),
  problem: DetailText,
  scope: z.array(z.string().min(1).max(8_000)).min(1).max(1_000),
  selection_state: z.literal("selected_for_poc"),
  epistemic_mode: RecommendationMode,
  supporting_claim_ids: SupportingClaimIDs.min(1),
}).strict();

const NonGoalSchema = z.object({
  id: Identifier,
  statement: z.string().min(1).max(8_000),
  rationale: DetailText,
}).strict();

const ConstraintSchema = z.object({
  id: Identifier,
  statement: z.string().min(1).max(8_000),
  category: ConstraintCategory,
  epistemic_mode: EpistemicMode,
  supporting_claim_ids: SupportingClaimIDs.min(1),
}).strict();

const AcceptanceCriterionSchema = z.object({
  id: Identifier,
  statement: z.string().min(1).max(8_000),
  measure: z.string().min(1).max(2_000),
  target: z.string().min(1).max(2_000),
  supporting_claim_ids: SupportingClaimIDs.min(1),
}).strict();

const SuccessMeasureSchema = z.object({
  id: Identifier,
  name: z.string().min(1).max(2_000),
  baseline: z.string().min(1).max(2_000),
  target: z.string().min(1).max(2_000),
  unit: z.string().min(1).max(1_000),
  supporting_claim_ids: SupportingClaimIDs.min(1),
}).strict();

const RedactionManifestSchema = z.object({
  contains_raw_audio: z.literal(false),
  contains_raw_transcript: z.literal(false),
  excludes_personal_data_by_default: z.literal(true),
  included_evidence_form: z.string().min(1).max(1_000),
}).strict();

export const ContextPackBodySchema = z.object({
  context_pack_id: Identifier,
  session_id: Identifier,
  revision: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  generated_at: Timestamp,
  approved_at: Timestamp.optional(),
  journal_head_sha256: SHA256.optional(),
  previous_context_pack_sha256: SHA256.optional(),
  organization: z.string().min(1).max(4_000),
  objective: DetailText,
  graph_state_sha256: SHA256,
  entities: z.array(EntitySchema).max(MAX_COLLECTION_ITEMS),
  relationships: z.array(RelationshipSchema).max(MAX_COLLECTION_ITEMS),
  claims: z.array(ClaimSchema).max(MAX_COLLECTION_ITEMS),
  open_questions: z.array(QuestionSchema).max(MAX_COLLECTION_ITEMS),
  quick_wins: z.array(OpportunitySchema).max(MAX_COLLECTION_ITEMS),
  selected_poc: SelectedPOCSchema.nullable().optional(),
  non_goals: z.array(NonGoalSchema).max(MAX_COLLECTION_ITEMS),
  constraints: z.array(ConstraintSchema).max(MAX_COLLECTION_ITEMS),
  acceptance_criteria: z.array(AcceptanceCriterionSchema).max(MAX_COLLECTION_ITEMS),
  success_measures: z.array(SuccessMeasureSchema).max(MAX_COLLECTION_ITEMS),
  redaction_manifest: RedactionManifestSchema,
}).strict();

const ApprovalBindingSchema = z.object({
  algorithm: z.literal("ed25519"),
  key_id: Identifier,
  context_pack_id: Identifier,
  session_id: Identifier,
  revision: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  journal_head_sha256: SHA256,
  previous_context_pack_sha256: SHA256.optional(),
  content_sha256: SHA256,
  approved_scope_sha256: SHA256,
  approved_at: Timestamp,
  signature: Ed25519Signature,
}).strict();

export const ContextPackSchema = z.object({
  schema_version: z.literal(1),
  content_sha256: SHA256,
  body: ContextPackBodySchema,
  approval: ApprovalBindingSchema.optional(),
}).strict();

export type ContextPackBody = z.infer<typeof ContextPackBodySchema>;
export type ContextPack = z.infer<typeof ContextPackSchema>;
export type ApprovalBinding = z.infer<typeof ApprovalBindingSchema>;

export interface ContextPackApprovalOptions {
  readonly signingKey?: {
    readonly keyID: string;
    readonly privateKey: string;
  };
  readonly verificationKeys: Readonly<Record<string, string>>;
}

export class ContextPackApprovalAuthority {
  private readonly activeKey: KeyObject | undefined;
  private readonly verificationKeys: ReadonlyMap<string, KeyObject>;
  readonly keyID: string | undefined;

  constructor(options: ContextPackApprovalOptions) {
    const keys = new Map<string, KeyObject>();
    for (const [keyID, key] of Object.entries(options.verificationKeys)) {
      if (!Identifier.safeParse(keyID).success || !Ed25519RawKey.safeParse(key).success) {
        throw new Error("Context-pack approval verification keyring is invalid");
      }
      keys.set(keyID, publicKeyFromRaw(key));
    }
    if (options.signingKey !== undefined) {
      if (!Identifier.safeParse(options.signingKey.keyID).success
        || !Ed25519RawKey.safeParse(options.signingKey.privateKey).success) {
        throw new Error("Context-pack approval authority is invalid");
      }
      this.activeKey = privateKeyFromRaw(options.signingKey.privateKey);
      this.keyID = options.signingKey.keyID;
      const derivedPublic = rawPublicKey(this.activeKey);
      const configuredPublic = options.verificationKeys[this.keyID];
      if (configuredPublic !== undefined && configuredPublic !== derivedPublic) {
        throw new Error("Context-pack approval signing key does not match its public key");
      }
      keys.set(this.keyID, publicKeyFromRaw(derivedPublic));
    } else {
      this.activeKey = undefined;
      this.keyID = undefined;
    }
    this.verificationKeys = keys;
  }

  approve(pack: ContextPack): ContextPack {
    if (this.activeKey === undefined || this.keyID === undefined) {
      throw new PublicError(503, "context_pack_approval_unconfigured", "Context-pack signing is not configured");
    }
    const binding = this.unsignedBinding(pack, this.keyID);
    return {
      ...pack,
      approval: {
        ...binding,
        signature: signEd25519(
          null,
          Buffer.from(canonicalJSONString(binding), "utf8"),
          this.activeKey,
        ).toString("base64url"),
      },
    };
  }

  verify(pack: ContextPack): boolean {
    const approval = pack.approval;
    if (approval === undefined) return false;
    const key = this.verificationKeys.get(approval.key_id);
    if (key === undefined) return false;
    try {
      const unsigned = this.unsignedBinding(pack, approval.key_id);
      return canonicalJSONString(approvalWithoutSignature(approval)) === canonicalJSONString(unsigned)
        && verifyEd25519(
          null,
          Buffer.from(canonicalJSONString(unsigned), "utf8"),
          key,
          Buffer.from(approval.signature, "base64url"),
        );
    } catch {
      return false;
    }
  }

  private unsignedBinding(pack: ContextPack, keyID: string): Omit<ApprovalBinding, "signature"> {
    const body = pack.body;
    if (body.approved_at === undefined || body.journal_head_sha256 === undefined) {
      throw new PublicError(422, "context_pack_approval_required", "Approved context pack lacks a canonical approval boundary");
    }
    return {
      algorithm: "ed25519",
      key_id: keyID,
      context_pack_id: body.context_pack_id,
      session_id: body.session_id,
      revision: body.revision,
      journal_head_sha256: body.journal_head_sha256,
      ...(body.previous_context_pack_sha256 === undefined
        ? {}
        : { previous_context_pack_sha256: body.previous_context_pack_sha256 }),
      content_sha256: pack.content_sha256,
      approved_scope_sha256: pack.content_sha256,
      approved_at: body.approved_at,
    };
  }

}

function approvalWithoutSignature(binding: ApprovalBinding): Omit<ApprovalBinding, "signature"> {
  const { signature: _signature, ...unsigned } = binding;
  return unsigned;
}

const ED25519_PRIVATE_DER_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const ED25519_PUBLIC_DER_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function privateKeyFromRaw(value: string): KeyObject {
  return createPrivateKey({
    key: Buffer.concat([ED25519_PRIVATE_DER_PREFIX, Buffer.from(value, "base64url")]),
    format: "der",
    type: "pkcs8",
  });
}

function publicKeyFromRaw(value: string): KeyObject {
  return createPublicKey({
    key: Buffer.concat([ED25519_PUBLIC_DER_PREFIX, Buffer.from(value, "base64url")]),
    format: "der",
    type: "spki",
  });
}

function rawPublicKey(privateKey: KeyObject): string {
  const encoded = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  return encoded.subarray(ED25519_PUBLIC_DER_PREFIX.length).toString("base64url");
}

export interface ContextPackSummary {
  readonly context_pack_id: string;
  readonly session_id: string;
  readonly content_sha256: string;
  readonly revision: number;
  readonly generated_at: string;
  readonly approved_at?: string;
  readonly organization: string;
  readonly objective: string;
  readonly graph_state_sha256: string;
  readonly schema_version: 1;
}

export interface ContextPackPutResult {
  readonly contextPack: ContextPackSummary;
  readonly created: boolean;
}

export interface SessionHead {
  readonly session_id: string;
  readonly context_pack_id: string;
  readonly revision: number;
  readonly generated_at: string;
  readonly approved_at: string;
  readonly content_sha256: string;
  readonly graph_state_sha256: string;
}

export interface ContextPackPage {
  readonly context_packs: ContextPackSummary[];
  readonly next_cursor: string | null;
  readonly limit: number;
}

const CursorSchema = z.object({
  v: z.literal(1),
  session_id: Identifier.nullable(),
  generated_at: Timestamp,
  context_pack_id: Identifier,
}).strict();

const forbiddenKeys = new Set([
  "openaikey",
  "openaiapikey",
  "apikey",
  "rawaudio",
  "rawaudiobase64",
  "rawtranscript",
  "unrestrictedtranscript",
  "rawimage",
  "rawimagebase64",
  "normalizedimage",
  "imagebytes",
  "imagedataurl",
]);

function normalizedKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function assertNoForbiddenMaterial(value: unknown): void {
  const pending: Array<{ value: unknown; path: string }> = [{ value, path: "$" }];
  let visited = 0;
  while (pending.length > 0) {
    const current = pending.pop();
    if (current === undefined) break;
    visited += 1;
    if (visited > 250_000) {
      throw new PublicError(422, "invalid_context_pack", "Context pack structure is too complex");
    }
    if (typeof current.value === "string") {
      if (/(?:^|[^A-Za-z0-9])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}(?:$|[^A-Za-z0-9_-])/.test(current.value)) {
        throw new PublicError(422, "context_pack_privacy_violation", `Context pack contains credential-shaped material at ${current.path}`);
      }
      continue;
    }
    if (Array.isArray(current.value)) {
      for (let index = 0; index < current.value.length; index += 1) {
        const path = current.path.length < 512 ? `${current.path}[${index}]` : "$.<deep>";
        pending.push({ value: current.value[index], path });
      }
      continue;
    }
    if (!current.value || typeof current.value !== "object") continue;
    for (const [key, child] of Object.entries(current.value as Record<string, unknown>)) {
      if (forbiddenKeys.has(normalizedKey(key))) {
        throw new PublicError(422, "context_pack_privacy_violation", `Context pack contains forbidden material at ${current.path}`);
      }
      const path = current.path.length < 512 ? `${current.path}.${key}` : "$.<deep>";
      pending.push({ value: child, path });
    }
  }
}

/** Matches JSONEncoder's sorted-key encoding for Scout's integer/string/bool/null body contract. */
export function canonicalJSONString(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new PublicError(422, "invalid_context_pack", "Context pack contains a non-finite number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJSONString).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, child]) => child !== undefined)
      .sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0);
    return `{${entries.map(([key, child]) => `${JSON.stringify(key)}:${canonicalJSONString(child)}`).join(",")}}`;
  }
  throw new PublicError(422, "invalid_context_pack", "Context pack contains an unsupported JSON value");
}

/** The app signs the canonical, snake-case encoded body only. */
export function computeContextPackHash(body: unknown): string {
  return createHash("sha256").update(canonicalJSONString(body)).digest("hex");
}

function assertUniqueIDs(values: readonly { id: string }[], label: string): void {
  const ids = new Set<string>();
  for (const value of values) {
    if (ids.has(value.id)) {
      throw new PublicError(422, "invalid_context_pack_integrity", `Context pack contains a duplicate ${label} ID`);
    }
    ids.add(value.id);
  }
}

function assertUniqueReferences(values: readonly string[], label: string): void {
  if (new Set(values).size !== values.length) {
    throw new PublicError(422, "invalid_context_pack_integrity", `Context pack contains duplicate ${label} references`);
  }
}

function setsEqual(left: ReadonlySet<string>, right: ReadonlySet<string>): boolean {
  return left.size === right.size && [...left].every((value) => right.has(value));
}

function assertContextPackIntegrity(body: ContextPackBody): void {
  assertUniqueIDs(body.entities, "entity");
  assertUniqueIDs(body.relationships, "relationship");
  assertUniqueIDs(body.claims, "claim");
  assertUniqueIDs(body.open_questions, "question");
  assertUniqueIDs(body.quick_wins, "opportunity");
  assertUniqueIDs(body.non_goals, "non-goal");
  assertUniqueIDs(body.constraints, "constraint");
  assertUniqueIDs(body.acceptance_criteria, "acceptance-criterion");
  assertUniqueIDs(body.success_measures, "success-measure");

  const entityIDs = new Set(body.entities.map((entity) => entity.id));
  for (const relationship of body.relationships) {
    if (!entityIDs.has(relationship.source_id) || !entityIDs.has(relationship.target_id)) {
      throw new PublicError(422, "invalid_context_pack_integrity", "A relationship references an unknown entity");
    }
  }

  const evidenceIDs = body.claims.map((claim) => claim.evidence.id);
  assertUniqueReferences(evidenceIDs, "evidence");
  for (const claim of body.claims) {
    assertUniqueReferences(claim.evidence.source_evidence_ids, "source evidence");
  }
  const claimIDs = new Set(body.claims.map((claim) => claim.id));
  for (const claim of body.claims) {
    if (claim.related_entity_id !== undefined && !entityIDs.has(claim.related_entity_id)) {
      throw new PublicError(422, "invalid_context_pack_integrity", "A claim references an unknown related entity");
    }
  }
  const claimsByID = new Map(body.claims.map((claim) => [claim.id, claim]));
  for (const relationship of body.relationships) {
    assertUniqueReferences(relationship.supporting_claim_ids, "relationship supporting claim");
    assertUniqueReferences(relationship.source_evidence_ids, "relationship source evidence");
    if (relationship.supporting_claim_ids.some((id) => !claimIDs.has(id))) {
      throw new PublicError(422, "invalid_context_pack_integrity", "A relationship references an unknown claim");
    }
    const authorizedEvidenceIDs = new Set(relationship.supporting_claim_ids.flatMap(
      (id) => claimsByID.get(id)?.evidence.source_evidence_ids ?? [],
    ));
    if (relationship.source_evidence_ids.some((id) => !authorizedEvidenceIDs.has(id))) {
      throw new PublicError(422, "invalid_context_pack_integrity", "A relationship references evidence outside its supporting claims");
    }
  }
  const referenceSets: readonly (readonly string[])[] = [
    ...body.quick_wins.map((value) => value.supporting_claim_ids),
    ...(body.selected_poc === undefined || body.selected_poc === null
      ? []
      : [body.selected_poc.supporting_claim_ids]),
    ...body.constraints.map((value) => value.supporting_claim_ids),
    ...body.acceptance_criteria.map((value) => value.supporting_claim_ids),
    ...body.success_measures.map((value) => value.supporting_claim_ids),
  ];
  for (const references of referenceSets) {
    assertUniqueReferences(references, "supporting claim");
    if (references.some((id) => !claimIDs.has(id))) {
      throw new PublicError(422, "invalid_context_pack_integrity", "Build guidance references an unknown claim");
    }
  }

  const graphHash = computeContextPackHash({ entities: body.entities, relationships: body.relationships });
  if (graphHash !== body.graph_state_sha256) {
    throw new PublicError(422, "context_pack_graph_hash_mismatch", "Context pack graph hash does not match its graph projection");
  }
  if (body.approved_at !== undefined && Date.parse(body.approved_at) < Date.parse(body.generated_at)) {
    throw new PublicError(422, "invalid_context_pack_integrity", "Context pack approval predates generation");
  }
  if (body.approved_at !== undefined) {
    if (body.journal_head_sha256 === undefined) {
      throw new PublicError(422, "invalid_context_pack_integrity", "An approved handoff requires a canonical journal head");
    }
    if (body.selected_poc === undefined || body.selected_poc === null) {
      throw new PublicError(422, "invalid_context_pack_integrity", "An approved handoff requires a selected POC");
    }
    const approvedClaimIDs = new Set(body.selected_poc.supporting_claim_ids);
    const approvedBuildReferences = new Set([
      ...body.constraints.flatMap((value) => value.supporting_claim_ids),
      ...body.acceptance_criteria.flatMap((value) => value.supporting_claim_ids),
      ...body.success_measures.flatMap((value) => value.supporting_claim_ids),
    ]);
    if (!setsEqual(claimIDs, approvedClaimIDs)
      || [...approvedBuildReferences].some((id) => !approvedClaimIDs.has(id))) {
      throw new PublicError(422, "invalid_context_pack_integrity", "Approved handoff exceeds the selected POC claim closure");
    }
    for (const claimID of approvedClaimIDs) {
      const claim = claimsByID.get(claimID);
      if (claim === undefined
        || claim.needs_validation
        || (claim.epistemic_mode !== "heard" && claim.epistemic_mode !== "confirmed")) {
        throw new PublicError(
          422,
          "invalid_context_pack_integrity",
          "Approved build guidance may reference only factual claims that do not need validation",
        );
      }
    }
    if (body.open_questions.length !== 0) {
      throw new PublicError(422, "invalid_context_pack_integrity", "Approved handoff cannot include open discovery questions");
    }
    if (body.objective !== body.selected_poc.problem) {
      throw new PublicError(422, "invalid_context_pack_integrity", "Approved handoff objective must equal the selected POC problem");
    }
    const selectedQuickWin = body.quick_wins[0];
    if (body.quick_wins.length !== 1
      || selectedQuickWin === undefined
      || selectedQuickWin.title !== body.selected_poc.title
      || selectedQuickWin.detail !== body.selected_poc.problem
      || !setsEqual(new Set(selectedQuickWin.supporting_claim_ids), approvedClaimIDs)) {
      throw new PublicError(422, "invalid_context_pack_integrity", "Approved handoff must contain only the selected POC opportunity");
    }
    const authorizedEntityIDs = new Set(body.claims.flatMap((claim) => (
      claim.related_entity_id === undefined ? [] : [claim.related_entity_id]
    )));
    for (const relationship of body.relationships) {
      relationship.supporting_claim_ids.forEach((id) => {
        if (!approvedClaimIDs.has(id)) {
          throw new PublicError(422, "invalid_context_pack_integrity", "Approved relationship exceeds the selected POC claim closure");
        }
      });
      authorizedEntityIDs.add(relationship.source_id);
      authorizedEntityIDs.add(relationship.target_id);
    }
    if (!setsEqual(entityIDs, authorizedEntityIDs)) {
      throw new PublicError(422, "invalid_context_pack_integrity", "Approved handoff exceeds the selected POC entity closure");
    }
  } else if (body.journal_head_sha256 !== undefined || body.previous_context_pack_sha256 !== undefined) {
    throw new PublicError(422, "invalid_context_pack_integrity", "Draft context packs cannot carry approval boundaries");
  }
}

export class ContextPackStore {
  readonly root: string;
  private readonly containmentRoot: string;
  private readonly approvalAuthority: ContextPackApprovalAuthority | undefined;
  private readonly sessionWriteTails = new Map<string, Promise<void>>();

  constructor(root: string, approvalOptions?: ContextPackApprovalOptions, containmentRoot: string = root) {
    this.root = resolve(root);
    this.containmentRoot = resolve(containmentRoot);
    this.approvalAuthority = approvalOptions === undefined
      ? undefined
      : new ContextPackApprovalAuthority(approvalOptions);
  }

  /** Public reads default to approved artifacts; internal callers must opt out explicitly. */
  async list(options: { approvedOnly?: boolean; sessionId?: string } = {}): Promise<ContextPackSummary[]> {
    const approvedOnly = options.approvedOnly ?? true;
    if (options.sessionId !== undefined && !Identifier.safeParse(options.sessionId).success) {
      throw new PublicError(400, "invalid_session_id", "Session ID is invalid");
    }
    const root = await this.ensureRoot();
    const entries = await readdir(root, { withFileTypes: true });
    const candidates = entries.filter((entry) => entry.isFile() && !entry.isSymbolicLink() && entry.name.endsWith(".json"));
    if (candidates.length > MAX_CONTEXT_PACK_FILES) {
      throw new PublicError(503, "context_pack_store_capacity_exceeded", "Context pack store requires maintenance");
    }
    const summaries: ContextPackSummary[] = [];
    for (const entry of candidates) {
      const id = entry.name.slice(0, -5);
      if (!Identifier.safeParse(id).success) continue;
      try {
        const pack = await this.read(id, approvedOnly);
        const summary = this.summary(pack);
        if (options.sessionId === undefined || summary.session_id === options.sessionId) summaries.push(summary);
      } catch (error) {
        if (error instanceof PublicError && approvedOnly && error.code === "context_pack_not_found") continue;
        throw error;
      }
    }
    return summaries.sort((left, right) =>
      right.generated_at.localeCompare(left.generated_at)
      || right.context_pack_id.localeCompare(left.context_pack_id));
  }

  async listPage(options: { sessionId?: string; limit?: number; cursor?: string } = {}): Promise<ContextPackPage> {
    const limit = options.limit ?? 20;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new PublicError(400, "invalid_page_limit", "Page limit must be an integer from 1 through 100");
    }
    const cursor = options.cursor === undefined ? undefined : this.decodeCursor(options.cursor);
    if (cursor !== undefined && cursor.session_id !== (options.sessionId ?? null)) {
      throw new PublicError(400, "invalid_page_cursor", "Page cursor does not belong to this query");
    }
    const summaries = await this.list({ sessionId: options.sessionId });
    const afterCursor = cursor === undefined ? summaries : summaries.filter((summary) =>
      summary.generated_at < cursor.generated_at
      || (summary.generated_at === cursor.generated_at && summary.context_pack_id < cursor.context_pack_id));
    const page = afterCursor.slice(0, limit);
    const last = page.at(-1);
    return {
      context_packs: page,
      next_cursor: afterCursor.length > limit && last !== undefined
        ? this.encodeCursor(options.sessionId, last.generated_at, last.context_pack_id)
        : null,
      limit,
    };
  }

  async head(sessionId: string): Promise<SessionHead | null> {
    if (!Identifier.safeParse(sessionId).success) {
      throw new PublicError(400, "invalid_session_id", "Session ID is invalid");
    }
    const summaries = await this.list({ sessionId });
    const current = summaries.sort((left, right) =>
      right.revision - left.revision
      || right.generated_at.localeCompare(left.generated_at)
      || right.context_pack_id.localeCompare(left.context_pack_id))[0];
    if (current?.approved_at === undefined) return null;
    return {
      session_id: current.session_id,
      context_pack_id: current.context_pack_id,
      revision: current.revision,
      generated_at: current.generated_at,
      approved_at: current.approved_at,
      content_sha256: current.content_sha256,
      graph_state_sha256: current.graph_state_sha256,
    };
  }

  async get(contextPackId: string, options: { approvedOnly?: boolean } = {}): Promise<ContextPack> {
    return this.read(contextPackId, options.approvedOnly ?? true);
  }

  async approve(raw: unknown): Promise<{ contextPack: ContextPack; created: boolean }> {
    if (this.approvalAuthority === undefined) {
      throw new PublicError(503, "context_pack_approval_unconfigured", "Context-pack approval is not configured");
    }
    assertNoForbiddenMaterial(raw);
    const parsed = ContextPackSchema.safeParse(raw);
    if (!parsed.success || parsed.data.approval !== undefined || parsed.data.body.approved_at === undefined) {
      throw new PublicError(422, "invalid_context_pack", "Approval requires one unsigned, final context pack");
    }
    this.validatePack(parsed.data, false);
    const approved = this.approvalAuthority.approve(parsed.data);
    const result = await this.put(approved);
    return { contextPack: approved, created: result.created };
  }

  async put(raw: unknown): Promise<ContextPackPutResult> {
    assertNoForbiddenMaterial(raw);
    const parsed = ContextPackSchema.safeParse(raw);
    if (!parsed.success) {
      throw new PublicError(422, "invalid_context_pack", "Context pack does not satisfy the Scout export contract");
    }
    this.validatePack(parsed.data, true);

    const encoded = `${canonicalJSONString(parsed.data)}\n`;
    if (Buffer.byteLength(encoded) > MAX_CONTEXT_PACK_BYTES) {
      throw new PublicError(413, "context_pack_too_large", "Context pack is too large");
    }

    return this.withSessionWriteLock(parsed.data.body.session_id, async () => {
      const root = await this.ensureRoot();
      const id = parsed.data.body.context_pack_id;
      const existingByID = await this.read(id, false).catch((error: unknown) => {
        if (error instanceof PublicError && error.code === "context_pack_not_found") return undefined;
        throw error;
      });
      if (existingByID !== undefined) {
        if (canonicalJSONString(existingByID) === canonicalJSONString(parsed.data)) {
          return { contextPack: this.summary(existingByID), created: false };
        }
        throw new PublicError(409, "context_pack_exists", "A different immutable context pack already uses this ID");
      }

      const sessionPacks = await this.list({
        approvedOnly: false,
        sessionId: parsed.data.body.session_id,
      });
      const current = sessionPacks.sort((left, right) =>
        right.revision - left.revision
        || right.generated_at.localeCompare(left.generated_at)
        || right.context_pack_id.localeCompare(left.context_pack_id))[0];
      const currentRevision = current?.revision ?? 0;
      const expectedRevision = currentRevision + 1;
      if (parsed.data.body.revision !== expectedRevision) {
        throw new PublicError(
          409,
          "context_pack_revision_conflict",
          `Context pack revision must extend the current session head (expected ${expectedRevision})`,
        );
      }
      if (parsed.data.body.previous_context_pack_sha256 !== current?.content_sha256) {
        throw new PublicError(
          409,
          "context_pack_head_conflict",
          "Context pack approval does not extend the exact staged session head",
        );
      }

      const destination = join(root, `${id}.json`);
      const temporary = join(root, `.${id}.${randomUUID()}.tmp`);
      let handle;
      try {
        handle = await open(temporary, "wx", 0o600);
        await handle.writeFile(encoded, "utf8");
        await handle.sync();
        await handle.close();
        handle = undefined;
        await link(temporary, destination);
        const directoryHandle = await open(root, "r");
        try {
          await directoryHandle.sync();
        } finally {
          await directoryHandle.close();
        }
        return { contextPack: this.summary(parsed.data), created: true };
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "EEXIST") {
          const existing = await this.read(id, false).catch(() => undefined);
          if (existing && canonicalJSONString(existing) === canonicalJSONString(parsed.data)) {
            return { contextPack: this.summary(existing), created: false };
          }
          throw new PublicError(409, "context_pack_exists", "A different immutable context pack already uses this ID");
        }
        if (error instanceof PublicError) throw error;
        throw new PublicError(503, "context_pack_store_unavailable", "Context pack store is unavailable");
      } finally {
        if (handle) await handle.close().catch(() => undefined);
        await unlink(temporary).catch(() => undefined);
      }
    });
  }

  /// Serializes head comparison and immutable creation per session. Scout Bridge is intentionally
  /// a single local authority; this prevents concurrent requests from forking one revision number.
  private async withSessionWriteLock<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.sessionWriteTails.get(sessionId) ?? Promise.resolve();
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolveGate) => { release = resolveGate; });
    const tail = previous.then(() => gate);
    this.sessionWriteTails.set(sessionId, tail);
    await previous;
    try {
      return await operation();
    } finally {
      release?.();
      if (this.sessionWriteTails.get(sessionId) === tail) {
        this.sessionWriteTails.delete(sessionId);
      }
    }
  }

  private validatePack(pack: ContextPack, requireApprovalBinding: boolean): void {
    if (computeContextPackHash(pack.body) !== pack.content_sha256) {
      throw new PublicError(422, "context_pack_hash_mismatch", "Context pack body hash does not match its contents");
    }
    assertContextPackIntegrity(pack.body);
    if (pack.body.approved_at === undefined) {
      if (pack.approval !== undefined) {
        throw new PublicError(422, "invalid_context_pack_integrity", "Draft context pack carries an approval binding");
      }
      return;
    }
    if (!requireApprovalBinding) return;
    if (pack.approval === undefined || this.approvalAuthority?.verify(pack) !== true) {
      throw new PublicError(422, "context_pack_approval_invalid", "Context pack approval is missing or invalid");
    }
  }

  private async read(contextPackId: string, approvedOnly: boolean): Promise<ContextPack> {
    const parsedId = Identifier.safeParse(contextPackId);
    if (!parsedId.success) {
      throw new PublicError(400, "invalid_context_pack_id", "Context pack ID is invalid");
    }

    const root = await this.ensureRoot();
    const filePath = join(root, `${parsedId.data}.json`);
    let metadata;
    try {
      metadata = await lstat(filePath);
    } catch {
      throw new PublicError(404, "context_pack_not_found", "Context pack was not found");
    }
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > MAX_CONTEXT_PACK_BYTES) {
      throw new PublicError(422, "invalid_context_pack", "Context pack is not a valid immutable artifact");
    }

    const canonicalPath = await realpath(filePath);
    const relativePath = relative(root, canonicalPath);
    if (relativePath.startsWith("..") || basename(canonicalPath) !== `${parsedId.data}.json`) {
      throw new PublicError(422, "invalid_context_pack", "Context pack path is unsafe");
    }

    let raw: unknown;
    try {
      raw = JSON.parse(await readFile(canonicalPath, "utf8")) as unknown;
    } catch {
      throw new PublicError(422, "invalid_context_pack", "Context pack is not valid JSON");
    }
    assertNoForbiddenMaterial(raw);

    const parsed = ContextPackSchema.safeParse(raw);
    if (!parsed.success || parsed.data.body.context_pack_id !== parsedId.data) {
      throw new PublicError(422, "invalid_context_pack", "Context pack does not satisfy the Scout export contract");
    }
    this.validatePack(parsed.data, true);
    if (approvedOnly && parsed.data.body.approved_at === undefined) {
      throw new PublicError(404, "context_pack_not_found", "Context pack was not found");
    }
    return parsed.data;
  }

  private async ensureRoot(): Promise<string> {
    try {
      await mkdir(this.containmentRoot, { recursive: true, mode: 0o700 });
      const boundaryMetadata = await lstat(this.containmentRoot);
      if (!boundaryMetadata.isDirectory() || boundaryMetadata.isSymbolicLink()) throw new Error("unsafe boundary");
      await chmod(this.containmentRoot, 0o700);

      const lexicalPath = relative(this.containmentRoot, this.root);
      if (isAbsolute(lexicalPath) || lexicalPath === ".." || lexicalPath.startsWith(`..${sep}`)) {
        throw new Error("root escapes boundary");
      }

      let current = this.containmentRoot;
      for (const component of lexicalPath.split(sep).filter(Boolean)) {
        current = join(current, component);
        try {
          await mkdir(current, { mode: 0o700 });
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        }
        const metadata = await lstat(current);
        if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error("unsafe path component");
        await chmod(current, 0o700);
      }

      const canonicalBoundary = await realpath(this.containmentRoot);
      const canonicalRoot = await realpath(this.root);
      const canonicalPath = relative(canonicalBoundary, canonicalRoot);
      if (isAbsolute(canonicalPath) || canonicalPath === ".." || canonicalPath.startsWith(`..${sep}`)) {
        throw new Error("canonical root escapes boundary");
      }
      return canonicalRoot;
    } catch {
      throw new PublicError(503, "context_pack_store_unavailable", "Context pack store is unavailable");
    }
  }

  private decodeCursor(cursor: string): z.infer<typeof CursorSchema> {
    if (cursor.length < 1 || cursor.length > 512 || !/^[A-Za-z0-9_-]+$/.test(cursor)) {
      throw new PublicError(400, "invalid_page_cursor", "Page cursor is invalid");
    }
    try {
      const decoded = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as unknown;
      const parsed = CursorSchema.safeParse(decoded);
      if (!parsed.success) throw new Error("invalid cursor payload");
      return parsed.data;
    } catch {
      throw new PublicError(400, "invalid_page_cursor", "Page cursor is invalid");
    }
  }

  private encodeCursor(sessionId: string | undefined, generatedAt: string, contextPackId: string): string {
    return Buffer.from(canonicalJSONString({
      v: 1,
      session_id: sessionId ?? null,
      generated_at: generatedAt,
      context_pack_id: contextPackId,
    }), "utf8").toString("base64url");
  }

  private summary(pack: ContextPack): ContextPackSummary {
    const body = pack.body;
    return {
      context_pack_id: body.context_pack_id,
      session_id: body.session_id,
      content_sha256: pack.content_sha256,
      revision: body.revision,
      generated_at: body.generated_at,
      ...(body.approved_at === undefined ? {} : { approved_at: body.approved_at }),
      organization: body.organization,
      objective: body.objective,
      graph_state_sha256: body.graph_state_sha256,
      schema_version: pack.schema_version,
    };
  }
}
