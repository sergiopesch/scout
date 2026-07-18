import assert from "node:assert/strict";
import { createPrivateKey, createPublicKey } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  canonicalJSONString,
  computeContextPackHash,
  ContextPackApprovalAuthority,
  ContextPackStore,
} from "../src/context-packs.js";
import { PublicError } from "../src/errors.js";
import {
  makeContextPack,
  TEST_APPROVAL_OPTIONS,
  TEST_APPROVAL_PUBLIC_KEYS,
} from "./context-pack-fixture.js";

function publicKeyFor(privateKey: string): string {
  const key = createPrivateKey({
    key: Buffer.concat([
      Buffer.from("302e020100300506032b657004220420", "hex"),
      Buffer.from(privateKey, "base64url"),
    ]),
    format: "der",
    type: "pkcs8",
  });
  return createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("base64url");
}

test("approval-key rotation retains verification of packs signed by non-retired keys", () => {
  const rotatedPrivateKey = Buffer.alloc(32, 11).toString("base64url");
  const rotated = new ContextPackApprovalAuthority({
    signingKey: { keyID: "scout-test-v2", privateKey: rotatedPrivateKey },
    verificationKeys: TEST_APPROVAL_PUBLIC_KEYS,
  });
  const oldPack = makeContextPack();
  assert.equal(rotated.verify(oldPack), true);

  const unsigned = structuredClone(oldPack);
  delete unsigned.approval;
  const newlyApproved = rotated.approve(unsigned);
  assert.equal(newlyApproved.approval?.key_id, "scout-test-v2");
  assert.equal(rotated.verify(newlyApproved), true);

  const retired = new ContextPackApprovalAuthority({
    signingKey: { keyID: "scout-test-v2", privateKey: rotatedPrivateKey },
    verificationKeys: { "scout-test-v2": publicKeyFor(rotatedPrivateKey) },
  });
  assert.equal(retired.verify(oldPack), false);
});

test("public verification material cannot mint context-pack approvals", () => {
  const verifier = new ContextPackApprovalAuthority({
    verificationKeys: TEST_APPROVAL_PUBLIC_KEYS,
  });
  assert.equal(verifier.verify(makeContextPack()), true);

  const unsigned = structuredClone(makeContextPack());
  delete unsigned.approval;
  assert.throws(() => verifier.approve(unsigned), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_approval_unconfigured");
    return true;
  });
});

test("ContextPackStore writes immutable, body-hash-verified artifacts idempotently", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  const source = makeContextPack();

  const created = await store.put(source);
  assert.equal(created.created, true);
  assert.equal(created.contextPack.context_pack_id, "pack-001");
  assert.equal(created.contextPack.content_sha256, source.content_sha256);
  assert.deepEqual(await store.get("pack-001"), source);
  assert.equal((await store.list()).length, 1);

  const stored = await readFile(join(directory, "pack-001.json"), "utf8");
  assert.ok(stored.endsWith("\n"));
  const repeated = await store.put(source);
  assert.equal(repeated.created, false);
  assert.deepEqual(repeated.contextPack, created.contextPack);

  await assert.rejects(
    () => store.put(makeContextPack({ organization: "A different immutable body." })),
    (error: unknown) => {
      assert.ok(error instanceof PublicError);
      assert.equal(error.code, "context_pack_exists");
      return true;
    },
  );
});

test("ContextPackStore rejects symlinked roots and restores owner-only directory permissions", async (context) => {
  const boundary = await mkdtemp(join(tmpdir(), "scout-context-boundary-"));
  const outside = await mkdtemp(join(tmpdir(), "scout-context-outside-"));
  context.after(() => rm(boundary, { recursive: true, force: true }));
  context.after(() => rm(outside, { recursive: true, force: true }));

  const linkedRoot = join(boundary, "linked-context-packs");
  await symlink(outside, linkedRoot, "dir");
  const linkedStore = new ContextPackStore(linkedRoot, TEST_APPROVAL_OPTIONS, boundary);
  await assert.rejects(() => linkedStore.list(), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_store_unavailable");
    return true;
  });

  const ownedRoot = join(boundary, "owned-context-packs");
  await mkdir(ownedRoot, { mode: 0o777 });
  await chmod(ownedRoot, 0o777);
  const ownedStore = new ContextPackStore(ownedRoot, TEST_APPROVAL_OPTIONS, boundary);
  assert.deepEqual(await ownedStore.list(), []);
  assert.equal((await stat(ownedRoot)).mode & 0o777, 0o700);
});

