import SwiftUI
import UIKit

/// The Activity tab: a live monitor of what your agents are doing right now and
/// what just finished — running sessions, then everything touched in the last
/// 24 hours. By default (Settings › Appearance › "Newest at the bottom") the
/// most recent session sits at the bottom of the screen. Unlike the Chats list, rows are **directly tappable**: each
/// opens its session in a single tap, with no App Store-style card/zoom drill-in
/// in between (Activity favors immediacy — it's backed by a periodic poll that
/// keeps the list live). The list itself is ``ActivityFeed``, which takes plain
/// data so it can also be rendered with sample sessions.
///
/// With two or more servers the title is a menu (``ActivitySwitcher``): All
/// Servers, one feed of every server (``AllServersSource``), or one server,
/// which selects it for the whole app as the Chats title does.
struct ActivityView: View {
    let activity: ActivityModel
    let client: CodegClient?
    /// The session that is open (iPad) or was opened last (iPhone).
    var markedConversationID: Int? = nil
    /// Bumped to bring the feed to its newest end (a tap on the Activity
    /// tab, coming back to it).
    var newestRequest = 0
    /// The feed left its newest end, or came back to it.
    var onAwayFromNewest: (Bool) -> Void = { _ in }
    /// The title menu. Nil: the plain "Activity" title (one server).
    var switcher: ActivitySwitcher? = nil
    /// All Servers is chosen: every server's sessions in one feed. Nil: the
    /// selected server's (`activity`).
    var allServers: AllServersSource? = nil
    let onOpen: (Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppearanceStore.self) private var appearance

    var body: some View {
        ZStack {
            CodegBackground()
            if let allServers {
                allServersContent(allServers)
            } else {
                content
            }
        }
        .connectionCapsule()
        .modifier(ActivityTitle(compact: horizontalSizeClass == .compact, switcher: switcher))
        // No explicit refresh button — pull-to-refresh and the background
        // activity pulse keep this current.
        .task {
            if !activity.hasLoaded {
                await activity.refresh(client: client)
            }
        }
    }

    // MARK: - Content states

    /// With the title menu, the empty state offers Manage Servers too.
    private var manageTitle: LocalizedStringKey? {
        switcher == nil ? nil : "Manage Servers"
    }

    private var content: some View {
        Group {
            if client == nil {
                EmptyStateView(
                    icon: "server.rack",
                    title: "No Server Selected",
                    message: "Pick a server from the menu at the top to see its activity.",
                    actionTitle: manageTitle,
                    action: switcher?.onManage
                )
            } else if !activity.hasLoaded, activity.isRefreshing {
                LoadingView(label: "Checking activity…")
            } else if let error = activity.error, !activity.hasLoaded {
                InlineErrorView(message: error) {
                    Task { await activity.refresh(client: client) }
                }
            } else {
                let earlier = activity.earlier
                ActivityFeed(
                    running: activity.running,
                    recent: activity.recent,
                    earlier: Array(earlier.prefix(activity.earlierShown)),
                    earlierTotal: earlier.count,
                    folderNames: activity.folderNames,
                    markedID: markedConversationID,
                    lastRefreshed: activity.lastRefreshed,
                    error: activity.hasLoaded ? activity.error : nil,
                    onOpen: onOpen,
                    onRefresh: { await activity.refresh(client: client) },
                    onDismissError: { activity.dismissError() },
                    onShowEarlier: { activity.showMoreEarlier() },
                    newestAtBottom: appearance.newestAtBottom,
                    newestRequest: newestRequest,
                    onAwayFromNewest: onAwayFromNewest
                )
            }
        }
        // Cross-fade the first load into the feed instead of a hard swap.
        .transition(.opacity)
        .animation(Theme.Motion.content, value: activity.hasLoaded)
    }

