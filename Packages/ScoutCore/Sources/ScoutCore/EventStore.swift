import Foundation

public struct AppendReceipt: Equatable, Sendable {
    public let sessionID: SessionID
    public let eventID: EventID
    public let sequence: EventSequence
    public let integrityHash: SHA256Digest

    public init(event: ScoutEventEnvelope) {
        sessionID = event.sessionID
        eventID = event.id
        sequence = event.sequence
        integrityHash = event.integrityHash
    }
}

public enum EventStoreError: Error, Equatable, Sendable {
    case duplicateEventID(EventID)
    case reduction(ScoutReducerError)
}

/// Actor-isolated append-only store suitable for previews, tests, and a local
/// session runtime. Batch appends are validated against cloned value state and
/// committed atomically only after every event reduces successfully.
public actor InMemoryEventStore {
    private var streams: [SessionID: [ScoutEventEnvelope]] = [:]
    private var states: [SessionID: ScoutState] = [:]
    private var eventIDs: Set<EventID> = []

    public init() {}

    @discardableResult
    public func append(_ event: ScoutEventEnvelope) throws -> AppendReceipt {
        try append([event])[0]
    }

    @discardableResult
    public func append(_ events: [ScoutEventEnvelope]) throws -> [AppendReceipt] {
        guard !events.isEmpty else { return [] }

        var candidateStreams = streams
        var candidateStates = states
        var candidateEventIDs = eventIDs
        var receipts: [AppendReceipt] = []
        receipts.reserveCapacity(events.count)

        for event in events {
            guard candidateEventIDs.insert(event.id).inserted else {
                throw EventStoreError.duplicateEventID(event.id)
            }
            let current = candidateStates[event.sessionID] ?? ScoutState(sessionID: event.sessionID)
            do {
                let next = try ScoutGraphReducer.reduce(current, event: event)
                candidateStates[event.sessionID] = next
            } catch let error as ScoutReducerError {
                throw EventStoreError.reduction(error)
            }
            candidateStreams[event.sessionID, default: []].append(event)
            receipts.append(AppendReceipt(event: event))
        }

        streams = candidateStreams
        states = candidateStates
        eventIDs = candidateEventIDs
        return receipts
    }

    public func events(
        for sessionID: SessionID,
        after sequence: EventSequence? = nil
    ) -> [ScoutEventEnvelope] {
        let events = streams[sessionID, default: []]
        guard let sequence else { return events }
        return events.filter { $0.sequence > sequence }
    }

    public func state(for sessionID: SessionID) -> ScoutState? {
        states[sessionID]
    }

    public func eventCount(for sessionID: SessionID) -> Int {
        streams[sessionID]?.count ?? 0
    }

    public func sessionIDs() -> [SessionID] {
        streams.keys.sorted()
    }
}
