import CryptoKit
import Foundation
import XCTest
@testable import Scout

@MainActor
final class ContextPackExporterTests: XCTestCase {
    func testExportUsesSnakeCaseAndContentHashMatchesBody() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace(completed: true)
        workspace.selectPOC("win-monitor")
        let pack = try exporter.makePack(
            from: workspace,
            approved: true,
            journalHeadSHA256: String(repeating: "a", count: 64),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try exporter.encode(pack)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try XCTUnwrap(object["body"] as? [String: Any])

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertNotNil(object["content_sha256"])
        XCTAssertNotNil(body["context_pack_id"])
        XCTAssertNotNil(body["graph_state_sha256"])
        XCTAssertNotNil(body["selected_poc"])
        XCTAssertNil(body["contextPackID"])
        XCTAssertEqual(pack.body.selectedPOC?.title, "Inventory feed sentinel")
        let relationship = try XCTUnwrap(pack.body.relationships.first)
        XCTAssertFalse(relationship.epistemicMode.isEmpty)
        XCTAssertFalse(relationship.supportingClaimIDs.isEmpty)
        XCTAssertFalse(relationship.sourceEvidenceIDs.isEmpty)

        let canonicalBody = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let expectedHash = SHA256.hash(data: canonicalBody)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(pack.contentSHA256, expectedHash)
    }

    func testContextPackExcludesRawAudioAndTranscript() throws {
        let exporter = ContextPackExporter()
        let pack = try exporter.makePack(from: ScoutWorkspace(completed: true), approved: false)

        XCTAssertFalse(pack.body.redactionManifest.containsRawAudio)
        XCTAssertFalse(pack.body.redactionManifest.containsRawTranscript)
        XCTAssertTrue(pack.body.redactionManifest.excludesPersonalDataByDefault)
        XCTAssertNil(pack.body.approvedAt)
    }

    func testDraftExplicitlyEncodesMissingPOCAsNull() throws {
        let exporter = ContextPackExporter()
        let pack = try exporter.makePack(from: ScoutWorkspace(), approved: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exporter.encode(pack)) as? [String: Any])
        let body = try XCTUnwrap(object["body"] as? [String: Any])

