import SwiftUI

struct VisualEvidencePanel: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Bounded vision", title: "Visual evidence") {
                if workspace.visualEvidencePhase == .ready {
                    Label(
                        workspace.visualEvidenceProposals.contains(where: \.needsValidation)
                            ? "Review"
                            : "Reviewed",
                        systemImage: workspace.visualEvidenceProposals.contains(where: \.needsValidation)
                            ? "exclamationmark.circle"
                            : "checkmark.seal.fill"
                    )
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            workspace.visualEvidenceProposals.contains(where: \.needsValidation)
                                ? ScoutColors.gold
                                : ScoutColors.mint
                        )
                } else {
                    importButton(compact: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().overlay(ScoutColors.stroke)

            Group {
                switch workspace.visualEvidencePhase {
                case .idle:
                    emptyState
                case .preparing, .persisted, .analyzing:
                    workingState
                case .ready:
                    proposalState
                case .failed:
                    failedState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .scoutPanel(emphasized: workspace.visualEvidencePhase == .ready)
        .accessibilityIdentifier("scout.visualEvidence.panel")
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(ScoutColors.cyan)
            Text("Bring the room's sketch into discovery")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
            Text("JPEG, PNG, HEIC, or HEIF · one still image · metadata removed")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
                .multilineTextAlignment(.center)
            importButton(compact: false)
        }
        .padding(14)
    }

    private var workingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(phaseTitle)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
            if let message = workspace.visualEvidenceMessage {
                Text(message)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if workspace.visualEvidenceAsset != nil {
                Label("Evidence is already durable", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ScoutColors.mint)
            }
        }
        .padding(14)
    }

    private var proposalState: some View {
        VStack(spacing: 0) {
            assetSummary
            if let error = workspace.visualEvidenceReviewError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ScoutColors.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(ScoutColors.coral.opacity(0.08))
                    .accessibilityIdentifier("scout.visualEvidence.reviewError")
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    if workspace.visualEvidenceProposals.isEmpty {
                        Text(workspace.visualEvidenceMessage ?? "No observations proposed.")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ScoutColors.secondaryText)
                            .padding(14)
                    } else {
                        ForEach(workspace.visualEvidenceProposals) { proposal in
                            proposalCard(proposal)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var failedState: some View {
        VStack(spacing: 9) {
            Image(systemName: workspace.visualEvidenceAsset == nil ? "xmark.circle" : "checkmark.shield")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(workspace.visualEvidenceAsset == nil ? ScoutColors.coral : ScoutColors.mint)
            Text(workspace.visualEvidenceAsset == nil ? "Import did not complete" : "Evidence retained safely")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
            Text(workspace.visualEvidenceMessage ?? "No model proposal was applied.")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            importButton(compact: false)
        }
        .padding(14)
    }

    private var assetSummary: some View {
        Group {
            if let asset = workspace.visualEvidenceAsset {
                HStack(spacing: 8) {
                    Label("\(asset.pixelWidth)×\(asset.pixelHeight)", systemImage: "photo")
                    Text("·")
                    Text(Self.formattedBytes(asset.byteCount))
                    Text("·")
                    Text("sha256 \(asset.assetSHA256.prefix(8))…")
                        .fontDesign(.monospaced)
                    Spacer(minLength: 4)
                    Text(assetReviewLabel)
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            workspace.visualEvidenceProposals.contains(where: \.needsValidation)
                                ? ScoutColors.gold
                                : ScoutColors.mint
                        )
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
                .padding(.horizontal, 11)
                .frame(height: 31)
                .background(ScoutColors.canvas.opacity(0.44))
            }
        }
    }

    private func proposalCard(_ proposal: VisualEvidenceProposalCard) -> some View {
        let isReviewing = workspace.reviewingVisualObservationIDs.contains(proposal.id)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: proposal.kind.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(reviewColor(proposal.reviewStatus))
                .frame(width: 26, height: 26)
                .background(reviewColor(proposal.reviewStatus).opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(proposal.title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ScoutColors.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(proposal.basis.rawValue.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(proposal.basis == .visible ? ScoutColors.cyan : ScoutColors.indigo)
                    Text("\(Int(proposal.confidence * 100))%")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(reviewColor(proposal.reviewStatus))
                }
                Text(proposal.detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(2)
                Text(reviewTrustCopy(proposal.reviewStatus))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(reviewColor(proposal.reviewStatus).opacity(0.9))

                if proposal.reviewStatus == .proposed {
                    HStack(spacing: 7) {
                        if isReviewing {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Saving review…")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(ScoutColors.secondaryText)
                        } else {
                            Button("Confirm observation") {
                                workspace.confirmVisualObservation(proposal.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(ScoutColors.mint)
                            .foregroundStyle(ScoutColors.canvas)
                            .accessibilityIdentifier("scout.visualEvidence.confirm.\(proposal.id)")

                            Button("Reject observation") {
                                workspace.rejectVisualObservation(proposal.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(ScoutColors.coral)
                            .accessibilityIdentifier("scout.visualEvidence.reject.\(proposal.id)")
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(9)
        .background(
            reviewColor(proposal.reviewStatus).opacity(proposal.reviewStatus == .rejected ? 0.025 : 0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(reviewColor(proposal.reviewStatus).opacity(0.20), lineWidth: 1)
        )
        .opacity(proposal.reviewStatus == .rejected ? 0.72 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(proposal.reviewStatus.label) \(proposal.kind.rawValue), \(proposal.title)")
    }

    private var assetReviewLabel: String {
        let remaining = workspace.visualEvidenceProposals.filter(\.needsValidation).count
        return remaining == 0 ? "REVIEW COMPLETE" : "\(remaining) NEED REVIEW"
    }

    private func reviewColor(_ status: VisualEvidenceReviewStatus) -> Color {
        switch status {
        case .proposed: ScoutColors.gold
        case .confirmed: ScoutColors.mint
        case .rejected: ScoutColors.coral
        }
    }

    private func reviewTrustCopy(_ status: VisualEvidenceReviewStatus) -> String {
        switch status {
        case .proposed: "MODEL PROPOSAL · NOT GRAPH STATE"
        case .confirmed: "HUMAN-CONFIRMED · EVIDENCE ONLY · NOT GRAPH STATE"
        case .rejected: "REJECTED · EXCLUDED FROM USE"
        }
    }

    private func importButton(compact: Bool) -> some View {
        Button {
            workspace.importVisualEvidence()
        } label: {
            Label(compact ? "Import" : "Import whiteboard or image", systemImage: "photo.badge.plus")
                .font(.system(size: compact ? 8 : 9, weight: .semibold, design: .rounded))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(workspace.visualEvidencePhase.isWorking)
        .accessibilityIdentifier("scout.visualEvidence.panelImport")
    }

    private var phaseTitle: String {
        switch workspace.visualEvidencePhase {
        case .preparing: "Preparing visual evidence"
        case .persisted: "Evidence committed"
        case .analyzing: "Extracting bounded observations"
        default: "Working"
        }
    }

    private static func formattedBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

#Preview("Visual evidence") {
    VisualEvidencePanel(workspace: ScoutWorkspace(completed: true))
        .frame(width: 460, height: 300)
        .padding()
        .background(ScoutColors.canvas)
        .preferredColorScheme(.dark)
}
