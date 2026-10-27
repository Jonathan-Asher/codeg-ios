import SwiftUI

// MARK: - A session's hits

/// One session's message hits, as one card: the session (agent, title,
/// folder) and its best hit's excerpt, with the session's other hits folded
/// under "N more matches". Each hit opens the session at its message.
struct MessageHitCard: View {
    let group: MessageSearchGroup
    var folderName: String?
    /// The session open (iPad) or opened last (iPhone), outlined like a row.
    var isSelected = false
    @Binding var isExpanded: Bool
    let onOpen: (MessageSearchHit) -> Void

    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onOpen(group.best) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    MessageHitExcerpt(hit: group.best, agent: group.agentType)
                }
                .padding(.horizontal, SessionRowStyle.card.contentInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HitRowButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spokenSession + ". " + MessageHitExcerpt.spoken(group.best, agent: group.agentType)))
            .accessibilityHint(Text("Opens the session at this message"))

            if !group.more.isEmpty {
                if isExpanded {
                    ForEach(group.more, id: \.turnIdx) { hit in
                        divider
                        Button { onOpen(hit) } label: {
                            MessageHitExcerpt(hit: hit, agent: group.agentType)
                                .padding(.horizontal, SessionRowStyle.card.contentInset)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HitRowButtonStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: MessageHitExcerpt.spoken(hit, agent: group.agentType)))
                        .accessibilityHint(Text("Opens the session at this message"))
                    }
                }
                divider
                Button {
                    withAnimation(Theme.Motion.expand) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if isExpanded {
                            Text("Show fewer")
                        } else {
                            Text("\(group.more.count) more matches")
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, SessionRowStyle.card.contentInset)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HitRowButtonStyle())
            }
        }
        .background { SessionRowSurface(style: .card, isSelected: isSelected, isPressed: false) }
        .clipShape(SessionRowStyle.card.shape)
    }

    private var divider: some View {
        Divider()
            .overlay(Theme.hairline)
            .padding(.leading, SessionRowStyle.card.contentInset)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: group.agentType, size: avatarSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title
                HStack(spacing: 5) {
                    Text(verbatim: group.agentType.shortName)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                    if let folderName {
                        Text(verbatim: "·")
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: "folder")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                        Text(verbatim: folderName)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.footnote)
            }
        }
    }

    /// The title, laid out in its own direction: a Hebrew title reads right
    /// to left from the right edge.
    @ViewBuilder
    private var title: some View {
        if let title = group.title {
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blockDirection(TextDirection.detect(title))
        } else {
            Text("Untitled session")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var spokenSession: String {
        var parts = [group.title ?? String(localized: "Untitled session"), group.agentType.displayName]
        if let folderName { parts.append(String(localized: "folder \(folderName)")) }
        return parts.joined(separator: ", ")
    }
}

/// A hit's excerpt: whose message it was, then the text around the match
/// with the matched words lit. It reads in the excerpt's own direction, so a
/// Hebrew one starts at the right edge, its "You" first.
struct MessageHitExcerpt: View {
    let hit: MessageSearchHit
    let agent: AgentType

    var body: some View {
        let snippet = MessageSnippet(hit.snippet)
        Text(Self.attributed(snippet, role: Self.roleLabel(hit.role, agent: agent)))
            .font(.subheadline)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockDirection(TextDirection.detect(snippet.text))
    }

    /// "You", the agent's name, or "System".
    static func roleLabel(_ role: MessageSearchRole, agent: AgentType) -> String {
        switch role {
        case .user: return String(localized: "You")
        case .assistant: return agent.shortName
        case .system: return String(localized: "System")
        }
    }

    /// The role in semibold, then the excerpt, its matches highlighted.
    static func attributed(_ snippet: MessageSnippet, role: String) -> AttributedString {
        var out = AttributedString(role + " · ")
        out.font = .subheadline.weight(.semibold)
        out.foregroundColor = Theme.textSecondary
        for segment in snippet.segments {
            var piece = AttributedString(segment.text)
            if segment.marked {
                piece.font = .subheadline.weight(.semibold)
                piece.foregroundColor = Theme.textPrimary
                piece.backgroundColor = Theme.searchMatch
            } else {
                piece.foregroundColor = Theme.textSecondary
            }
            out += piece
        }
        return out
    }

    /// For VoiceOver: whose message, and its text.
    static func spoken(_ hit: MessageSearchHit, agent: AgentType) -> String {
        "\(roleLabel(hit.role, agent: agent)): \(MessageSnippet(hit.snippet).text)"
    }
}

/// A row inside a hit card: the pressed row darkens (the card clips it to
/// its corners).
private struct HitRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { if configuration.isPressed { Theme.pressed } }
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Pieces of the results list

/// "Sessions", "Messages": a section of the search results.
struct SearchSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet line in the results: the short-query hint, "No messages match",
/// a failed message search with its retry.
struct SearchNoteRow: View {
    let text: LocalizedStringKey
    var symbol: String?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
    }
}

// MARK: - From the Chats filter

/// The Chats filter's way to the server search, under the field: "Search
/// messages for “…”". The filter itself stays local and instant.
struct SearchMessagesRow: View {
    let query: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "text.magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Text("Search messages for “\(query)”")
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, SessionRowStyle.card.contentInset)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(SessionRowStyle.card.shape)
        }
        .buttonStyle(SessionRowButtonStyle(style: .card, isSelected: false))
    }
}

/// Runs the server search for some words: the Search tab with them on
/// iPhone, the search pushed in the content column on iPad. Set by
/// `RootView`; nil in previews and tests.
struct OpenMessageSearchAction {
    let perform: (String) -> Void
    func callAsFunction(_ query: String) { perform(query) }
}

private struct OpenMessageSearchKey: EnvironmentKey {
    static let defaultValue: OpenMessageSearchAction? = nil
}

extension EnvironmentValues {
    var openMessageSearch: OpenMessageSearchAction? {
        get { self[OpenMessageSearchKey.self] }
        set { self[OpenMessageSearchKey.self] = newValue }
    }
}

extension Theme {
    /// Behind the words a search matched, and the row a hit opened at: a
    /// highlighter yellow, whatever the accent.
    static let searchMatch = Color(light: Color(red: 1.0, green: 0.80, blue: 0.16).opacity(0.42),
                                   dark: Color(red: 1.0, green: 0.80, blue: 0.22).opacity(0.30))
}
