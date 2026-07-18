import Foundation
@testable import ScoutCore
import XCTest
@testable import Scout

@MainActor
final class ClaimReviewCoordinatorTests: XCTestCase {
    func testProposedAcceptanceAppliesOnlyAlreadyCommittedCanonicalState() async throws {
        let proposedState = try ScoutFixtures.sampleState()
        let canonicalState = try acceptedCanonicalState(from: proposedState)
        let workspace = ScoutWorkspace(completed: false)
        workspace.applyReplayProjection(try XCTUnwrap(
            WorkspaceStateProjector().project(proposedState)
        ))
        let receipt = LiveEventJournal.ClaimReviewReceipt(
            claimID: ScoutFixtures.claimID,
            status: .accepted,
            committedReviewBoundary: AppendReceipt(
                event: try XCTUnwrap(ScoutFixtures.sampleEvents().last)
            ),
            canonicalState: canonicalState
        )
        let calls = ReviewCallRecorder()
        let coordinator = ClaimReviewCoordinator(
            workspace: workspace,
            prepareReview: { sessionID, claimID, status in
                await calls.recordPreparation(
                    sessionID: sessionID,
                    claimID: claimID,
                    status: status
                )
                return .alreadyCommitted(receipt)
            },
            recordReview: { _, _ in
                throw ReviewStubError.unexpectedRecord
            },
            authorizeReview: { _ in
                throw ReviewStubError.unexpectedAuthorization
            }
        )
        coordinator.install()

        workspace.acceptClaim(ScoutFixtures.claimID.rawValue)
        workspace.acceptClaim(ScoutFixtures.claimID.rawValue)

        await waitUntil {
            workspace.claims.first?.reviewStatus == .accepted
        }
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.preparations.count, 1)
        XCTAssertEqual(snapshot.preparations.first?.sessionID, ScoutFixtures.sessionID.rawValue)
        XCTAssertEqual(snapshot.preparations.first?.claimID, ScoutFixtures.claimID.rawValue)
        XCTAssertEqual(snapshot.preparations.first?.status, .accepted)
        XCTAssertEqual(snapshot.authorizationIntents.count, 0)
        XCTAssertFalse(workspace.reviewingClaimIDs.contains(ScoutFixtures.claimID.rawValue))
        XCTAssertNil(workspace.claimReviewError)
    }

    func testLegacyAcceptanceRequestsReauthenticationWithoutLocalMutationOnFailure() async throws {
        let legacyState = try legacyAcceptedState()
        let workspace = ScoutWorkspace(completed: false)
        workspace.applyReplayProjection(try XCTUnwrap(
            WorkspaceStateProjector().project(legacyState)
        ))
        let intent = try LocalReviewIntent.preparing(
            eventID: try EventID(validating: "event-app-legacy-claim-reattestation"),
            operation: .attestLegacyReview(LocalReviewAttested(
                target: .claim(ScoutFixtures.claimID)
            )),
            in: legacyState
        )
        let calls = ReviewCallRecorder()
        let coordinator = ClaimReviewCoordinator(
            workspace: workspace,
            prepareReview: { sessionID, claimID, status in
                await calls.recordPreparation(
                    sessionID: sessionID,
                    claimID: claimID,
                    status: status
                )
                return .authorizationRequired(intent)
            },
            recordReview: { _, _ in
                throw ReviewStubError.unexpectedRecord
            },
            authorizeReview: { receivedIntent in
                await calls.recordAuthorization(receivedIntent)
                throw ReviewStubError.authenticationCancelled
            }
        )
        coordinator.install()

        workspace.reattestClaimAcceptance(ScoutFixtures.claimID.rawValue)

        await waitUntil { workspace.claimReviewError != nil }
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.preparations.count, 1)
        XCTAssertEqual(snapshot.preparations.first?.status, .accepted)
        XCTAssertEqual(snapshot.authorizationIntents, [intent])
        XCTAssertEqual(workspace.claims.first?.reviewStatus, .legacyAccepted)
        XCTAssertFalse(workspace.reviewingClaimIDs.contains(ScoutFixtures.claimID.rawValue))
        XCTAssertTrue(
            workspace.claimReviewError?.message.contains("Authentication was cancelled") == true
        )
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for claim review work.", file: file, line: line)
    }

    private func acceptedCanonicalState(from state: ScoutState) throws -> ScoutState {
        var state = state
        let original = try XCTUnwrap(state.claims[ScoutFixtures.claimID])
        state.claims[original.id] = acceptedClaim(from: original)
        state.claimReviewAttestations[original.id] = .deviceOwnerAuthenticated(
            try authorizationRecord(for: original.id)
        )
        return state
    }

    private func legacyAcceptedState() throws -> ScoutState {
        var state = try ScoutFixtures.sampleState()
        let original = try XCTUnwrap(state.claims[ScoutFixtures.claimID])
        state.claims[original.id] = acceptedClaim(from: original)
        state.claimReviewAttestations[original.id] = .legacyUnattested(
            schemaVersion: EventSchemaVersion(major: 1, minor: 3)
        )
        state.claimReviewEvents[original.id] = try XCTUnwrap(
            ScoutFixtures.sampleEvents().last?.id
        )
        return state
    }

    private func acceptedClaim(from claim: ScoutCore.Claim) -> ScoutCore.Claim {
        ScoutCore.Claim(
            id: claim.id,
            subject: claim.subject,
            predicate: claim.predicate,
            object: claim.object,
            assertedBy: claim.assertedBy,
            evidenceIDs: claim.evidenceIDs,
            trust: TrustAssessment(
                origin: .confirmed,
                confidence: claim.trust.confidence,
                validationStatus: .validated,
                rationale: claim.trust.rationale
            ),
            status: .accepted,
            supersedes: claim.supersedes
        )
    }

    private func authorizationRecord(for claimID: ClaimID) throws
        -> LocalReviewAuthorizationRecord
    {
        let fixture = AuthorizationRecordFixture(
            id: try ReviewAuthorizationID(validating: "review-authorization-app-test"),
            assurance: .deviceOwnerAuthentication,
            reviewer: .localDeviceOwner,
            sessionID: ScoutFixtures.sessionID,
            eventID: try EventID(validating: "event-app-authenticated-claim-review"),
            target: .claim(claimID),
            targetEventID: try EventID(validating: "event-app-claim-proposal"),
            targetStateHash: .hash(Data("claim-state".utf8)),
            operationHash: .hash(Data("claim-review-operation".utf8)),
            authenticatedAt: ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_100_000)
        )
        return try JSONDecoder().decode(
            LocalReviewAuthorizationRecord.self,
            from: JSONEncoder().encode(fixture)
        )
    }
}

