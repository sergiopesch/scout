import SwiftUI

struct ScoutControllerBar: View {
    @Bindable var controller: ScoutController
    @Bindable var workspace: ScoutWorkspace
    let windowRole: ScoutWindowRole

    var body: some View {
        ScoutGlassGroup(spacing: 8) {
            HStack(spacing: 6) {
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
                .frame(maxWidth: 620, alignment: .leading)

                if !closedSurfaces.isEmpty {
                    surfaceMenu
                }

                if !controller.minimizedTabs.isEmpty {
                    minimizedTabs
                }

                Spacer(minLength: 8)

                ControllerIconButton(
                    symbol: "sidebar.trailing",
                    help: controller.isInspectorVisible ? "Hide inspector" : "Show inspector",
                    isActive: controller.isInspectorVisible,
                    action: controller.toggleInspector
                )
                .accessibilityIdentifier("scout.controller.inspector")

                windowMenu
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .scoutChrome(cornerRadius: 13)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("scout.controller.bar")
    }

    private var surfaceMenu: some View {
        Menu {
            ForEach(closedSurfaces) { surface in
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
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open workspace tab")
        .accessibilityIdentifier("scout.controller.newTab")
    }

    private var closedSurfaces: [ScoutSurface] {
        ScoutSurface.allCases.filter { surface in
            !controller.tabs.contains(where: { $0.surface == surface })
        }
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

    private var windowMenu: some View {
        Menu {
            Section("Layout") {
                Button(controller.isSidebarVisible ? "Hide Sessions" : "Show Sessions", systemImage: "sidebar.leading") {
                    controller.toggleSidebar()
                }
                Button(controller.isInspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") {
                    controller.toggleInspector()
                }
            }
            Divider()
            Section("Scout windows") {
                Button {
                    controller.openWindow(.controlCenter)
                } label: {
                    Label("Controller", systemImage: "slider.horizontal.3")
                }
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

private struct ControllerIconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? ScoutColors.primaryText : ScoutColors.secondaryText)
        .help(help)
        .accessibilityLabel(help)
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
                Text(tab.title)
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
        .padding(.leading, 10)
        .padding(.trailing, isSelected || isHovering ? 5 : 9)
        .frame(height: 28)
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
