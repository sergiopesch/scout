import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// A stable, sendable reference to content that ScreenCaptureKit can capture.
///
/// ScreenCaptureKit's shareable-content objects are snapshots. Scout stores only
/// their identifiers and resolves them against a fresh snapshot when capture
/// starts, so a closed or moved meeting window fails explicitly instead of
/// silently capturing something else.
enum SystemAudioSourceSelection: Hashable, Sendable {
    case display(displayID: UInt32)
    case window(windowID: UInt32)
    case application(processID: Int32, displayID: UInt32)

    fileprivate var stableID: String {
        switch self {
        case let .display(displayID):
            "display:\(displayID)"
        case let .window(windowID):
            "window:\(windowID)"
        case let .application(processID, displayID):
            "application:\(processID):\(displayID)"
        }
    }
}

/// Presentation metadata for a currently shareable system-audio source.
struct SystemAudioCaptureSource: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case display
        case window
        case application
    }

    let selection: SystemAudioSourceSelection
    let kind: Kind
    let title: String
    let subtitle: String?

    var id: String { selection.stableID }
}

enum SystemAudioCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case alreadyRunning
    case startCancelled
    case noShareableSources
    case sourceUnavailable(String)
    case missingScreenCaptureEntitlement
    case outputRegistrationFailed(String)
    case captureStartFailed(String)
    case captureStopped(String)
    case unsupportedAudioFormat
    case audioNormalizationFailed
    case frameConsumerAlreadyAttached

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording access was not granted. Enable Scout in System Settings > Privacy & Security > Screen & System Audio Recording; if you just granted it, restart Scout."
        case .alreadyRunning:
            "System audio capture is already running."
        case .startCancelled:
            "System audio capture was stopped before it finished starting."
        case .noShareableSources:
            "No displays, applications, or windows are currently available for system audio capture."
        case let .sourceUnavailable(sourceID):
            "The selected system audio source is no longer available (\(sourceID))."
        case .missingScreenCaptureEntitlement:
            "Scout is not permitted to use ScreenCaptureKit in its current signing configuration."
        case let .outputRegistrationFailed(reason):
            "Scout could not register the system audio output: \(reason)"
        case let .captureStartFailed(reason):
            "Scout could not start system audio capture: \(reason)"
        case let .captureStopped(reason):
            "System audio capture stopped unexpectedly: \(reason)"
        case .unsupportedAudioFormat:
            "The selected source produced an unsupported audio format."
        case .audioNormalizationFailed:
            "Scout could not normalize captured system audio to 24 kHz mono PCM16."
        case .frameConsumerAlreadyAttached:
            "Only one system audio frame consumer can be attached at a time."
        }
    }
}

