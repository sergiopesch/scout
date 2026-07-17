import XCTest
@testable import Scout

final class QuickWinEngineTests: XCTestCase {
    func testRanksEvidenceLinkedBatchOpportunityDeterministically() {
        let snapshot = QuickWinSnapshot(
            entities: [
                entity("system-crm", "CRM", .system),
                entity("system-erp", "ERP", .system),
                entity("process-exception", "Exception handling", .process),
                entity("data-export", "Nightly CSV", .data),
            ],
            relationships: [
                GraphRelationship(
                    id: "relationship-export",
                    sourceID: "system-crm",
                    targetID: "data-export",
                    label: "exports",
                    confidence: 0.95,
                    isFriction: true
                ),
            ],
            claims: [claim]
        )

        let first = QuickWinEngine().rank(snapshot)
        let second = QuickWinEngine().rank(snapshot)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.title, "Batch handoff sentinel")
        XCTAssertEqual(first.first?.supportingClaimIDs, [claim.id])
        XCTAssertGreaterThan(first.first?.evidenceCount ?? 0, 0)
        XCTAssertLessThanOrEqual(first.count, QuickWinEngine.maximumCount)
    }

    func testProducesNoOpportunityWithoutEvidenceLinkedClaim() {
        let snapshot = QuickWinSnapshot(
            entities: [entity("data-export", "Nightly CSV", .data)],
            relationships: [],
            claims: []
        )
        XCTAssertTrue(QuickWinEngine().rank(snapshot).isEmpty)
    }

    private var claim: TrustClaim {
        TrustClaim(
            id: "claim-nightly",
            title: "Inventory reconciliation is batch-only",
            detail: "CRM exports a nightly CSV to the ERP.",
            provenance: .heard,
            confidence: 0.97,
            evidenceQuote: "The systems reconcile through a nightly CSV export.",
            speakerName: "Customer",
            timestamp: "00:10",
            relatedEntityID: "data-export",
            needsValidation: false
        )
    }

    private func entity(_ id: String, _ title: String, _ kind: GraphEntityKind) -> GraphEntity {
        GraphEntity(
            id: id,
            title: title,
            subtitle: kind.rawValue,
            kind: kind,
            x: 0.5,
            y: 0.5,
            provenance: .heard,
            confidence: 0.95
        )
    }
}
