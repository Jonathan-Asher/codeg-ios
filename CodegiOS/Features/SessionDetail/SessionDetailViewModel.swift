import SwiftUI
import Observation

/// Drives the session detail screen: loads the transcript, sends prompts, and
/// consumes the live ACP event stream — mapping each event onto the in-flight
/// assistant turn. All mutable UI state lives here on the main actor, so there
/// are no data races even though the WebSocket delivers frames concurrently
/// (the consuming `Task` is main-actor isolated, so `for await` hops back to the
/// main actor on every frame).
@MainActor
@Observable
final class SessionDetailViewModel {

    // MARK: - Load phase

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    // MARK: - Inputs

    private let client: CodegClient

    /// What this screen is bound to: an existing conversation, or a brand-new
    /// task that adopts its conversation id from the `conversation_linked`
    /// event after the first prompt.
    private enum Mode {
        case existing(conversationID: Int)
        case new(NewSessionRequest)
    }
    private let mode: Mode

    /// The bound conversation id — fixed for an existing conversation; nil for
    /// a new task until the server links one.
    private(set) var conversationID: Int?
    /// The new-task payload (nil when opened on an existing conversation).
    private(set) var newRequest: NewSessionRequest?

    /// Drives the agent-options sheet (mode + config selectors). Shares this
    /// model's chat connection so applying an option targets the same agent the
    /// next send will reuse.
    let agentOptions: AgentOptionsModel

    /// Backs the compose "+" menu's insert pickers (quick messages / experts /
    /// slash commands). Pure-text inserts — no live connection required.
    let insertModel: ComposeInsertModel

    // MARK: - Observable state

    private(set) var phase: LoadPhase = .loading

    /// Authoritative, persisted turns from the server.
    ///
    /// The `didSet` bumps `turnsVersion` on every mutation (assignment or append)
    /// so the transcript can detect a real persisted change cheaply. `@Observable`
    /// preserves the observer (same pattern as `AppModel.selectedServerID`).
    private(set) var turns: [MessageTurn] = [] {
        didSet {
            turnsVersion &+= 1
            // Following the latest message, the reader sees what arrives.
            if isPinnedToBottom { seenTurnEnd = heldEnd }
        }
    }
    /// Global index of `turns[0]` in the whole transcript. Above 0 while
    /// older turns are still on the server (see `TranscriptSync`); they are
    /// fetched a page at a time by `loadOlderTurns()`.
    private(set) var turnsOffset = 0
    /// The server's fingerprint of the turns before `turnsOffset` (`nil`
    /// with offset 0: the whole transcript from a server without windows).
    private var windowPrefixHash: String?
    /// The whole transcript's length at the last fetch.
    private var windowTotal: Int?
    /// An older page is on its way.
    private(set) var isLoadingOlder = false
    /// Turns older than the ones held are still on the server.
    var hasOlderTurns: Bool { turnsOffset > 0 && windowPrefixHash != nil }
    /// What this screen holds of the transcript, for `TranscriptSync`.
    private var heldWindow: TranscriptWindow {
        TranscriptWindow(offset: turnsOffset, prefixHash: windowPrefixHash, total: windowTotal, turns: turns)
    }
    /// Turns fetched per older page.
    static let olderPageTurns = 150

    /// Where this session's transcript is kept between openings (`nil` in
    /// tests that don't exercise it).
    private let transcriptCache: TranscriptCache?
    private let cacheServerKey: String
    private var cacheSaveTask: Task<Void, Never>?
    /// The screen opened with the cached transcript.
    private(set) var openedFromCache = false
    /// The first load, owned by the model rather than the view, so a view
    /// that goes away mid-load (a layout change) doesn't cancel it.
    private var loadTask: Task<Void, Never>?
    /// No screen shows this session: its sockets are closed (see
    /// `SessionModelStore`). `resume()` brings it back.
    private(set) var isSuspended = false
    /// Monotonic version of `turns`, bumped on every mutation. A content-free
    /// signal the transcript keys its persisted-node memo on, so streamed tokens
    /// no longer force a re-hash of every visible turn's full text (`MessageTurn`
    /// is content-`Hashable`) just to rebuild the node list.
    private(set) var turnsVersion = 0
    /// Optimistic user turns awaiting persistence (spliced out on re-fetch).
    private(set) var pendingUserTurns: [MessageTurn] = []
    /// The assistant reply currently streaming, if any.
    private(set) var liveTurn: LiveTurn?
    /// Whether `liveTurn` was rebuilt from a reattach snapshot (vs. created by a
    /// local send). On reattach the snapshot's `live_message` is the COMPLETE
    /// in-flight reply, but the agent CLI asynchronously persists a PARTIAL copy
    /// of that same reply into `turns` while it streams — so the transcript must
    /// hide the persisted partial to avoid double-rendering the reply (see
    /// `TranscriptTimeline.buildPersisted`'s `suppressInFlight`). False on the send
    /// path, where the optimistic prompt lives in `pendingUserTurns` and `turns`
    /// carries no trailing in-flight reply to hide. Reset on every send (the one
    /// chokepoint that creates a send live turn), set on every reattach build.
    private(set) var liveTurnFromReattach = false
    /// The live turn came (partly) through a frame the server shrank to fit
    /// this socket, so it is an incomplete copy: it must not stand in for the
    /// persisted one, and the transcript is reloaded. Reset with every new
    /// live turn.
    private(set) var liveCopyIncomplete = false
    /// When a shrunk frame last reloaded the transcript (see `noteCutFrame`).
    private var cutReloadAt: Date?

    /// Where the transcript's images load from when a frame carried one by
    /// reference (`ImageData.dataRef`).
    var imageSource: ImageSource { ImageSource(baseURL: client.baseURL, token: client.token) }

    /// The server user's home, for `~/` paths in messages. Asked once per server.
    private(set) var homePath: String?

    /// Where the session's paths point: its folder, and the home for `~/`.
    /// Nil until the folder is known (a new session without one).
    var mediaPathContext: MediaPathContext? {
        guard let path = folder?.path, !path.isEmpty else { return nil }
        return MediaPathContext(folderPath: path, homePath: homePath)
    }

    /// The media cards' library (this server) and paths.
    var mediaEnvironment: MediaEnvironment? {
        mediaPathContext.map { MediaEnvironment(library: MediaLibrary.shared(for: client), context: $0) }
    }

    private static var homePaths: [String: String] = [:]

    /// Learn the home directory once; a server without it leaves `~/` paths alone.
    private func loadHomePath() async {
        let key = client.baseURL.absoluteString
        if let known = Self.homePaths[key] { homePath = known; return }
        guard let home = try? await client.homeDirectory(), home.hasPrefix("/") else { return }
        Self.homePaths[key] = home
        homePath = home
    }

    /// A pending permission request — or ExitPlanMode — awaiting the user's
    /// choice. Rendered as a card above the compose bar; nil when none is pending.
    private(set) var pendingPermission: PendingPermission? {
        didSet {
            if pendingPermission?.requestId != oldValue?.requestId {
                modeWhenPermissionAsked = pendingPermission == nil ? nil : agentOptions.currentMode?.id
            }
            syncAttention()
        }
    }
    /// The session's mode when the waiting permission card was raised.
    private var modeWhenPermissionAsked: String?

    /// Said on the permission card once the mode changed while it waited.
    /// Switching modes (to Bypass permissions, say) doesn't answer a request
    /// the agent already made, on the desktop either: it still needs a tap.
    var permissionModeNote: String? {
        guard pendingPermission != nil, let asked = modeWhenPermissionAsked,
              let now = agentOptions.currentMode, now.id != asked else { return nil }
        return "The mode is now \(now.name). This request came before the switch and still needs your answer."
    }
    /// A pending `ask_user_question` awaiting the user's answers.
    private(set) var pendingQuestion: PendingQuestion? {
        didSet { syncAttention() }
    }
    /// A pending Grok `exit_plan_mode` awaiting approve / request-changes / abandon.
    private(set) var pendingPlanApproval: PendingPlanApproval? {
        didSet { syncAttention() }
    }
    /// Revision notes waiting to be sent as a follow-up prompt after a
    /// "request changes" decision (see ``answerPlanApproval(decision:feedback:)``).
    private var pendingPlanFollowUp: String?

    private(set) var summary: ConversationSummary?
    private(set) var sessionStats: SessionStats?
    private(set) var folder: FolderDetail?

    /// The working tree's current git branch (for `folder`), shown + checkmarked
    /// in the branch selector. Seeded from conversation/folder metadata and
    /// updated optimistically on checkout / new-branch.
    private(set) var currentBranch: String?

    // MARK: - Draft new-session selection

    /// The draft's chosen agent (new session only; nil for existing). The
    /// authoritative agent for a linked/existing conversation is the summary's.
    private(set) var selectedAgent: AgentType?
    /// Agents offered in the draft's in-page picker (narrowed to installed/enabled).
    private(set) var availableAgents: [AgentType] = AgentType.allCases
    /// Folders offered in the draft's in-page picker.
    private(set) var availableFolders: [FolderDetail] = []
    /// The full folder set (`list_all_folder_details`), kept so the branch switcher
    /// can resolve a worktree's root and locate a registered target folder by id.
    private(set) var allFolders: [FolderDetail] = []
    /// True once a draft's first send begins — locks the agent/folder pickers.
    private(set) var hasStartedFirstSend = false

    /// Compose-bar text.
    var draft: String = ""

    /// Images staged for the next prompt (added via the "+" menu). Cleared when
    /// the optimistic turn is posted; restored if that send is rolled back.
    private(set) var attachments: [Attachment] = []

    var canAttachMore: Bool {
        attachments.count < AttachmentPrep.maxCount
            && attachments.reduce(0) { $0 + $1.byteCount } < AttachmentPrep.maxTotalBytes
    }

    /// Uploads attached videos and audio files: the server, or a fake in tests.
    @ObservationIgnored var uploaderOverride: (any AttachmentUploading)?
    private var uploader: any AttachmentUploading { uploaderOverride ?? client }
    /// Compresses attached videos (AVFoundation; a fake in tests).
    @ObservationIgnored var videoPreparer: any VideoPreparing = VideoAttachmentPrep()
    /// The upload bucket of a session not created yet.
    @ObservationIgnored private let uploadSessionID = UUID()

    /// Coarse phase of an in-flight send, for the compose status line.
    enum SendState: Equatable {
        case idle
        case connecting
        case thinking
        case running(tool: String)
        case error(String)
    }
    private(set) var sendState: SendState = .idle

    /// A transient, non-fatal notice (e.g. "a turn is already running").
    var notice: String?

    // MARK: - Reading position

    /// The saved reading positions (UserDefaults; a scratch store in tests).
    @ObservationIgnored let readingPositions: ReadingPositionStore
    /// The first turn the transcript shows (global index); nil while it
    /// follows the end. Kept here, not in the view, so leaving the session and
    /// coming back finds the same history on screen.
    var transcriptWindowStart: Int?
    /// Where the reader was when scrolling last settled (or as saved).
    @ObservationIgnored private(set) var readingPosition: ReadingPosition?
    /// The screen the restore decision was made for, and the decision.
    @ObservationIgnored private var restoreScreen: UUID?
    @ObservationIgnored private var restoreForScreen: ReadingRestore = .bottom
    /// The next screen opens at the latest message (a notification, a link).
    @ObservationIgnored private var openAtLatestNext = false
    @ObservationIgnored private var positionSaveTask: Task<Void, Never>?
    /// How far the persisted transcript went (global end) when the reader
    /// last saw its end.
    @ObservationIgnored private(set) var seenTurnEnd = 0
    /// The live reply grew while the reader was scrolled up.
    private(set) var hasUnseenLive = false

    /// Something arrived below while the reader was scrolled up (or away):
    /// "New messages" instead of a plain jump button. The view doesn't move.
    var hasNewMessagesBelow: Bool {
        !isPinnedToBottom && (heldEnd > seenTurnEnd || hasUnseenLive)
    }

    /// Monotonic token used to scroll-to-bottom; bump it to request a scroll.
    /// The transcript follows this *only while pinned to the bottom* (so streamed
    /// tokens don't yank a user who has scrolled up to read).
    private(set) var scrollTick: Int = 0
    /// Monotonic token that *forces* a re-pin to the bottom regardless of the
    /// user's current scroll position — bumped on the user's own send and on
    /// initial load, where landing at the latest message is always intended.
    private(set) var stickTick: Int = 0
    /// Whether the transcript viewport is parked at the bottom. Reported by the
    /// transcript as the user scrolls; drives the floating "jump to latest" button
    /// (shown when false). Starts true (a fresh open lands at the latest message).
    private(set) var isPinnedToBottom = true
    /// Monotonic token bumped once each time a reply *successfully* finalizes, so
    /// the view can fire a single success haptic. Distinct from `sendState`
    /// reaching `.idle`, which also happens on a pre-acceptance rollback (that
    /// path must NOT feel like success). The error counterpart is `sendState`
    /// transitioning to `.error`, which only `failLive` sets.
    private(set) var completedTurnTick: Int = 0
    /// Monotonic token bumped only when the *user* toggles pin / status, so the
    /// view fires a selection haptic on the action itself. Keying the haptic on the
    /// derived `isPinned` / `currentStatus` instead mis-fires on the async `summary`
    /// load (nil → value), buzzing on every session open.
    private(set) var userToggleTick: Int = 0

    // MARK: - Live session signals (codeg fork)

    /// The live connection can take a message into the running turn through
    /// the native `_session/steering` channel (snapshot
    /// `native_steering_available`, or an `awaiting_background` event).
    private(set) var nativeSteeringAvailable = false
    /// The prompting turn is held open only for background work: the agent
    /// answered and is idle, and a message is delivered at once.
    private(set) var awaitingBackground = false
    /// Background tasks still running (0 = none or count unknown).
    private(set) var backgroundOutstanding = 0
    /// The latest `attach_progress` phase while the session is being opened.
    private(set) var attachPhase: String?

    /// A message waiting for the running turn to end (or, while the turn is
    /// held for background work, for the agent to go idle).
    struct QueuedMessage: Identifiable, Hashable {
        let id: UUID
        let text: String
        let attachments: [Attachment]
        /// Queued explicitly for the END of the turn: never delivered into a
        /// held turn, only sent once the turn finishes.
        let holdUntilTurnEnd: Bool
        /// The id every send of this message carries (`client_message_id`, and
        /// the client id of an insert into the turn). The server answers a
        /// repeat with the same id as already delivered, so a resend after a
        /// lost answer is never a second message.
        var clientMessageID: String = "ios-" + UUID().uuidString
        /// Set when a send failed: the row says "Not sent" and why. See
        /// ``SendFailure``.
        var failure: SendFailure? = nil
    }
    /// The queue, also this conversation's local outbox: stored on every
    /// change (see ``OutboxStore``).
    private(set) var queuedMessages: [QueuedMessage] = [] {
        didSet { persistOutbox() }
    }
    /// Messages on their way that the server has not acknowledged yet, by
    /// client id. Stored with the queue, so one whose send outlives the app
    /// comes back at the front of the queue.
    @ObservationIgnored private var inflightMessages: [String: OutboxMessage] = [:]
    @ObservationIgnored private let outboxServerKey: String
    /// The outbox was read for this conversation.
    @ObservationIgnored private var restoredOutboxFor: Int?
    /// Sends a "Not sent" head again once its backoff has passed.
    @ObservationIgnored private var unsentResendTask: Task<Void, Never>?
    /// A message sent into the running turn (`submit_session_feedback`). It
    /// waits above the composer only while it is on its way, or, on the pull
    /// channel, until the agent reads it. Once the agent has it, it is in the
    /// conversation: a message of the user's inside the reply, where the agent
    /// took it (``LiveTurn/insertSteered(id:serverID:text:blocks:timestamp:)``).
    struct InsertedNote: Identifiable, Hashable {
        let id: UUID
        let text: String
        /// What the conversation shows: the text, then any pictures.
        let blocks: [ContentBlock]
        /// The server's note id, from the echo, the response or a snapshot.
        var serverID: String?
        /// What the server said about it, when it said.
        var serverStatus: FeedbackNoteSnapshot.Status?
        /// The server answered the request.
        var resolved: Bool
        /// The agent has the message.
        var delivered: Bool
        /// It shows in the conversation, inside the reply.
        var inThread: Bool
        /// The turn it was sent into (``SessionDetailViewModel/turnSerial``).
        let turnSerial: Int
    }
    private(set) var insertedNotes: [InsertedNote] = []
    /// The messages above the composer: on their way into the turn, or
    /// waiting for an agent that reads them through its feedback tool.
    var stripNotes: [InsertedNote] { insertedNotes.filter { !$0.inThread } }
    /// Counts the turns this screen shows, so a message whose delivery is
    /// confirmed after its turn ended isn't put into the next one. A reply
    /// rebuilt from a snapshot is the same turn.
    private var turnSerial = 0
    /// A queued message is being delivered into the held turn.
    private var deliveringQueued = false

    // MARK: - Streaming internals

    private var connectionID: String?
    /// The conversation row THIS draft's first send created up front (via
    /// `create_conversation`). Held until the prompt is accepted; if the send is
    /// rolled back before then, this row is deleted so no empty conversation
    /// lingers on other clients and the draft's pickers re-open.
    private var draftCreatedConversationID: Int?
    private var stream: (any SessionEventStream)?
    /// Opens the event socket (an ``EventStream``; a scripted one in tests).
    private let makeEventStream: @MainActor () -> any SessionEventStream
    /// The outer send pipeline (resolve connection → open stream → prompt).
    private var sendTask: Task<Void, Never>?
    /// The long-lived loop consuming `stream.frames`.
    private var consumerTask: Task<Void, Never>?
    private let subscriptionID = UUID().uuidString
    /// Guards against double-finalizing a turn from racing terminal events.
    private var isTurnActive = false
    /// Bumped every time a new stream is opened. A consumer loop captures the
    /// value at spawn and ignores its own terminal frames once superseded — so
    /// closing an old stream during a stale-connection retry can't end the turn.
    private var streamGeneration = 0
    /// Pending silent reconnect after a transient socket drop (see
    /// `scheduleReconnect`). Cancelled by `closeStream`.
    private var reconnectTask: Task<Void, Never>?
    /// Tells the server this phone is looking at the session while it is on
    /// screen, so it doesn't push about it (see `SessionPresenceReporter`).
    private let presenceReporter: SessionPresenceReporter
    @ObservationIgnored private var isOnScreen = false
    /// Consecutive reconnect attempts with no frames since the last good one.
    /// Reset whenever the server confirms a fresh attach (a snapshot/replay
    /// frame). Past `maxStreamReconnects`, recovery gives up and reconciles.
    private var streamReconnects = 0
    private static let maxStreamReconnects = 6
    /// Sends resolving their connection, attaching their stream or prompting.
    private var sendsInProgress = 0
    /// The prompt is on its way to the server. A reconnect snapshot taken now
    /// can predate it, so it says nothing yet about whether this turn ended.
    private var promptInFlight = false
    /// The socket dropped after the attach was confirmed but before the send
    /// marked its turn active, so no reconnect was started; the send starts
    /// one once the prompt is accepted.
    private var streamLostBeforeTurn = false
    /// `user_message` ids the stream echoed since the last send: the server
    /// broadcasts each accepted prompt under the client message id it was
    /// sent with, so an id here proves the prompt was taken.
    private var echoedUserMessageIDs: Set<String> = []
    /// A cold reattach whose socket dropped before its snapshot tries again.
    private var reattachRetryTask: Task<Void, Never>?
    /// Cold reattach attempts lost to a dropped socket since the last snapshot.
    private var reattachDrops = 0
    private static let maxReattachDrops = 3

