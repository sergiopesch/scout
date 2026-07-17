import Foundation

/// A deliberately small local turn segmenter for 24 kHz mono signed PCM16.
/// It never identifies speech content; it only decides when an OpenAI input buffer
/// should be committed or cleared.
struct VoiceActivitySegmenter: Sendable {
    enum Action: Equatable, Sendable {
        case continueBuffering
        case commit
        case clear
    }

    private let sampleRate: Int
    private let speechThresholdDBFS: Double
    private let minimumSpeechSamples: Int
    private let trailingSilenceSamples: Int
    private let maximumTurnSamples: Int
    private let maximumIdleSamples: Int

    private var bufferedSamples = 0
    private var voicedSamples = 0
    private var trailingUnvoicedSamples = 0
    private var hasSpeech = false

    init(
        sampleRate: Int = 24_000,
        speechThresholdDBFS: Double = -42,
        minimumSpeechDuration: TimeInterval = 0.24,
        trailingSilenceDuration: TimeInterval = 0.72,
        maximumTurnDuration: TimeInterval = 15,
        maximumIdleDuration: TimeInterval = 4
    ) {
        self.sampleRate = sampleRate
        self.speechThresholdDBFS = speechThresholdDBFS
        minimumSpeechSamples = Int(minimumSpeechDuration * Double(sampleRate))
        trailingSilenceSamples = Int(trailingSilenceDuration * Double(sampleRate))
        maximumTurnSamples = Int(maximumTurnDuration * Double(sampleRate))
        maximumIdleSamples = Int(maximumIdleDuration * Double(sampleRate))
    }

    mutating func ingest(pcm16 data: Data) -> Action {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return .continueBuffering }

        bufferedSamples += sampleCount
        let isVoiced = Self.dbfs(ofPCM16: data) >= speechThresholdDBFS

        if isVoiced {
            voicedSamples += sampleCount
            trailingUnvoicedSamples = 0
            if voicedSamples >= minimumSpeechSamples {
                hasSpeech = true
            }
        } else if hasSpeech {
            trailingUnvoicedSamples += sampleCount
        }

        if hasSpeech, trailingUnvoicedSamples >= trailingSilenceSamples {
            reset()
            return .commit
        }

        if hasSpeech, bufferedSamples >= maximumTurnSamples {
            reset()
            return .commit
        }

        if !hasSpeech, bufferedSamples >= maximumIdleSamples {
            reset()
            return .clear
        }

        return .continueBuffering
    }

    mutating func finish() -> Action {
        defer { reset() }
        return hasSpeech ? .commit : .clear
    }

    private mutating func reset() {
        bufferedSamples = 0
        voicedSamples = 0
        trailingUnvoicedSamples = 0
        hasSpeech = false
    }

    private static func dbfs(ofPCM16 data: Data) -> Double {
        guard data.count >= 2 else { return -.infinity }

        var sumOfSquares = 0.0
        var count = 0
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < bytes.count {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits)) / Double(Int16.max)
                sumOfSquares += sample * sample
                count += 1
                index += 2
            }
        }

        guard count > 0, sumOfSquares > 0 else { return -.infinity }
        let rootMeanSquare = sqrt(sumOfSquares / Double(count))
        return 20 * log10(rootMeanSquare)
    }
}
