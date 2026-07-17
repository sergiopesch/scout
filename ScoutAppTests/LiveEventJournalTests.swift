import CryptoKit
import Foundation
import ScoutCore
import ScoutPersistence
import XCTest
@testable import Scout

final class LiveEventJournalTests: XCTestCase {
    func testFinalizedUtterancesAreDurableAndIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "Scout.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptionKey = Data(repeating: 0x3C, count: 32)

        let journal = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        let speaker = LiveEventJournal.SpeakerDescriptor(
            id: "speaker-test",
            displayName: "Test speaker",
            role: "Customer",
            affiliation: .customer
        )

        try await journal.prepareSession(
            sessionID: "session-test",
            title: "Test discovery",
            speakers: [speaker]
        )
        let firstReceipt = try await journal.recordFinalUtterance(
            sessionID: "session-test",
            itemID: "mic-item-1",
            speakerID: speaker.id,
            text: "Inventory exceptions take two days to resolve.",
            confidenceBasisPoints: 9_100
        )
        let retryReceipt = try await journal.recordFinalUtterance(
            sessionID: "session-test",
            itemID: "mic-item-1",
            speakerID: speaker.id,
            text: "Inventory exceptions take two days to resolve.",
            confidenceBasisPoints: 9_100
        )
        XCTAssertEqual(retryReceipt, firstReceipt)
        XCTAssertEqual(firstReceipt.speakerID.rawValue, speaker.id)
        XCTAssertEqual(firstReceipt.text, "Inventory exceptions take two days to resolve.")
        XCTAssertEqual(firstReceipt.startMilliseconds, firstReceipt.endMilliseconds)
        XCTAssertGreaterThanOrEqual(firstReceipt.startMilliseconds, 0)
        XCTAssertEqual(
            firstReceipt.committedEvidenceBoundary.eventID.rawValue,
            "event-\(Self.digest("utterance|session-test|mic-item-1"))-evidence"
        )

        let report = try await journal.verify(sessionID: "session-test")
        XCTAssertEqual(report.eventCount, 4)
        XCTAssertEqual(report.lastSequence?.rawValue, 4)

