import Foundation
@testable import ScoutCore
import Testing

@Suite("Model-call receipts")
struct ModelCallReceiptTests {
    @Test("Receipt Codable and canonical forms are stable")
    func canonicalRoundTrip() throws {
        let receipt = try makeReceipt(
            id: testID("model-call-canonical"),
            responseID: "resp_canonical"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(receipt)
        let decoded = try JSONDecoder().decode(ModelCallReceipt.self, from: encoded)

        #expect(decoded == receipt)
        #expect(decoded.canonicalValue == receipt.canonicalValue)
        #expect(
            CanonicalJSON.string(receipt.canonicalValue)
                == "{\"id\":\"model-call-canonical\",\"inputBoundary\":{\"eventID\":\"event-input\",\"integrityHash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sequence\":1},\"metadata\":{\"input_tokens\":{\"type\":\"integer\",\"value\":7}},\"model\":\"gpt-fixture\",\"outputHash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"outputSchemaVersion\":\"claims.v1\",\"promptVersion\":\"extract.v1\",\"provider\":\"openai\",\"providerResponseID\":\"resp_canonical\",\"purpose\":\"claimExtraction\"}"
        )

        let payload = ScoutEventPayload.modelCallRecorded(receipt)
        let payloadData = try encoder.encode(payload)
        #expect(try JSONDecoder().decode(ScoutEventPayload.self, from: payloadData) == payload)
        #expect(payload.kind == "modelCall.recorded")
    }

