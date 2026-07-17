import Foundation
import ScoutCore
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

    var errorDescription: String? { "The test observation service is unavailable." }
}
