import Foundation
import ScoutCore
@testable import ScoutLocalReviewAuthority
import ScoutPersistence
import UniformTypeIdentifiers
import XCTest
@testable import Scout

@MainActor
final class VisualEvidenceCoordinatorTests: XCTestCase {
    func testPersistsEvidenceBeforeObservationAndKeepsResultProposed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspace = ScoutWorkspace()
        let journal = fixture.journal
        let coordinator = VisualEvidenceCoordinator(
            workspace: workspace,
            journal: journal,
            prepareImage: { try ImageEvidenceImporter().prepareUserSelectedImage(at: $0) },
            observeImage: { request in
                let report = try await journal.verify(sessionID: request.sessionID)
                XCTAssertEqual(report.eventCount, 2, "Session and image evidence must commit before the model call")
                return try Self.result(assetSHA256: request.image.assetSHA256)
            },
            selectImage: { nil }
        )

        await coordinator.importUserSelectedImage(at: fixture.imageURL)

        XCTAssertEqual(workspace.visualEvidencePhase, .ready)
        XCTAssertEqual(workspace.destination, .evidence)
        XCTAssertEqual(workspace.visualEvidenceProposals.count, 3)
        XCTAssertTrue(workspace.visualEvidenceProposals.allSatisfy(\.needsValidation))
        XCTAssertTrue(workspace.entities.isEmpty, "Image proposals must not mutate canonical graph UI")
        XCTAssertTrue(workspace.claims.isEmpty, "Image proposals must not become accepted claims")
        XCTAssertNotNil(workspace.visualEvidenceAsset?.modelCallReceiptID)

