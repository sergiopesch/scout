import AppKit
import SwiftUI
import XCTest
@testable import Scout

/// Renders Scout's five critical workspace states at a representative production size. This catches views
/// that compile but cannot produce a native frame, and can emit current-run audit artifacts when
/// `SCOUT_SNAPSHOT_DIR` is supplied to the test process.
@MainActor
final class ScoutVisualSmokeTests: XCTestCase {
    func testCriticalWorkspacesRenderAtProductionSize() throws {
        let outputDirectory = ProcessInfo.processInfo.environment["SCOUT_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let discovery = ScoutWorkspace(completed: true)
        discovery.destination = .discovery
        try render(
            AuditWorkspaceView(workspace: discovery),
            named: "01-discovery",
            outputDirectory: outputDirectory
        )

        let evidence = ScoutWorkspace(completed: true)
        evidence.destination = .evidence
        evidence.visualEvidencePhase = .ready
        evidence.visualEvidenceAsset = VisualEvidenceAssetSummary(
            evidenceID: "evidence-visual-audit",
            assetSHA256: String(repeating: "a", count: 64),
            pixelWidth: 2_048,
            pixelHeight: 1_152,
            byteCount: 842_304,
            model: "gpt-5.6-luna",
            modelCallReceiptID: "model-call-visual-audit"
        )
        evidence.visualEvidenceProposals = [
            VisualEvidenceProposalCard(
                id: "visual-system-order-hub",
                kind: .entity,
                title: "Order orchestration hub",
                detail: "A labelled system box sits between support and inventory.",
                basis: .visible,
                confidence: 0.96
            ),
            VisualEvidenceProposalCard(
                id: "visual-flow-status",
                kind: .relationship,
                title: "Status flows to support",
                detail: "A directed arrow appears to connect inventory status with the support workspace.",
                basis: .inferred,
                confidence: 0.78
            ),
        ]
        evidence.visualEvidenceMessage = "Two bounded observations proposed. Human validation is required."
        try render(
            AuditWorkspaceView(workspace: evidence),
            named: "02-evidence",
            outputDirectory: outputDirectory
        )

        let actionPack = ScoutWorkspace(completed: true)
        actionPack.destination = .actionPack
        actionPack.selectedPOCQuickWinID = "win-monitor"
        try render(
            AuditWorkspaceView(workspace: actionPack),
            named: "03-action-pack",
            outputDirectory: outputDirectory
        )

        let controllerWorkspace = ScoutWorkspace(completed: true)
        let controller = ScoutController(selectedSurface: .discovery)
        controller.windowStateDidChange(ScoutManagedWindowState(
            role: .workspace,
            isOpen: true,
            isMinimized: false,
            isKey: true
        ))
        controller.windowStateDidChange(ScoutManagedWindowState(
            role: .transcript,
            isOpen: true,
            isMinimized: true,
            isKey: false
        ))
        try render(
            ScoutControlCenterView(
                controller: controller,
                workspace: controllerWorkspace,
                capabilities: ScoutCapabilityBroker()
            ),
            named: "04-controller",
            outputDirectory: outputDirectory
        )

        let uncommittedTranscript = ScoutWorkspace(completed: true)
        uncommittedTranscript.liveError = "A final transcript arrived without matching captured-audio timing; Scout left it uncommitted for review."
        uncommittedTranscript.transcript[0].commitState = .uncommitted
        try render(
            AuditWorkspaceView(workspace: uncommittedTranscript),
            named: "05-uncommitted-transcript-warning",
            outputDirectory: outputDirectory
        )
    }

    private func render<Content: View>(
        _ content: Content,
        named name: String,
        outputDirectory: URL?
    ) throws {
        let size = NSSize(width: 1_440, height: 900)
        let hostingView = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .environment(\.scoutForcesOpaqueRendering, true)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        // ScrollView and text selection contain AppKit-backed adaptors that ImageRenderer cannot
        // flatten. A real off-screen host window exercises the same rendering path as Scout.app.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderBack(nil)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.18))

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            window.close()
            return XCTFail("Scout could not render the \(name) workspace")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.orderOut(nil)
        window.close()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Scout could not encode the \(name) workspace")
        }

        // AppKit renders at the host display's backing scale. Keep the production logical frame
        // as the minimum while accepting Retina output (for example 2,400 × 1,600).
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1_440)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 900)
        XCTAssertEqual(
            bitmap.pixelsWide * 5,
            bitmap.pixelsHigh * 8,
            "The \(name) render must preserve Scout's 8:5 production aspect ratio"
        )
        XCTAssertEqual(
            Double(bitmap.pixelsWide) / 1_440,
            Double(bitmap.pixelsHigh) / 900,
            accuracy: 0.001,
            "The \(name) render must use one consistent backing scale"
        )
        XCTAssertGreaterThan(png.count, 25_000, "The \(name) render should contain a full native frame")

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let outputDirectory else { return }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try png.write(to: outputDirectory.appending(path: "\(name).png"), options: .atomic)
    }
}

/// The production visual hierarchy flattened into one deterministic host. Native split-view and
/// inspector adaptors have their own lifecycle tests; flattening them here avoids AppKit keeping a
/// headless test window alive after image capture.
private struct AuditWorkspaceView: View {
    @Bindable var workspace: ScoutWorkspace
    @State private var controller: ScoutController

    init(workspace: ScoutWorkspace) {
        self.workspace = workspace
        _controller = State(initialValue: ScoutController(
            selectedSurface: ScoutSurface(workspace.destination)
        ))
    }

    var body: some View {
        ZStack {
            ScoutAmbientBackdrop()
            VStack(spacing: 0) {
                ScoutControllerBar(
                    controller: controller,
                    workspace: workspace,
                    windowRole: .workspace
                )

                HStack(spacing: 0) {
                    SessionSidebarView(workspace: workspace)
                        .frame(width: 248)

                    VStack(spacing: 0) {
                        CockpitHeaderView(workspace: workspace, showsDestinations: false)
                        switch workspace.destination {
                        case .discovery:
                            DiscoveryCockpitView(workspace: workspace)
                        case .evidence:
                            EvidenceWorkspaceView(workspace: workspace)
                        case .actionPack:
                            ActionPackView(workspace: workspace)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if workspace.destination != .actionPack {
                        ScoutAuditInspector(workspace: workspace)
                            .frame(width: 340)
                            .frame(maxHeight: .infinity)
                            .background(ScoutColors.graphiteMid.opacity(0.72))
                    }
                }
            }
        }
    }
}

private struct ScoutAuditInspector: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 8) {
            Picker("Inspector section", selection: .constant("Evidence")) {
                Text("Evidence").tag("Evidence")
                Text("Gaps").tag("Gaps")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TrustInspectorView(workspace: workspace, compact: true)
                .frame(maxHeight: .infinity)
        }
        .padding(12)
        .tint(ScoutColors.mint)
    }
}
