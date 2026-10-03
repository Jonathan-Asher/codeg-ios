import SwiftUI

/// The Activity tab: a live monitor of what your agents are doing right now and
/// what just finished — running sessions, then everything touched in the last
/// 24 hours. By default (Settings › Appearance › "Newest at the bottom") the
/// most recent session sits at the bottom of the screen. Unlike the Chats list, rows are **directly tappable**: each
/// opens its session in a single tap, with no App Store-style card/zoom drill-in
/// in between (Activity favors immediacy — it's backed by a periodic poll that
/// keeps the list live). The list itself is ``ActivityFeed``, which takes plain
/// data so it can also be rendered with sample sessions.
struct ActivityView: View {
    let activity: ActivityModel
    let client: CodegClient?
    /// The session that is open (iPad) or was opened last (iPhone).
    var markedConversationID: Int? = nil
    let onOpen: (Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppearanceStore.self) private var appearance

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Activity", compact: horizontalSizeClass == .compact)
        // No explicit refresh button — pull-to-refresh and the background
        // activity pulse keep this current.
        .task {
            if !activity.hasLoaded {
                await activity.refresh(client: client)
            }
        }
    }

    // MARK: - Content states

    private var content: some View {
        Group {
            if client == nil {
                EmptyStateView(
                    icon: "server.rack",
                    title: "No Server Selected",
                    message: "Pick a server in the Chats tab to see its activity."
                )
            } else if !activity.hasLoaded, activity.isRefreshing {
                LoadingView(label: "Checking activity…")
            } else if let error = activity.error, !activity.hasLoaded {
                InlineErrorView(message: error) {
                    Task { await activity.refresh(client: client) }
                }
            } else {
                ActivityFeed(
                    running: activity.running,
                    recent: activity.recent,
                    folderNames: activity.folderNames,
                    markedID: markedConversationID,
                    lastRefreshed: activity.lastRefreshed,
                    error: activity.hasLoaded ? activity.error : nil,
                    onOpen: onOpen,
                    onRefresh: { await activity.refresh(client: client) },
                    onDismissError: { activity.dismissError() },
                    newestAtBottom: appearance.newestAtBottom
                )
            }
        }
        // Cross-fade the first load into the feed instead of a hard swap.
        .transition(.opacity)
        .animation(Theme.Motion.content, value: activity.hasLoaded)
    }
}

/// The Activity list: directly-tappable session cards under tinted "Running" /
/// "Last 24 Hours" headers, plus the refresh-error banner, the idle empty state
/// and the "Updated …" line. Takes plain values (read live by ``ActivityView``
/// each render, so a background pulse keeps them fresh).
///
/// With `newestAtBottom` the feed is turned over (``ActivityFeedLayout``), it
/// opens scrolled to the bottom with no jump, short content sits at the bottom,
/// and ``BottomPin`` keeps it on the newest row while it is there. The error
/// banner moves to the bottom with the newest rows and "Updated …" to the top.
struct ActivityFeed: View {
    /// Running sessions, most recently updated first.
    let running: [ConversationSummary]
    /// Sessions touched in the last 24 hours, most recently updated first.
    let recent: [ConversationSummary]
    let folderNames: [Int: String]
    /// The session that is open (iPad) or was opened last (iPhone); its row is
    /// marked.
    var markedID: Int? = nil
    let lastRefreshed: Date?
    /// A failed refresh over a list that still has rows.
    let error: String?
    let onOpen: (Int) -> Void
    let onRefresh: () async -> Void
    let onDismissError: () -> Void
    /// Oldest at the top, the most recent session at the bottom.
    var newestAtBottom: Bool = false

    /// Bumped only when a user pull-to-refresh completes, so the soft landing
    /// haptic fires on the pull — not on the initial programmatic load.
    @State private var pullTick = 0
    @State private var pin = BottomPin()
    @State private var isUserScrolling = false

    private static let topID = "activity-top"
    private static let bottomID = "activity-bottom"

    private var sections: [ActivityFeedLayout.Section] {
        ActivityFeedLayout.sections(running: running, recent: recent, newestAtBottom: newestAtBottom)
    }

    /// Changes whenever a row is added, removed or moved.
    private var rowIDs: [Int] { sections.flatMap { $0.rows.map(\.id) } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear.frame(height: 1).id(Self.topID)
                    if newestAtBottom { updatedLine } else { errorBanner }

                    if sections.isEmpty {
                        EmptyStateView(
                            icon: "moon.zzz",
                            title: "All Agents Idle",
                            message: "Nothing is running and nothing finished in the last 24 hours."
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.rows) { row($0) }
                        }
                    }

