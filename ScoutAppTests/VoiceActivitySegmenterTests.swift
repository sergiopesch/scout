import Foundation
import XCTest
@testable import Scout

final class VoiceActivitySegmenterTests: XCTestCase {
    func testCommitsAfterSpeechAndTrailingSilence() {
        var segmenter = VoiceActivitySegmenter(
            minimumSpeechDuration: 0.1,
            trailingSilenceDuration: 0.2,
            maximumTurnDuration: 2,
            maximumIdleDuration: 1
        )

        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 12_000, duration: 0.12)), .continueBuffering)
        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 0, duration: 0.1)), .continueBuffering)
        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 0, duration: 0.12)), .commit)
    }

    func testClearsIdleAudioWithoutCreatingAnUtterance() {
        var segmenter = VoiceActivitySegmenter(
            maximumIdleDuration: 0.25
        )

        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 0, duration: 0.1)), .continueBuffering)
        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 0, duration: 0.16)), .clear)
    }

    func testMaximumTurnBoundsContinuousSpeech() {
        var segmenter = VoiceActivitySegmenter(
            minimumSpeechDuration: 0.05,
            maximumTurnDuration: 0.2
        )

        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 8_000, duration: 0.1)), .continueBuffering)
        XCTAssertEqual(segmenter.ingest(pcm16: pcm(amplitude: 8_000, duration: 0.11)), .commit)
    }

    private func pcm(amplitude: Int16, duration: TimeInterval, sampleRate: Int = 24_000) -> Data {
        let count = Int(Double(sampleRate) * duration)
        var data = Data(capacity: count * 2)
        let bits = UInt16(bitPattern: amplitude)
        for _ in 0..<count {
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
}
