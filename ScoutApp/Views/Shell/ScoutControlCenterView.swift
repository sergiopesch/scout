import SwiftUI

struct ScoutControlCenterView: View {
    @Bindable var controller: ScoutController
    @Bindable var workspace: ScoutWorkspace
    @Bindable var capabilities: ScoutCapabilityBroker

    var body: some View {
        ZStack {
            ScoutAmbientBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    workspaceControls
                    windowControls
                    capabilityControls
                    trustBoundary
                }
                .padding(18)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("scout.controlCenter")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ScoutBrandMark(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("SCOUT CONTROLLER")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(ScoutColors.secondaryText)
                Text("See the state. Direct the work.")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(ScoutColors.primaryText)
            }
            Spacer()
            Label(
                workspace.captureState.label,
                systemImage: workspace.captureState == .listening ? "waveform" : "pause.fill"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                workspace.captureState == .listening ? ScoutColors.mint : ScoutColors.gold
            )
            .padding(.horizontal, 10)
            .frame(height: 30)
            .scoutChrome(cornerRadius: 10)
        }
        .padding(15)
        .scoutPanel(emphasized: true)
    }

    private var workspaceControls: some View {
        ControllerSection(
            eyebrow: "Workspace",
            title: "Tabs and live surfaces",
            trailing: "\(controller.openTabs.count) open · \(controller.minimizedTabs.count) minimized"
        ) {
            HStack(spacing: 9) {
                ForEach(ScoutSurface.allCases) { surface in
                    Button {
                        controller.open(surface)
                        workspace.destination = surface.destination
                        controller.focusWindow(.workspace)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: surface.symbol)
                                    .foregroundStyle(surface.tint)
                                Spacer()
                                if controller.selectedTabID == surface {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(ScoutColors.mint)
                                }
                            }
                            Text(surface.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(surface.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(ScoutColors.secondaryText)
                                .lineLimit(2)
                        }
                        .foregroundStyle(ScoutColors.primaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                        .background(
                            controller.selectedTabID == surface
                                ? ScoutColors.porcelain.opacity(0.08)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .scoutChrome(cornerRadius: 12)
                    .accessibilityIdentifier("scout.controlCenter.surface.\(surface.rawValue)")
                }
            }

            HStack(spacing: 8) {
                Toggle("Session sidebar", isOn: $controller.isSidebarVisible)
                Toggle("Evidence inspector", isOn: $controller.isInspectorVisible)
                Spacer()
                Button(workspace.captureState == .listening ? "Pause capture" : "Start capture") {
                    workspace.toggleCapture()
                }
                .buttonStyle(.borderedProminent)
                .tint(ScoutColors.mint)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.top, 2)
        }
    }

    private var windowControls: some View {
        ControllerSection(
            eyebrow: "Desktop",
            title: "Scout-owned windows",
            trailing: "Live lifecycle"
        ) {
            VStack(spacing: 7) {
                ForEach(ScoutWindowRole.allCases) { role in
                    let state = controller.windows[role] ?? ScoutManagedWindowState(role: role)
                    HStack(spacing: 10) {
                        Image(systemName: role.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(state.isOpen ? ScoutColors.mint : ScoutColors.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(
                                (state.isOpen ? ScoutColors.mint : ScoutColors.porcelain).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ScoutColors.primaryText)
                            Text(windowStatus(state))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(ScoutColors.secondaryText)
                        }
                        Spacer()
                        Button(state.isOpen ? "Focus" : "Open") {
                            state.isOpen
                                ? controller.focusWindow(role)
                                : controller.openWindow(role)
                        }
                        .controlSize(.small)
                        if state.isOpen {
                            Button {
                                controller.minimizeWindow(role)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .buttonStyle(.borderless)
                            .help("Minimize \(role.title)")
                            Button {
                                controller.closeWindow(role)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Close \(role.title)")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }
    }

    private var capabilityControls: some View {
        ControllerSection(
            eyebrow: "Permission preflight",
            title: "Optional macOS permissions",
            trailing: "Never prompted on launch"
        ) {
            VStack(spacing: 8) {
                ForEach(ScoutSystemCapability.allCases) { capability in
                    let status = capabilities.status(for: capability)
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: capability.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(status == .authorized ? ScoutColors.mint : ScoutColors.gold)
                            .frame(width: 32, height: 32)
                            .background(
                                (status == .authorized ? ScoutColors.mint : ScoutColors.gold).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capability.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ScoutColors.primaryText)
                            Text(capability.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(ScoutColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        if status == .authorized {
                            Label(status.label, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ScoutColors.mint)
                        } else {
                            Button("Review permission") {
                                capabilities.request(capability)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
        }
    }

    private var trustBoundary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(ScoutColors.mint)
            Text("Scout can operate its own registered tabs and windows. External screen observation requires a separate explicit grant. Accessibility here is permission preflight for future adapters only; Scout does not currently execute external Accessibility actions.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scoutChrome(cornerRadius: 12)
    }

    private func windowStatus(_ state: ScoutManagedWindowState) -> String {
        if !state.isOpen { return "Closed" }
        if state.isMinimized { return "Minimized" }
        if state.isKey { return "Focused" }
        return "Open"
    }
}

struct ScoutCommandPalette: View {
    @Bindable var controller: ScoutController
    @Bindable var workspace: ScoutWorkspace
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { controller.isCommandPalettePresented = false }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ScoutColors.secondaryText)
                    TextField("Direct Scout…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .focused($isSearchFocused)
                    Text("esc")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(ScoutColors.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                }
                .padding(.horizontal, 14)
                .frame(height: 48)

                Divider().overlay(ScoutColors.strokeStrong)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredCommands) { command in
                            Button {
                                command.action()
                                controller.isCommandPalettePresented = false
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: command.symbol)
                                        .frame(width: 26, height: 26)
                                        .foregroundStyle(command.tint)
                                        .background(command.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(command.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(ScoutColors.primaryText)
                                        Text(command.detail)
                                            .font(.system(size: 9))
                                            .foregroundStyle(ScoutColors.secondaryText)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 46)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
            }
            .frame(width: 520)
            .scoutChrome(cornerRadius: 16)
            .shadow(color: Color.black.opacity(0.46), radius: 36, y: 18)
            .offset(y: -80)
        }
        .onAppear { isSearchFocused = true }
        .onExitCommand { controller.isCommandPalettePresented = false }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .accessibilityIdentifier("scout.commandPalette")
    }

    private var filteredCommands: [Command] {
        guard !query.isEmpty else { return commands }
        return commands.filter {
            ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query)
        }
    }

    private var commands: [Command] {
        var values = ScoutSurface.allCases.map { surface in
            Command(
                id: "surface-\(surface.rawValue)",
                title: "Open \(surface.title)",
                detail: surface.subtitle,
                symbol: surface.symbol,
                tint: surface.tint
            ) {
                controller.open(surface)
                workspace.destination = surface.destination
            }
        }
        values += [
            Command(
                id: "capture",
                title: workspace.captureState == .listening ? "Pause listening" : "Start listening",
                detail: "Control live customer discovery capture",
                symbol: workspace.captureState == .listening ? "pause.fill" : "waveform",
                tint: ScoutColors.mint,
                action: workspace.toggleCapture
            ),
            Command(
                id: "import",
                title: "Import visual evidence",
                detail: "Normalize and inspect a whiteboard or architecture image",
                symbol: "photo.badge.plus",
                tint: ScoutColors.cyan,
                action: workspace.importVisualEvidence
            ),
            Command(
                id: "replay",
                title: "Replay demonstration",
                detail: "Reset and replay the bounded product tour",
                symbol: "arrow.counterclockwise",
                tint: ScoutColors.indigo,
                action: workspace.replayDemo
            ),
            Command(
                id: "controller-window",
                title: "Open Scout Controller window",
                detail: "Manage tabs, windows, and explicit capabilities",
                symbol: "slider.horizontal.3",
                tint: ScoutColors.porcelain
            ) {
                controller.openWindow(.controlCenter)
            },
        ]
        return values
    }

    private struct Command: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let action: () -> Void
    }
}

private struct ControllerSection<Content: View>: View {
    let eyebrow: String
    let title: String
    let trailing: String
    let content: Content

    init(
        eyebrow: String,
        title: String,
        trailing: String,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(ScoutColors.secondaryText)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ScoutColors.primaryText)
                }
                Spacer()
                Text(trailing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            content
        }
        .padding(14)
        .scoutPanel()
    }
}

private extension ScoutSurface {
    var subtitle: String {
        switch self {
        case .discovery: "Live model, transcript, and gap radar"
        case .evidence: "Claims, sources, and visual review"
        case .actionPack: "Proof of value and Codex handoff"
        }
    }

    var tint: Color {
        switch self {
        case .discovery: ScoutColors.mint
        case .evidence: ScoutColors.cyan
        case .actionPack: ScoutColors.gold
        }
    }
}
