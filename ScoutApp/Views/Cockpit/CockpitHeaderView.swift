import SwiftUI

struct CockpitHeaderView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ScoutSpacing.large) {
                sessionIdentity
                Spacer(minLength: 20)
                sessionMetrics
                captureControls
            }
            .padding(.horizontal, ScoutSpacing.large)
            .padding(.top, 14)
            .padding(.bottom, 12)

            HStack(spacing: 4) {
                ForEach(WorkspaceDestination.allCases) { destination in
                    destinationButton(destination)
                }
                Spacer()
                Label("Every claim links to source", systemImage: "link")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
                if let liveError = workspace.liveError {
                    Label(liveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ScoutColors.coral)
                        .lineLimit(1)
                        .accessibilityIdentifier("scout.live.error")
                }
            }
            .padding(.horizontal, ScoutSpacing.large)
            .padding(.bottom, 10)
        }
        .background(ScoutColors.sidebar.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ScoutColors.stroke).frame(height: 1)
        }
        // The live cockpit has several vertically ambitious child panes. Keep the session identity
        // and capture controls from being compressed away when the window is near its minimum size.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("scout.cockpitHeader")
    }

    private var sessionIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusDot(
                    color: workspace.captureState == .listening ? ScoutColors.mint : ScoutColors.gold,
                    pulses: workspace.captureState == .listening
                )
                Text(workspace.captureState.label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(workspace.captureState == .listening ? ScoutColors.mint : ScoutColors.gold)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(workspace.selectedSession.organization)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
                Text("/ \(workspace.selectedSession.title)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.selectedSession.organization), \(workspace.selectedSession.title), \(workspace.captureState.label)")
    }

    private var sessionMetrics: some View {
        HStack(spacing: 7) {
            MetricPill(symbol: "clock", value: workspace.elapsedLabel, label: "elapsed", tint: ScoutColors.cyan)
            MetricPill(
                symbol: "person.2",
                value: "\(Set(workspace.transcript.map(\.speaker.id)).count)",
                label: "speakers",
                tint: ScoutColors.indigo
            )
            MetricPill(
                symbol: "checkmark.shield",
                value: "\(Int(workspace.evidenceCoverage * 100))%",
                label: "grounded",
                tint: ScoutColors.mint
            )
        }
    }

    private var captureControls: some View {
        HStack(spacing: 8) {
            visualEvidenceButton
            ScoutIconButton(symbol: "arrow.counterclockwise", help: "Replay demonstration") {
                workspace.replayDemo()
            }
            audioSourceMenu
            captureButton
        }
    }

    private var visualEvidenceButton: some View {
        Button {
            workspace.importVisualEvidence()
        } label: {
            HStack(spacing: 6) {
                if workspace.visualEvidencePhase.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "photo.badge.plus")
                }
                Text(workspace.visualEvidencePhase.isWorking ? "Analyzing…" : "Import visual")
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(ScoutColors.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ScoutColors.strokeStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(workspace.visualEvidencePhase.isWorking)
        .help("Import a whiteboard, process sketch, or architecture image")
        .accessibilityLabel("Import whiteboard or image")
        .accessibilityIdentifier("scout.visualEvidence.import")
    }

    private var audioSourceMenu: some View {
        Menu {
            Section("Capture mode") {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Button {
                        workspace.selectAudioMode(mode)
                    } label: {
                        Label(mode.rawValue, systemImage: workspace.audioCaptureMode == mode ? "checkmark" : mode.symbol)
                    }
                }
            }

            if workspace.audioCaptureMode == .onlineMeeting {
                Section("Meeting audio source") {
                    if workspace.systemAudioSources.isEmpty {
                        Text(workspace.isRefreshingAudioSources ? "Finding sources…" : "No source selected")
                    } else {
                        ForEach(workspace.systemAudioSources) { source in
                            Button {
                                workspace.selectedSystemAudioSourceID = source.id
                            } label: {
                                Label(
                                    source.title,
                                    systemImage: workspace.selectedSystemAudioSourceID == source.id ? "checkmark" : source.kind.symbol
                                )
                            }
                        }
                    }

                    Divider()
                    Button {
                        workspace.refreshSystemAudioSources()
                    } label: {
                        Label("Refresh sources", systemImage: "arrow.clockwise")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: workspace.audioCaptureMode.symbol)
                Text(workspace.audioCaptureMode.shortLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(ScoutColors.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ScoutColors.strokeStrong, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(workspace.captureState == .listening || workspace.isRefreshingAudioSources)
        .help("Choose in-room or online meeting audio")
        .accessibilityIdentifier("scout.capture.source")
    }

    @ViewBuilder
    private var captureButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: workspace.toggleCapture) {
                captureButtonLabel
                    .foregroundStyle(ScoutColors.primaryText)
            }
            .buttonStyle(.glassProminent)
            .tint(ScoutColors.mint.opacity(0.72))
            .captureButtonAccessibility(workspace.captureState)
        } else {
            Button(action: workspace.toggleCapture) {
                captureButtonLabel
                    .foregroundStyle(ScoutColors.canvas)
                    .background(ScoutColors.mint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .captureButtonAccessibility(workspace.captureState)
        }
    }

    private var captureButtonLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: workspace.captureState == .listening ? "pause.fill" : "waveform")
            Text(workspace.captureState == .listening ? "Pause" : "Listen")
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .padding(.horizontal, 13)
        .frame(height: 30)
    }

    private func destinationButton(_ destination: WorkspaceDestination) -> some View {
        let isSelected = workspace.destination == destination
        return Button {
            workspace.destination = destination
        } label: {
            Label(destination.rawValue, systemImage: destination.symbol)
                .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? ScoutColors.primaryText : ScoutColors.secondaryText)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(isSelected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? ScoutColors.strokeStrong : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scout.destination.\(destination.rawValue)")
    }
}

private extension SystemAudioCaptureSource.Kind {
    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .application: "app"
        }
    }
}

private extension View {
    func captureButtonAccessibility(_ state: CaptureState) -> some View {
        keyboardShortcut(.space, modifiers: [.command])
            .accessibilityLabel(state == .listening ? "Pause live capture" : "Start live capture")
            .accessibilityIdentifier("scout.capture.toggle")
    }
}

#Preview("Cockpit header") {
    CockpitHeaderView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 1180)
        .background(ScoutColors.canvas)
        .preferredColorScheme(.dark)
}
