import Foundation
import Observation

protocol MicrophoneCaptureProviding: Sendable {
    func frames() -> AsyncThrowingStream<CapturedAudioFrame, Error>
    func start() async throws
    func stop()
}

extension MicrophoneAudioCapture: MicrophoneCaptureProviding {}

protocol SystemAudioCaptureProviding: Sendable {
    func shareableSources(requestPermission: Bool) async throws -> [SystemAudioCaptureSource]
    func frames() -> AsyncThrowingStream<CapturedAudioFrame, Error>
    func start(source: SystemAudioCaptureSource) async throws
    func stop()
}

extension SystemAudioCapture: SystemAudioCaptureProviding {}

protocol RealtimeTranscriptionProviding: Sendable {
    func events() async -> AsyncStream<RealtimeTranscriptEvent>
    func connect(language: String?) async throws
    func append(frame: CapturedAudioFrame) async throws
    func finishAndDrain(timeout: Duration) async throws
    func disconnect() async
}

extension RealtimeTranscriptionClient: RealtimeTranscriptionProviding {}

/// Serializes start/stop intent independently from the active capture generation. Stop must not
/// invalidate the active generation until buffered transcript completions have drained, but it must
/// make every suspended startup continuation stale immediately.
struct LiveCaptureLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case starting(UInt64)
        case listening(UInt64)
        case stopping(UInt64)
    }

    struct StopRequest: Equatable, Sendable {
        let token: UInt64
        let wasListening: Bool
    }

    private(set) var phase: Phase = .idle
    private var nextToken: UInt64 = 0

    mutating func beginStart() -> UInt64? {
        guard phase == .idle else { return nil }
        nextToken &+= 1
        phase = .starting(nextToken)
        return nextToken
    }

    func isStarting(_ token: UInt64) -> Bool {
        phase == .starting(token)
    }

    mutating func markListening(_ token: UInt64) -> Bool {
        guard isStarting(token) else { return false }
        phase = .listening(token)
        return true
    }

    mutating func beginStop() -> StopRequest? {
        let wasListening: Bool
        switch phase {
        case .idle, .stopping:
            return nil
        case .starting:
            wasListening = false
        case .listening:
            wasListening = true
        }
        nextToken &+= 1
        phase = .stopping(nextToken)
        return StopRequest(token: nextToken, wasListening: wasListening)
    }

    mutating func finishStop(_ token: UInt64) -> Bool {
        guard phase == .stopping(token) else { return false }
        phase = .idle
        return true
    }

    mutating func failStart(_ token: UInt64) -> Bool {
        guard isStarting(token) else { return false }
        phase = .idle
        return true
    }
}

@MainActor
@Observable
final class LiveDiscoveryCoordinator {
    private enum Channel: String {
        case microphone = "mic"
        case systemAudio = "system"
    }

    private weak var workspace: ScoutWorkspace?

    private struct PendingClaimExtraction {
        let sessionID: String
        let generation: UInt64
        let receipt: LiveEventJournal.FinalUtteranceReceipt
        let source: ClaimUtteranceSource
    }

    @ObservationIgnored
    private let microphone: any MicrophoneCaptureProviding
    @ObservationIgnored
    private let systemAudio: any SystemAudioCaptureProviding
    @ObservationIgnored
    private let microphoneRealtime: any RealtimeTranscriptionProviding
    @ObservationIgnored
    private let systemRealtime: any RealtimeTranscriptionProviding
    @ObservationIgnored
    private let journal: LiveEventJournal
    @ObservationIgnored
    private let diarization: DiarizationClient
    @ObservationIgnored
    private let claimExtraction: ClaimExtractionClient
    @ObservationIgnored
    private let prepareCaptureSession: @Sendable (
        _ sessionID: String,
        _ title: String,
        _ speakers: [LiveEventJournal.SpeakerDescriptor]
    ) async throws -> Void
    @ObservationIgnored
    private var startTransitionTask: Task<Void, Never>?
    @ObservationIgnored
    private var startTransitionToken: UInt64?
    @ObservationIgnored
    private var stopTransitionTask: Task<Void, Never>?
    @ObservationIgnored
    private var microphoneAudioTask: Task<Void, Never>?
    @ObservationIgnored
    private var microphoneTranscriptTask: Task<Void, Never>?
    @ObservationIgnored
    private var systemAudioTask: Task<Void, Never>?
    @ObservationIgnored
    private var systemTranscriptTask: Task<Void, Never>?
    @ObservationIgnored
    private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored
    private var claimExtractionTask: Task<Void, Never>?
    @ObservationIgnored
    private var backgroundWorkTasks: [UUID: Task<Void, Never>] = [:]

