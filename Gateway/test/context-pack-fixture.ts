import { createPrivateKey, createPublicKey } from "node:crypto";
import {
  computeContextPackHash,
  ContextPackApprovalAuthority,
  type ContextPack,
  type ContextPackBody,
  type ContextPackApprovalOptions,
} from "../src/context-packs.js";

export const TEST_APPROVAL_OPTIONS: ContextPackApprovalOptions = {
  signingKey: {
    privateKey: Buffer.alloc(32, 7).toString("base64url"),
    keyID: "scout-test-v1",
  },
  verificationKeys: {},
};

const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.from(TEST_APPROVAL_OPTIONS.signingKey!.privateKey, "base64url"),
  ]),
  format: "der",
  type: "pkcs8",
});
const publicDER = createPublicKey(privateKey).export({ format: "der", type: "spki" });
export const TEST_APPROVAL_PUBLIC_KEYS = {
  [TEST_APPROVAL_OPTIONS.signingKey!.keyID]: publicDER.subarray(-32).toString("base64url"),
};

const testApprovalAuthority = new ContextPackApprovalAuthority(TEST_APPROVAL_OPTIONS);

export function makeContextPack(overrides: Partial<ContextPackBody> = {}): ContextPack {
  const body: ContextPackBody = {
    context_pack_id: "pack-001",
    session_id: "session-001",
    revision: 1,
    generated_at: "2026-07-16T12:00:00Z",
    approved_at: "2026-07-16T12:01:00Z",
    journal_head_sha256: "a".repeat(64),
    organization: "Acme Retail",
    objective: "Detect a missing export before customer impact.",
    graph_state_sha256: "0".repeat(64),
    entities: [{
      id: "system-netsuite",
      kind: "system",
      title: "NetSuite",
      detail: "Inventory system",
      trust: "heard",
      confidence_basis_points: 9_800,
    }],
    relationships: [{
      id: "edge-netsuite-order",
      source_id: "system-netsuite",
      target_id: "system-netsuite",
      predicate: "tracks",
      epistemic_mode: "heard",
      confidence_basis_points: 9_100,
      needs_validation: false,
      supporting_claim_ids: ["claim-nightly"],
      source_evidence_ids: ["evidence-source-nightly"],
    }],
    claims: [{
      id: "claim-nightly",
      title: "Inventory reconciliation is batch-only",
      detail: "Inventory is reconciled through a nightly export.",
      epistemic_mode: "heard",
      confidence_basis_points: 9_700,
      needs_validation: false,
      related_entity_id: "system-netsuite",
      evidence: {
        id: "evidence-claim-nightly",
        source_evidence_ids: ["evidence-source-nightly"],
        speaker: "Raj",
        timestamp: "30:46",
        excerpt: "The two systems reconcile through a nightly export.",
      },
    }],
    open_questions: [],
    quick_wins: [{
      id: "win-monitor",
      title: "Inventory feed sentinel",
      detail: "Detect a missing export before customer impact.",
      impact: 4,
      effort: 1,
      readiness: 5,
      time_to_value: "3–5 days",
      evidence_count: 4,
      supporting_claim_ids: ["claim-nightly"],
    }],
    selected_poc: {
      id: "poc-inventory-feed-sentinel",
      title: "Inventory feed sentinel",
      problem: "Detect a missing export before customer impact.",
      scope: ["Detect missing nightly exports"],
      selection_state: "selected_for_poc",
      epistemic_mode: "suggested",
      supporting_claim_ids: ["claim-nightly"],
    },
    non_goals: [{
      id: "non-goal-system-writes",
      statement: "No writes to systems of record.",
      rationale: "The proof of value is read-only.",
    }],
    constraints: [{
      id: "constraint-read-only",
      statement: "The POC must not mutate systems of record.",
      category: "system_mutation",
      epistemic_mode: "suggested",
      supporting_claim_ids: ["claim-nightly"],
    }],
    acceptance_criteria: [{
      id: "accept-detect",
      statement: "Detect a missing export before customer impact.",
      measure: "Detection lead time",
      target: "> 0 minutes",
      supporting_claim_ids: ["claim-nightly"],
    }],
    success_measures: [{
      id: "measure-detection-lead",
      name: "Detection lead",
      baseline: "After customer impact",
      target: "Before customer impact",
      unit: "event ordering",
      supporting_claim_ids: ["claim-nightly"],
    }],
    redaction_manifest: {
      contains_raw_audio: false,
      contains_raw_transcript: false,
      excludes_personal_data_by_default: true,
      included_evidence_form: "minimal attributed excerpts",
    },
    ...overrides,
  };
  if (body.approved_at === undefined) {
    body.journal_head_sha256 = undefined;
    body.previous_context_pack_sha256 = undefined;
  }
  if (overrides.graph_state_sha256 === undefined) {
    body.graph_state_sha256 = computeContextPackHash({
      entities: body.entities,
      relationships: body.relationships,
    });
  }
  const pack: ContextPack = {
    schema_version: 1,
    content_sha256: computeContextPackHash(body),
    body,
  };
  return body.approved_at === undefined ? pack : testApprovalAuthority.approve(pack);
}
