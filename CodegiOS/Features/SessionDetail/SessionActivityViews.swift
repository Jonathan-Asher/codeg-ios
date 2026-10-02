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
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// Messages waiting for the running turn to end. Each can be sent now (into
/// the turn when it can take it, or as the next prompt), edited, or dropped.
struct QueuedMessagesView: View {
    let items: [SessionDetailViewModel.QueuedMessage]
    let canSendNow: Bool
    let onSendNow: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: items.count == 1 ? "1 message queued for when the turn ends"
                     : "\(items.count) messages queued for when the turn ends")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.textTertiary)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(verbatim: item.text.isEmpty ? "(\(item.attachments.count) image)" : item.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        if canSendNow {
                            Button { onSendNow(item.id) } label: {
                                Label("Send now", systemImage: "arrow.up.circle")
                            }
                        }
                        Button { onEdit(item.id) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) { onRemove(item.id) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Queued message actions")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
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
