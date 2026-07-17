import ScoutCore
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

    func testEndedSessionProjectsCompleteAndAcceptedClaimProjectsValidated() throws {
        var events = try ScoutFixtures.sampleEvents()
        let last = try XCTUnwrap(events.last)
        var builder = EventChainBuilder(
            sessionID: ScoutFixtures.sessionID,
            nextSequence: try last.sequence.successor(),
            previousHash: last.integrityHash
        )
        let validatedTrust = TrustAssessment(
            origin: .confirmed,
            confidence: try Confidence(basisPoints: 9_800),
            validationStatus: .validated,
            rationale: try NonEmptyString(validating: "Confirmed with the customer.")
        )
        events.append(try builder.seal(
            id: try EventID(validating: "event-010-review"),
            occurredAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_010_000),
            recordedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_010_001),
            actor: .system(component: try NonEmptyString(validating: "test-review")),
            payload: .claimReviewed(.init(
                claimID: ScoutFixtures.claimID,
                status: .accepted,
                trust: validatedTrust
            ))
        ))
        events.append(try builder.seal(
            id: try EventID(validating: "event-011-end"),
            occurredAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_060_000),
            recordedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_060_001),
            actor: .system(component: try NonEmptyString(validating: "test-end")),
            payload: .sessionEnded(.init(
                endedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_060_000)
            ))
        ))

        let projection = try XCTUnwrap(
            WorkspaceStateProjector().project(try ScoutGraphReducer.replay(events))
        )

        XCTAssertEqual(projection.captureState.rawValue, CaptureState.complete.rawValue)
        XCTAssertEqual(projection.elapsedSeconds, 60)
        XCTAssertEqual(projection.claims.first?.provenance, .validated)
        XCTAssertEqual(projection.claims.first?.needsValidation, false)
    }
}
