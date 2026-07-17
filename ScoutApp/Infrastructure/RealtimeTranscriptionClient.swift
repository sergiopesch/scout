import Foundation

/// Immutable timing derived at capture time. `capturedAtUptimeNanoseconds` on a
/// `CapturedAudioFrame` is treated as the end of that frame; the start is
/// derived from the exact PCM sample count. This monotonic span is carried with
/// the committed audio until the matching Realtime item completes.
struct RealtimeAudioCaptureSpan: Equatable, Sendable {
    let startUptimeNanoseconds: UInt64
    let endUptimeNanoseconds: UInt64
    let pcmDurationNanoseconds: UInt64
}

struct RealtimeTranscriptFragment: Equatable, Sendable {
    let itemID: String
    let text: String
    let pcm16: Data?
    let captureSpan: RealtimeAudioCaptureSpan?
}

enum RealtimeTranscriptEvent: Equatable, Sendable {
    case connected
    case delta(RealtimeTranscriptFragment)
    case completed(RealtimeTranscriptFragment)
    case recoverableError(String)
    case disconnected
}

enum RealtimeTranscriptionError: LocalizedError, Equatable, Sendable {
    case alreadyConnected
    case notConnected
    case bridgeRejectedConnection
    case invalidAudioFrame
    case connectionInterrupted
    case drainTimedOut(pendingTurns: Int)

    var errorDescription: String? {
        switch self {
        case .alreadyConnected: "The live transcript is already connected."
        case .notConnected: "The live transcript is not connected."
        case .bridgeRejectedConnection: "Scout Bridge rejected the live transcript connection."
        case .invalidAudioFrame: "Scout rejected an invalid or out-of-order captured audio frame."
        case .connectionInterrupted: "The live transcript connection ended before committed audio completed."
        case let .drainTimedOut(pendingTurns):
            "Timed out waiting for \(pendingTurns) committed audio turn(s) to finish transcribing."
        }
    }
}

/// Pure accumulator used by the realtime actor and unit tests. It never reads
/// the wall clock, so response latency cannot influence evidence timing.
struct RealtimeAudioCaptureAccumulator: Equatable, Sendable {
    private(set) var startUptimeNanoseconds: UInt64?
    private(set) var endUptimeNanoseconds: UInt64?
    private(set) var pcmDurationNanoseconds: UInt64 = 0

    var span: RealtimeAudioCaptureSpan? {
        guard let startUptimeNanoseconds, let endUptimeNanoseconds else { return nil }
        return .init(
            startUptimeNanoseconds: startUptimeNanoseconds,
            endUptimeNanoseconds: endUptimeNanoseconds,
            pcmDurationNanoseconds: pcmDurationNanoseconds
        )
    }

    mutating func append(_ frame: CapturedAudioFrame) throws {
        guard frame.sampleRate == 24_000,
              !frame.pcm16.isEmpty,
              frame.pcm16.count.isMultiple(of: MemoryLayout<Int16>.size)
        else { throw RealtimeTranscriptionError.invalidAudioFrame }

        let sampleCount = UInt64(frame.pcm16.count / MemoryLayout<Int16>.size)
        let (scaledSamples, scaledOverflow) = sampleCount.multipliedReportingOverflow(by: 1_000_000_000)
        guard !scaledOverflow else { throw RealtimeTranscriptionError.invalidAudioFrame }

        let sampleRate = UInt64(frame.sampleRate)
        let quotient = scaledSamples / sampleRate
        let remainder = scaledSamples % sampleRate
        let (durationNanoseconds, durationOverflow) = quotient.addingReportingOverflow(remainder == 0 ? 0 : 1)
        guard !durationOverflow,
              durationNanoseconds > 0,
              frame.capturedAtUptimeNanoseconds >= durationNanoseconds
        else { throw RealtimeTranscriptionError.invalidAudioFrame }

        let frameStart = frame.capturedAtUptimeNanoseconds - durationNanoseconds
        let (combinedDuration, combinedOverflow) = pcmDurationNanoseconds.addingReportingOverflow(durationNanoseconds)
        guard !combinedOverflow else { throw RealtimeTranscriptionError.invalidAudioFrame }

        startUptimeNanoseconds = min(startUptimeNanoseconds ?? frameStart, frameStart)
        endUptimeNanoseconds = max(endUptimeNanoseconds ?? frame.capturedAtUptimeNanoseconds, frame.capturedAtUptimeNanoseconds)
        pcmDurationNanoseconds = combinedDuration
    }

    mutating func reset() {
        startUptimeNanoseconds = nil
        endUptimeNanoseconds = nil
        pcmDurationNanoseconds = 0
    }
}

struct RealtimeSessionClock: Equatable, Sendable {
    let originUptimeNanoseconds: UInt64
    let sessionOffsetMilliseconds: Int64
}

