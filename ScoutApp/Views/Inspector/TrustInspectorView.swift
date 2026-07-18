import SwiftUI

struct TrustInspectorView: View {
    let workspace: ScoutWorkspace
    var compact = true

    var body: some View {
        let selectedClaim = workspace.selectedClaim
        let canonicalEvidenceIDs = workspace.selectedClaimCanonicalEvidenceIDs

        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Trust layer", title: "Evidence inspector") {
                canonicalEvidenceStatus(
                    hasSelectedClaim: selectedClaim != nil,
                    evidenceIDs: canonicalEvidenceIDs
                )
                .font(.system(size: 9, weight: .semibold))
                .accessibilityIdentifier("scout.trustInspector.evidenceStatus")
            }
            .padding(.horizontal, ScoutSpacing.medium)
            .padding(.vertical, 11)

            Divider().overlay(ScoutColors.stroke)

            if let claim = selectedClaim {
                ScrollView {
                    claimContent(claim, canonicalEvidenceIDs: canonicalEvidenceIDs)
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
        .scoutPanel(emphasized: selectedClaim?.needsValidation == true)
        .accessibilityIdentifier("scout.trustInspector")
    }

    @ViewBuilder
    private func canonicalEvidenceStatus(
        hasSelectedClaim: Bool,
        evidenceIDs: [String]
    ) -> some View {
        if !hasSelectedClaim {
            Label("No claim selected", systemImage: "link")
                .foregroundStyle(ScoutColors.secondaryText)
        } else if evidenceIDs.isEmpty {
            Label("Evidence unresolved", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ScoutColors.gold)
        } else {
            Label(
                evidenceIDs.count == 1
                    ? "1 canonical source"
                    : "\(evidenceIDs.count) canonical sources",
                systemImage: "link.badge.plus"
            )
            .foregroundStyle(ScoutColors.mint)
        }
    }

    private func claimContent(
        _ claim: TrustClaim,
        canonicalEvidenceIDs: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 10) {
                EvidenceBadge(kind: claim.provenance)
                if claim.reviewStatus == .accepted {
                    Label("Accepted", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ScoutColors.mint)
                } else if claim.reviewStatus == .legacyAccepted {
                    Label("Legacy acceptance", systemImage: "exclamationmark.shield")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ScoutColors.gold)
                } else {
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

            if canonicalEvidenceIDs.isEmpty {
                unresolvedEvidenceNotice
            } else {
                sourceChain
            }

            if let provenance = workspace.claimProvenanceByID[claim.id] {
                modelReceipt(provenance, canonicalEvidenceIDs: canonicalEvidenceIDs)
            }

            claimReviewControls(claim)

            if !compact {
                trustLegend
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var unresolvedEvidenceNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Canonical evidence unresolved", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(ScoutColors.gold)
            Text("No immutable evidence ID resolves for this claim. Treat the excerpt as context only until canonical replay restores the link.")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScoutColors.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(ScoutColors.gold.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scout.trustInspector.evidenceUnresolved")
    }

    @ViewBuilder
    private func claimReviewControls(_ claim: TrustClaim) -> some View {
        let isReviewing = workspace.reviewingClaimIDs.contains(claim.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("CLAIM REVIEW")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(ScoutColors.secondaryText)
                Spacer()
                Text(reviewStatusLabel(claim.reviewStatus))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(reviewStatusColor(claim.reviewStatus))
            }

            if isReviewing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(
                        claim.reviewStatus == .legacyAccepted
                            ? "Authenticating acceptance…"
                            : "Saving claim review…"
                    )
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
            } else {
                switch claim.reviewStatus {
                case .proposed:
                    HStack(spacing: 7) {
                        Button("Accept claim") {
                            workspace.acceptClaim(claim.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(ScoutColors.mint)
                        .foregroundStyle(ScoutColors.canvas)
                        .accessibilityIdentifier("scout.claim.accept.\(claim.id)")

                        Button("Reject claim") {
                            workspace.rejectClaim(claim.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(ScoutColors.coral)
                        .accessibilityIdentifier("scout.claim.reject.\(claim.id)")
                    }

                case .legacyAccepted:
                    Button("Re-authenticate acceptance") {
                        workspace.reattestClaimAcceptance(claim.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(ScoutColors.gold)
                    .foregroundStyle(ScoutColors.canvas)
                    .accessibilityIdentifier("scout.claim.reattest.\(claim.id)")

                case .accepted:
                    Text("Device-owner authentication is recorded in the canonical event history.")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
            }

            if let error = workspace.claimReviewError,
               error.claimID == claim.id {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ScoutColors.coral)
                    .accessibilityIdentifier("scout.claim.reviewError.\(claim.id)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            reviewStatusColor(claim.reviewStatus).opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(reviewStatusColor(claim.reviewStatus).opacity(0.22), lineWidth: 1)
        )
    }

    private func reviewStatusLabel(_ status: ClaimReviewStatus) -> String {
        switch status {
        case .proposed: "AWAITING REVIEW"
        case .accepted: "AUTHENTICATED ACCEPTANCE"
        case .legacyAccepted: "LEGACY · RE-AUTH REQUIRED"
        }
    }

    private func reviewStatusColor(_ status: ClaimReviewStatus) -> Color {
        switch status {
        case .proposed, .legacyAccepted: ScoutColors.gold
        case .accepted: ScoutColors.mint
        }
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

    private func modelReceipt(
        _ provenance: ClaimProjectionProvenance,
        canonicalEvidenceIDs: [String]
    ) -> some View {
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
            if canonicalEvidenceIDs.isEmpty {
                Label("Canonical evidence IDs unresolved", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScoutColors.gold)
            } else {
                Text("\(canonicalEvidenceIDs.count) resolved immutable evidence \(canonicalEvidenceIDs.count == 1 ? "record" : "records")")
            }
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
            ViewThatFits(in: .horizontal) {
                evidenceMetrics(columnCount: 4)
                    .frame(minWidth: 720)
                evidenceMetrics(columnCount: 2)
            }

            HSplitView {
                ClaimsListView(workspace: workspace)
                    .frame(minWidth: 390, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

                VisualEvidencePanel(workspace: workspace)
                    .frame(minWidth: 310, idealWidth: 390, maxWidth: 480, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(Color.clear)
        .accessibilityIdentifier("scout.evidenceWorkspace")
    }

    private func evidenceMetrics(columnCount: Int) -> some View {
        let canonicallyLinkedClaimCount = workspace.claims.filter {
            !workspace.canonicalEvidenceIDs(forClaimID: $0.id).isEmpty
        }.count
        let unresolvedEvidenceClaimCount = workspace.claims.count - canonicallyLinkedClaimCount

        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 150), spacing: 10),
                count: columnCount
            ),
            spacing: 10
        ) {
            EvidenceMetricCard(symbol: "link", value: "\(canonicallyLinkedClaimCount)", label: "canonically linked", tint: ScoutColors.cyan)
            EvidenceMetricCard(symbol: "checkmark.shield", value: "\(Int(workspace.evidenceCoverage * 100))%", label: "graph coverage", tint: ScoutColors.mint)
            EvidenceMetricCard(symbol: "exclamationmark.triangle", value: "\(unresolvedEvidenceClaimCount)", label: "evidence unresolved", tint: ScoutColors.gold)
            EvidenceMetricCard(symbol: "exclamationmark.bubble", value: "\(workspace.claims.filter(\.needsValidation).count)", label: "needs validation", tint: ScoutColors.gold)
        }
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
                            workspace.selectClaim(claim.id)
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
                                workspace.selectedClaimID == claim.id ? claim.provenance.color.opacity(0.08) : Color.white.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(workspace.selectedClaimID == claim.id ? claim.provenance.color.opacity(0.34) : ScoutColors.stroke, lineWidth: 1)
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
