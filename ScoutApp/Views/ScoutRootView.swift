import SwiftUI

struct ScoutRootView: View {
    @Bindable var workspace: ScoutWorkspace
    @Bindable var controller: ScoutController
    let journal: LiveEventJournal?
    let windowRole: ScoutWindowRole
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        workspace: ScoutWorkspace,
        controller: ScoutController,
        journal: LiveEventJournal? = nil,
        windowRole: ScoutWindowRole = .workspace
    ) {
        self.workspace = workspace
        self.controller = controller
        self.journal = journal
        self.windowRole = windowRole
    }

    var body: some View {
        ZStack {
            ScoutAmbientBackdrop()

            VStack(spacing: 0) {
                ScoutControllerBar(
                    controller: controller,
                    workspace: workspace,
                    windowRole: windowRole
                )

                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SessionSidebarView(workspace: workspace)
                } detail: {
                    Group {
                        if workspace.activeSessionSelected {
                            activeWorkspace
                        } else {
                            ArchivedSessionView(session: workspace.selectedSession) {
                                workspace.selectedSessionID = workspace.sessions[0].id
                            }
                        }
                    }
                    .background(Color.clear)
                }
                .navigationSplitViewStyle(.balanced)
                .inspector(isPresented: inspectorBinding) {
                    ScoutInspectorContent(
                        workspace: workspace,
                        surface: controller.selectedSurface ?? .discovery
                    )
                        .inspectorColumnWidth(min: 320, ideal: 360, max: 440)
                        .background(.thinMaterial)
                        .background(ScoutColors.graphiteMid.opacity(0.20))
                }
            }

            if controller.isCommandPalettePresented {
                ScoutCommandPalette(controller: controller, workspace: workspace)
                    .zIndex(20)
            }
        }
        .preferredColorScheme(.dark)
        .tint(ScoutColors.porcelain)
        .onAppear {
            controller.synchronize(with: workspace.destination)
            columnVisibility = controller.isSidebarVisible ? .all : .detailOnly
        }
        .onChange(of: controller.selectedTabID) { _, selected in
            guard let selected else { return }
            workspace.destination = selected.destination
        }
        .onChange(of: workspace.destination) { _, destination in
            controller.synchronize(with: destination)
        }
        .onChange(of: controller.isSidebarVisible) { _, isVisible in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                columnVisibility = isVisible ? .all : .detailOnly
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            controller.isSidebarVisible = visibility != .detailOnly
        }
        .onChange(of: workspace.selectedSessionID) { _, newValue in
            if newValue != workspace.sessions[0].id {
                workspace.requestCaptureStopForArchiveNavigation()
            }
        }
    }

    @ViewBuilder
    private var activeWorkspace: some View {
        if controller.selectedSurface == nil {
            ScoutClosedTabsView(controller: controller, workspace: workspace)
        } else {
            VStack(spacing: 0) {
                CockpitHeaderView(workspace: workspace, showsDestinations: false)
                switch workspace.destination {
                case .discovery:
                    DiscoveryCockpitView(workspace: workspace)
                case .evidence:
                    EvidenceWorkspaceView(workspace: workspace)
                case .actionPack:
                    ActionPackView(workspace: workspace, journal: journal)
                }
            }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: {
                controller.isInspectorVisible
                    && controller.selectedSurface != .actionPack
                    && controller.selectedSurface != nil
            },
            set: { controller.isInspectorVisible = $0 }
        )
    }
}

private struct ScoutInspectorContent: View {
    enum Section: String, CaseIterable, Identifiable {
        case evidence = "Evidence"
        case gaps = "Gaps"

        var id: Self { self }
    }

    @Bindable var workspace: ScoutWorkspace
    let surface: ScoutSurface
    @State private var section: Section = .evidence

    var body: some View {
        VStack(spacing: 8) {
            if surface == .discovery {
                Picker("Inspector section", selection: $section) {
                    ForEach(Section.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            Group {
                if section == .gaps && surface == .discovery {
                    VStack(spacing: 10) {
                        ProactiveQuestionsView(workspace: workspace)
                            .frame(minHeight: 300, maxHeight: .infinity)
                        QuickWinsSummaryView(workspace: workspace)
                            .frame(minHeight: 126, idealHeight: 150)
                    }
                } else {
                    TrustInspectorView(workspace: workspace, compact: true)
                }
            }
            .padding(surface == .discovery ? 12 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("scout.inspector")
    }
}

private struct ScoutClosedTabsView: View {
    @Bindable var controller: ScoutController
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 16) {
            ScoutBrandMark(size: 72)
            Text("Your Scout workspace is clear")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(ScoutColors.primaryText)
            Text("Open a live surface or restore a minimized tab. Capture continues independently of presentation.")
                .font(.system(size: 12))
                .foregroundStyle(ScoutColors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            HStack(spacing: 8) {
                ForEach(ScoutSurface.allCases) { surface in
                    Button {
                        controller.open(surface)
                        workspace.destination = surface.destination
                    } label: {
                        Label(surface.title, systemImage: surface.symbol)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArchivedSessionView: View {
    let session: SessionSummary
    let returnToLive: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .bottomTrailing) {
                ScoutBrandMark(size: 74)
                Image(systemName: session.status == .ready ? "shippingbox.fill" : "archivebox.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ScoutColors.canvas)
                    .frame(width: 24, height: 24)
                    .background(session.status.color, in: Circle())
                    .overlay(Circle().stroke(ScoutColors.canvas, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            VStack(spacing: 6) {
                Text(session.organization)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
                Text(session.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                MetricPill(symbol: "clock", value: session.duration, label: "session")
                MetricPill(symbol: "person.2", value: "\(session.participantCount)", label: "speakers")
            }
            Button("Return to live discovery", action: returnToLive)
                .buttonStyle(.borderedProminent)
                .tint(ScoutColors.mint)
                .foregroundStyle(ScoutColors.canvas)
                .accessibilityIdentifier("scout.returnToLive")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [session.status.color.opacity(0.08), Color.clear],
                center: .center,
                startRadius: 10,
                endRadius: 360
            )
        )
    }
}

#Preview("Scout workspace") {
    ScoutRootView(
        workspace: ScoutWorkspace(completed: true),
        controller: ScoutController()
    )
        .frame(width: 1440, height: 900)
}