    private var pendingClaimExtractions: [PendingClaimExtraction] = []
    private var claimUtteranceWindows: [String: [ClaimExtractionUtterance]] = [:]
    private var isProcessingClaimExtractions = false
    private var latestAppliedClaimBoundary: [String: Int] = [:]

    private var provisionalText: [String: String] = [:]
    private var transcriptIndex: [String: Int] = [:]
    private var captureLifecycle = LiveCaptureLifecycle()
    private var captureGeneration: UInt64 = 0
    private var microphoneConnected = false
    private var systemRealtimeConnected = false
    private var activeRunClock: RealtimeSessionClock?
    private var activeRunSessionID: String?
    private var resumeOffsetMillisecondsBySession: [String: Int64] = [:]

    private let microphoneSpeaker = Speaker(
        id: "speaker-live-microphone",
        name: "In-room audio",
        role: "Microphone channel",
        initials: "IR",
        tone: .indigo
    )
    private let systemSpeaker = Speaker(
        id: "speaker-live-system",
        name: "Meeting speaker",
        role: "Identity resolving",
        initials: "MS",
        tone: .gold
    )

    init(
        workspace: ScoutWorkspace,
        microphone: any MicrophoneCaptureProviding = MicrophoneAudioCapture(),
        systemAudio: any SystemAudioCaptureProviding = SystemAudioCapture(),
        microphoneRealtime: any RealtimeTranscriptionProviding = RealtimeTranscriptionClient(),
        systemRealtime: any RealtimeTranscriptionProviding = RealtimeTranscriptionClient(),
        journal: LiveEventJournal = .init(),
        diarization: DiarizationClient = .init(),
        claimExtraction: ClaimExtractionClient = .init(),
        prepareCaptureSession: (@Sendable (
            _ sessionID: String,
            _ title: String,
            _ speakers: [LiveEventJournal.SpeakerDescriptor]
        ) async throws -> Void)? = nil
    ) {
        self.workspace = workspace
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.microphoneRealtime = microphoneRealtime
        self.systemRealtime = systemRealtime
        self.journal = journal
        self.diarization = diarization
        self.claimExtraction = claimExtraction
        self.prepareCaptureSession = prepareCaptureSession ?? { sessionID, title, speakers in
            try await journal.prepareSession(
                sessionID: sessionID,
                title: title,
                speakers: speakers
            )
        }
    }

    func install() {
        workspace?.liveCaptureToggle = { [weak self] in
            self?.toggleCapture()
        }
        workspace?.liveCaptureStopRequest = { [weak self] in
            _ = self?.scheduleStop()
        }
        workspace?.systemAudioRefresh = { [weak self] in
            Task { await self?.refreshSystemAudioSources() }
        }
    }

    func toggleCapture() {
        switch captureLifecycle.phase {
        case .idle:
            _ = scheduleStart()
        case .starting, .listening:
            _ = scheduleStop()
        case .stopping:
            break
        }
    }

    func refreshSystemAudioSources() async {
        guard let workspace, !workspace.isRefreshingAudioSources else { return }
        workspace.isRefreshingAudioSources = true
        workspace.liveError = nil
        defer { workspace.isRefreshingAudioSources = false }

        do {
            let sources = try await systemAudio.shareableSources(requestPermission: true)
            workspace.systemAudioSources = sources
            if let selected = workspace.selectedSystemAudioSourceID,
               !sources.contains(where: { $0.id == selected }) {
                workspace.selectedSystemAudioSourceID = nil
            }
        } catch {
            workspace.liveError = error.localizedDescription
        }
    }

    func start() async {
        guard let task = scheduleStart() else { return }
        await task.value
    }

    func stop() async {
        if let task = scheduleStop() {
            await task.value
        } else if case .stopping = captureLifecycle.phase {
            await stopTransitionTask?.value
        }
    }

