import SwiftUI

/// A Pi sub-agent's own session, read-only, as a sheet over the session that
/// launched it (codeg web's `SubagentSessionDialog`): the child's task, what
/// it did and what it answered, drawn as a Pi transcript. The child lives in
/// its parent's folder and is listed nowhere else, so this is the way in. A
/// child still working keeps writing: Refresh reads it again.
struct SubagentSessionSheet: View {
    let ref: SubagentSessionRef
    let load: (String) async throws -> [MessageTurn]

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var version = 0

    enum LoadState {
        case loading
        case loaded([MessageTurn])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle(Text(verbatim: ref.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("Refresh"))
                }
            }
        }
        // The child's own runs aren't on this connection, and its rows open
        // nothing over this sheet.
        .environment(\.liveToolCards, nil)
        .environment(\.openSubagentSession, nil)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            LoadingView(label: "Loading session…")
        case .failed(let message):
            InlineErrorView(message: message) {
                Task { await reload() }
            }
        case .loaded(let turns):
            TranscriptView(turns: turns, pendingUserTurns: [], liveTurn: nil, agent: .pi, turnsVersion: version,
                           scrollTick: 0, stickTick: 0, onPinnedChange: { _ in }) {
                SubagentSessionHeader(ref: ref, isEmpty: turns.isEmpty)
            }
        }
    }

    private func reload() async {
        do {
            let turns = try await load(ref.sessionID)
            version &+= 1
            state = .loaded(turns)
        } catch is CancellationError {
            return
        } catch {
            // A refresh that fails keeps what was shown.
            if case .loaded = state { return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// Above the child's transcript: whose session it is, and that it can only be
/// read here.
private struct SubagentSessionHeader: View {
    let ref: SubagentSessionRef
    let isEmpty: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 10, weight: .semibold))
                if let agent = ref.agent, agent != ref.label {
                    Text("Sub-agent session · \(agent) · read-only")
                } else {
                    Text("Sub-agent session · read-only")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            if isEmpty {
                EmptyStateView(icon: "person.2", title: "No messages yet",
                               message: "This sub-agent hasn’t written anything yet.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// What the Pi cards in a transcript read and do: the live connection's run
/// and job cards, and the sheet a row of a run card opens. One modifier, so
/// the screen's own chain stays as it is.
struct PiAgentCardsEnvironment: ViewModifier {
    let cards: LiveToolCards
    let loadSession: (String) async throws -> [MessageTurn]
    @State private var openSession: SubagentSessionRef?

    func body(content: Content) -> some View {
        content
            .environment(\.liveToolCards, cards)
            .environment(\.openSubagentSession, OpenSubagentSessionAction { openSession = $0 })
            .sheet(item: $openSession) { ref in
                SubagentSessionSheet(ref: ref, load: loadSession)
            }
    }
}