/// Captures audio emitted by a selected macOS display, application, or window.
///
/// Only the `.audio` stream output is registered. Screen frames are never
/// delivered to Scout and no captured media is written to disk. Every emitted
/// frame is normalized to 24 kHz, mono, signed little-endian PCM16.
@available(macOS 15.0, *)
final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private static let targetSampleRate = 24_000

    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(
        label: "dev.scout.system-audio.samples",
        qos: .userInitiated
    )

    private var stream: SCStream?
    private var pendingStartID: UUID?
    private var selection: SystemAudioSourceSelection?
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var continuationID: UUID?
    private var nextSequence: UInt64 = 0
    private var lastTimestamp: UInt64 = 0

    var isRunning: Bool {
        lock.withLock { stream != nil }
    }

    var selectedSource: SystemAudioSourceSelection? {
        lock.withLock { selection }
    }

    /// Returns whether macOS has already authorized screen and system-audio
    /// capture. This check never prompts.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Presents the macOS Screen Recording consent prompt when necessary.
    /// macOS owns the prompt and its copy; Scout never attempts to infer consent.
    @MainActor
    static func requestScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    /// Enumerates immutable descriptors suitable for a source picker.
    /// Applications are associated with the display containing the largest area
    /// of one of their windows, which makes application filters deterministic.
    func shareableSources(requestPermission: Bool = true) async throws -> [SystemAudioCaptureSource] {
        try await Self.ensurePermission(requestIfNeeded: requestPermission)
        let content = try await Self.currentShareableContent()
        let sources = Self.makeSourceDescriptors(from: content)
        guard !sources.isEmpty else { throw SystemAudioCaptureError.noShareableSources }
        return sources
    }

    /// A single frame stream is supported so ordering, sequence numbers, and
    /// termination have one unambiguous consumer.
    func frames() -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { newContinuation in
            let subscriptionID = UUID()
            let accepted = lock.withLock { () -> Bool in
                guard continuation == nil else { return false }
                continuation = newContinuation
                continuationID = subscriptionID
                return true
            }

            guard accepted else {
                newContinuation.finish(throwing: SystemAudioCaptureError.frameConsumerAlreadyAttached)
                return
            }

            newContinuation.onTermination = { [weak self] _ in
                self?.frameConsumerTerminated(subscriptionID)
            }
        }
    }

    func start(source: SystemAudioCaptureSource) async throws {
        try await start(selection: source.selection)
    }

    func start(selection requestedSelection: SystemAudioSourceSelection) async throws {
        let startID = UUID()
        try lock.withLock {
            guard stream == nil, pendingStartID == nil else {
                throw SystemAudioCaptureError.alreadyRunning
            }
            pendingStartID = startID
        }

        do {
            try await Self.ensurePermission(requestIfNeeded: true)
            try ensureStartIsPending(startID)

            let content = try await Self.currentShareableContent()
            try ensureStartIsPending(startID)
            let filter = try Self.makeFilter(for: requestedSelection, content: content)
            let configuration = Self.makeConfiguration()
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)

            do {
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            } catch {
                throw Self.translate(
                    error,
                    fallback: .outputRegistrationFailed((error as NSError).localizedDescription)
                )
            }

            let accepted = lock.withLock { () -> Bool in
                guard pendingStartID == startID else { return false }
                pendingStartID = nil
                stream = newStream
                selection = requestedSelection
                nextSequence = 0
                lastTimestamp = 0
                return true
            }

            guard accepted else {
                try? newStream.removeStreamOutput(self, type: .audio)
                throw SystemAudioCaptureError.startCancelled
            }

            do {
                try await newStream.startCapture()
            } catch {
                discard(newStream)
                throw Self.translate(
                    error,
                    fallback: .captureStartFailed((error as NSError).localizedDescription)
                )
            }

            guard lock.withLock({ stream === newStream }) else {
                try? await newStream.stopCapture()
                throw SystemAudioCaptureError.startCancelled
            }
        } catch {
            lock.withLock {
                if pendingStartID == startID {
                    pendingStartID = nil
                }
            }
            throw error
        }
    }

    /// Stops capture and closes the current frame stream. Call `frames()` again
    /// before a later capture run.
    func stop() {
        let stopped: (
            SCStream?,
            AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
        ) = lock.withLock {
            let result = (stream, continuation)
            stream = nil
            pendingStartID = nil
            selection = nil
            continuation = nil
            continuationID = nil
            nextSequence = 0
            lastTimestamp = 0
            return result
        }

        if let stoppedStream = stopped.0 {
            stoppedStream.stopCapture()
        }
        stopped.1?.finish()
    }

    private func ensureStartIsPending(_ startID: UUID) throws {
        guard lock.withLock({ pendingStartID == startID }) else {
            throw SystemAudioCaptureError.startCancelled
        }
    }

    private func frameConsumerTerminated(_ subscriptionID: UUID) {
        let shouldStop = lock.withLock { () -> Bool in
            guard continuationID == subscriptionID else { return false }
            continuation = nil
            continuationID = nil
            return true
        }
        if shouldStop {
            stop()
        }
    }

    private func discard(_ discardedStream: SCStream) {
        let shouldStop = lock.withLock { () -> Bool in
            guard stream === discardedStream else { return false }
            stream = nil
            selection = nil
            nextSequence = 0
            lastTimestamp = 0
            return true
        }
        if shouldStop {
            discardedStream.stopCapture()
        }
    }

    private func emit(
        _ pcm16: Data,
        capturedAt candidateTimestamp: UInt64,
        from sourceStream: SCStream
    ) {
        let emission = lock.withLock { () -> (
            AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation,
            CapturedAudioFrame
        )? in
            guard stream === sourceStream, let continuation else { return nil }

            let timestamp: UInt64
            if candidateTimestamp > lastTimestamp {
                timestamp = candidateTimestamp
            } else if lastTimestamp < UInt64.max {
                timestamp = lastTimestamp + 1
            } else {
                timestamp = lastTimestamp
            }

            let frame = CapturedAudioFrame(
                sequence: nextSequence,
                capturedAtUptimeNanoseconds: timestamp,
                pcm16: pcm16,
                sampleRate: Self.targetSampleRate
            )
            nextSequence &+= 1
            lastTimestamp = timestamp
            return (continuation, frame)
        }
        if let emission {
            emission.0.yield(emission.1)
        }
    }

    private func fail(_ error: SystemAudioCaptureError, sourceStream: SCStream) {
        let failure: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation? = lock.withLock {
            guard stream === sourceStream else { return nil }
            stream = nil
            selection = nil
            let currentContinuation = continuation
            continuation = nil
            continuationID = nil
            return currentContinuation
        }

        guard let failure else { return }
        // Do not synchronously remove an output from inside its own sample
        // callback. Stopping and releasing the stream tears the output down
        // without risking a callback-queue deadlock.
        sourceStream.stopCapture()
        failure.finish(throwing: error)
    }
}