test("ContextPackStore rejects mismatched hashes and forbidden raw material", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);

  await assert.rejects(
    () => store.put({ ...makeContextPack(), content_sha256: "0".repeat(64) }),
    (error: unknown) => {
      assert.ok(error instanceof PublicError);
      assert.equal(error.code, "context_pack_hash_mismatch");
      return true;
    },
  );

  const unsafe = { ...makeContextPack(), raw_transcript: "unrestricted customer transcript" };
  await assert.rejects(() => store.put(unsafe), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_privacy_violation");
    return true;
  });

  const unsafeImage = structuredClone(makeContextPack()) as any;
  unsafeImage.body.raw_image_base64 = "data:image/jpeg;base64,/9j/2Q==";
  await assert.rejects(() => store.put(unsafeImage), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_privacy_violation");
    return true;
  });
});

test("approved context packs require a Gateway-minted binding over the exact immutable body", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);

  const unsigned = structuredClone(makeContextPack({ context_pack_id: "pack-approved-by-gateway" })) as any;
  delete unsigned.approval;
  await assert.rejects(() => store.put(unsigned), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_approval_invalid");
    return true;
  });

  const approved = await store.approve(unsigned);
  assert.equal(approved.created, true);
  assert.equal(approved.contextPack.approval?.content_sha256, unsigned.content_sha256);
  assert.equal(approved.contextPack.approval?.journal_head_sha256, unsigned.body.journal_head_sha256);
  assert.deepEqual(await store.get("pack-approved-by-gateway"), approved.contextPack);

  const rewritten = structuredClone(approved.contextPack) as any;
  rewritten.body.organization = "A rewritten organization";
  rewritten.content_sha256 = computeContextPackHash(rewritten.body);
  await assert.rejects(() => store.put(rewritten), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_approval_invalid");
    return true;
  });

  const changedJournalHead = structuredClone(approved.contextPack) as any;
  changedJournalHead.body.journal_head_sha256 = "f".repeat(64);
  changedJournalHead.content_sha256 = computeContextPackHash(changedJournalHead.body);
  await assert.rejects(() => store.put(changedJournalHead), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_approval_invalid");
    return true;
  });

  const rotatedKeyStore = new ContextPackStore(directory, {
    signingKey: {
      keyID: "scout-test-v2",
      privateKey: Buffer.alloc(32, 19).toString("base64url"),
    },
    verificationKeys: {},
  });
  await assert.rejects(() => rotatedKeyStore.get("pack-approved-by-gateway"), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_approval_invalid");
    return true;
  });
});