    /// All Servers: the feed shows once any server has given its lists; a
    /// server that can't be reached gets a note instead of blanking it.
    private func allServersContent(_ source: AllServersSource) -> some View {
        let feed = source.model.feed(servers: source.servers, selectedID: source.selectedServerID,
                                     selected: activity)
        return Group {
            if !feed.hasLoaded {
                if let error = feed.firstError, !feed.isRefreshing {
                    InlineErrorView(message: error) {
                        Task { await source.onRefresh() }
                    }
                } else {
                    LoadingView(label: "Checking activity…")
                }
            } else {
                ActivityFeed(
                    running: feed.running,
                    recent: feed.recent,
                    earlier: Array(feed.earlier.prefix(source.model.earlierShown)),
                    earlierTotal: feed.earlier.count,
                    // The session opened last is on the selected server.
                    markedKey: markedConversationID.map {
                        ActivityRowKey(server: source.selectedServerID, conversationID: $0)
                    },
                    lastRefreshed: feed.lastRefreshed,
                    // Each server's failure is a note of its own.
                    error: nil,
                    notices: feed.notices,
                    onOpenRow: { source.onOpen($0.id) },
                    onRefresh: source.onRefresh,
                    onDismissError: {},
                    onDismissNotice: { source.model.dismiss($0) },
                    onShowEarlier: { source.model.showMoreEarlier(total: feed.earlier.count) },
                    newestAtBottom: appearance.newestAtBottom,
                    newestRequest: newestRequest,
                    onAwayFromNewest: onAwayFromNewest
                )
            }
        }
        .transition(.opacity)
        .animation(Theme.Motion.content, value: feed.hasLoaded)
    }
}

/// Activity's title menu: All Servers (with two or more servers), each
/// saved server with a checkmark on the current choice, then Manage
/// Servers….
struct ActivitySwitcher {
    let servers: [ServerProfile]
    /// The checked item; setting it chooses All Servers or selects a server.
    let choice: Binding<ActivityChoice?>
    let onManage: () -> Void

    /// What the title says after "Activity": All Servers or the server.
    var choiceName: String? {
        switch choice.wrappedValue {
        case .allServers: return String(localized: "All Servers")
        case .server(let id): return servers.first { $0.id == id }.map { Self.short($0.name) }
        case nil: return nil
        }
    }

    /// A long server name, cut short for the title bar.
    static func short(_ name: String, limit: Int = 24) -> String {
        name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
    }
}

/// The All Servers feed's data and actions.
struct AllServersSource {
    let model: AllServersActivity
    let servers: [ServerProfile]
    let selectedServerID: UUID?
    /// A row was tapped: its server is selected first when it isn't.
    let onOpen: (ActivityRowKey) -> Void
    /// Every server at once (pull to refresh, Try Again).
    let onRefresh: () async -> Void
}

/// "Activity" as the screen title, or, with the switcher, the leading title
/// menu (as on the Chats root): the menu draws the title, so the system one
/// is left empty.
struct ActivityTitle: ViewModifier {
    let compact: Bool
    let switcher: ActivitySwitcher?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let switcher {
            let noTitle = ""
            content
                .navigationTitle(noTitle)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ActivityTitleMenu(switcher: switcher)
                    }
                }
        } else {
            content.screenTitle("Activity", compact: compact)
        }
    }
}

struct ActivityTitleMenu: View {
    let switcher: ActivitySwitcher

