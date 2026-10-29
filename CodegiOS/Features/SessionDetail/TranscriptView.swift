import SwiftUI

// MARK: - Scroll action (environment)

/// A scroll capability the transcript publishes into the environment so any
/// descendant (an assistant reply's "scroll to question" button) can move the
/// viewport without threading the `ScrollViewProxy` down by hand.
struct TranscriptScrollAction {
    let perform: (String, UnitPoint) -> Void
    func callAsFunction(_ id: String, anchor: UnitPoint = .top) { perform(id, anchor) }
}

private struct TranscriptScrollKey: EnvironmentKey {
    static let defaultValue = TranscriptScrollAction { _, _ in }
}

extension EnvironmentValues {
    var transcriptScroll: TranscriptScrollAction {
        get { self[TranscriptScrollKey.self] }
        set { self[TranscriptScrollKey.self] = newValue }
    }
}

// MARK: - Transcript

/// Where the reader is, as the transcript reports it to its screen.
struct TranscriptViewport: Equatable {
    /// The row at the top of the screen and how far into it; nil at the
    /// latest message.
    var anchor: TranscriptScrollBridge.Anchor?
    var atBottom: Bool
}

/// The scrollable transcript, rendered as a **vertical timeline**: a continuous
/// rail runs top-to-bottom and every event — each user message, reasoning block,
/// tool call, tool group, assistant text segment, and system note — is a node on
/// it (`TranscriptTimeline.buildPersisted` flattens persisted + optimistic pending
/// turns and `buildLive` the live streaming turn, into `[TimelineNode]`). An
/// optional leading `header` scrolls away above the first node.
///
/// Backed by `List` (UICollectionView-backed) so it recycles cells and only
/// realizes on-screen rows — the iOS-native counterpart to the web client's
/// `virtua` windowing — which suits the timeline well (many small per-part rows).
///
/// To keep opening a very long session fast, only a **window** of the most recent
/// turns is built and rendered initially; older turns are revealed as the user
/// scrolls up (see the windowing section below). This bounds the on-open work —
/// decode aside, both node construction and the initial `List` layout become
/// O(window) rather than O(history).
///
/// **Keeping the reader's place.** `List` can't hold a row still while rows go
/// in above it, so a ``TranscriptScrollBridge`` reaches its collection view
/// and does it in UIKit's layout pass: older turns brought in, or a picture
/// above that loaded taller than its placeholder, move nothing on screen. The
/// same bridge saves where the reader is (``TranscriptViewport``) and opens
/// the transcript there again (`restore`), instead of at the latest message.
/// Only the reader's own scroll, their send or a tap on the latest-message
/// button moves the view to the bottom; a refresh or a reconnect never does.
struct TranscriptView<Header: View>: View {
    let turns: [MessageTurn]
    let pendingUserTurns: [MessageTurn]
    let liveTurn: LiveTurn?
    /// When the live turn was rebuilt from a reattach snapshot, it is the
    /// authoritative complete in-flight reply; the persisted partial copy the
    /// agent is concurrently writing into `turns` is hidden so it isn't doubled.
    var liveOwnsInFlightReply: Bool
    /// The running turn's prompt, as the server stamps it
    /// (`in_flight_user_turn_id`). The persisted copy of the running reply is
    /// what follows it; without it, what follows the last user turn.
    var inFlightPromptID: String?
    /// The session's agent, for the agent-branded marker on assistant nodes.
    let agent: AgentType
    /// A cheap, monotonic version of the view model's `turns`, bumped on every
    /// mutation. The persisted node tier is memoized on it (plus the window /
    /// pending / suppression signals), so a streamed token — which re-runs this
    /// view via `scrollTick` — no longer rebuilds and re-hashes the whole visible
    /// transcript to follow the scroll.
    let turnsVersion: Int
    /// Bumped on streamed content growth; the transcript follows it ONLY while
    /// pinned to the bottom.
    let scrollTick: Int
    /// Bumped on the user's own send, the latest-message button and an open
    /// from a notification; forces a re-pin regardless of the scroll position.
    let stickTick: Int
    /// Reports whether the viewport is parked at the bottom. The owning view uses
    /// it to show/hide the floating "jump to latest" button (which lives above the
    /// compose bar, not here, so it is reliably tappable).
    let onPinnedChange: (Bool) -> Void
    /// Global index of `turns[0]`: above 0 while older turns are still on
    /// the server (the session opened with a window of its latest turns).
    var turnsOffset: Int
    /// Older turns can be fetched from the server.
    var hasOlderOnServer: Bool
    /// Fetches the page of turns before `turns[0]` and puts it in front.
    var onLoadOlder: () async -> Void
    /// An older page is on its way.
    var isLoadingOlder: Bool
    /// The first turn shown (global index). Kept by the session's model, so
    /// the window survives this screen; nil follows the end.
    var windowStart: Int?
    var onWindowStartChange: (Int?) -> Void
    /// Where the transcript opens. Read once, when the screen appears.
    var restore: ReadingRestore
    /// Where the reader is: whenever scrolling settles, and when the screen
    /// or the app goes.
    var onViewportChange: (TranscriptViewport) -> Void
    /// A message search hit to open at. `restore` is already anchored at its
    /// turn; this picks the turn's row that holds the searched words and
    /// lights it for a moment once it is in place.
    var jump: TranscriptJump?
    /// The transcript is at the jump's row (or couldn't get there).
    var onJumpLanded: (TranscriptJump) -> Void
    /// Where the session's paths point. With it, messages and replies that
    /// refer to media files show them as cards.
    var mediaContext: MediaPathContext?
    /// Which of those files are on the server; a card shows once its file is found.
    var mediaPresence: MediaPresence?
    /// Scrolls with the content as the first element (header above the first
    /// node). Kept generic so the transcript stays agnostic of the header's type.
    @ViewBuilder var header: () -> Header

