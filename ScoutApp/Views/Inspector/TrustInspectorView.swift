import SwiftUI

struct TrustInspectorView: View {
    let workspace: ScoutWorkspace
    var compact = true

    var body: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Trust layer", title: "Evidence inspector") {
                Label("Source-linked", systemImage: "link.badge.plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ScoutColors.mint)
            }
            .padding(.horizontal, ScoutSpacing.medium)
            .padding(.vertical, 11)

            Divider().overlay(ScoutColors.stroke)

            if let claim = workspace.selectedClaim {
                ScrollView {
                    claimContent(claim)
                        .padding(ScoutSpacing.medium)
                }
            } else {
                EmptyStateView(
                    symbol: "checkmark.shield",
                    title: "Select a model entity",
                    detail: "Scout will show the source, speaker, and certainty behind it."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scoutPanel(emphasized: workspace.selectedClaim?.needsValidation == true)
        .accessibilityIdentifier("scout.trustInspector")
    }

    private func claimContent(_ claim: TrustClaim) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 10) {
                EvidenceBadge(kind: claim.provenance)
                if claim.needsValidation {
                    Label("Needs validation", systemImage: "exclamationmark.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ScoutColors.gold)
                }
                Spacer()
                ConfidenceGauge(value: claim.confidence)
            }

            VStack(alignment: .leading, spacing: 5) {
                if let entity = workspace.selectedEntity {
                    Label(entity.kind.rawValue, systemImage: entity.kind.symbol)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(entity.kind.color)
                }
                Text(claim.title)
                    .font(.system(size: compact ? 14 : 18, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(claim.detail)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineSpacing(3)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("SOURCE UTTERANCE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(ScoutColors.secondaryText)
                Text("“\(claim.evidenceQuote)”")
                    .font(.system(size: compact ? 10 : 12, weight: .medium))
                    .italic()
                    .foregroundStyle(ScoutColors.primaryText.opacity(0.88))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Image(systemName: "person.wave.2.fill")
                        .foregroundStyle(ScoutColors.cyan)
                    Text(claim.speakerName)
                    Text("·")
                    Text(claim.timestamp)
                        .fontDesign(.monospaced)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScoutColors.canvas.opacity(0.48), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(claim.provenance.color)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }

            sourceChain

            if let provenance = workspace.claimProvenanceByID[claim.id] {
                modelReceipt(provenance)
            }

            if !compact {
                trustLegend
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var sourceChain: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROVENANCE CHAIN")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(ScoutColors.secondaryText)
            HStack(spacing: 4) {
                chainStep(symbol: "mic.fill", label: "Audio")
                chainLink
                chainStep(symbol: "quote.bubble.fill", label: "Utterance")
                chainLink
                chainStep(symbol: "cpu", label: "Proposal")
                chainLink
                chainStep(symbol: "point.3.connected.trianglepath.dotted", label: "Graph")
            }
        }
    }

    private func modelReceipt(_ provenance: ClaimProjectionProvenance) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("MODEL RECEIPT")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(ScoutColors.secondaryText)
            HStack(spacing: 8) {
                Label(provenance.modelCall.model, systemImage: "cpu")
                Spacer()
                Text("event #\(provenance.modelCall.inputEventBoundary)")
                    .fontDesign(.monospaced)
            }
            Text("Response \(Self.short(provenance.modelCall.responseID)) · output \(Self.short(provenance.modelCall.outputSHA256))")
                .fontDesign(.monospaced)
            Text("\(provenance.evidenceIDs.count) immutable evidence \(provenance.evidenceIDs.count == 1 ? "record" : "records")")
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(ScoutColors.secondaryText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScoutColors.canvas.opacity(0.36), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private static func short(_ value: String) -> String {
        guard value.count > 14 else { return value }
        return "\(value.prefix(8))…\(value.suffix(5))"
    }

    private func chainStep(symbol: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ScoutColors.cyan)
                .frame(width: 22, height: 22)
                .background(ScoutColors.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var chainLink: some View {
        Rectangle()
            .fill(ScoutColors.cyan.opacity(0.25))
            .frame(width: 12, height: 1)
            .offset(y: -7)
            .accessibilityHidden(true)
    }

    private var trustLegend: some View {
        HStack(spacing: 8) {
            ForEach(EvidenceKind.allCases, id: \.self) { kind in
                EvidenceBadge(kind: kind, compact: true)
            }
        }
    }
}

private struct ConfidenceGauge: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 3)
            Circle()
                .trim(from: 0, to: value)
                .stroke(
                    value >= 0.95 ? ScoutColors.mint : ScoutColors.gold,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
        }
        .frame(width: 34, height: 34)
        .accessibilityLabel("\(Int(value * 100)) percent confidence")
    }
}

struct EvidenceWorkspaceView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                EvidenceMetricCard(symbol: "link", value: "\(workspace.claims.count)", label: "source-linked claims", tint: ScoutColors.cyan)
                EvidenceMetricCard(symbol: "checkmark.shield", value: "\(Int(workspace.evidenceCoverage * 100))%", label: "graph coverage", tint: ScoutColors.mint)
                EvidenceMetricCard(symbol: "chart.bar.fill", value: "\(Int(workspace.averageConfidence * 100))%", label: "mean confidence", tint: ScoutColors.blue)
                EvidenceMetricCard(symbol: "exclamationmark.bubble", value: "\(workspace.claims.filter(\.needsValidation).count)", label: "needs validation", tint: ScoutColors.gold)
            }