    @Test("Receipt initializer rejects ambiguous identity and metadata")
    func strictValidation() throws {
        let boundary = try makeBoundary()
        let hash = try SHA256Digest(validating: String(repeating: "b", count: 64))

        #expect(throws: ModelCallReceiptValidationError.invalidProvider("OpenAI")) {
            _ = try ModelCallReceipt(
                id: testID("model-call-invalid-provider"),
                provider: testText("OpenAI"),
                providerResponseID: testText("resp_1"),
                purpose: .claimExtraction,
                inputBoundary: boundary,
                promptVersion: testText("extract.v1"),
                outputSchemaVersion: testText("claims.v1"),
                model: testText("gpt-fixture"),
                outputHash: hash
            )
        }
        #expect(throws: ModelCallReceiptValidationError.invalidToken(
            field: "model",
            value: "bad model"
        )) {
            _ = try ModelCallReceipt(
                id: testID("model-call-invalid-model"),
                provider: testText("openai"),
                providerResponseID: testText("resp_2"),
                purpose: .claimExtraction,
                inputBoundary: boundary,
                promptVersion: testText("extract.v1"),
                outputSchemaVersion: testText("claims.v1"),
                model: testText("bad model"),
                outputHash: hash
            )
        }
        #expect(throws: ModelCallReceiptValidationError.invalidMetadataKey("Input Tokens")) {
            _ = try ModelCallReceipt(
                id: testID("model-call-invalid-metadata"),
                provider: testText("openai"),
                providerResponseID: testText("resp_3"),
                purpose: .claimExtraction,
                inputBoundary: boundary,
                promptVersion: testText("extract.v1"),
                outputSchemaVersion: testText("claims.v1"),
                model: testText("gpt-fixture"),
                outputHash: hash,
                metadata: ["Input Tokens": .integer(7)]
            )
        }
    }

    @Test("Fixture replay retains receipt and proves its historical input boundary")
    func replayProjection() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let receipt = try #require(state.modelCallReceipts[ScoutFixtures.modelCallReceiptID])

        #expect(receipt.purpose == .claimExtraction)
        #expect(receipt.inputBoundary == ModelInputEventBoundary(events[3]))
        #expect(state.eventBoundaries.count == events.count)
        #expect(state.eventBoundaries[events[3].id] == receipt.inputBoundary)
        #expect(try ScoutGraphReducer.replay(events).digest == state.digest)
    }

    @Test("Reducer rejects a missing or forged input boundary")
    func inputBoundaryValidation() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        var chain = try chainContinuing(after: events)

        let missingReceipt = try makeReceipt(
            id: testID("model-call-missing-input"),
            responseID: "resp_missing",
            boundary: ModelInputEventBoundary(
                eventID: testID("event-not-applied"),
                sequence: EventSequence(1),
                integrityHash: SHA256Digest(validating: String(repeating: "c", count: 64))
            )
        )
        let missingEvent = try chain.seal(
            id: testID("event-model-missing-input"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .modelCallRecorded(missingReceipt)
        )
        #expect(throws: ScoutReducerError.missingModelInputEvent(testID("event-not-applied"))) {
            _ = try ScoutGraphReducer.reduce(state, event: missingEvent)
        }

        let applied = events[3]
        let forgedBoundary = try ModelInputEventBoundary(
            eventID: applied.id,
            sequence: applied.sequence,
            integrityHash: SHA256Digest(validating: String(repeating: "d", count: 64))
        )
        let forgedReceipt = try makeReceipt(
            id: testID("model-call-forged-input"),
            responseID: "resp_forged",
            boundary: forgedBoundary
        )
        let forgedEvent = ScoutEventEnvelope.seal(
            id: testID("event-model-forged-input"),
            sessionID: ScoutFixtures.sessionID,
            sequence: missingEvent.sequence,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .modelCallRecorded(forgedReceipt),
            previousHash: missingEvent.previousHash
        )
        #expect(throws: ScoutReducerError.modelInputBoundaryMismatch(
            expected: ModelInputEventBoundary(applied),
            actual: forgedBoundary
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: forgedEvent)
        }
    }

    @Test("Reducer distinguishes receipt duplicates from receipt conflicts")
    func receiptIdentityProtection() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let original = try #require(state.modelCallReceipts[ScoutFixtures.modelCallReceiptID])
        var chain = try chainContinuing(after: events)

        let duplicateEvent = try chain.seal(
            id: testID("event-model-duplicate-id"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .modelCallRecorded(original)
        )
        #expect(throws: ScoutReducerError.duplicateModelCallReceipt(original.id)) {
            _ = try ScoutGraphReducer.reduce(state, event: duplicateEvent)
        }

        let conflicting = try replacing(
            original,
            outputHash: SHA256Digest.hash(Data("different-output".utf8))
        )
        let conflictEvent = ScoutEventEnvelope.seal(
            id: testID("event-model-conflicting-id"),
            sessionID: ScoutFixtures.sessionID,
            sequence: duplicateEvent.sequence,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .modelCallRecorded(conflicting),
            previousHash: duplicateEvent.previousHash
        )
        #expect(throws: ScoutReducerError.modelCallReceiptConflict(original.id)) {
            _ = try ScoutGraphReducer.reduce(state, event: conflictEvent)
        }
    }

    @Test("Reducer protects provider response IDs across local receipt IDs")
    func providerResponseProtection() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let original = try #require(state.modelCallReceipts[ScoutFixtures.modelCallReceiptID])
        var chain = try chainContinuing(after: events)

        let duplicate = try replacing(original, id: testID("model-call-duplicate-response"))
        let duplicateEvent = try chain.seal(
            id: testID("event-model-duplicate-response"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .modelCallRecorded(duplicate)
        )
        #expect(throws: ScoutReducerError.duplicateModelResponse(
            provider: original.provider.rawValue,
            responseID: original.providerResponseID.rawValue
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: duplicateEvent)
        }

        let conflict = try replacing(
            original,
            id: testID("model-call-conflicting-response"),
            outputHash: SHA256Digest.hash(Data("conflicting-provider-output".utf8))
        )
        let conflictEvent = ScoutEventEnvelope.seal(
            id: testID("event-model-conflicting-response"),
            sessionID: ScoutFixtures.sessionID,
            sequence: duplicateEvent.sequence,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .modelCallRecorded(conflict),
            previousHash: duplicateEvent.previousHash
        )
        #expect(throws: ScoutReducerError.modelResponseConflict(
            provider: original.provider.rawValue,
            responseID: original.providerResponseID.rawValue
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: conflictEvent)
        }
    }

    @Test("v1.0 events replay while model-call receipts require v1.1")
    func schemaCompatibility() throws {
        let sessionID: SessionID = testID("session-schema-v1")
        let started = try ScoutEventEnvelope.seal(
            schemaVersion: EventSchemaVersion(major: 1, minor: 0),
            id: testID("event-schema-v1-start"),
            sessionID: sessionID,
            sequence: EventSequence(1),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .sessionStarted(DiscoverySession(
                id: sessionID,
                title: testText("v1 compatibility"),
                startedAt: timestamp()
            )),
            previousHash: nil
        )
        let state = try ScoutGraphReducer.reduce(ScoutState(sessionID: sessionID), event: started)
        #expect(state.session?.status == .active)

        let receipt = try makeReceipt(
            id: testID("model-call-v1-invalid"),
            responseID: "resp_v1_invalid",
            boundary: ModelInputEventBoundary(started)
        )
        let receiptEvent = try ScoutEventEnvelope.seal(
            schemaVersion: EventSchemaVersion(major: 1, minor: 0),
            id: testID("event-model-v1-invalid"),
            sessionID: sessionID,
            sequence: EventSequence(2),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            actor: testSystemActor(),
            payload: .modelCallRecorded(receipt),
            previousHash: started.integrityHash
        )
        #expect(throws: ScoutReducerError.payloadUnavailableInSchema(
            kind: "modelCall.recorded",
            schemaVersion: EventSchemaVersion(major: 1, minor: 0)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: receiptEvent)
        }
    }

    @Test("v1.0 state snapshots decode without the new projections")
    func legacyStateDecode() throws {
        let state = try ScoutFixtures.sampleState()
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object.removeValue(forKey: "modelCallReceipts")
        object.removeValue(forKey: "eventBoundaries")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ScoutState.self, from: legacyData)

        #expect(decoded.modelCallReceipts.isEmpty)
        #expect(decoded.eventBoundaries.isEmpty)
        #expect(decoded.sessionID == state.sessionID)
        #expect(decoded.graph == state.graph)
    }

    private func makeReceipt(
        id: ModelCallReceiptID,
        responseID: String,
        boundary: ModelInputEventBoundary? = nil
    ) throws -> ModelCallReceipt {
        try ModelCallReceipt(
            id: id,
            provider: testText("openai"),
            providerResponseID: testText(responseID),
            purpose: .claimExtraction,
            inputBoundary: boundary ?? makeBoundary(),
            promptVersion: testText("extract.v1"),
            outputSchemaVersion: testText("claims.v1"),
            model: testText("gpt-fixture"),
            outputHash: SHA256Digest(validating: String(repeating: "b", count: 64)),
            metadata: ["input_tokens": .integer(7)]
        )
    }

    private func makeBoundary() throws -> ModelInputEventBoundary {
        try ModelInputEventBoundary(
            eventID: testID("event-input"),
            sequence: EventSequence(1),
            integrityHash: SHA256Digest(validating: String(repeating: "a", count: 64))
        )
    }

    private func replacing(
        _ receipt: ModelCallReceipt,
        id: ModelCallReceiptID? = nil,
        outputHash: SHA256Digest? = nil
    ) throws -> ModelCallReceipt {
        try ModelCallReceipt(
            id: id ?? receipt.id,
            provider: receipt.provider,
            providerResponseID: receipt.providerResponseID,
            purpose: receipt.purpose,
            inputBoundary: receipt.inputBoundary,
            promptVersion: receipt.promptVersion,
            outputSchemaVersion: receipt.outputSchemaVersion,
            model: receipt.model,
            outputHash: outputHash ?? receipt.outputHash,
            metadata: receipt.metadata
        )
    }
}