    init(turns: [MessageTurn], pendingUserTurns: [MessageTurn], liveTurn: LiveTurn?,
         liveOwnsInFlightReply: Bool = false, inFlightPromptID: String? = nil, agent: AgentType, turnsVersion: Int,
         scrollTick: Int, stickTick: Int, onPinnedChange: @escaping (Bool) -> Void,
         turnsOffset: Int = 0, hasOlderOnServer: Bool = false,
         onLoadOlder: @escaping () async -> Void = {}, isLoadingOlder: Bool = false,
         windowStart: Int? = nil, onWindowStartChange: @escaping (Int?) -> Void = { _ in },
         restore: ReadingRestore = .bottom,
         onViewportChange: @escaping (TranscriptViewport) -> Void = { _ in },
         jump: TranscriptJump? = nil, onJumpLanded: @escaping (TranscriptJump) -> Void = { _ in },
         mediaContext: MediaPathContext? = nil, mediaPresence: MediaPresence? = nil,
         @ViewBuilder header: @escaping () -> Header) {
        self.turns = turns
        self.pendingUserTurns = pendingUserTurns
        self.liveTurn = liveTurn
        self.liveOwnsInFlightReply = liveOwnsInFlightReply
        self.inFlightPromptID = inFlightPromptID
        self.agent = agent
        self.turnsVersion = turnsVersion
        self.scrollTick = scrollTick
        self.stickTick = stickTick
        self.onPinnedChange = onPinnedChange
        self.turnsOffset = turnsOffset
        self.hasOlderOnServer = hasOlderOnServer
        self.onLoadOlder = onLoadOlder
        self.isLoadingOlder = isLoadingOlder
        self.windowStart = windowStart
        self.onWindowStartChange = onWindowStartChange
        self.restore = restore
        self.onViewportChange = onViewportChange
        self.jump = jump
        self.onJumpLanded = onJumpLanded
        self.mediaContext = mediaContext
        self.mediaPresence = mediaPresence
        self.header = header
        let anchored = restore != .bottom
        _stuckToBottom = State(initialValue: !anchored)
        _isRestoring = State(initialValue: anchored)
    }

    private let bottomAnchor = "transcript-bottom-anchor"
    private let topRowID = "transcript-top-row"

