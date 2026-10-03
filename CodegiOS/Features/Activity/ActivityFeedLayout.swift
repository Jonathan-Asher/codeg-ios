import CoreGraphics
import Foundation

/// The Activity tab's sections in display order.
///
/// Newest first (the default upstream order): "Running" on top, then "Last 24
/// Hours", each most recent first. Newest at the bottom (the Settings ›
/// Appearance option): the whole feed is turned over, so the most recent
/// session sits at the bottom of the screen, within reach of the thumb, and
/// older ones go up. "Last 24 Hours" then comes first and "Running" last, each
/// oldest first. A header always stays above its own rows.
enum ActivityFeedLayout {
    enum Kind: Hashable, Sendable {
        case running
        case recent
    }

    struct Section: Identifiable, Equatable {
        let kind: Kind
        let rows: [ConversationSummary]
        var id: Kind { kind }
    }

    /// `running` and `recent` arrive most recent first, as `ActivityModel`
    /// derives them. Empty sections are dropped.
    static func sections(
        running: [ConversationSummary],
        recent: [ConversationSummary],
        newestAtBottom: Bool
    ) -> [Section] {
        var sections: [Section] = []
        if !running.isEmpty { sections.append(Section(kind: .running, rows: running)) }
        if !recent.isEmpty { sections.append(Section(kind: .recent, rows: recent)) }
        guard newestAtBottom else { return sections }
        return sections.reversed().map { Section(kind: $0.kind, rows: $0.rows.reversed()) }
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
