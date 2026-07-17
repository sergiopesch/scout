import SwiftUI

struct DiscoveryCockpitView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 12) {
                CustomerGraphView(workspace: workspace)
                    .frame(minHeight: 330, maxHeight: .infinity)
                    .layoutPriority(2)
                LiveTranscriptView(workspace: workspace)
                    .frame(minHeight: 210, idealHeight: 250, maxHeight: 290)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                TrustInspectorView(workspace: workspace)
                    .frame(minHeight: 250, maxHeight: .infinity)
                    .layoutPriority(2)
                ProactiveQuestionsView(workspace: workspace)
                    .frame(minHeight: 210, idealHeight: 245, maxHeight: 270)
                QuickWinsSummaryView(workspace: workspace)
                    .frame(minHeight: 108, idealHeight: 135, maxHeight: 155)
            }
            .frame(minWidth: 326, idealWidth: 350, maxWidth: 380, maxHeight: .infinity)
        }
        .padding(12)
        .background(ScoutColors.canvas)
        .accessibilityIdentifier("scout.discoveryCockpit")
    }
}

#Preview("Discovery cockpit") {
    DiscoveryCockpitView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 1240, height: 760)
        .preferredColorScheme(.dark)
}