        let reopened = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        try await reopened.prepareSession(
            sessionID: "session-test",
            title: "Test discovery",
            speakers: [speaker]
        )
        let reopenedReport = try await reopened.verify(sessionID: "session-test")
        XCTAssertEqual(reopenedReport.eventCount, 4)
        XCTAssertEqual(reopenedReport.stateDigest, report.stateDigest)
    }

    func testConcurrentMultiSpeakerUtterancesCommitSequentialEvidenceBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-concurrency-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "Scout.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptionKey = Data(repeating: 0x7D, count: 32)
        let journal = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        let emma = LiveEventJournal.SpeakerDescriptor(
            id: "speaker-emma",
            displayName: "Emma",
            role: "VP Digital",
            affiliation: .customer
        )
        let raj = LiveEventJournal.SpeakerDescriptor(
            id: "speaker-raj",
            displayName: "Raj",
            role: "Platform lead",
            affiliation: .customer
        )
        async let prepareEmma: Void = journal.prepareSession(
            sessionID: "session-concurrent",
            title: "Concurrent discovery",
            speakers: [emma]
        )
        async let prepareRaj: Void = journal.prepareSession(
            sessionID: "session-concurrent",
            title: "Concurrent discovery",
            speakers: [raj]
        )
        _ = try await (prepareEmma, prepareRaj)

        let inputs = [
            UtteranceInput(itemID: "item-emma-1", speakerID: emma.id, text: "Salesforce owns customer data.", start: 100, end: 450),
            UtteranceInput(itemID: "item-raj-1", speakerID: raj.id, text: "Inventory lives in NetSuite.", start: 500, end: 900),
            UtteranceInput(itemID: "item-emma-2", speakerID: emma.id, text: "The hand-off is manual.", start: 950, end: 1_300),
            UtteranceInput(itemID: "item-raj-2", speakerID: raj.id, text: "Failures take two days to resolve.", start: 1_350, end: 1_900),
        ]

        let receipts = try await withThrowingTaskGroup(
            of: LiveEventJournal.FinalUtteranceReceipt.self,
            returning: [LiveEventJournal.FinalUtteranceReceipt].self
        ) { group in
            for input in inputs {
                group.addTask {
                    try await journal.recordFinalUtterance(
                        sessionID: "session-concurrent",
                        itemID: input.itemID,
                        speakerID: input.speakerID,
                        text: input.text,
                        confidenceBasisPoints: 9_250,
                        startMilliseconds: input.start,
                        endMilliseconds: input.end
                    )
                }
            }
            var result: [LiveEventJournal.FinalUtteranceReceipt] = []
            for try await receipt in group {
                result.append(receipt)
            }
            return result
        }

        XCTAssertEqual(receipts.count, inputs.count)
        XCTAssertEqual(Set(receipts.map(\.utteranceID)).count, inputs.count)
        XCTAssertEqual(Set(receipts.map(\.evidenceID)).count, inputs.count)
        XCTAssertEqual(
            receipts.map(\.committedEvidenceBoundary.sequence.rawValue).sorted(),
            [5, 7, 9, 11]
        )

        for input in inputs {
            let digest = Self.digest("utterance|session-concurrent|\(input.itemID)")
            let receipt = try XCTUnwrap(receipts.first {
                $0.utteranceID.rawValue == "utterance-\(digest)"
            })
            XCTAssertEqual(receipt.evidenceID.rawValue, "evidence-\(digest)")
            XCTAssertEqual(
                receipt.committedEvidenceBoundary.eventID.rawValue,
                "event-\(digest)-evidence"
            )
            XCTAssertEqual(receipt.committedEvidenceBoundary.sessionID.rawValue, "session-concurrent")
            XCTAssertEqual(receipt.speakerID.rawValue, input.speakerID)
            XCTAssertEqual(receipt.text, input.text)
            XCTAssertEqual(receipt.startMilliseconds, input.start)
            XCTAssertEqual(receipt.endMilliseconds, input.end)
        }

        let report = try await journal.verify(sessionID: "session-concurrent")
        XCTAssertEqual(report.eventCount, 11)
        XCTAssertEqual(report.lastSequence?.rawValue, 11)

        let retriedInput = inputs[2]
        let original = try XCTUnwrap(receipts.first {
            $0.text == retriedInput.text
        })
        let retried = try await journal.recordFinalUtterance(
            sessionID: "session-concurrent",
            itemID: retriedInput.itemID,
            speakerID: retriedInput.speakerID,
            text: retriedInput.text,
            confidenceBasisPoints: 9_250,
            startMilliseconds: retriedInput.start,
            endMilliseconds: retriedInput.end
        )
        XCTAssertEqual(retried, original)
        let reportAfterRetry = try await journal.verify(sessionID: "session-concurrent")
        XCTAssertEqual(reportAfterRetry.eventCount, 11)
    }

    func testSessionRelativeTimeRangeIsValidated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-time-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "Scout.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptionKey = Data(repeating: 0x19, count: 32)
        let journal = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        let speaker = LiveEventJournal.SpeakerDescriptor(
            id: "speaker-time",
            displayName: "Time tester",
            role: "Customer",
            affiliation: .customer
        )
        try await journal.prepareSession(
            sessionID: "session-time",
            title: "Time validation",
            speakers: [speaker]
        )

        do {
            _ = try await journal.recordFinalUtterance(
                sessionID: "session-time",
                itemID: "invalid-negative",
                speakerID: speaker.id,
                text: "Invalid time.",
                confidenceBasisPoints: 9_000,
                startMilliseconds: -1,
                endMilliseconds: 20
            )
            XCTFail("Expected a negative session-relative time to fail")
        } catch let error as LiveEventJournal.JournalError {
            XCTAssertEqual(error, .invalidUtteranceTimeRange)
        }

        do {
            _ = try await journal.recordFinalUtterance(
                sessionID: "session-time",
                itemID: "invalid-partial",
                speakerID: speaker.id,
                text: "Incomplete time.",
                confidenceBasisPoints: 9_000,
                startMilliseconds: 10
            )
            XCTFail("Expected a partial session-relative range to fail")
        } catch let error as LiveEventJournal.JournalError {
            XCTAssertEqual(error, .invalidUtteranceTimeRange)
        }

        let report = try await journal.verify(sessionID: "session-time")
        XCTAssertEqual(report.eventCount, 2)
    }

    func testValidatedClaimProjectionCommitsAtomicallyAndRetriesAsNoOp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-projection-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "Scout.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptionKey = Data(repeating: 0x55, count: 32)
        let journal = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        let speaker = LiveEventJournal.SpeakerDescriptor(
            id: "speaker-projection",
            displayName: "Customer",
            role: "Architect",
            affiliation: .customer
        )
        try await journal.prepareSession(
            sessionID: "session-projection",
            title: "Projection commit",
            speakers: [speaker]
        )
        let utterance = try await journal.recordFinalUtterance(
            sessionID: "session-projection",
            itemID: "item-1",
            speakerID: speaker.id,
            text: "NetSuite stores inventory.",
            confidenceBasisPoints: 9_500,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let boundary = Int(utterance.committedEvidenceBoundary.sequence.rawValue)
        let request = ClaimExtractionRequest(
            sessionID: "session-projection",
            eventBoundary: boundary,
            utterances: [
                ClaimExtractionUtterance(
                    utteranceID: utterance.utteranceID.rawValue,
                    evidenceID: utterance.evidenceID.rawValue,
                    speakerID: utterance.speakerID.rawValue,
                    text: utterance.text,
                    startMilliseconds: Int(utterance.startMilliseconds),
                    endMilliseconds: Int(utterance.endMilliseconds),
                    source: .realtime
                ),
            ]
        )
        let result = try Self.claimResult(
            utteranceID: utterance.utteranceID.rawValue,
            boundary: boundary
        )
        let projection = try ClaimProposalProjector().project(
            result,
            for: request,
            speakerNamesByID: [speaker.id: speaker.displayName]
        )

        let first = try await journal.recordClaimProjection(
            sessionID: "session-projection",
            projection: projection
        )
        let retry = try await journal.recordClaimProjection(
            sessionID: "session-projection",
            projection: projection
        )

        XCTAssertEqual(first.count, 5)
        XCTAssertTrue(retry.isEmpty)
        let report = try await journal.verify(sessionID: "session-projection")
        XCTAssertEqual(report.eventCount, 9)
        XCTAssertEqual(report.lastSequence?.rawValue, 9)

        let persisted = try SQLiteEventStore(fileURL: databaseURL, encryptionKey: encryptionKey)
        let state = try await persisted.state(for: SessionID(validating: "session-projection"))
        XCTAssertEqual(state?.modelCallReceipts.count, 1)
        XCTAssertEqual(state?.graph.entities.count, 2)
        XCTAssertEqual(state?.claims.count, 1)
        XCTAssertEqual(state?.graph.relationships.count, 1)
    }

    func testLatestReplayStateRebuildsFromEncryptedJournal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = LiveEventJournal(
            fileURL: root.appending(path: "Scout.sqlite"),
            encryptionKeyProvider: { Data(repeating: 0x6a, count: 32) }
        )
        try await journal.prepareSession(
            sessionID: "session-restore",
            title: "Acme — Restored discovery",
            speakers: [.init(
                id: "speaker-restore",
                displayName: "Customer",
                role: "Operator",
                affiliation: .customer
            )]
        )
        _ = try await journal.recordFinalUtterance(
            sessionID: "session-restore",
            itemID: "restore-item",
            speakerID: "speaker-restore",
            text: "This evidence must survive an app restart.",
            confidenceBasisPoints: 9_500,
            startMilliseconds: 100,
            endMilliseconds: 900
        )

        let replayed = try await journal.latestReplayState()
        let restored = try XCTUnwrap(replayed)

        XCTAssertEqual(restored.sessionID.rawValue, "session-restore")
        XCTAssertEqual(restored.utterances.count, 1)
        XCTAssertEqual(restored.evidence.count, 1)
        XCTAssertEqual(restored.lastSequence?.rawValue, 4)
    }

    func testIdenticalEmptyOutputsAtDifferentBoundariesDoNotCollide() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-empty-projections-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "Scout.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptionKey = Data(repeating: 0x56, count: 32)
        let journal = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        let speaker = LiveEventJournal.SpeakerDescriptor(
            id: "speaker-empty-projection",
            displayName: "Customer",
            role: "Architect",
            affiliation: .customer
        )
        try await journal.prepareSession(
            sessionID: "session-empty-projections",
            title: "Empty projection boundaries",
            speakers: [speaker]
        )

        let firstEvidence = try await journal.recordFinalUtterance(
            sessionID: "session-empty-projections",
            itemID: "item-empty-1",
            speakerID: speaker.id,
            text: "No structured claims yet.",
            confidenceBasisPoints: 9_500,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let sharedOutputHash = String(repeating: "b", count: 64)
        let firstProjection = Self.emptyProjection(
            responseID: "resp-empty-1",
            boundary: Int(firstEvidence.committedEvidenceBoundary.sequence.rawValue),
            outputHash: sharedOutputHash
        )
        let firstCommit = try await journal.recordClaimProjection(
            sessionID: "session-empty-projections",
            projection: firstProjection
        )

        let secondEvidence = try await journal.recordFinalUtterance(
            sessionID: "session-empty-projections",
            itemID: "item-empty-2",
            speakerID: speaker.id,
            text: "There are still no structured claims.",
            confidenceBasisPoints: 9_500,
            startMilliseconds: 2_100,
            endMilliseconds: 3_100
        )
        let secondProjection = Self.emptyProjection(
            responseID: "resp-empty-2",
            boundary: Int(secondEvidence.committedEvidenceBoundary.sequence.rawValue),
            outputHash: sharedOutputHash
        )
        let secondCommit = try await journal.recordClaimProjection(
            sessionID: "session-empty-projections",
            projection: secondProjection
        )

        XCTAssertEqual(firstCommit.count, 1)
        XCTAssertEqual(secondCommit.count, 1)
        XCTAssertNotEqual(firstCommit.first?.eventID, secondCommit.first?.eventID)
        let persisted = try SQLiteEventStore(fileURL: databaseURL, encryptionKey: encryptionKey)
        let state = try await persisted.state(for: SessionID(validating: "session-empty-projections"))
        XCTAssertEqual(state?.modelCallReceipts.count, 2)
        XCTAssertEqual(Set(state?.modelCallReceipts.values.map(\.outputHash) ?? []).count, 1)
        XCTAssertEqual(Set(state?.modelCallReceipts.values.map(\.inputBoundary) ?? []).count, 2)
    }

    func testVisualEvidenceAndModelReceiptCommitBeforeProposalProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scout-journal-image-\(UUID().uuidString)", directoryHint: .isDirectory)
        let databaseURL = root.appending(path: "Scout.sqlite")
        let imageURL = root.appending(path: "whiteboard.png")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try scoutTestImageData(width: 32, height: 20, type: .png).write(to: imageURL)

        let encryptionKey = Data(repeating: 0x61, count: 32)
        let journal = LiveEventJournal(
            fileURL: databaseURL,
            encryptionKeyProvider: { encryptionKey }
        )
        try await journal.prepareSession(
            sessionID: "session-image",
            title: "Whiteboard discovery",
            speakers: []
        )
        let prepared = try ImageEvidenceImporter().prepareUserSelectedImage(at: imageURL)

        let evidence = try await journal.recordImageEvidence(
            sessionID: "session-image",
            image: prepared
        )
        let evidenceRetry = try await journal.recordImageEvidence(
            sessionID: "session-image",
            image: prepared
        )
        XCTAssertEqual(evidenceRetry, evidence)
        XCTAssertEqual(evidence.committedEvidenceBoundary.sequence.rawValue, 2)
        XCTAssertEqual(evidence.assetSHA256, prepared.assetSHA256)

        let result = try Self.imageObservationResult(assetSHA256: prepared.assetSHA256)
        let observation = try await journal.recordImageObservation(
            sessionID: "session-image",
            evidence: evidence,
            result: result
        )
        let observationRetry = try await journal.recordImageObservation(
            sessionID: "session-image",
            evidence: evidence,
            result: result
        )
        XCTAssertEqual(observationRetry, observation)
        XCTAssertEqual(observation.committedModelBoundary.sequence.rawValue, 3)

        let persisted = try SQLiteEventStore(fileURL: databaseURL, encryptionKey: encryptionKey)
        let state = try await persisted.state(for: SessionID(validating: "session-image"))
        XCTAssertEqual(state?.evidence.count, 1)
        XCTAssertEqual(state?.modelCallReceipts.count, 1)
        XCTAssertTrue(state?.graph.entities.isEmpty == true)
        XCTAssertTrue(state?.claims.isEmpty == true)
        let receipt = try XCTUnwrap(state?.modelCallReceipts.values.first)
        XCTAssertEqual(receipt.purpose, .whiteboardExtraction)
        XCTAssertEqual(receipt.inputBoundary.sequence, evidence.committedEvidenceBoundary.sequence)
        XCTAssertEqual(receipt.inputBoundary.integrityHash, evidence.committedEvidenceBoundary.integrityHash)
        XCTAssertEqual(receipt.metadata["asset_sha256"], .text(prepared.assetSHA256))

        let report = try await journal.verify(sessionID: "session-image")
        // Session start, image evidence, immutable model receipt, and one proposed observation.
        XCTAssertEqual(report.eventCount, 4)
        XCTAssertEqual(report.lastSequence?.rawValue, 4)

        try await journal.prepareSession(
            sessionID: "session-image-two",
            title: "A separate discovery",
            speakers: []
        )
        let secondSessionEvidence = try await journal.recordImageEvidence(
            sessionID: "session-image-two",
            image: prepared
        )
        XCTAssertNotEqual(secondSessionEvidence.evidenceID, evidence.evidenceID)
        XCTAssertNotEqual(
            secondSessionEvidence.committedEvidenceBoundary.eventID,
            evidence.committedEvidenceBoundary.eventID
        )
        let secondReport = try await journal.verify(sessionID: "session-image-two")
        XCTAssertEqual(secondReport.eventCount, 2)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func claimResult(
        utteranceID: String,
        boundary: Int
    ) throws -> ClaimExtractionResult {
        let data = Data(
            """
            {
              "proposal": {
                "schema_version": "1.0",
                "claims": [{
                  "client_ref": "claim-1",
                  "subject": {"kind": "system", "name": "NetSuite"},
                  "predicate": "stores",
                  "object": {"kind": "data", "name": "Inventory", "value": null},
                  "epistemic_status": "heard",
                  "confidence": 0.95,
                  "evidence_utterance_ids": ["\(utteranceID)"],
                  "rationale": "Direct statement."
                }],
                "unresolved_terms": []
              },
              "model_call": {
                "response_id": "resp-projection-1",
                "model": "gpt-test",
                "prompt_version": "claims-v1",
                "schema_version": "1.0",
                "input_event_boundary": \(boundary),
                "output_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              }
            }
            """.utf8
        )
        return try JSONDecoder().decode(ClaimExtractionResult.self, from: data)
    }

    private static func emptyProjection(
        responseID: String,
        boundary: Int,
        outputHash: String
    ) -> ClaimProposalProjection {
        ClaimProposalProjection(
            modelCall: ClaimModelCall(
                responseID: responseID,
                model: "gpt-test",
                promptVersion: "claims-v1",
                schemaVersion: "1.0",
                inputEventBoundary: boundary,
                outputSHA256: outputHash
            ),
            entities: [],
            relationships: [],
            claims: [],
            entityEvidence: [],
            relationshipEvidence: [],
            claimProvenance: []
        )
    }

    private static func imageObservationResult(assetSHA256: String) throws -> ImageObservationResult {
        let data = Data(
            """
            {
              "proposal": {
                "schema_version": "1.0",
                "evidence_asset_sha256": "\(assetSHA256)",
                "entities": [{
                  "client_ref": "entity-crm",
                  "kind": "system",
                  "name": "CRM",
                  "detail": "Customer records",
                  "basis": "visible",
                  "confidence": 0.96,
                  "rationale": "A labelled system box is visible."
                }],
                "relationships": [],
                "notes": []
              },
              "model_call": {
                "response_id": "resp-image-journal",
                "model": "gpt-test",
                "prompt_version": "image-observations-v1",
                "schema_version": "1.0",
                "input_asset_sha256": "\(assetSHA256)",
                "output_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
              }
            }
            """.utf8
        )
        return try JSONDecoder().decode(ImageObservationResult.self, from: data)
    }
}

private struct UtteranceInput: Sendable {
    let itemID: String
    let speakerID: String
    let text: String
    let start: Int64
    let end: Int64
}
