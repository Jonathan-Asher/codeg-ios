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

// MARK: - The newest end

extension ActivityFeedLayout {
    /// Whether the feed shows its newest end: the bottom (pinned there) when
    /// the newest is at the bottom, else the top.
    static func showsNewest(newestAtBottom: Bool, pinned: Bool, atTop: Bool) -> Bool {
        newestAtBottom ? pinned : atTop
    }
}

/// The Activity tab and the feed's newest end (the bottom, or the top with
/// newest first). A tap on the tab while it shows brings the feed there,
/// unless a session is open on the tab: then the tab bar first takes it back
/// to the feed. Coming to the tab from another one lands there too, unless
/// the feed was left scrolled away from it less than a minute ago: then it
/// is where it was left.
struct ActivityTabReturn: Equatable, Sendable {
    /// How long a feed left scrolled away from its newest end stays there.
    static let keepsPlaceFor: TimeInterval = 60

    private(set) var leftAt: Date?
    private(set) var leftAwayFromNewest = false

    /// The tab was left, the feed showing its newest end or not.
    mutating func left(awayFromNewest: Bool, at date: Date) {
        leftAt = date
        leftAwayFromNewest = awayFromNewest
    }

    /// Coming back at `date`: to the newest end?
    func landsOnNewest(at date: Date) -> Bool {
        guard leftAwayFromNewest, let leftAt else { return true }
        return date.timeIntervalSince(leftAt) >= Self.keepsPlaceFor
    }

    /// A tap on the tab that shows: to the newest end, when the feed itself
    /// shows (`stackDepth` sessions are open on the tab).
    static func tapScrollsToNewest(stackDepth: Int) -> Bool {
        stackDepth == 0
    }
}
