import XCTest
@testable import Scout

final class DiscoveryGapEngineTests: XCTestCase {
    func testDerivesDeterministicBoundedQuestionsWithoutChangingSnapshot() {
        let snapshot = DiscoveryGapSnapshot(
            entities: fixtures,
            relationships: [],
            claims: [inferredClaim],
            existingQuestions: []
        )
        let originalEntities = snapshot.entities
        let originalClaims = snapshot.claims
        let engine = DiscoveryGapEngine()

        let first = engine.derive(from: snapshot, maximumCount: 100)
        let reordered = engine.derive(
            from: DiscoveryGapSnapshot(
                entities: fixtures.reversed(),
                relationships: [],
                claims: [inferredClaim],
                existingQuestions: []
            ),
            maximumCount: 100
        )

        XCTAssertLessThanOrEqual(first.count, DiscoveryGapEngine.hardMaximumQuestionCount)
        XCTAssertEqual(first, reordered)
        XCTAssertEqual(snapshot.entities, originalEntities)
        XCTAssertEqual(snapshot.claims, originalClaims)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
        XCTAssertTrue(first.allSatisfy { !$0.isAsked })
        XCTAssertEqual(first.first?.priority, .critical)
    }

    func testSurfacesGuardrailOwnershipWorkflowAndInferenceGaps() {
        let questions = DiscoveryGapEngine().derive(
            from: DiscoveryGapSnapshot(
                entities: fixtures,
                relationships: [],
                claims: [inferredClaim]
            ),
            maximumCount: 8
        )

        let topics = Set(questions.map(\.topic))
        XCTAssertTrue(topics.contains("Data guardrail"))
        XCTAssertTrue(topics.contains("Ownership"))
        XCTAssertTrue(topics.contains("Workflow"))
        XCTAssertTrue(topics.contains("Evidence validation"))
    }

    func testExistingQuestionIsNotSuggestedAgain() throws {
        let engine = DiscoveryGapEngine()
        let initial = engine.derive(
            from: DiscoveryGapSnapshot(entities: fixtures, relationships: [], claims: [inferredClaim]),
            maximumCount: 8
        )
        let existing = try XCTUnwrap(initial.first)
        let next = engine.derive(
            from: DiscoveryGapSnapshot(
                entities: fixtures,
                relationships: [],
                claims: [inferredClaim],
                existingQuestions: [existing]
            ),
            maximumCount: 8
        )

        XCTAssertFalse(next.contains(where: { $0.id == existing.id || $0.text == existing.text }))
    }

    func testZeroMaximumReturnsNoQuestions() {
        let questions = DiscoveryGapEngine().derive(
            from: DiscoveryGapSnapshot(entities: [], relationships: [], claims: []),
            maximumCount: 0
        )
        XCTAssertTrue(questions.isEmpty)
    }

    @MainActor
    func testWorkspaceOverloadIsReadOnly() {
        let workspace = ScoutWorkspace()
        let beforeEntities = workspace.entities
        let beforeClaims = workspace.claims
        let beforeQuestions = workspace.questions

        _ = DiscoveryGapEngine().derive(from: workspace)

        XCTAssertEqual(workspace.entities, beforeEntities)
        XCTAssertEqual(workspace.claims, beforeClaims)
        XCTAssertEqual(workspace.questions, beforeQuestions)
    }

    private var fixtures: [GraphEntity] {
        [
            GraphEntity(
                id: "system-crm",
                title: "CRM",
                subtitle: "System",
                kind: .system,
                x: 0.2,
                y: 0.3,
                provenance: .heard,
                confidence: 0.98
            ),
            GraphEntity(
                id: "data-customer",
                title: "Customer data",
                subtitle: "Data",
                kind: .data,
                x: 0.4,
                y: 0.3,
                provenance: .heard,
                confidence: 0.95
            ),
            GraphEntity(
                id: "goal-speed",
                title: "Faster resolution",
                subtitle: "Business goal",
                kind: .goal,
                x: 0.7,
                y: 0.3,
                provenance: .heard,
                confidence: 0.92
            ),
        ]
    }

    private var inferredClaim: TrustClaim {
        TrustClaim(
            id: "claim-inferred",
            title: "CRM is the system of record",
            detail: "The current model infers ownership of the customer record.",
            provenance: .inferred,
            confidence: 0.72,
            evidenceQuote: "We usually check the CRM first.",
            speakerName: "Customer",
            timestamp: "02:10",
            relatedEntityID: "system-crm",
            needsValidation: true
        )
    }
}
