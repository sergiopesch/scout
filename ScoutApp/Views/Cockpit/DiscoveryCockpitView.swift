import SwiftUI

struct DiscoveryCockpitView: View {
    @Bindable var workspace: ScoutWorkspace

    var body: some View {
        VSplitView {
            CustomerGraphView(workspace: workspace)
                .frame(minHeight: 300, idealHeight: 470, maxHeight: .infinity)
                .layoutPriority(2)

            LiveTranscriptView(workspace: workspace)
                .frame(minHeight: 190, idealHeight: 260, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background(Color.clear)
        .accessibilityIdentifier("scout.discoveryCockpit")
    }
}

#Preview("Discovery cockpit") {
    DiscoveryCockpitView(workspace: ScoutWorkspace(completed: true))
        .frame(width: 1240, height: 760)
        .preferredColorScheme(.dark)
}
