import Foundation
import Observation

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
    private let microphone: MicrophoneAudioCapture
    @ObservationIgnored
    private let systemAudio: SystemAudioCapture
    @ObservationIgnored
    private let microphoneRealtime: RealtimeTranscriptionClient
    @ObservationIgnored
    private let systemRealtime: RealtimeTranscriptionClient
    @ObservationIgnored
    private let journal: LiveEventJournal
    @ObservationIgnored
    private let diarization: DiarizationClient
    @ObservationIgnored
    private let claimExtraction: ClaimExtractionClient
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
    private var captureGeneration: UInt64 = 0
    private var microphoneConnected = false
    private var systemRealtimeConnected = false
    private var isStopping = false
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
        microphone: MicrophoneAudioCapture = .init(),
        systemAudio: SystemAudioCapture = .init(),
        microphoneRealtime: RealtimeTranscriptionClient = .init(),
        systemRealtime: RealtimeTranscriptionClient = .init(),
        journal: LiveEventJournal = .init(),
        diarization: DiarizationClient = .init(),
        claimExtraction: ClaimExtractionClient = .init()
    ) {
        self.workspace = workspace
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.microphoneRealtime = microphoneRealtime
        self.systemRealtime = systemRealtime
        self.journal = journal
        self.diarization = diarization
        self.claimExtraction = claimExtraction
    }

    func install() {
        workspace?.liveCaptureToggle = { [weak self] in
            self?.toggleCapture()
        }
        workspace?.systemAudioRefresh = { [weak self] in
            Task { await self?.refreshSystemAudioSources() }
        }
    }

    func toggleCapture() {
        guard let workspace else { return }
        if workspace.captureState == .listening {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    func refreshSystemAudioSources() async {
        guard let workspace, !workspace.isRefreshingAudioSources else { return }
        workspace.isRefreshingAudioSources = true
        workspace.liveError = nil
        defer { workspace.isRefreshingAudioSources = false }

        do {
            let sources = try await systemAudio.shareableSources()
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
        guard microphoneAudioTask == nil,
              microphoneTranscriptTask == nil,
              systemAudioTask == nil,
              systemTranscriptTask == nil,
              elapsedTask == nil,
              !isStopping,
              let workspace
        else { return }

        workspace.pauseDemo()
        workspace.liveError = nil

        let capturesSystemAudio = workspace.audioCaptureMode == .onlineMeeting
        guard !capturesSystemAudio || workspace.selectedSystemAudioSource != nil else {
            workspace.captureState = .paused
            workspace.liveError = "Choose the meeting window or application before listening."
            if workspace.systemAudioSources.isEmpty {
                await refreshSystemAudioSources()
            }
            return
        }

        workspace.beginLiveSessionIfNeeded()

        workspace.captureState = .listening

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
            try await journal.prepareSession(
                sessionID: workspace.activeEvidenceSessionID,
                title: "\(workspace.selectedSession.organization) — \(workspace.selectedSession.title)",
                speakers: speakers
            )
        } catch {
            workspace.captureState = .paused
            workspace.liveError = "Event journal unavailable: \(error.localizedDescription)"
            return
        }

        let elapsedSeconds = max(0, workspace.elapsedSeconds)
        guard elapsedSeconds <= Int(Int64.max / 1_000) else {
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

        var systemFrames: AsyncThrowingStream<CapturedAudioFrame, Error>?
        var systemEvents: AsyncStream<RealtimeTranscriptEvent>?
        if capturesSystemAudio {
            systemFrames = systemAudio.frames()
            systemEvents = await systemRealtime.events()
        }

        do {
            try await microphoneRealtime.connect(language: "en")
            microphoneConnected = true
            try await microphone.start()

            if capturesSystemAudio, let source = workspace.selectedSystemAudioSource {
                try await systemRealtime.connect(language: "en")
                systemRealtimeConnected = true
                try await systemAudio.start(source: source)
            }
        } catch {
            workspace.liveError = error.localizedDescription
            await stop()
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

    func stop() async {
        guard let workspace, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        // Stop capture producers first. Their streams finish only after the last
        // captured frame has been yielded, so awaiting the producer tasks keeps
        // that immutable frame timing in the realtime client before commit.
        microphone.stop()
        systemAudio.stop()
        recordCaptureStop()
        elapsedTask?.cancel()
        elapsedTask = nil

        let microphoneProducer = microphoneAudioTask
        let systemProducer = systemAudioTask
        await microphoneProducer?.value
        await systemProducer?.value
        microphoneAudioTask = nil
        systemAudioTask = nil

        let shouldDrainMicrophone = microphoneConnected
        let shouldDrainSystem = systemRealtimeConnected
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
        workspace.captureState = .paused
        if !drainFailures.isEmpty {
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
        client: RealtimeTranscriptionClient,
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
            upsert(itemID, text: text, isFinal: false, channel: channel, startMilliseconds: nil)
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
                upsert(itemID, text: text, isFinal: true, channel: channel, startMilliseconds: nil)
                workspace.liveError = "A final transcript arrived without matching captured-audio timing; Scout left it uncommitted for review."
                return
            }

            upsert(
                itemID,
                text: text,
                isFinal: true,
                channel: channel,
                startMilliseconds: captureRange.start
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
        let utterance = TranscriptUtterance(
            id: index == 0 ? "realtime-\(itemID)" : "realtime-\(itemID)-segment-\(segment.id)",
            speaker: speaker,
            secondsFromStart: Int(exactly: startMilliseconds / 1_000) ?? 0,
            text: segment.text,
            provenance: .heard,
            confidence: 0.94,
            isFinal: true
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
                return
            } catch {
                guard coordinator.captureGeneration == generation,
                      coordinator.workspace?.activeEvidenceSessionID == sessionID
                else { return }
                coordinator.workspace?.liveError = "Transcript shown, but durable evidence failed: \(error.localizedDescription)"
            }
        }
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
        try await journal.recordClaimProjection(
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
        workspace.apply(projection)
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
        startMilliseconds: Int64?
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
            isFinal: isFinal
        )

        if let index = transcriptIndex[itemID], workspace.transcript.indices.contains(index) {
            workspace.transcript[index] = utterance
        } else {
            workspace.transcript.append(utterance)
            transcriptIndex[itemID] = workspace.transcript.endIndex - 1
        }
    }
}
