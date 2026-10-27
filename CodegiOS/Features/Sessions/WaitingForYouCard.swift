import SwiftUI

/// "Waiting for you" at the top of the sessions list: every question,
/// permission request and plan waiting on the user on this server, oldest
/// first (``PendingItemsStore``). A row says which session asks, how long it
/// has waited, what kind of thing waits and what is asked. Tapping it opens
/// the session (a sub-agent's parent) at the latest message, where the
/// waiting card sits above the message bar. A single-choice question with a
/// few short options can be answered right here.
struct WaitingForYouCard: View {
    let items: [PendingItem]
    /// Why the last answer from the list didn't go through.
    var error: String?
    let onOpen: (PendingItem) -> Void
    let onAnswer: (PendingItem, String) -> Void
    var onDismissError: () -> Void = {}

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        InsetDivider(leading: 60)
                            .padding(.trailing, 16)
                    }
                    PendingItemRow(item: item, onOpen: { onOpen(item) }, onAnswer: { onAnswer(item, $0) })
                        .padding(.horizontal, 6)
                }
                if let error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                        Text("Couldn't send the answer: \(error)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button(action: onDismissError) {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(items.count) waiting")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.warning)
                .tracking(0.8)
                .textCase(.uppercase)
            Text("Waiting for you")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One waiting item: the session, its age, the kind and what is asked, and
/// for a single-choice question its options as buttons.
struct PendingItemRow: View {
    let item: PendingItem
    let onOpen: () -> Void
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            title
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(verbatim: RelativeTime.compact(from: item.askedAt, relativeTo: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        meta
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        if !item.text.isEmpty {
                            Text(verbatim: item.text)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .padding(.top, 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the session")

            if let labels = item.quickAnswers {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                        Button {
                            onAnswer(label)
                        } label: {
                            Text(verbatim: label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(Theme.accent)
                                .background(Capsule().fill(Theme.accentDim))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressableRowStyle())
                        .accessibilityLabel(Text("Answer \(label)"))
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private var symbol: String {
        switch item.knownKind {
        case .permission: return "hand.raised.fill"
        case .plan: return "list.bullet.clipboard.fill"
        case .question, .none: return "questionmark.bubble.fill"
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.warning)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Theme.warning.opacity(0.16)))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var title: some View {
        if let text = item.displayTitle {
            Text(verbatim: text)
        } else {
            Text("Untitled session")
        }
    }

    private var kindLabel: Text {
        switch item.knownKind {
        case .permission: return Text("Permission")
        case .plan: return Text("Plan")
        case .question, .none: return Text("Question")
        }
    }

    /// "Question · Claude Code · Sub-agent".
    private var meta: Text {
        var line = kindLabel
        if !item.agentLabel.isEmpty { line = line + Text(verbatim: " · \(item.agentLabel)") }
        if item.isSubAgent { line = line + Text(verbatim: " · ") + Text("Sub-agent") }
        return line
    }
}
