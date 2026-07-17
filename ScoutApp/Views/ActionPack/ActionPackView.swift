import AppKit
import SwiftUI

struct ActionPackView: View {
    @Bindable var workspace: ScoutWorkspace
    let journal: LiveEventJournal?
    @State private var handoffReceipt: HandoffReceipt?
    @State private var copied = false
    @State private var handoffInProgress = false
    @State private var handoffError: String?
    @State private var pendingHandoff: StagedContextPack?

    init(workspace: ScoutWorkspace, journal: LiveEventJournal? = nil) {
        self.workspace = workspace
        self.journal = journal
    }

    private var canHandoff: Bool {
        workspace.captureState != .listening
            && workspace.selectedPOCHasBuildReadyEvidence
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                actionHero
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        quickWinsSection
                        if workspace.selectedPOCQuickWin != nil {
                            pocBlueprint
                        }
                        if !canHandoff {
                            readinessPanel
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 14) {
                        artifactBundle
                        buildContext
                    }
                    .frame(minWidth: 330, idealWidth: 380, maxWidth: 430)
                }
            }
            .padding(16)
        }
        .background(ScoutColors.canvas)
        .sheet(item: $handoffReceipt) { receipt in
            HandoffReceiptView(receipt: receipt)
        }
        .sheet(item: $pendingHandoff) { staged in
            HandoffApprovalSheet(staged: staged) {
                try await completeHandoff(staged)
            }
        }
        .alert(
            "Handoff not completed",
            isPresented: Binding(
                get: { handoffError != nil },
                set: { if !$0 { handoffError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { handoffError = nil }
        } message: {
            Text(handoffError ?? "Scout could not stage the context pack.")
        }
        .accessibilityIdentifier("scout.actionPack")
    }

    private var actionHero: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(ScoutColors.mint)
                    Text(canHandoff ? "HANDOFF ELIGIBLE" : "DRAFT CONTEXT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.1)
                    .foregroundStyle(canHandoff ? ScoutColors.mint : ScoutColors.gold)
                }
                Text(canHandoff ? "Ready for explicit approval" : "Discovery is still forming")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(canHandoff
                    ? "The selected proof of value is supported by factual claims that no longer need validation. Review the bounded context before sending it to Codex."
                    : "Scout is preserving evidence and surfacing gaps. Select a proof of value; handoff stays locked until every supporting claim is factual and validated.")
                    .font(.system(size: 11))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: 580, alignment: .leading)
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                heroMetric(value: "\(workspace.claims.count)", label: "claims", tint: ScoutColors.cyan)
                heroMetric(value: "\(workspace.entities.count)", label: "entities", tint: ScoutColors.blue)
                heroMetric(value: "\(workspace.quickWins.count)", label: "quick wins", tint: ScoutColors.gold)
            }
            HStack(spacing: 8) {
                Button {
                    copyContextPack()
                } label: {
                    Label(copied ? "Copied" : "Copy context", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? ScoutColors.mint : ScoutColors.primaryText)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ScoutColors.strokeStrong, lineWidth: 1))
                .accessibilityIdentifier("scout.actionPack.copy")

                Button {
                    stageHandoff()
                } label: {
                    Group {
                        if handoffInProgress {
                            ProgressView()
                                .controlSize(.small)
                            Text("Staging…")
                        } else {
                            Label("Review & open", systemImage: "arrow.up.forward.app.fill")
                        }
                    }
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.canvas)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(ScoutColors.mint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canHandoff || handoffInProgress)
                .opacity(canHandoff && !handoffInProgress ? 1 : 0.55)
                .help(canHandoff ? "Review and approve bounded context for Codex" : "Select a fully evidence-backed POC first")
                .accessibilityIdentifier("scout.actionPack.openInCodex")
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [ScoutColors.panelRaised, ScoutColors.mint.opacity(0.07)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ScoutColors.mint.opacity(0.18), lineWidth: 1))
    }

    private func copyContextPack() {
        do {
            let exporter = ContextPackExporter()
            let pack = try exporter.makePack(from: workspace, approved: false)
            try exporter.copyToPasteboard(pack)
            copied = true
        } catch {
            handoffError = error.localizedDescription
        }
    }

    private func stageHandoff() {
        guard !handoffInProgress else { return }
        handoffInProgress = true

        Task { @MainActor in
            defer { handoffInProgress = false }
            do {
                guard let journal else {
                    throw ContextPackExportError.missingJournalHead
                }
                let bridge = ScoutBridgeClient()
                let currentHead = try await bridge.currentHead(
                    for: workspace.activeEvidenceSessionID
                )
                let verification = try await journal.verify(
                    sessionID: workspace.activeEvidenceSessionID
                )
                guard let journalHead = verification.lastHash?.rawValue else {
                    throw ContextPackExportError.missingJournalHead
                }
                let exporter = ContextPackExporter()
                pendingHandoff = try exporter.stageApprovedPack(
                    from: workspace,
                    currentHead: currentHead,
                    journalHeadSHA256: journalHead
                )
            } catch {
                handoffError = error.localizedDescription
            }
        }
    }

    private func completeHandoff(_ staged: StagedContextPack) async throws {
        let exporter = ContextPackExporter()
        try exporter.validate(staged)
        let approvedPack = try await ScoutBridgeClient().approveAndStore(staged)
        let localURL = try exporter.save(approvedPack)
        exporter.copyHandoffPromptToPasteboard(approvedPack)

        let codexURL = URL(string: "codex://plugins/scout")!
        let codexOpened = NSWorkspace.shared.open(codexURL)
        handoffReceipt = HandoffReceipt(
            organization: approvedPack.body.organization,
            artifactCount: approvedPack.body.quickWins.count
                + approvedPack.body.constraints.count
                + approvedPack.body.acceptanceCriteria.count,
            claimCount: approvedPack.body.claims.count,
            contextPackID: approvedPack.body.contextPackID,
            savedPath: localURL.path,
            codexOpened: codexOpened
        )
    }

    private func heroMetric(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
        }
        .frame(width: 62, height: 54)
        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var quickWinsSection: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Ranked by value × readiness", title: "Recommended quick wins") {
                Label("Evidence weighted", systemImage: "scalemass")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            .padding(14)
            Divider().overlay(ScoutColors.stroke)

            if workspace.quickWins.isEmpty {
                EmptyStateView(symbol: "bolt", title: "Still compiling", detail: "Quick wins appear when Scout has enough evidence to rank impact and effort.")
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(workspace.quickWins.enumerated()), id: \.element.id) { index, win in
                        QuickWinCard(
                            rank: index + 1,
                            win: win,
                            isSelected: workspace.selectedPOCQuickWinID == win.id,
                            onSelect: { workspace.selectPOC(win.id) }
                        )
                    }
                }
                .padding(12)
            }
        }
        .scoutPanel()
    }

    private var pocBlueprint: some View {
        let win = workspace.selectedPOCQuickWin
        return VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Selected proof of value", title: win?.title ?? "Selection unavailable") {
                EvidenceBadge(kind: .proposed, compact: true)
            }
            .padding(14)
            Divider().overlay(ScoutColors.stroke)

            VStack(alignment: .leading, spacing: 14) {
                Text(win?.detail ?? "Select an evidence-backed opportunity to form the POC boundary.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ScoutColors.primaryText)
                    .lineSpacing(3)

                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        blueprintCell(symbol: "scope", title: "Outcome", lines: [contextObjective, win?.timeToValue ?? "Timebox to validate"])
                        blueprintCell(symbol: "lock.shield", title: "Guardrails", lines: ["No production writes", "Evidence-linked context only"])
                    }
                    GridRow {
                        blueprintCell(symbol: "cylinder.split.1x2", title: "Evidence", lines: ["\(win?.evidenceCount ?? 0) supporting claims", contextSystems])
                        blueprintCell(symbol: "calendar.badge.clock", title: "Boundary", lines: [win?.timeToValue ?? "Not estimated", "Read-only and reversible"])
                    }
                }

                HStack(spacing: 7) {
                    phase(number: "01", label: "Observe", tint: ScoutColors.cyan)
                    phaseConnector
                    phase(number: "02", label: "Prototype", tint: ScoutColors.blue)
                    phaseConnector
                    phase(number: "03", label: "Validate", tint: ScoutColors.indigo)
                    phaseConnector
                    phase(number: "04", label: "Decide", tint: ScoutColors.mint)
                }
            }
            .padding(14)
        }
        .scoutPanel()
    }

    private var readinessPanel: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Handoff gate", title: "Evidence before execution") {
                EvidenceBadge(kind: .inferred, compact: true)
            }
            .padding(14)
            Divider().overlay(ScoutColors.stroke)
            VStack(alignment: .leading, spacing: 11) {
                readinessLine(
                    complete: !workspace.claims.isEmpty,
                    title: "Evidence-linked customer claims",
                    detail: "At least one factual statement must resolve to preserved source evidence."
                )
                readinessLine(
                    complete: !workspace.quickWins.isEmpty,
                    title: "Ranked opportunity",
                    detail: "Impact, effort, and readiness need a visible evidence basis."
                )
                readinessLine(
                    complete: workspace.selectedPOCQuickWin != nil,
                    title: "Explicitly selected proof of value",
                    detail: "Choose the opportunity this handoff is allowed to build."
                )
                readinessLine(
                    complete: canHandoff,
                    title: "Factual support and safe guardrail",
                    detail: "Every supporting claim must be heard or validated, with no unresolved validation flag."
                )
            }
            .padding(14)
        }
        .scoutPanel()
    }

    private func readinessLine(complete: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(complete ? ScoutColors.mint : ScoutColors.gold)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
        }
    }

    private func blueprintCell(symbol: String, title: String, lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ScoutColors.cyan)
                .frame(width: 26, height: 26)
                .background(ScoutColors.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(ScoutColors.secondaryText)
                ForEach(lines, id: \.self) { line in
                    Text("• \(line)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ScoutColors.primaryText.opacity(0.88))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phase(number: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ScoutColors.primaryText)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.17), lineWidth: 1))
    }

    private var phaseConnector: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(ScoutColors.secondaryText)
    }

    private var artifactBundle: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Portable source of truth", title: "Context bundle") {
                Text("JSON + Markdown")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(ScoutColors.cyan)
            }
            .padding(14)
            Divider().overlay(ScoutColors.stroke)
            VStack(spacing: 0) {
                ForEach(workspace.artifacts) { artifact in
                    ArtifactRow(artifact: artifact)
                    if artifact.id != workspace.artifacts.last?.id {
                        Divider().overlay(ScoutColors.stroke).padding(.leading, 48)
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .scoutPanel()
    }

    private var buildContext: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Codex handoff", title: "Build context preview")
                .padding(14)
            Divider().overlay(ScoutColors.stroke)

            VStack(alignment: .leading, spacing: 10) {
                contextLine(key: "objective", value: contextObjective)
                contextLine(key: "systems", value: contextSystems)
                contextLine(key: "constraint", value: contextConstraint)
                contextLine(key: "first_build", value: workspace.selectedPOCQuickWin?.title ?? "Not selected")
                contextLine(key: "acceptance", value: canHandoff ? "Ready for explicit approval" : "Requires validation")

                Divider().overlay(ScoutColors.stroke)

                HStack(spacing: 7) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(ScoutColors.mint)
                    Text("All factual context carries evidence IDs; assumptions remain explicit.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
            }
            .padding(14)
            .background(ScoutColors.canvas.opacity(0.42))
        }
        .scoutPanel()
    }

    private var contextObjective: String {
        workspace.entities
            .filter { $0.kind == .goal }
            .sorted { ($0.confidence, $0.id) > ($1.confidence, $1.id) }
            .first?.title ?? workspace.selectedSession.summary
    }

    private var contextSystems: String {
        let values = workspace.entities
            .filter { $0.kind == .system }
            .map(\.title)
            .sorted()
        return values.isEmpty ? "Still discovering" : values.joined(separator: ", ")
    }

    private var contextConstraint: String {
        if workspace.selectedPOCQuickWin != nil {
            return "Read-only; no production system mutation"
        }
        return workspace.entities
            .filter { $0.kind == .policy || $0.kind == .friction }
            .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
            .first?.title ?? "No validated guardrail yet"
    }

    private func contextLine(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(ScoutColors.indigo)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(ScoutColors.primaryText.opacity(0.88))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct QuickWinCard: View {
    let rank: Int
    let win: QuickWin
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(rank)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(rank == 1 ? ScoutColors.gold : ScoutColors.secondaryText)
                .frame(width: 28, height: 28)
                .background((rank == 1 ? ScoutColors.gold : ScoutColors.secondaryText).opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(win.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ScoutColors.primaryText)
                    Spacer()
                    Label(win.timeToValue, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ScoutColors.mint)
                }
                Text(win.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    score(label: "Impact", value: win.impact, tint: ScoutColors.gold)
                    score(label: "Effort", value: win.effort, tint: ScoutColors.cyan)
                    score(label: "Ready", value: win.readiness, tint: ScoutColors.mint)
                    Spacer()
                    Label("\(win.evidenceCount) sources", systemImage: "link")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
                HStack {
                    Spacer()
                    Button(action: onSelect) {
                        Label(
                            isSelected ? "Selected for POC" : "Select for POC",
                            systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? ScoutColors.mint : ScoutColors.cyan)
                    .accessibilityIdentifier("scout.quickWin.\(win.id).select")
                }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? ScoutColors.mint.opacity(0.55) : ScoutColors.stroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scout.quickWin.\(win.id)")
    }

    private func score(label: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { index in
                    Capsule()
                        .fill(index <= value ? tint : Color.white.opacity(0.08))
                        .frame(width: 7, height: 3)
                }
            }
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(ScoutColors.secondaryText)
    }
}

private struct ArtifactRow: View {
    let artifact: ActionArtifact

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(artifact.readiness.color)
                .frame(width: 28, height: 28)
                .background(artifact.readiness.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(artifact.detail)
                    .font(.system(size: 8))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Text(artifact.readiness.rawValue.uppercased())
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(artifact.readiness.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

private struct HandoffApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let staged: StagedContextPack
    let approve: @MainActor () async throws -> Void
    @State private var isApproving = false
    @State private var approvalError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(ScoutColors.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Approve exact context for Codex")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(ScoutColors.primaryText)
                    Text(staged.pack.body.selectedPOC?.title ?? staged.pack.body.objective)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                reviewRow("Organization", staged.pack.body.organization)
                reviewRow("Evidence-linked claims", "\(staged.pack.body.claims.count)")
                reviewRow("Revision", "\(staged.pack.body.revision)")
                reviewRow("Approved scope", staged.approvedScopeSHA256)
                reviewRow("Journal head", staged.journalHeadSHA256)
            }
            .padding(14)
            .background(Color.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))

            Text("Only these immutable bytes can be stored. Raw audio, unrestricted transcripts, image bytes, unresolved claims, and unrelated workspace state remain in Scout.")
                .font(.system(size: 10))
                .foregroundStyle(ScoutColors.secondaryText)
                .lineSpacing(3)

            if let approvalError {
                Label(approvalError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ScoutColors.coral)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isApproving)
                Spacer()
                Button {
                    Task { @MainActor in
                        isApproving = true
                        approvalError = nil
                        do {
                            try await approve()
                            dismiss()
                        } catch {
                            approvalError = error.localizedDescription
                        }
                        isApproving = false
                    }
                } label: {
                    if isApproving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Approve and open", systemImage: "arrow.up.forward.app.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ScoutColors.mint)
                .foregroundStyle(ScoutColors.canvas)
                .disabled(isApproving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(ScoutColors.panel)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("scout.handoffApproval")
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(ScoutColors.secondaryText)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(ScoutColors.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct HandoffReceipt: Identifiable {
    let id = UUID()
    let organization: String
    let artifactCount: Int
    let claimCount: Int
    let contextPackID: String
    let savedPath: String
    let codexOpened: Bool
}

private struct HandoffReceiptView: View {
    @Environment(\.dismiss) private var dismiss
    let receipt: HandoffReceipt

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(ScoutColors.mint.opacity(0.12))
                    .frame(width: 68, height: 68)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(ScoutColors.mint)
            }
            VStack(spacing: 6) {
                Text(receipt.codexOpened ? "Context staged for Codex" : "Context pack staged")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(receipt.codexOpened
                     ? "\(receipt.organization)’s approved context is available to Codex: \(receipt.artifactCount) artifacts and \(receipt.claimCount) evidence-linked claims. The handoff prompt is on your clipboard."
                     : "\(receipt.organization)’s approved context pack was stored, but Codex could not be opened automatically. Open Codex and paste the handoff prompt from your clipboard.")
                    .font(.system(size: 11))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 8) {
                Label("Deterministic context", systemImage: "checkmark.shield")
                Label("Assumptions explicit", systemImage: "exclamationmark.bubble")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ScoutColors.secondaryText)

            VStack(alignment: .leading, spacing: 4) {
                Text("PACK  \(receipt.contextPackID)")
                Text("LOCAL \(receipt.savedPath)")
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(ScoutColors.secondaryText)
            .textSelection(.enabled)
            .frame(maxWidth: 420, alignment: .leading)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(ScoutColors.mint)
                .foregroundStyle(ScoutColors.canvas)
                .keyboardShortcut(.defaultAction)
        }
        .padding(34)
        .frame(width: 500)
        .background(ScoutColors.panel)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("scout.handoffReceipt")
    }
}

#Preview("Action pack") {
    ActionPackView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 1240, height: 780)
        .preferredColorScheme(.dark)
}