enum RealtimeSessionTimeMapper {
    static func sessionMilliseconds(
        for span: RealtimeAudioCaptureSpan,
        clock: RealtimeSessionClock
    ) -> (start: Int64, end: Int64)? {
        guard span.endUptimeNanoseconds >= span.startUptimeNanoseconds,
              span.pcmDurationNanoseconds > 0,
              clock.sessionOffsetMilliseconds >= 0,
              span.endUptimeNanoseconds >= clock.originUptimeNanoseconds
        else { return nil }

        let boundedStart = max(span.startUptimeNanoseconds, clock.originUptimeNanoseconds)
        let startDelta = boundedStart - clock.originUptimeNanoseconds
        let endDelta = span.endUptimeNanoseconds - clock.originUptimeNanoseconds
        guard let startOffset = Int64(exactly: startDelta / 1_000_000),
              let endOffset = ceilMilliseconds(nanoseconds: endDelta)
        else { return nil }

        let (start, startOverflow) = clock.sessionOffsetMilliseconds.addingReportingOverflow(startOffset)
        let (end, endOverflow) = clock.sessionOffsetMilliseconds.addingReportingOverflow(endOffset)
        guard !startOverflow, !endOverflow, end >= start else { return nil }
        return (start, end)
    }

    static func ceilMilliseconds(nanoseconds: UInt64) -> Int64? {
        let quotient = nanoseconds / 1_000_000
        let remainder = nanoseconds % 1_000_000
        let (rounded, overflow) = quotient.addingReportingOverflow(remainder == 0 ? 0 : 1)
        guard !overflow else { return nil }
        return Int64(exactly: rounded)
    }
}

