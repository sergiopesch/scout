import XCTest
@testable import Scout

@MainActor
final class ScoutWorkspaceLiveTests: XCTestCase {
    func testBeginningLiveSessionClearsTourDataOnlyOnce() {
        let workspace = ScoutWorkspace()
        XCTAssertFalse(workspace.transcript.isEmpty)
        XCTAssertFalse(workspace.entities.isEmpty)

        workspace.beginLiveSessionIfNeeded()

        XCTAssertEqual(workspace.activeEvidenceSessionID, workspace.selectedSessionID)
        XCTAssertEqual(workspace.sessions.first?.id, workspace.selectedSessionID)
        XCTAssertFalse(workspace.isDemoWorkspace)
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

    func testNewDiscoverySessionCreatesAndSelectsOneCleanAlignedDraft() {
        let workspace = ScoutWorkspace(completed: true)
        XCTAssertTrue(workspace.isDemoWorkspace)

        workspace.beginNewDiscoverySession(
            id: "session-new-draft",
            organization: "Acme",
            title: "Operations discovery"
        )

        XCTAssertEqual(workspace.selectedSessionID, "session-new-draft")
        XCTAssertEqual(workspace.activeEvidenceSessionID, "session-new-draft")
        XCTAssertEqual(workspace.sessions.first?.id, "session-new-draft")
        XCTAssertEqual(workspace.sessions.first?.status, .draft)
        XCTAssertEqual(workspace.sessions.first?.organization, "Acme")
        XCTAssertFalse(workspace.isDemoWorkspace)
        XCTAssertEqual(workspace.captureState, .idle)
        XCTAssertTrue(workspace.transcript.isEmpty)
        XCTAssertTrue(workspace.entities.isEmpty)
        XCTAssertTrue(workspace.relationships.isEmpty)
        XCTAssertTrue(workspace.claims.isEmpty)
        XCTAssertTrue(workspace.projectionEvidenceByID.isEmpty)
        XCTAssertTrue(workspace.claimEvidenceIDsByID.isEmpty)

        workspace.beginNewDiscoverySession(
            id: "session-new-draft",
            organization: "Acme",
            title: "Operations discovery"
        )
        XCTAssertEqual(workspace.sessions.filter { $0.id == "session-new-draft" }.count, 1)
    }

    func testEvidenceCoverageRequiresImmutableProjectionEvidence() {
        let workspace = ScoutWorkspace()
        workspace.entities = [
            GraphEntity(
                id: "entity-grounded",
                title: "Grounded",
                subtitle: "System",
                kind: .system,
                x: 0.2,
                y: 0.5,
                provenance: .heard,
                confidence: 0.9
            ),
            GraphEntity(
                id: "entity-unlinked",
                title: "Unlinked",
                subtitle: "Process",
                kind: .process,
                x: 0.5,
                y: 0.5,
                provenance: .validated,
                confidence: 0.9
            ),
            GraphEntity(
                id: "entity-proposed",
                title: "Proposed",
                subtitle: "Action",
                kind: .action,
                x: 0.8,
                y: 0.5,
                provenance: .proposed,
                confidence: 0.9
            ),
        ]
        workspace.projectionEvidenceByID = [
            "entity-grounded": ProjectionEvidenceLink(
                projectionID: "entity-grounded",
                projectedClaimIDs: ["claim-grounded"],
                clientReferences: [],
                evidenceUtteranceIDs: ["utterance-grounded"],
                evidenceIDs: ["evidence-grounded"]
            ),
            "entity-unlinked": ProjectionEvidenceLink(
                projectionID: "entity-unlinked",
                projectedClaimIDs: [],
                clientReferences: [],
                evidenceUtteranceIDs: [],
                evidenceIDs: ["   "]
            ),
        ]

        XCTAssertEqual(workspace.evidenceCoverage, 1.0 / 3.0, accuracy: 0.000_001)
    }

    func testSelectedClaimCanonicalEvidenceFailsClosedAndNormalizesResolvedIDs() throws {
        let workspace = ScoutWorkspace()
        let claimID = try XCTUnwrap(workspace.selectedClaim?.id)

        XCTAssertTrue(workspace.selectedClaimCanonicalEvidenceIDs.isEmpty)

        workspace.claimEvidenceIDsByID[claimID] = [
            " ",
            "evidence-b",
            " evidence-a ",
            "evidence-b",
        ]

        XCTAssertEqual(
            workspace.selectedClaimCanonicalEvidenceIDs,
            ["evidence-a", "evidence-b"]
        )
    }

    func testClaimSelectionRemainsExactWhenOneEntityHasMultipleClaims() {
        let workspace = ScoutWorkspace(completed: true)

        workspace.selectClaim("claim-nightly")

        XCTAssertEqual(workspace.selectedEntityID, "data-csv")
        XCTAssertEqual(workspace.selectedClaimID, "claim-nightly")
        XCTAssertEqual(workspace.selectedClaim?.id, "claim-nightly")

        workspace.selectEntity("data-csv")

        XCTAssertEqual(workspace.selectedClaimID, "claim-failure")
        XCTAssertEqual(workspace.selectedClaim?.id, "claim-failure")
    }

    func testArchiveNavigationRequestsLiveStopWithoutChangingAuthoritativeState() {
        let workspace = ScoutWorkspace()
        workspace.captureState = .listening
        var stopRequestCount = 0
        workspace.liveCaptureStopRequest = { stopRequestCount += 1 }

        workspace.requestCaptureStopForArchiveNavigation()

        XCTAssertEqual(stopRequestCount, 1)
        XCTAssertEqual(workspace.captureState, .listening)
    }

    func testArchiveNavigationStopsDemoLocallyWithoutInvokingLiveStop() {
        let workspace = ScoutWorkspace()
        var stopRequestCount = 0
        workspace.liveCaptureStopRequest = { stopRequestCount += 1 }
        workspace.startDemoIfNeeded()
        XCTAssertEqual(workspace.captureState, .listening)

        workspace.requestCaptureStopForArchiveNavigation()

        XCTAssertEqual(stopRequestCount, 0)
        XCTAssertEqual(workspace.captureState, .paused)
    }

    func testArchiveNavigationStillDelegatesWhenProjectedCaptureIsPaused() {
        let workspace = ScoutWorkspace()
        workspace.captureState = .paused
        var stopRequestCount = 0
        workspace.liveCaptureStopRequest = { stopRequestCount += 1 }

        workspace.requestCaptureStopForArchiveNavigation()

        XCTAssertEqual(stopRequestCount, 1)
        XCTAssertEqual(workspace.captureState, .paused)
    }

    func testCanonicalClaimProjectionReplacesSuppressedRawGraphState() {
        let workspace = ScoutWorkspace()
        workspace.beginLiveSessionIfNeeded()
        let evidence = ProjectionEvidenceLink(
            projectionID: "entity-crm",
            projectedClaimIDs: ["claim-crm"],
            clientReferences: ["model-1"],
            evidenceUtteranceIDs: ["utterance-1"],
            evidenceIDs: ["evidence-1"]
        )
        workspace.relationships = [GraphRelationship(
            id: "relationship-raw",
            sourceID: "entity-crm",
            targetID: "entity-crm",
            label: "uses",
            confidence: 0.99,
            isFriction: false
        )]
        let canonical = WorkspaceReplayProjection(
            sessionID: workspace.activeEvidenceSessionID,
            title: "Canonical projection",
            participantCount: 1,
            captureState: .listening,
            elapsedSeconds: 1,
            transcript: [],
            entities: [entity(title: "CRM", confidence: 0.8)],
            relationships: [],
            claims: [claim(confidence: 0.8)],
            projectionEvidenceByID: ["entity-crm": evidence],
            claimEvidenceIDsByID: ["claim-crm": ["evidence-1"]],
            visualEvidenceAsset: nil,
            visualEvidenceProposals: []
        )

        workspace.applyCanonicalClaimProjection(canonical)

        XCTAssertEqual(workspace.entities.count, 1)
        XCTAssertEqual(workspace.entities.first?.confidence, 0.8)
        XCTAssertTrue(workspace.relationships.isEmpty)
        XCTAssertEqual(workspace.claims.count, 1)
        XCTAssertEqual(workspace.projectionEvidenceByID["entity-crm"]?.evidenceIDs, ["evidence-1"])
        XCTAssertEqual(workspace.claimEvidenceIDsByID["claim-crm"], ["evidence-1"])
        XCTAssertTrue(workspace.claimProvenanceByID.isEmpty)
    }

    func testClaimReviewActionsAreStatusGuardedAndDoNotMutateCanonicalProjection() {
        let workspace = ScoutWorkspace()
        workspace.beginLiveSessionIfNeeded()
        let proposed = claim(
            id: "claim-proposed",
            provenance: .proposed,
            needsValidation: true,
            reviewStatus: .proposed
        )
        let legacy = claim(
            id: "claim-legacy",
            provenance: .proposed,
            needsValidation: true,
            reviewStatus: .legacyAccepted
        )
        let accepted = claim(
            id: "claim-accepted",
            provenance: .validated,
            needsValidation: false,
            reviewStatus: .accepted
        )
        workspace.claims = [proposed, legacy, accepted]
        var requests: [(String, ClaimReviewDecision)] = []
        workspace.claimReview = { requests.append(($0, $1)) }

        workspace.acceptClaim(proposed.id)
        workspace.rejectClaim(proposed.id)
        workspace.reattestClaimAcceptance(proposed.id)
        workspace.acceptClaim(legacy.id)
        workspace.rejectClaim(legacy.id)
        workspace.reattestClaimAcceptance(legacy.id)
        workspace.acceptClaim(accepted.id)
        workspace.rejectClaim(accepted.id)
        workspace.reattestClaimAcceptance(accepted.id)

        XCTAssertEqual(requests.map(\.0), [proposed.id, proposed.id, legacy.id])
        XCTAssertEqual(requests.map(\.1), [.accept, .reject, .reattestAcceptance])
        XCTAssertEqual(workspace.claims, [proposed, legacy, accepted])

        workspace.setClaimReviewInProgress(proposed.id, true)
        workspace.acceptClaim(proposed.id)
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(workspace.reviewingClaimIDs.contains(proposed.id))

        workspace.failClaimReview(proposed.id, message: "Authentication was cancelled.")
        XCTAssertFalse(workspace.reviewingClaimIDs.contains(proposed.id))
        XCTAssertEqual(workspace.claimReviewError?.claimID, proposed.id)
        XCTAssertTrue(workspace.claimReviewError?.message.contains("not saved") == true)

        workspace.rejectClaim(proposed.id)
        XCTAssertEqual(requests.last?.1, .reject)
        XCTAssertNil(workspace.claimReviewError)
        XCTAssertEqual(workspace.claims.first?.reviewStatus, .proposed)
    }

    func testLegacyInitializerDerivesCompatibleReviewStatus() {
        XCTAssertEqual(
            claim(provenance: .heard, needsValidation: false).reviewStatus,
            .legacyAccepted
        )
        XCTAssertEqual(
            claim(provenance: .proposed, needsValidation: false).reviewStatus,
            .proposed
        )
        XCTAssertEqual(
            claim(provenance: .validated, needsValidation: true).reviewStatus,
            .proposed
        )
    }

    func testVisualReviewActionsPermitOnlyTheExistingLegacyDecision() {
        let workspace = ScoutWorkspace()
        workspace.beginLiveSessionIfNeeded()
        workspace.visualEvidenceProposals = [
            visualCard(id: "visual-proposed", status: .proposed),
            visualCard(id: "visual-legacy-confirmed", status: .legacyConfirmed),
            visualCard(id: "visual-legacy-rejected", status: .legacyRejected),
            visualCard(id: "visual-authenticated", status: .confirmed),
        ]
        var requests: [(String, VisualEvidenceReviewStatus)] = []
        workspace.visualEvidenceReview = { requests.append(($0, $1)) }

        workspace.confirmVisualObservation("visual-proposed")
        workspace.rejectVisualObservation("visual-proposed")
        workspace.rejectVisualObservation("visual-legacy-confirmed")
        workspace.confirmVisualObservation("visual-legacy-confirmed")
        workspace.confirmVisualObservation("visual-legacy-rejected")
        workspace.rejectVisualObservation("visual-legacy-rejected")
        workspace.confirmVisualObservation("visual-authenticated")

        XCTAssertEqual(
            requests.map(\.0),
            [
                "visual-proposed",
                "visual-proposed",
                "visual-legacy-confirmed",
                "visual-legacy-rejected",
            ]
        )
        XCTAssertEqual(requests.map(\.1), [.confirmed, .rejected, .confirmed, .rejected])
        XCTAssertEqual(workspace.visualEvidenceProposals[1].reviewStatus, .legacyConfirmed)
        XCTAssertEqual(workspace.visualEvidenceProposals[2].reviewStatus, .legacyRejected)
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

    private func claim(
        id: String = "claim-crm",
        confidence: Double = 0.8,
        provenance: EvidenceKind = .heard,
        needsValidation: Bool = false,
        reviewStatus: ClaimReviewStatus? = nil
    ) -> TrustClaim {
        TrustClaim(
            id: id,
            title: "CRM stores customer data",
            detail: "Directly stated.",
            provenance: provenance,
            confidence: confidence,
            evidenceQuote: "Customer data lives in the CRM.",
            speakerName: "Customer",
            timestamp: "00:01",
            relatedEntityID: "entity-crm",
            needsValidation: needsValidation,
            reviewStatus: reviewStatus
        )
    }

    private func visualCard(
        id: String,
        status: VisualEvidenceReviewStatus
    ) -> VisualEvidenceProposalCard {
        VisualEvidenceProposalCard(
            id: id,
            kind: .note,
            title: "Observation",
            detail: "Evidence-linked detail.",
            basis: .visible,
            confidence: 0.9,
            reviewStatus: status
        )
    }
}
