import SwiftUI

enum ScoutColors {
    static let canvas = Color(red: 0.035, green: 0.043, blue: 0.062)
    static let sidebar = Color(red: 0.048, green: 0.059, blue: 0.084)
    static let panel = Color(red: 0.068, green: 0.080, blue: 0.108)
    static let panelRaised = Color(red: 0.087, green: 0.101, blue: 0.134)
    static let stroke = Color.white.opacity(0.09)
    static let strokeStrong = Color.white.opacity(0.16)
    static let primaryText = Color(red: 0.94, green: 0.96, blue: 0.98)
    static let secondaryText = Color(red: 0.62, green: 0.67, blue: 0.74)
    static let mint = Color(red: 0.37, green: 0.91, blue: 0.74)
    static let blue = Color(red: 0.43, green: 0.65, blue: 0.98)
    static let indigo = Color(red: 0.56, green: 0.50, blue: 0.98)
    static let coral = Color(red: 0.98, green: 0.47, blue: 0.42)
    static let gold = Color(red: 0.96, green: 0.72, blue: 0.31)
    static let cyan = Color(red: 0.31, green: 0.80, blue: 0.90)
}

enum ScoutSpacing {
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 14
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 28
}

extension SpeakerTone {
    var color: Color {
        switch self {
        case .indigo: ScoutColors.indigo
        case .teal: ScoutColors.mint
        case .coral: ScoutColors.coral
        case .gold: ScoutColors.gold
        }
    }
}

extension EvidenceKind {
    var color: Color {
        switch self {
        case .heard: ScoutColors.cyan
        case .inferred: ScoutColors.indigo
        case .proposed: ScoutColors.gold
        case .validated: ScoutColors.mint
        }
    }
}

extension GraphEntityKind {
    var color: Color {
        switch self {
        case .person: ScoutColors.indigo
        case .system: ScoutColors.blue
        case .data: ScoutColors.cyan
        case .process: ScoutColors.mint
        case .goal: ScoutColors.gold
        case .policy: Color(red: 0.75, green: 0.57, blue: 0.98)
        case .friction: ScoutColors.coral
        case .action: Color(red: 0.49, green: 0.94, blue: 0.50)
        }
    }
}

extension QuestionPriority {
    var color: Color {
        switch self {
        case .critical: ScoutColors.coral
        case .high: ScoutColors.gold
        case .explore: ScoutColors.blue
        }
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .live: ScoutColors.mint
        case .ready: ScoutColors.blue
        case .archived: ScoutColors.secondaryText
        }
    }
}

extension ArtifactReadiness {
    var color: Color {
        switch self {
        case .ready: ScoutColors.mint
        case .review: ScoutColors.gold
        case .drafting: ScoutColors.secondaryText
        }
    }
}

struct ScoutPanelSurface: ViewModifier {
    let emphasized: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(emphasized ? ScoutColors.panelRaised : ScoutColors.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(emphasized ? ScoutColors.strokeStrong : ScoutColors.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func scoutPanel(emphasized: Bool = false) -> some View {
        modifier(ScoutPanelSurface(emphasized: emphasized))
    }
}
