import Foundation
@testable import Scout
import XCTest

final class RealtimeTranscriptionClientTests: XCTestCase {
    func testProductionTranscriptionModelUsesSupportedCurrentModel() {
        XCTAssertEqual(
            RealtimeTranscriptionClient.productionTranscriptionModel,
            "gpt-4o-mini-transcribe"
        )
    }

    func testRealtimeHandshakeWaitsForTranscriptionSessionAcceptance() throws {
        let created = try JSONSerialization.data(withJSONObject: [
            "type": "session.created",
            "session": ["type": "transcription"]
        ])
        let accepted = try JSONSerialization.data(withJSONObject: [
            "type": "session.updated",
            "session": ["type": "transcription"]
        ])
        let wrongSession = try JSONSerialization.data(withJSONObject: [
            "type": "session.updated",
            "session": ["type": "realtime"]
        ])
        let rejected = try JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["code": "invalid_value"]
        ])

        XCTAssertEqual(RealtimeSessionHandshake.disposition(for: created), .awaitingAcceptance)
        XCTAssertEqual(RealtimeSessionHandshake.disposition(for: accepted), .accepted)
        XCTAssertEqual(RealtimeSessionHandshake.disposition(for: wrongSession), .rejected)
        XCTAssertEqual(RealtimeSessionHandshake.disposition(for: rejected), .rejected)
    }

    func testCaptureAccumulatorPreservesExactFrameSpanAndPCMDuration() throws {
        var accumulator = RealtimeAudioCaptureAccumulator()

        try accumulator.append(frame(
            sequence: 7,
            capturedAt: 1_000_000_000,
            samples: 480
        ))
        try accumulator.append(frame(
            sequence: 9,
            capturedAt: 1_020_000_000,
            samples: 480
        ))

        XCTAssertEqual(accumulator.span, RealtimeAudioCaptureSpan(
            startUptimeNanoseconds: 980_000_000,
            endUptimeNanoseconds: 1_020_000_000,
            pcmDurationNanoseconds: 40_000_000
        ))
    }

    func testCaptureAccumulatorRoundsFractionalNanosecondsUpWithoutFloatingPoint() throws {
        var accumulator = RealtimeAudioCaptureAccumulator()
        try accumulator.append(frame(
            sequence: 0,
            capturedAt: 1_000_000_000,
            samples: 1
        ))

        XCTAssertEqual(accumulator.span?.startUptimeNanoseconds, 999_958_333)
        XCTAssertEqual(accumulator.span?.endUptimeNanoseconds, 1_000_000_000)
        XCTAssertEqual(accumulator.span?.pcmDurationNanoseconds, 41_667)
    }

    func testCaptureAccumulatorRejectsMalformedFramesWithoutNumericTrap() {
        var accumulator = RealtimeAudioCaptureAccumulator()

        XCTAssertThrowsError(try accumulator.append(.init(
            sequence: 0,
            capturedAtUptimeNanoseconds: 1,
            pcm16: Data(repeating: 0, count: 960),
            sampleRate: 24_000
        ))) { error in
            XCTAssertEqual(error as? RealtimeTranscriptionError, .invalidAudioFrame)
        }

        XCTAssertThrowsError(try accumulator.append(.init(
            sequence: 0,
            capturedAtUptimeNanoseconds: 1_000_000_000,
            pcm16: Data(repeating: 0, count: 3),
            sampleRate: 24_000
        ))) { error in
            XCTAssertEqual(error as? RealtimeTranscriptionError, .invalidAudioFrame)
        }

        XCTAssertThrowsError(try accumulator.append(.init(
            sequence: 0,
            capturedAtUptimeNanoseconds: 1_000_000_000,
            pcm16: Data(repeating: 0, count: 960),
            sampleRate: 48_000
        ))) { error in
            XCTAssertEqual(error as? RealtimeTranscriptionError, .invalidAudioFrame)
        }
    }

    func testSessionTimeMappingUsesCaptureClockAndNotTranscriptResponseTime() throws {
        let span = RealtimeAudioCaptureSpan(
            startUptimeNanoseconds: 10_250_400_000,
            endUptimeNanoseconds: 10_750_400_001,
            pcmDurationNanoseconds: 500_000_001
        )
        let clock = RealtimeSessionClock(
            originUptimeNanoseconds: 10_000_000_000,
            sessionOffsetMilliseconds: 42_000
        )

        let range = try XCTUnwrap(RealtimeSessionTimeMapper.sessionMilliseconds(for: span, clock: clock))

        XCTAssertEqual(range.start, 42_250)
        XCTAssertEqual(range.end, 42_751)
        XCTAssertEqual(RealtimeSessionTimeMapper.ceilMilliseconds(nanoseconds: 500_000_001), 501)
    }

    func testSessionTimeMappingFailsClosedOnOverflow() {
        let span = RealtimeAudioCaptureSpan(
            startUptimeNanoseconds: 2_000_000,
            endUptimeNanoseconds: 3_000_000,
            pcmDurationNanoseconds: 1_000_000
        )
        let clock = RealtimeSessionClock(
            originUptimeNanoseconds: 1_000_000,
            sessionOffsetMilliseconds: Int64.max
        )

        XCTAssertNil(RealtimeSessionTimeMapper.sessionMilliseconds(for: span, clock: clock))
    }

    private func frame(sequence: UInt64, capturedAt: UInt64, samples: Int) -> CapturedAudioFrame {
        CapturedAudioFrame(
            sequence: sequence,
            capturedAtUptimeNanoseconds: capturedAt,
            pcm16: Data(repeating: 0, count: samples * MemoryLayout<Int16>.size),
            sampleRate: 24_000
        )
    }
}