    /// Whether the viewport is parked at (or near) the bottom. Drives the
    /// auto-follow (only follow streamed tokens when true). True on a fresh
    /// open at the latest message, false when opening at a saved position.
    @State private var stuckToBottom: Bool
    @State private var isUserScrolling = false
    /// Opening at a saved position: the list stays hidden until it is there.
    @State private var isRestoring: Bool
    /// Within reach of the top: older turns come in.
    @State private var nearTop = false
    /// Bumped when a restore lands, to look again at the top from a fresh view.
    @State private var revealCheck = 0
    /// The first appearance decided where the transcript opens. Later ones
    /// (back from another tab, or from a screen pushed on top) keep the list
    /// where it is: it scrolled to the bottom there too.
    @State private var hasAppeared = false
    /// The list's collection view, for holding rows still and for positions.
    @State private var bridge = TranscriptScrollBridge()
    /// The row a search hit opened at, lit for a moment.
    @State private var litRowID: String?
    @Environment(\.scenePhase) private var scenePhase

    /// Layout changes must not be mistaken for the user scrolling into history.
    private struct ScrollMetrics: Equatable {
        var atBottom: Bool
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var bottomInset: CGFloat

        init(_ geometry: ScrollGeometry) {
            contentHeight = geometry.contentSize.height
            containerHeight = geometry.containerSize.height
            bottomInset = geometry.contentInsets.bottom
            atBottom = contentHeight
                - (geometry.contentOffset.y + containerHeight - bottomInset) <= 80
        }
    }

    /// Near the top, re-read whenever the content grows, so a reveal that
    /// still leaves the reader near the top brings in the next one.
    private struct TopProximity: Equatable {
        var near: Bool
        var contentHeight: CGFloat
    }

    // MARK: Windowing
    //
    // A very long transcript (thousands of turns) is expensive to open: the whole
    // history is decoded, every turn is flattened into nodes, and `List` lays out
    // the full set before the first frame — on a 6k-turn session that's hundreds of
    // ms of on-main work, exactly the cost the web client avoids by virtualizing.
    // So we only build + render a *window* of the most recent turns initially, and
    // bring older ones in as the user scrolls up. `build` + the `List` layout become
    // O(window) instead of O(history), so open time stops growing with length.
    //
    // The window's start is a global index (in the whole transcript), kept by the
    // session's model (`windowStart`); `nil` means "not yet expanded" → the window
    // is anchored to the tail and follows new turns. Persisted turns only grow at
    // the end, and older ones fetched from the server go in front of `turns`
    // (lowering `turnsOffset`), so a global index stays valid either way.
    //
    // Older turns come in before the reader reaches them: within 1.5 screens of
    // the top, the next held turns join the window, and once fewer than
    // `prefetchMarginTurns` held turns are left above it, the server's next page
    // is fetched in the background, joining `turns` without changing the window.
    // Each step is held still by the bridge, so the reader sees no movement.

    /// How many trailing turns to show on first open. Enough to fill the viewport
    /// with room to spare; small enough that layout is instant.
    private let initialTurnWindow = 50
    /// How many held turns join the window at a time.
    private let revealTurns = 60
    /// Fetch the server's next older page once fewer held turns than this are
    /// left above the window.
    private let prefetchMarginTurns = 100
    /// How close to the top, in screen heights, older turns start coming in.
    private let nearTopScreens: CGFloat = 1.5

