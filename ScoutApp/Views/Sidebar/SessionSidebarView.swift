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
            brand
            sessionList
            engineStatus
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
        .navigationSplitViewColumnWidth(min: 224, ideal: 248, max: 282)
        .accessibilityIdentifier("scout.sessionSidebar")
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ScoutBrandMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("SCOUT")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(ScoutColors.primaryText)
                Text("Discovery engine")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            Spacer()
            Button {
                workspace.beginNewDiscoverySession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                sidebarSectionHeader("NOW")
                sessionRow(workspace.sessions[0])

                sidebarSectionHeader("RECENT")
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
            .font(.system(size: 9, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(ScoutColors.secondaryText.opacity(0.72))
            .padding(.horizontal, 5)
            .padding(.bottom, 2)
    }

    private var engineStatus: some View {
        HStack(spacing: 9) {
            StatusDot(
                color: operationalStatus.tone.color,
                pulses: operationalStatus.pulses
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(operationalStatus.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(operationalStatus.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(operationalStatus.accessibilityLabel)
    }

    private var operationalStatus: SessionSidebarOperationalStatus {
        SessionSidebarOperationalStatus(workspace: workspace)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(session.status.color.opacity(isSelected ? 0.20 : 0.10))
                    .frame(width: 34, height: 34)
                Text(String(session.organization.prefix(1)))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(session.status.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(session.organization)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ScoutColors.primaryText)
                        .lineLimit(1)
                    if session.status == .live {
                        StatusDot(color: ScoutColors.mint, pulses: true)
                    }
                }
                Text(session.title)
                    .font(.system(size: 10))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.relativeDate)
                    Text("·")
                    Text("\(session.participantCount) people")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(session.status == .live ? ScoutColors.mint : ScoutColors.secondaryText.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(isSelected ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
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
