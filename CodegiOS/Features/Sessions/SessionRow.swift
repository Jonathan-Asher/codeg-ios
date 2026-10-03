import SwiftUI

/// One session in a list: the Chats folder cards, a folder's full list,
/// Activity and Search. Each session is a separate tap target with a clear
/// hierarchy:
///
/// - the agent's avatar, with a corner dot for the review status;
/// - the title, prominent and up to two lines, with the relative time on the
///   right;
/// - a details line: the agent, the folder, and what the session is doing
///   (Working, Needs you, Interrupted, Paused…) whenever it is doing something.
///   An idle session shows no status tag.
///
/// ``SessionRowStyle/card`` draws the row on its own rounded surface (the
/// standalone lists); ``SessionRowStyle/inset`` sits inside an enclosing card
/// (the Chats folder cards), between inset dividers. A press highlights the
/// surface, and `isSelected` marks the session that is open (iPad) or the one
/// you just came back from (iPhone).
struct SessionRow: View {
    let conversation: ConversationSummary
    /// The session open in the detail column (iPad), or the one opened last
    /// from a list (iPhone). Drawn with an accent outline.
    let isSelected: Bool
    /// The session's folder, or `nil` to omit it (e.g. inside a Chats folder
    /// card, where the folder is already the header).
    var folderName: String?
    /// Tap handler. When `nil`, the row is display-only (no Button, no context
    /// menu).
    var onTap: (() -> Void)? = nil
    /// When set, a long-press context menu (and a VoiceOver action) offers
    /// Pin/Unpin; the label follows `conversation.isPinned`.
    var onTogglePin: (() -> Void)?
    var style: SessionRowStyle = .card

    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 34
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let onTap {
            Button(action: onTap) { rowContent }
                .buttonStyle(SessionRowButtonStyle(style: style, isSelected: isSelected))
                .contentShape(.contextMenuPreview, style.shape)
                .contextMenu {
                    if let onTogglePin {
                        Button(action: onTogglePin) { pinLabel }
                    }
                }
                .accessibilityLabel(Text(verbatim: accessibilityText))
                .accessibilityHint(Text("Opens the session"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityActions {
                    if let onTogglePin {
                        Button(action: onTogglePin) { pinLabel }
                    }
                }
        } else {
            rowContent
                .background { SessionRowSurface(style: style, isSelected: isSelected, isPressed: false) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityText))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var pinLabel: some View {
        Label(conversation.isPinned ? "Unpin" : "Pin",
              systemImage: conversation.isPinned ? "pin.slash" : "pin")
    }

    // MARK: - Layout

    /// The row's content, shared by the interactive (Button) and display-only
    /// renderings. The surface behind it comes from the button style.
    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                titleLine
                detailsLine
            }
        }
        .padding(.horizontal, style.contentInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(style.shape)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let title = conversation.trimmedTitle {
                    Text(verbatim: title)
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Untitled session")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.headline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: RelativeTime.compact(from: conversation.updatedAt))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }

    /// Agent · folder, then the status tag. At accessibility text sizes the
    /// pieces stack instead of squeezing onto one line.
    @ViewBuilder
    private var detailsLine: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                agentAndFolder
                if let tag = statusTag { SessionStatusTag(tag: tag) }
            }
        } else {
            HStack(spacing: 8) {
                agentAndFolder
                Spacer(minLength: 0)
                if let tag = statusTag { SessionStatusTag(tag: tag) }
            }
        }
    }

    private var agentAndFolder: some View {
        HStack(spacing: 5) {
            Text(verbatim: conversation.agentType.shortName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if let folderName {
                Text(verbatim: "·")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text(verbatim: folderName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Agent avatar with a status-tinted dot in the corner.
    private var avatar: some View {
        AgentAvatar(agent: conversation.agentType, size: avatarSize)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(dotTint)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(style.dotRing, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
    }

    // MARK: - Status

    /// What the session is doing (fork `turn_state` / attention / limit pause),
    /// read from the shared attention snapshot so a row can say "Needs you".
    private var activity: SessionActivity {
        SessionActivity.of(conversation, attention: AttentionStore.shared.kind(for: conversation.id))
    }

    /// The corner dot: the activity's colour when it says more than the review
    /// status (needs you, interrupted, paused), else the status tint.
    private var dotTint: Color {
        switch activity {
        case .needsYou: return Theme.warning
        case .interrupted, .connectFailed: return Theme.danger
        case .limitPaused: return Color.secondary
        default: return conversation.status.tint
        }
    }

    /// The tag on the details line, or `nil` while the session is idle.
    private var statusTag: SessionStatusTag.Model? {
        switch activity {
        case .working:
            return .init(live: true, symbol: nil, text: "Working",
                         spoken: String(localized: "Working"), tint: Theme.accent)
        case .background(let count):
            if count > 0 {
                return .init(symbol: "hourglass", text: "\(count) background",
                             spoken: String(localized: "Idle, \(count) background tasks running"),
                             tint: Theme.textSecondary)
            }
            return .init(symbol: "hourglass", text: "Background",
                         spoken: String(localized: "Idle, background work running"),
                         tint: Theme.textSecondary)
        case .needsYou:
            return .init(symbol: "hand.raised.fill", text: "Needs you",
                         spoken: String(localized: "Needs you"), tint: Theme.warning)
        case .interrupted:
            return .init(symbol: "exclamationmark.triangle.fill", text: "Interrupted",
                         spoken: String(localized: "Interrupted"), tint: Theme.danger)
        case .limitPaused(let pause):
            if pause.state == .claimed {
                return .init(symbol: "pause.circle.fill", text: "Continuing",
                             spoken: String(localized: "Continuing"), tint: Theme.textSecondary)
            }
            let time = LimitResetFormat.parts(resetsAt: pause.resetsAt).time
            return .init(symbol: "pause.circle.fill", text: "Paused · \(time)",
                         spoken: String(localized: "Paused until \(time)"), tint: Theme.textSecondary)
        case .connecting:
            return .init(symbol: "antenna.radiowaves.left.and.right", text: "Connecting",
                         spoken: String(localized: "Connecting"), tint: Theme.textSecondary)
        case .connectFailed:
            return .init(symbol: "wifi.exclamationmark", text: "Couldn't connect",
                         spoken: String(localized: "Couldn't connect"), tint: Theme.danger)
        case .idle:
            return nil
        }
    }

    /// VoiceOver reads the row as one element: title, status, agent, folder,
    /// time.
    private var accessibilityText: String {
        var parts = [conversation.trimmedTitle ?? String(localized: "Untitled session")]
        parts.append(statusTag?.spoken ?? String(localized: "Idle"))
        parts.append(conversation.agentType.displayName)
        if let folderName { parts.append(String(localized: "folder \(folderName)")) }
        parts.append(RelativeTime.spoken(from: conversation.updatedAt))
        if conversation.isPinned { parts.append(String(localized: "pinned")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Style

/// How a ``SessionRow`` draws its surface.
enum SessionRowStyle {
    /// Its own rounded card with a hairline: rows in a standalone list.
    case card
    /// No surface of its own (it sits inside an enclosing card); only the
    /// pressed and selected highlights are drawn.
    case inset

    var cornerRadius: CGFloat {
        switch self {
        case .card: return Theme.Radius.md
        case .inset: return Theme.Radius.sm
        }
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Horizontal padding inside the row.
    var contentInset: CGFloat {
        switch self {
        case .card: return 14
        case .inset: return 10
        }
    }

    /// The ring around the avatar's status dot: the colour behind the row, so
    /// the dot reads as cut out of the avatar.
    var dotRing: Color {
        switch self {
        case .card: return Theme.bgElevated
        case .inset: return Theme.bg
        }
    }
}

/// The row's surface: a flat card (or nothing, inset), a press highlight, and
/// the accent outline for the selected session. Flat on purpose: a Liquid Glass
/// plate per row reads as a stack of shadowed plates on the light backdrop and
/// costs a backdrop pass per cell; glass stays on the cards and bars around
/// the rows.
private struct SessionRowSurface: View {
    let style: SessionRowStyle
    let isSelected: Bool
    let isPressed: Bool

    var body: some View {
        let shape = style.shape
        ZStack {
            if style == .card {
                shape.fill(Theme.bgElevated)
            }
            if isSelected {
                shape.fill(Theme.accent.opacity(style == .card ? 0.10 : 0.14))
            }
            if isPressed {
                shape.fill(Theme.pressed)
            }
            if isSelected {
                shape.strokeBorder(Theme.accent.opacity(0.65), lineWidth: 1.5)
            } else if style == .card {
                shape.strokeBorder(Theme.surfaceStroke, lineWidth: 0.75)
            }
        }
    }
}

/// Press feedback for a session row: the surface darkens (or lightens, in
/// dark mode) and the row shrinks a touch, so a tap visibly lands on the row
/// you touched.
private struct SessionRowButtonStyle: ButtonStyle {
    let style: SessionRowStyle
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                SessionRowSurface(style: style, isSelected: isSelected, isPressed: configuration.isPressed)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// The status tag on a row's details line: a tinted capsule with an icon (or
/// the live pulse while working) and one or two words.
struct SessionStatusTag: View {
    struct Model {
        var live = false
        var symbol: String?
        var text: LocalizedStringKey
        /// The same words for VoiceOver.
        var spoken: String
        var tint: Color
    }

    let tag: Model

    var body: some View {
        HStack(spacing: 5) {
            if tag.live {
                LivePulse()
                    .scaleEffect(0.8)
            } else if let symbol = tag.symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
            }
            Text(tag.text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tag.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tag.tint.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Relative time

/// Compact relative-time formatting shared by rows.
///
/// `RelativeDateTimeFormatter` is not `Sendable`, so the shared instance is
/// pinned to the main actor — every caller here renders from a SwiftUI view
/// body, which is already main-actor isolated.
@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .numeric
        return f
    }()

    private static let spokenFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .numeric
        return f
    }()

    /// Phrased relative time ("2h ago", "now", "in 5m") for prose contexts.
    static func string(from date: Date, relativeTo reference: Date = Date()) -> String {
        let interval = reference.timeIntervalSince(date)
        if interval >= 0, interval < 45 { return "now" }
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// Ultra-compact magnitude for dense list rows: "now", "5m", "2h", "6d",
    /// then a short date ("Mar 5") past a week. No "ago"/"in" suffix.
    static func compact(from date: Date, relativeTo reference: Date = Date()) -> String {
        let interval = reference.timeIntervalSince(date)
        if interval < 60 { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What ``compact(from:relativeTo:)`` says, in words for VoiceOver:
    /// "just now", "5 minutes ago", "2 days ago", then the date.
    static func spoken(from date: Date, relativeTo reference: Date = Date()) -> String {
        let interval = reference.timeIntervalSince(date)
        if interval < 60 { return String(localized: "just now") }
        if interval >= 7 * 24 * 3600 { return date.formatted(.dateTime.month(.wide).day()) }
        return spokenFormatter.localizedString(for: date, relativeTo: reference)
    }
}