    var body: some View {
        Menu {
            Picker("Server", selection: switcher.choice) {
                ForEach(ActivityChoice.options(serverIDs: switcher.servers.map(\.id)), id: \.self) { choice in
                    item(choice).tag(Optional(choice))
                }
            }
            .pickerStyle(.inline)
            Divider()
            // Plain text (no icon), as on the Chats title: a menu draws a
            // button's icon on the trailing edge, opposite the checkmarks.
            Button("Manage Servers…", action: switcher.onManage)
        } label: {
            HStack(spacing: 6) {
                Text("Activity")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                if let name = switcher.choiceName {
                    Text(verbatim: name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize()
        }
        .accessibilityLabel(Text("Activity: \(switcher.choiceName ?? "")"))
        .accessibilityHint("Switch server")
    }

    @ViewBuilder
    private func item(_ choice: ActivityChoice) -> some View {
        switch choice {
        case .allServers:
            Text("All Servers")
        case .server(let id):
            Text(verbatim: switcher.servers.first { $0.id == id }?.name ?? "")
        }
    }
}

/// "Couldn't reach MacBook" over the All Servers feed: one server timed out
/// (a laptop asleep on battery, say) while the others' rows show. Its own
/// rows stay as it last gave them, with their time. Dismissed, it stays
/// away until that server answers and fails again.
struct ServerUnreachableNote: View {
    let notice: ActivityServerNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn’t reach \(notice.serverName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let date = notice.lastRefreshed {
                    Text("Showing its sessions from \(LastUpdatedLine.text(for: date))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
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
    let running: [ActivityRow]
    /// Sessions touched in the last 24 hours, most recently updated first.
    let recent: [ActivityRow]
    /// Older sessions listed so far ("Earlier"), most recent first.
    let earlier: [ActivityRow]
    /// How many older sessions there are in all.
    let earlierTotal: Int
    /// The session that is open (iPad) or was opened last (iPhone); its row is
    /// marked.
    let markedKey: ActivityRowKey?
    let lastRefreshed: Date?
    /// A failed refresh over a list that still has rows.
    let error: String?
    /// All Servers: the servers that couldn't be reached.
    let notices: [ActivityServerNotice]
    let onOpenRow: (ActivityRow) -> Void
    let onRefresh: () async -> Void
    let onDismissError: () -> Void
    let onDismissNotice: (ActivityServerNotice) -> Void
    /// Lists the next page of older sessions.
    let onShowEarlier: () -> Void
    /// Oldest at the top, the most recent session at the bottom.
    let newestAtBottom: Bool
    /// Bumped to bring the feed to its newest end.
    let newestRequest: Int
    /// The feed left its newest end, or came back to it.
    let onAwayFromNewest: (Bool) -> Void

    /// Rows of any number of servers, keyed by server and conversation
    /// (All Servers).
    init(
        running: [ActivityRow],
        recent: [ActivityRow],
        earlier: [ActivityRow] = [],
        earlierTotal: Int = 0,
        markedKey: ActivityRowKey? = nil,
        lastRefreshed: Date?,
        error: String?,
        notices: [ActivityServerNotice] = [],
        onOpenRow: @escaping (ActivityRow) -> Void,
        onRefresh: @escaping () async -> Void,
        onDismissError: @escaping () -> Void,
        onDismissNotice: @escaping (ActivityServerNotice) -> Void = { _ in },
        onShowEarlier: @escaping () -> Void = {},
        newestAtBottom: Bool = false,
        newestRequest: Int = 0,
        onAwayFromNewest: @escaping (Bool) -> Void = { _ in }
    ) {
        self.running = running
        self.recent = recent
        self.earlier = earlier
        self.earlierTotal = earlierTotal
        self.markedKey = markedKey
        self.lastRefreshed = lastRefreshed
        self.error = error
        self.notices = notices
        self.onOpenRow = onOpenRow
        self.onRefresh = onRefresh
        self.onDismissError = onDismissError
        self.onDismissNotice = onDismissNotice
        self.onShowEarlier = onShowEarlier
        self.newestAtBottom = newestAtBottom
        self.newestRequest = newestRequest
        self.onAwayFromNewest = onAwayFromNewest
    }

    /// One server's sessions.
    init(
        running: [ConversationSummary],
        recent: [ConversationSummary],
        earlier: [ConversationSummary] = [],
        earlierTotal: Int = 0,
        folderNames: [Int: String],
        markedID: Int? = nil,
        lastRefreshed: Date?,
        error: String?,
        onOpen: @escaping (Int) -> Void,
        onRefresh: @escaping () async -> Void,
        onDismissError: @escaping () -> Void,
        onShowEarlier: @escaping () -> Void = {},
        newestAtBottom: Bool = false,
        newestRequest: Int = 0,
        onAwayFromNewest: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            running: ActivityRow.rows(running, folderNames: folderNames),
            recent: ActivityRow.rows(recent, folderNames: folderNames),
            earlier: ActivityRow.rows(earlier, folderNames: folderNames),
            earlierTotal: earlierTotal,
            markedKey: markedID.map { ActivityRowKey(server: nil, conversationID: $0) },
            lastRefreshed: lastRefreshed,
            error: error,
            onOpenRow: { onOpen($0.conversation.id) },
            onRefresh: onRefresh,
            onDismissError: onDismissError,
            onShowEarlier: onShowEarlier,
            newestAtBottom: newestAtBottom,
            newestRequest: newestRequest,
            onAwayFromNewest: onAwayFromNewest
        )
    }

    /// Bumped only when a user pull-to-refresh completes, so the soft landing
    /// haptic fires on the pull — not on the initial programmatic load.
    @State private var pullTick = 0
    @State private var pin = BottomPin()
    @State private var isUserScrolling = false
    /// Older sessions are going in above the rows being read, which stay put.
    @State private var holdingForEarlier = false
    /// Newest first: the feed is at its top.
    @State private var atTop = true

    /// The feed shows its newest end.
    private var showsNewest: Bool {
        ActivityFeedLayout.showsNewest(newestAtBottom: newestAtBottom, pinned: pin.isPinned, atTop: atTop)
    }

    private static let topID = "activity-top"
    private static let bottomID = "activity-bottom"

    private var sections: [ActivityFeedLayout.Section<ActivityRow>] {
        ActivityFeedLayout.sections(running: running, recent: recent, earlier: earlier,
                                    newestAtBottom: newestAtBottom)
    }

    private var earlierControlState: ActivityFeedLayout.EarlierControl {
        ActivityFeedLayout.earlierControl(total: earlierTotal, shown: earlier.count)
    }

    /// Changes whenever a row is added, removed or moved.
    private var rowIDs: [ActivityRowKey] { sections.flatMap { $0.rows.map(\.id) } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear.frame(height: 1).id(Self.topID)
                    if newestAtBottom { updatedLine } else { errorBanner }
                    // Older sessions continue at the old end of the feed.
                    if newestAtBottom { earlierControl }

                    if sections.isEmpty {
                        EmptyStateView(
                            icon: "moon.zzz",
                            title: "All Agents Idle",
                            message: "Nothing is running and nothing finished in the last 24 hours."
                        )
                        .frame(maxWidth: .infinity, minHeight: earlierTotal > 0 ? 240 : 360)
                    } else {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.rows) { row($0) }
                        }
                    }

                    if !newestAtBottom { earlierControl }
                    if newestAtBottom { errorBanner } else { updatedLine }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.bottom, newestAtBottom ? 8 : Theme.Layout.screenBottomInset)
                // A tap on the status bar (or iOS's own on the tab) scrolls to
                // the top: only where the top is the newest end. And while
                // older sessions go in above, the rows on screen stay put.
                .background(FeedScrollHook(scrollsToTop: !newestAtBottom, holdsRows: holdingForEarlier))
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
            // the top in place instead (older sessions going in above are
            // held by ``FeedScrollHook``).
            .defaultScrollAnchor(newestAtBottom ? UnitPoint.bottom : nil, for: .initialOffset)
            .defaultScrollAnchor(newestAtBottom ? UnitPoint.bottom : nil, for: .alignment)
            .defaultScrollAnchor(newestAtBottom && pin.isPinned ? UnitPoint.bottom : UnitPoint.top, for: .sizeChanges)
            .onScrollPhaseChange { _, phase, context in
                let wasUserScrolling = isUserScrolling
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if isUserScrolling { holdingForEarlier = false }
                guard newestAtBottom, isUserScrolling || wasUserScrolling else { return }
                pin.update(atBottom: FeedScrollMetrics(context.geometry).atBottom, userScrolling: true)
            }
            // Late row measurement and inset changes: follow while pinned; a
            // layout change can re-pin but never unpin.
            .onScrollGeometryChange(for: FeedScrollMetrics.self) { FeedScrollMetrics($0) } action: { old, new in
                atTop = new.atTop
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
            // A tap on the Activity tab, or coming back to it.
            .onChange(of: newestRequest) { _, _ in
                holdingForEarlier = false
                if newestAtBottom { pin.reset() }
                withAnimation(Theme.Motion.chrome) {
                    proxy.scrollTo(newestAtBottom ? Self.bottomID : Self.topID,
                                   anchor: newestAtBottom ? .bottom : .top)
                }
            }
            .onChange(of: showsNewest, initial: true) { _, shows in onAwayFromNewest(!shows) }
            // The older rows are in and measured: back to the usual anchor.
            .task(id: holdingForEarlier) {
                guard holdingForEarlier else { return }
                try? await Task.sleep(for: .seconds(1))
                holdingForEarlier = false
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
        ForEach(notices) { notice in
            ServerUnreachableNote(notice: notice, dismiss: { onDismissNotice(notice) })
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
    private func row(_ row: ActivityRow) -> some View {
        SessionRow(
            conversation: row.conversation,
            isSelected: row.id == markedKey,
            folderName: row.folderName,
            onTap: { onOpenRow(row) },
            serverName: row.serverName,
            attention: row.attention,
            offersSessionActions: row.offersSessionActions
        )
    }

    /// "Earlier": lists sessions older than 24 hours on demand, a page at a
    /// time, so they don't simply vanish from Activity. A flat card in the
    /// rows' style with the section header's badge; once some are shown, a
    /// plain "Show more" line in their place.
    @ViewBuilder
    private var earlierControl: some View {
        switch earlierControlState {
        case .none, .allShown:
            EmptyView()
        case .show(let total):
            Button(action: showEarlier) {
                HStack(spacing: 11) {
                    SectionBadgeIcon(systemImage: "calendar", tint: Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Earlier")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Sessions from before the last 24 hours")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    CountBadge(count: total)
                    Image(systemName: newestAtBottom ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .hairlineBorder(Theme.Radius.md)
            }
            .buttonStyle(PressableRowStyle())
            .padding(.top, 4)
            .accessibilityLabel("Earlier sessions, \(total)")
            .accessibilityHint("Lists sessions from before the last 24 hours")
        case .more(let remaining):
            Button(action: showEarlier) {
                Label("Show \(min(remaining, ActivityModel.earlierPage)) more", systemImage: newestAtBottom ? "arrow.up" : "arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
        }
    }

    /// With the newest at the bottom, older rows go in above the rows being
    /// read, which keep their place on screen: the feed lets go of the
    /// bottom (he is reading older sessions now), holds what shows
    /// (``FeedScrollHook``), then lists them, without the rows' animation,
    /// which would slide what is held.
    private func showEarlier() {
        guard newestAtBottom else {
            onShowEarlier()
            return
        }
        pin.update(atBottom: false, userScrolling: true)
        holdingForEarlier = true
        Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onShowEarlier() }
        }
    }

    /// A group header above its cards: a tinted circular badge + the section
    /// name + a count pill.
    private func sectionHeader(_ section: ActivityFeedLayout.Section<ActivityRow>) -> some View {
        let (title, icon, tint): (LocalizedStringKey, String, Color) = switch section.kind {
        case .running: ("Running", "waveform", Theme.accent)
        case .recent: ("Last 24 Hours", "clock.arrow.circlepath", Theme.textSecondary)
        case .earlier: ("Earlier", "calendar", Theme.textSecondary)
        }
        let count = section.kind == .earlier ? earlierTotal : section.rows.count
        return HStack(spacing: 11) {
            SectionBadgeIcon(systemImage: icon, tint: tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            CountBadge(count: count)
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
    var atTop: Bool
    var contentHeight: CGFloat
    var containerHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        atTop = geometry.contentOffset.y + geometry.contentInsets.top <= BottomPin.tolerance
        atBottom = BottomPin.isAtBottom(
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            offsetY: geometry.contentOffset.y,
            bottomInset: geometry.contentInsets.bottom
        )
    }
}

/// What the feed asks of its scroll view: whether the system's scroll to the
/// top (a tap on the status bar, iOS's own on the tab that shows) works, and,
/// while `holdsRows`, that the rows on screen stay exactly where they are as
/// content goes in above them (older sessions): everything below the top of
/// the screen is as it was, so the end of the content is kept as far from it,
/// in the same layout pass, whether or not SwiftUI moved the offset itself.
struct FeedScrollHook: UIViewRepresentable {
    let scrollsToTop: Bool
    let holdsRows: Bool

    func makeUIView(context: Context) -> Probe {
        Probe()
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.update(scrollsToTop: scrollsToTop, holdsRows: holdsRows)
    }

    final class Probe: UIView {
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var scrollsToTop = true
        private var holdsRows = false
        /// While the rows are held: from the top of the screen to the end of
        /// the content.
        private var heldDistance: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            update(scrollsToTop: scrollsToTop, holdsRows: holdsRows)
        }

        func update(scrollsToTop: Bool, holdsRows: Bool) {
            self.scrollsToTop = scrollsToTop
            self.holdsRows = holdsRows
            attach()
            guard let scrollView else { return }
            if scrollView.scrollsToTop != scrollsToTop { scrollView.scrollsToTop = scrollsToTop }
            if !holdsRows {
                heldDistance = nil
            } else if heldDistance == nil {
                heldDistance = scrollView.contentSize.height - scrollView.contentOffset.y
            }
        }

        /// The scroll view this one sits in.
        private func attach() {
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let found = view as? UIScrollView, found !== scrollView else { return }
            scrollView = found
            heldDistance = nil
            observations = [
                found.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated { self?.hold(scrollView) }
                },
                found.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated { self?.hold(scrollView) }
                },
            ]
        }

        private func hold(_ scrollView: UIScrollView) {
            guard let heldDistance, !scrollView.isTracking, !scrollView.isDecelerating else { return }
            let offset = scrollView.contentSize.height - heldDistance
            if abs(scrollView.contentOffset.y - offset) > 0.5 { scrollView.contentOffset.y = offset }
        }
    }
}
