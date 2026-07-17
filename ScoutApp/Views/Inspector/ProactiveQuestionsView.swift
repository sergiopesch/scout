import SwiftUI

struct ProactiveQuestionsView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Gap radar", title: "Ask next") {
                Text("\(workspace.unansweredQuestionCount) open")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(ScoutColors.gold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ScoutColors.gold.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, ScoutSpacing.medium)
            .padding(.vertical, 11)

            Divider().overlay(ScoutColors.stroke)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(workspace.questions) { question in
                        QuestionCard(question: question) {
                            workspace.markQuestionAsked(question.id)
                        }
                    }
                }
                .padding(10)
            }
        }
        .scoutPanel()
        .accessibilityIdentifier("scout.proactiveQuestions")
    }
}

private struct QuestionCard: View {
    let question: DiscoveryQuestion
    let toggleAsked: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 4) {
                Circle()
                    .fill(question.priority.color)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(question.priority.color.opacity(0.18))
                    .frame(width: 1, height: 32)
            }
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(question.topic.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(question.priority.color)
                    Spacer()
                    Button(action: toggleAsked) {
                        Image(systemName: question.isAsked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(question.isAsked ? ScoutColors.mint : ScoutColors.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(question.isAsked ? "Mark as open" : "Mark as asked")
                    .accessibilityLabel(question.isAsked ? "Mark question as open" : "Mark question as asked")
                }
                Text(question.text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(question.isAsked ? ScoutColors.secondaryText : ScoutColors.primaryText)
                    .strikethrough(question.isAsked, color: ScoutColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(question.rationale)
                    .font(.system(size: 8))
                    .foregroundStyle(ScoutColors.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .background(Color.white.opacity(question.isAsked ? 0.015 : 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))
        .opacity(question.isAsked ? 0.65 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scout.question.\(question.id)")
    }
}

struct QuickWinsSummaryView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScoutPanelHeader(eyebrow: "Value radar", title: "Quick wins") {
                Button("View action pack") {
                    workspace.destination = .actionPack
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ScoutColors.mint)
                .accessibilityIdentifier("scout.quickWins.openActionPack")
            }
            .padding(.horizontal, ScoutSpacing.medium)
            .padding(.vertical, 10)

            Divider().overlay(ScoutColors.stroke)

            if workspace.quickWins.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(ScoutColors.gold)
                    Text("Scout is ranking opportunities as evidence arrives.")
                        .font(.system(size: 9))
                        .foregroundStyle(ScoutColors.secondaryText)
                    Spacer()
                }
                .padding(12)
            } else {
                VStack(spacing: 7) {
                    ForEach(workspace.quickWins.prefix(2)) { win in
                        HStack(spacing: 9) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ScoutColors.gold)
                                .frame(width: 25, height: 25)
                                .background(ScoutColors.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(win.title)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(ScoutColors.primaryText)
                                Text("Impact \(win.impact)/5 · Effort \(win.effort)/5 · \(win.timeToValue)")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(ScoutColors.secondaryText)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .scoutPanel()
        .accessibilityIdentifier("scout.quickWins")
    }
}

#Preview("Discovery intelligence") {
    VStack(spacing: 12) {
        ProactiveQuestionsView(workspace: ScoutWorkspace(completed: true))
            .frame(height: 360)
        QuickWinsSummaryView(workspace: ScoutWorkspace(completed: true))
    }
    .padding(16)
    .frame(width: 380, height: 600)
    .background(ScoutColors.canvas)
    .preferredColorScheme(.dark)
}