                    if newestAtBottom { errorBanner } else { updatedLine }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.bottom, newestAtBottom ? 8 : Theme.Layout.screenBottomInset)
                // Ease rows between Running ↔ Last-24h as the background poll
                // reorders them, instead of teleporting.
                .animation(Theme.Motion.chrome, value: rowIDs)
            }
            .scrollContentBackground(.hidden)
            .refreshable {
                await onRefresh()
                pullTick &+= 1
            }
            // Newest at the bottom: open there (no visible jump), sit short
            // content at the bottom, and keep the bottom in place as rows
            // change, but only while pinned. Scrolled up, a size change keeps
            // the top in place instead, so the rows he is reading stay put.
            .defaultScrollAnchor(newestAtBottom ? UnitPoint.bottom : nil, for: .initialOffset)
            .defaultScrollAnchor(newestAtBottom ? UnitPoint.bottom : nil, for: .alignment)
            .defaultScrollAnchor(newestAtBottom && pin.isPinned ? UnitPoint.bottom : UnitPoint.top, for: .sizeChanges)
            .onScrollPhaseChange { _, phase, context in
                let wasUserScrolling = isUserScrolling
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                guard newestAtBottom, isUserScrolling || wasUserScrolling else { return }
                pin.update(atBottom: FeedScrollMetrics(context.geometry).atBottom, userScrolling: true)
            }
            // Late row measurement and inset changes: follow while pinned; a
            // layout change can re-pin but never unpin.
            .onScrollGeometryChange(for: FeedScrollMetrics.self) { FeedScrollMetrics($0) } action: { old, new in
                guard newestAtBottom else { return }
                if isUserScrolling {
                    pin.update(atBottom: new.atBottom, userScrolling: true)
                } else if pin.isPinned {
                    if old.contentHeight != new.contentHeight || old.containerHeight != new.containerHeight {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                } else {
                    pin.update(atBottom: new.atBottom, userScrolling: false)
                }
            }
            // A session updated or arrived: stay on the newest row while
            // pinned; leave a scrolled-up list alone.
            .onChange(of: rowIDs) { _, _ in
                guard newestAtBottom, pin.isPinned, !isUserScrolling else { return }
                withAnimation(Theme.Motion.chrome) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            // The option was switched while the list is alive (another tab).
            .onChange(of: newestAtBottom) { _, bottom in
                pin.reset()
                proxy.scrollTo(bottom ? Self.bottomID : Self.topID, anchor: bottom ? .bottom : .top)
            }
        }
        // A soft tick when a user pull-to-refresh lands (not the initial load).
        .sensoryFeedback(.impact(flexibility: .soft), trigger: pullTick)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error {
            RefreshErrorBanner(
                message: error,
                retry: { Task { await onRefresh() } },
                dismiss: onDismissError
            )
        }
    }

    @ViewBuilder
    private var updatedLine: some View {
        if let lastRefreshed {
            Text("Updated \(RelativeTime.string(from: lastRefreshed))")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }

    /// One directly-tappable session card (opens in a single tap), as in
    /// ``SearchView``'s result list and ``SessionSectionFullScreen``.
    private func row(_ conversation: ConversationSummary) -> some View {
        SessionRow(
            conversation: conversation,
            isSelected: conversation.id == markedID,
            folderName: folderNames[conversation.folderId],
            onTap: { onOpen(conversation.id) }
        )
    }

    /// A group header above its cards: a tinted circular badge + the section
    /// name + a count pill.
    private func sectionHeader(_ section: ActivityFeedLayout.Section) -> some View {
        let (title, icon, tint): (LocalizedStringKey, String, Color) = switch section.kind {
        case .running: ("Running", "waveform", Theme.accent)
        case .recent: ("Last 24 Hours", "clock.arrow.circlepath", Theme.textSecondary)
        }
        return HStack(spacing: 11) {
            SectionBadgeIcon(systemImage: icon, tint: tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            CountBadge(count: section.rows.count)
        }
        .padding(.horizontal, 2)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What the feed reads from its scroll geometry. Layout changes must not be
/// mistaken for the user scrolling away from the bottom.
private struct FeedScrollMetrics: Equatable {
    var atBottom: Bool
    var contentHeight: CGFloat
    var containerHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        atBottom = BottomPin.isAtBottom(
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            offsetY: geometry.contentOffset.y,
            bottomInset: geometry.contentInsets.bottom
        )
    }
}