    // MARK: Node memoization
    //
    // `body` re-runs on every streamed token (the scroll-follow bumps `scrollTick`),
    // but the *persisted* node tier changes only when `turns` / the window / pending
    // / in-flight suppression change — never per token. Rebuilding it per token is
    // O(all visible text): `MessageRender.adaptTurn`'s value-keyed cache hashes each
    // `MessageTurn`'s full content on lookup (`MessageTurn` is content-`Hashable`).
    // So the persisted tier is memoized behind this cheap, content-free key and only
    // rebuilt when the key changes. The live tier is always rebuilt fresh (cheap,
    // and required so live tool / plan state doesn't freeze — see `buildLive`).
    //
    // The cache lives in a reference holder (a plain class) so it survives the
    // per-token re-instantiation of this struct at its fixed position, and so the
    // `nodes` accessor can update it without tripping `@State` invalidation: we
    // mutate the holder's fields, never reassign the `@State`. Safe because `body`
    // and the builders are `@MainActor`, so every access is serialized.
    private struct PersistedKey: Equatable {
        var turnsVersion: Int
        var effectiveStart: Int
        var pendingIDs: [String]
        var suppressInFlight: Bool
        var inFlightPromptID: String?
        var liveCoverage: TranscriptTimeline.LiveCoverage?
        var agent: AgentType
        var mediaContext: MediaPathContext?
        /// Bumped when an existence check answers.
        var mediaVersion: Int
    }
    private final class PersistedMemo {
        var key: PersistedKey?
        var nodes: [TimelineNode] = []
    }
    @State private var persistedMemo = PersistedMemo()

    /// The window's start (global): the model's, widened to show the saved
    /// position's row.
    private var windowStartGlobal: Int? {
        switch (windowStart, restoreWindowStart) {
        case let (kept?, saved?): return min(kept, saved)
        case let (kept?, nil): return kept
        case let (nil, saved?): return saved
        case (nil, nil): return nil
        }
    }

    /// The start that shows the saved position's row, while opening there.
    private var restoreWindowStart: Int? {
        guard case .anchored(let position) = restore else { return nil }
        return ReadingRestore.windowStart(for: position, turnIDs: turns.map(\.id), turnsOffset: turnsOffset)
    }

    /// The first turn index currently shown. When not explicitly expanded, anchors
    /// to the tail (most recent `initialTurnWindow` turns), snapped back to a
    /// user/system boundary so an assistant reply is never split and keeps its
    /// originating question in-window (jump-to-question stays correct).
    private var effectiveStart: Int {
        if let s = windowStartGlobal { return snappedStart(min(max(0, s - turnsOffset), turns.count)) }
        // While a reattached live turn stands in for the persisted copy of the
        // running reply, that copy is hidden: count the window back from the
        // reply's prompt. Counting from the end let a long running reply push
        // everything the reader had on screen out of the window, leaving the
        // prompt and the live turn alone on a screen too short to scroll.
        var tailEnd = turns.count
        if liveTurn != nil, liveOwnsInFlightReply,
           let prompt = TranscriptTimeline.inFlightPromptIndex(in: turns, promptID: inFlightPromptID) {
            tailEnd = prompt + 1
        }
        guard tailEnd > initialTurnWindow else { return 0 }
        return snappedStart(tailEnd - initialTurnWindow)
    }

    /// Whether the window reaches the true start of the conversation (everything
    /// loaded). Only then is the scrollaway `header` shown and the rail's top capped.
    private var headLoaded: Bool { effectiveStart == 0 && !hasOlderOnServer }

    /// Walk back from `desired` to the nearest non-assistant (user/system) turn so
    /// the window never starts in the middle of a merged assistant reply.
    private func snappedStart(_ desired: Int) -> Int {
        guard !turns.isEmpty else { return 0 }
        guard desired < turns.count else { return turns.count }
        var i = max(0, desired)
        while i > 0, turns[i].role == .assistant { i -= 1 }
        return i
    }

