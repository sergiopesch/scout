import SwiftUI

@main
@MainActor
struct ScoutApp: App {
    @State private var workspace: ScoutWorkspace
    @State private var controller: ScoutController
    @State private var capabilities: ScoutCapabilityBroker
    @State private var liveDiscovery: LiveDiscoveryCoordinator
    @State private var visualEvidence: VisualEvidenceCoordinator
    @State private var claimReviews: ClaimReviewCoordinator
    private let journal: LiveEventJournal
    private let windowRegistry: ScoutWindowRegistry

    init() {
        let workspace = ScoutWorkspace()
        let journal = LiveEventJournal()
        let controller = ScoutController()
        let capabilities = ScoutCapabilityBroker()
        let liveDiscovery = LiveDiscoveryCoordinator(workspace: workspace, journal: journal)
        let visualEvidence = VisualEvidenceCoordinator(workspace: workspace, journal: journal)
        let claimReviews = ClaimReviewCoordinator(workspace: workspace, journal: journal)
        liveDiscovery.install()
        visualEvidence.install()
        claimReviews.install()
        self.journal = journal
        self.windowRegistry = ScoutWindowRegistry()
        _workspace = State(initialValue: workspace)
        _controller = State(initialValue: controller)
        _capabilities = State(initialValue: capabilities)
        _liveDiscovery = State(initialValue: liveDiscovery)
        _visualEvidence = State(initialValue: visualEvidence)
        _claimReviews = State(initialValue: claimReviews)
    }

    var body: some Scene {
        WindowGroup("Scout", id: ScoutWindowRole.workspace.sceneID) {
            ScoutRootView(
                workspace: workspace,
                controller: controller,
                journal: journal,
                windowRole: .workspace
            )
                .frame(minWidth: 1_100, minHeight: 700)
                .scoutSceneActions(controller: controller, registry: windowRegistry)
                .scoutWindowRegistration(
                    .workspace,
                    controller: controller,
                    registry: windowRegistry
                )
                .task {
                    await restoreJournalIfNeeded()
                }
        }
        .defaultSize(width: 1_460, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Focus Scout Workspace") {
                    controller.focusWindow(.workspace)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            SidebarCommands()
            InspectorCommands()

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

            CommandMenu("Scout Controller") {
                Button("Open Command Palette") {
                    controller.isCommandPalettePresented = true
                    controller.focusWindow(.workspace)
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Open Controller Window") {
                    controller.openWindow(.controlCenter)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                ForEach(ScoutWindowRole.allCases.filter { $0 != .workspace }) { role in
                    Button("Open \(role.title)") {
                        controller.openWindow(role)
                    }
                }
            }
        }

        Window("Scout Controller", id: ScoutWindowRole.controlCenter.sceneID) {
            ScoutControlCenterView(
                controller: controller,
                workspace: workspace,
                capabilities: capabilities
            )
            .frame(minWidth: 720, minHeight: 680)
            .scoutSceneActions(controller: controller, registry: windowRegistry)
            .scoutWindowRegistration(
                .controlCenter,
                controller: controller,
                registry: windowRegistry
            )
        }
        .defaultSize(width: 840, height: 820)

        Window("Live Transcript", id: ScoutWindowRole.transcript.sceneID) {
            ScoutDetachedWindow(
                eyebrow: "Live source",
                title: "Transcript",
                detail: "Diarised evidence updates while this window is open, minimized, or behind the workspace."
            ) {
                LiveTranscriptView(workspace: workspace)
            }
            .frame(minWidth: 620, minHeight: 460)
            .scoutSceneActions(controller: controller, registry: windowRegistry)
            .scoutWindowRegistration(
                .transcript,
                controller: controller,
                registry: windowRegistry
            )
        }
        .defaultSize(width: 780, height: 620)

        Window("Evidence Review", id: ScoutWindowRole.evidence.sceneID) {
            ScoutDetachedWindow(
                eyebrow: "Evidence",
                title: "Claims and source review",
                detail: "A live, evidence-linked projection of the append-only journal."
            ) {
                EvidenceWorkspaceView(workspace: workspace)
            }
            .frame(minWidth: 840, minHeight: 620)
            .scoutSceneActions(controller: controller, registry: windowRegistry)
            .scoutWindowRegistration(
                .evidence,
                controller: controller,
                registry: windowRegistry
            )
        }
        .defaultSize(width: 1_080, height: 760)

        Window("Action Pack", id: ScoutWindowRole.actionPack.sceneID) {
            ScoutDetachedWindow(
                eyebrow: "Build handoff",
                title: "Action Pack",
                detail: "Review the bounded, approved context before handing work to Codex."
            ) {
                ActionPackView(workspace: workspace, journal: journal)
            }
            .frame(minWidth: 900, minHeight: 650)
            .scoutSceneActions(controller: controller, registry: windowRegistry)
            .scoutWindowRegistration(
                .actionPack,
                controller: controller,
                registry: windowRegistry
            )
        }
        .defaultSize(width: 1_180, height: 800)
    }

    private func restoreJournalIfNeeded() async {
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
}

private struct ScoutDetachedWindow<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String
    let content: Content

    init(
        eyebrow: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        ZStack {
            ScoutAmbientBackdrop()
            VStack(spacing: 10) {
                HStack(spacing: 11) {
                    ScoutBrandMark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(eyebrow.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(ScoutColors.secondaryText)
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(ScoutColors.primaryText)
                    }
                    Spacer()
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 420, alignment: .trailing)
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 48)
                .scoutChrome(cornerRadius: 14)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(10)
        }
        .preferredColorScheme(.dark)
    }
}
