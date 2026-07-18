import Foundation
import Testing
@testable import ScoutCore

@Suite("Actor-isolated append-only event store")
struct EventStoreTests {
    @Test("Batch append exposes events and reduced state")
    func appendAndRead() async throws {
        let store = InMemoryEventStore()
        let validatedEvents = try ScoutFixtures.sampleValidatedEvents()
        let events = validatedEvents.map(\.envelope)
        let receipts = try await store.append(validatedEvents)
        let expectedState = try ScoutGraphReducer.replay(events)

        #expect(receipts.count == events.count)
        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == events.count)
        #expect(await store.events(for: ScoutFixtures.sessionID) == events)
        #expect(await store.state(for: ScoutFixtures.sessionID)?.digest == expectedState.digest)
        #expect(await store.sessionIDs() == [ScoutFixtures.sessionID])

        let after = try EventSequence(5)
        #expect(await store.events(for: ScoutFixtures.sessionID, after: after) == Array(events.dropFirst(5)))
    }

    @Test("A failed batch is rolled back atomically")
    func atomicRollback() async throws {
        let store = InMemoryEventStore()
        let validFirst = try ScoutFixtures.sampleValidatedEvents()[0]
        let invalidSecond = ScoutEventEnvelope.seal(
            id: testID("event-wrong-sequence"),
            sessionID: ScoutFixtures.sessionID,
            sequence: try EventSequence(1),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: validFirst.envelope.actor,
            authorization: validFirst.envelope.authorization,
            payload: validFirst.envelope.payload,
            previousHash: nil
        )

        do {
            _ = try await store.append([
                validFirst,
                ValidatedScoutEvent(envelope: invalidSecond),
            ])
            Issue.record("Expected batch failure")
        } catch let error as EventStoreError {
            #expect(error == .reduction(.unexpectedSequence(expected: 2, actual: 1)))
        }

        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == 0)
        #expect(await store.state(for: ScoutFixtures.sessionID) == nil)
    }

    @Test("Event IDs are globally unique")
    func duplicateEventID() async throws {
        let store = InMemoryEventStore()
        let first = try ScoutFixtures.sampleValidatedEvents()[0]
        _ = try await store.append(first)

        do {
            _ = try await store.append(first)
            Issue.record("Expected duplicate ID to fail")
        } catch let error as EventStoreError {
            #expect(error == .duplicateEventID(first.envelope.id))
        }
        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == 1)
    }

    @Test("Concurrent duplicate appends serialize safely")
    func concurrentAppend() async throws {
        let store = InMemoryEventStore()
        let event = try ScoutFixtures.sampleValidatedEvents()[0]

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    do {
                        _ = try await store.append(event)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }

        #expect(successes == 1)
        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == 1)
    }
}
