import Foundation
import XCTest
@testable import Scout

@MainActor
final class LiveDiscoveryCoordinatorLifecycleTests: XCTestCase {
    func testStopDuringJournalPreparationPreventsCaptureFromStarting() async {
        let preparation = AsyncTestGate()
        let workspace = ScoutWorkspace()
        let microphone = TestMicrophoneCapture()
        let microphoneRealtime = TestRealtimeTranscription()
        let coordinator = LiveDiscoveryCoordinator(
            workspace: workspace,
            microphone: microphone,
            systemAudio: TestSystemAudioCapture(),
            microphoneRealtime: microphoneRealtime,
            systemRealtime: TestRealtimeTranscription(),
            prepareCaptureSession: { _, _, _ in await preparation.suspend() }
        )

        let starting = Task { await coordinator.start() }
        await preparation.waitUntilSuspended()
        let stopping = Task { await coordinator.stop() }
        await Task.yield()
        await preparation.resume()
        await starting.value
        await stopping.value

        let realtimeConnectCount = await microphoneRealtime.connectCount
        XCTAssertEqual(microphone.startCount, 0)
        XCTAssertEqual(realtimeConnectCount, 0)
        XCTAssertEqual(workspace.captureState, .paused)
    }

    func testArchiveNavigationStopsStartupBeforeListeningIsPublished() async {
        let preparation = AsyncTestGate()
        let workspace = ScoutWorkspace()
        let microphone = TestMicrophoneCapture()
        let microphoneRealtime = TestRealtimeTranscription()
        let coordinator = LiveDiscoveryCoordinator(
            workspace: workspace,
            microphone: microphone,
            systemAudio: TestSystemAudioCapture(),
            microphoneRealtime: microphoneRealtime,
            systemRealtime: TestRealtimeTranscription(),
            prepareCaptureSession: { _, _, _ in await preparation.suspend() }
        )
        coordinator.install()

        let starting = Task { await coordinator.start() }
        await preparation.waitUntilSuspended()
        XCTAssertEqual(workspace.captureState, .idle)
        XCTAssertTrue(workspace.isCaptureTransitioning)

        workspace.requestCaptureStopForArchiveNavigation()
        await Task.yield()
        await preparation.resume()
        await starting.value
        await coordinator.stop()

        let realtimeConnectCount = await microphoneRealtime.connectCount
        XCTAssertEqual(microphone.startCount, 0)
        XCTAssertEqual(realtimeConnectCount, 0)
        XCTAssertEqual(workspace.captureState, .paused)
    }

    func testConcurrentStartsActivateEachCaptureDependencyOnlyOnce() async {
        let preparation = AsyncTestGate()
        let workspace = ScoutWorkspace()
        let microphone = TestMicrophoneCapture()
        let microphoneRealtime = TestRealtimeTranscription()
        let coordinator = LiveDiscoveryCoordinator(
            workspace: workspace,
            microphone: microphone,
            systemAudio: TestSystemAudioCapture(),
            microphoneRealtime: microphoneRealtime,
            systemRealtime: TestRealtimeTranscription(),
            prepareCaptureSession: { _, _, _ in await preparation.suspend() }
        )

        let first = Task { await coordinator.start() }
        await preparation.waitUntilSuspended()
        let duplicate = Task { await coordinator.start() }
        await duplicate.value
        await preparation.resume()
        await first.value

        let realtimeConnectCount = await microphoneRealtime.connectCount
        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(realtimeConnectCount, 1)
        XCTAssertEqual(workspace.captureState, .listening)

        await coordinator.stop()
        XCTAssertEqual(workspace.captureState, .paused)
    }