/// Owns the low-latency provisional transcript channel. Speaker attribution is
/// intentionally handled by the separate diarization refinement path.
actor RealtimeTranscriptionClient {
    private struct ClientEvent: Encodable {
        let type: String
        var audio: String?
        var session: SessionUpdate?

        struct SessionUpdate: Encodable {
            let type = "transcription"
            let audio: Audio

            struct Audio: Encodable {
                let input: Input

                struct Input: Encodable {
                    let format: Format
                    let transcription: Transcription

                    struct Format: Encodable {
                        let type = "audio/pcm"
                        let rate = 24_000
                    }

                    struct Transcription: Encodable {
                        let model = "gpt-realtime-whisper"
                        let language: String?
                        let delay = "low"
                    }
                }
            }
        }
    }

    private struct CommittedTurn: Equatable, Sendable {
        let pcm16: Data
        let captureSpan: RealtimeAudioCaptureSpan
    }

    private let configuration: BridgeConfiguration
    private let encoder = JSONEncoder()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private var streamID: UUID?
    private var segmenter = VoiceActivitySegmenter()
    private var currentTurnAudio = Data()
    private var currentTurnCapture = RealtimeAudioCaptureAccumulator()
    private var lastFrameSequence: UInt64?
    private var lastFrameTimestamp: UInt64?
    private var pendingCommittedTurns: [CommittedTurn] = []
    private var turnByItemID: [String: CommittedTurn] = [:]
    private var committedItemIDs: Set<String> = []
    private var connectionWasInterrupted = false
    private var activeAppendOperations = 0

    init(configuration: BridgeConfiguration = .fromEnvironment()) {
        self.configuration = configuration
    }

    func events() -> AsyncStream<RealtimeTranscriptEvent> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.streamID = identifier
            self.streamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.streamTerminated(identifier) }
            }
        }
    }

    func connect(language: String? = "en") async throws {
        guard socket == nil, activeAppendOperations == 0 else {
            throw RealtimeTranscriptionError.alreadyConnected
        }
        resetSessionState(keepingStream: true)

        let request = try await configuration.authorizedRequest(url: configuration.realtimeURL)
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()

        let input = ClientEvent.SessionUpdate.Audio.Input(
            format: .init(),
            transcription: .init(language: language)
        )
        try await send(.init(
            type: "session.update",
            session: .init(audio: .init(input: input))
        ))

        streamContinuation?.yield(.connected)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: task)
        }
    }

    func append(frame: CapturedAudioFrame) async throws {
        guard let appendSocket = socket else { throw RealtimeTranscriptionError.notConnected }
        guard lastFrameSequence.map({ frame.sequence > $0 }) ?? true,
              lastFrameTimestamp.map({ frame.capturedAtUptimeNanoseconds >= $0 }) ?? true
        else { throw RealtimeTranscriptionError.invalidAudioFrame }

        var updatedCapture = currentTurnCapture
        try updatedCapture.append(frame)

        activeAppendOperations += 1
        defer { activeAppendOperations -= 1 }
        try await send(.init(type: "input_audio_buffer.append", audio: frame.pcm16.base64EncodedString()))
        guard socket === appendSocket else { throw RealtimeTranscriptionError.notConnected }
        currentTurnAudio.append(frame.pcm16)
        currentTurnCapture = updatedCapture
        lastFrameSequence = frame.sequence
        lastFrameTimestamp = frame.capturedAtUptimeNanoseconds

        switch segmenter.ingest(pcm16: frame.pcm16) {
        case .continueBuffering:
            break
        case .commit:
            // Stage the immutable local turn before the awaited send. Actor
            // reentrancy can otherwise let a very fast server commitment arrive
            // before Scout has anything to associate with its item ID.
            try commitLocalAudio()
            try await send(.init(type: "input_audio_buffer.commit"))
        case .clear:
            try await send(.init(type: "input_audio_buffer.clear"))
            clearLocalTurn()
        }
    }

    func finishTurn() async throws {
        switch segmenter.finish() {
        case .commit:
            try commitLocalAudio()
            try await send(.init(type: "input_audio_buffer.commit"))
        case .clear:
            try await send(.init(type: "input_audio_buffer.clear"))
            clearLocalTurn()
        case .continueBuffering:
            break
        }
    }

    /// Commits the final local turn and waits only for the completions that
    /// correspond to audio Scout actually sent. The bounded wait keeps shutdown
    /// deterministic while allowing the receive loop to continue matching item
    /// IDs in the background.
    func finishAndDrain(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while activeAppendOperations > 0 {
            if connectionWasInterrupted {
                throw RealtimeTranscriptionError.connectionInterrupted
            }
            guard clock.now < deadline else {
                throw RealtimeTranscriptionError.drainTimedOut(
                    pendingTurns: max(1, unmatchedTurnCount)
                )
            }
            try await clock.sleep(for: .milliseconds(20))
        }

        try await finishTurn()

        while unmatchedTurnCount > 0 {
            if connectionWasInterrupted {
                throw RealtimeTranscriptionError.connectionInterrupted
            }
            guard clock.now < deadline else {
                throw RealtimeTranscriptionError.drainTimedOut(pendingTurns: unmatchedTurnCount)
            }
            try await clock.sleep(for: .milliseconds(20))
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let endingContinuation = streamContinuation
        streamContinuation = nil
        streamID = nil
        endingContinuation?.yield(.disconnected)
        endingContinuation?.finish()
        resetSessionState(keepingStream: false)
    }

    private var unmatchedTurnCount: Int {
        pendingCommittedTurns.count + turnByItemID.count
    }

    private func send(_ event: ClientEvent) async throws {
        guard let socket else { throw RealtimeTranscriptionError.notConnected }
        let payload = try encoder.encode(event)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw RealtimeTranscriptionError.bridgeRejectedConnection
        }
        try await socket.send(.string(text))
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard self.socket === socket else { return }
                let data: Data
                switch message {
                case let .data(value): data = value
                case let .string(value): data = Data(value.utf8)
                @unknown default: continue
                }
                processServerEvent(data)
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.socket === socket else { return }
            connectionWasInterrupted = true
            streamContinuation?.yield(.recoverableError("The live transcript connection was interrupted."))
            streamContinuation?.yield(.disconnected)
        }
    }

    private func streamTerminated(_ identifier: UUID) {
        guard streamID == identifier else { return }
        disconnect()
    }

    private func processServerEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        let itemID = object["item_id"] as? String ?? object["itemId"] as? String ?? "unknown"
        switch type {
        case "input_audio_buffer.committed":
            guard itemID != "unknown", !committedItemIDs.contains(itemID) else { return }
            committedItemIDs.insert(itemID)
            if !pendingCommittedTurns.isEmpty {
                turnByItemID[itemID] = pendingCommittedTurns.removeFirst()
            }
        case "conversation.item.input_audio_transcription.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                streamContinuation?.yield(.delta(.init(
                    itemID: itemID,
                    text: delta,
                    pcm16: nil,
                    captureSpan: nil
                )))
            }
        case "conversation.item.input_audio_transcription.completed":
            let transcript = object["transcript"] as? String ?? ""
            let turn = turnByItemID.removeValue(forKey: itemID)
            streamContinuation?.yield(.completed(.init(
                itemID: itemID,
                text: transcript,
                pcm16: turn?.pcm16,
                captureSpan: turn?.captureSpan
            )))
        case "error":
            streamContinuation?.yield(.recoverableError("OpenAI could not process part of the live audio."))
        default:
            break
        }
    }

    private func commitLocalAudio() throws {
        guard !currentTurnAudio.isEmpty else { return }
        guard let captureSpan = currentTurnCapture.span else {
            throw RealtimeTranscriptionError.invalidAudioFrame
        }
        pendingCommittedTurns.append(.init(pcm16: currentTurnAudio, captureSpan: captureSpan))
        clearLocalTurn()
    }

    private func clearLocalTurn() {
        currentTurnAudio.removeAll(keepingCapacity: true)
        currentTurnCapture.reset()
    }

    private func resetSessionState(keepingStream: Bool) {
        segmenter = VoiceActivitySegmenter()
        currentTurnAudio.removeAll(keepingCapacity: false)
        currentTurnCapture.reset()
        lastFrameSequence = nil
        lastFrameTimestamp = nil
        pendingCommittedTurns.removeAll(keepingCapacity: false)
        turnByItemID.removeAll(keepingCapacity: false)
        committedItemIDs.removeAll(keepingCapacity: false)
        connectionWasInterrupted = false
        if !keepingStream {
            streamContinuation = nil
        }
    }
}