private actor ReviewCallRecorder {
    struct Preparation: Sendable {
        let sessionID: String
        let claimID: String
        let status: ClaimStatus
    }

    struct Snapshot: Sendable {
        let preparations: [Preparation]
        let authorizationIntents: [LocalReviewIntent]
    }

    private var preparations: [Preparation] = []
    private var authorizationIntents: [LocalReviewIntent] = []

    func recordPreparation(sessionID: String, claimID: String, status: ClaimStatus) {
        preparations.append(Preparation(
            sessionID: sessionID,
            claimID: claimID,
            status: status
        ))
    }

    func recordAuthorization(_ intent: LocalReviewIntent) {
        authorizationIntents.append(intent)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            preparations: preparations,
            authorizationIntents: authorizationIntents
        )
    }
}

private struct AuthorizationRecordFixture: Encodable {
    let id: ReviewAuthorizationID
    let assurance: LocalReviewAssurance
    let reviewer: AuthenticatedReviewer
    let sessionID: SessionID
    let eventID: EventID
    let target: LocalReviewTarget
    let targetEventID: EventID
    let targetStateHash: SHA256Digest
    let operationHash: SHA256Digest
    let authenticatedAt: ScoutTimestamp
}

private enum ReviewStubError: LocalizedError {
    case authenticationCancelled
    case unexpectedAuthorization
    case unexpectedRecord

    var errorDescription: String? {
        switch self {
        case .authenticationCancelled: "Authentication was cancelled."
        case .unexpectedAuthorization: "Authorization should not have been requested."
        case .unexpectedRecord: "A review should not have been recorded."
        }
    }
}
