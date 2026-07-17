import SwiftUI

@main
@MainActor
struct ScoutApp: App {
    @State private var workspace: ScoutWorkspace
    @State private var liveDiscovery: LiveDiscoveryCoordinator
    @State private var visualEvidence: VisualEvidenceCoordinator
    private let journal: LiveEventJournal

    init() {
        let workspace = ScoutWorkspace()
        let journal = LiveEventJournal()
        let liveDiscovery = LiveDiscoveryCoordinator(workspace: workspace, journal: journal)
        let visualEvidence = VisualEvidenceCoordinator(workspace: workspace, journal: journal)
        liveDiscovery.install()
        visualEvidence.install()
        self.journal = journal
        _workspace = State(initialValue: workspace)
        _liveDiscovery = State(initialValue: liveDiscovery)
        _visualEvidence = State(initialValue: visualEvidence)
    }

    var body: some Scene {
        WindowGroup {
            ScoutRootView(workspace: workspace, journal: journal)
                .frame(minWidth: 1_100, minHeight: 700)
                .task {
                    do {
                        guard workspace.captureState != .listening,
                              let state = try await journal.latestReplayState(),
                              let projection = WorkspaceStateProjector().project(state)
                        else { return }
                        workspace.applyReplayProjection(projection)
                    } catch {
                        workspace.liveError = "Scout could not restore the encrypted session journal: \(error.localizedDescription)"
                    }
                }
                .onDisappear {
                    Task { await liveDiscovery.stop() }
                    visualEvidence.cancel()
                }
        }
        .defaultSize(width: 1_460, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Discovery") {
                Button(workspace.captureState == .listening ? "Pause Listening" : "Start Listening") {
                    workspace.toggleCapture()
                }
                .keyboardShortcut(.space, modifiers: [.command])

                Button("Replay Demonstration") {
                    workspace.replayDemo()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Import Whiteboard or Image…") {
                    workspace.importVisualEvidence()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(workspace.visualEvidencePhase.isWorking)

                Divider()

                Picker("Workspace", selection: $workspace.destination) {
                    ForEach(WorkspaceDestination.allCases) { destination in
                        Label(destination.rawValue, systemImage: destination.symbol)
                            .tag(destination)
                    }
                }
            }
        }
    }
}
