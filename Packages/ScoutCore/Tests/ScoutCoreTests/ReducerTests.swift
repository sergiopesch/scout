import Foundation
import Testing
@testable import ScoutCore

@Suite("Pure graph reducer")
struct ReducerTests {
    @Test("Replaying fixture builds the trusted customer graph")
    func fixtureReplay() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)

        #expect(state.session?.status == .active)
        #expect(state.speakers.count == 1)
        #expect(state.utterances.count == 1)
        #expect(state.evidence.count == 1)
        #expect(state.modelCallReceipts.count == 1)
        #expect(state.claims.count == 1)
        #expect(state.graph.entities.count == 2)
        #expect(state.graph.relationships.count == 1)
        #expect(state.claims[ScoutFixtures.claimID]?.trust.origin == .heard)
        #expect(state.lastEventHash == events.last?.integrityHash)
        let replayed = try ScoutGraphReducer.replay(events)
        #expect(state.digest == replayed.digest)
    }

    @Test("State Codable round-trip preserves canonical digest")
    func stateRoundTrip() throws {
        let state = try ScoutFixtures.sampleState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ScoutState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.digest == state.digest)
    }

    @Test("Reducer rejects sequence gaps before applying payload")
    func sequenceGap() throws {
        let events = try ScoutFixtures.sampleEvents()
        let firstState = try ScoutGraphReducer.reduce(
            ScoutState(sessionID: ScoutFixtures.sessionID),
            event: events[0]
        )
        let gap = ScoutEventEnvelope.seal(
            id: testID("event-gap"),
            sessionID: ScoutFixtures.sessionID,
            sequence: try EventSequence(3),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: events[1].payload,
            previousHash: events[0].integrityHash
        )

        do {
            _ = try ScoutGraphReducer.reduce(firstState, event: gap)
            Issue.record("Expected sequence gap to fail")
        } catch let error as ScoutReducerError {
            #expect(error == .unexpectedSequence(expected: 2, actual: 3))
        }
    }

    @Test("Reducer rejects a broken predecessor link")
    func predecessorMismatch() throws {
        let events = try ScoutFixtures.sampleEvents()
        let firstState = try ScoutGraphReducer.reduce(
            ScoutState(sessionID: ScoutFixtures.sessionID),
            event: events[0]
        )
        let broken = ScoutEventEnvelope.seal(
            id: testID("event-broken-link"),
            sessionID: ScoutFixtures.sessionID,
            sequence: try EventSequence(2),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: events[1].payload,
            previousHash: nil
        )

        do {
            _ = try ScoutGraphReducer.reduce(firstState, event: broken)
            Issue.record("Expected predecessor mismatch")
        } catch let error as ScoutReducerError {
            #expect(error == .previousHashMismatch(
                expected: events[0].integrityHash,
                actual: nil
            ))
        }
    }

    @Test("A claim without evidence cannot become graph truth")
    func evidenceInvariant() throws {
        let prefix = Array(try ScoutFixtures.sampleEvents().prefix(6))
        let state = try ScoutGraphReducer.replay(prefix)
        var chain = try chainContinuing(after: prefix)
        let claim = Claim(
            id: testID("claim-no-evidence"),
            subject: .entity(ScoutFixtures.customerDataEntityID),
            predicate: .storesDataIn,
            object: .entity(ScoutFixtures.salesforceEntityID),
            evidenceIDs: [],
            trust: ScoutFixtures.heardTrust
        )
        let event = try chain.seal(
            id: testID("event-no-evidence"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .claimProposed(claim)
        )

        do {
            _ = try ScoutGraphReducer.reduce(state, event: event)
            Issue.record("Expected ungrounded claim to fail")
        } catch let error as ScoutReducerError {
            #expect(error == .emptyEvidence(subject: claim.id.rawValue))
        }
    }

    @Test("Utterance evidence must reference an existing finalized utterance")
    func utteranceEvidenceReference() throws {
        let prefix = Array(try ScoutFixtures.sampleEvents().prefix(2))
        let state = try ScoutGraphReducer.replay(prefix)
        var chain = try chainContinuing(after: prefix)
        let missingUtterance: UtteranceID = testID("utterance-missing")
        let evidence = Evidence(
            id: testID("evidence-bad-reference"),
            source: .utterance(missingUtterance),
            capturedAt: timestamp(),
            capturedBy: testSystemActor()
        )
        let event = try chain.seal(
            id: testID("event-bad-evidence"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .evidenceRecorded(evidence)
        )

        do {
            _ = try ScoutGraphReducer.reduce(state, event: event)
            Issue.record("Expected missing utterance to fail")
        } catch let error as ScoutReducerError {
            #expect(error == .unknownUtterance(missingUtterance))
        }
    }

    @Test("Upserts merge aliases, evidence, and attributes deterministically")
    func entityMerge() throws {
        let baseEvents = try ScoutFixtures.sampleEvents()
        let baseState = try ScoutGraphReducer.replay(baseEvents)
        let original = try #require(baseState.graph.entities[ScoutFixtures.salesforceEntityID])
        var chain = try chainContinuing(after: baseEvents)
        let update = GraphEntity(
            id: original.id,
            kind: original.kind,
            canonicalName: testText("Salesforce CRM"),
            aliases: [testText("SFDC"), testText("Salesforce")],
            attributes: ["tier": .text("critical")],
            evidenceIDs: original.evidenceIDs,
            trust: original.trust
        )
        let event = try chain.seal(
            id: testID("event-entity-update"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .entityUpserted(update)
        )
        let updatedState = try ScoutGraphReducer.reduce(baseState, event: event)
        let merged = try #require(updatedState.graph.entities[original.id])

        #expect(merged.canonicalName == testText("Salesforce CRM"))
        #expect(merged.aliases == [testText("SFDC"), testText("Salesforce")])
        #expect(merged.attributes["category"] == .text("CRM"))
        #expect(merged.attributes["tier"] == .text("critical"))
    }

    @Test("Ending a session is terminal")
    func terminalSession() throws {
        let endedEvents = try ScoutFixtures.sampleEvents(includeSessionEnd: true)
        let state = try ScoutGraphReducer.replay(endedEvents)
        #expect(state.session?.status == .ended)

        var chain = try chainContinuing(after: endedEvents)
        let extra = try chain.seal(
            id: testID("event-after-end"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: testSystemActor(),
            payload: .speakerUpserted(try #require(state.speakers[ScoutFixtures.speakerID]))
        )
        do {
            _ = try ScoutGraphReducer.reduce(state, event: extra)
            Issue.record("Expected terminal session to reject events")
        } catch let error as ScoutReducerError {
            #expect(error == .sessionHasEnded)
        }
    }
}
