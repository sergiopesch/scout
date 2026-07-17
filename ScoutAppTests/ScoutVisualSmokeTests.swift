import AppKit
import SwiftUI
import XCTest
@testable import Scout

/// Renders Scout's three critical workspaces at a representative production size. This catches views
/// that compile but cannot produce a native frame, and can emit current-run audit artifacts when
/// `SCOUT_SNAPSHOT_DIR` is supplied to the test process.
@MainActor
final class ScoutVisualSmokeTests: XCTestCase {
    func testCriticalWorkspacesRenderAtProductionSize() throws {
        let outputDirectory = ProcessInfo.processInfo.environment["SCOUT_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let discovery = ScoutWorkspace(completed: true)
        discovery.destination = .discovery
        try render(discovery, named: "01-discovery", outputDirectory: outputDirectory)

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
        try render(evidence, named: "02-evidence", outputDirectory: outputDirectory)

        let actionPack = ScoutWorkspace(completed: true)
        actionPack.destination = .actionPack
        actionPack.selectedPOCQuickWinID = "win-monitor"
        try render(actionPack, named: "03-action-pack", outputDirectory: outputDirectory)
    }

    private func render(
        _ workspace: ScoutWorkspace,
        named name: String,
        outputDirectory: URL?
    ) throws {
        let size = NSSize(width: 1_200, height: 800)
        let hostingView = NSHostingView(
            rootView: AuditWorkspaceView(workspace: workspace)
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
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
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1_200)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 800)
        XCTAssertEqual(
            bitmap.pixelsWide * 2,
            bitmap.pixelsHigh * 3,
            "The \(name) render must preserve Scout's 3:2 production aspect ratio"
        )
        XCTAssertEqual(
            Double(bitmap.pixelsWide) / 1_200,
            Double(bitmap.pixelsHigh) / 800,
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

/// The exact active workspace used inside ScoutRootView, excluding only NavigationSplitView's
/// AppKit-backed session column, which ImageRenderer cannot flatten in a headless test process.
private struct AuditWorkspaceView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            CockpitHeaderView(workspace: workspace)
            switch workspace.destination {
            case .discovery:
                DiscoveryCockpitView(workspace: workspace)
            case .evidence:
                EvidenceWorkspaceView(workspace: workspace)
            case .actionPack:
                ActionPackView(workspace: workspace)
            }
        }
        .background(ScoutColors.canvas)
    }
}
