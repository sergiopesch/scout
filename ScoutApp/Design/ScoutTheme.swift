import SwiftUI

private struct ScoutForcesOpaqueRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Deterministic rendering hook for snapshots and constrained compositors. Accessibility's
    /// system value remains read-only, so tests use this equivalent Scout-local override.
    var scoutForcesOpaqueRendering: Bool {
        get { self[ScoutForcesOpaqueRenderingKey.self] }
        set { self[ScoutForcesOpaqueRenderingKey.self] = newValue }
    }
}

enum ScoutColors {
    // Scout's product palette is sampled from the original mark: warm porcelain over layered
    // graphite. Meaning is also carried by copy, symbols, shape, and line treatment, so state never
    // depends on a rainbow of decorative colors.
    static let porcelain = Color(red: 250.0 / 255.0, green: 250.0 / 255.0, blue: 247.0 / 255.0)
    static let pearl = Color(red: 247.0 / 255.0, green: 247.0 / 255.0, blue: 243.0 / 255.0)
    static let graphite = Color(red: 41.0 / 255.0, green: 44.0 / 255.0, blue: 52.0 / 255.0)
    static let graphiteMid = Color(red: 29.0 / 255.0, green: 31.0 / 255.0, blue: 37.0 / 255.0)
    static let ink = Color(red: 16.0 / 255.0, green: 17.0 / 255.0, blue: 21.0 / 255.0)
    static let signalDot = Color(red: 23.0 / 255.0, green: 24.0 / 255.0, blue: 28.0 / 255.0)

    static let canvas = ink
    static let sidebar = graphiteMid.opacity(0.76)
    static let panel = graphiteMid.opacity(0.68)
    static let panelRaised = graphite.opacity(0.78)
    static let stroke = porcelain.opacity(0.09)
    static let strokeStrong = porcelain.opacity(0.17)
    static let primaryText = porcelain
    static let secondaryText = porcelain.opacity(0.62)
    static let mint = porcelain
    static let blue = porcelain.opacity(0.88)
    static let indigo = porcelain.opacity(0.76)
    static let coral = pearl
    static let gold = pearl.opacity(0.84)
    static let cyan = porcelain.opacity(0.92)
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
        case .policy: ScoutColors.porcelain.opacity(0.68)
        case .friction: ScoutColors.coral
        case .action: ScoutColors.porcelain
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
        case .draft: ScoutColors.gold
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scoutForcesOpaqueRendering) private var forceOpaque

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || forceOpaque {
            opaque(content)
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                glass(content)
            } else {
                material(content)
            }
#else
            material(content)
#endif
        }
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(
                contrast == .increased
                    ? ScoutColors.porcelain.opacity(0.24)
                    : (emphasized ? ScoutColors.strokeStrong : ScoutColors.stroke),
                lineWidth: 1
            )
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func glass(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        (emphasized ? ScoutColors.graphite : ScoutColors.graphiteMid)
                            .opacity(emphasized ? 0.34 : 0.20)
                    )
            )
            .glassEffect(
                .regular.tint(
                    emphasized
                        ? ScoutColors.gold.opacity(0.045)
                        : ScoutColors.porcelain.opacity(0.022)
                ),
                in: .rect(cornerRadius: 20)
            )
            .overlay(panelStroke)
    }
#endif

    private func material(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        (emphasized ? ScoutColors.graphite : ScoutColors.graphiteMid)
                            .opacity(emphasized ? 0.78 : 0.68)
                    )
            )
            .overlay(panelStroke)
    }

    private func opaque(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(emphasized ? ScoutColors.graphite : ScoutColors.graphiteMid)
            )
            .overlay(panelStroke)
    }
}

extension View {
    func scoutPanel(emphasized: Bool = false) -> some View {
        modifier(ScoutPanelSurface(emphasized: emphasized))
    }

    func scoutChrome(cornerRadius: CGFloat = 16) -> some View {
        modifier(ScoutChromeSurface(cornerRadius: cornerRadius))
    }
}

private struct ScoutChromeSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scoutForcesOpaqueRendering) private var forceOpaque

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || forceOpaque {
            content
                .background(
                    ScoutColors.graphiteMid,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(chromeStroke)
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(ScoutColors.graphiteMid.opacity(0.24))
                    )
                    .glassEffect(
                        .regular.tint(ScoutColors.porcelain.opacity(0.035)),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .overlay(chromeStroke)
            } else {
                fallback(content)
            }
#else
            fallback(content)
#endif
        }
    }

    private var chromeStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                contrast == .increased
                    ? ScoutColors.porcelain.opacity(0.24)
                    : ScoutColors.strokeStrong,
                lineWidth: 1
            )
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                ScoutColors.graphiteMid.opacity(0.62),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(chromeStroke)
    }
}

struct ScoutGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scoutForcesOpaqueRendering) private var forceOpaque

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if reduceTransparency || forceOpaque {
            content
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) { content }
            } else {
                content
            }
#else
            content
#endif
        }
    }
}

/// A static, logo-derived field behind every translucent workspace surface. It is intentionally
/// non-animated so live transcript and graph updates do not continuously re-render the backdrop.
struct ScoutAmbientBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [ScoutColors.graphite.opacity(0.96), ScoutColors.graphiteMid, ScoutColors.ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [ScoutColors.porcelain.opacity(0.105), Color.clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(420, geometry.size.width * 0.72)
                )

                RadialGradient(
                    colors: [ScoutColors.mint.opacity(0.105), Color.clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: max(360, geometry.size.height * 0.78)
                )

                Image("ScoutMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: min(geometry.size.width, geometry.size.height) * 0.78)
                    .opacity(0.026)
                    .blendMode(.softLight)
                    .rotationEffect(.degrees(-9))
            }
            .overlay {
                LinearGradient(
                    colors: [Color.white.opacity(0.022), Color.clear, Color.black.opacity(0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blendMode(.softLight)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