    @discardableResult
    private func scheduleStart() -> Task<Void, Never>? {
        guard startTransitionTask == nil,
              stopTransitionTask == nil,
              microphoneAudioTask == nil,
              microphoneTranscriptTask == nil,
              systemAudioTask == nil,
              systemTranscriptTask == nil,
              elapsedTask == nil,
              let token = captureLifecycle.beginStart()
        else { return nil }
        workspace?.isCaptureTransitioning = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart(token: token)
            if self.startTransitionToken == token {
                self.startTransitionTask = nil
                self.startTransitionToken = nil
                if case .stopping = self.captureLifecycle.phase {
                    // The stop transition owns the final published state.
                } else {
                    self.workspace?.isCaptureTransitioning = false
                }
            }
        }
        startTransitionToken = token
        startTransitionTask = task
        return task
    }

    @discardableResult
    private func scheduleStop() -> Task<Void, Never>? {
        guard let request = captureLifecycle.beginStop() else { return nil }
        workspace?.isCaptureTransitioning = true
        let pendingStart = startTransitionTask
        pendingStart?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(request: request, pendingStart: pendingStart)
            if self.captureLifecycle.phase == .idle {
                self.stopTransitionTask = nil
            }
        }
        stopTransitionTask = task
        return task
    }

    private func performStart(token: UInt64) async {
        guard captureLifecycle.isStarting(token), let workspace else { return }

        workspace.pauseDemo()
        workspace.liveError = nil

        let capturesSystemAudio = workspace.audioCaptureMode == .onlineMeeting
        guard !capturesSystemAudio || workspace.selectedSystemAudioSource != nil else {
            _ = captureLifecycle.failStart(token)
            workspace.captureState = .paused
            workspace.liveError = "Choose the meeting window or application before listening."
            if workspace.systemAudioSources.isEmpty {
                await refreshSystemAudioSources()
            }
            return
        }

        workspace.beginLiveSessionIfNeeded()

        do {
            var speakers = [
                LiveEventJournal.SpeakerDescriptor(
                    id: microphoneSpeaker.id,
                    displayName: microphoneSpeaker.name,
                    role: microphoneSpeaker.role,
                    affiliation: .internalTeam
                )
            ]
            if capturesSystemAudio {
                speakers.append(.init(
                    id: systemSpeaker.id,
                    displayName: systemSpeaker.name,
                    role: systemSpeaker.role,
                    affiliation: .unknown
                ))
            }
            try await prepareCaptureSession(
                workspace.activeEvidenceSessionID,
                "\(workspace.selectedSession.organization) — \(workspace.selectedSession.title)",
                speakers
            )
        } catch {
            guard captureLifecycle.isStarting(token) else { return }
            _ = captureLifecycle.failStart(token)
            workspace.captureState = .paused
            workspace.liveError = "Event journal unavailable: \(error.localizedDescription)"
            return
        }
        guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }

        let elapsedSeconds = max(0, workspace.elapsedSeconds)
        guard elapsedSeconds <= Int(Int64.max / 1_000) else {
            _ = captureLifecycle.failStart(token)
            workspace.captureState = .paused
            workspace.liveError = "The session clock exceeded Scout's supported range."
            return
        }
        captureGeneration &+= 1
        let generation = captureGeneration
        let sessionID = workspace.activeEvidenceSessionID
        let displayedOffset = Int64(elapsedSeconds) * 1_000
        let trustedOffset = resumeOffsetMillisecondsBySession[sessionID] ?? displayedOffset
        let runClock = RealtimeSessionClock(
            originUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            sessionOffsetMilliseconds: trustedOffset
        )
        activeRunClock = runClock
        activeRunSessionID = sessionID

        let microphoneFrames = microphone.frames()
        let microphoneEvents = await microphoneRealtime.events()
        guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }

        var systemFrames: AsyncThrowingStream<CapturedAudioFrame, Error>?
        var systemEvents: AsyncStream<RealtimeTranscriptEvent>?
        if capturesSystemAudio {
            systemFrames = systemAudio.frames()
            systemEvents = await systemRealtime.events()
            guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }
        }

        do {
            try await microphoneRealtime.connect(language: "en")
            microphoneConnected = true
            guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }
            try await microphone.start()
            guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }

            if capturesSystemAudio, let source = workspace.selectedSystemAudioSource {
                try await systemRealtime.connect(language: "en")
                systemRealtimeConnected = true
                guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }
                try await systemAudio.start(source: source)
                guard captureLifecycle.isStarting(token), !Task.isCancelled else { return }
            }
        } catch {
            guard captureLifecycle.isStarting(token) else { return }
            guard let request = captureLifecycle.beginStop() else { return }
            await performStop(
                request: request,
                pendingStart: nil,
                startupError: error.localizedDescription
            )
            return
        }

        microphoneTranscriptTask = transcriptTask(
            events: microphoneEvents,
            channel: .microphone,
            generation: generation,
            runClock: runClock
        )
        microphoneAudioTask = audioTask(
            frames: microphoneFrames,
            client: microphoneRealtime,
            generation: generation
        )

        if let systemFrames, let systemEvents {
            systemTranscriptTask = transcriptTask(
                events: systemEvents,
                channel: .systemAudio,
                generation: generation,
                runClock: runClock
            )
            systemAudioTask = audioTask(
                frames: systemFrames,
                client: systemRealtime,
                generation: generation
            )
        }
        guard captureLifecycle.markListening(token) else { return }
        workspace.captureState = .listening
        elapsedTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      self.captureGeneration == generation,
                      self.workspace?.captureState == .listening
                else { return }
                self.workspace?.elapsedSeconds += 1
            }
        }
    }

    private func performStop(
        request: LiveCaptureLifecycle.StopRequest,
        pendingStart: Task<Void, Never>?,
        startupError: String? = nil
    ) async {
        guard let workspace else { return }

        // Stop capture producers first. Their streams finish only after the last
        // captured frame has been yielded, so awaiting the producer tasks keeps
        // that immutable frame timing in the realtime client before commit.
        microphone.stop()
        systemAudio.stop()
        if request.wasListening {
            recordCaptureStop()
        }
        elapsedTask?.cancel()
        elapsedTask = nil

        // A connect/start operation may ignore cancellation until its current system call returns.
        // Keep the lifecycle in `.stopping`, wait for that continuation to observe its stale token,
        // then stop both producers again before disconnecting. A newer start cannot interleave.
        await pendingStart?.value
        microphone.stop()
        systemAudio.stop()

        let microphoneProducer = microphoneAudioTask
        let systemProducer = systemAudioTask
        await microphoneProducer?.value
        await systemProducer?.value
        microphoneAudioTask = nil
        systemAudioTask = nil

        let shouldDrainMicrophone = request.wasListening && microphoneConnected
        let shouldDrainSystem = request.wasListening && systemRealtimeConnected
        let microphoneClient = microphoneRealtime
        let systemClient = systemRealtime
        let drainFailures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            if shouldDrainMicrophone {
                group.addTask {
                    do {
                        try await microphoneClient.finishAndDrain(timeout: .seconds(5))
                        return nil
                    } catch {
                        return "microphone: \(error.localizedDescription)"
                    }
                }
            }
            if shouldDrainSystem {
                group.addTask {
                    do {
                        try await systemClient.finishAndDrain(timeout: .seconds(5))
                        return nil
                    } catch {
                        return "meeting audio: \(error.localizedDescription)"
                    }
                }
            }

            var failures: [String] = []
            for await failure in group {
                if let failure { failures.append(failure) }
            }
            return failures.sorted()
        }

        await microphoneRealtime.disconnect()
        await systemRealtime.disconnect()
        microphoneConnected = false
        systemRealtimeConnected = false

        // `disconnect()` finishes (rather than discards) the AsyncStreams. Let
        // consumers drain every buffered completion before releasing them;
        // cancelling here could lose the final evidence event after the client
        // had already matched its item ID.
        await microphoneTranscriptTask?.value
        await systemTranscriptTask?.value
        microphoneTranscriptTask = nil
        systemTranscriptTask = nil
        if captureLifecycle.finishStop(request.token) {
            workspace.captureState = .paused
            workspace.isCaptureTransitioning = false
        }
        if let startupError {
            workspace.liveError = startupError
        } else if !drainFailures.isEmpty {
            workspace.liveError = "Capture stopped safely, but final transcript completion was incomplete (\(drainFailures.joined(separator: "; ")))."
        }
        activeRunClock = nil
        activeRunSessionID = nil
    }

    private func transcriptTask(
        events: AsyncStream<RealtimeTranscriptEvent>,
        channel: Channel,
        generation: UInt64,
        runClock: RealtimeSessionClock
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard let self, self.captureGeneration == generation else { return }
                self.apply(event, channel: channel, generation: generation, runClock: runClock)
            }
        }
    }

    private func audioTask(
        frames: AsyncThrowingStream<CapturedAudioFrame, Error>,
        client: any RealtimeTranscriptionProviding,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await frame in frames {
                    guard !Task.isCancelled,
                          let self,
                          self.captureGeneration == generation
                    else { return }
                    try await client.append(frame: frame)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.captureGeneration == generation else { return }
                self.workspace?.liveError = "Live audio stopped before the session ended."
                Task { [weak self] in await self?.stop() }
            }
        }
    }

    private func apply(
        _ event: RealtimeTranscriptEvent,
        channel: Channel,
        generation: UInt64,
        runClock: RealtimeSessionClock
    ) {
        guard captureGeneration == generation, let workspace else { return }

        switch event {
        case .connected:
            workspace.liveError = nil
        case let .delta(fragment):
            let itemID = "\(channel.rawValue)-\(fragment.itemID)"
            let text = (provisionalText[itemID] ?? "") + fragment.text
            provisionalText[itemID] = text
            upsert(
                itemID,
                text: text,
                isFinal: false,
                channel: channel,
                startMilliseconds: nil,
                commitState: .pending,
                commitOperationID: itemID
            )
        case let .completed(fragment):
            let itemID = "\(channel.rawValue)-\(fragment.itemID)"
            let text = fragment.text.isEmpty ? provisionalText[itemID] ?? "" : fragment.text
            provisionalText.removeValue(forKey: itemID)
            guard let pcm16 = fragment.pcm16,
                  !pcm16.isEmpty,
                  let captureSpan = fragment.captureSpan,
                  let captureRange = RealtimeSessionTimeMapper.sessionMilliseconds(
                      for: captureSpan,
                      clock: runClock
                  )
            else {
                upsert(
                    itemID,
                    text: text,
                    isFinal: true,
                    channel: channel,
                    startMilliseconds: nil,
                    commitState: .uncommitted,
                    commitOperationID: nil
                )
                workspace.liveError = "A final transcript arrived without matching captured-audio timing; Scout left it uncommitted for review."
                return
            }

            upsert(
                itemID,
                text: text,
                isFinal: true,
                channel: channel,
                startMilliseconds: captureRange.start,
                commitState: .pending,
                commitOperationID: itemID
            )
            let sessionID = workspace.activeEvidenceSessionID
            resumeOffsetMillisecondsBySession[sessionID] = max(
                resumeOffsetMillisecondsBySession[sessionID] ?? 0,
                captureRange.end
            )
            // Commit the direct realtime evidence immediately. Diarization is
            // a later append-only revision and cannot delay or replace it.
            persist(
                itemID: itemID,
                text: text,
                speaker: baseSpeaker(for: channel),
                confidenceBasisPoints: 9_000,
                startMilliseconds: captureRange.start,
                endMilliseconds: captureRange.end,
                source: .realtime,
                generation: generation
            )
            refineAndPersist(
                itemID: itemID,
                pcm16: pcm16,
                captureSpan: captureSpan,
                captureRange: captureRange,
                channel: channel,
                generation: generation
            )
        case let .recoverableError(message):
            workspace.liveError = message
        case .disconnected:
            break
        }
    }

    private func refineAndPersist(
        itemID: String,
        pcm16: Data,
        captureSpan: RealtimeAudioCaptureSpan,
        captureRange: (start: Int64, end: Int64),
        channel: Channel,
        generation: UInt64
    ) {
        let sessionID = workspace?.activeEvidenceSessionID
        launchBackgroundWork { coordinator in
            do {
                let proposal = try await coordinator.diarization.refine(pcm16: pcm16)
                guard coordinator.captureGeneration == generation,
                      coordinator.workspace?.activeEvidenceSessionID == sessionID
                else { return }
                let usableSegments = proposal.segments.filter {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !usableSegments.isEmpty else { return }

                guard let pcmDurationMilliseconds = RealtimeSessionTimeMapper.ceilMilliseconds(
                    nanoseconds: captureSpan.pcmDurationNanoseconds
                ) else { return }
                let (pcmEnd, pcmEndOverflow) = captureRange.start.addingReportingOverflow(pcmDurationMilliseconds)
                guard !pcmEndOverflow else { return }
                let maximumSegmentEnd = min(captureRange.end, pcmEnd)

                for (index, segment) in usableSegments.enumerated() {
                    guard let relativeStart = Self.safeMilliseconds(seconds: segment.start, rounding: .down),
                          let relativeEnd = Self.safeMilliseconds(seconds: segment.end, rounding: .up)
                    else { return }
                    let (unboundedStart, startOverflow) = captureRange.start.addingReportingOverflow(relativeStart)
                    let (unboundedEnd, endOverflow) = captureRange.start.addingReportingOverflow(relativeEnd)
                    guard !startOverflow, !endOverflow else { return }
                    let segmentStartMilliseconds = min(max(captureRange.start, unboundedStart), maximumSegmentEnd)
                    let segmentEndMilliseconds = min(
                        maximumSegmentEnd,
                        max(segmentStartMilliseconds, unboundedEnd)
                    )
                    let speaker = coordinator.diarizedSpeaker(label: segment.speaker, channel: channel)
                    coordinator.applyDiarizedSegment(
                        segment,
                        itemID: itemID,
                        index: index,
                        speaker: speaker,
                        startMilliseconds: segmentStartMilliseconds
                    )
                    coordinator.persist(
                        itemID: "\(itemID)-diarized-\(segment.id)",
                        text: segment.text,
                        speaker: speaker,
                        confidenceBasisPoints: 9_400,
                        startMilliseconds: segmentStartMilliseconds,
                        endMilliseconds: segmentEndMilliseconds,
                        source: .diarizationRevision,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard coordinator.captureGeneration == generation,
                      coordinator.workspace?.activeEvidenceSessionID == sessionID
                else { return }
                coordinator.workspace?.liveError = "Live transcript preserved; speaker refinement will need review."
            }
        }
    }

    private func applyDiarizedSegment(
        _ segment: DiarizationProposal.Segment,
        itemID: String,
        index: Int,
        speaker: Speaker,
        startMilliseconds: Int64
    ) {
        guard let workspace else { return }
        let commitOperationID = "\(itemID)-diarized-\(segment.id)"
        let utterance = TranscriptUtterance(
            id: index == 0 ? "realtime-\(itemID)" : "realtime-\(itemID)-segment-\(segment.id)",
            speaker: speaker,
            secondsFromStart: Int(exactly: startMilliseconds / 1_000) ?? 0,
            text: segment.text,
            provenance: .heard,
            confidence: 0.94,
            isFinal: true,
            commitState: .pending,
            commitOperationID: commitOperationID
        )

        if index == 0, let transcriptPosition = transcriptIndex[itemID], workspace.transcript.indices.contains(transcriptPosition) {
            workspace.transcript[transcriptPosition] = utterance
        } else if !workspace.transcript.contains(where: { $0.id == utterance.id }) {
            workspace.transcript.append(utterance)
        }
    }

    private func persist(
        itemID: String,
        text: String,
        speaker: Speaker,
        confidenceBasisPoints: Int,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        source: ClaimUtteranceSource,
        generation: UInt64
    ) {
        guard let workspace,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              startMilliseconds >= 0,
              endMilliseconds >= startMilliseconds
        else { return }
        let sessionID = workspace.activeEvidenceSessionID
        let sessionTitle = "\(workspace.selectedSession.organization) — \(workspace.selectedSession.title)"

        launchBackgroundWork { coordinator in
            do {
                try await coordinator.journal.prepareSession(
                    sessionID: sessionID,
                    title: sessionTitle,
                    speakers: [.init(
                        id: speaker.id,
                        displayName: speaker.name,
                        role: speaker.role,
                        affiliation: speaker.id == coordinator.microphoneSpeaker.id ? .internalTeam : .unknown
                    )]
                )
                let receipt = try await coordinator.journal.recordFinalUtterance(
                    sessionID: sessionID,
                    itemID: itemID,
                    speakerID: speaker.id,
                    text: text,
                    confidenceBasisPoints: confidenceBasisPoints,
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds
                )
                if coordinator.workspace?.activeEvidenceSessionID == sessionID {
                    coordinator.updateTranscriptCommitState(
                        operationID: itemID,
                        state: .committed
                    )
                }
                guard coordinator.captureGeneration == generation,
                      coordinator.workspace?.activeEvidenceSessionID == sessionID
                else { return }
                coordinator.enqueueClaimExtraction(
                    sessionID: sessionID,
                    generation: generation,
                    receipt: receipt,
                    source: source
                )
            } catch is CancellationError {
                if coordinator.workspace?.activeEvidenceSessionID == sessionID {
                    coordinator.updateTranscriptCommitState(
                        operationID: itemID,
                        state: .uncommitted
                    )
                }
                return
            } catch {
                if coordinator.workspace?.activeEvidenceSessionID == sessionID {
                    coordinator.updateTranscriptCommitState(
                        operationID: itemID,
                        state: .uncommitted
                    )
                }
                guard coordinator.captureGeneration == generation,
                      coordinator.workspace?.activeEvidenceSessionID == sessionID
                else { return }
                coordinator.workspace?.liveError = "Transcript shown, but durable evidence failed: \(error.localizedDescription)"
            }
        }
    }

    private func updateTranscriptCommitState(
        operationID: String,
        state: TranscriptCommitState
    ) {
        guard let workspace,
              let index = workspace.transcript.firstIndex(where: {
                  $0.commitOperationID == operationID
              })
        else { return }
        workspace.transcript[index].commitState = state
    }

    private func enqueueClaimExtraction(
        sessionID: String,
        generation: UInt64,
        receipt: LiveEventJournal.FinalUtteranceReceipt,
        source: ClaimUtteranceSource
    ) {
        guard captureGeneration == generation,
              workspace?.activeEvidenceSessionID == sessionID
        else { return }
        guard pendingClaimExtractions.count < 256 else {
            workspace?.liveError = "Evidence is safe, but live intelligence is behind; pause capture to let Scout catch up."
            return
        }
        pendingClaimExtractions.append(.init(
            sessionID: sessionID,
            generation: generation,
            receipt: receipt,
            source: source
        ))
        guard !isProcessingClaimExtractions else { return }
        isProcessingClaimExtractions = true
        claimExtractionTask = Task { [weak self] in
            await self?.processClaimExtractionQueue()
        }
    }

    private func processClaimExtractionQueue() async {
        defer {
            isProcessingClaimExtractions = false
            claimExtractionTask = nil
        }
        while !pendingClaimExtractions.isEmpty {
            let pending = pendingClaimExtractions.removeFirst()
            guard pending.generation == captureGeneration,
                  workspace?.activeEvidenceSessionID == pending.sessionID
            else { continue }
            do {
                try await processClaimExtraction(pending)
            } catch is CancellationError {
                return
            } catch {
                guard pending.generation == captureGeneration,
                      workspace?.activeEvidenceSessionID == pending.sessionID
                else { continue }
                workspace?.liveError = "Evidence is preserved; a live graph proposal failed closed and can be replayed."
            }
        }
    }

    private func processClaimExtraction(_ pending: PendingClaimExtraction) async throws {
        guard captureGeneration == pending.generation,
              workspace?.activeEvidenceSessionID == pending.sessionID
        else { return }
        let boundaryValue = pending.receipt.committedEvidenceBoundary.sequence.rawValue
        guard let eventBoundary = Int(exactly: boundaryValue),
              let startMilliseconds = Int(exactly: pending.receipt.startMilliseconds),
              let endMilliseconds = Int(exactly: pending.receipt.endMilliseconds),
              startMilliseconds >= 0,
              endMilliseconds >= startMilliseconds
        else {
            throw LiveIntelligenceError.numericBoundaryOverflow
        }

        let utterance = ClaimExtractionUtterance(
            utteranceID: pending.receipt.utteranceID.rawValue,
            evidenceID: pending.receipt.evidenceID.rawValue,
            speakerID: pending.receipt.speakerID.rawValue,
            text: pending.receipt.text,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            source: pending.source
        )
        var window = claimUtteranceWindows[pending.sessionID] ?? []
        window.removeAll { $0.utteranceID == utterance.utteranceID }
        window.append(utterance)
        window.sort {
            ($0.startMilliseconds, $0.utteranceID) < ($1.startMilliseconds, $1.utteranceID)
        }
        window = Self.boundedClaimWindow(window)
        claimUtteranceWindows[pending.sessionID] = window

        let request = ClaimExtractionRequest(
            sessionID: pending.sessionID,
            eventBoundary: eventBoundary,
            utterances: window
        )
        let result = try await claimExtraction.extract(request)
        guard captureGeneration == pending.generation,
              workspace?.activeEvidenceSessionID == pending.sessionID
        else { return }

        var speakerNames: [String: String] = [:]
        for transcriptItem in workspace?.transcript ?? [] {
            speakerNames[transcriptItem.speaker.id] = transcriptItem.speaker.name
        }
        let projection = try ClaimProposalProjector().project(
            result,
            for: request,
            speakerNamesByID: speakerNames
        )
        let commit = try await journal.recordClaimProjection(
            sessionID: pending.sessionID,
            projection: projection
        )
        guard captureGeneration == pending.generation,
              workspace?.activeEvidenceSessionID == pending.sessionID
        else { return }

        guard latestAppliedClaimBoundary[pending.sessionID, default: 0] <= request.eventBoundary else {
            return
        }
        latestAppliedClaimBoundary[pending.sessionID] = request.eventBoundary
        guard let workspace, workspace.activeEvidenceSessionID == pending.sessionID else { return }
        guard let canonicalProjection = WorkspaceStateProjector().project(commit.canonicalState) else {
            throw LiveIntelligenceError.missingCanonicalClaimProjection
        }
        workspace.applyCanonicalClaimProjection(canonicalProjection)
        workspace.refreshDerivedIntelligence()
    }

    private static func boundedClaimWindow(
        _ utterances: [ClaimExtractionUtterance]
    ) -> [ClaimExtractionUtterance] {
        var selected: [ClaimExtractionUtterance] = []
        var characterCount = 0
        for utterance in utterances.reversed() {
            let nextCount = characterCount + utterance.text.utf16.count
            guard selected.count < 24, nextCount <= 50_000 else { break }
            selected.append(utterance)
            characterCount = nextCount
        }
        return selected.reversed()
    }

    private enum LiveIntelligenceError: Error {
        case numericBoundaryOverflow
        case missingCanonicalClaimProjection
    }

    private func launchBackgroundWork(
        _ operation: @escaping @MainActor @Sendable (LiveDiscoveryCoordinator) async -> Void
    ) {
        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)
            self.backgroundWorkTasks.removeValue(forKey: identifier)
        }
        backgroundWorkTasks[identifier] = task
    }

    private func recordCaptureStop() {
        guard let runClock = activeRunClock,
              let sessionID = activeRunSessionID
        else { return }
        let stoppedAt = DispatchTime.now().uptimeNanoseconds
        guard stoppedAt >= runClock.originUptimeNanoseconds,
              let runDurationMilliseconds = RealtimeSessionTimeMapper.ceilMilliseconds(
                  nanoseconds: stoppedAt - runClock.originUptimeNanoseconds
              )
        else { return }
        let (sessionEnd, sessionEndOverflow) = runClock.sessionOffsetMilliseconds
            .addingReportingOverflow(runDurationMilliseconds)
        guard !sessionEndOverflow else { return }
        resumeOffsetMillisecondsBySession[sessionID] = max(
            resumeOffsetMillisecondsBySession[sessionID] ?? 0,
            sessionEnd
        )

        let secondsQuotient = sessionEnd / 1_000
        let secondsRemainder = sessionEnd % 1_000
        let (roundedSeconds, secondsOverflow) = secondsQuotient.addingReportingOverflow(
            secondsRemainder == 0 ? 0 : 1
        )
        if !secondsOverflow, let displayedSeconds = Int(exactly: roundedSeconds) {
            workspace?.elapsedSeconds = max(workspace?.elapsedSeconds ?? 0, displayedSeconds)
        }
    }

    private static func safeMilliseconds(
        seconds: Double,
        rounding rule: FloatingPointRoundingRule
    ) -> Int64? {
        // DiarizationClient already limits turns to one minute. This independent
        // bound makes the Double-to-Int conversion non-trapping even if that
        // adapter is replaced or compromised.
        guard seconds.isFinite, seconds >= 0, seconds <= 120 else { return nil }
        let milliseconds = (seconds * 1_000).rounded(rule)
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 120_000 else { return nil }
        return Int64(milliseconds)
    }

    private func baseSpeaker(for channel: Channel) -> Speaker {
        channel == .microphone ? microphoneSpeaker : systemSpeaker
    }

    private func diarizedSpeaker(label: String, channel: Channel) -> Speaker {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = clean.lowercased().hasPrefix("speaker") ? clean : "Speaker \(clean)"
        let slug = clean.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compactSlug = String(slug).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        let initials = displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        let toneSeed = clean.utf8.reduce(0) { ($0 + Int($1)) % 4 }
        let tone: SpeakerTone = [.indigo, .teal, .coral, .gold][toneSeed]
        return Speaker(
            id: "speaker-diarized-\(channel.rawValue)-\(compactSlug.isEmpty ? "unknown" : compactSlug)",
            name: displayName,
            role: "Diarized voice; identity unconfirmed",
            initials: initials.isEmpty ? "?" : initials,
            tone: tone
        )
    }

    private func upsert(
        _ itemID: String,
        text: String,
        isFinal: Bool,
        channel: Channel,
        startMilliseconds: Int64?,
        commitState: TranscriptCommitState,
        commitOperationID: String?
    ) {
        guard let workspace, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let secondsFromStart = startMilliseconds.flatMap { milliseconds in
            Int(exactly: milliseconds / 1_000)
        } ?? workspace.elapsedSeconds

        let utterance = TranscriptUtterance(
            id: "realtime-\(itemID)",
            speaker: channel == .microphone ? microphoneSpeaker : systemSpeaker,
            secondsFromStart: secondsFromStart,
            text: text,
            provenance: .heard,
            confidence: isFinal ? 0.90 : 0.65,
            isFinal: isFinal,
            commitState: commitState,
            commitOperationID: commitOperationID
        )

        if let index = transcriptIndex[itemID], workspace.transcript.indices.contains(index) {
            workspace.transcript[index] = utterance
        } else {
            workspace.transcript.append(utterance)
            transcriptIndex[itemID] = workspace.transcript.endIndex - 1
        }
    }
}