            HStack(spacing: 12) {
                ClaimsListView(workspace: workspace)
                    .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    TrustInspectorView(workspace: workspace, compact: false)
                        .frame(minHeight: 300, maxHeight: .infinity)
                    VisualEvidencePanel(workspace: workspace)
                        .frame(minHeight: 190, idealHeight: 245, maxHeight: 310)
                }
                .frame(minWidth: 360, idealWidth: 430, maxWidth: 500, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(ScoutColors.canvas)
        .accessibilityIdentifier("scout.evidenceWorkspace")
    }
}

private struct EvidenceMetricCard: View {
    let symbol: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .scoutPanel()
        .accessibilityElement(children: .combine)
    }
}

private struct ClaimsListView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Append-only evidence", title: "Claims ledger") {
                Text("\(workspace.claims.count) claims")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ScoutColors.secondaryText)
            }
            .padding(14)
            Divider().overlay(ScoutColors.stroke)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(workspace.claims.reversed()) { claim in
                        Button {
                            if let id = claim.relatedEntityID {
                                workspace.selectEntity(id)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: claim.provenance.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(claim.provenance.color)
                                    .frame(width: 28, height: 28)
                                    .background(claim.provenance.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(claim.title)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(ScoutColors.primaryText)
                                        Spacer()
                                        Text("\(Int(claim.confidence * 100))%")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(claim.provenance.color)
                                    }
                                    Text(claim.detail)
                                        .font(.system(size: 9))
                                        .foregroundStyle(ScoutColors.secondaryText)
                                        .lineLimit(2)
                                    HStack(spacing: 5) {
                                        Text(claim.speakerName)
                                        Text("·")
                                        Text(claim.timestamp)
                                        if claim.needsValidation {
                                            Text("· NEEDS VALIDATION")
                                                .foregroundStyle(ScoutColors.gold)
                                        }
                                    }
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(ScoutColors.secondaryText)
                                }
                            }
                            .padding(11)
                            .background(
                                workspace.selectedClaim?.id == claim.id ? claim.provenance.color.opacity(0.08) : Color.white.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(workspace.selectedClaim?.id == claim.id ? claim.provenance.color.opacity(0.34) : ScoutColors.stroke, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(claim.title), \(claim.provenance.rawValue), \(Int(claim.confidence * 100)) percent confidence")
                        .accessibilityIdentifier("scout.claim.\(claim.id)")
                    }
                }
                .padding(12)
            }
        }
        .scoutPanel()
    }
}

#Preview("Evidence inspector") {
    EvidenceWorkspaceView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 1180, height: 720)
        .preferredColorScheme(.dark)
}
