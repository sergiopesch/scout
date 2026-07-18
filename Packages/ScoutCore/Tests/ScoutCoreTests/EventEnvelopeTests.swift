import Foundation
import Testing
@testable import ScoutCore

@Suite("Versioned event envelopes")
struct EventEnvelopeTests {
    @Test("Legacy authorization fields cannot alter state outside the canonical hash")
    func legacyAuthorizationIsRejected() throws {
        let schema = EventSchemaVersion(major: 1, minor: 2)
        let sessionID: SessionID = testID("session-legacy-auth-field")
        let eventID: EventID = testID("event-legacy-auth-field")
        let actor = testSystemActor()
        let payload = ScoutEventPayload.sessionStarted(DiscoverySession(
            id: sessionID,
            title: testText("Legacy authorization integrity"),
            startedAt: timestamp()
        ))
        let clean = ScoutEventEnvelope.seal(
            schemaVersion: schema,
            id: eventID,
            sessionID: sessionID,
            sequence: try EventSequence(1),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: actor,
            payload: payload,
            previousHash: nil
        )
        let injected = ScoutEventEnvelope.seal(
            schemaVersion: schema,
            id: eventID,
            sessionID: sessionID,
            sequence: try EventSequence(1),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: actor,
            authorization: EventAuthorizationRecord(
                scope: .localReview,
                component: testText("not-hash-bound")
            ),
            payload: payload,
            previousHash: nil
        )

        #expect(clean.integrityHash == injected.integrityHash)
        #expect(clean.canonicalValue == injected.canonicalValue)
        #expect(throws: ScoutReducerError.authorizationUnavailableInSchema(
            eventID: eventID,
            schemaVersion: schema
        )) {
            _ = try ScoutGraphReducer.reducePersisted(
                ScoutState(sessionID: sessionID),
                event: injected
            )
        }
    }

    @Test("Fixture is a valid, continuous cryptographic chain")
    func fixtureChain() throws {
        let events = try ScoutFixtures.sampleEvents()
        #expect(events.count == 9)

        for (index, event) in events.enumerated() {
            #expect(event.sequence.rawValue == UInt64(index + 1))
            #expect(event.hasValidIntegrity)
            if index == 0 {
                #expect(event.previousHash == nil)
            } else {
                #expect(event.previousHash == events[index - 1].integrityHash)
            }
        }
    }

    @Test("Sealing identical content produces identical hashes")
    func deterministicSeal() throws {
        let original = try ScoutFixtures.sampleEvents()[0]
        let duplicate = ScoutEventEnvelope.seal(
            schemaVersion: original.schemaVersion,
            id: original.id,
            sessionID: original.sessionID,
            sequence: original.sequence,
            occurredAt: original.occurredAt,
            recordedAt: original.recordedAt,
            actor: original.actor,
            authorization: original.authorization,
            correlationID: original.correlationID,
            causationID: original.causationID,
            payload: original.payload,
            previousHash: original.previousHash
        )

        #expect(original.integrityHash == duplicate.integrityHash)
        #expect(original == duplicate)
    }

    @Test("Any semantic envelope change changes its hash")
    func semanticMutationChangesHash() throws {
        let original = try ScoutFixtures.sampleEvents()[0]
        let changed = ScoutEventEnvelope.seal(
            id: original.id,
            sessionID: original.sessionID,
            sequence: original.sequence,
            occurredAt: original.occurredAt,
            recordedAt: ScoutTimestamp(
                millisecondsSinceUnixEpoch: original.recordedAt.millisecondsSinceUnixEpoch + 1
            ),
            actor: original.actor,
            authorization: original.authorization,
            payload: original.payload,
            previousHash: original.previousHash
        )

        #expect(original.integrityHash != changed.integrityHash)
    }

    @Test("Envelope Codable round-trip retains integrity")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        for event in try ScoutFixtures.sampleEvents(includeSessionEnd: true) {
            let decoded = try decoder.decode(
                ScoutEventEnvelope.self,
                from: encoder.encode(event)
            )
            #expect(decoded == event)
            #expect(decoded.hasValidIntegrity)
        }
    }

    @Test("A persisted envelope with a changed integrity hash is rejected")
    func tamperDetection() throws {
        let event = try ScoutFixtures.sampleEvents()[0]
        let encoded = try JSONEncoder().encode(event)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["integrityHash"] = String(repeating: "0", count: 64)
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let tampered = try JSONDecoder().decode(ScoutEventEnvelope.self, from: tamperedData)

        #expect(!tampered.hasValidIntegrity)
        do {
            _ = try ScoutGraphReducer.reducePersisted(
                ScoutState(sessionID: tampered.sessionID),
                event: tampered
            )
            Issue.record("Expected tampered event to fail")
        } catch let error as ScoutReducerError {
            #expect(error == .invalidIntegrity(tampered.id))
        }
    }

    @Test("Future major and minor schema versions are rejected")
    func schemaCompatibility() throws {
        let original = try ScoutFixtures.sampleEvents()[0]
        for version in [
            EventSchemaVersion(major: EventSchemaVersion.current.major + 1, minor: 0),
            EventSchemaVersion(
                major: EventSchemaVersion.current.major,
                minor: EventSchemaVersion.current.minor + 1
            ),
        ] {
            let future = ScoutEventEnvelope.seal(
                schemaVersion: version,
                id: original.id,
                sessionID: original.sessionID,
                sequence: original.sequence,
                occurredAt: original.occurredAt,
                recordedAt: original.recordedAt,
                actor: original.actor,
                authorization: original.authorization,
                payload: original.payload,
                previousHash: nil
            )
            do {
                _ = try ScoutGraphReducer.reducePersisted(
                    ScoutState(sessionID: future.sessionID),
                    event: future
                )
                Issue.record("Expected unsupported schema \(version)")
            } catch let error as ScoutReducerError {
                #expect(error == .unsupportedSchema(version))
            }
        }
    }
}