    private init(client: CodegClient, mode: Mode,
                 makeEventStream: (@MainActor (CodegClient) -> any SessionEventStream)? = nil,
                 transcriptCache: TranscriptCache? = nil,
                 readingPositions: ReadingPositionStore? = nil) {
        self.client = client
        self.mode = mode
        self.transcriptCache = transcriptCache
        self.readingPositions = readingPositions ?? .shared
        self.cacheServerKey = TranscriptCache.serverKey(for: client)
        self.outboxServerKey = OutboxStore.serverKey(baseURL: client.baseURL)
        if let makeEventStream {
            self.makeEventStream = { makeEventStream(client) }
        } else {
            self.makeEventStream = { EventStream(baseURL: client.baseURL, token: client.token) }
        }
        switch mode {
        case .existing(let id):
            self.conversationID = id
        case .new(let request):
            self.newRequest = request
            // Agent/folder are chosen in-page (from the agent button in the
            // navigation bar); their defaults are resolved in `load()` from the
            // server's folder + agent lists, honoring any preselected folder.
        }
        // Initialize both child models BEFORE wiring any closures: the closures
        // below capture `self`, which Swift only allows once every stored property
        // is initialized.
        self.agentOptions = AgentOptionsModel(client: client)
        self.insertModel = ComposeInsertModel(client: client)
        self.presenceReporter = SessionPresenceReporter(baseURL: client.baseURL, token: client.token)
        // Apply actions resolve (and cache) the same chat connection the send
        // flow uses, so a mode/config change targets the agent the next prompt
        // will reuse — and never spawns a second one.
        agentOptions.resolveConnection = { [weak self] in
            guard let self else { throw APIError.transport("Session closed.") }
            return try await self.resolveConnectionForOptions()
        }
        // The authoritative current mode/config for this conversation's live
        // session (nil when none is live). Used to load the sheet and to reconcile
        // after an apply, since the set_* routes only enqueue the change.
        agentOptions.loadSnapshot = { [weak self] in
            guard let self, let id = self.conversationID else { return nil }
            return try await self.client.sessionSnapshot(conversationId: id)
        }
        // A change that failed after the sheet was closed still gets said.
        agentOptions.onFailure = { [weak self] message in
            guard let self, !self.agentOptions.isSheetShown else { return }
            self.notice = message
        }

        // Quick messages + experts are connection-independent catalog reads.
        // Slash commands come from the cheap by-conversation snapshot (empty until
        // a connection binds — no agent is spawned to list them).
        insertModel.loadQuickMessagesAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.quickMessages()
        }
        insertModel.loadExpertsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.experts(agentType: self.agentTypeForUI)
        }
        insertModel.loadBuiltInExpertsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.builtInExperts()
        }
        insertModel.loadCommandsAction = { [weak self] in
            guard let self, let id = self.conversationID else { return [] }
            return try await self.client.sessionSnapshot(conversationId: id)?.availableCommands ?? []
        }

    }

    convenience init(client: CodegClient, conversationID: Int,
                     transcriptCache: TranscriptCache? = .shared,
                     readingPositions: ReadingPositionStore? = nil) {
        self.init(client: client, mode: .existing(conversationID: conversationID),
                  transcriptCache: transcriptCache, readingPositions: readingPositions)
    }

    /// An existing conversation whose event sockets come from `makeEventStream`
    /// (the unit tests' scripted sockets).
    convenience init(client: CodegClient, conversationID: Int,
                     makeEventStream: @escaping @MainActor (CodegClient) -> any SessionEventStream,
                     transcriptCache: TranscriptCache? = nil,
                     readingPositions: ReadingPositionStore? = nil) {
        self.init(client: client, mode: .existing(conversationID: conversationID),
                  makeEventStream: makeEventStream, transcriptCache: transcriptCache,
                  readingPositions: readingPositions)
    }

    /// A brand-new task: `load()` immediately fires the first prompt composed
    /// in the new-task sheet, and the screen adopts the conversation id the
    /// server links — so the very first reply streams like any other turn.
    convenience init(client: CodegClient, newSession request: NewSessionRequest,
                     transcriptCache: TranscriptCache? = .shared) {
        self.init(client: client, mode: .new(request), transcriptCache: transcriptCache)
    }

    /// Show what the session list already knows (title, agent, status) while
    /// the transcript loads. Ignored once the screen has its own summary.
    func prime(summary listed: ConversationSummary?) {
        guard summary == nil, let listed, listed.id == conversationID else { return }
        summary = listed
        insertModel.agentType = listed.agentType
    }

    // MARK: - Derived

    /// In flight only while the live turn is still streaming. A finalized,
    /// errored, or cancelled live turn stays on screen but is no longer "in
    /// flight", so the compose bar returns to its send state. (Reading the live
    /// turn's `isStreaming` here lets SwiftUI track it transitively.)
    var isInFlight: Bool { liveTurn?.isStreaming == true }

    /// True when there is no content at all to show in the loaded state.
    var isEmptyTranscript: Bool {
        turns.isEmpty && pendingUserTurns.isEmpty && liveTurn == nil
    }

    /// Whether this screen started as a new task (vs. an existing conversation).
    var isNewSession: Bool { newRequest != nil }

    /// The draft's agent/folder are still editable: a new session whose first
    /// send hasn't started yet (after that the conversation is being created).
    var isDraftEditable: Bool { isNewSession && !hasStartedFirstSend }

    /// The agent identity for UI + connection purposes: the loaded summary's
    /// (existing / linked), else the draft's chosen agent.
    var agentTypeForUI: AgentType {
        summary?.agentType ?? selectedAgent ?? .claudeCode
    }

    // MARK: - Load

    /// Guards the one-time draft option load so a re-run of `.task` can't refetch.
    private var didLoadDraftOptions = false

    /// Start the first load unless it ran or runs already. The screen calls
    /// this whenever it appears: a screen rebuilt around the same model (a
    /// layout change, a tab switched back) must not load it again.
    func loadIfNeeded() {
        guard phase != .loaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.load()
            self?.loadTask = nil
        }
    }

    func load() async {
        switch mode {
        case .existing(let id):
            restoreOutbox(conversationID: id)
            // The cached transcript first, drawn at once; then only what
            // changed since it was saved.
            if turns.isEmpty, turnsOffset == 0, let cache = transcriptCache,
               let entry = await cache.load(serverKey: cacheServerKey, conversationID: id),
               turns.isEmpty, phase != .loaded {
                applyCached(entry)
                phase = .loaded
                openedFromCache = true
                // Where it opens (the latest message, or where the reader
                // left it) is the screen's call: `restoreDecision(screen:)`.
                await syncExisting(id: id, stickToBottom: false, overlap: TranscriptSync.reopenOverlap)
                return
            }
            if phase != .loaded { phase = .loading }
            await syncExisting(id: id, stickToBottom: true)

        case .new(let request):
            // A blank draft: show the composer immediately, then populate the
            // folder + agent lists so the in-page pickers (the nav-bar agent
            // button) are ready. Nothing is sent until the user writes + taps send.
            phase = .loaded
            guard !didLoadDraftOptions else { return }
            didLoadDraftOptions = true
            if selectedAgent == nil, let agent = request.agent { selectedAgent = agent }
            await loadDraftOptions(preselectedFolderID: request.preselectedFolderID)
            // An edited first message: the new conversation starts with it.
            if let prompt = request.initialPrompt, !hasStartedFirstSend {
                startSend(text: prompt.text, attachments: prompt.images.enumerated().compactMap {
                    Attachment(image: $1, index: $0)
                }, fromComposer: false)
            }
        }
    }

    /// Re-sync an already-loaded, server-linked conversation: re-fetch its detail
    /// and reattach if a turn is live. Shared by the initial `load()` (which shows
    /// the loading spinner first) and `refreshOnForeground()` (which does not, so
    /// resuming the app doesn't flash the transcript away and back).
    private func syncExisting(id: Int, stickToBottom: Bool, overlap: Int = TranscriptSync.reopenOverlap) async {
        do {
            let held: TranscriptWindow? = turns.isEmpty && turnsOffset == 0 ? nil : heldWindow
            let version = turnsVersion
            async let fetchReq = TranscriptSync.fetch(client: client, id: id, held: held, overlap: overlap)
            async let foldersReq = client.listFolders()
            let outcome = try await fetchReq
            let folders = try await foldersReq
            let detail = outcome.detail

            summary = detail.summary
            // Another path (a turn reconciling, an older page) changed the
            // turns while this fetch ran: its copy is newer.
            if turnsVersion == version { adoptWindow(outcome, allowShrink: true) }
            sessionStats = detail.sessionStats
            allFolders = folders
            folder = folders.first { $0.id == detail.summary.folderId }
            currentBranch = detail.summary.gitBranch ?? folder?.gitBranch
            insertModel.agentType = detail.summary.agentType
            phase = .loaded
            if homePath == nil { Task { await loadHomePath() } }
            scheduleCacheSave()
            if stickToBottom { requestStickToBottom() }
            // If a turn is still running on this session (started here earlier,
            // from codeg web, or before an app relaunch), attach so it streams
            // live and any pending permission/question card surfaces.
            //
            // Two signals say "a turn is in flight", and we trust EITHER:
            //   • `in_flight_user_turn_id` — precise, but the server only stamps
            //     it when the persisted tail is `[…, User]` or `[…, User,
            //     Assistant]` (see `apply_in_flight_message_id`); it goes nil the
            //     moment the agent persists a second trailing assistant turn
            //     mid-stream — which is exactly what plan mode does (a plan/
            //     reasoning turn, then the partial reply). That nil would strand a
            //     genuinely-streaming session on a static transcript.
            //   • row `status == .inProgress` — coarser but RELIABLE: set
            //     unconditionally when the turn starts and cleared only on
            //     `TurnComplete`, so it stays true for the whole turn (including
            //     while blocked on an ExitPlanMode confirmation).
            // Treating either as live makes reattach retry through a transient
            // discovery miss; the snapshot then decides what's actually running.
            let serverSaysLive = detail.inFlightUserTurnId != nil
                || detail.summary.status == .inProgress
            reattachDrops = 0
            await reattachIfLive(serverSaysLive: serverSaysLive)
        } catch {
            // A foreground refresh failing silently leaves the existing transcript
            // on screen (better than replacing a working view with an error for a
            // transient network blip); the initial `load()` path, which has nothing
            // to fall back to, is the one that needs `phase = .failed`.
            if phase != .loaded {
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// Re-sync when the app returns to the foreground: iOS suspends the live
    /// WebSocket while backgrounded, so without this the transcript sits frozen
    /// until the user backs all the way out and re-enters (which tears down and
    /// rebuilds this whole model via `RootView`'s `.id(...)`). No-op for a draft
    /// `.new` session — there's nothing server-linked yet to resync.
    /// Two different recoveries, picked by whether a turn was actually live:
    /// a turn that was streaming is reconnected IN PLACE by
    /// `resumeStreamAfterForeground()` (the same `liveTurn`/connection, so
    /// nothing it already streamed is lost or duplicated); an idle session
    /// instead gets a full re-fetch, since nothing here would otherwise notice
    /// e.g. a rename or a message sent from another client while we were away.
    func refreshOnForeground() async {
        // A "Not sent" message goes again now that the app is back.
        defer { scheduleUnsentResend() }
        guard case .existing(let id) = mode, phase == .loaded else { return }
        // A send still attaching its stream owns its recovery (its handshake
        // opens a fresh socket); discarding the live state here would cancel it
        // and strand the message.
        if sendsInProgress > 0, !isTurnActive { return }
        if isInFlight, isTurnActive, liveTurn != nil {
            resumeStreamAfterForeground()
            return
        }
        // No turn was in flight. Discard any (now-unverifiable) stale live
        // tracking defensively before resyncing — see `discardStaleLiveState`.
        discardStaleLiveState()
        await syncExisting(id: id, stickToBottom: false)
    }

    /// Drop local tracking of a live turn WITHOUT telling the server to cancel it
    /// (unlike `cancel()`) — the turn may genuinely still be running; only our
    /// view of it (built from a socket iOS suspended while backgrounded) is
    /// stale. `reattachIfLive`, called right after, re-discovers the true state:
    /// a fresh stream if it's still going, or nothing further if the server-
    /// fetched `turns` already carry its finished reply.
    ///
    /// What the live turn showed is kept: its optimistic prompt, its reply and
    /// the messages sent into it fold into `turns` as phone-made turns, which
    /// the re-fetch replaces with the server's copies. Dropping only the live
    /// turn left the optimistic prompt behind, beside the server's copy of the
    /// same message.
    private func discardStaleLiveState() {
        guard let live = liveTurn else { return }
        isTurnActive = false
        sendTask?.cancel()
        consumerTask?.cancel()
        closeStream()
        live.flushAllText()
        live.isStreaming = false
        promoteUnreconciled(live)
        sendState = .idle
    }

    // MARK: - Transcript window and cache

    /// Show a cached transcript: the turns, identity and stats it was saved with.
    private func applyCached(_ entry: CachedTranscript) {
        var cachedSummary = entry.summary
        cachedSummary.selectorState = entry.selectorState
        summary = cachedSummary
        sessionStats = entry.sessionStats
        if let cachedFolder = entry.folder { folder = cachedFolder }
        currentBranch = cachedSummary.gitBranch ?? folder?.gitBranch
        insertModel.agentType = cachedSummary.agentType
        turnsOffset = entry.turnsOffset
        windowPrefixHash = entry.prefixHash
        windowTotal = entry.turnsTotal
        turns = entry.turns
    }

    /// Adopt a fetched window. A response that continues the held window but
    /// ends before it is a stale read (the server hasn't written what this
    /// screen showed yet), so it never takes turns away. A fresh window or a
    /// whole transcript replaces what is held, only growing it unless
    /// `allowShrink` (an authoritative reload).
    @discardableResult
    private func adoptWindow(_ outcome: TranscriptSync.Outcome, allowShrink: Bool) -> Bool {
        let window = outcome.window
        if window.end < heldEnd, outcome.continuesHeld || !allowShrink { return false }
        if window.prefixHash != nil { TranscriptSync.noteWindowed(serverKey: cacheServerKey) }
        turnsOffset = window.offset
        windowPrefixHash = window.prefixHash
        windowTotal = window.total
        turns = window.turns
        scheduleCacheSave()
        return true
    }

    /// The global end (offset + count) of what `turns` holds.
    private var heldEnd: Int { turnsOffset + turns.count }

    /// Fetch what changed since the held window (`TranscriptSync`).
    private func fetchTranscript(id: Int, overlap: Int) async throws -> TranscriptSync.Outcome {
        let held: TranscriptWindow? = turns.isEmpty && turnsOffset == 0 ? nil : heldWindow
        return try await TranscriptSync.fetch(client: client, id: id, held: held, overlap: overlap)
    }

    /// Save the transcript for the next opening, shortly after the last change.
    private func scheduleCacheSave() {
        guard let cache = transcriptCache, let id = conversationID, let summary, phase == .loaded || !turns.isEmpty
        else { return }
        let entry = CachedTranscript(
            conversationID: id, savedAt: Date(), summary: summary, selectorState: summary.selectorState,
            sessionStats: sessionStats, folder: folder, turnsOffset: turnsOffset,
            prefixHash: windowPrefixHash, turnsTotal: windowTotal, turns: turns
        )
        let key = cacheServerKey
        cacheSaveTask?.cancel()
        cacheSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await cache.save(entry, serverKey: key)
        }
    }

    /// Fetch the page of turns before the held ones and put it in front. When
    /// the server's history before the window was rewritten (a compaction),
    /// the page can't join it, and the screen starts over from the end.
    func loadOlderTurns() async {
        guard let id = conversationID, hasOlderTurns, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let before = heldWindow
        do {
            let page = try await client.conversationTurnsPage(id: id, beforeIndex: before.offset,
                                                              limit: Self.olderPageTurns)
            // Only joins the window it was asked for.
            guard conversationID == id, turnsOffset == before.offset, windowPrefixHash == before.prefixHash
            else { return }
            if let joined = TranscriptSync.prepend(page: page, to: heldWindow) {
                turnsOffset = joined.offset
                windowPrefixHash = joined.prefixHash
                windowTotal = joined.total
                turns = joined.turns
                scheduleCacheSave()
            } else {
                let outcome = try await TranscriptSync.fetch(client: client, id: id, held: nil, overlap: 0)
                guard conversationID == id, turnsOffset == before.offset else { return }
                adoptWindow(outcome, allowShrink: true)
            }
        } catch {
            // Scrolling up again tries again; the held turns stay.
        }
    }

    /// A message is still being handed to the server: a prompt resolving its
    /// connection, attaching or being sent, or a message into the turn not yet
    /// confirmed. Suspension waits for it (`SessionModelStore`).
    var isHandingOffSend: Bool {
        sendsInProgress > 0 || insertedNotes.contains { !$0.resolved }
    }

    /// No screen shows this session any more (`SessionModelStore`): close
    /// its sockets, as leaving the screen always did. The model, its turns
    /// and its draft stay, so opening it again is instant.
    func suspend() {
        guard !isSuspended else { return }
        teardown()
        isSuspended = true
    }

    /// The session is on screen again after `suspend()`: reconnect a turn
    /// that was streaming in place, or fetch what changed and reattach if a
    /// turn started meanwhile.
    func resume() async {
        guard isSuspended else { return }
        isSuspended = false
        guard phase == .loaded else { return }
        await refreshOnForeground()
    }

    /// Populate the draft's folder/agent lists and pick sensible defaults
    /// (preselected folder → most-recent folder; its default agent → first
    /// installed). Failures leave the full `AgentType` fallback in place.
    private func loadDraftOptions(preselectedFolderID: Int?) async {
        // The picker lists top-level open folders only (a new session shouldn't
        // target a worktree directly). The full set resolves a preselected folder
        // that the picker omits — e.g. a worktree the branch switcher just opened a
        // draft in.
        async let openReq = client.listOpenFolders()
        async let allReq = client.listFolders()

        // Narrow agents to what the server actually has installed + enabled.
        if let agents = try? await client.listAgents() {
            let usable = agents.filter { $0.available && $0.enabled }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.agentType)
            var deduped: [AgentType] = []
            for agent in usable where !deduped.contains(agent) { deduped.append(agent) }
            if !deduped.isEmpty { availableAgents = deduped }
        }

        let open = (try? await openReq) ?? []
        let all = (try? await allReq) ?? []
        allFolders = all
        availableFolders = FolderVisibility.filterTopLevel(open)
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        if folder == nil {
            folder = all.first { $0.id == preselectedFolderID } ?? availableFolders.first
        }
        currentBranch = folder?.gitBranch
        if selectedAgent == nil {
            if let preferred = folder?.defaultAgentType, availableAgents.contains(preferred) {
                selectedAgent = preferred
            } else {
                selectedAgent = availableAgents.first
            }
        }
        if let agent = selectedAgent { insertModel.agentType = agent }
    }

    // MARK: - Draft selection (new session only)

    /// Change the draft's agent before the first send. A different agent needs a
    /// different connection, so any one resolved by the options sheet is dropped.
    func selectAgent(_ agent: AgentType) {
        guard isDraftEditable, agent != selectedAgent else { return }
        selectedAgent = agent
        insertModel.agentType = agent
        resetDraftConnection()
    }

    /// Change the draft's folder before the first send. The folder is the agent's
    /// working dir, so a change likewise invalidates any resolved connection.
    func selectFolder(_ newFolder: FolderDetail) {
        guard isDraftEditable, newFolder.id != folder?.id else { return }
        folder = newFolder
        currentBranch = newFolder.gitBranch
        resetDraftConnection()
    }

    /// Drop a connection the options sheet resolved before any send, so the next
    /// option-apply / first prompt re-resolves against the new agent/folder.
    private func resetDraftConnection() {
        connectionID = nil
        agentOptions.teardown()
    }

    // MARK: - Git branch (selector)

    /// List the folder's branches for the branch selector. Returns nil when there
    /// is no folder path (no git context) or the call fails (surfaced via notice).
    /// Also refreshes the current-branch label opportunistically.
    func loadBranches() async -> GitBranchList? {
        guard let path = folder?.path else { return nil }
        do {
            let list = try await client.gitListAllBranches(path: path)
            if let cur = try? await client.gitCurrentBranch(path: path), !cur.isEmpty {
                currentBranch = cur
            }
            return list
        } catch {
            notice = Self.describe(error)
            return nil
        }
    }

    /// The folder name to show in the branch/workspace surface: the ROOT repo's
    /// name when this conversation lives in a worktree (git ops still target the
    /// worktree's own `path`), else the folder's own name. Mirrors the web's
    /// `resolveFolderDisplayName`.
    var displayFolderName: String? {
        guard let folder else { return nil }
        return FolderVisibility.displayName(of: folder, in: allFolders)
    }

    /// Switch to `branch`, worktree-aware (web parity, `planBranchSwitch`):
    /// - the branch isn't checked out anywhere (or it's a remote pick) → `git
    ///   checkout` in the repo root (in place when we're already in the root);
    /// - it lives in another (registered or unregistered) worktree → open a NEW
    ///   draft session in that folder rather than mutating this conversation.
    ///
    /// Returns the navigation intent for the caller (the view performs the actual
    /// navigation since the view model has no nav handle). Surfaces failures via
    /// `notice`.
    func switchBranch(_ branch: String, isRemote: Bool) async -> BranchSwitchOutcome {
        guard let active = folder else { return .failed }
        if branch == currentBranch { return .noop }

        // Find where the branch is checked out (skip for a remote pick — those
        // always check out fresh in the root).
        let resolution: WorktreeResolution? = isRemote
            ? nil
            : try? await client.resolveWorktreeFolder(repoPath: active.path, branch: branch)
        let plan = FolderVisibility.planBranchSwitch(
            active: active, resolution: resolution, allFolders: allFolders, isRemote: isRemote
        )

        switch plan {
        case .noop:
            return .noop

        case .navigateRegistered(let folderId):
            // Already a registered folder — make sure it's open, then navigate.
            if let target = allFolders.first(where: { $0.id == folderId }) {
                _ = try? await client.openFolder(path: target.path)
            }
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: folderId)

        case .navigateExternal(let path, let rootId):
            // Worktree dir not registered yet — register it (parented to the root),
            // then navigate into it.
            guard let detail = try? await client.openWorktreeFolder(path: path, sourceFolderId: rootId) else {
                notice = "Couldn’t open the worktree folder."
                return .failed
            }
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: detail.id)

        case .checkoutInRoot(let root):
            do {
                try await client.gitCheckout(path: root.path, branchName: branch)
            } catch {
                // A plain `git checkout` is refused by git when the branch is
                // already checked out in another worktree ("fatal: '<b>' is already
                // used by worktree at '<path>'"). We only land here when resolution
                // was skipped (a remote pick) or was unavailable, so the branch was
                // never routed to its worktree. Recover the way the web's resolve
                // step would have — locate that worktree and open a session in it —
                // instead of surfacing a dead-end checkout failure. A genuine
                // failure (e.g. a dirty working tree) yields nil and is surfaced.
                if let outcome = await recoverFromWorktreeCheckout(branch: branch, root: root, error: error) {
                    return outcome
                }
                notice = Self.describe(error)
                return .failed
            }
            if root.id == active.id {
                // In place — reflect the ACTUAL resulting HEAD (a remote ref like
                // `origin/x` lands on local `x`).
                if let actual = try? await client.gitCurrentBranch(path: root.path), !actual.isEmpty {
                    currentBranch = actual
                } else {
                    currentBranch = branch
                }
                return .switchedInPlace
            }
            // We were inside a worktree; the checkout happened in the root → open a
            // session there so the user lands on the branch they picked.
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: root.id)
        }
    }

    /// Recover from a `git checkout` that git refused because `branch` is already
    /// checked out in a worktree. Locates that worktree and returns a navigation
    /// intent into it, mirroring what the web's resolve step does up front. Returns
    /// nil when the failure was something else (e.g. a dirty tree) so the caller
    /// surfaces the real error.
    private func recoverFromWorktreeCheckout(branch: String, root: FolderDetail, error: Error) async -> BranchSwitchOutcome? {
        // Preferred: ask the server where the branch lives. This works no matter how
        // we got here — notably a remote ref whose local branch sits in a worktree,
        // where the up-front resolution was deliberately skipped.
        if let resolution = try? await client.resolveWorktreeFolder(repoPath: root.path, branch: branch),
           let path = resolution.path {
            return await openWorktreeSession(path: path, folderId: resolution.folderId, root: root)
        }
        // Fallback for servers without `resolve_worktree_folder`: git names the
        // occupying worktree in its error ("… already used by worktree at '<path>'").
        if let path = Self.worktreePath(fromCheckoutError: Self.describe(error)) {
            return await openWorktreeSession(path: path, folderId: nil, root: root)
        }
        return nil
    }

    /// Open (registering if needed) the folder backing the worktree at `path` and
    /// return the intent to start a session there. `folderId` is the already-known
    /// registered folder, if resolution provided one.
    private func openWorktreeSession(path: String, folderId: Int?, root: FolderDetail) async -> BranchSwitchOutcome? {
        if let folderId, let target = allFolders.first(where: { $0.id == folderId }) {
            _ = try? await client.openFolder(path: target.path)
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: folderId)
        }
        guard let detail = try? await client.openWorktreeFolder(path: path, sourceFolderId: root.id) else {
            return nil
        }
        NotificationCenter.default.post(name: .foldersDidChange, object: nil)
        return .openSession(folderId: detail.id)
    }

    /// Extract the worktree path from git's "already used by worktree at '<path>'"
    /// checkout error, or nil when the message isn't that collision (so a genuine
    /// failure like a dirty tree isn't mistaken for one).
    static func worktreePath(fromCheckoutError message: String) -> String? {
        guard message.contains("already used by worktree") else { return nil }
        guard let start = message.range(of: "at '")?.upperBound,
              let end = message[start...].firstIndex(of: "'") else { return nil }
        let path = String(message[start..<end])
        return path.isEmpty ? nil : path
    }

    /// Create `branch` (off `startPoint`; nil = current HEAD) and check it out.
    func createBranch(_ branch: String, from startPoint: String?) async -> Bool {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = folder?.path, !name.isEmpty else { return false }
        do {
            try await client.gitNewBranch(path: path, branchName: name, startPoint: startPoint)
            currentBranch = name
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    // MARK: - Attachments

    /// Append newly-prepared images, enforcing both a count cap and an aggregate
    /// byte budget (so the base64 prompt payload stays under the server's body
    /// limit), and surfacing a notice if any were dropped.
    func addAttachments(_ newAttachments: [Attachment]) {
        guard !newAttachments.isEmpty else { return }
        var currentBytes = attachments.reduce(0) { $0 + $1.byteCount }
        var droppedForCount = false
        var droppedForSize = false
        for attachment in newAttachments {
            if attachments.count >= AttachmentPrep.maxCount {
                droppedForCount = true
                break
            }
            if currentBytes + attachment.byteCount > AttachmentPrep.maxTotalBytes {
                droppedForSize = true
                continue
            }
            attachments.append(attachment)
            currentBytes += attachment.byteCount
        }
        if droppedForCount {
            notice = "You can attach up to \(AttachmentPrep.maxCount) images."
        } else if droppedForSize {
            notice = "Some images were too large to attach."
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.first { $0.id == id }?.upload?.cancel()
        attachments.removeAll { $0.id == id }
    }

    /// Attach a video or an audio file: it is fetched (from iCloud if it has
    /// to be), compressed when it needs to be and uploaded to codeg while the
    /// user writes; the message can go once it is uploaded. A video goes as
    /// the user last chose (``VideoQuality/preferred``).
    func addMedia(_ source: AttachmentSource) {
        guard attachments.count < AttachmentPrep.maxCount else {
            notice = "You can attach up to \(AttachmentPrep.maxCount) files."
            if case .file(let url) = source { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return
        }
        let name: String
        if case .file(let url) = source { name = url.lastPathComponent } else { name = "Video" }
        let upload = AttachmentUpload(source: source, displayName: name, uploader: uploader, bucket: uploadBucket,
                                      preparer: videoPreparer, quality: VideoQuality.preferred)
        attachments.append(Attachment(upload: upload))
        upload.start()
    }

    /// Try a video or audio file that didn't upload again.
    func retryAttachment(_ id: UUID) {
        attachments.first { $0.id == id }?.upload?.start()
    }

    /// Send a video as it is or compressed, and do so for the next ones too.
    func setVideoQuality(_ quality: VideoQuality, for id: UUID) {
        VideoQuality.preferred = quality
        attachments.first { $0.id == id }?.upload?.setQuality(quality)
    }

    /// Every attachment can be sent (a video is uploaded).
    var attachmentsReady: Bool { attachments.allSatisfy(\.isReady) }

    /// Why the staged attachments can't be sent yet, nil when they can.
    private var attachmentsNotReadyNotice: String? {
        guard !attachmentsReady else { return nil }
        let waiting = attachments.compactMap(\.upload).filter { !$0.isDone }
        let failed = waiting.filter { $0.failure != nil }
        if !failed.isEmpty {
            return failed.contains { $0.kind == .video }
                ? "A video didn't upload. Tap it to try again, or remove it."
                : "An audio file didn't upload. Tap it to try again, or remove it."
        }
        return waiting.contains { $0.kind == .video }
            ? "Wait for the video to finish uploading."
            : "Wait for the audio file to finish uploading."
    }

    /// Where `upload_attachment` keeps this session's files: the bucket codeg
    /// web uses for the conversation's tab (`conv-<folder>-<agent>-<id>`).
    var uploadBucket: String {
        let agent = summary?.agentType ?? selectedAgent
        if let folderID = summary?.folderId ?? folder?.id, let agent, let conversationID {
            return "conv-\(folderID)-\(agent.wireValue)-\(conversationID)"
        }
        return "ios-\(uploadSessionID.uuidString.lowercased())"
    }

    // MARK: - Send

    /// Send the composer's draft — or, with `overrideText`, a prompt the app itself
    /// generated (today: the revision notes from a plan-approval "request changes",
    /// which Grok expects as a follow-up turn). An override never touches the
    /// composer's draft or attachments, so a message the user was typing survives;
    /// a rejected send still restores the text into the composer so it isn't lost.
    func send(overrideText: String? = nil) {
        if let overrideText {
            startSend(text: overrideText, attachments: [], fromComposer: false)
        } else {
            startSend(text: draft, attachments: attachments, fromComposer: true)
        }
    }

    /// Start a turn with `rawText` + `sending`. `fromComposer` clears the
    /// composer once the optimistic turn is posted. A message from the queue
    /// keeps its `clientMessageID` and its last `failure`. Returns whether the
    /// send started; a caller holding the message keeps it when it did not.
    @discardableResult
    private func startSend(text rawText: String, attachments sending: [Attachment], fromComposer: Bool,
                           clientMessageID: String? = nil, failure previous: SendFailure? = nil) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !sending.isEmpty), !isInFlight else { return false }
        guard sending.allSatisfy(\.isReady) else {
            notice = attachmentsNotReadyNotice ?? "Wait for the video to finish uploading."
            return false
        }
        // Identity comes from the loaded summary (existing conversation) or the
        // new-task request; without either the screen isn't ready to send.
        guard summary != nil || newRequest != nil else { return false }
        // A draft (no linked summary yet) needs a folder + agent before it can
        // connect; lock the pickers the moment its first send begins.
        if summary == nil {
            guard folder != nil, selectedAgent != nil else {
                notice = "Pick a folder and agent first."
                return false
            }
            hasStartedFirstSend = true
        }

        // If the previous reply finished streaming but never reconciled into the
        // transcript (slow server persistence, or refreshAfterTurn still retrying),
        // fold it into `turns` before we reuse the `liveTurn` slot — otherwise this
        // send would drop that reply from view until the next reconcile.
        if let prior = liveTurn, !prior.isStreaming, !prior.isEmpty {
            promoteUnreconciled(prior)
        }

        // 1) Optimistic user turn (text first, then images) + clear the composer.
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: sending.map { $0.optimisticBlock })
        let userTurn = MessageTurn(
            id: "pending-\(UUID().uuidString)",
            role: .user,
            blocks: blocks,
            timestamp: Date()
        )
        pendingUserTurns.append(userTurn)
        if fromComposer {
            draft = ""
            attachments = []
        }

        // 2) Live assistant placeholder.
        let live = LiveTurn()
        liveTurn = live
        // A locally-sent turn: the reply streams into this placeholder and the
        // prompt lives in `pendingUserTurns`, so `turns` carries no persisted
        // in-flight reply to suppress. Clearing here is also the single point that
        // un-sticks a stale reattach flag once the user sends again.
        liveTurnFromReattach = false
        liveCopyIncomplete = false
        sendState = .connecting
        attachPhase = nil
        awaitingBackground = false
        backgroundOutstanding = 0
        retireSettledNotes()
        turnSerial &+= 1
        notice = nil
        echoedUserMessageIDs = []
        // This send attaches its own stream; a cold reattach still waiting to
        // retry would only be superseded by it.
        reattachRetryTask?.cancel()
        reattachRetryTask = nil
        // The user's own send always re-pins, even if they'd scrolled up.
        requestStickToBottom()

        // 3) Run the network + streaming flow.
        sendTask?.cancel()
        let userTurnID = userTurn.id
        let clientMessageID = clientMessageID ?? Self.newClientMessageID()
        // On its way: stored until the server answers, so an app that is
        // killed, or a screen closed, before then gives it back (and sends it
        // again under this id). Before the task, which a closing screen can
        // cancel before it ever runs.
        trackInFlight(clientMessageID: clientMessageID, text: text, attachments: sending)
        sendTask = Task { [weak self] in
            await self?.runSend(text: text, attachments: sending, live: live, userTurnID: userTurnID,
                                clientMessageID: clientMessageID, previous: previous)
        }
        return true
    }

    /// A new client message id (see ``QueuedMessage/clientMessageID``).
    nonisolated static func newClientMessageID() -> String { "ios-" + UUID().uuidString }

    private func runSend(text: String, attachments sending: [Attachment], live: LiveTurn, userTurnID: String,
                         clientMessageID: String, previous: SendFailure?) async {
        sendsInProgress += 1
        defer { sendsInProgress -= 1 }
        do {
            // For a brand-new draft, create the conversation row server-side BEFORE
            // prompting so every client (desktop / web) sees it immediately. No-op
            // for an existing or already-created conversation.
            try await ensureConversationCreated(firstPromptText: text)

            // Resolve a connection (reuse → existing live conn → fresh spawn).
            let conn = try await resolveConnection()
            connectionID = conn

            let duplicate = try await attachAndPrompt(conn: conn, text: text, attachments: sending, live: live,
                                                      clientMessageID: clientMessageID)
            settleInFlight(clientMessageID)
            if duplicate { showAlreadyDelivered(userTurnID: userTurnID, live: live) }
        } catch let error as APIError where error.isStaleConnection {
            // Stale connection → drop it and retry once with a fresh spawn.
            connectionID = nil
            await retrySendOnce(text: text, attachments: sending, live: live, clientMessageID: clientMessageID,
                                userTurnID: userTurnID, previous: previous)
        } catch APIError.turnInProgress {
            parkBehindRunningTurn(userTurnID: userTurnID, live: live, text: text, attachments: sending,
                                  clientMessageID: clientMessageID)
        } catch is CancellationError {
            // Cancelled by the user (`cancel()` settles it) or by the screen going
            // away: then it stays stored as on its way, and comes back at the
            // front of the queue when the session opens again.
        } catch {
            // The prompt was never accepted as far as this screen knows (resolve
            // or the prompt itself threw, and the server could not confirm it;
            // a socket that won't attach no longer fails a send). Roll back the
            // optimistic turn and keep the message: at the queue's front, marked
            // "Not sent", to go again under the same id.
            keepUnsent(userTurnID: userTurnID, live: live, text: text, attachments: sending,
                       clientMessageID: clientMessageID, error: error, previous: previous)
        }
    }

    private func retrySendOnce(text: String, attachments sending: [Attachment], live: LiveTurn, clientMessageID: String,
                               userTurnID: String, previous: SendFailure?) async {
        do {
            closeStream()
            let prefs = preferredSelectors
            let conn = try await client.connect(
                agentType: agentTypeForUI,
                workingDir: folder?.path,
                sessionId: summary?.externalId,
                preferredModeId: prefs.modeId,
                preferredConfigValues: prefs.configValues
            )
            connectionID = conn
            let duplicate = try await attachAndPrompt(conn: conn, text: text, attachments: sending, live: live,
                                                      clientMessageID: clientMessageID)
            settleInFlight(clientMessageID)
            if duplicate { showAlreadyDelivered(userTurnID: userTurnID, live: live) }
        } catch is CancellationError {
            // Stays stored as on its way (see `runSend`).
        } catch APIError.turnInProgress {
            parkBehindRunningTurn(userTurnID: userTurnID, live: live, text: text, attachments: sending,
                                  clientMessageID: clientMessageID)
        } catch {
            keepUnsent(userTurnID: userTurnID, live: live, text: text, attachments: sending,
                       clientMessageID: clientMessageID, error: error, previous: previous)
        }
    }

    /// A send that did not go through: back out of the conversation, into the
    /// queue's front as "Not sent" (it was sent before anything queued since),
    /// never into the message bar — where the user may already be writing the
    /// next one. Reachability failures go again by themselves.
    private func keepUnsent(userTurnID: String, live: LiveTurn, text: String, attachments sending: [Attachment],
                            clientMessageID: String, error: Error, previous: SendFailure?) {
        discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text,
                              restoringAttachments: sending, restoreToComposer: false,
                              keepCreatedConversation: true)
        let failure = SendFailure.next(after: error, previous: previous)
        queuedMessages.insert(QueuedMessage(id: UUID(), text: text, attachments: sending, holdUntilTurnEnd: false,
                                            clientMessageID: clientMessageID, failure: failure), at: 0)
        settleInFlight(clientMessageID)
        notice = failure.autoRetry ? nil : "Not sent: \(Self.describe(error))"
        scheduleUnsentResend()
    }

    /// The server had this message already, from an earlier attempt whose
    /// answer was lost: nothing new runs. Drop this attempt's placeholder and
    /// show the session as the server has it.
    private func showAlreadyDelivered(userTurnID: String, live: LiveTurn) {
        discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: "", restoringAttachments: [],
                              restoreToComposer: false, keepCreatedConversation: true)
        Task { [weak self] in
            await Task.yield()
            await self?.refreshOnForeground()
        }
    }

    /// Attach the event stream, then fire the prompt. Only the prompt can fail
    /// the send: a socket that drops before its attach is confirmed is opened
    /// again, and when it still won't attach the prompt goes anyway and the
    /// stream is recovered once the turn runs. The reconnect's snapshot carries
    /// everything the agent streamed in the meantime.
    @discardableResult
    private func attachAndPrompt(conn: String, text: String, attachments sending: [Attachment],
                                 live: LiveTurn, clientMessageID: String) async throws -> Bool {
        let attached = try await openStream(connectionID: conn, live: live)
        try Task.checkCancellation()

        isTurnActive = true
        if case .connecting = sendState { sendState = .thinking }

        // Fire the prompt; the reply arrives over the stream. Once this
        // returns, the server has accepted the turn — past this point a
        // failure is a *stream* failure (handled by the consumer loop), not a
        // send failure, so the optimistic turn must stay on screen.
        promptInFlight = true
        defer { promptInFlight = false }
        let duplicate = try await sendPromptConfirmed(conn: conn, text: text, attachments: sending,
                                                      clientMessageID: clientMessageID)
        // Prompt accepted — the created conversation is now legitimately in use,
        // so it must not be rolled back by a later stream failure.
        draftCreatedConversationID = nil
        if duplicate { return true }
        attachPhase = nil
        refreshSteeringAvailability(connectionID: conn)
        if !attached || streamLostBeforeTurn {
            streamLostBeforeTurn = false
            reconnectStream(into: live, connectionID: conn, reason: nil)
        }
        return false
    }

    /// `acp_prompt`, where an unclear failure is checked against the server
    /// before it fails the send: a lost response (LTE), a timeout or a 5xx can
    /// come back for a prompt the server took, and a retried request is told
    /// a turn is already running — its own. The prompt counts as sent when the
    /// stream echoed its client message id or the connection's snapshot shows
    /// it as the running turn's prompt. Otherwise the error stands.
    @discardableResult
    private func sendPromptConfirmed(conn: String, text: String, attachments sending: [Attachment],
                                     clientMessageID: String) async throws -> Bool {
        do {
            return try await sendPrompt(conn: conn, text: text, attachments: sending, clientMessageID: clientMessageID)
        } catch let error as APIError {
            let unclear: Bool
            if case .turnInProgress = error { unclear = true } else { unclear = error.isTransient }
            guard unclear else { throw error }
            let checks: Int
            if case .turnInProgress = error { checks = 1 } else { checks = 3 }
            let accepted = await promptWasAccepted(conn: conn, clientMessageID: clientMessageID, checks: checks)
            if !accepted { throw error }
            return false
        }
    }

    /// Whether the server took the prompt sent with `clientMessageID`. A server
    /// that can't be reached now can't confirm anything, so the first failed
    /// check ends the questions.
    private func promptWasAccepted(conn: String, clientMessageID: String, checks: Int) async -> Bool {
        for check in 0..<max(1, checks) {
            if echoedUserMessageIDs.contains(clientMessageID) { return true }
            let snap: LiveSessionSnapshot?
            do { snap = try await client.liveSessionSnapshot(connectionId: conn) } catch { break }
            if echoedUserMessageIDs.contains(clientMessageID)
                || SendConfirmation.promptIsRunning(clientMessageID: clientMessageID, in: snap) {
                return true
            }
            if check < checks - 1 { try? await Task.sleep(for: .milliseconds(700)) }
        }
        return echoedUserMessageIDs.contains(clientMessageID)
    }

    /// The server is running a turn this screen didn't know about: one started
    /// from another client, or one it lost track of while its socket was down.
    /// Keep the message instead of handing it back: queue it at the front, and
    /// attach to that turn so the message goes when the turn ends (or at once,
    /// when the turn is only held open for background work).
    private func parkBehindRunningTurn(userTurnID: String, live: LiveTurn, text: String, attachments sending: [Attachment],
                                       clientMessageID: String) {
        discardOptimisticSend(userTurnID: userTurnID, live: live, restoringDraft: text,
                              restoringAttachments: sending, restoreToComposer: false,
                              keepCreatedConversation: true)
        queuedMessages.insert(QueuedMessage(id: UUID(), text: text, attachments: sending,
                                            holdUntilTurnEnd: false, clientMessageID: clientMessageID), at: 0)
        settleInFlight(clientMessageID)
        notice = "A turn is already running on this session. Your message is queued and goes when it ends."
        Task { [weak self] in await self?.reattachIfLive(serverSaysLive: true) }
    }

    /// The user's last-used mode/config for the active agent, sent on every
    /// `connect` so a fresh session starts with their saved selections (mirrors
    /// the web client). Empty/nil values are omitted by the request encoder.
    private var preferredSelectors: SelectorPrefs {
        SelectorPrefsStore.prefs(for: agentTypeForUI)
    }

    private func resolveConnection() async throws -> String {
        if let existing = connectionID { return existing }
        // Only a linked conversation can have a server-side connection to find;
        // a new task always spawns fresh (no sessionId → a brand-new session).
        if let id = conversationID,
           let found = try await client.findConnection(
               conversationId: id,
               sessionId: summary?.externalId,
               agentType: agentTypeForUI
           )?.connectionId {
            return found
        }
        let prefs = preferredSelectors
        return try await client.connect(
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionId: summary?.externalId,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
    }

    /// Resolve a live chat connection for out-of-band actions — currently applying
    /// agent mode/config from the options sheet. Unlike the send path, this does
    /// NOT trust a cached `connectionID`: it validates liveness via `findConnection`
    /// (which returns the conversation's bound connection or nil) and only spawns a
    /// fresh one when none is live, so a mode/config change can't be sent to a
    /// connection the server has since garbage-collected. The result is cached so
    /// the next send reuses the same connection.
    func resolveConnectionForOptions() async throws -> String {
        if let id = conversationID,
           let found = try await client.findConnection(
               conversationId: id,
               sessionId: summary?.externalId,
               agentType: agentTypeForUI
           )?.connectionId {
            connectionID = found
            return found
        }
        let prefs = preferredSelectors
        let conn = try await client.connect(
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionId: summary?.externalId,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
        connectionID = conn
        return conn
    }

    /// Returns whether the server answered that it already had this message.
    private func sendPrompt(conn: String, text: String, attachments sending: [Attachment], clientMessageID: String) async throws -> Bool {
        // Text first, then images — matches the web client's block order.
        var blocks: [PromptInputBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: sending.map { $0.promptInputBlock })
        // A new task sends a nil conversationId + the target folderId; the
        // server creates the conversation and announces it via
        // `conversation_linked` on the stream.
        return try await client.prompt(
            connectionId: conn,
            blocks: blocks,
            folderId: summary?.folderId ?? folder?.id,
            conversationId: conversationID,
            clientMessageId: clientMessageID
        )
    }

    /// Create the server-side conversation row up front for a brand-new draft's
    /// first send (mirrors codeg web). This is what makes the new session visible
    /// to *other* clients immediately: `create_conversation` broadcasts a
    /// `conversation_upsert` to every connected client, whereas prompting with a
    /// nil `conversationId` creates the row implicitly and announces it only on
    /// this client's own stream — so the desktop never learns of it.
    ///
    /// No-op once a conversation exists (existing session, or a retry after the
    /// row was already created). On failure it throws into `runSend`'s `catch`,
    /// which rolls the optimistic send back.
    private func ensureConversationCreated(firstPromptText text: String) async throws {
        guard conversationID == nil, let folderId = folder?.id, let agent = selectedAgent else { return }
        let id = try await client.createConversation(
            folderId: folderId,
            agentType: agent,
            title: Self.draftTitle(from: text)
        )
        conversationID = id
        draftCreatedConversationID = id
        restoredOutboxFor = id
        persistOutbox()
        presenceReporter.update(conversationID: id, looking: isOnScreen)
        currentBranch = folder?.gitBranch
        // Refresh this app's own session list so the new row shows there too.
        notifyConversationsChanged()
        // Fetch identity (title / status / external id) in the background so the
        // nav-bar title + actions menu light up — without blocking the prompt's
        // first token on an extra round-trip.
        Task { [weak self] in
            guard let self,
                  let detail = try? await self.client.conversationDetail(id: id, window: .tail(1)),
                  self.conversationID == id else { return }
            self.summary = detail.summary
            self.sessionStats = detail.sessionStats ?? self.sessionStats
            self.insertModel.agentType = detail.summary.agentType
        }
    }

    /// A title for a freshly created conversation, derived from the first prompt
    /// (first non-empty line, capped to 80 chars) — mirrors the web client. nil →
    /// the server titles it later from the session.
    private static func draftTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(80))
    }

    // MARK: - Stream lifecycle

    /// Resolved by the consumer loop the moment the socket reports `.ready`, so
    /// `openStream` can return only after the stream is attached. Single-shot.
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Open the send's event stream: attach, and when the socket drops before
    /// the server confirms the attach, open a fresh one (see
    /// ``StreamHandshake``). Returns whether a stream is attached; `false` means
    /// the caller prompts without one and recovers the stream afterwards.
    /// Throws only `APIError.streamGone` (the connection is gone: retry with a
    /// fresh one) and cancellation.
    private func openStream(connectionID conn: String, live: LiveTurn) async throws -> Bool {
        streamReconnects = 0   // fresh send → fresh reconnect budget
        streamLostBeforeTurn = false
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await attachStream(connectionID: conn, live: live)
                return true
            } catch let failure as StreamHandshake.Failure {
                switch StreamHandshake.next(after: failure, attempt: attempt) {
                case .retry(let delay):
                    closeStream()
                    try await Task.sleep(for: delay)
                case .promptWithoutStream:
                    closeStream()
                    return false
                }
            }
        }
    }

    /// Opens a fresh event stream, spawns the single consumer loop, and suspends
    /// until that loop has seen `.ready` and the server confirmed the attach.
    /// There is exactly one iterator over `frames` — the consumer loop — so
    /// frames are never dropped.
    private func attachStream(connectionID conn: String, live: LiveTurn) async throws {
        closeStream()
        streamGeneration &+= 1
        let generation = streamGeneration
        let newStream = makeEventStream()
        stream = newStream
        newStream.start()

        consumerTask = Task { [weak self] in
            await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation)
        }

        // Safety net for a hung socket. A healthy server always answers `attach`
        // immediately — either a snapshot/replay frame (success) or a detached
        // frame (connection gone). Only this attempt's own timer may end it.
        let readyTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: StreamHandshake.attachTimeout) } catch { return }
            guard let self, self.streamGeneration == generation else { return }
            self.resumeReady(throwing: StreamHandshake.Failure.timedOut)
        }
        defer { readyTimeout.cancel() }

        // Wait for the consumer loop to signal readiness (resolved once the attach
        // is confirmed by the server's snapshot/replay frame).
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if readyContinuation != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readyContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeReady(throwing: CancellationError()) }
        }
    }

    /// The sole consumer of `stream.frames`. Attaches on `.ready`, maps `.event`
    /// frames onto the live turn, and finalizes on terminal frames. A superseded
    /// consumer (its `generation` no longer current) ignores its terminal frames
    /// so it can't end a turn that a newer stream now owns.
    private func consume(stream: any SessionEventStream, connectionID conn: String, live: LiveTurn, generation: Int) async {
        // The turn this consumer feeds. A mid-turn reconnect REPLACES it with the
        // turn rebuilt from the fresh attach snapshot (see `.snapshot` below), so
        // every frame after that point lands on the turn the transcript is showing
        // rather than on an orphaned placeholder.
        var live = live
        for await frame in stream.frames {
            if Task.isCancelled { return }
            let isCurrent = generation == streamGeneration
            switch frame {
            case .ready:
                // Send attach, but do NOT release openStream yet: wait for the
                // server to confirm the subscription (snapshot/replay) before the
                // prompt is fired. Otherwise acp_prompt (a separate HTTP request)
                // can reach the server before the WS attach is registered, and the
                // first streamed events would be delivered to no subscriber.
                stream.attach(subscriptionId: subscriptionID, connectionId: conn, sinceSeq: nil)
            case .snapshot(let snap):
                // Attach confirmed — a healthy socket. Reset the reconnect budget
                // and (for the initial connect) release the waiting send.
                streamReconnects = 0
                if isCurrent { applyLiveSignals(from: snap) }
                // A mid-turn RECONNECT can drop the socket exactly as a
                // `permission_request` / `question_request` arrives — losing that
                // live event. The fresh snapshot still carries the pending card, so
                // restore it; otherwise an ExitPlanMode / permission prompt is
                // silently lost across the reconnect and the reply "looks finished"
                // with no way to approve. Mirrors `consumeReattach` + the web client.
                // Skipped during the INITIAL attach handshake (readyContinuation set)
                // — that snapshot is the pre-prompt state and carries no live card.
                //
                // While the prompt is still on its way the snapshot can predate
                // it, so it says nothing about this turn: keep the turn as is.
                if isCurrent, readyContinuation == nil, isTurnActive, !promptInFlight {
                    switch snap.turnPhase {
                    case .running:
                        // The agent kept replying while the socket was down and those
                        // events reached no subscriber. The snapshot's `live_message` is
                        // the COMPLETE in-flight reply, so adopt it wholesale instead of
                        // keeping the turn that stopped at the drop — otherwise whatever
                        // was produced during the outage stays missing from the open
                        // screen until the user leaves and re-enters the session (the
                        // reply is there on re-entry, which is exactly the tell).
                        //
                        // Deliberately does NOT set `liveTurnFromReattach` — the one
                        // thing `consumeReattach` does that must not be copied here. That
                        // flag drops the persisted assistant turns trailing the last user
                        // prompt, and on the send path those are the PREVIOUS turn's
                        // finished reply: `turns` is never refetched mid-turn, so it
                        // holds no partial copy of THIS reply to double-render.
                        if let rebuilt = buildLiveTurn(from: snap) {
                            // The snapshot marks no messages sent into the turn:
                            // put this screen's back where they were.
                            rebuilt.adoptSteered(from: live) { Self.steered($0, belongsTo: snap) }
                            live = rebuilt
                            liveTurn = rebuilt
                            // Recovery parked the status line on "connecting"; the reply
                            // is streaming again, so say so (without stomping a tool run).
                            if case .running = sendState {} else { sendState = .thinking }
                            // Follow the new content only for a reader who is still
                            // pinned — a socket blip must not yank someone who scrolled
                            // up, unlike a fresh open or the user's own send.
                            requestScrollToBottom()
                        }
                        restorePending(from: snap)
                    case .starting:
                        // The agent is taking the prompt; its events follow on this socket.
                        break
                    case .ended, .connectionDown:
                        // The turn ended while the socket was down, so its
                        // `turn_complete` never reached this screen. Without this the
                        // reply stays "working" for good and the queue never moves.
                        settleIfTurnEnded(live: live, connectionID: conn, reading: snap.turnPhase)
                    }
                }
                if isCurrent { resumeReady(throwing: nil) }
            case .replay:
                streamReconnects = 0
                if isCurrent { resumeReady(throwing: nil) }
            case .pong:
                break
            case .frameCut:
                if isCurrent { noteCutFrame() }
            case .event(let envelope):
                if isCurrent { handle(event: envelope.event, live: live) }
            case .detached(let reason):
                guard isCurrent else { return }
                // During the attach handshake (before the prompt is accepted), a
                // gone connection makes `runSend` retry with a fresh one; any other
                // detach is a passing one and the handshake opens a fresh socket.
                if readyContinuation != nil {
                    if reason == "connection_gone" {
                        resumeReady(throwing: APIError.streamGone)
                    } else {
                        resumeReady(throwing: StreamHandshake.Failure.dropped(reason: reason))
                    }
                    return
                }
                // Mid-turn detach. `connection_gone` is terminal (the connection
                // was GC'd) — reconcile rather than blindly error, since the turn
                // may have finished. `lagged` / `server_shutdown` are transient:
                // re-attach silently, matching the web client.
                guard isTurnActive else {
                    // Attached, but the send hasn't marked its turn active yet:
                    // it recovers the stream once the prompt is accepted.
                    if reason != "connection_gone" { streamLostBeforeTurn = true }
                    return
                }
                if reason == "connection_gone" {
                    // Bind before the closure: `live` is a `var` now (a reconnect can
                    // adopt the snapshot's turn) and a `Task` may only capture an
                    // immutable local. `consumeReattach` gets this for free from its
                    // `guard let live`.
                    let current = live
                    Task { [weak self] in await self?.reconcileOrFail(live: current, reason: reason) }
                } else {
                    reconnectStream(into: live, connectionID: conn, reason: reason)
                }
                return
            case .closed(let reason):
                guard isCurrent else { return }
                // Socket dropped during the attach handshake (a frame too large for
                // it, a lost connection): nothing streamed yet, so the handshake
                // opens a fresh socket. It never fails the send.
                if readyContinuation != nil {
                    resumeReady(throwing: StreamHandshake.Failure.dropped(reason: reason))
                    return
                }
                // Past the handshake a turn is streaming. The ACP connection
                // outlives the WebSocket, so a dropped socket is a transport blip:
                // re-attach silently instead of erroring (web parity).
                if isTurnActive {
                    reconnectStream(into: live, connectionID: conn, reason: reason)
                } else {
                    // Attached, but the send hasn't marked its turn active yet:
                    // it recovers the stream once the prompt is accepted.
                    streamLostBeforeTurn = true
                }
                return
            }
        }
    }

    /// Resolve the pending `openStream` suspension exactly once.
    private func resumeReady(throwing error: Error?) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    // MARK: - Reattach (open a session whose turn is already in-flight)

    /// After loading an existing conversation, attach to its live connection — if
    /// one exists and a turn is in-flight (or a card is pending) — so the reply
    /// streams and any pending permission/question surfaces, all WITHOUT sending.
    /// This is the cross-client / app-relaunch path: a turn started in codeg web
    /// (or left blocked) becomes interactive on open. Idle connections are dropped.
    ///
    /// Additive: it does not touch the send flow. The moment the user sends,
    /// `openStream` supersedes this stream (a generation bump ends this consumer).
    func reattachIfLive(serverSaysLive: Bool = false) async {
        // A load that finished after the screen went away opens nothing:
        // `resume()` reattaches when the session is shown again.
        guard let id = conversationID, summary != nil, !isSuspended else { return }
        // Nothing to do if we're already streaming locally, or for a finished session.
        guard liveTurn == nil, !isInFlight, stream == nil else { return }
        if summary?.status == .completed || summary?.status == .cancelled { return }

        // Discover the live ACP connection. When the server reported a turn in
        // flight (`serverSaysLive`), a single discovery miss is almost always a
        // transient blip or a bind-lag race (the connection links to the
        // conversation a beat after the prompt) rather than a finished turn — so
        // retry a few times with a short backoff before giving up. Without that, a
        // lone miss leaves the user on a static transcript for the screen's
        // lifetime (the web never misses because it tracks connections
        // continuously; this is the poll-era stand-in). When the server does NOT
        // claim a live turn, one best-effort probe is enough.
        let attempts = serverSaysLive ? 4 : 1
        var conn: String?
        for attempt in 0..<attempts {
            // Bail if a send (or another reattach) started while we awaited.
            guard liveTurn == nil, !isInFlight, stream == nil else { return }
            if let found = try? await client.findConnection(
                conversationId: id,
                sessionId: summary?.externalId,
                agentType: agentTypeForUI
            )?.connectionId {
                conn = found
                break
            }
            // Back off before the next attempt (no sleep after the last one).
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }

        guard let conn else {
            // The server claimed a live turn but no connection ever surfaced — it
            // most likely finished during load, leaving our fetched transcript a
            // beat stale. Reconcile once so the final reply isn't missing.
            if serverSaysLive { await reconcileAfterMissedLive() }
            return
        }

        // Re-check: a send may have started (or the screen gone) while we awaited.
        guard liveTurn == nil, !isInFlight, stream == nil, !isSuspended else { return }

        connectionID = conn
        closeStream()
        streamGeneration &+= 1
        let generation = streamGeneration
        let newStream = makeEventStream()
        stream = newStream
        newStream.start()
        consumerTask = Task { [weak self] in
            await self?.consumeReattach(stream: newStream, connectionID: conn, generation: generation, serverSaysLive: serverSaysLive)
        }
    }

    /// The server reported a live turn at load but we couldn't attach to it (it
    /// finished in the gap, or the connection was momentarily undiscoverable).
    /// Quietly refetch the detail so the transcript shows the final reply rather
    /// than the snapshot we loaded a beat too early. No-op if a turn has since
    /// started locally — that path owns the transcript.
    private func reconcileAfterMissedLive() async {
        guard let id = conversationID, liveTurn == nil, !isInFlight, stream == nil else { return }
        guard let outcome = try? await fetchTranscript(id: id, overlap: TranscriptSync.liveOverlap) else { return }
        guard liveTurn == nil, !isInFlight, stream == nil else { return }
        summary = outcome.detail.summary
        adoptWindow(outcome, allowShrink: true)
        sessionStats = outcome.detail.sessionStats ?? sessionStats
        // A background refresh: it follows the latest message only for a
        // reader already there, never pulls one who scrolled up.
        requestScrollToBottom()
    }

    /// A frame the server shrank to fit this socket just arrived (only an older
    /// server, or one that did not hear this app's frame limit, does that): the
    /// live copy it fed is incomplete. Stop letting it stand in for the
    /// persisted reply, and reload the transcript — at most every 5 s, and
    /// never to fewer turns than are shown.
    private func noteCutFrame() {
        liveCopyIncomplete = true
        if let at = cutReloadAt, Date().timeIntervalSince(at) < 5 { return }
        cutReloadAt = Date()
        guard let id = conversationID else { return }
        Task { [weak self] in
            guard let self,
                  let outcome = try? await self.fetchTranscript(id: id, overlap: TranscriptSync.liveOverlap)
            else { return }
            self.adoptWindow(outcome, allowShrink: false)
            self.sessionStats = outcome.detail.sessionStats ?? self.sessionStats
        }
    }

    /// Consumer for the reattach stream. Unlike `consume`, it has no `openStream`
    /// continuation to release and it BUILDS the live turn from the attach snapshot
    /// rather than being handed one. If the snapshot shows nothing in flight, it
    /// closes the stream (idle connection — leave it alone).
    private func consumeReattach(stream: any SessionEventStream, connectionID conn: String, generation: Int, serverSaysLive: Bool = false) async {
        var live: LiveTurn?
        for await frame in stream.frames {
            if Task.isCancelled { return }
            // A send (or another reattach) superseded us — let go; the new stream owns the turn.
            guard generation == streamGeneration else { return }
            switch frame {
            case .ready:
                stream.attach(subscriptionId: subscriptionID, connectionId: conn, sinceSeq: nil)
            case .snapshot(let snap):
                // A snapshot means the socket is healthy — reset the reconnect budget.
                streamReconnects = 0
                reattachDrops = 0
                // A reconnect of a turn this screen already shows, as opposed to
                // the cold attach that opened the session.
                let resuming = isTurnActive && liveTurn != nil
                applyLiveSignals(from: snap)
                if let rebuilt = buildLiveTurn(from: snap) {
                    if resuming, let shown = liveTurn {
                        // The same turn again: the messages sent into it stay
                        // where they were (the snapshot marks none).
                        rebuilt.adoptSteered(from: shown) { Self.steered($0, belongsTo: snap) }
                    } else {
                        turnSerial &+= 1
                    }
                    live = rebuilt
                    liveTurn = rebuilt
                    // This live turn is the snapshot's in-flight reply; the
                    // transcript hides the partial copy the agent has begun
                    // persisting into `turns` so the reply isn't doubled — but
                    // only where this copy covers it (see `buildPersisted`).
                    liveTurnFromReattach = true
                    liveCopyIncomplete = false
                    isTurnActive = true
                    restorePending(from: snap)
                    sendState = .thinking
                    // A reattach or a reconnect: followed at the latest
                    // message, never a pull down for a reader scrolled up.
                    requestScrollToBottom()
                } else if resuming, let current = liveTurn {
                    // The turn on screen ended while the socket was down, so its
                    // `turn_complete` never arrived. Settle it rather than leave it
                    // "working" for good with the queue stuck behind it. Frames
                    // that still arrive feed it meanwhile.
                    live = current
                    settleIfTurnEnded(live: current, connectionID: conn, reading: snap.turnPhase)
                } else {
                    // Idle connection: nothing in flight. Release it.
                    closeStream()
                    connectionID = nil
                    // If the server had claimed a live turn at load, it finished
                    // between the detail fetch and this snapshot — reconcile so the
                    // final reply isn't missing from the (now stale) transcript.
                    if serverSaysLive { await reconcileAfterMissedLive() }
                    return
                }
            case .replay(let events):
                if let live { for env in events { handle(event: env.event, live: live) } }
            case .pong:
                break
            case .frameCut:
                noteCutFrame()
            case .event(let envelope):
                // The attach snapshot always precedes events, so `live` is set by now.
                if let live { handle(event: envelope.event, live: live) }
            case .detached(let reason):
                // Once a turn is live, recover transient detaches silently (web
                // parity); only `connection_gone` reconciles/fails. A reconnected
                // socket that drops before its snapshot still recovers the turn on
                // screen. With no turn on screen yet, the cold attach tries again.
                guard isTurnActive, let current = live ?? liveTurn else {
                    retryReattachAfterDrop(serverSaysLive: serverSaysLive)
                    return
                }
                if reason == "connection_gone" {
                    Task { [weak self] in await self?.reconcileOrFail(live: current, reason: reason) }
                } else {
                    reconnectStream(into: current, connectionID: conn, reason: reason, reattach: true)
                }
                return
            case .closed(let reason):
                // A socket drop while a turn is live is a transport blip — re-attach
                // silently, also when the drop hit a reconnected socket before its
                // snapshot. With no turn on screen yet, the cold attach tries again,
                // so a session whose turn runs on the server doesn't stay
                // unattached here.
                if isTurnActive, let current = live ?? liveTurn {
                    reconnectStream(into: current, connectionID: conn, reason: reason, reattach: true)
                } else {
                    retryReattachAfterDrop(serverSaysLive: serverSaysLive)
                }
                return
            }
        }
    }

    /// Whether a message sent into the turn on screen belongs to the turn a
    /// snapshot runs. The server keeps a turn's messages in its `feedback`
    /// until the next turn starts, so one it doesn't list was sent into an
    /// earlier turn. One whose note id never arrived is kept.
    static func steered(_ message: SteeredMessage, belongsTo snap: LiveSessionSnapshot) -> Bool {
        guard let serverID = message.serverID else { return true }
        return snap.feedback.contains { $0.id == serverID }
    }

    /// Rebuild an in-flight assistant turn from a reattach snapshot. Returns nil
    /// when no turn runs: the connection isn't prompting and no card waits. A
    /// `live_message` on an idle connection is out-of-turn output (the agent
    /// woke up for a background task after its turn ended), not a turn: reading
    /// it as one showed "Working" here while the session list, the server and
    /// the web client all said idle, and the reply never ended.
    private func buildLiveTurn(from snap: LiveSessionSnapshot) -> LiveTurn? {
        guard snap.isTurnInFlight else { return nil }
        let blocks = snap.liveMessage?.content ?? []

        let live = LiveTurn()
        let toolsById = Dictionary((snap.activeToolCalls ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for block in blocks {
            switch block {
            case .text(let t): live.appendText(t)
            case .thinking(let t): live.appendThinking(t)
            case .toolCallRef(let toolId):
                guard let st = toolsById[toolId] else { break }
                live.upsertToolCall(
                    id: st.id,
                    title: st.label,
                    kind: st.kind,
                    status: Self.normalizedToolStatus(st.status),
                    rawInput: st.inputPreview,
                    rawOutput: st.outputText,
                    content: st.content,
                    meta: st.meta,
                    images: st.images
                )
            case .plan(let entries):
                live.updatePlan(PlanEntry.list(from: entries))
            case .unknown:
                break
            }
        }
        live.flushAllText()
        return live
    }

    private func restorePending(from snap: LiveSessionSnapshot) {
        if let p = snap.pendingPermission {
            pendingPermission = PendingPermission(requestId: p.requestId, toolCall: p.toolCall, options: p.options)
        }
        if let q = snap.pendingQuestion {
            pendingQuestion = PendingQuestion(questionId: q.questionId, questions: q.questions)
        }
        // Set OR clear: the attach snapshot is the connection's authoritative
        // pending state, so an approval that another client resolved while we were
        // reconnecting must not leave a stale, still-actionable card behind
        // (answering it would post a decision for an approval that no longer
        // exists). The permission/question restores above deliberately keep their
        // existing set-only behavior — changing those is out of scope here.
        if let p = snap.pendingPlanApproval {
            pendingPlanApproval = PendingPlanApproval(
                approvalId: p.approvalId, toolCallId: p.toolCallId, planMarkdown: p.planMarkdown)
        } else {
            pendingPlanApproval = nil
        }
    }

    /// Normalize a snapshot `ToolCallStatus` (which may be PascalCase) to the
    /// lowercase form the live tool card interprets.
    private static func normalizedToolStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "inprogress", "in_progress", "in-progress", "running": return "in_progress"
        case "completed", "done", "success": return "completed"
        case "failed", "error": return "failed"
        case "pending": return "pending"
        default: return raw.lowercased()
        }
    }

    // MARK: - Event → UI mapping

    private func handle(event: AcpEvent, live: LiveTurn) {
        switch event {
        case .contentDelta(let text):
            live.appendText(text)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .thinking(let text):
            live.appendThinking(text)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .toolCall(let id, let title, let kind, let status, let content, let rawInput, let rawOutput, let meta, let images):
            live.upsertToolCall(id: id, title: title, kind: kind, status: status, rawInput: rawInput, rawOutput: rawOutput,
                                content: content, meta: meta, images: images)
            sendState = .running(tool: title.isEmpty ? "tool" : title)
            requestScrollToBottom()

        case .toolCallUpdate(let id, let title, let status, let content, let rawInput, let rawOutput, let append, let meta, let images):
            live.updateToolCall(id: id, title: title, status: status, rawInput: rawInput, rawOutput: rawOutput,
                                content: content, append: append, meta: meta, images: images)
            if let active = live.activeToolTitle {
                sendState = .running(tool: active)
            } else {
                sendState = .thinking
            }
            requestScrollToBottom()

        case .statusChanged(let status):
            switch status {
            case .connecting: if case .idle = sendState { sendState = .connecting }
            case .prompting: if case .running = sendState {} else { sendState = .thinking }
            case .error:
                failLive(live, message: "The agent connection errored.")
            default:
                break
            }

        case .usageUpdate(let used, let size):
            applyUsage(used: used, size: size)

        case .userMessage(let messageId, _):
            // The server echoes our own prompt; we already showed it optimistically.
            // The echo carries the client message id it was sent with, which
            // proves the prompt was accepted if its HTTP response goes missing.
            if !messageId.isEmpty { echoedUserMessageIDs.insert(messageId) }

        case .turnComplete(let stopReason):
            finalize(live: live, stopReason: stopReason)

        case .error(let message, let code):
            // An error about one action (a mode or option change, a goal
            // action, a dropped picture) leaves the turn running: the web
            // client shows it as a toast, and so does this screen.
            if let code, Self.actionErrorCodes.contains(code) {
                handleActionError(code: code, message: message)
            } else {
                failLive(live, message: message)
            }

        case .conversationLinked(let linkedID, _):
            adoptLinkedConversation(linkedID)

        case .permissionRequest(let requestId, let toolCall, let options):
            // The agent paused for approval (incl. ExitPlanMode). Surface the card
            // above the compose bar; the turn stays in-flight until it's resolved.
            pendingPermission = PendingPermission(requestId: requestId, toolCall: toolCall, options: options)
            requestScrollToBottom()

        case .permissionResolved(let requestId):
            // Resolved here or by another client — clear the matching card only, so
            // a stale echo can't wipe a freshly-raised one.
            if pendingPermission?.requestId == requestId { pendingPermission = nil }

        case .questionRequest(let questionId, let questions):
            pendingQuestion = PendingQuestion(questionId: questionId, questions: questions)
            requestScrollToBottom()

        case .questionResolved(let questionId):
            if pendingQuestion?.questionId == questionId { pendingQuestion = nil }

        case .planApprovalRequest(let approvalId, let toolCallId, let planMarkdown):
            // Grok finished planning and is blocked until the user decides.
            pendingPlanApproval = PendingPlanApproval(
                approvalId: approvalId, toolCallId: toolCallId, planMarkdown: planMarkdown)
            requestScrollToBottom()

        case .planApprovalResolved(let approvalId):
            if pendingPlanApproval?.approvalId == approvalId { pendingPlanApproval = nil }

        case .planUpdate(let entries):
            live.updatePlan(entries)
            requestScrollToBottom()

        case .attachProgress(let phase, _):
            attachPhase = (phase == "ready" || phase == "failed") ? nil : phase

        case .awaitingBackground(let awaiting, let nativeSteering):
            awaitingBackground = awaiting
            if nativeSteering { nativeSteeringAvailable = true }
            if awaiting { drainIntoHeldTurnIfPossible() }

        case .backgroundActivity(let outstanding):
            backgroundOutstanding = max(0, outstanding)

        case .feedbackSubmitted(let note):
            noteRecorded(note, live: live)

        case .feedbackConsumed(let ids):
            // The pull channel: the agent read these through its tool, as a
            // tool result rather than a message, so they stay above the
            // composer (as on the desktop), marked read.
            for idx in insertedNotes.indices where insertedNotes[idx].serverID.map({ ids.contains($0) }) == true {
                insertedNotes[idx].delivered = true
            }

        // The agent's mode and options, as changed by the agent (leaving plan
        // mode) or by any client, this one included: the options sheet follows.
        case .modeChanged(let modeId):
            agentOptions.applyLiveMode(modeId)

        case .sessionModes(let modes):
            agentOptions.applyLiveModes(modes)

        case .sessionConfigOptions(let options):
            agentOptions.applyLiveConfigOptions(options)

        case .configOptionRejected(let configId, let optionName, let requested, let actual, let actualValue):
            agentOptions.applyRejection(configId: configId, optionName: optionName, requested: requested,
                                        actual: actual, actualValue: actualValue)

        case .forkSupported(let supported):
            ForkCapabilities.shared.note(agent: agentTypeForUI, forks: supported, client: client)

        case .sessionStarted, .conversationStatusChanged, .userPromptSent, .unknown:
            break
        }
    }

    /// Error codes that report one action going wrong while the turn goes on
    /// (codeg web `routeAcpError`, kind `action`).
    static let actionErrorCodes: Set<String> = [
        "set_mode_failed", "set_config_option_failed", "grok_model_switch_incompatible_agent",
        "goal_control_failed", "image_dropped",
    ]

    private func handleActionError(code: String, message: String) {
        switch code {
        case "set_mode_failed":
            agentOptions.applyServerFailure(isModeChange: true, message: message)
        case "set_config_option_failed":
            agentOptions.applyServerFailure(isModeChange: false, message: message)
        default:
            notice = message
        }
    }

    /// Adopt the connection-level signals an attach snapshot carries.
    private func applyLiveSignals(from snap: LiveSessionSnapshot) {
        agentOptions.applyLiveSnapshot(modes: snap.modes, currentMode: snap.currentMode,
                                       configOptions: snap.configOptions)
        if snap.nativeSteeringAvailable { nativeSteeringAvailable = true }
        ForkCapabilities.shared.note(agent: agentTypeForUI, forks: snap.forkSupported, client: client)
        awaitingBackground = snap.awaitingBackground && snap.status == .prompting
        backgroundOutstanding = snap.backgroundOutstanding
        if awaitingBackground { drainIntoHeldTurnIfPossible() }
    }

    /// The attach snapshot of a freshly spawned agent can predate its
    /// handshake, so ask once more after the prompt is accepted.
    private func refreshSteeringAvailability(connectionID conn: String) {
        guard !nativeSteeringAvailable else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.connectionID == conn, !self.nativeSteeringAvailable else { return }
            if let snap = try? await self.client.connectionSnapshot(connectionId: conn),
               snap.nativeSteeringAvailable, self.connectionID == conn {
                self.nativeSteeringAvailable = true
            }
        }
    }

    /// A new task's first prompt creates the server-side conversation; adopt
    /// its id (and identity summary) without disturbing the in-flight stream.
    private func adoptLinkedConversation(_ id: Int) {
        guard conversationID == nil else { return }
        conversationID = id
        presenceReporter.update(conversationID: id, looking: isOnScreen)
        Task { [weak self] in
            guard let self else { return }
            guard let detail = try? await self.client.conversationDetail(id: id, window: .tail(1)),
                  self.conversationID == id else { return }
            // Mid-stream: adopt identity + stats only — the live turn is still
            // rendering and `refreshAfterTurn()` reconciles the transcript.
            self.summary = detail.summary
            self.sessionStats = detail.sessionStats ?? self.sessionStats
            self.insertModel.agentType = detail.summary.agentType
        }
    }

    private func applyUsage(used: UInt64, size: UInt64) {
        let prev = sessionStats
        sessionStats = SessionStats(
            totalUsage: prev?.totalUsage,
            totalTokens: Int(used),
            totalDurationMs: prev?.totalDurationMs ?? 0,
            contextWindowUsedTokens: Int(used),
            contextWindowMaxTokens: size > 0 ? Int(size) : prev?.contextWindowMaxTokens,
            contextWindowUsagePercent: size > 0 ? (Double(used) / Double(size)) * 100 : prev?.contextWindowUsagePercent
        )
    }

    // MARK: - Finalize / fail

    private func finalize(live: LiveTurn, stopReason: String) {
        guard isTurnActive else { return }
        isTurnActive = false
        // Read before clearing: this is the one transition that delivers parked
        // plan-revision notes (every other terminal path drops them).
        let planFollowUp = pendingPlanFollowUp
        clearInteractivePrompts()
        // Publish any pending coalesced text before flipping to the finalized
        // render so the seam is reflow-free (the finalized branch reads the same
        // run text, now complete).
        live.flushAllText()
        live.isStreaming = false
        live.stopReason = stopReason
        sendState = .idle
        completedTurnTick &+= 1
        closeStream()
        requestScrollToBottom()
        // Replace the optimistic + live turns with the authoritative server copy.
        Task { [weak self] in await self?.refreshAfterTurn(reconciling: live) }
        retireSettledNotes()
        awaitingBackground = false
        backgroundOutstanding = 0
        // The keep-planning turn just ended — deliver the revision notes as the
        // follow-up prompt Grok expects (it discards them on the reply itself).
        if let planFollowUp {
            send(overrideText: planFollowUp)
        } else {
            sendNextQueued()
        }
    }

    /// Roll back an optimistic send that failed *before the server accepted the
    /// prompt*: tear down the stream, drop the pending user turn and its empty
    /// live placeholder, and restore the user's text so they can retry (unless
    /// `restoreToComposer` is false: the caller keeps the message elsewhere).
    /// The caller surfaces the reason via `notice`.
    private func discardOptimisticSend(userTurnID: String, live: LiveTurn, restoringDraft text: String,
                                       restoringAttachments sent: [Attachment], restoreToComposer: Bool = true,
                                       keepCreatedConversation: Bool = false) {
        isTurnActive = false
        clearInteractivePrompts()
        closeStream()
        pendingUserTurns.removeAll { $0.id == userTurnID }
        if liveTurn === live { liveTurn = nil }
        sendState = .idle
        // If THIS send created the conversation up front (a draft's first send) but
        // the prompt was never accepted, roll that creation back too: delete the
        // empty row (so it doesn't linger in every client's sidebar) and clear the
        // adopted identity, returning the screen to a clean, editable draft.
        // Not when the message stays queued for it: the conversation is where it
        // goes once the server answers.
        if keepCreatedConversation {
            draftCreatedConversationID = nil
        } else if let createdID = draftCreatedConversationID {
            draftCreatedConversationID = nil
            conversationID = nil
            summary = nil
            sessionStats = nil
            Task { [weak self] in
                try? await self?.client.deleteConversation(conversationId: createdID)
                self?.notifyConversationsChanged()
            }
        }
        // The send failed before the server accepted it, so no conversation was
        // created — re-open the draft's agent/folder pickers for an edited retry.
        if conversationID == nil { hasStartedFirstSend = false }
        if restoreToComposer {
            // Don't clobber a fresh draft the user may have started typing.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = text
            }
            // Restore the staged images too, unless the user has since added new ones.
            if attachments.isEmpty, !sent.isEmpty {
                attachments = sent
            }
        }
        requestScrollToBottom()
    }

    private func failLive(_ live: LiveTurn, message: String?) {
        isTurnActive = false
        awaitingBackground = false
        attachPhase = nil
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if let message { live.errorMessage = message }
        sendState = message.map { .error($0) } ?? .idle
        closeStream()
        // Keep the live turn on screen so the user sees partial output + error;
        // drop the placeholder only if it is completely empty and errorless.
        if live.isEmpty {
            liveTurn = nil
        }
        requestScrollToBottom()
    }

    // MARK: - Stream recovery (transient drops)

    /// Restart stream recovery after the app returns to the foreground. iOS
    /// suspends the process on screen lock / app switch, which kills the event
    /// socket, and the silent-reconnect backoff is a `Task.sleep` that makes no
    /// progress while suspended — so a turn that was streaming comes back to a dead
    /// socket having quietly spent its reconnect budget on attempts that never
    /// reached the server. The reply then sits frozen mid-stream indefinitely with
    /// no error, and only leaving and re-entering the session recovers it.
    ///
    /// Re-attaching targets the SAME server-side ACP connection (it outlives the
    /// WebSocket) and the fresh attach snapshot carries everything the agent
    /// produced while we were away, so nothing is lost by reconnecting here.
    ///
    /// No-op unless a turn is actually streaming: an idle screen has nothing to
    /// recover, and a session opened cold is already covered by `reattachIfLive`.
    func resumeStreamAfterForeground() {
        // A send still shaking hands owns its own recovery (its ready timeout fails
        // it cleanly). Closing that socket here would cancel the handshake and
        // strand a turn whose prompt the server never received.
        guard readyContinuation == nil else { return }
        guard isInFlight, isTurnActive, let live = liveTurn, let conn = connectionID else { return }
        // The attempts burned while suspended were never real attempts — give
        // recovery its full allowance back, or a long stretch in the background
        // leaves nothing left to reconnect with.
        streamReconnects = 0
        // `liveTurnFromReattach` records which consumer owns this turn: it is true
        // only when `consumeReattach` built it from a snapshot. Routing back to the
        // same one keeps the transcript's in-flight suppression consistent.
        reconnectStream(into: live, connectionID: conn, reason: nil, reattach: liveTurnFromReattach)
    }

    /// Recover a dropped event socket mid-turn by re-opening it and re-attaching
    /// to the SAME server-side ACP connection — which outlives the WebSocket.
    /// Mirrors the web client, whose socket auto-reconnects and re-subscribes its
    /// live streams, so a transient network blip or a server socket recycle no
    /// longer surfaces an error. Backs off between attempts; after
    /// `maxStreamReconnects` consecutive failures with no frames it gives up and
    /// reconciles against the server instead of looping forever.
    ///
    /// `reattach` selects the consumer: the send path (`consume`, feeding the
    /// existing `live`) versus the cross-client reattach path (`consumeReattach`,
    /// which rebuilds `live` from the fresh snapshot).
    private func reconnectStream(into live: LiveTurn, connectionID conn: String, reason: String?, reattach: Bool = false) {
        guard liveTurn === live, isTurnActive else { return }
        streamReconnects += 1
        guard streamReconnects <= Self.maxStreamReconnects else {
            Task { [weak self] in await self?.reconcileOrFail(live: live, reason: reason) }
            return
        }
        let attempt = streamReconnects
        closeStream()              // drop the dead socket (also bumps the generation)
        streamGeneration &+= 1
        let generation = streamGeneration
        // A quiet "connecting" indicator, not a hard error.
        if case .running = sendState {} else { sendState = .connecting }
        reconnectTask = Task { [weak self] in
            // Exponential backoff capped at 8s: 0.5, 1, 2, 4, 8, 8 …
            let delay = min(8.0, 0.5 * pow(2.0, Double(attempt - 1)))
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled,
                  self.liveTurn === live, self.isTurnActive,
                  generation == self.streamGeneration else { return }
            let newStream = self.makeEventStream()
            self.stream = newStream
            newStream.start()
            self.consumerTask = Task { [weak self] in
                if reattach {
                    await self?.consumeReattach(stream: newStream, connectionID: conn, generation: generation)
                } else {
                    await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation)
                }
            }
        }
    }

    /// A reconnect found no turn running on the connection while this screen
    /// still shows one: it ended while the socket was down. Ask the server once
    /// more after a moment (an attach can catch the instant before the agent
    /// starts on a fresh prompt), then settle the turn the way its missed
    /// `turn_complete` would have: finalize and reconcile with the transcript,
    /// which also sends the next queued message. A connection that is down or
    /// gone goes through ``reconcileOrFail(live:reason:)`` instead. `reading`
    /// is the reconnect's own snapshot, used when the server can't be asked.
    private func settleIfTurnEnded(live: LiveTurn, connectionID conn: String,
                                   reading: LiveSessionSnapshot.TurnPhase = .ended) {
        guard liveTurn === live, isTurnActive else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.liveTurn === live, self.isTurnActive, !self.promptInFlight else { return }
            var phase: LiveSessionSnapshot.TurnPhase? = reading
            do {
                phase = try await self.client.liveSessionSnapshot(connectionId: conn)?.turnPhase
            } catch {
                // The server didn't answer: go by what the reconnect saw.
            }
            guard self.liveTurn === live, self.isTurnActive, !self.promptInFlight else { return }
            switch phase {
            case .running?, .starting?:
                // A turn runs after all; its frames reach the attached socket.
                return
            case .ended?:
                self.finalize(live: live, stopReason: "end_turn")
            case .connectionDown?, nil:
                await self.reconcileOrFail(live: live, reason: nil)
            }
        }
    }

    /// The socket of a cold reattach dropped before its snapshot, with no turn on
    /// screen yet: try again a few times with a backoff, so a session whose turn
    /// runs on the server doesn't stay unattached here for the screen's
    /// lifetime (the dead socket also blocked every later reattach).
    private func retryReattachAfterDrop(serverSaysLive: Bool) {
        closeStream()
        guard liveTurn == nil, reattachDrops < Self.maxReattachDrops else { return }
        reattachDrops += 1
        let delay = 0.5 * pow(2.0, Double(reattachDrops - 1))
        reattachRetryTask?.cancel()
        reattachRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.reattachIfLive(serverSaysLive: serverSaysLive)
        }
    }

    /// Recovery's last resort: the socket can't be re-attached (the connection was
    /// GC'd, or reconnects kept failing). The turn may actually have completed
    /// during the outage, so re-fetch the transcript and adopt it silently when the
    /// reply has landed; only when the server still has nothing do we surface an
    /// error — and even then the partial streamed output stays on screen.
    private func reconcileOrFail(live: LiveTurn, reason: String?) async {
        guard liveTurn === live, isTurnActive else { return }
        streamReconnects = 0
        if let id = conversationID,
           let outcome = try? await fetchTranscript(id: id, overlap: TranscriptSync.liveOverlap),
           liveTurn === live, isTurnActive {
            let detail = outcome.detail
            summary = detail.summary
            sessionStats = detail.sessionStats ?? sessionStats
            // Adopt only a transcript that genuinely advanced past our pre-turn
            // baseline AND ends with a real reply — never a stale read.
            if outcome.window.end > heldEnd, Self.transcriptHasReply(outcome.window.turns) {
                isTurnActive = false
                clearInteractivePrompts()
                adoptWindow(outcome, allowShrink: false)
                pendingUserTurns.removeAll()
                liveTurn = nil
                sendState = .idle
                retireSettledNotes()
                awaitingBackground = false
                backgroundOutstanding = 0
                closeStream()
                requestScrollToBottom()
                // The turn is over: what waited for its end goes now.
                sendNextQueued()
                return
            }
        }
        failLive(live, message: "Lost the connection. Your reply may still be running — reopen the session to check.")
    }

    // MARK: - Interactive prompts (permission / question / plan)

    /// Resolve the pending permission (or ExitPlanMode) by selecting an option.
    /// Optimistically clears the card on success; on failure keeps it and returns
    /// `false` so the card can re-enable and show an inline error. The agent then
    /// continues — or stops, for a `reject*` option — over the same stream.
    func respondPermission(optionId: String) async -> Bool {
        guard let pending = pendingPermission, let conn = connectionID else { return false }
        do {
            try await client.respondPermission(connectionId: conn, requestId: pending.requestId, optionId: optionId)
            // Optimistic clear; the stream also echoes `permission_resolved`
            // (idempotent — matched by request id).
            if pendingPermission?.requestId == pending.requestId { pendingPermission = nil }
            requestScrollToBottom()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Answer the pending `ask_user_question`. Optimistic clear on success.
    func answerQuestion(_ answer: QuestionAnswer) async -> Bool {
        guard let pending = pendingQuestion, let conn = connectionID else { return false }
        do {
            try await client.answerQuestion(connectionId: conn, questionId: pending.questionId, answer: answer)
            if pendingQuestion?.questionId == pending.questionId { pendingQuestion = nil }
            requestScrollToBottom()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// Dismiss the pending question — the agent proceeds with its own judgment.
    func declineQuestion() async -> Bool {
        await answerQuestion(.dismissed)
    }

    /// Resolve Grok's blocked `exit_plan_mode`. Optimistic clear on success.
    ///
    /// "Request changes" needs one extra step: Grok DISCARDS the reply's `feedback`
    /// on the keep-planning path (only approve/abandon consume it), and its own TUI
    /// instead delivers the revision notes as a follow-up user turn. Mirror that —
    /// otherwise the notes vanish and Grok re-presents the same plan. The
    /// keep-planning turn is usually still winding down at this point, so the
    /// follow-up is parked and flushed when the turn completes.
    func answerPlanApproval(decision: PlanApprovalDecision, feedback: String?) async -> Bool {
        guard let pending = pendingPlanApproval, let conn = connectionID else { return false }
        let notes = (feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.answerPlanApproval(connectionId: conn, approvalId: pending.approvalId,
                                                decision: decision, feedback: notes.isEmpty ? nil : notes)
            if pendingPlanApproval?.approvalId == pending.approvalId { pendingPlanApproval = nil }
            if decision == .requestChanges, !notes.isEmpty {
                // Park the notes for THIS turn's completion — `finalize` picks them
                // up. If the keep-planning turn already ended, send them now.
                if isInFlight { pendingPlanFollowUp = notes } else { send(overrideText: notes) }
            }
            requestScrollToBottom()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    /// A blocked permission/question/plan-approval can't outlive its turn: clear
    /// any pending card when the turn finalizes, fails, or is cancelled.
    ///
    /// Parked plan-revision notes are dropped here too — they are meaningful only
    /// as the immediate follow-up to the keep-planning turn that produced them. A
    /// turn that failed or was cancelled never gets that follow-up, and leaving
    /// the notes parked would let a LATER, unrelated turn's completion send them.
    /// (`finalize` — the one path that legitimately delivers them — reads them
    /// before calling this.)
    private func clearInteractivePrompts() {
        pendingPermission = nil
        pendingQuestion = nil
        pendingPlanApproval = nil
        pendingPlanFollowUp = nil
        if let id = conversationID { AttentionStore.shared.set(nil, for: id) }
    }

    /// After a successful turn, re-fetch the persisted transcript and splice it
    /// in, dropping the optimistic user turns and the live placeholder so nothing
    /// renders twice.
    ///
    /// The server emits `turn_complete` a beat *before* the assistant reply is
    /// queryable, so an immediate `conversationDetail` can come back without the
    /// new reply (only the user turn persisted, or the assistant turn present but
    /// still empty). Adopting that blindly would replace the just-streamed reply
    /// with an empty "No content" turn — the bug this guards against. So we only
    /// retire the finalized live turn once the fetched transcript actually carries
    /// the reply; until then the live turn (now pulse-free) stays on screen, and
    /// we retry a few times with a short backoff. If it never reconciles, the live
    /// turn simply remains — the content is preserved and a later full load
    /// reconciles it.
    private func refreshAfterTurn(reconciling live: LiveTurn) async {
        // A new task that never got linked keeps its locally rendered turns.
        guard let id = conversationID else { return }
        // Whether the finished live turn has content worth preserving. If it was
        // empty (e.g. a no-op turn), there's nothing to protect — adopt whatever
        // the server returns on the first successful fetch.
        let mustPreserveReply = !live.isEmpty
        // Pre-turn baseline. A fetched transcript is only "ours" once it has grown
        // past this — otherwise a stale read that still ends with the *previous*
        // turn's assistant reply would satisfy `transcriptHasReply` and we'd adopt
        // it, dropping the reply we just streamed. `turns` isn't mutated elsewhere
        // between finalize and this reconcile.
        let baselineEnd = heldEnd

        for attempt in 0..<5 {
            // If the user started another turn while we were reconciling, that
            // newer turn now owns turns/pendingUserTurns/liveTurn; bail so we
            // don't wipe its in-flight state (its own finalize reconciles later).
            guard liveTurn === live else { return }
            do {
                // Only what changed: the reply and the turn or two before it.
                let outcome = try await fetchTranscript(id: id, overlap: TranscriptSync.liveOverlap)
                let detail = outcome.detail
                // Re-check after the await — a new turn may have begun during it.
                guard liveTurn === live else { return }
                // Identity/stats are always safe to adopt, even before the reply
                // is queryable, so the header stays fresh while we wait.
                summary = detail.summary
                sessionStats = detail.sessionStats ?? sessionStats

                // Adopt only once the transcript has genuinely advanced for THIS
                // turn: it must have grown past the baseline (so a stale read that
                // merely ends with an older reply can't masquerade as ours) and —
                // when there's a streamed reply to protect — end with a non-empty
                // assistant turn.
                let advanced = outcome.window.end > baselineEnd
                if advanced, !mustPreserveReply || Self.transcriptHasReply(outcome.window.turns) {
                    adoptWindow(outcome, allowShrink: false)
                    pendingUserTurns.removeAll()
                    liveTurn = nil
                    requestScrollToBottom()
                    return
                }
                // Not reconciled for this turn yet — keep the finalized live turn
                // visible and try again shortly.
            } catch {
                // Re-fetch failed: keep the live turn (now finalized, no pulse) so
                // the user still sees the reply, then retry.
            }
            // Don't sleep after the final attempt.
            if attempt < 4 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Gave up reconciling (the server hasn't persisted the reply within the
        // retry window). Fold the finalized reply — and its optimistic user turn —
        // into the authoritative `turns` so it survives a subsequent send instead
        // of living only in the single `liveTurn` slot; a later reconcile or full
        // load replaces it with the server's copy.
        promoteUnreconciled(live)
    }

    /// Fold a finalized-but-unreconciled live reply (plus the optimistic user
    /// turn(s) still awaiting persistence) into `turns`, so the reply is never
    /// dropped from view when the `liveTurn` slot is reused by the next send. The
    /// synthesized turns are transient: the next successful `refreshAfterTurn` /
    /// `load` overwrites `turns` wholesale with the server's authoritative copy.
    private func promoteUnreconciled(_ live: LiveTurn) {
        // Only act while this is still the current live turn — if a newer turn has
        // taken over, it already owns (and preserved) the prior state.
        guard liveTurn === live else { return }
        turns.append(contentsOf: pendingUserTurns)
        pendingUserTurns.removeAll()
        // Only fold in assistant turns that actually have renderable content. A
        // finalized turn can be non-empty *solely* because of an inline error /
        // "Cancelled." message (which the snapshot can't represent as a
        // persisted block, since ContentBlock has no error case) — appending a
        // zero-block snapshot would render as "No content". Such a transient error
        // placeholder is simply dropped on the next send; the user turn is kept,
        // and so is every message the user sent into the turn, where it was.
        turns.append(contentsOf: live.snapshotAsMessageTurns())
        liveTurn = nil
        requestScrollToBottom()
    }

    /// True when the latest persisted turn is an assistant reply that actually
    /// carries renderable content — the signal that the server has committed the
    /// reply we just streamed (vs. only the user turn, or an empty placeholder).
    private static func transcriptHasReply(_ turns: [MessageTurn]) -> Bool {
        guard let last = turns.last, last.role == .assistant else { return false }
        return last.blocks.contains { block in
            switch block {
            case .text(let t), .thinking(let t):
                return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .toolUse, .toolResult, .unknown:
                return true
            case .imageGeneration(let prompt, let image):
                return image != nil || !(prompt ?? "").isEmpty
            }
        }
    }

    // MARK: - Activity, steering, queue, Continue (codeg fork)

    /// What this session's own live card says it is blocked on.
    private var localAttention: String? {
        if pendingPermission != nil { return "permission" }
        if pendingQuestion != nil { return "question" }
        if pendingPlanApproval != nil { return "plan_approval" }
        return nil
    }

    /// Mirror this session's card into the shared attention snapshot, so its
    /// list row agrees with the screen.
    private func syncAttention() {
        guard let id = conversationID else { return }
        AttentionStore.shared.set(localAttention, for: id)
    }

    /// What the session is doing, for the header (see ``SessionActivity``).
    var activity: SessionActivity {
        var inputs = SessionActivityInputs(
            attention: localAttention,
            turnState: summary?.turnState,
            turnStateReported: summary?.turnStateReported ?? true,
            status: summary?.status,
            limitPause: summary?.limitPause
            // `summary.background` is deliberately left out: this screen's
            // summary is refreshed by detail reads, which don't carry it, so
            // it would linger from whichever list read last set it.
        )
        if inputs.attention == nil, !isInFlight, let id = conversationID {
            inputs.attention = AttentionStore.shared.kind(for: id)
        }
        if isInFlight {
            if !isTurnActive, case .connecting = sendState {
                inputs.connection = .connecting(phase: attachPhase)
            } else {
                inputs.connectionStatus = .prompting
                inputs.awaitingBackground = awaitingBackground
                inputs.backgroundCount = backgroundOutstanding
            }
        }
        return SessionActivity.derive(inputs)
    }

    /// A message can go into the running turn right now (native steering).
    var canInsertIntoTurn: Bool {
        isInFlight && isTurnActive && nativeSteeringAvailable && connectionID != nil
    }

    /// The turn is held only for background work and the agent is idle: a
    /// plain send is delivered into it at once instead of queueing.
    var canDeliverIntoHeldTurn: Bool {
        canInsertIntoTurn && HeldTurn.canDeliver(
            status: .prompting, awaitingBackground: awaitingBackground, nativeSteering: nativeSteeringAvailable)
    }

    /// Where the send button routes while a turn runs.
    var composerSendRoute: ComposerSendRoute {
        HeldTurn.route(isPrompting: isInFlight, canDeliverNow: canDeliverIntoHeldTurn)
    }

    /// The plain send action: an ordinary prompt when idle, a delivery into a
    /// held turn, or the queue while the agent is really replying.
    func sendFromComposer() {
        switch composerSendRoute {
        case .send: send()
        case .deliver: insertIntoTurn()
        case .enqueue: queueDraft()
        }
    }

    /// Deliver the composer's text (and images) into the running turn.
    func insertIntoTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = attachments
        guard !text.isEmpty || !sending.isEmpty else { return }
        if let waiting = attachmentsNotReadyNotice {
            notice = waiting
            return
        }
        guard canInsertIntoTurn, let conn = connectionID else {
            queueDraft()
            return
        }
        draft = ""
        attachments = []
        let clientMessageID = Self.newClientMessageID()
        trackInFlight(clientMessageID: clientMessageID, text: text, attachments: sending)
        Task { [weak self] in
            await self?.deliverIntoTurn(text: text, attachments: sending, connectionID: conn,
                                        clientMessageID: clientMessageID)
        }
    }

    /// Park the composer's message until the running turn ends.
    func queueDraft(holdUntilTurnEnd: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = attachments
        guard !text.isEmpty || !sending.isEmpty else { return }
        if let waiting = attachmentsNotReadyNotice {
            notice = waiting
            return
        }
        queuedMessages.append(QueuedMessage(id: UUID(), text: text, attachments: sending,
                                            holdUntilTurnEnd: holdUntilTurnEnd))
        draft = ""
        attachments = []
        // Idle after all (the turn ended while typing): send it now.
        if !isInFlight { sendNextQueued() }
    }

    func removeQueued(_ id: UUID) {
        queuedMessages.removeAll { $0.id == id }
        scheduleUnsentResend()
    }

    /// Put a queued message back in the composer to edit it.
    func editQueued(_ id: UUID) {
        guard let item = queuedMessages.first(where: { $0.id == id }) else { return }
        queuedMessages.removeAll { $0.id == id }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = item.text }
        else { draft += "\n" + item.text }
        attachments += item.attachments
    }

    /// "Send now" on a queued row: into the turn when it can take it, else as
    /// the next prompt when idle.
    func sendQueuedNow(_ id: UUID) {
        guard let item = queuedMessages.first(where: { $0.id == id }) else { return }
        if !isInFlight {
            // Taken off the queue only once the send has started.
            let before = queuedMessages
            queuedMessages.removeAll { $0.id == id }
            if !startSend(text: item.text, attachments: item.attachments, fromComposer: false,
                          clientMessageID: item.clientMessageID, failure: item.failure) {
                queuedMessages = before
            }
        } else if canInsertIntoTurn, let conn = connectionID {
            queuedMessages.removeAll { $0.id == id }
            Task { [weak self] in
                await self?.deliverIntoTurn(text: item.text, attachments: item.attachments, connectionID: conn,
                                            clientMessageID: item.clientMessageID, previous: item.failure)
            }
        }
    }

    /// The turn ended: send the next queued message as a fresh prompt. A
    /// "Not sent" head the server refused waits for Send now, and holds the
    /// rest behind it.
    private func sendNextQueued() {
        guard !isInFlight, let next = queuedMessages.first else { return }
        if let failure = next.failure, !failure.autoRetry { return }
        queuedMessages.removeFirst()
        if !startSend(text: next.text, attachments: next.attachments, fromComposer: false,
                      clientMessageID: next.clientMessageID, failure: next.failure) {
            queuedMessages.insert(next, at: 0)
        }
    }

    /// While the turn is held for background work, deliver the queue's head
    /// into it — one message per idle stretch, FIFO, skipping nothing: a head
    /// that waits for the turn's end holds everything behind it.
    private func drainIntoHeldTurnIfPossible() {
        guard canDeliverIntoHeldTurn, !deliveringQueued, let head = queuedMessages.first,
              !head.holdUntilTurnEnd, let conn = connectionID else { return }
        queuedMessages.removeFirst()
        deliveringQueued = true
        Task { [weak self] in
            await self?.deliverIntoTurn(text: head.text, attachments: head.attachments, connectionID: conn,
                                        clientMessageID: head.clientMessageID, previous: head.failure)
            self?.deliveringQueued = false
        }
    }

    /// `submit_session_feedback`. When the turn already ended (`NoActiveTurn`)
    /// the message is sent as an ordinary prompt instead.
    ///
    /// The message waits above the composer while it is on its way. Once the
    /// server says the agent has it (the `feedback_submitted` echo or the
    /// response, whichever comes first), it moves into the conversation, inside
    /// the reply where the agent took it, as the desktop shows it.
    private func deliverIntoTurn(text: String, attachments sending: [Attachment], connectionID conn: String,
                                 clientMessageID: String = SessionDetailViewModel.newClientMessageID(),
                                 previous: SendFailure? = nil) async {
        // On its way until the server answers (see `runSend`); an insert that
        // outlives the app comes back as a queued prompt under the same id,
        // which the server answers as a duplicate when the insert had arrived.
        trackInFlight(clientMessageID: clientMessageID, text: text, attachments: sending)
        var shown: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        shown.append(contentsOf: sending.map { $0.optimisticBlock })
        let note = InsertedNote(id: UUID(), text: text.isEmpty ? "(image)" : text, blocks: shown,
                                serverID: nil, serverStatus: nil, resolved: false, delivered: false,
                                inThread: false, turnSerial: turnSerial)
        insertedNotes.append(note)
        requestScrollToBottom()
        var blocks: [PromptInputBlock]?
        if !sending.isEmpty {
            blocks = (text.isEmpty ? [] : [PromptInputBlock.text(text)]) + sending.map { $0.promptInputBlock }
        }
        var failure: Error?
        var recorded: FeedbackNoteSnapshot?
        do {
            recorded = try await client.submitSessionFeedback(connectionId: conn, text: text, blocks: blocks,
                                                              clientId: clientMessageID)
        } catch {
            failure = error
        }
        // A lost response (a timeout, a dropped LTE connection) doesn't mean the
        // message failed: a message into a turn held open for background work
        // can take a while to confirm, and the server finishes a delivery it
        // started. Ask it before handing back a message the agent already has.
        if case .transport? = failure as? APIError,
           await insertWasRecorded(noteID: note.id, text: text, connectionID: conn, clientID: clientMessageID) {
            failure = nil
        }
        // The stream's echo already said the server recorded it (it echoes only
        // a note it keeps), so whatever the response says, the agent has it:
        // handing it back would send it twice.
        if failure != nil, insertedNotes.first(where: { $0.id == note.id })?.serverID != nil {
            failure = nil
        }
        // Answered either way below: the server has it, or it is handed on
        // (as a prompt, or queued as "Not sent") under the same id.
        settleInFlight(clientMessageID)
        guard let error = failure else {
            insertAccepted(note.id, recorded: recorded)
            return
        }
        if let api = error as? APIError, api.isNoActiveTurn {
            insertedNotes.removeAll { $0.id == note.id }
            // The turn finished meanwhile: this is simply the next prompt (under
            // the same id).
            if isInFlight || !startSend(text: text, attachments: sending, fromComposer: false,
                                        clientMessageID: clientMessageID, failure: previous) {
                queuedMessages.insert(QueuedMessage(id: UUID(), text: text, attachments: sending,
                                                    holdUntilTurnEnd: false, clientMessageID: clientMessageID,
                                                    failure: previous), at: 0)
            }
            return
        }
        insertedNotes.removeAll { $0.id == note.id }
        // Not delivered as far as this screen knows: kept at the queue's front as
        // "Not sent", for the turn's end (never put back into the message bar,
        // and never retried into the same failure). Its id makes the prompt it
        // becomes a no-op if the insert did arrive.
        let failed = SendFailure.next(after: error, previous: previous)
        queuedMessages.insert(QueuedMessage(id: UUID(), text: text, attachments: sending, holdUntilTurnEnd: true,
                                            clientMessageID: clientMessageID, failure: failed), at: 0)
        notice = failed.autoRetry ? nil : "Not sent: \(Self.describe(error))"
    }

    /// The server took a message sent into the turn. `recorded` is the note
    /// its response described (nil from an older server, or when the response
    /// was lost and a snapshot confirmed it).
    private func insertAccepted(_ noteID: UUID, recorded: FeedbackNoteSnapshot?) {
        guard let idx = insertedNotes.firstIndex(where: { $0.id == noteID }) else { return }
        insertedNotes[idx].resolved = true
        if let recorded {
            if insertedNotes[idx].serverID == nil { insertedNotes[idx].serverID = recorded.id }
            insertedNotes[idx].serverStatus = recorded.status
        }
        let status = insertedNotes[idx].serverStatus ?? .unknown
        // Native steering hands the agent the message at once; the pull channel
        // waits for its tool. A server that says neither: go by the channel.
        let delivered = status == .delivered || (status == .unknown && nativeSteeringAvailable)
        guard delivered else { return }
        insertedNotes[idx].delivered = true
        placeInThread(noteID)
    }

    /// A `feedback_submitted` echo: the server recorded a message for the turn,
    /// sent from here or from another client.
    private func noteRecorded(_ recorded: FeedbackNoteSnapshot, live: LiveTurn) {
        guard !recorded.id.isEmpty else { return }
        // `submit_session_feedback` takes no client id, so the text is what ties
        // the echo to a message sent from here.
        let wanted = recorded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let idx = insertedNotes.firstIndex(where: { $0.serverID == recorded.id })
            ?? insertedNotes.firstIndex(where: {
                $0.serverID == nil && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            })
        if let idx {
            if insertedNotes[idx].serverID == nil { insertedNotes[idx].serverID = recorded.id }
            insertedNotes[idx].serverStatus = recorded.status
        }
        // A note on the pull channel waits for the agent's tool, which reads it
        // as a tool result, never as a message: it stays above the composer.
        guard recorded.status == .delivered else { return }
        if let idx {
            insertedNotes[idx].delivered = true
            placeInThread(insertedNotes[idx].id)
        } else if liveTurn === live, live.isStreaming {
            // Sent into this turn from another client (the desktop): the
            // conversation shows it too, as the desktop shows the phone's.
            if live.insertSteered(id: "fb-\(recorded.id)", serverID: recorded.id, text: recorded.text,
                                  blocks: recorded.displayBlocks, timestamp: recorded.createdAt ?? Date()) {
                requestScrollToBottom()
            }
        }
    }

    /// Move a message the agent has from above the composer into the
    /// conversation: into the reply of the turn it was sent into, at the point
    /// the agent took it. When that turn is no longer on screen (it ended, and
    /// the server's transcript replaced it), the transcript holds the agent's
    /// own copy of the message, so it is fetched once nothing runs.
    private func placeInThread(_ noteID: UUID) {
        guard let idx = insertedNotes.firstIndex(where: { $0.id == noteID }), !insertedNotes[idx].inThread
        else { return }
        let note = insertedNotes[idx]
        guard let live = liveTurn, note.turnSerial == turnSerial else {
            insertedNotes.remove(at: idx)
            showLateInsert()
            return
        }
        live.insertSteered(id: note.id.uuidString, serverID: note.serverID, text: note.text,
                           blocks: note.blocks)
        insertedNotes[idx].inThread = true
        requestScrollToBottom()
    }

    /// A message the agent took into a turn this screen no longer shows: the
    /// transcript has it (the agent writes its own copy), so fetch what changed
    /// once no turn runs. A turn that runs reconciles with the transcript when
    /// it ends, which brings it then.
    private func showLateInsert() {
        guard let id = conversationID else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.liveTurn == nil, !self.isInFlight, self.pendingUserTurns.isEmpty,
                  let outcome = try? await self.fetchTranscript(id: id, overlap: TranscriptSync.liveOverlap),
                  self.liveTurn == nil, !self.isInFlight, self.pendingUserTurns.isEmpty else { return }
            self.adoptWindow(outcome, allowShrink: false)
            self.requestScrollToBottom()
        }
    }

    /// The turn ended (or a new one starts): drop the messages above the
    /// composer that are settled. One still on its way stays until the server
    /// answers, so it is never lost in between.
    private func retireSettledNotes() {
        insertedNotes.removeAll { $0.resolved || $0.inThread }
    }

    /// Whether the server recorded a message sent into the turn whose response
    /// never arrived. The stream's `feedback_submitted` echo already tied it to
    /// a server note, or the connection's snapshot lists a note with its text
    /// that no other message on screen claims. The server finishes a delivery
    /// it started even after the request is gone, so it is asked a few times.
    private func insertWasRecorded(noteID: UUID, text: String, connectionID conn: String,
                                   clientID: String) async -> Bool {
        func echoed() -> Bool { insertedNotes.first(where: { $0.id == noteID })?.serverID != nil }
        for check in 0..<3 {
            if echoed() { return true }
            // A server that can't be reached now can't confirm anything.
            let snap: LiveSessionSnapshot?
            do { snap = try await client.liveSessionSnapshot(connectionId: conn) } catch { break }
            if echoed() { return true }
            var claimed = Set(insertedNotes.compactMap { $0.id == noteID ? nil : $0.serverID })
            if let live = liveTurn { claimed.formUnion(live.steeredMessages.compactMap(\.serverID)) }
            // A server that takes client ids records the note under ours.
            let byID = snap?.feedback.first { $0.id == clientID }
            if let recorded = byID
                ?? SendConfirmation.recordedNote(text: text, in: snap?.feedback ?? [], excluding: claimed) {
                if let idx = insertedNotes.firstIndex(where: { $0.id == noteID }) {
                    insertedNotes[idx].serverID = recorded.id
                    insertedNotes[idx].serverStatus = recorded.status
                }
                return true
            }
            if check < 2 { try? await Task.sleep(for: .seconds(1)) }
        }
        return echoed()
    }

    /// The thread ends on the agent's reply (a finished live reply counts).
    private var endsWithAgentReply: Bool {
        if let live = liveTurn, !live.isStreaming {
            return !live.isEmpty && live.errorMessage == nil && !live.endsWithSteered
        }
        guard pendingUserTurns.isEmpty else { return false }
        return ContinuePrompt.endsWithAgentReply(turns)
    }

    /// Offer Continue: an empty composer, nothing queued or waiting on you,
    /// and the agent either idle after its reply, cut off mid-turn, or held
    /// open only for background work (then it goes into the held turn).
    var canOfferContinue: Bool {
        guard summary != nil, !isDraftEditable else { return false }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty,
              queuedMessages.isEmpty else { return false }
        guard localAttention == nil else { return false }
        switch activity {
        case .idle: return !isInFlight && endsWithAgentReply
        case .interrupted: return !isInFlight
        case .background: return canDeliverIntoHeldTurn
        default: return false
        }
    }

    /// One tap: send the fork's Continue prompt ("continue").
    func sendContinue() {
        if canDeliverIntoHeldTurn, let conn = connectionID {
            Task { [weak self] in
                await self?.deliverIntoTurn(text: ContinuePrompt.text, attachments: [], connectionID: conn)
            }
        } else if !isInFlight {
            startSend(text: ContinuePrompt.text, attachments: [], fromComposer: false)
        }
    }

    // MARK: - Cancel

    func cancel() {
        guard let live = liveTurn else { return }
        let conn = connectionID
        // The user stopped it: a message still on its way is not resent later.
        if !inflightMessages.isEmpty {
            inflightMessages.removeAll()
            persistOutbox()
        }
        isTurnActive = false
        awaitingBackground = false
        attachPhase = nil
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if live.isEmpty {
            live.errorMessage = "Cancelled."
        }
        sendState = .idle
        sendTask?.cancel()
        consumerTask?.cancel()
        closeStream()
        requestScrollToBottom()
        if let conn {
            Task { [weak self] in
                try? await self?.client.cancel(connectionId: conn)
            }
        }
    }

    private func closeStream() {
        // Supersede the current consumer so its imminent `.closed`/`.detached`
        // frame is ignored (it must not end a turn we are deliberately closing).
        streamGeneration &+= 1
        resumeReady(throwing: CancellationError())
        // Drop any pending silent reconnect — a deliberate close ends recovery.
        reconnectTask?.cancel()
        reconnectTask = nil
        stream?.detach(subscriptionId: subscriptionID)
        stream?.close()
        stream = nil
    }

    /// The screen became visible / hidden, or the app moved between the
    /// foreground and the background.
    func setOnScreen(_ onScreen: Bool) {
        isOnScreen = onScreen
        presenceReporter.update(conversationID: conversationID, looking: onScreen)
    }

    /// Tear down all live work — call from `.onDisappear` / deinit paths.
    func teardown() {
        isOnScreen = false
        unsentResendTask?.cancel()
        unsentResendTask = nil
        presenceReporter.stop()
        reattachRetryTask?.cancel()
        reattachRetryTask = nil
        sendTask?.cancel()
        sendTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        agentOptions.teardown()
        insertModel.teardown()
        closeStream()
    }

    // MARK: - Scroll

    private func requestScrollToBottom() {
        scrollTick &+= 1
        if !isPinnedToBottom, !hasUnseenLive { hasUnseenLive = true }
    }

    /// Force the transcript to re-pin to the bottom even if the user had scrolled
    /// up (their own send / initial load).
    private func requestStickToBottom() {
        stickTick &+= 1
    }

    /// The transcript reports its bottom-proximity here as the user scrolls, so the
    /// floating "jump to latest" button can appear/disappear.
    func setPinnedToBottom(_ pinned: Bool) {
        if isPinnedToBottom != pinned { isPinnedToBottom = pinned }
        if pinned { markSeen() }
    }

    /// The user tapped the floating "jump to latest" button.
    func userTappedScrollToBottom() {
        isPinnedToBottom = true
        markSeen()
        requestStickToBottom()
    }

    /// The reader is at the latest message: everything so far is seen.
    private func markSeen() {
        seenTurnEnd = heldEnd
        if hasUnseenLive { hasUnseenLive = false }
    }

    // MARK: - Reading position

    /// How this screen's transcript opens, decided once per screen (`screen`
    /// is the screen's own id): at the latest message, or where the reader
    /// left it (``ReadingRestore/decide(saved:openAtLatest:)``). Called while
    /// the screen is drawn, so it only touches state nothing observes.
    func restoreDecision(screen: UUID) -> ReadingRestore {
        if restoreScreen == screen { return restoreForScreen }
        restoreScreen = screen
        let atLatest = openAtLatestNext
        openAtLatestNext = false
        if readingPosition == nil, let id = conversationID {
            readingPosition = readingPositions.position(serverKey: cacheServerKey, conversationID: id)
        }
        var decision = ReadingRestore.decide(saved: readingPosition, openAtLatest: atLatest)
        // The history was rewritten since: the saved row's id is another message now.
        if case .anchored(let saved) = decision, !ReadingRestore.isStillThere(saved, in: turns) { decision = .bottom }
        if case .anchored(let saved) = decision { seenTurnEnd = saved.seenTurnEnd }
        restoreForScreen = decision
        return decision
    }

    /// Open at the latest message: a notification or a link pointed at this
    /// session. A screen showing it now jumps there; otherwise the next one
    /// opens there.
    func requestOpenAtLatest(onScreen: Bool) {
        if onScreen {
            userTappedScrollToBottom()
        } else {
            openAtLatestNext = true
        }
    }

    /// The transcript says where the reader is (scrolling settled, the screen
    /// or the app going). Kept here and saved shortly after, at once when the
    /// session is no longer looked at.
    func noteViewport(_ viewport: TranscriptViewport) {
        let position: ReadingPosition
        if viewport.atBottom || viewport.anchor == nil {
            position = .bottom(seenTurnEnd: heldEnd)
        } else if let anchor = viewport.anchor {
            let millis = anchor.turnID.flatMap { id in turns.first(where: { $0.id == id })?.serverMillis }
            position = ReadingPosition(
                anchorID: anchor.id, anchorTurnID: anchor.turnID, anchorTurnMillis: millis,
                offset: Double(anchor.offset), atBottom: false, windowStart: transcriptWindowStart,
                seenTurnEnd: seenTurnEnd, savedAt: Date()
            )
        } else {
            return
        }
        readingPosition = position
        if isOnScreen {
            positionSaveTask?.cancel()
            positionSaveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                self.persistReadingPosition()
            }
        } else {
            persistReadingPosition()
        }
    }

    /// Save where the reader is now (the screen went, the app went to the
    /// background).
    func persistReadingPosition() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        guard let id = conversationID, let position = readingPosition else { return }
        readingPositions.save(position, serverKey: cacheServerKey, conversationID: id)
    }

    /// The history was replaced (an in-place fork, an edit): the old
    /// position means nothing in it.
    private func forgetReadingPosition() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        readingPosition = nil
        transcriptWindowStart = nil
        if let id = conversationID { readingPositions.remove(serverKey: cacheServerKey, conversationID: id) }
    }

    // MARK: - Conversation actions (nav-bar "…" menu)

    /// Whether there's a real, server-linked conversation to act on (gates the
    /// actions menu; a brand-new unsent draft has none yet).
    var canManageConversation: Bool { conversationID != nil && summary != nil }

    /// Pinned state for the menu's Pin/Unpin label.
    var isPinned: Bool { summary?.isPinned ?? false }

    /// Current lifecycle status (for the status submenu's checkmark).
    var currentStatus: ConversationStatus? { summary?.status }

    /// Rename the conversation. Optimistically updates the title (so the nav
    /// title and details sheet reflect it immediately), reverting on failure.
    func rename(to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = conversationID, !trimmed.isEmpty, trimmed != summary?.title else { return }
        let previous = summary?.title
        summary?.title = trimmed
        do {
            try await client.renameConversation(conversationId: id, title: trimmed)
            notifyConversationsChanged()
        } catch {
            summary?.title = previous
            notice = Self.describe(error)
        }
    }

    /// Pin or unpin. Optimistically flips `pinnedAt`, reverting on failure.
    func togglePin() async {
        guard let id = conversationID else { return }
        userToggleTick &+= 1
        let next = !isPinned
        let previous = summary?.pinnedAt
        summary?.pinnedAt = next ? (previous ?? Date()) : nil
        do {
            try await client.setPinned(conversationId: id, pinned: next)
            notifyConversationsChanged()
        } catch {
            summary?.pinnedAt = previous
            notice = Self.describe(error)
        }
    }

    /// Mark or unmark the session critical from its ⋯ menu or Session
    /// Details (nil: not offered, see ``CriticalSessionRules``).
    var criticalAction: CriticalSessionRules.Action? {
        summary.flatMap(CriticalSessionRules.action(for:))
    }

    /// Mark or unmark critical, and with `stall`, its stall detection. Shown at
    /// once, put back with the desktop's message if the server refuses.
    func setCritical(_ critical: Bool, stall: Bool? = nil) async {
        guard let id = conversationID, let current = summary else { return }
        userToggleTick &+= 1
        summary?.critical = critical
        if let stall { summary?.criticalStall = stall }
        do {
            try await client.setCritical(conversationId: id, critical: critical, stall: stall)
            notifyConversationsChanged()
        } catch {
            summary?.critical = current.critical
            summary?.criticalStall = current.criticalStall
            notice = CriticalSessionRules.failure(Self.describe(error))
        }
    }

    /// Change lifecycle status. Optimistically updates, reverting on failure.
    func setStatus(_ status: ConversationStatus) async {
        guard let id = conversationID, summary?.status != status else { return }
        userToggleTick &+= 1
        let previous = summary?.status
        summary?.status = status
        do {
            try await client.updateStatus(conversationId: id, status: status)
            notifyConversationsChanged()
        } catch {
            summary?.status = previous ?? status
            notice = Self.describe(error)
        }
    }

    /// Permanently delete the conversation. Returns `true` on success so the
    /// view can pop back to the list; on failure surfaces a notice and stays.
    func deleteConversation() async -> Bool {
        guard let id = conversationID else { return false }
        do {
            try await client.deleteConversation(conversationId: id)
            cacheSaveTask?.cancel()
            if let cache = transcriptCache {
                let key = cacheServerKey
                Task { await cache.remove(serverKey: key, conversationID: id) }
            }
            notifyConversationsChanged()
            return true
        } catch {
            notice = Self.describe(error)
            return false
        }
    }

    // MARK: - Fork

    /// The session a fork is taken from, once the conversation is server-linked.
    var forkTarget: ForkTarget? {
        guard let id = conversationID, let summary else { return nil }
        return ForkTarget(conversationID: id, folderID: summary.folderId, agentType: summary.agentType,
                          sessionID: summary.externalId, workingDir: folder?.path)
    }

    /// "Fork Session" in the ⋯ menu (see ``SessionForkRules/listAvailability``),
    /// with this screen's own knowledge of whether a turn runs.
    func sessionForkAvailability(forking: Bool) -> ForkAvailability {
        guard canManageConversation else { return .hidden }
        return SessionForkRules.listAvailability(
            endpoints: ForkCapabilities.shared.endpoints(for: client),
            agent: agentTypeForUI,
            agentForks: ForkCapabilities.shared.agentForks(agentTypeForUI, client: client),
            turnRunning: isInFlight,
            forking: forking
        )
    }

    /// "Fork from here" on the reply that ends at `turnID`
    /// (see ``SessionForkRules/replyAvailability``).
    func replyForkAvailability(turnID: String, forking: Bool) -> ForkAvailability {
        guard canManageConversation else { return .hidden }
        return SessionForkRules.replyAvailability(
            turnID: turnID,
            turns: turns,
            pendingPrompt: !pendingUserTurns.isEmpty,
            endpoints: ForkCapabilities.shared.endpoints(for: client),
            agent: agentTypeForUI,
            agentForks: ForkCapabilities.shared.agentForks(agentTypeForUI, client: client),
            turnRunning: isInFlight,
            forking: forking
        )
    }

    // MARK: - Edit message

    /// An edit is being saved (one at a time): every other Edit greys out.
    private(set) var editInFlight = false
    /// A fork an edit made whose message didn't go out (its history didn't
    /// load): Save again goes on from it instead of forking twice.
    @ObservationIgnored private var pendingEditFork: (forkPointID: String, forkedSessionID: String, keptOriginal: Bool)?
    /// How long a resumed connection may take to come up for an edit.
    @ObservationIgnored var editReadyTimeout: Duration = .seconds(90)

    /// Messages here can be edited: a conversation on the server, an agent
    /// whose fork lands exactly on a chosen reply, and a server whose
    /// `acp_fork` takes an edit mode.
    var canEditMessages: Bool {
        canManageConversation && MessageEditRules.supports(agentTypeForUI)
            && ForkCapabilities.shared.editModes(for: client) == true
    }

    /// A turn runs on this session (the screen's own knowledge; the server
    /// refuses a fork under a turn it started elsewhere).
    private var editTurnRunning: Bool { isInFlight || awaitingBackground || isTurnActive }
    /// A message is on its way to becoming a turn: an edit forking under it
    /// would carry it into the branch.
    private var editAwaitingPersist: Bool { !pendingUserTurns.isEmpty || sendsInProgress > 0 }

    /// "Edit Message" on the user message `turnID` (codeg web's rules,
    /// ``MessageEditRules``): hidden where it can't apply, greyed out with the
    /// reason while it can't run now.
    func editAvailability(turnID: String) -> MessageEditAvailability {
        guard canEditMessages,
              let target = MessageEditRules.target(for: turnID, in: turns, hasOlderTurns: hasOlderTurns)
        else { return .hidden }
        if let block = MessageEditRules.block(target, turnRunning: editTurnRunning,
                                              awaitingPersist: editAwaitingPersist,
                                              queued: !queuedMessages.isEmpty, saving: editInFlight) {
            return .blocked(target, block)
        }
        return .available(target)
    }

    /// What an edit opens with: the message as sent and its pictures.
    func editDraft(turnID: String) -> (text: String, images: [ImageData])? {
        guard let turn = turns.first(where: { $0.id == turnID }) else { return nil }
        return (MessageEditRules.editableText(turn), MessageEditRules.images(turn))
    }

    /// Where a saved edit went.
    enum EditOutcome: Equatable {
        /// The conversation continues from the edited message (in place, or
        /// with the original kept as a separate conversation).
        case sent
        /// The first message: a new conversation to open, which sends it.
        case newConversation(NewSessionRequest)
    }

    /// Save an edit, as codeg web's `handleEditUserMessage` does: fork the
    /// session at the reply right before the message (strictly: a reply the
    /// agent can't name refuses), so the forked session ends exactly where
    /// the message was; load the forked history, which this row now holds;
    /// then send the edited text there with the message's pictures, as any
    /// other message. The first message has no reply before it, so it opens a
    /// new conversation on the same agent and folder instead. Throws
    /// ``MessageEditError`` in the web's words; the editor stays open then.
    func saveEdit(turnID: String, text: String, keepOriginal: Bool) async throws -> EditOutcome {
        guard let id = conversationID, let summary, let message = turns.first(where: { $0.id == turnID }),
              let target = MessageEditRules.target(for: turnID, in: turns, hasOlderTurns: hasOlderTurns)
        else { throw MessageEditError.replyNotFound }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = MessageEditRules.images(message)
        guard !trimmed.isEmpty || !images.isEmpty else {
            throw MessageEditError.failed(String(localized: "there is nothing to send"))
        }
        // Checked again here, not left to the greyed-out item: both can change
        // while the editor is open.
        guard !editInFlight, !editTurnRunning, !editAwaitingPersist else { throw MessageEditError.busy }
        guard queuedMessages.isEmpty else { throw MessageEditError.queued }

        guard case .fork(let forkPoint, _) = target else {
            return .newConversation(NewSessionRequest(
                preselectedFolderID: summary.folderId, agent: summary.agentType,
                initialPrompt: InitialPrompt(text: trimmed, images: images)
            ))
        }

        editInFlight = true
        defer { editInFlight = false }
        do {
            let conn = try await resolveConnectionForOptions()
            let status = try await waitUntilConnectedForEdit(conn)
            if status == .prompting { throw MessageEditError.busy }
            var fork = pendingEditFork
            if fork?.forkPointID != forkPoint {
                pendingEditFork = nil
                // A reply this phone has no server name for: find it in a
                // fresh read of the transcript.
                let point: String
                if let reply = turns.first(where: { $0.id == forkPoint }), MessageEditRules.isServerTurn(reply) {
                    point = forkPoint
                } else if let named = try await resolveEditForkPoint(for: message) {
                    point = named
                } else {
                    throw MessageEditError.replyNotFound
                }
                let result = try await client.fork(
                    connectionId: conn, conversationId: id, folderId: summary.folderId,
                    forkFromTurnId: point, mode: MessageEditRules.forkMode(keepOriginal: keepOriginal)
                )
                adoptForkConnection(conn)
                // This row now holds the forked session; the original is on a
                // sibling row (hidden, or "… (before edit)" for the lists).
                notifyConversationsChanged()
                fork = (forkPoint, result.forkedSessionId, keepOriginal)
                pendingEditFork = fork
            }
            guard let fork else { throw MessageEditError.replyNotFound }
            guard await adoptForkedHistory(forkedSessionID: fork.forkedSessionID) else {
                throw MessageEditError.historyFailed(keptOriginal: fork.keptOriginal)
            }
            pendingEditFork = nil
            startSend(text: trimmed, attachments: images.enumerated().compactMap { Attachment(image: $1, index: $0) },
                      fromComposer: false)
            return .sent
        } catch let error as MessageEditError {
            throw error
        } catch APIError.turnInProgress {
            throw MessageEditError.busy
        } catch let error as APIError {
            throw MessageEditError.failed(error.serverMessage)
        } catch let error as ForkError {
            throw MessageEditError.failed(error.errorDescription ?? "\(error)")
        } catch {
            throw MessageEditError.failed(error.localizedDescription)
        }
    }

    /// Wait until the connection has started (`connected`, or `prompting`
    /// for a turn already running).
    private func waitUntilConnectedForEdit(_ conn: String) async throws -> ConnectionStatus? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: editReadyTimeout)
        while true {
            guard let snapshot = try await client.liveSessionSnapshot(connectionId: conn) else {
                throw APIError.streamGone
            }
            switch snapshot.status {
            case .connected?, .prompting?:
                return snapshot.status
            case .error?, .disconnected?:
                throw MessageEditError.failed(String(localized: "the agent didn’t start"))
            case .connecting?, nil:
                break
            }
            guard clock.now < deadline else {
                throw MessageEditError.failed(String(localized: "the agent took too long to start"))
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// The server's name for the reply right before `message`, from a fresh
    /// read starting at the turn the held window starts at (codeg web's
    /// `resolveEditForkTurnId`).
    private func resolveEditForkPoint(for message: MessageTurn) async throws -> String? {
        guard let id = conversationID,
              let ordinal = turns.filter({ $0.role == .user }).firstIndex(where: { $0.id == message.id })
        else { return nil }
        let fresh = try await client.conversationDetail(id: id, window: .from(index: turnsOffset, expected: ""))
        // Started anywhere else, the turns wouldn't line up.
        if let offset = fresh.turnsOffset, offset != turnsOffset { return nil }
        return MessageEditRules.resolveForkPoint(in: fresh.turns, userOrdinal: ordinal,
                                                 messageText: MessageEditRules.editableText(message))
    }

    /// Load the forked history this row now holds (codeg web's
    /// `awaitForkedHistory`): read from the end until the row is on the
    /// forked session, four tries. A history that is in place but still reads
    /// back empty counts: the edit goes to the fork rather than being lost.
    private func adoptForkedHistory(forkedSessionID: String) async -> Bool {
        guard case .existing(let id) = mode else { return false }
        cacheSaveTask?.cancel()
        if let cache = transcriptCache { await cache.remove(serverKey: cacheServerKey, conversationID: id) }
        forgetReadingPosition()
        // A reply streamed here before the fork belongs to the old history.
        if let live = liveTurn, !live.isStreaming { liveTurn = nil }
        openedFromCache = false
        var onFork = false
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(400 * attempt)) }
            guard let outcome = try? await TranscriptSync.fetch(client: client, id: id, held: nil, overlap: 0)
            else { continue }
            onFork = outcome.detail.summary.externalId == forkedSessionID
            guard onFork else { continue }
            summary = outcome.detail.summary
            sessionStats = outcome.detail.sessionStats ?? sessionStats
            adoptWindow(outcome, allowShrink: true)
            if !outcome.window.turns.isEmpty { return true }
        }
        return onFork
    }

    /// The connection a fork ran on is this conversation's: the next send
    /// reuses it, unless a send is already being handed over on another.
    func adoptForkConnection(_ conn: String) {
        guard !isHandingOffSend else { return }
        connectionID = conn
    }

    /// A fork moved this conversation to the forked session in place: its
    /// history now ends where the fork was taken, under a `[Fork] …` title, and
    /// the original lives on in another row. Reload it from the end, letting
    /// the transcript shrink, and forget the cached copy of the original.
    func reloadAfterInPlaceFork(connectionID conn: String?) async {
        guard case .existing(let id) = mode else { return }
        cacheSaveTask?.cancel()
        if let cache = transcriptCache { await cache.remove(serverKey: cacheServerKey, conversationID: id) }
        if let conn { adoptForkConnection(conn) }
        openedFromCache = false
        forgetReadingPosition()
        do {
            let outcome = try await TranscriptSync.fetch(client: client, id: id, held: nil, overlap: 0)
            summary = outcome.detail.summary
            sessionStats = outcome.detail.sessionStats ?? sessionStats
            adoptWindow(outcome, allowShrink: true)
            phase = .loaded
            requestStickToBottom()
        } catch {
            // Never leave the original's history standing for the fork's: a
            // suspended screen loads it afresh when it is shown again, one on
            // screen offers to try again.
            turns = []
            turnsOffset = 0
            windowPrefixHash = nil
            windowTotal = nil
            if !isSuspended { phase = .failed(Self.describe(error)) }
        }
    }

    /// Tell the (separate) session-list view model to refetch after a mutation,
    /// so it doesn't show a stale title/status or a still-tappable deleted row.
    private func notifyConversationsChanged() {
        NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
    }

    // MARK: - Errors

    // MARK: - Outbox (messages the server does not have yet)

    /// Store the queue and the messages on their way (see ``OutboxStore``).
    /// Not before the stored copy was read, which it would overwrite.
    private func persistOutbox() {
        guard let id = conversationID, restoredOutboxFor == id else { return }
        let contents = OutboxStore.Contents(
            queue: queuedMessages.map { Self.outboxMessage($0) },
            inflight: Array(inflightMessages.values)
        )
        OutboxStore.save(contents, serverKey: outboxServerKey, conversationID: id)
    }

    /// Read the stored outbox, once per conversation: the queue as it was,
    /// behind the messages that were on their way when the app last went away
    /// (marked interrupted, to go again under their ids).
    private func restoreOutbox(conversationID id: Int) {
        guard restoredOutboxFor != id else { return }
        restoredOutboxFor = id
        guard let stored = OutboxStore.load(serverKey: outboxServerKey, conversationID: id) else { return }
        let have = Set(queuedMessages.map(\.clientMessageID))
        let restored = stored.restoredQueue
            .filter { !have.contains($0.clientMessageID) }
            .map { Self.queuedMessage($0) }
        inflightMessages = [:]
        queuedMessages = restored + queuedMessages
        scheduleUnsentResend()
    }

    private func trackInFlight(clientMessageID: String, text: String, attachments sending: [Attachment]) {
        inflightMessages[clientMessageID] = Self.outboxMessage(
            QueuedMessage(id: UUID(), text: text, attachments: sending, holdUntilTurnEnd: false,
                          clientMessageID: clientMessageID)
        )
        persistOutbox()
    }

    private func settleInFlight(_ clientMessageID: String) {
        guard inflightMessages.removeValue(forKey: clientMessageID) != nil else { return }
        persistOutbox()
    }

    /// The stored form: text and pictures; an uploaded video stays on the
    /// server and comes back as its reference in the text.
    private static func outboxMessage(_ item: QueuedMessage) -> OutboxMessage {
        var text = item.text
        var images: [OutboxMessage.Image] = []
        for attachment in item.attachments {
            if let uploaded = attachment.upload?.uploaded {
                let marker = MediaAttachmentText.marker(name: uploaded.name, path: uploaded.path)
                text = text.isEmpty ? marker : text + "\n" + marker
            } else if !attachment.isVideo {
                images.append(OutboxMessage.Image(name: attachment.name, mimeType: attachment.mimeType,
                                                  data: attachment.data))
            }
        }
        return OutboxMessage(clientMessageID: item.clientMessageID, text: text, images: images,
                             holdUntilTurnEnd: item.holdUntilTurnEnd, failure: item.failure)
    }

    private static func queuedMessage(_ stored: OutboxMessage) -> QueuedMessage {
        QueuedMessage(
            id: UUID(),
            text: stored.text,
            attachments: stored.images.map { Attachment(name: $0.name, mimeType: $0.mimeType, data: $0.data) },
            holdUntilTurnEnd: stored.holdUntilTurnEnd,
            clientMessageID: stored.clientMessageID,
            failure: stored.failure
        )
    }

    /// When the queue's head is "Not sent" for a reason that goes again by
    /// itself, send it once its backoff has passed (at the earliest
    /// `minimumDelay` seconds from now).
    private func scheduleUnsentResend(minimumDelay: Double = 0) {
        unsentResendTask?.cancel()
        unsentResendTask = nil
        guard let head = queuedMessages.first, let failure = head.failure, failure.autoRetry else { return }
        let delay = max(minimumDelay, failure.retryDelay)
        unsentResendTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.unsentResendTask = nil
            // In the background it waits for the app to come back
            // (`refreshOnForeground`).
            guard !self.isSuspended else { return }
            let before = self.queuedMessages.first?.id
            self.sendNextQueued()
            // Not started (the screen is not ready to send yet): look again.
            if !self.isInFlight, self.queuedMessages.first?.id == before {
                self.scheduleUnsentResend(minimumDelay: 3)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}
