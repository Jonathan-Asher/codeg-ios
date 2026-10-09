import CoreGraphics
import Foundation

/// The Activity tab's sections in display order.
///
/// Newest first (the default upstream order): "Running" on top, then "Last 24
/// Hours", then "Earlier" (older sessions, listed on demand), each most
/// recent first. Newest at the bottom (the Settings › Appearance option): the
/// whole feed is turned over, so the most recent session sits at the bottom
/// of the screen, within reach of the thumb, and older ones go up. "Earlier"
/// then comes first and "Running" last, each oldest first. A header always
/// stays above its own rows.
enum ActivityFeedLayout {
    enum Kind: Hashable, Sendable {
        case running
        case recent
        case earlier
    }

    struct Section: Identifiable, Equatable {
        let kind: Kind
        let rows: [ConversationSummary]
        var id: Kind { kind }
    }

    /// `running`, `recent` and `earlier` arrive most recent first, as
    /// `ActivityModel` derives them; `earlier` holds only the rows asked for.
    /// Empty sections are dropped.
    static func sections(
        running: [ConversationSummary],
        recent: [ConversationSummary],
        earlier: [ConversationSummary] = [],
        newestAtBottom: Bool
    ) -> [Section] {
        var sections: [Section] = []
        if !running.isEmpty { sections.append(Section(kind: .running, rows: running)) }
        if !recent.isEmpty { sections.append(Section(kind: .recent, rows: recent)) }
        if !earlier.isEmpty { sections.append(Section(kind: .earlier, rows: earlier)) }
        guard newestAtBottom else { return sections }
        return sections.reversed().map { Section(kind: $0.kind, rows: $0.rows.reversed()) }
    }

    /// The "Earlier" control: what it offers given how many older sessions
    /// exist and how many are shown. It sits at the old end of the feed
    /// (the bottom, or the top when the newest is at the bottom), where
    /// older sessions continue.
    enum EarlierControl: Equatable {
        /// Nothing older than 24 hours.
        case none
        /// None shown yet: "Earlier", with how many there are.
        case show(total: Int)
        /// Some shown: "Show more", with how many are left.
        case more(remaining: Int)
        /// All shown.
        case allShown
    }

    static func earlierControl(total: Int, shown: Int) -> EarlierControl {
        if total == 0 { return .none }
        if shown == 0 { return .show(total: total) }
        if shown < total { return .more(remaining: total - shown) }
        return .allShown
    }
}

/// Keeps a newest-at-the-bottom list on its newest row. The list opens pinned
/// to the bottom and follows new and updated rows while it stays there. Only
/// the user's own scroll can unpin it: a refresh that adds rows, a layout pass
/// or a programmatic scroll never does, so a list he has scrolled up stays
/// where he left it. Scrolling back down to the bottom pins it again.
struct BottomPin: Equatable, Sendable {
    /// Within this distance (pt) of the end of the content, the list counts as
    /// at the bottom.
    static let tolerance: CGFloat = 40

    private(set) var isPinned = true

    /// Whether the viewport shows the end of the content. `offsetY` is the
    /// scroll view's content offset, `bottomInset` its bottom content inset
    /// (the tab bar and home indicator). Content shorter than the viewport is
    /// always at the bottom.
    static func isAtBottom(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        offsetY: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        contentHeight - (offsetY + containerHeight - bottomInset) <= tolerance
    }

    /// A new scroll position. While the user scrolls, it decides: at the
    /// bottom pins, anywhere else unpins. Otherwise (layout, new rows, a
    /// programmatic scroll) it can only re-pin.
    mutating func update(atBottom: Bool, userScrolling: Bool) {
        if userScrolling {
            isPinned = atBottom
        } else if atBottom {
            isPinned = true
        }
    }

    /// Back to the bottom, e.g. when the option is turned on.
    mutating func reset() {
        isPinned = true
    }
}