test("ContextPackStore closes epistemic enums and validates graph and claim references", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);

  const invalidMode = structuredClone(makeContextPack()) as any;
  invalidMode.body.entities[0].trust = "proposed";
  invalidMode.content_sha256 = computeContextPackHash(invalidMode.body);
  await assert.rejects(() => store.put(invalidMode), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "invalid_context_pack");
    return true;
  });

  const missingRelationshipTrust = structuredClone(makeContextPack()) as any;
  delete missingRelationshipTrust.body.relationships[0].epistemic_mode;
  missingRelationshipTrust.content_sha256 = computeContextPackHash(missingRelationshipTrust.body);
  await assert.rejects(() => store.put(missingRelationshipTrust), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "invalid_context_pack");
    return true;
  });

  const unrelatedRelationshipEvidence = structuredClone(makeContextPack()) as any;
  unrelatedRelationshipEvidence.body.relationships[0].source_evidence_ids = ["evidence-source-unrelated"];
  unrelatedRelationshipEvidence.content_sha256 = computeContextPackHash(unrelatedRelationshipEvidence.body);
  await assert.rejects(() => store.put(unrelatedRelationshipEvidence), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "invalid_context_pack_integrity");
    return true;
  });

  const unknownClaim = structuredClone(makeContextPack()) as any;
  unknownClaim.body.quick_wins[0].supporting_claim_ids = ["claim-unknown"];
  unknownClaim.content_sha256 = computeContextPackHash(unknownClaim.body);
  await assert.rejects(() => store.put(unknownClaim), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "invalid_context_pack_integrity");
    return true;
  });

  const staleGraphDigest = structuredClone(makeContextPack()) as any;
  staleGraphDigest.body.graph_state_sha256 = "f".repeat(64);
  staleGraphDigest.content_sha256 = computeContextPackHash(staleGraphDigest.body);
  await assert.rejects(() => store.put(staleGraphDigest), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_graph_hash_mismatch");
    return true;
  });

  const unvalidatedBuildGuidance = structuredClone(makeContextPack()) as any;
  unvalidatedBuildGuidance.body.claims[0].needs_validation = true;
  unvalidatedBuildGuidance.content_sha256 = computeContextPackHash(unvalidatedBuildGuidance.body);
  await assert.rejects(() => store.put(unvalidatedBuildGuidance), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "invalid_context_pack_integrity");
    return true;
  });
});

test("approved context packs reject records outside the selected POC closure", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  const variants: readonly ((pack: any) => void)[] = [
    (pack) => {
      pack.body.claims.push({
        id: "claim-unrelated",
        title: "Unrelated claim",
        detail: "This claim was not approved for the selected POC.",
        epistemic_mode: "inferred",
        confidence_basis_points: 9_000,
        needs_validation: true,
        evidence: {
          id: "evidence-claim-unrelated",
          source_evidence_ids: ["evidence-source-unrelated"],
          speaker: "Customer",
          timestamp: "00:10",
          excerpt: "Unrelated evidence",
        },
      });
    },
    (pack) => {
      pack.body.entities.push({
        id: "entity-unrelated",
        kind: "system",
        title: "Unrelated system",
        detail: "Outside the selected POC.",
        trust: "inferred",
        confidence_basis_points: 9_000,
      });
    },
    (pack) => {
      pack.body.open_questions.push({
        id: "question-unrelated",
        priority: "explore",
        topic: "Unrelated",
        question: "This must remain local.",
        rationale: "Outside the selected POC.",
      });
    },
    (pack) => {
      pack.body.quick_wins.push({
        ...pack.body.quick_wins[0],
        id: "win-unrelated",
        title: "Unrelated opportunity",
      });
    },
  ];

  for (const [index, mutate] of variants.entries()) {
    const overbroad = structuredClone(makeContextPack({
      context_pack_id: `pack-overbroad-${index}`,
    })) as any;
    mutate(overbroad);
    overbroad.body.graph_state_sha256 = computeContextPackHash({
      entities: overbroad.body.entities,
      relationships: overbroad.body.relationships,
    });
    overbroad.content_sha256 = computeContextPackHash(overbroad.body);
    await assert.rejects(() => store.put(overbroad), (error: unknown) => {
      assert.ok(error instanceof PublicError);
      assert.equal(error.code, "invalid_context_pack_integrity");
      return true;
    });
  }
});

test("unapproved context packs are stored but hidden from public and MCP-default reads", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  const unapproved = makeContextPack({ context_pack_id: "pack-draft", approved_at: undefined });

  assert.equal((await store.put(unapproved)).created, true);
  assert.equal((await store.list()).length, 0);
  assert.equal((await store.list({ approvedOnly: false })).length, 1);
  assert.equal((await store.get("pack-draft", { approvedOnly: false })).body.approved_at, undefined);
  await assert.rejects(() => store.get("pack-draft"), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "context_pack_not_found");
    return true;
  });
});

