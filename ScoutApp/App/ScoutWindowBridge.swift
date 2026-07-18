import AppKit
import SwiftUI

/// Registers only windows whose view hierarchy explicitly contains this probe. Scout never scans or
/// controls unrelated application windows, which keeps the controller boundary narrow and testable.
struct ScoutWindowProbe: NSViewRepresentable {
    let role: ScoutWindowRole
    let controller: ScoutController

    func makeCoordinator() -> Coordinator {
        Coordinator(role: role, controller: controller)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.update(role: role, controller: controller)
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.onWindowChange = nil
    }

    final class ProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var role: ScoutWindowRole
        private weak var controller: ScoutController?
        private weak var window: NSWindow?
        private var notifications: [NSObjectProtocol] = []

        init(role: ScoutWindowRole, controller: ScoutController) {
            self.role = role
            self.controller = controller
        }

        func update(role: ScoutWindowRole, controller: ScoutController) {
            self.role = role
            self.controller = controller
            publish()
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            guard let window else {
                publish()
                return
            }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ]
            notifications = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.publish()
                    }
                }
            }
            publish()
        }

        func detach() {
            notifications.forEach(NotificationCenter.default.removeObserver)
            notifications.removeAll()
            window = nil
            publish()
        }

        func minimize() {
            window?.performMiniaturize(nil)
        }

        func focus() {
            guard let window else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            window?.performClose(nil)
        }

        private func publish() {
            controller?.windowStateDidChange(ScoutManagedWindowState(
                role: role,
                isOpen: window != nil && window?.isVisible == true,
                isMinimized: window?.isMiniaturized == true,
                isKey: window?.isKeyWindow == true
            ))
        }
    }
}

/// Owns weak AppKit handles for Scout-registered scenes so minimize/focus/close commands operate on
/// exact Scout windows. The probes remain responsible for publishing lifecycle state.
@MainActor
final class ScoutWindowRegistry {
    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow?) { self.value = value }
    }

    private var windows: [ScoutWindowRole: WeakWindow] = [:]

    func register(_ window: NSWindow?, for role: ScoutWindowRole) {
        windows[role] = WeakWindow(window)
    }

    func isOpen(_ role: ScoutWindowRole) -> Bool {
        windows[role]?.value != nil
    }

    func minimize(_ role: ScoutWindowRole) {
        windows[role]?.value?.performMiniaturize(nil)
    }

    func focus(_ role: ScoutWindowRole) {
        guard let window = windows[role]?.value else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ role: ScoutWindowRole) {
        windows[role]?.value?.performClose(nil)
    }
}

/// A second probe feeds the exact AppKit handle into the registry while `ScoutWindowProbe` publishes
/// observable lifecycle state. Keeping the registry separate avoids exposing `NSWindow` in models.
struct ScoutWindowHandleProbe: NSViewRepresentable {
    let role: ScoutWindowRole
    let registry: ScoutWindowRegistry

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onWindowChange = { [weak registry] window in
            registry?.register(window, for: role)
        }
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        registry.register(nsView.window, for: role)
    }

    final class HandleView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

struct ScoutSceneActionInstaller: ViewModifier {
    let controller: ScoutController
    let registry: ScoutWindowRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            controller.installSceneActions(
                open: { role in
                    if registry.isOpen(role) {
                        registry.focus(role)
                    } else {
                        openWindow(id: role.sceneID)
                    }
                },
                close: { role in
                    if registry.isOpen(role) {
                        registry.close(role)
                    } else {
                        dismissWindow(id: role.sceneID)
                    }
                },
                minimize: { registry.minimize($0) },
                focus: { role in
                    if registry.isOpen(role) {
                        registry.focus(role)
                    } else {
                        openWindow(id: role.sceneID)
                    }
                }
            )
        }
    }
}

extension View {
    func scoutSceneActions(
        controller: ScoutController,
        registry: ScoutWindowRegistry
    ) -> some View {
        modifier(ScoutSceneActionInstaller(controller: controller, registry: registry))
    }

    func scoutWindowRegistration(
        _ role: ScoutWindowRole,
        controller: ScoutController,
        registry: ScoutWindowRegistry
    ) -> some View {
        background(ScoutWindowProbe(role: role, controller: controller))
            .background(ScoutWindowHandleProbe(role: role, registry: registry))
    }
}