    /// The flattened timeline: a memoized **persisted** tier + a fresh **live**
    /// tier. The persisted tier is expensive (it hashes every visible turn's content
    /// through `adaptTurn`'s cache), so it is reused whenever the cheap `PersistedKey`
    /// is unchanged — which is every streamed token. The live tier is rebuilt each
    /// pass (cheap; keeps live tool / plan cards updating). Rail endpoints are
    /// terminated on the *combined* list so the tail's `connectBottom` lands on the
    /// live node while a reply streams.
    private var nodes: [TimelineNode] {
        let start = effectiveStart
        let suppressInFlight = liveTurn != nil && liveOwnsInFlightReply
        // What the live turn holds, so the persisted copy is hidden only where
        // the live one shows all of it (see `TranscriptTimeline.liveCovers`).
        let coverage = suppressInFlight
            ? liveTurn.map { TranscriptTimeline.LiveCoverage(toolIDs: $0.toolCallIDs, imageCount: $0.imageCount) }
            : nil
        let key = PersistedKey(
            turnsVersion: turnsVersion,
            effectiveStart: start,
            pendingIDs: pendingUserTurns.map(\.id),
            suppressInFlight: suppressInFlight,
            inFlightPromptID: inFlightPromptID,
            liveCoverage: coverage,
            agent: agent,
            mediaContext: mediaContext,
            mediaVersion: mediaPresence?.version ?? 0
        )

        let persisted: [TimelineNode]
        if persistedMemo.key == key {
            persisted = persistedMemo.nodes
        } else {
            let slice = start == 0 ? turns : Array(turns[start...])
            persisted = TranscriptTimeline.buildPersisted(
                turns: slice, pending: pendingUserTurns, agent: agent,
                suppressInFlight: suppressInFlight, inFlightPromptID: inFlightPromptID, liveCoverage: coverage,
                media: mediaContext, presence: mediaContext == nil ? nil : mediaPresence
            )
            persistedMemo.key = key
            persistedMemo.nodes = persisted
        }

        var all = persisted
        if let liveTurn {
            all.append(contentsOf: TranscriptTimeline.buildLive(liveTurn, agent: agent))
        }
        // Terminate the rail at its endpoints, on the *combined* list. The top
        // terminates only when the window starts at the true beginning of the
        // conversation; otherwise the spine continues up into the not-yet-loaded
        // turns.
        if !all.isEmpty {
            if start == 0, !hasOlderOnServer { all[0].connectTop = false }
            all[all.count - 1].connectBottom = false
        }
        return all
    }

    /// The list's rows as the bridge maps them: the top row, the nodes, the
    /// bottom anchor.
    private func rowInfos(_ nodes: [TimelineNode]) -> [TranscriptScrollBridge.RowInfo] {
        var rows: [TranscriptScrollBridge.RowInfo] = [.init(id: topRowID, anchorable: false)]
        rows.reserveCapacity(nodes.count + 2)
        for node in nodes { rows.append(.init(id: node.id, turnID: node.turnID)) }
        rows.append(.init(id: bottomAnchor, anchorable: false))
        return rows
    }

