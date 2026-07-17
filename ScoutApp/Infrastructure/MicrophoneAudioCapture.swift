@preconcurrency import AVFoundation
import Foundation

struct CapturedAudioFrame: Sendable {
    let sequence: UInt64
    let capturedAtUptimeNanoseconds: UInt64
    let pcm16: Data
    let sampleRate: Int
}

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case inputUnavailable
    case conversionUnavailable
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access was not granted."
        case .inputUnavailable: "No usable microphone input is available."
        case .conversionUnavailable: "Scout could not normalize microphone audio."
        case .alreadyRunning: "Microphone capture is already running."
        }
    }
}

/// Native microphone capture that emits 24 kHz mono signed PCM16 frames.
/// The OpenAI key and network transport remain outside this service.
final class MicrophoneAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var nextSequence: UInt64 = 0

    func frames() -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func start() async throws {
        guard await Self.requestPermission() else {
            throw AudioCaptureError.permissionDenied
        }

        try lock.withLock {
            guard engine == nil else { throw AudioCaptureError.alreadyRunning }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
                throw AudioCaptureError.inputUnavailable
            }
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
            ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AudioCaptureError.conversionUnavailable
            }

            input.installTap(onBus: 0, bufferSize: 1_920, format: sourceFormat) { [weak self] buffer, _ in
                guard let self,
                      let pcm = Self.convert(buffer, using: converter, targetFormat: targetFormat),
                      !pcm.isEmpty
                else { return }

                let frame = self.lock.withLock { () -> CapturedAudioFrame in
                    defer { self.nextSequence &+= 1 }
                    return CapturedAudioFrame(
                        sequence: self.nextSequence,
                        capturedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        pcm16: pcm,
                        sampleRate: 24_000
                    )
                }
                _ = self.lock.withLock {
                    self.continuation?.yield(frame)
                }
            }

            engine.prepare()
            try engine.start()
            self.engine = engine
        }
    }

    func stop() {
        let stopped: (AVAudioEngine?, AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?) = lock.withLock {
            let current = (engine, continuation)
            engine = nil
            continuation = nil
            nextSequence = 0
            return current
        }

        stopped.0?.inputNode.removeTap(onBus: 0)
        stopped.0?.stop()
        stopped.1?.finish()
    }

    private static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return source
        }

        guard conversionError == nil,
              status != .error,
              output.frameLength > 0
        else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard let first = buffers.first, let bytes = first.mData else { return nil }
        return Data(bytes: bytes, count: Int(first.mDataByteSize))
    }
}
