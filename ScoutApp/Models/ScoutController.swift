import Foundation
import Observation

enum ScoutSurface: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case discovery
    case evidence
    case actionPack

    var id: Self { self }

    var title: String {
        switch self {
        case .discovery: "Discovery"
        case .evidence: "Evidence"
        case .actionPack: "Action pack"
        }
    }

    var symbol: String {
        switch self {
        case .discovery: "waveform.path.ecg"
        case .evidence: "checkmark.shield"
        case .actionPack: "shippingbox"
        }
    }

    var destination: WorkspaceDestination {
        switch self {
        case .discovery: .discovery
        case .evidence: .evidence
        case .actionPack: .actionPack
        }
    }

    init(_ destination: WorkspaceDestination) {
        switch destination {
        case .discovery: self = .discovery
        case .evidence: self = .evidence
        case .actionPack: self = .actionPack
        }
    }
}

enum ScoutTabPresentation: String, Codable, Hashable, Sendable {
    case open
    case minimized
}

struct ScoutWorkspaceTab: Identifiable, Codable, Hashable, Sendable {
    let surface: ScoutSurface
    var presentation: ScoutTabPresentation

    var id: ScoutSurface { surface }
    var title: String { surface.title }
    var symbol: String { surface.symbol }
}

enum ScoutWindowRole: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case workspace
    case controlCenter
    case transcript
    case evidence
    case actionPack

    var id: Self { self }

    var sceneID: String {
        switch self {
        case .workspace: "workspace"
        case .controlCenter: "control-center"
        case .transcript: "transcript"
        case .evidence: "evidence-window"
        case .actionPack: "action-pack-window"
        }
    }

    var title: String {
        switch self {
        case .workspace: "Scout"
        case .controlCenter: "Scout Controller"
        case .transcript: "Live Transcript"
        case .evidence: "Evidence Review"
        case .actionPack: "Action Pack"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "rectangle.3.group"
        case .controlCenter: "slider.horizontal.3"
        case .transcript: "quote.bubble"
        case .evidence: "checkmark.shield"
        case .actionPack: "shippingbox"
        }
    }
}

struct ScoutManagedWindowState: Equatable, Sendable {
    let role: ScoutWindowRole
    var isOpen = false
    var isMinimized = false
    var isKey = false
}

/// The single source of truth for Scout-owned tabs, panels, and native windows.
///
/// Canonical discovery data stays in `ScoutWorkspace`; this controller owns presentation only. Its
/// command closures are installed by the SwiftUI scene boundary so the model remains deterministic
/// and unit-testable without opening AppKit windows.
@MainActor
@Observable
final class ScoutController {
    private(set) var tabs: [ScoutWorkspaceTab]
    var selectedTabID: ScoutSurface?
    var isSidebarVisible = true
    var isInspectorVisible = true
    var isCommandPalettePresented = false
    private(set) var windows: [ScoutWindowRole: ScoutManagedWindowState]

    @ObservationIgnored
    private var openScene: ((ScoutWindowRole) -> Void)?
    @ObservationIgnored
    private var closeScene: ((ScoutWindowRole) -> Void)?
    @ObservationIgnored
    private var minimizeScene: ((ScoutWindowRole) -> Void)?
    @ObservationIgnored
    private var focusScene: ((ScoutWindowRole) -> Void)?

    init(selectedSurface: ScoutSurface = .discovery) {
        tabs = ScoutSurface.allCases.map {
            ScoutWorkspaceTab(surface: $0, presentation: .open)
        }
        selectedTabID = selectedSurface
        windows = Dictionary(uniqueKeysWithValues: ScoutWindowRole.allCases.map {
            ($0, ScoutManagedWindowState(role: $0))
        })
    }

    var selectedSurface: ScoutSurface? {
        guard let selectedTabID,
              tabs.contains(where: { $0.id == selectedTabID && $0.presentation == .open })
        else { return nil }
        return selectedTabID
    }

    var openTabs: [ScoutWorkspaceTab] {
        tabs.filter { $0.presentation == .open }
    }

    var minimizedTabs: [ScoutWorkspaceTab] {
        tabs.filter { $0.presentation == .minimized }
    }

    func select(_ surface: ScoutSurface) {
        open(surface)
    }

    func open(_ surface: ScoutSurface) {
        if let index = tabs.firstIndex(where: { $0.id == surface }) {
            tabs[index].presentation = .open
        } else {
            tabs.append(ScoutWorkspaceTab(surface: surface, presentation: .open))
            sortTabs()
        }
        selectedTabID = surface
    }

    func close(_ surface: ScoutSurface) {
        guard let index = tabs.firstIndex(where: { $0.id == surface }) else { return }
        let wasSelected = selectedTabID == surface
        tabs.remove(at: index)
        guard wasSelected else { return }
        selectedTabID = replacementAfterRemoval(at: index)?.surface
    }

    func minimize(_ surface: ScoutSurface) {
        guard let index = tabs.firstIndex(where: { $0.id == surface }) else { return }
        tabs[index].presentation = .minimized
        guard selectedTabID == surface else { return }
        selectedTabID = nextOpenTab(after: index)?.surface
    }

    func restore(_ surface: ScoutSurface) {
        open(surface)
    }

    func synchronize(with destination: WorkspaceDestination) {
        open(ScoutSurface(destination))
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func toggleInspector() {
        isInspectorVisible.toggle()
    }

    func installSceneActions(
        open: @escaping (ScoutWindowRole) -> Void,
        close: @escaping (ScoutWindowRole) -> Void,
        minimize: @escaping (ScoutWindowRole) -> Void,
        focus: @escaping (ScoutWindowRole) -> Void
    ) {
        openScene = open
        closeScene = close
        minimizeScene = minimize
        focusScene = focus
    }

    func openWindow(_ role: ScoutWindowRole) {
        openScene?(role)
    }

    func closeWindow(_ role: ScoutWindowRole) {
        closeScene?(role)
    }

    func minimizeWindow(_ role: ScoutWindowRole) {
        minimizeScene?(role)
    }

    func focusWindow(_ role: ScoutWindowRole) {
        focusScene?(role)
    }

    func windowStateDidChange(_ state: ScoutManagedWindowState) {
        windows[state.role] = state
    }

    /// Browser-style selection is stable: prefer the tab immediately to the right, then the
    /// closest open tab to the left. The helpers differ because closing removes the index while
    /// minimizing leaves a non-selectable item in place.
    private func replacementAfterRemoval(at index: Int) -> ScoutWorkspaceTab? {
        if index < tabs.count,
           let right = tabs[index...].first(where: { $0.presentation == .open }) {
            return right
        }
        return tabs.prefix(index).reversed().first(where: { $0.presentation == .open })
    }

    private func nextOpenTab(after index: Int) -> ScoutWorkspaceTab? {
        let nextIndex = tabs.index(after: index)
        if nextIndex < tabs.endIndex,
           let right = tabs[nextIndex...].first(where: { $0.presentation == .open }) {
            return right
        }
        return tabs.prefix(index).reversed().first(where: { $0.presentation == .open })
    }

    private func sortTabs() {
        let order = Dictionary(uniqueKeysWithValues: ScoutSurface.allCases.enumerated().map {
            ($0.element, $0.offset)
        })
        tabs.sort { order[$0.surface, default: .max] < order[$1.surface, default: .max] }
    }
}
