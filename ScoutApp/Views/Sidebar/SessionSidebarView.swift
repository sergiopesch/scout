import SwiftUI

struct SessionSidebarView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            brand
            sessionList
            engineStatus
        }
        .background(ScoutColors.sidebar)
        .navigationSplitViewColumnWidth(min: 224, ideal: 248, max: 282)
        .accessibilityIdentifier("scout.sessionSidebar")
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [ScoutColors.mint, ScoutColors.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ScoutColors.canvas)
            }
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
            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ScoutColors.primaryText)
            .help("Start a new discovery session")
            .accessibilityLabel("Start a new discovery session")
            .accessibilityIdentifier("scout.newSession")
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var sessionList: some View {
        List(selection: $workspace.selectedSessionID) {
            Section("NOW") {
                sessionRow(workspace.sessions[0])
            }
            Section("RECENT") {
                ForEach(workspace.sessions.dropFirst()) { session in
                    sessionRow(session)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityLabel("Discovery sessions")
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        SessionRow(session: session, isSelected: workspace.selectedSessionID == session.id)
            .tag(session.id)
            .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("scout.session.\(session.id)")
    }

    private var engineStatus: some View {
        HStack(spacing: 9) {
            StatusDot(color: ScoutColors.mint, pulses: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Engine healthy")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ScoutColors.primaryText)
                Text("Capture · Models · Local store")
                    .font(.system(size: 9))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            Spacer()
            Text("12 ms")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(ScoutColors.mint)
        }
        .padding(12)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scout engine healthy, twelve millisecond event latency")
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
