import SwiftUI

/// The navigation-bar title of a session: its name, and under it what the
/// session is doing (``SessionActivity``). The limit-pause countdown refreshes
/// every minute.
struct SessionTitleView: View {
    let title: Text
    let activity: SessionActivity?
    let agentName: String

    var body: some View {
        VStack(spacing: 1) {
            title
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let activity {
                TimelineView(.everyMinute) { context in
                    SessionActivityLabel(activity: activity, agentName: agentName, now: context.date)
                }
            }
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .combine)
    }
}

/// One line: a tinted glyph (a pulse while working) and the activity label.
struct SessionActivityLabel: View {
    let activity: SessionActivity
    let agentName: String
    var now: Date = Date()

    var body: some View {
        HStack(spacing: 4) {
            if activity.isWorking {
                LivePulse()
                    .scaleEffect(0.7)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: activity.symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(verbatim: activity.label(agentName: agentName, now: now))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch activity.tone {
        case .active: return Theme.accent
        case .attention: return Theme.warning
        case .warning: return Theme.danger
        case .quiet, .paused: return Theme.textTertiary
        }
    }
}

/// What the send button can do while a turn runs.
struct ComposeSteering: Equatable {
    /// Native steering is available: a message can go into the running turn.
    var canInsert = false
    /// The turn is held only for background work: send delivers at once.
    var deliverNow = false
}

/// Messages delivered into the running turn, shown until it ends.
struct InsertedNotesView: View {
    let notes: [SessionDetailViewModel.InsertedNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: note.delivered ? "checkmark.circle.fill" : "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(note.delivered ? Theme.accent : Theme.textTertiary)
                    Text(verbatim: note.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(verbatim: note.delivered ? "Inserted" : "Inserting…")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .padding(.bottom, 6)
    }
}

/// Messages waiting for the running turn to end. Each can be sent now (into
/// the turn when it can take it, or as the next prompt), edited, or dropped.
///
/// The rows sit above the message bar while a turn streams, so the view is
/// rebuilt constantly. To keep an open menu from closing under the finger,
/// the view is `Equatable` (its body only reruns when the queue or
/// `canSendNow` changes) and every row's menu lists the same items in every
/// state; "Send now" is disabled rather than hidden.
struct QueuedMessagesView: View, Equatable {
    let items: [SessionDetailViewModel.QueuedMessage]
    let canSendNow: Bool
    let onSendNow: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onRemove: (UUID) -> Void

    /// The actions behind a queued row: the ⋯ menu and the long-press menu.
    /// The same list whether or not the message can be sent now.
    enum Action: CaseIterable, Equatable {
        case sendNow
        case edit
        case remove

        var title: String {
            switch self {
            case .sendNow: "Send now"
            case .edit: "Edit"
            case .remove: "Remove"
            }
        }

        var systemImage: String {
            switch self {
            case .sendNow: "arrow.up.circle"
            case .edit: "pencil"
            case .remove: "trash"
            }
        }

        func isEnabled(canSendNow: Bool) -> Bool { self != .sendNow || canSendNow }
    }

    /// A queued message never changes under its id (editing takes it out of
    /// the queue), so the ids say whether the rows changed. The closures
    /// belong to the session's view model, which outlives this view.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items.map(\.id) == rhs.items.map(\.id) && lhs.canSendNow == rhs.canSendNow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: items.count == 1 ? "1 message queued for when the turn ends"
                     : "\(items.count) messages queued for when the turn ends")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 2)
            ForEach(items, id: \.id) { item in
                row(item)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .padding(.bottom, 6)
    }

    private func row(_ item: SessionDetailViewModel.QueuedMessage) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: item.text.isEmpty ? "(\(item.attachments.count) image)" : item.text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { actions(for: item) }
            Menu {
                actions(for: item)
            } label: {
                // A 15 pt glyph in a 44 pt target (Apple's minimum).
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Queued message actions")
            Button { onRemove(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove queued message")
        }
    }

    @ViewBuilder
    private func actions(for item: SessionDetailViewModel.QueuedMessage) -> some View {
        ForEach(Action.allCases, id: \.self) { action in
            Button(role: action == .remove ? .destructive : nil) {
                perform(action, on: item.id)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(!action.isEnabled(canSendNow: canSendNow))
        }
    }

    private func perform(_ action: Action, on id: UUID) {
        switch action {
        case .sendNow: onSendNow(id)
        case .edit: onEdit(id)
        case .remove: onRemove(id)
        }
    }
}

/// One tap to let the agent keep going: sends "continue".
struct ContinueChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Continue")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .hairlineBorder(18, color: Theme.accent.opacity(0.35))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Sends “continue” so the agent keeps going"))
    }
}