    /// Bring older turns into view: the next held ones, or, with all held
    /// turns shown, the server's next page (which joins `turns` and is then
    /// revealed by `onChange(of: turnsOffset)`). Each step is held still by
    /// the bridge, and goes in without animation.
    private func revealEarlier() {
        let current = effectiveStart
        if current > 0 {
            let local = snappedStart(max(0, current - revealTurns))
            let next = turnsOffset + local
            // The rows after the change: the top row, the new window's nodes
            // (counted as built), the bottom anchor.
            let rowsAfter = nodeCount(from: local) + 2
            bridge.coverUpdate(expectedRows: rowsAfter)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onWindowStartChange(next) }
            prefetchOlder(localStart: next - turnsOffset)
        } else if hasOlderOnServer, !isLoadingOlder {
            Task { await onLoadOlder() }
        }
    }

    /// Fetch the server's next older page in the background while the reader
    /// still has held turns to scroll through.
    private func prefetchOlder(localStart: Int) {
        guard hasOlderOnServer, !isLoadingOlder, localStart < prefetchMarginTurns else { return }
        Task { await onLoadOlder() }
    }

    /// Older turns go in only while the list is at rest (under a picture of
    /// the screen, see ``TranscriptScrollBridge/coverUpdate(expectedRows:)``):
    /// a reader still scrolling gets them when the scroll ends.
    private func revealIfNeeded() {
        guard nearTop, !stuckToBottom, !headLoaded, !isRestoring, !isUserScrolling else { return }
        revealEarlier()
    }

    /// How many nodes the transcript shows with the window starting at `local`.
    private func nodeCount(from local: Int) -> Int {
        let suppressInFlight = liveTurn != nil && liveOwnsInFlightReply
        let coverage = suppressInFlight
            ? liveTurn.map { TranscriptTimeline.LiveCoverage(toolIDs: $0.toolCallIDs, imageCount: $0.imageCount) }
            : nil
        var count = TranscriptTimeline.buildPersisted(
            turns: Array(turns[local...]), pending: pendingUserTurns, agent: agent,
            suppressInFlight: suppressInFlight, inFlightPromptID: inFlightPromptID, liveCoverage: coverage,
            media: mediaContext, presence: mediaContext == nil ? nil : mediaPresence
        ).count
        if let liveTurn { count += TranscriptTimeline.buildLive(liveTurn, agent: agent).count }
        return count
    }

    var body: some View {
        let nodes = self.nodes
        let headLoaded = self.headLoaded
        let _ = bridge.setRows(rowInfos(nodes))
        ScrollViewReader { proxy in
            List {
                // Top of the list. When the whole history is loaded, the `header`
                // scrolls above the first node (no gutter marker, standard margin).
                // While older turns are still windowed out, one row of a fixed
                // height says so: a button, or a spinner while the server's page
                // is on its way, so neither pushes the content when they swap.
                if headLoaded {
                    header()
                        .background(TranscriptCollectionFinder { bridge.attach($0) })
                        .modifier(TimelineRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))
                } else {
                    EarlierMessagesRow(loading: isLoadingOlder && effectiveStart == 0) {
                        revealEarlier()
                    }
                    .background(TranscriptCollectionFinder { bridge.attach($0) })
                    .modifier(TimelineRowChrome(top: 0, leading: TimelineMetrics.rowTrailingInset))
                }

                ForEach(nodes) { node in
                    TimelineRailRow(
                        marker: node.marker,
                        connectTop: node.connectTop,
                        connectBottom: node.connectBottom,
                        startsGroup: node.startsGroup
                    ) {
                        NodeBody(node: node)
                            .background {
                                if litRowID == node.id { JumpHighlight() }
                            }
                    }
                    .modifier(TimelineRowChrome())
                    // Fade newly-inserted nodes in (the optimistic user bubble on
                    // send, the thinking tick, each streamed segment) instead of a
                    // hard cut. Pure opacity only — a geometric transition would
                    // seam the continuous rail. Driven by the `.animation(value:)`
                    // on the transcript in `SessionDetailView`.
                    .transition(.opacity)
                    .id(node.id)
                }

                // Zero-height anchor we scroll to (a little top inset keeps the
                // last node off the compose bar). Outside the rail (no gutter).
                Color.clear
                    .frame(height: 1)
                    .background(TranscriptCollectionFinder { bridge.attach($0) })
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(bottomAnchor)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(TranscriptCollectionFinder { bridge.attach($0) })
            // Let the 1pt anchor row actually be 1pt (List's default min row
            // height would otherwise pad it to ~44).
            .environment(\.defaultMinListRowHeight, 1)
            // The first paint lands at the newest node, or (opening at a saved
            // position) the bridge scrolls there before the list shows. Size
            // changes keep the bottom only while following it; scrolled up, the
            // bridge holds the reader's row instead.
            .defaultScrollAnchor(restore == .bottom ? .bottom : .top, for: .initialOffset)
            .defaultScrollAnchor(stuckToBottom ? .bottom : TranscriptScrollBridge.scrolledUpSizeAnchor, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .opacity(isRestoring ? 0 : 1)
            // Publish a scroll capability so a reply's "scroll to question" button
            // (deep inside a row) can move the viewport to the user message.
            .environment(\.transcriptScroll, TranscriptScrollAction { id, anchor in
                setStuck(false)
                onPinnedChange(false)
                bridge.releaseLock()
                withAnimation(Theme.Motion.scroll) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            })
            .onScrollPhaseChange { old, phase, context in
                let wasUserScrolling = isUserScrolling
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if isUserScrolling || wasUserScrolling {
                    let atBottom = ScrollMetrics(context.geometry).atBottom
                    setStuck(atBottom)
                    onPinnedChange(atBottom)
                }
                // An animated programmatic scroll (the status bar's scroll to
                // the top) goes where it goes; the hold is taken again where it
                // ends.
                if phase == .animating { bridge.releaseLock() }
                // Settled (the reader's scroll, or a programmatic one): hold the
                // row now at the top, and save where the reader is.
                if phase == .idle, old != .idle {
                    bridge.captureLock()
                    reportViewport()
                    revealIfNeeded()
                }
            }
            // Keep following through keyboard/compose inset changes and late
            // List row measurement. Only a user scroll can unpin the viewport;
            // shrinking its visible area or inserting rows cannot revoke intent.
            .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { old, new in
                if isUserScrolling {
                    setStuck(new.atBottom)
                    onPinnedChange(new.atBottom)
                } else if stuckToBottom {
                    if old.contentHeight != new.contentHeight
                        || old.containerHeight != new.containerHeight
                        || old.bottomInset != new.bottomInset {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                } else if new.atBottom, !isRestoring {
                    setStuck(true)
                    onPinnedChange(true)
                    reportViewport()
                }
            }
            // Bring older turns in before the reader reaches the top: within
            // 1.5 screens of it. Re-read as the content grows, so a reveal that
            // leaves the reader near the top brings in the next.
            .onScrollGeometryChange(for: TopProximity.self) { geo in
                TopProximity(
                    near: ScrollAnchorMath.isNearTop(contentOffsetY: geo.contentOffset.y,
                                                     topInset: geo.contentInsets.top,
                                                     viewportHeight: geo.containerSize.height,
                                                     screens: nearTopScreens),
                    contentHeight: geo.contentSize.height
                )
            } action: { _, proximity in
                // The bridge reads this from the list itself (it sees offsets
                // SwiftUI doesn't); this is for a list it couldn't reach.
                guard bridge.collectionView == nil else { return }
                nearTop = proximity.near
                // `!stuckToBottom` rejects the transient near-top geometry reported
                // while the list is still settling onto the bottom anchor at open —
                // otherwise a fresh open would immediately page in older history.
                revealIfNeeded()
            }
            // A page from the server joined `turns`: show it if the reader is
            // waiting near the top for it.
            .onChange(of: turnsOffset) { _, _ in revealIfNeeded() }
            .onChange(of: revealCheck) { _, _ in revealIfNeeded() }
            // Streamed growth: follow instantly, but ONLY while pinned. A single
            // plain `scrollTo` per tick (no re-assert) — the content is already
            // moving, so anything heavier stacks and stutters.
            .onChange(of: scrollTick) { _, _ in
                guard stuckToBottom else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            // Force re-pin (user send / jump-to-latest tap / an open from a
            // notification), regardless of scroll state. Routed through
            // `scrollToBottom`, which re-asserts on the next runloop: the first
            // pass can stop short when rich content (code blocks / markdown) is
            // still measuring taller, so a far jump would otherwise land above
            // the true bottom.
            .onChange(of: stickTick) { _, _ in
                cancelRestore()
                setStuck(true)
                onPinnedChange(true)
                scrollToBottom(proxy)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { reportViewport() }
            }
            .onAppear { appear(proxy) }
            .onDisappear { reportViewport() }
        }
    }

    // MARK: Position

    private func setStuck(_ stuck: Bool) {
        if stuckToBottom != stuck { stuckToBottom = stuck }
        bridge.pinned = stuck
    }

    /// Open at the latest message, or at the saved position: hidden until the
    /// bridge has scrolled there (or, if it can't reach the list, until
    /// SwiftUI has scrolled to the row's top).
    private func appear(_ proxy: ScrollViewProxy) {
        bridge.pinned = stuckToBottom
        bridge.onUserScroll = {
            setStuck(false)
            onPinnedChange(false)
        }
        bridge.onScrollSettled = { reportViewport() }
        // Near the top: look at the window from a fresh view (`revealCheck`).
        bridge.onNearTop = { near in
            nearTop = near
            if near { revealCheck &+= 1 }
        }
        guard !hasAppeared else { return }
        hasAppeared = true
        guard isRestoring, case .anchored(let position) = restore else {
            setStuck(true)
            onPinnedChange(true)
            scrollToBottom(proxy)
            return
        }
        // The model keeps the window that shows the saved row.
        if let start = restoreWindowStart, windowStart.map({ start < $0 }) ?? true {
            onWindowStartChange(start)
        }
        let shown = nodes
        // A search hit: the row of its turn that holds the searched words,
        // a little below the top.
        let jumpRow = jump.flatMap { TranscriptJump.row(for: $0, in: shown) }
        let target: (id: String, offset: Double)? = jumpRow.map { (id: $0, offset: -Double(TranscriptJump.topGap)) }
            ?? ReadingRestore.resolve(position, rows: shown.map { (id: $0.id, turnID: $0.turnID) })
        guard let target else {
            isRestoring = false
            setStuck(true)
            onPinnedChange(true)
            scrollToBottom(proxy)
            if let jump { onJumpLanded(jump) }
            return
        }
        setStuck(false)
        onPinnedChange(false)
        bridge.onRestored = {
            isRestoring = false
            revealCheck &+= 1
            reportViewport()
            landJump(at: jumpRow)
        }
        bridge.restore(id: target.id, offset: CGFloat(target.offset))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard isRestoring else { return }
            bridge.cancelRestore()
            proxy.scrollTo(target.id, anchor: .top)
            isRestoring = false
            landJump(at: jumpRow)
        }
    }

    /// Opened at a search hit: light its row for a moment, and let the model
    /// forget the jump.
    private func landJump(at row: String?) {
        guard let jump else { return }
        onJumpLanded(jump)
        guard let row else { return }
        withAnimation(.easeOut(duration: 0.2)) { litRowID = row }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard litRowID == row else { return }
            withAnimation(.easeOut(duration: 0.7)) { litRowID = nil }
        }
    }

    private func cancelRestore() {
        guard isRestoring else { return }
        bridge.cancelRestore()
        isRestoring = false
    }

    /// Tell the screen where the reader is.
    private func reportViewport() {
        guard !isRestoring else { return }
        if stuckToBottom {
            onViewportChange(TranscriptViewport(anchor: nil, atBottom: true))
        } else if let anchor = bridge.topAnchor(preferPersisted: true) {
            onViewportChange(TranscriptViewport(anchor: anchor, atBottom: false))
        }
    }

    /// Reassert a far jump after List has realized its destination rows.
    /// Subsequent layout changes are followed by the geometry observer above.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard stuckToBottom, !isUserScrolling else { return }
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}

