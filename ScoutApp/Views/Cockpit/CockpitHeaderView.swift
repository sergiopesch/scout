import SwiftUI

struct CockpitHeaderView: View {
    @Bindable var workspace: ScoutWorkspace
    var showsDestinations = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ScoutSpacing.medium) {
                sessionIdentity
                    .layoutPriority(1)
                Spacer(minLength: 12)
                captureControls
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ScoutSpacing.large)
            .padding(.vertical, 9)

            if showsDestinations {
                HStack(spacing: 4) {
                    ForEach(WorkspaceDestination.allCases) { destination in
                        destinationButton(destination)
                    }
                    Spacer()
                }
                .padding(.horizontal, ScoutSpacing.large)
                .padding(.bottom, 10)
            }

            // Trust failures belong to the capture surface, not to optional navigation chrome.
            // Keep this visible in the production controller layout where destinations are hidden.
            if let liveError = workspace.liveError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(liveError)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ScoutColors.coral)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ScoutColors.coral.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ScoutColors.coral.opacity(0.26), lineWidth: 1)
                }
                .padding(.horizontal, ScoutSpacing.large)
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Scout capture warning: \(liveError)")
                .accessibilityIdentifier("scout.live.error")
            }
        }
        .background(ScoutColors.graphiteMid.opacity(0.16))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ScoutColors.stroke).frame(height: 1)
        }
        // The live cockpit has several vertically ambitious child panes. Keep the session identity
        // and capture controls from being compressed away when the window is near its minimum size.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("scout.cockpitHeader")
    }

    private var sessionIdentity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(workspace.selectedSession.organization)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
                .lineLimit(1)
            if workspace.isDemoWorkspace {
                Text("Demo")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(ScoutColors.gold)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(ScoutColors.gold.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(ScoutColors.gold.opacity(0.24), lineWidth: 1))
                    .accessibilityLabel("Fictional demo data")
                    .accessibilityIdentifier("scout.demo.badge")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(workspace.selectedSession.organization), \(workspace.selectedSession.title), "
                + "\(workspace.captureState.label)"
                + (workspace.isDemoWorkspace ? ", fictional demo data" : "")
        )
    }

    private var captureControls: some View {
        ScoutGlassGroup(spacing: 8) {
            HStack(spacing: 7) {
                audioSourceMenu
                captureButton
            }
        }
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
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(workspace.captureState == .listening || workspace.isRefreshingAudioSources)
        .help("Choose in-room or online meeting audio")
        .accessibilityIdentifier("scout.capture.source")
    }

    @ViewBuilder
    private var captureButton: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Button(action: workspace.toggleCapture) {
                captureButtonLabel
                    .foregroundStyle(ScoutColors.primaryText)
            }
            .buttonStyle(.glassProminent)
            .tint(ScoutColors.mint.opacity(0.72))
            .captureButtonAccessibility(workspace.captureState)
        } else {
            fallbackCaptureButton
        }
#else
        fallbackCaptureButton
#endif
    }

    private var fallbackCaptureButton: some View {
        Button(action: workspace.toggleCapture) {
            captureButtonLabel
                .foregroundStyle(ScoutColors.canvas)
                .background(ScoutColors.mint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .captureButtonAccessibility(workspace.captureState)
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
