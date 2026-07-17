import SwiftUI

struct ScoutRootView: View {
    @Bindable var workspace: ScoutWorkspace
    let journal: LiveEventJournal?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(workspace: ScoutWorkspace, journal: LiveEventJournal? = nil) {
        self.workspace = workspace
        self.journal = journal
    }

    var body: some View {
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
            .background(ScoutColors.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .onChange(of: workspace.selectedSessionID) { _, newValue in
            if newValue != workspace.sessions[0].id {
                workspace.pauseDemo()
            }
        }
    }

    @ViewBuilder
    private var activeWorkspace: some View {
        VStack(spacing: 0) {
            CockpitHeaderView(workspace: workspace)
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

private struct ArchivedSessionView: View {
    let session: SessionSummary
    let returnToLive: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(session.status.color.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: session.status == .ready ? "shippingbox.fill" : "archivebox.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(session.status.color)
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
    ScoutRootView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 1440, height: 900)
}