    func testStopDuringRealtimeConnectRollsBackBeforeMicrophoneStarts() async {
        let connection = AsyncTestGate()
        let workspace = ScoutWorkspace()
        let microphone = TestMicrophoneCapture()
        let microphoneRealtime = TestRealtimeTranscription(connectGate: connection)
        let coordinator = LiveDiscoveryCoordinator(
            workspace: workspace,
            microphone: microphone,
            systemAudio: TestSystemAudioCapture(),
            microphoneRealtime: microphoneRealtime,
            systemRealtime: TestRealtimeTranscription(),
            prepareCaptureSession: { _, _, _ in }
        )

        let starting = Task { await coordinator.start() }
        await connection.waitUntilSuspended()
        let stopping = Task { await coordinator.stop() }
        await Task.yield()
        await connection.resume()
        await starting.value
        await stopping.value

        let realtimeConnectCount = await microphoneRealtime.connectCount
        let realtimeDisconnectCount = await microphoneRealtime.disconnectCount
        XCTAssertEqual(microphone.startCount, 0)
        XCTAssertEqual(realtimeConnectCount, 1)
        XCTAssertGreaterThanOrEqual(realtimeDisconnectCount, 1)
        XCTAssertEqual(workspace.captureState, .paused)
    }

    func testSystemAudioStartFailureRollsBackPartiallyStartedCapture() async {
        let workspace = ScoutWorkspace()
        let source = SystemAudioCaptureSource(
            selection: .display(displayID: 1),
            kind: .display,
            title: "Test display",
            subtitle: nil
        )
        workspace.audioCaptureMode = .onlineMeeting
        workspace.systemAudioSources = [source]
        workspace.selectedSystemAudioSourceID = source.id

        let microphone = TestMicrophoneCapture()
        let systemAudio = TestSystemAudioCapture(startError: TestCaptureError.startFailed)
        let microphoneRealtime = TestRealtimeTranscription()
        let systemRealtime = TestRealtimeTranscription()
        let coordinator = LiveDiscoveryCoordinator(
            workspace: workspace,
            microphone: microphone,
            systemAudio: systemAudio,
            microphoneRealtime: microphoneRealtime,
            systemRealtime: systemRealtime,
            prepareCaptureSession: { _, _, _ in }
        )

        await coordinator.start()

        let microphoneDisconnectCount = await microphoneRealtime.disconnectCount
        let systemDisconnectCount = await systemRealtime.disconnectCount
        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(systemAudio.startCount, 1)
        XCTAssertGreaterThanOrEqual(microphone.stopCount, 1)
        XCTAssertGreaterThanOrEqual(systemAudio.stopCount, 1)
        XCTAssertGreaterThanOrEqual(microphoneDisconnectCount, 1)
        XCTAssertGreaterThanOrEqual(systemDisconnectCount, 1)
        XCTAssertEqual(workspace.captureState, .paused)
        XCTAssertEqual(workspace.liveError, TestCaptureError.startFailed.localizedDescription)
    }
}

private enum TestCaptureError: LocalizedError {
    case startFailed

    var errorDescription: String? { "Test capture failed to start." }
}

private actor AsyncTestGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class TestMicrophoneCapture: MicrophoneCaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func frames() -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func start() async throws {
        lock.withLock { starts += 1 }
    }

    func stop() {
        let stream = lock.withLock { () -> AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation? in
            stops += 1
            defer { continuation = nil }
            return continuation
        }
        stream?.finish()
    }
}

private final class TestSystemAudioCapture: SystemAudioCaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var starts = 0
    private var stops = 0

    init(startError: Error? = nil) {
        self.startError = startError
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func shareableSources(requestPermission _: Bool) async throws -> [SystemAudioCaptureSource] {
        []
    }

    func frames() -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func start(source _: SystemAudioCaptureSource) async throws {
        lock.withLock { starts += 1 }
        if let startError { throw startError }
    }

    func stop() {
        let stream = lock.withLock { () -> AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation? in
            stops += 1
            defer { continuation = nil }
            return continuation
        }
        stream?.finish()
    }
}

private actor TestRealtimeTranscription: RealtimeTranscriptionProviding {
    private let connectGate: AsyncTestGate?
    private var continuation: AsyncStream<RealtimeTranscriptEvent>.Continuation?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(connectGate: AsyncTestGate? = nil) {
        self.connectGate = connectGate
    }

    func events() async -> AsyncStream<RealtimeTranscriptEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func connect(language _: String?) async throws {
        connectCount += 1
        if let connectGate { await connectGate.suspend() }
    }

    func append(frame _: CapturedAudioFrame) async throws {}

    func finishAndDrain(timeout _: Duration) async throws {}

    func disconnect() async {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }
}
