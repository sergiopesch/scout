import SwiftUI

struct ScoutControllerBar: View {
    @Bindable var controller: ScoutController
    @Bindable var workspace: ScoutWorkspace
    let windowRole: ScoutWindowRole

    var body: some View {
        ScoutGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                brand
                divider

                Button {
                    controller.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    controller.isSidebarVisible
                        ? ScoutColors.primaryText
                        : ScoutColors.secondaryText
                )
                .help(controller.isSidebarVisible ? "Hide session sidebar" : "Show session sidebar")
                .accessibilityIdentifier("scout.controller.sidebar")

                Button {
                    controller.toggleInspector()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    controller.isInspectorVisible
                        ? ScoutColors.primaryText
                        : ScoutColors.secondaryText
                )
                .help(controller.isInspectorVisible ? "Hide evidence inspector" : "Show evidence inspector")
                .accessibilityIdentifier("scout.controller.inspector")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(controller.openTabs) { tab in
                            ScoutTabButton(
                                tab: tab,
                                isSelected: controller.selectedTabID == tab.id,
                                select: {
                                    controller.select(tab.surface)
                                    workspace.destination = tab.surface.destination
                                },
                                minimize: { controller.minimize(tab.surface) },
                                close: { controller.close(tab.surface) },
                                detach: { controller.openWindow(tab.surface.windowRole) }
                            )
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)

                surfaceMenu

                if !controller.minimizedTabs.isEmpty {
                    minimizedTabs
                }

                Spacer(minLength: 12)

                liveState

                Button {
                    controller.isCommandPalettePresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "command")
                        Text("Control")
                        Text("K")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(ScoutColors.secondaryText)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: [.command])
                .help("Open Scout Controller")
                .accessibilityIdentifier("scout.controller.palette")

                Button {
                    controller.openWindow(.controlCenter)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ScoutColors.primaryText)
                .help("Open Scout Controller window")
                .accessibilityIdentifier("scout.controller.window")

                windowMenu
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
            .scoutChrome(cornerRadius: 14)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("scout.controller.bar")
    }

    private var brand: some View {
        HStack(spacing: 8) {
            ScoutBrandMark(size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("SCOUT")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                Text("Controller")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
        }
        .foregroundStyle(ScoutColors.primaryText)
        .padding(.trailing, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(ScoutColors.strokeStrong)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    private var surfaceMenu: some View {
        Menu {
            ForEach(ScoutSurface.allCases) { surface in
                Button {
                    controller.open(surface)
                    workspace.destination = surface.destination
                } label: {
                    Label("Open \(surface.title)", systemImage: surface.symbol)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 27, height: 27)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open workspace tab")
        .accessibilityIdentifier("scout.controller.newTab")
    }

    private var minimizedTabs: some View {
        Menu {
            ForEach(controller.minimizedTabs) { tab in
                Button {
                    controller.restore(tab.surface)
                    workspace.destination = tab.surface.destination
                } label: {
                    Label("Restore \(tab.title)", systemImage: tab.symbol)
                }
            }
        } label: {
            Label("\(controller.minimizedTabs.count)", systemImage: "rectangle.compress.vertical")
                .font(.system(size: 10, weight: .semibold))
                .frame(height: 27)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Restore minimized tabs")
    }

    private var liveState: some View {
        HStack(spacing: 6) {
            StatusDot(
                color: workspace.captureState == .listening ? ScoutColors.mint : ScoutColors.gold,
                pulses: workspace.captureState == .listening
            )
            Text(workspace.captureState.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ScoutColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var windowMenu: some View {
        Menu {
            Section("Scout windows") {
                ForEach(ScoutWindowRole.allCases.filter { $0 != .workspace }) { role in
                    Button {
                        controller.openWindow(role)
                    } label: {
                        Label("Open \(role.title)", systemImage: role.symbol)
                    }
                }
            }
            Divider()
            Button("Minimize This Window", systemImage: "minus.rectangle") {
                controller.minimizeWindow(windowRole)
            }
            Button("Close This Window", systemImage: "xmark.rectangle") {
                controller.closeWindow(windowRole)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Window actions")
        .accessibilityIdentifier("scout.controller.windowMenu")
    }
}

private struct ScoutTabButton: View {
    let tab: ScoutWorkspaceTab
    let isSelected: Bool
    let select: () -> Void
    let minimize: () -> Void
    let close: () -> Void
    let detach: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                Label(tab.title, systemImage: tab.symbol)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            if isSelected || isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ScoutColors.secondaryText)
                .help("Close \(tab.title)")
            }
        }
        .foregroundStyle(isSelected ? ScoutColors.primaryText : ScoutColors.secondaryText)
        .padding(.leading, 9)
        .padding(.trailing, isSelected || isHovering ? 5 : 9)
        .frame(height: 29)
        .background(
            isSelected ? ScoutColors.porcelain.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? ScoutColors.strokeStrong : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Window", systemImage: "macwindow.badge.plus", action: detach)
            Button("Minimize Tab", systemImage: "rectangle.compress.vertical", action: minimize)
            Divider()
            Button("Close Tab", systemImage: "xmark", role: .destructive, action: close)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("scout.tab.\(tab.surface.rawValue)")
    }
}

private extension ScoutSurface {
    var windowRole: ScoutWindowRole {
        switch self {
        case .discovery: .transcript
        case .evidence: .evidence
        case .actionPack: .actionPack
        }
    }
}