@available(macOS 15.0, *)
extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              lock.withLock({ self.stream === stream })
        else { return }

        let capturedAt = DispatchTime.now().uptimeNanoseconds
        do {
            let pcm16 = try Self.normalize(sampleBuffer)
            guard !pcm16.isEmpty else { return }
            emit(pcm16, capturedAt: capturedAt, from: stream)
        } catch let error as SystemAudioCaptureError {
            fail(error, sourceStream: stream)
        } catch {
            fail(.audioNormalizationFailed, sourceStream: stream)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let translated = Self.translate(
            error,
            fallback: .captureStopped((error as NSError).localizedDescription)
        )
        fail(translated, sourceStream: stream)
    }
}

@available(macOS 15.0, *)
private extension SystemAudioCapture {
    static func ensurePermission(requestIfNeeded: Bool) async throws {
        if CGPreflightScreenCaptureAccess() { return }
        guard requestIfNeeded,
              await requestScreenRecordingPermission()
        else { throw SystemAudioCaptureError.permissionDenied }
    }

    static func currentShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.current
        } catch {
            throw translate(
                error,
                fallback: .captureStartFailed((error as NSError).localizedDescription)
            )
        }
    }

    static func makeSourceDescriptors(from content: SCShareableContent) -> [SystemAudioCaptureSource] {
        let displays = content.displays.sorted { $0.displayID < $1.displayID }
        let fallbackDisplayID = displays.first(where: { CGDisplayIsMain($0.displayID) != 0 })?.displayID
            ?? displays.first?.displayID

        let displaySources = displays.map { display in
            let isMain = CGDisplayIsMain(display.displayID) != 0
            return SystemAudioCaptureSource(
                selection: .display(displayID: display.displayID),
                kind: .display,
                title: isMain ? "Main Display" : "Display \(display.displayID)",
                subtitle: "All system audio on this display"
            )
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let applications = content.applications
            .filter { $0.processID != currentProcessID }
            .sorted {
                let comparison = $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
                return comparison == .orderedSame ? $0.processID < $1.processID : comparison == .orderedAscending
            }

        let applicationSources = applications.compactMap { application -> SystemAudioCaptureSource? in
            guard let displayID = preferredDisplayID(
                for: application,
                windows: content.windows,
                displays: displays
            ) ?? fallbackDisplayID else { return nil }

            let bundleIdentifier = application.bundleIdentifier.isEmpty ? nil : application.bundleIdentifier
            return SystemAudioCaptureSource(
                selection: .application(processID: application.processID, displayID: displayID),
                kind: .application,
                title: application.applicationName,
                subtitle: bundleIdentifier
            )
        }

        let windowSources = content.windows
            .filter { window in
                window.windowID != 0
                    && window.frame.width > 0
                    && window.frame.height > 0
                    && window.owningApplication?.processID != currentProcessID
            }
            .sorted { lhs, rhs in
                let lhsOwner = lhs.owningApplication?.applicationName ?? ""
                let rhsOwner = rhs.owningApplication?.applicationName ?? ""
                if lhsOwner != rhsOwner {
                    return lhsOwner.localizedCaseInsensitiveCompare(rhsOwner) == .orderedAscending
                }
                let lhsTitle = lhs.title ?? ""
                let rhsTitle = rhs.title ?? ""
                if lhsTitle != rhsTitle {
                    return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
                }
                return lhs.windowID < rhs.windowID
            }
            .map { window in
                let owner = window.owningApplication?.applicationName
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return SystemAudioCaptureSource(
                    selection: .window(windowID: window.windowID),
                    kind: .window,
                    title: title.flatMap { $0.isEmpty ? nil : $0 } ?? owner ?? "Window \(window.windowID)",
                    subtitle: owner
                )
            }

        return displaySources + applicationSources + windowSources
    }

    static func preferredDisplayID(
        for application: SCRunningApplication,
        windows: [SCWindow],
        displays: [SCDisplay]
    ) -> UInt32? {
        let applicationWindows = windows.filter {
            $0.owningApplication?.processID == application.processID
        }
        guard !applicationWindows.isEmpty else { return nil }

        let scoredDisplays = displays.map { display in
            (displayID: display.displayID, area: intersectionArea(of: applicationWindows, with: display.frame))
        }
        guard let best = scoredDisplays.max(by: { $0.area < $1.area }), best.area > 0 else {
            return nil
        }
        return best.displayID
    }

    static func intersectionArea(of windows: [SCWindow], with displayFrame: CGRect) -> CGFloat {
        windows.reduce(0) { area, window in
            let intersection = window.frame.intersection(displayFrame)
            guard !intersection.isNull, !intersection.isInfinite else { return area }
            return area + intersection.width * intersection.height
        }
    }

    static func makeFilter(
        for selection: SystemAudioSourceSelection,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        switch selection {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw SystemAudioCaptureError.sourceUnavailable(selection.stableID)
            }
            return SCContentFilter(display: display, excludingWindows: [])

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw SystemAudioCaptureError.sourceUnavailable(selection.stableID)
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case let .application(processID, displayID):
            guard let application = content.applications.first(where: { $0.processID == processID }),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                throw SystemAudioCaptureError.sourceUnavailable(selection.stableID)
            }
            return SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )
        }
    }

    static func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = targetSampleRate
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false

        // ScreenCaptureKit requires visual capture configuration even when the
        // caller registers only an audio output. Keep that unused path minimal.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        return configuration
    }

    static func normalize(_ sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw SystemAudioCaptureError.unsupportedAudioFormat
        }

        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard inputFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(targetSampleRate),
                  channels: 1,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw SystemAudioCaptureError.unsupportedAudioFormat }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return Data() }

        return try sampleBuffer.withAudioBufferList(
            flags: .audioBufferListAssure16ByteAlignment
        ) { audioBufferList, _ in
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: audioBufferList.unsafePointer,
                deallocator: nil
            ), sampleCount <= Int(inputBuffer.frameCapacity)
            else { throw SystemAudioCaptureError.unsupportedAudioFormat }

            inputBuffer.frameLength = AVAudioFrameCount(sampleCount)
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(
                (Double(sampleCount) * ratio).rounded(.up)
            ) + 32
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else { throw SystemAudioCaptureError.audioNormalizationFailed }

            let converterInput = SystemAudioConverterInput(buffer: inputBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                converterInput.take(inputStatus: inputStatus)
            }

            guard conversionError == nil,
                  status != .error,
                  outputBuffer.frameLength > 0
            else { throw SystemAudioCaptureError.audioNormalizationFailed }

            let buffers = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
            guard buffers.count == 1,
                  let bytes = buffers[0].mData
            else { throw SystemAudioCaptureError.audioNormalizationFailed }

            let expectedByteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            guard expectedByteCount > 0,
                  expectedByteCount <= Int(buffers[0].mDataByteSize)
            else { throw SystemAudioCaptureError.audioNormalizationFailed }
            return Data(bytes: bytes, count: expectedByteCount)
        }
    }

    static func translate(
        _ error: any Error,
        fallback: SystemAudioCaptureError
    ) -> SystemAudioCaptureError {
        if let captureError = error as? SystemAudioCaptureError {
            return captureError
        }

        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return fallback }
        switch nsError.code {
        case -3801:
            return .permissionDenied
        case -3803:
            return .missingScreenCaptureEntitlement
        case -3813, -3814, -3815:
            return .noShareableSources
        default:
            return fallback
        }
    }
}

/// `AVAudioConverterInputBlock` is `@Sendable`, even though the converter calls
/// it synchronously. This box gives that callback a genuinely synchronized,
/// single-consumption input instead of capturing mutable local state or an
/// `AVAudioPCMBuffer` directly.
private final class SystemAudioConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !wasSupplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            wasSupplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
    }
}
