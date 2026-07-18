import SwiftUI

struct CustomerGraphView: View {
    @Bindable var workspace: ScoutWorkspace
    @State private var zoom: CGFloat = 1
    @State private var showRelationshipLabels = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entities = workspace.entities
        let relationships = workspace.relationships
        let entitiesByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        let layoutSnapshot = entities.map(GraphLayoutSnapshot.init)
        let needsValidationCount = relationships.reduce(into: 0) { count, relationship in
            if relationship.needsValidation { count += 1 }
        }

        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Living customer model", title: "Current-state architecture") {
                HStack(spacing: 6) {
                    graphLegend
                    ScoutIconButton(symbol: showRelationshipLabels ? "tag.fill" : "tag", help: "Toggle relationship labels", isActive: showRelationshipLabels) {
                        showRelationshipLabels.toggle()
                    }
                    ScoutIconButton(symbol: "minus.magnifyingglass", help: "Zoom out") {
                        zoom = max(0.78, zoom - 0.08)
                    }
                    ScoutIconButton(symbol: "plus.magnifyingglass", help: "Zoom in") {
                        zoom = min(1.18, zoom + 0.08)
                    }
                    ScoutIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit graph") {
                        zoom = 1
                    }
                }
            }
            .padding(.horizontal, ScoutSpacing.medium)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider().overlay(ScoutColors.stroke)

            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    GraphGrid()

                    GraphEdgesLayer(
                        entitiesByID: entitiesByID,
                        relationships: relationships,
                        canvasSize: size
                    )

                    if showRelationshipLabels {
                        ForEach(Array(relationships.enumerated()), id: \.element.id) { index, relationship in
                            if let labelPoint = labelPoint(
                                for: relationship,
                                at: index,
                                in: size,
                                entitiesByID: entitiesByID
                            ) {
                                HStack(spacing: 3) {
                                    Text(relationship.label)
                                    Image(systemName: relationship.needsValidation ? "questionmark.circle.fill" : relationship.provenance.symbol)
                                    Text(relationship.provenance.rawValue)
                                }
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundStyle(relationship.needsValidation ? ScoutColors.gold : relationship.provenance.color)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(ScoutColors.canvas.opacity(0.90), in: Capsule())
                                    .overlay(Capsule().stroke(relationship.provenance.color.opacity(0.35), lineWidth: 1))
                                    .position(labelPoint)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(relationship.label), \(relationship.provenance.rawValue), \(relationship.needsValidation ? "needs validation" : "validated"), \(Int(relationship.confidence * 100)) percent confidence")
                            }
                        }
                    }

                    ForEach(entities) { entity in
                        GraphEntityView(
                            entity: entity,
                            isSelected: workspace.selectedEntityID == entity.id
                        ) {
                            workspace.selectEntity(entity.id)
                        }
                        .position(point(for: entity, in: size))
                        .transition(reduceMotion ? .identity : .scale(scale: 0.82).combined(with: .opacity))
                    }
                }
                .scaleEffect(zoom)
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.52, extraBounce: 0.08),
                    value: layoutSnapshot
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: zoom)
            }
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Customer reality graph with \(entities.count) entities and \(relationships.count) relationships; \(needsValidationCount) relationships need validation")
            .accessibilityIdentifier("scout.customerGraph")
        }
        .scoutPanel()
    }

    private var graphLegend: some View {
        HStack(spacing: 8) {
            legendDot(label: "System", color: ScoutColors.blue)
            legendDot(label: "Process", color: ScoutColors.mint)
            legendDot(label: "Risk", color: ScoutColors.coral)
            legendDot(label: "Needs review", color: ScoutColors.gold)
        }
        .padding(.trailing, 4)
    }

    private func legendDot(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func point(for entity: GraphEntity, in size: CGSize) -> CGPoint {
        CGPoint(
            x: max(86, min(size.width - 86, size.width * entity.x)),
            y: max(40, min(size.height - 40, size.height * entity.y))
        )
    }

    /// Relationship labels deliberately sample different points and sides of their edge. A single
    /// midpoint makes independent relationships collapse into one unreadable badge as the graph
    /// becomes denser.
    private func labelPoint(
        for relationship: GraphRelationship,
        at index: Int,
        in size: CGSize,
        entitiesByID: [String: GraphEntity]
    ) -> CGPoint? {
        guard let source = entitiesByID[relationship.sourceID],
              let target = entitiesByID[relationship.targetID] else {
            return nil
        }
        let sourcePoint = point(for: source, in: size)
        let targetPoint = point(for: target, in: size)
        let dx = targetPoint.x - sourcePoint.x
        let dy = targetPoint.y - sourcePoint.y
        let length = max(1, hypot(dx, dy))
        let progress: CGFloat = [0.42, 0.50, 0.58][index % 3]
        let lateralOffsets: [CGFloat] = [-14, 10, -6, 16, 3]
        let lateral = lateralOffsets[index % lateralOffsets.count]
        let rawX = sourcePoint.x + dx * progress - (dy / length) * lateral
        let rawY = sourcePoint.y + dy * progress + (dx / length) * lateral
        return CGPoint(
            x: max(50, min(size.width - 50, rawX)),
            y: max(24, min(size.height - 24, rawY))
        )
    }
}

