import SwiftUI

struct SessionSidebarOperationalStatus: Equatable {
    enum Tone: Equatable {
        case coral
        case gold
        case mint
        case blue

        var color: Color {
            switch self {
            case .coral: ScoutColors.coral
            case .gold: ScoutColors.gold
            case .mint: ScoutColors.mint
            case .blue: ScoutColors.blue
            }
        }
    }

    let title: String
    let detail: String
    let tone: Tone
    let pulses: Bool

    var accessibilityLabel: String {
        "\(title). \(detail)"
    }

    @MainActor
    init(workspace: ScoutWorkspace) {
        pulses = workspace.captureState == .listening && !workspace.isDemoWorkspace

        if workspace.liveError != nil {
            title = "Attention required"
            detail = "Review the capture warning in the workspace"
            tone = .coral
        } else if workspace.isCaptureTransitioning {
            title = "Capture changing state"
            detail = "Waiting for capture services to finish safely"
            tone = .gold
        } else if workspace.isDemoWorkspace {
            title = "Fictional demo"
            detail = "No customer capture is active"
            tone = .gold
        } else if workspace.captureState == .listening {
            title = "Capture active"
            detail = "Audio capture and local journal are active"
            tone = .mint
        } else {
            title = "Local workspace ready"
            detail = "Capture starts only on explicit request"
            tone = .blue
        }
    }
}

struct SessionSidebarView: View {
    @Bindable var workspace: ScoutWorkspace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            sessionList
        }
        .background {
            if reduceTransparency {
                Rectangle().fill(ScoutColors.sidebar)
            } else {
                ZStack {
                    Rectangle().fill(.thinMaterial)
                    Rectangle().fill(ScoutColors.sidebar.opacity(0.66))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 270)
        .accessibilityIdentifier("scout.sessionSidebar")
    }

    private var sidebarHeader: some View {
        HStack(spacing: 9) {
            ScoutBrandMark(size: 24)
            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ScoutColors.primaryText)
            Spacer()
            Button {
                workspace.beginNewDiscoverySession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ScoutColors.primaryText)
            .disabled(workspace.captureState == .listening || workspace.isCaptureTransitioning)
            .help(workspace.captureState == .listening || workspace.isCaptureTransitioning
                ? "Pause capture before starting a new discovery session"
                : "Start a new discovery session")
            .accessibilityLabel("Start a new discovery session")
            .accessibilityIdentifier("scout.newSession")
        }
        .padding(.horizontal, 13)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                sidebarSectionHeader("Now")
                sessionRow(workspace.sessions[0])

                sidebarSectionHeader("Recent")
                    .padding(.top, 10)
                ForEach(workspace.sessions.dropFirst()) { session in
                    sessionRow(session)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.clear)
        .accessibilityLabel("Discovery sessions")
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        Button {
            workspace.selectedSessionID = session.id
        } label: {
            SessionRow(session: session, isSelected: workspace.selectedSessionID == session.id)
        }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("scout.session.\(session.id)")
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ScoutColors.secondaryText.opacity(0.72))
            .padding(.horizontal, 5)
            .padding(.bottom, 2)
    }

}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: session.status.color, pulses: session.status == .live)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.organization)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ScoutColors.primaryText)
                    .lineLimit(1)
                Text(session.title)
                    .font(.system(size: 10))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(2)
                Text("\(session.relativeDate) · \(session.participantCount)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(session.status == .live ? ScoutColors.mint : ScoutColors.secondaryText.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(isSelected ? Color.white.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? ScoutColors.strokeStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.organization), \(session.title), \(session.relativeDate)")
    }
}

#Preview("Session sidebar") {
    SessionSidebarView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 260, height: 760)
        .preferredColorScheme(.dark)
}