/// Behind the row a search hit opened at, for a moment: the search's
/// highlighter colour, a little wider than the row's content.
private struct JumpHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.searchMatch)
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The top row while older turns are windowed out: "Show earlier messages",
/// or a spinner while the server's page is on its way. One fixed height for
/// both, so the swap never moves the content under it.
private struct EarlierMessagesRow: View {
    let loading: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            if loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                // Older turns normally come in as the reader nears the top. A
                // window too short to scroll never gets near it, so the way up
                // is also a plain button.
                Button(action: action) {
                    Label("Show earlier messages", systemImage: "arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }
}

/// Shared chrome for a timeline row: transparent background, no separators, and
/// the timeline's leading/trailing insets (the leading one lines the gutter marker
/// up with the nav bar's leading button). Vertical insets are 0 — the per-node
/// vertical rhythm is baked into `TimelineRailRow` so the continuous rail
/// background spans the inter-node spacing (a `listRowInsets` gap would break the
/// spine). The header row passes a small `top` since it has no rail of its own.
private struct TimelineRowChrome: ViewModifier {
    var top: CGFloat = 0
    /// Leading inset. Defaults to the rail's wider inset (which lines the gutter
    /// marker up with the nav button); the marker-less header overrides it to the
    /// standard symmetric margin.
    var leading: CGFloat = TimelineMetrics.rowLeadingInset

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: top,
                leading: leading,
                bottom: 0,
                trailing: TimelineMetrics.rowTrailingInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
