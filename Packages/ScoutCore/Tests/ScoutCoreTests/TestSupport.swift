import Foundation
@testable import ScoutCore

func testID<Tag: Sendable>(_ value: String) -> ScoutID<Tag> {
    try! ScoutID<Tag>(validating: value)
}

func testText(_ value: String) -> NonEmptyString {
    try! NonEmptyString(validating: value)
}

func timestamp(_ offset: Int64 = 0) -> ScoutTimestamp {
    ScoutTimestamp(millisecondsSinceUnixEpoch: 1_760_000_000_000 + offset)
}

func testSystemActor() -> EventActor {
    .system(component: testText("test-suite"))
}

func chainContinuing(after events: [ScoutEventEnvelope]) throws -> EventChainBuilder {
    let last = try requireLast(events)
    return EventChainBuilder(
        sessionID: last.sessionID,
        nextSequence: try last.sequence.successor(),
        previousHash: last.integrityHash
    )
}

private func requireLast(_ events: [ScoutEventEnvelope]) throws -> ScoutEventEnvelope {
    guard let last = events.last else { throw TestSupportError.emptyEvents }
    return last
}

private enum TestSupportError: Error {
    case emptyEvents
}