        XCTAssertTrue(body.keys.contains("selected_poc"))
        XCTAssertTrue(body["selected_poc"] is NSNull)
    }

    func testExportUsesDurableEvidenceIdentifierWhenProjectionProvenanceExists() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace()
        let claimID = try XCTUnwrap(workspace.claims.first?.id)
        workspace.claimProvenanceByID[claimID] = ClaimProjectionProvenance(
            projectedClaimID: claimID,
            clientReferences: ["proposal-1"],
            evidenceUtteranceIDs: ["utterance-durable"],
            evidenceIDs: ["evidence-durable"],
            rationales: ["Direct evidence."],
            modelCall: ClaimModelCall(
                responseID: "response-1",
                model: "gpt-test",
                promptVersion: "claims-v1",
                schemaVersion: "1.0",
                inputEventBoundary: 4,
                outputSHA256: String(repeating: "a", count: 64)
            )
        )

        let pack = try exporter.makePack(from: workspace, approved: false)

        XCTAssertEqual(pack.body.claims.first?.evidence.id, "evidence-link-\(claimID)")
        XCTAssertEqual(pack.body.claims.first?.evidence.sourceEvidenceIDs, ["evidence-durable"])
    }

    func testExplicitRevisionAndEvidenceExcerptAreBoundedDeterministically() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace()
        let longExcerpt = String(repeating: "é", count: 2_000)
        workspace.claims = [
            TrustClaim(
                id: "claim-bounded-excerpt",
                title: "Bounded evidence",
                detail: "The encrypted journal retains the complete source.",
                provenance: .heard,
                confidence: 0.9,
                evidenceQuote: longExcerpt,
                speakerName: "Customer",
                timestamp: "00:01",
                relatedEntityID: nil,
                needsValidation: false
            ),
        ]

        let first = try exporter.makePack(from: workspace, approved: false, revision: 42)
        let second = try exporter.makePack(from: workspace, approved: false, revision: 42)

        XCTAssertEqual(first.body.revision, 42)
        XCTAssertEqual(first.body.claims[0].evidence.excerpt.count, 1_200)
        XCTAssertTrue(first.body.claims[0].evidence.excerpt.hasSuffix("…"))
        XCTAssertEqual(
            first.body.claims[0].evidence.excerpt,
            second.body.claims[0].evidence.excerpt
        )
    }

    func testApprovedHandoffRequiresExplicitPOCWithOnlyResolvedFactualSupport() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace(completed: true)

        XCTAssertThrowsError(try exporter.makePack(from: workspace, approved: true)) { error in
            XCTAssertEqual(error as? ContextPackExportError, .handoffNotReady)
        }

        workspace.selectPOC("win-status")
        XCTAssertFalse(workspace.selectedPOCHasBuildReadyEvidence)
        XCTAssertThrowsError(try exporter.makePack(from: workspace, approved: true))

        workspace.selectPOC("win-monitor")
        XCTAssertTrue(workspace.selectedPOCHasBuildReadyEvidence)
        let pack = try exporter.makePack(
            from: workspace,
            approved: true,
            revision: 7,
            journalHeadSHA256: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(pack.body.revision, 7)
        XCTAssertEqual(pack.body.selectedPOC?.supportingClaimIDs, [
            "claim-failure",
            "claim-nightly",
            "claim-resolution",
        ])
        XCTAssertTrue(pack.body.claims
            .filter { pack.body.selectedPOC?.supportingClaimIDs.contains($0.id) == true }
            .allSatisfy { !$0.needsValidation })
        XCTAssertTrue(pack.body.relationships.allSatisfy {
            !$0.supportingClaimIDs.isEmpty && !$0.sourceEvidenceIDs.isEmpty
        })
    }

    func testApprovedHandoffExportsOnlySelectedPOCClosure() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace(completed: true)
        workspace.selectPOC("win-monitor")
        let selectedClaimIDs = Set(try XCTUnwrap(workspace.selectedPOCQuickWin).supportingClaimIDs)

        workspace.entities.append(
            GraphEntity(
                id: "entity-unrelated",
                title: "Unrelated system",
                subtitle: "Must remain in Scout",
                kind: .system,
                x: 0.5,
                y: 0.5,
                provenance: .inferred,
                confidence: 0.9
            )
        )
        workspace.claims.append(
            TrustClaim(
                id: "claim-unrelated",
                title: "Unrelated claim",
                detail: "This claim is outside the selected POC.",
                provenance: .inferred,
                confidence: 0.9,
                evidenceQuote: "Unrelated evidence",
                speakerName: "Customer",
                timestamp: "00:10",
                relatedEntityID: "entity-unrelated",
                needsValidation: true
            )
        )
        workspace.relationships.append(
            GraphRelationship(
                id: "relationship-unrelated",
                sourceID: "entity-unrelated",
                targetID: "entity-unrelated",
                label: "references",
                confidence: 0.9,
                isFriction: false,
                provenance: .inferred,
                needsValidation: true,
                supportingClaimIDs: ["claim-unrelated"],
                evidenceIDs: ["evidence-claim-unrelated"]
            )
        )
        workspace.questions.append(
            DiscoveryQuestion(
                id: "question-unrelated",
                priority: .explore,
                topic: "Unrelated",
                text: "This must stay local.",
                rationale: "Outside the selected POC.",
                isAsked: false
            )
        )
        workspace.quickWins.append(
            QuickWin(
                id: "win-unrelated",
                title: "Unrelated opportunity",
                detail: "Outside the selected POC.",
                impact: 5,
                effort: 1,
                readiness: 5,
                timeToValue: "1 day",
                evidenceCount: 1,
                supportingClaimIDs: ["claim-unrelated"]
            )
        )

        let pack = try exporter.makePack(
            from: workspace,
            approved: true,
            revision: 8,
            journalHeadSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(Set(pack.body.claims.map(\.id)), selectedClaimIDs)
        XCTAssertFalse(pack.body.entities.contains { $0.id == "entity-unrelated" })
        XCTAssertFalse(pack.body.relationships.contains { $0.id == "relationship-unrelated" })
        XCTAssertTrue(pack.body.openQuestions.isEmpty)
        XCTAssertEqual(pack.body.quickWins.map(\.id), ["win-monitor"])
    }

    func testStagedApprovalRemainsBoundToReviewedBytesWhenWorkspaceChanges() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace(completed: true)
        workspace.selectPOC("win-monitor")
        let staged = try exporter.stageApprovedPack(
            from: workspace,
            currentHead: ContextPackHead(
                contextPackID: "previous-pack",
                revision: 4,
                contentSHA256: String(repeating: "b", count: 64)
            ),
            journalHeadSHA256: String(repeating: "a", count: 64),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reviewedBytes = staged.encodedPack
        let reviewedDigest = staged.approvedScopeSHA256

        workspace.selectPOC("win-status")
        workspace.claims.removeAll()
        workspace.entities.removeAll()

        XCTAssertNoThrow(try exporter.validate(staged))
        XCTAssertEqual(staged.encodedPack, reviewedBytes)
        XCTAssertEqual(staged.approvedScopeSHA256, reviewedDigest)
        XCTAssertEqual(staged.pack.body.selectedPOC?.title, "Inventory feed sentinel")
        XCTAssertEqual(staged.pack.body.revision, 5)
        XCTAssertEqual(staged.pack.body.previousContextPackSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(staged.pack.body.journalHeadSHA256, String(repeating: "a", count: 64))
    }

    func testApprovedHandoffRequiresCanonicalJournalHead() throws {
        let exporter = ContextPackExporter()
        let workspace = ScoutWorkspace(completed: true)
        workspace.selectPOC("win-monitor")

        XCTAssertThrowsError(
            try exporter.makePack(from: workspace, approved: true, revision: 1)
        ) { error in
            XCTAssertEqual(error as? ContextPackExportError, .missingJournalHead)
        }
    }
}