private struct GraphLayoutSnapshot: Hashable {
    let id: String
    let x: Double
    let y: Double

    init(_ entity: GraphEntity) {
        id = entity.id
        x = entity.x
        y = entity.y
    }
}

private struct GraphGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(Color.white.opacity(0.026)), lineWidth: 0.6)
        }
        .background(
            RadialGradient(
                colors: [ScoutColors.blue.opacity(0.055), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
        )
        .accessibilityHidden(true)
    }
}

private struct GraphEdgesLayer: View {
    let entitiesByID: [String: GraphEntity]
    let relationships: [GraphRelationship]
    let canvasSize: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            for relationship in relationships {
                guard let source = entitiesByID[relationship.sourceID],
                      let target = entitiesByID[relationship.targetID] else { continue }

                let start = point(for: source)
                let end = point(for: target)
                let controlOffset = max(24, abs(end.x - start.x) * 0.34)
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + (end.x >= start.x ? controlOffset : -controlOffset), y: start.y),
                    control2: CGPoint(x: end.x - (end.x >= start.x ? controlOffset : -controlOffset), y: end.y)
                )

                let color = relationship.isFriction
                    ? ScoutColors.coral.opacity(0.62)
                    : relationship.provenance.color.opacity(relationship.needsValidation ? 0.48 : 0.68)
                let style = StrokeStyle(
                    lineWidth: relationship.isFriction ? 1.5 : 1.2,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: relationship.needsValidation ? [3, 4] : relationship.isFriction ? [5, 5] : []
                )
                context.stroke(path, with: .color(color), style: style)
                context.fill(
                    Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)),
                    with: .color(color)
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func point(for entity: GraphEntity) -> CGPoint {
        CGPoint(
            x: max(86, min(canvasSize.width - 86, canvasSize.width * entity.x)),
            y: max(40, min(canvasSize.height - 40, canvasSize.height * entity.y))
        )
    }
}

private struct GraphEntityView: View {
    let entity: GraphEntity
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(entity.kind.color.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: entity.kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(entity.kind.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(ScoutColors.primaryText)
                        .lineLimit(1)
                    Text(entity.subtitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 3)
                Circle()
                    .fill(entity.provenance.color)
                    .frame(width: 6, height: 6)
                    .help(entity.provenance.rawValue)
            }
            .padding(8)
            .frame(width: 168, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected || isHovering ? ScoutColors.panelRaised : ScoutColors.panel.opacity(0.96))
                    .shadow(color: entity.kind.color.opacity(isSelected ? 0.18 : 0.06), radius: isSelected ? 13 : 5, y: 3)
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(entity.kind.color)
                    .frame(width: 3, height: 24)
                    .padding(.leading, 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? entity.kind.color.opacity(0.72) : ScoutColors.stroke, lineWidth: isSelected ? 1.4 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering && !reduceMotion ? 1.025 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel("\(entity.kind.rawValue), \(entity.title), \(entity.subtitle), \(entity.provenance.rawValue), \(Int(entity.confidence * 100)) percent confidence")
        .accessibilityHint("Select to inspect supporting evidence")
        .accessibilityIdentifier("scout.graphEntity.\(entity.id)")
    }
}

#Preview("Customer graph") {
    CustomerGraphView(workspace: ScoutWorkspace(completed: true))
        .padding(16)
        .frame(width: 940, height: 520)
        .background(ScoutColors.canvas)
        .preferredColorScheme(.dark)
}