test("context pack body canonicalization is sorted and insertion-order independent", () => {
  const first = { alpha: 1, nested: { beta: true, gamma: "value/é" } };
  const second = { nested: { gamma: "value/é", beta: true }, alpha: 1 };
  assert.equal(canonicalJSONString(first), "{\"alpha\":1,\"nested\":{\"beta\":true,\"gamma\":\"value/é\"}}");
  assert.equal(computeContextPackHash(first), computeContextPackHash(second));
  // Golden digest produced by CryptoKit over Scout's JSONEncoder output.
  assert.equal(computeContextPackHash(first), "69d27833f30ea61ee1a0d351cdcef528805ab865554b2975d9c140a449789f38");
});

test("approved context-pack pagination is bounded and session head is revision-aware", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  const revisionOne = makeContextPack({
    context_pack_id: "pack-revision-1",
    revision: 1,
    generated_at: "2026-07-16T12:00:00Z",
    approved_at: "2026-07-16T12:01:00Z",
  });
  await store.put(revisionOne);
  await store.put(makeContextPack({
    context_pack_id: "pack-revision-2",
    revision: 2,
    generated_at: "2026-07-16T13:00:00Z",
    approved_at: "2026-07-16T13:01:00Z",
    previous_context_pack_sha256: revisionOne.content_sha256,
  }));

  const first = await store.listPage({ sessionId: "session-001", limit: 1 });
  assert.equal(first.context_packs[0]?.context_pack_id, "pack-revision-2");
  assert.ok(first.next_cursor);
  const second = await store.listPage({ sessionId: "session-001", limit: 1, cursor: first.next_cursor ?? undefined });
  assert.equal(second.context_packs[0]?.context_pack_id, "pack-revision-1");
  assert.equal(second.next_cursor, null);

  const head = await store.head("session-001");
  assert.equal(head?.context_pack_id, "pack-revision-2");
  assert.equal(head?.revision, 2);

  await writeFile(join(directory, "pack-revision-2.json"), "{}\n", "utf8");
  await assert.rejects(() => store.head("session-001"), (error: unknown) => {
    assert.ok(error instanceof PublicError);
    assert.equal(error.code, "invalid_context_pack");
    return true;
  });
});

test("session revisions are compare-and-swap monotonic under concurrent writes", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "scout-context-packs-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ContextPackStore(directory, TEST_APPROVAL_OPTIONS);
  const revisionOne = makeContextPack({ context_pack_id: "pack-cas-1", revision: 1 });
  await store.put(revisionOne);

  await assert.rejects(
    () => store.put(makeContextPack({
      context_pack_id: "pack-cas-wrong-head",
      revision: 2,
      previous_context_pack_sha256: "f".repeat(64),
    })),
    (error: unknown) => {
      assert.ok(error instanceof PublicError);
      assert.equal(error.code, "context_pack_head_conflict");
      return true;
    },
  );

  await assert.rejects(
    () => store.put(makeContextPack({
      context_pack_id: "pack-cas-skipped",
      revision: 3,
      previous_context_pack_sha256: revisionOne.content_sha256,
    })),
    (error: unknown) => {
      assert.ok(error instanceof PublicError);
      assert.equal(error.code, "context_pack_revision_conflict");
      return true;
    },
  );

  const competing = await Promise.allSettled([
    store.put(makeContextPack({
      context_pack_id: "pack-cas-2a",
      revision: 2,
      previous_context_pack_sha256: revisionOne.content_sha256,
    })),
    store.put(makeContextPack({
      context_pack_id: "pack-cas-2b",
      revision: 2,
      previous_context_pack_sha256: revisionOne.content_sha256,
    })),
  ]);
  assert.equal(competing.filter((result) => result.status === "fulfilled").length, 1);
  const rejected = competing.find((result) => result.status === "rejected");
  assert.ok(rejected?.status === "rejected");
  assert.ok(rejected.reason instanceof PublicError);
  assert.equal(rejected.reason.code, "context_pack_revision_conflict");

  const head = await store.head("session-001");
  assert.equal(head?.revision, 2);
});
