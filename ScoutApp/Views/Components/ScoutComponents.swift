import SwiftUI

struct ScoutPanelHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let trailing: () -> Trailing

    init(
        eyebrow: String? = nil,
        title: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ScoutSpacing.medium) {
            VStack(alignment: .leading, spacing: 3) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(ScoutColors.secondaryText)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(ScoutColors.primaryText)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension ScoutPanelHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

struct EvidenceBadge: View {
    let kind: EvidenceKind
    var compact = false

    var body: some View {
        Label(kind.rawValue, systemImage: kind.symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
            .foregroundStyle(kind.color)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 4 : 5)
            .background(kind.color.opacity(0.11), in: Capsule())
            .overlay(Capsule().stroke(kind.color.opacity(0.22), lineWidth: 1))
            .accessibilityLabel("Provenance: \(kind.rawValue)")
    }
}

struct StatusDot: View {
    let color: Color
    var pulses = false

    var body: some View {
        ZStack {
            if pulses {
                Circle()
                    .fill(color.opacity(0.20))
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .accessibilityHidden(true)
    }
}

struct MetricPill: View {
    let symbol: String
    let value: String
    let label: String
    var tint = ScoutColors.blue

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ScoutColors.panelRaised, in: Capsule())
        .overlay(Capsule().stroke(ScoutColors.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct ScoutIconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(isActive ? ScoutColors.canvas : ScoutColors.secondaryText)
                .background(isActive ? ScoutColors.mint : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(ScoutColors.primaryText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(ScoutColors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(24)
    }
}

#Preview("Scout components") {
    VStack(spacing: 16) {
        ScoutPanelHeader(eyebrow: "Trust layer", title: "Evidence inspector")
        HStack {
            EvidenceBadge(kind: .heard)
            EvidenceBadge(kind: .inferred)
            EvidenceBadge(kind: .proposed)
            MetricPill(symbol: "checkmark.shield", value: "92%", label: "grounded")
        }
    }
    .padding(30)
    .frame(width: 620)
    .background(ScoutColors.canvas)
    .preferredColorScheme(.dark)
}
