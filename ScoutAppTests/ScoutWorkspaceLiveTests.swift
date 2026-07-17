import XCTest
@testable import Scout

@MainActor
final class ScoutWorkspaceLiveTests: XCTestCase {
    func testBeginningLiveSessionClearsTourDataOnlyOnce() {
        let workspace = ScoutWorkspace()
        XCTAssertFalse(workspace.transcript.isEmpty)
        XCTAssertFalse(workspace.entities.isEmpty)

        workspace.beginLiveSessionIfNeeded()

        XCTAssertNotEqual(workspace.activeEvidenceSessionID, workspace.selectedSessionID)
        XCTAssertTrue(workspace.transcript.isEmpty)
        XCTAssertTrue(workspace.entities.isEmpty)
        XCTAssertTrue(workspace.claims.isEmpty)
        XCTAssertEqual(workspace.elapsedSeconds, 0)

        let liveSessionID = workspace.activeEvidenceSessionID
        workspace.entities = [entity(title: "Live CRM", confidence: 0.8)]
        workspace.beginLiveSessionIfNeeded()
        XCTAssertEqual(workspace.activeEvidenceSessionID, liveSessionID)
        XCTAssertEqual(workspace.entities.map(\.title), ["Live CRM"])
    }

    func testApplyingProjectionIsIdempotentAndRetainsGrounding() {
        let workspace = ScoutWorkspace()
        workspace.beginLiveSessionIfNeeded()
        let evidence = ProjectionEvidenceLink(
            projectionID: "entity-crm",
            projectedClaimIDs: ["claim-crm"],
            clientReferences: ["model-1"],
            evidenceUtteranceIDs: ["utterance-1"],
            evidenceIDs: ["evidence-1"]
        )
        let modelCall = ClaimModelCall(
            responseID: "response-1",
            model: "gpt-test",
            promptVersion: "claims-v1",
            schemaVersion: "1.0",
            inputEventBoundary: 4,
            outputSHA256: String(repeating: "a", count: 64)
        )
        let provenance = ClaimProjectionProvenance(
            projectedClaimID: "claim-crm",
            clientReferences: ["model-1"],
            evidenceUtteranceIDs: ["utterance-1"],
            evidenceIDs: ["evidence-1"],
            rationales: ["Directly stated."],
            modelCall: modelCall
        )
        let initial = ClaimProposalProjection(
            modelCall: modelCall,
            entities: [entity(title: "CRM", confidence: 0.8)],
            relationships: [],
            claims: [claim(confidence: 0.8)],
            entityEvidence: [evidence],
            relationshipEvidence: [],
            claimProvenance: [provenance]
        )
        let strengthened = ClaimProposalProjection(
            modelCall: modelCall,
            entities: [entity(title: "CRM", confidence: 0.97)],
            relationships: [],
            claims: [claim(confidence: 0.97)],
            entityEvidence: [evidence],
            relationshipEvidence: [],
            claimProvenance: [provenance]
        )

        workspace.apply(initial)
        workspace.apply(strengthened)

        XCTAssertEqual(workspace.entities.count, 1)
        XCTAssertEqual(workspace.entities.first?.confidence, 0.97)
        XCTAssertEqual(workspace.claims.count, 1)
        XCTAssertEqual(workspace.projectionEvidenceByID["entity-crm"]?.evidenceIDs, ["evidence-1"])
        XCTAssertEqual(workspace.claimProvenanceByID["claim-crm"]?.modelCall.responseID, "response-1")
    }

    private func entity(title: String, confidence: Double) -> GraphEntity {
        GraphEntity(
            id: "entity-crm",
            title: title,
            subtitle: "System",
            kind: .system,
            x: 0.5,
            y: 0.5,
            provenance: .heard,
            confidence: confidence
        )
    }

    private func claim(confidence: Double) -> TrustClaim {
        TrustClaim(
            id: "claim-crm",
            title: "CRM stores customer data",
            detail: "Directly stated.",
            provenance: .heard,
            confidence: confidence,
            evidenceQuote: "Customer data lives in the CRM.",
            speakerName: "Customer",
            timestamp: "00:01",
            relatedEntityID: "entity-crm",
            needsValidation: false
        )
    }
}
