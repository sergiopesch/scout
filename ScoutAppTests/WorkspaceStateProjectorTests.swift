@testable import ScoutCore
import XCTest
@testable import Scout

final class WorkspaceStateProjectorTests: XCTestCase {
    func testProjectionRebuildsCockpitFromCanonicalReducedState() throws {
        let state = try ScoutFixtures.sampleState()

        let projection = try XCTUnwrap(WorkspaceStateProjector().project(state))

        XCTAssertEqual(projection.sessionID, ScoutFixtures.sessionID.rawValue)
        XCTAssertEqual(projection.captureState.rawValue, CaptureState.paused.rawValue)
        XCTAssertEqual(projection.transcript.map(\.id), [ScoutFixtures.utteranceID.rawValue])
        XCTAssertEqual(projection.transcript.first?.secondsFromStart, 0)
        XCTAssertEqual(projection.entities.map(\.id).sorted(), [
            ScoutFixtures.customerDataEntityID.rawValue,
            ScoutFixtures.salesforceEntityID.rawValue,
        ])
        XCTAssertEqual(projection.relationships.map(\.id), [ScoutFixtures.relationshipID.rawValue])
        XCTAssertEqual(projection.relationships.first?.provenance, .heard)
        XCTAssertEqual(projection.relationships.first?.needsValidation, true)
        XCTAssertEqual(
            projection.relationships.first?.supportingClaimIDs,
            [ScoutFixtures.claimID.rawValue]
        )
        XCTAssertEqual(
            projection.relationships.first?.evidenceIDs,
            [ScoutFixtures.evidenceID.rawValue]
        )
        XCTAssertEqual(projection.claims.map(\.id), [ScoutFixtures.claimID.rawValue])
        XCTAssertEqual(projection.claims.first?.reviewStatus, .proposed)
        XCTAssertEqual(projection.claims.first?.needsValidation, true)
        XCTAssertEqual(
            projection.claimEvidenceIDsByID[ScoutFixtures.claimID.rawValue],
            [ScoutFixtures.evidenceID.rawValue]
        )
        XCTAssertEqual(
            projection.projectionEvidenceByID[ScoutFixtures.relationshipID.rawValue]?.evidenceIDs,
            [ScoutFixtures.evidenceID.rawValue]
        )
    }

    func testEndedSessionReplayProjectsComplete() throws {
        let projection = try XCTUnwrap(WorkspaceStateProjector().project(
            try ScoutFixtures.sampleState(includeSessionEnd: true)
        ))

        XCTAssertEqual(projection.captureState.rawValue, CaptureState.complete.rawValue)
        XCTAssertEqual(projection.elapsedSeconds, 60)
    }

    func testDeterministicallyValidatedProposedClaimStillRequiresReview() throws {
        var state = try ScoutFixtures.sampleState()
        let claimID = try ClaimID(validating: "claim-deterministically-validated")
        let validatedTrust = TrustAssessment(
            origin: .confirmed,
            confidence: try Confidence(basisPoints: 9_800),
            validationStatus: .validated,
            rationale: try NonEmptyString(validating: "Validated by a deterministic trusted source.")
        )
        var builder = try EventChainBuilder(
            sessionID: state.sessionID,
            nextSequence: XCTUnwrap(state.lastSequence).successor(),
            previousHash: state.lastEventHash
        )
        let event = try builder.seal(
            id: try EventID(validating: "event-deterministically-validated-claim"),
            occurredAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_010_000),
            recordedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_010_001),
            command: .deterministicProjection(
                component: try NonEmptyString(validating: "test-projection"),
                operation: .proposeClaim(ScoutCore.Claim(
                    id: claimID,
                    subject: .entity(ScoutFixtures.customerDataEntityID),
                    predicate: .storesDataIn,
                    object: .entity(ScoutFixtures.salesforceEntityID),
                    assertedBy: ScoutFixtures.speakerID,
                    evidenceIDs: [ScoutFixtures.evidenceID],
                    trust: validatedTrust
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: event)

        let projection = try XCTUnwrap(WorkspaceStateProjector().project(state))
        let claim = try XCTUnwrap(projection.claims.first { $0.id == claimID.rawValue })

        XCTAssertEqual(claim.provenance, .validated)
        XCTAssertEqual(claim.reviewStatus, .proposed)
        XCTAssertTrue(claim.needsValidation)
    }

    @MainActor
    func testLegacyAcceptedClaimRemainsExplicitlyUnattestedAndNotBuildReady() throws {
        var state = try ScoutFixtures.sampleState()
        let original = try XCTUnwrap(state.claims[ScoutFixtures.claimID])
        let trust = TrustAssessment(
            origin: .confirmed,
            confidence: try Confidence(basisPoints: 10_000),
            validationStatus: .validated
        )
        state.claims[original.id] = ScoutCore.Claim(
            id: original.id,
            subject: original.subject,
            predicate: original.predicate,
            object: original.object,
            assertedBy: original.assertedBy,
            evidenceIDs: original.evidenceIDs,
            trust: trust,
            status: .accepted,
            supersedes: original.supersedes
        )
        state.claimReviewAttestations[original.id] = .legacyUnattested(
            schemaVersion: EventSchemaVersion(major: 1, minor: 3)
        )

        let projection = try XCTUnwrap(WorkspaceStateProjector().project(state))
        let claim = try XCTUnwrap(projection.claims.first { $0.id == original.id.rawValue })

        XCTAssertEqual(claim.provenance, .proposed)
        XCTAssertEqual(claim.reviewStatus, .legacyAccepted)
        XCTAssertTrue(claim.needsValidation)
        XCTAssertTrue(claim.detail.contains("not device-owner authenticated"))

        let workspace = ScoutWorkspace(completed: false)
        workspace.claims = [claim]
        workspace.quickWins = [QuickWin(
            id: "legacy-review-poc",
            title: "Legacy review POC",
            detail: "Must remain blocked.",
            impact: 5,
            effort: 1,
            readiness: 5,
            timeToValue: "1 week",
            evidenceCount: 1,
            supportingClaimIDs: [claim.id]
        )]
        workspace.selectedPOCQuickWinID = "legacy-review-poc"
        XCTAssertFalse(workspace.selectedPOCHasBuildReadyEvidence)
    }
}