        let store = try SQLiteEventStore(fileURL: fixture.databaseURL, encryptionKey: fixture.encryptionKey)
        let state = try await store.state(for: SessionID(validating: workspace.activeEvidenceSessionID))
        XCTAssertEqual(state?.evidence.count, 1)
        XCTAssertEqual(state?.modelCallReceipts.count, 1)
        XCTAssertTrue(state?.graph.entities.isEmpty == true)
        XCTAssertTrue(state?.claims.isEmpty == true)
        try await store.close()
        try await journal.close()
    }

    func testObservationFailureRetainsEvidenceAndAppliesNoProposal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspace = ScoutWorkspace()
        let journal = fixture.journal
        let coordinator = VisualEvidenceCoordinator(
            workspace: workspace,
            journal: journal,
            prepareImage: { try ImageEvidenceImporter().prepareUserSelectedImage(at: $0) },
            observeImage: { _ in throw StubObservationError.unavailable },
            selectImage: { nil }
        )

        await coordinator.importUserSelectedImage(at: fixture.imageURL)

        XCTAssertEqual(workspace.visualEvidencePhase, .failed)
        XCTAssertNotNil(workspace.visualEvidenceAsset)
        XCTAssertTrue(workspace.visualEvidenceProposals.isEmpty)
        XCTAssertTrue(workspace.visualEvidenceMessage?.contains("Evidence retained") == true)

        let store = try SQLiteEventStore(fileURL: fixture.databaseURL, encryptionKey: fixture.encryptionKey)
        let state = try await store.state(for: SessionID(validating: workspace.activeEvidenceSessionID))
        XCTAssertEqual(state?.evidence.count, 1)
        XCTAssertEqual(state?.modelCallReceipts.count, 0)
        try await store.close()
        try await journal.close()
    }

    func testSessionSwitchDuringAuthenticationDoesNotRecordVisualReview() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = try ScoutFixtures.sampleState()
        let workspace = try workspaceForReview(state: state)
        let observationID = "visual-session-switch"
        workspace.visualEvidenceProposals = [Self.reviewCard(id: observationID)]
        let intent = try reviewIntent(in: state, suffix: "session-switch")
        let authenticationStarted = AsyncStream<Void>.makeStream()
        let releaseAuthentication = AsyncStream<Void>.makeStream()
        let calls = VisualReviewCallRecorder()
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { _ in
                await calls.recordAuthorization()
                authenticationStarted.continuation.yield()
                var iterator = releaseAuthentication.stream.makeAsyncIterator()
                _ = await iterator.next()
                return true
            },
            clock: { ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_200_000) }
        )
        let coordinator = reviewCoordinator(
            workspace: workspace,
            journal: fixture.journal,
            intent: intent,
            calls: calls,
            authorizeReview: { try await authority.authorize($0) }
        )
        coordinator.install()
        var startedIterator = authenticationStarted.stream.makeAsyncIterator()

        workspace.confirmVisualObservation(observationID)
        _ = await startedIterator.next()
        workspace.activeEvidenceSessionID = "session-switched-before-record"
        releaseAuthentication.continuation.yield()

        await waitUntil {
            !workspace.reviewingVisualObservationIDs.contains(observationID)
        }
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.authorizationCount, 1)
        XCTAssertEqual(snapshot.recordCount, 0)
        XCTAssertEqual(workspace.visualEvidenceProposals.first?.reviewStatus, .proposed)
        XCTAssertNil(workspace.visualEvidenceReviewError)
        authenticationStarted.continuation.finish()
        releaseAuthentication.continuation.finish()
        try await fixture.journal.close()
    }

    func testCancellationDuringAuthenticationDoesNotRecordVisualReview() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = try ScoutFixtures.sampleState()
        let workspace = try workspaceForReview(state: state)
        let observationID = "visual-cancelled-authentication"
        workspace.visualEvidenceProposals = [Self.reviewCard(id: observationID)]
        let intent = try reviewIntent(in: state, suffix: "cancelled")
        let authenticationStarted = AsyncStream<Void>.makeStream()
        let authenticationFinished = AsyncStream<Void>.makeStream()
        let releaseAuthentication = AsyncStream<Void>.makeStream()
        let calls = VisualReviewCallRecorder()
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { _ in
                await calls.recordAuthorization()
                authenticationStarted.continuation.yield()
                var iterator = releaseAuthentication.stream.makeAsyncIterator()
                _ = await iterator.next()
                authenticationFinished.continuation.yield()
                return true
            },
            clock: { ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_200_000) }
        )
        let coordinator = reviewCoordinator(
            workspace: workspace,
            journal: fixture.journal,
            intent: intent,
            calls: calls,
            authorizeReview: { try await authority.authorize($0) }
        )
        coordinator.install()
        var startedIterator = authenticationStarted.stream.makeAsyncIterator()
        var finishedIterator = authenticationFinished.stream.makeAsyncIterator()

        workspace.confirmVisualObservation(observationID)
        _ = await startedIterator.next()
        coordinator.cancel()
        releaseAuthentication.continuation.yield()
        _ = await finishedIterator.next()
        for _ in 0 ..< 20 { await Task.yield() }

        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.authorizationCount, 1)
        XCTAssertEqual(snapshot.recordCount, 0)
        XCTAssertFalse(workspace.reviewingVisualObservationIDs.contains(observationID))
        XCTAssertEqual(workspace.visualEvidenceProposals.first?.reviewStatus, .proposed)
        XCTAssertNil(workspace.visualEvidenceReviewError)
        authenticationStarted.continuation.finish()
        authenticationFinished.continuation.finish()
        releaseAuthentication.continuation.finish()
        try await fixture.journal.close()
    }

    func testSameSessionAuthenticationStillRecordsAndAppliesCanonicalProjection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = try ScoutFixtures.sampleState()
        let workspace = try workspaceForReview(state: state)
        let observationID = "visual-same-session"
        workspace.visualEvidenceProposals = [Self.reviewCard(id: observationID)]
        let intent = try reviewIntent(in: state, suffix: "same-session")
        let calls = VisualReviewCallRecorder()
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { _ in
                await calls.recordAuthorization()
                return true
            },
            clock: { ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_200_000) }
        )
        let event = try XCTUnwrap(ScoutFixtures.sampleEvents().last)
        let receipt = LiveEventJournal.VisualObservationReviewReceipt(
            observationID: try VisualObservationID(validating: observationID),
            disposition: .confirmed,
            committedReviewBoundary: AppendReceipt(event: event),
            canonicalState: state
        )
        let coordinator = reviewCoordinator(
            workspace: workspace,
            journal: fixture.journal,
            intent: intent,
            calls: calls,
            authorizeReview: { try await authority.authorize($0) },
            receipt: receipt
        )
        coordinator.install()

        workspace.confirmVisualObservation(observationID)

        await waitUntil {
            !workspace.reviewingVisualObservationIDs.contains(observationID)
                && workspace.visualEvidenceProposals.isEmpty
        }
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.authorizationCount, 1)
        XCTAssertEqual(snapshot.recordCount, 1)
        XCTAssertNil(workspace.visualEvidenceReviewError)
        try await fixture.journal.close()
    }

    private func workspaceForReview(state: ScoutState) throws -> ScoutWorkspace {
        let workspace = ScoutWorkspace(completed: false)
        workspace.applyReplayProjection(try XCTUnwrap(
            WorkspaceStateProjector().project(state)
        ))
        return workspace
    }

    private func reviewIntent(in state: ScoutState, suffix: String) throws -> LocalReviewIntent {
        let claim = try XCTUnwrap(state.claims[ScoutFixtures.claimID])
        return try LocalReviewIntent.preparing(
            eventID: try EventID(validating: "event-visual-coordinator-\(suffix)"),
            operation: .reviewClaim(ClaimReviewed(
                claimID: claim.id,
                status: .accepted,
                trust: TrustAssessment(
                    origin: .confirmed,
                    confidence: claim.trust.confidence,
                    validationStatus: .validated,
                    rationale: claim.trust.rationale
                )
            )),
            in: state
        )
    }

    private func reviewCoordinator(
        workspace: ScoutWorkspace,
        journal: LiveEventJournal,
        intent: LocalReviewIntent,
        calls: VisualReviewCallRecorder,
        authorizeReview: @escaping VisualEvidenceCoordinator.AuthorizeReview,
        receipt: LiveEventJournal.VisualObservationReviewReceipt? = nil
    ) -> VisualEvidenceCoordinator {
        VisualEvidenceCoordinator(
            workspace: workspace,
            journal: journal,
            prepareImage: { _ in throw StubObservationError.unexpectedImport },
            observeImage: { _ in throw StubObservationError.unexpectedImport },
            selectImage: { nil },
            authorizeReview: authorizeReview,
            prepareReview: { _, _, _ in
                await calls.recordPreparation()
                return .authorizationRequired(intent)
            },
            recordReview: { _, _ in
                await calls.recordReview()
                guard let receipt else { throw StubObservationError.unexpectedReviewRecord }
                return receipt
            }
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
        XCTFail("Timed out waiting for visual review work.", file: file, line: line)
    }

    nonisolated private static func reviewCard(id: String) -> VisualEvidenceProposalCard {
        VisualEvidenceProposalCard(
            id: id,
            kind: .entity,
            title: "Review target",
            detail: "A bounded visual observation.",
            basis: .visible,
            confidence: 0.9,
            reviewStatus: .proposed
        )
    }

    nonisolated private static func result(assetSHA256: String) throws -> ImageObservationResult {
        let data = Data(
            """
            {
              "proposal": {
                "schema_version": "1.0",
                "evidence_asset_sha256": "\(assetSHA256)",
                "entities": [
                  {
                    "client_ref": "entity-crm",
                    "kind": "system",
                    "name": "CRM",
                    "detail": "Customer records",
                    "basis": "visible",
                    "confidence": 0.96,
                    "rationale": "A labelled system box is visible."
                  },
                  {
                    "client_ref": "entity-orders",
                    "kind": "data",
                    "name": "Orders",
                    "detail": null,
                    "basis": "inferred",
                    "confidence": 0.72,
                    "rationale": "The cylinder shape may represent order data."
                  }
                ],
                "relationships": [{
                  "client_ref": "relationship-crm-orders",
                  "source_client_ref": "entity-crm",
                  "predicate": "writes_to",
                  "target_client_ref": "entity-orders",
                  "basis": "visible",
                  "confidence": 0.89,
                  "rationale": "A directed arrow is visible."
                }],
                "notes": []
              },
              "model_call": {
                "response_id": "resp-image-coordinator",
                "model": "gpt-test",
                "prompt_version": "image-observations-v1",
                "schema_version": "1.0",
                "input_asset_sha256": "\(assetSHA256)",
                "output_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
              }
            }
            """.utf8
        )
        return try JSONDecoder().decode(ImageObservationResult.self, from: data)
    }

    private struct Fixture {
        let root: URL
        let databaseURL: URL
        let imageURL: URL
        let encryptionKey = Data(repeating: 0x73, count: 32)
        let journal: LiveEventJournal

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "scout-visual-coordinator-\(UUID().uuidString)", directoryHint: .isDirectory)
            databaseURL = root.appending(path: "Scout.sqlite")
            imageURL = root.appending(path: "whiteboard.png")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try scoutTestImageData(width: 40, height: 24, type: .png).write(to: imageURL)
            let key = encryptionKey
            journal = LiveEventJournal(fileURL: databaseURL, encryptionKeyProvider: { key })
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private enum StubObservationError: LocalizedError, Sendable {
    case unavailable
    case unexpectedImport
    case unexpectedReviewRecord

    var errorDescription: String? {
        switch self {
        case .unavailable: "The test observation service is unavailable."
        case .unexpectedImport: "The visual import path should not run during review tests."
        case .unexpectedReviewRecord: "A visual review was recorded unexpectedly."
        }
    }
}

private actor VisualReviewCallRecorder {
    struct Snapshot: Sendable {
        let preparationCount: Int
        let authorizationCount: Int
        let recordCount: Int
    }

    private var preparationCount = 0
    private var authorizationCount = 0
    private var recordCount = 0

    func recordPreparation() {
        preparationCount += 1
    }

    func recordAuthorization() {
        authorizationCount += 1
    }

    func recordReview() {
        recordCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            preparationCount: preparationCount,
            authorizationCount: authorizationCount,
            recordCount: recordCount
        )
    }
}
