import SwiftUI

struct LiveTranscriptView: View {
    let workspace: ScoutWorkspace
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleUtterances: [TranscriptUtterance] {
        guard !searchText.isEmpty else { return workspace.transcript }
        return workspace.transcript.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            $0.speaker.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        let utterances = visibleUtterances
        let finalUtteranceID = utterances.last?.id

        VStack(spacing: 0) {
            ScoutPanelHeader(title: "Transcript") {
                if !workspace.transcript.isEmpty {
                    HStack(spacing: 9) {
                        Label(speakerCountLabel, systemImage: "person.2")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ScoutColors.secondaryText)
                        SearchField(text: $searchText)
                    }
                }
            }
            .padding(.horizontal, ScoutSpacing.medium)
            .padding(.vertical, 11)

            Divider().overlay(ScoutColors.stroke)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(utterances) { utterance in
                            TranscriptRow(utterance: utterance)
                                .id(utterance.id)
                            if utterance.id != finalUtteranceID {
                                Divider()
                                    .overlay(ScoutColors.stroke.opacity(0.7))
                                    .padding(.leading, 48)
                            }
                        }

                        if workspace.captureState == .listening && searchText.isEmpty {
                            ListeningRow()
                                .id("listening-indicator")
                        }
                    }
                    .padding(.horizontal, ScoutSpacing.medium)
                }
                .onChange(of: workspace.transcript.count) { _, _ in
                    guard workspace.captureState == .listening, searchText.isEmpty else { return }
                    if reduceMotion {
                        proxy.scrollTo("listening-indicator", anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("listening-indicator", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .scoutPanel()
        .accessibilityIdentifier("scout.liveTranscript")
    }

    private var speakerCountLabel: String {
        let count = Set(workspace.transcript.map(\.speaker.id)).count
        return "\(count) \(count == 1 ? "speaker" : "speakers")"
    }
}

private struct TranscriptRow: View {
    let utterance: TranscriptUtterance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(utterance.speaker.tone.color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Text(utterance.speaker.initials)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(utterance.speaker.tone.color)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(utterance.speaker.name)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ScoutColors.primaryText)
                    Text(utterance.speaker.role)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ScoutColors.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    EvidenceBadge(kind: utterance.provenance, compact: true)
                    if utterance.commitState != .committed {
                        TranscriptCommitBadge(state: utterance.commitState)
                    }
                    Text(utterance.timestamp)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
                Text(utterance.text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ScoutColors.primaryText.opacity(0.90))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(utterance.timestamp), \(utterance.speaker.name), \(utterance.text), \(utterance.provenance.rawValue), \(utterance.commitState.accessibilityLabel), \(Int(utterance.confidence * 100)) percent confidence")
        .accessibilityIdentifier("scout.utterance.\(utterance.id)")
    }
}

private struct TranscriptCommitBadge: View {
    let state: TranscriptCommitState

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.24), lineWidth: 1))
            .accessibilityLabel(state.accessibilityLabel)
    }

    private var label: String {
        switch state {
        case .pending: "Stabilising"
        case .committed: "Committed"
        case .uncommitted: "Uncommitted"
        }
    }

    private var symbol: String {
        switch state {
        case .pending: "clock"
        case .committed: "checkmark.seal.fill"
        case .uncommitted: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .pending: ScoutColors.gold
        case .committed: ScoutColors.mint
        case .uncommitted: ScoutColors.coral
        }
    }
}

private struct ListeningRow: View {
    var body: some View {
        HStack(spacing: 11) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(ScoutColors.mint.opacity(0.78))
                        .frame(width: 2, height: CGFloat([7, 14, 10, 17, 8][index]))
                }
            }
            .frame(width: 34, height: 30)
            Text("Listening and stabilising the next utterance…")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ScoutColors.secondaryText)
            Spacer()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scout is listening and stabilising the next utterance")
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ScoutColors.secondaryText)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 9))
                .frame(width: 92)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(ScoutColors.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear transcript search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(ScoutColors.stroke, lineWidth: 1))
        .accessibilityIdentifier("scout.transcript.search")
    }
}

#Preview("Live transcript") {
    LiveTranscriptView(workspace: ScoutWorkspace(completed: true))
        .padding(16)
        .frame(width: 760, height: 430)
        .background(ScoutColors.canvas)
        .preferredColorScheme(.dark)
}
