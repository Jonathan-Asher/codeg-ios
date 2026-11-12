import SwiftUI

// A session whose agent no longer has its history (codeg fork.230,
// `history_unavailable`): it can't be resumed or forked, so it opens
// read-only. The message bar's place says why, with "Start a new session
// from this"; above it, the copy this iPhone kept (the transcript, labelled
// so) or the text the server saved (``SavedHistoryView``). codeg's
// `HistoryUnavailableView` is the desktop's.

/// In place of the message bar: what happened, what is shown instead, and
/// "Start a new session from this".
struct HistoryUnavailableBanner: View {
    let info: HistoryUnavailable
    let agentName: String
    let copy: LostHistoryCopy
    /// Messages this session never sent, which go with the new session.
    var unsentCount = 0
    /// The copy shown is in, so the new session can start from it.
    var ready = true
    /// Nil where this screen can't open a new session (previews).
    var onStartNew: (() -> Void)?

    private var reason: Text {
        if let days = info.cleanupDays {
            return Text("\(agentName) deleted this session’s history because it was older than \(days) days.")
        }
        return Text("The agent’s history file for this session no longer exists.")
    }

    private var consequence: Text {
        switch copy {
        case .iPhone:
            return Text("It can’t be resumed or forked. This is the copy kept on this iPhone.")
        case .saved where info.savedTurns > 0:
            return Text("It can’t be resumed or forked. This is the text codeg saved for search: a partial copy, with the messages only and no tool output.")
        case .saved:
            return Text("It can’t be resumed or forked, and codeg kept no text of it.")
        }
    }

    private var startHint: Text {
        if copy == .saved, info.savedTurns <= 0 {
            return Text("Opens a new \(agentName) session in this folder. There is no saved text to carry over.")
        }
        return Text("Opens a new \(agentName) session in this folder with the saved text in its message box. Nothing is sent until you send it.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text("History unavailable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                reason
                consequence
                if unsentCount > 0 {
                    Text("\(unsentCount) unsent messages go with it.")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            if let onStartNew {
                Button(action: onStartNew) {
                    Label("Start a new session from this", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accent)
                .disabled(!ready)
                .accessibilityHint(startHint)
                .accessibilityIdentifier("history-unavailable-start-new")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg, color: Theme.warning.opacity(0.35))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history-unavailable-banner")
    }
}

/// Over the transcript this iPhone kept of a session whose history is gone.
struct KeptCopyLabel: View {
    var body: some View {
        Label("Copy kept on this iPhone", systemImage: "iphone")
            .font(Theme.Typography.metaLabel)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityIdentifier("kept-copy-label")
    }
}

/// The text the server's message search saved of a session whose history is
/// gone, oldest first, opening at the latest: each message under who wrote
/// it, the agent's as Markdown. Text only: no tool calls, no tool output.
struct SavedHistoryView: View {
    let state: SessionDetailViewModel.SavedCopyState
    /// How many turns the server says it saved.
    let savedTurns: Int
    let agentName: String
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if savedTurns > 0 {
                    Text("Saved copy · \(savedTurns) messages · text only")
                        .font(Theme.Typography.metaLabel)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("saved-copy-label")
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("saved-copy")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .notLoaded, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading the saved copy…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Couldn’t load the saved copy: \(message)")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        case .loaded(let turns) where turns.isEmpty:
            Text("codeg kept no text of this session.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        case .loaded(let turns):
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                SavedTurnView(turn: turn, agentName: agentName)
            }
        }
    }
}

/// One saved message: who wrote it, then its text.
private struct SavedTurnView: View {
    let turn: SavedTurn
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            speaker
                .font(Theme.Typography.metaLabel)
                .foregroundStyle(Theme.textTertiary)
            switch turn.role {
            case .user:
                MarkdownText(raw: turn.content)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.30))
            case .assistant:
                MarkdownContent(raw: turn.content)
            case .system:
                Text(verbatim: turn.content)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speaker: Text {
        switch turn.role {
        case .user: return Text("You")
        case .assistant: return Text(verbatim: agentName)
        case .system: return Text("System")
        }
    }
}
