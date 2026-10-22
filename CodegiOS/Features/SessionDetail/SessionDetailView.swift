import SwiftUI

/// The session detail transcript: header, live-streaming message transcript, and
/// a pinned compose bar. This is the app's showcase screen — the agent's reply
/// streams in token-by-token over a WebSocket and renders as it arrives.
///
/// Two entry modes share the screen: an existing conversation (loads the
/// transcript), and a brand-new task (fires the first prompt immediately and
/// adopts the conversation the server links). Initializer signatures are
/// contractually stable (constructed by the navigation layer); the view owns a
/// `@MainActor @Observable` model that does all the networking, streaming, and
/// event→UI mapping.
struct SessionDetailView: View {
    let server: ServerProfile
    let client: CodegClient
    /// Open a new draft session (used when the branch switcher resolves a branch
    /// to another worktree folder). `nil` where the host can't navigate.
    let onOpenSession: ((NewSessionRequest) -> Void)?

    /// Owned by `SessionModelStore` (above the navigation containers), so a
    /// screen rebuilt by a layout change keeps the same transcript, draft,
    /// live turn and socket.
    @Bindable private var model: SessionDetailViewModel
    /// Holds the model in the store while this screen is on screen. Without
    /// one (previews), the screen closes the model's sockets when it goes.
    private let lease: SessionLease?
    /// This screen's identity as a holder of the model.
    @State private var holderID = UUID()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Forking (and where a fork opens); absent in previews.
    @Environment(SessionActions.self) private var actions: SessionActions?
    /// Set on any `.background` frame, consumed on the next `.active` — see the
    /// `onChange(of: scenePhase)` below for why this beats comparing adjacent phases.
    @State private var wasBackgrounded = false
    /// The message field has focus: the compose bar is widened, and the boxes
    /// above it follow.
    @State private var composeFocused = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDetails = false
    @State private var showDeleteConfirm = false
    /// Between `onAppear` and `onDisappear`: drives the presence report.
    @State private var isVisible = false
    /// The one-time explanation before Camera Control to talk asks for the camera.
    @State private var showCameraTalkIntro = false
    /// The message open in the editor ("Edit Message").
    @State private var editing: MessageEditSession?
    /// "Keep the original as a separate conversation when editing".
    @AppStorage(MessageEditPreferences.keepOriginalKey) private var keepOriginalOnEdit = false

    private var cameraTalk: CameraTalkController { CameraTalkController.shared }

    init(server: ServerProfile, client: CodegClient, model: SessionDetailViewModel, lease: SessionLease?,
         onOpenSession: ((NewSessionRequest) -> Void)? = nil) {
        self.server = server
        self.client = client
        self.onOpenSession = onOpenSession
        self._model = Bindable(model)
        self.lease = lease
    }

    /// Localized nav title: a real session title renders verbatim (user data,
    /// never localized); the unnamed / new-task / loading fallbacks localize.
    private var navTitle: Text {
        if let t = model.summary?.trimmedTitle { return Text(verbatim: t) }
        if model.summary != nil { return Text("Untitled session") }
        return model.isNewSession ? Text("New Task") : Text("Session")
    }

    var body: some View {
        screen
            .alert("Camera Control to talk", isPresented: $showCameraTalkIntro) {
                Button("Turn On") { Task { await enableCameraTalk() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("While a session is open, hold the Camera Control and speak, then let go: \(AppIdentity.displayName) transcribes it on this iPhone and sends it to the agent. iOS only gives the Camera Control to an app whose camera is running, so the camera runs at its lowest quality while this screen is open. Nothing is recorded or saved, and the green camera dot shows. The volume buttons also work as talk keys and don't change the volume while it's on.")
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Title + what the session is doing ("Working", "Needs you",
        // "Idle — 2 background tasks running", "Paused — limit resets at …").
        ToolbarItem(placement: .principal) {
            SessionTitleView(
                title: navTitle,
                activity: model.summary == nil ? nil : model.activity,
                agentName: model.agentTypeForUI.displayName,
                critical: model.summary?.critical == true
            )
        }
        // The agent avatar (formerly in the compose bar) sits to the right of
        // the title. Shown once loaded; for an editable draft its sheet also
        // hosts the Agent + Folder pickers, otherwise just Mode/config.
        if case .loaded = model.phase {
            // Walkie-talkie: hold the Camera Control to talk to this agent.
            if CameraTalkController.isSupported {
                ToolbarItem(placement: .topBarTrailing) {
                    CameraTalkToolbarButton(isOn: cameraTalk.isEnabled, action: toggleCameraTalk)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                AgentOptionsButton(
                    agentType: model.agentTypeForUI,
                    workingDir: model.folder?.path,
                    isBusy: model.isInFlight,
                    cardWaiting: model.pendingPermission != nil || model.pendingPlanApproval != nil,
                    options: model.agentOptions,
                    newSession: model.isDraftEditable ? NewSessionAgentConfig(
                        availableAgents: model.availableAgents,
                        selectedAgent: model.agentTypeForUI,
                        onSelectAgent: { model.selectAgent($0) },
                        availableFolders: model.availableFolders,
                        selectedFolder: model.folder,
                        onSelectFolder: { model.selectFolder($0) }
                    ) : nil,
                    branch: SessionBranchConfig(
                        // Root repo name when this session lives in a worktree.
                        folderName: model.displayFolderName,
                        folderPath: model.folder?.path,
                        current: model.currentBranch,
                        load: { await model.loadBranches() },
                        switchTo: { await model.switchBranch($0, isRemote: $1) },
                        create: { await model.createBranch($0, from: $1) },
                        onOpenSession: { folderID in
                            onOpenSession?(NewSessionRequest(preselectedFolderID: folderID))
                        }
                    )
                )
            }
            // A "…" actions menu sits just after the agent avatar, available
            // once the conversation is server-linked. Hosts rename / pin /
            // details / status / delete (mirrors codeg web's per-conversation
            // menu). The session banner used to carry this identity inline;
            // it now lives behind "Session Details".
            if model.canManageConversation {
                ToolbarItem(placement: .topBarTrailing) {
                    SessionActionsMenu(
                        model: model,
                        fork: sessionForkAvailability,
                        onRename: {
                            renameText = model.summary?.title ?? ""
                            showRename = true
                        },
                        onFork: { startFork(at: .latest) },
                        onShowDetails: { showDetails = true },
                        onDelete: { showDeleteConfirm = true }
                    )
                }
            }
        }
    }

    private var screen: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("Rename Session", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") { Task { await model.rename(to: renameText) } }
        } message: {
            Text("Enter a new name for this session.")
        }
        .alert("Delete Session?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { if await model.deleteConversation() { dismiss() } }
            }
        } message: {
            Text("“\(model.summary?.displayTitle ?? "This session")” will be permanently deleted. This can't be undone.")
        }
        .sheet(isPresented: $showDetails) {
            if let summary = model.summary {
                SessionDetailsSheet(summary: summary, stats: model.sessionStats, folder: model.folder,
                                    activity: model.activity, agentName: model.agentTypeForUI.displayName,
                                    critical: model.criticalAction == nil ? nil : CriticalControls(
                                        isOn: model.summary?.critical == true,
                                        stall: model.summary?.criticalStall != false,
                                        set: { on, stall in Task { await model.setCritical(on, stall: stall) } }
                                    ))
            }
        }
        .task {
            model.loadIfNeeded()
            // Whether this server's fork takes an edit mode ("Edit Message").
            await ForkCapabilities.shared.probeEditModesIfNeeded(client: client)
        }
        .sheet(item: $editing) { session in
            MessageEditorSheet(
                session: session,
                availability: { model.editAvailability(turnID: session.id) },
                keepOriginal: keepOriginalOnEdit,
                onSave: { text in await saveEdit(session, text: text) }
            )
        }
        .onAppear {
            isVisible = true
            lease?.acquire(holderID)
            updateLooking()
        }
        .onDisappear {
            isVisible = false
            PresenceTracker.shared.hide(serverProfileID: server.id, conversationID: model.conversationID)
            model.setOnScreen(false)
            model.persistReadingPosition()
            if let lease {
                // The store closes the sockets once no screen holds the model.
                lease.release(holderID)
            } else {
                model.teardown()
            }
        }
        .onChange(of: model.conversationID) { _, _ in updateLooking() }
        // The live WebSocket is suspended (and often killed outright) while
        // backgrounded, so returning here otherwise leaves a frozen transcript
        // until the user backs all the way out and re-enters. Returning from the
        // background almost always lands on `.active` via an intermediate
        // `.inactive` frame first (`.background` -> `.inactive` -> `.active`), so
        // comparing only the immediately-prior phase misses most real resumes —
        // `wasBackgrounded` instead remembers that a `.background` frame happened
        // at all since the last refresh, however many `.inactive` frames follow it.
        // A sheet/alert/control-center pull's `.active` -> `.inactive` -> `.active`
        // blip never sets the flag, so it still won't trigger a spurious refresh.
        .onChange(of: scenePhase) { _, new in
            updateLooking()
            switch new {
            case .background:
                wasBackgrounded = true
                model.persistReadingPosition()
            case .active where wasBackgrounded:
                wasBackgrounded = false
                Task { await model.refreshOnForeground() }
            default:
                break
            }
        }
        // Haptics — the app's marquee "felt" moments, all keyed off existing
        // @Observable state. Vocabulary: success = a reply completed, error = it
        // failed, warning = the agent needs you (a permission / question card
        // appeared), selection = pin / status toggles. The send impact lives in
        // ComposeBar (fired on the tap itself, for immediate feedback).
        .sensoryFeedback(.success, trigger: model.completedTurnTick)
        .sensoryFeedback(trigger: model.sendState) { _, new in
            if case .error = new { return .error }
            return nil
        }
        .sensoryFeedback(trigger: model.pendingPermission?.requestId) { _, new in
            new != nil ? .warning : nil
        }
        .sensoryFeedback(trigger: model.pendingQuestion?.questionId) { _, new in
            new != nil ? .warning : nil
        }
        .sensoryFeedback(trigger: model.pendingPlanApproval?.approvalId) { _, new in
            new != nil ? .warning : nil
        }
        .sensoryFeedback(.selection, trigger: model.userToggleTick)
    }

    // MARK: - Edit message

    /// "Edit Message" on this session's messages (web `onEditUserMessage`).
    private var messageEditAction: MessageEditAction? {
        guard model.canEditMessages else { return nil }
        let model = self.model
        return MessageEditAction(
            availability: { model.editAvailability(turnID: $0) },
            start: { turnID in
                guard let draft = model.editDraft(turnID: turnID) else { return }
                editing = MessageEditSession(id: turnID, initialText: draft.text, images: draft.images)
            },
            explain: { model.notice = $0 }
        )
    }

    /// Save an edit: the conversation continues from it here, or, for the
    /// first message, a new conversation opens with it (Back returns here).
    /// Nil once it went out, else why not.
    private func saveEdit(_ session: MessageEditSession, text: String) async -> String? {
        do {
            switch try await model.saveEdit(turnID: session.id, text: text, keepOriginal: keepOriginalOnEdit) {
            case .sent:
                return nil
            case .newConversation(let request):
                guard let onOpenSession else { return MessageEditError.newConversationFailed.errorDescription }
                // Once the editor is down, on top of this session.
                editing = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    onOpenSession(request)
                }
                return nil
            }
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Fork

    /// "Fork Session" in the ⋯ menu: "Forking…" while this session is being
    /// forked, greyed out while another fork runs.
    private var sessionForkAvailability: ForkAvailability {
        guard let actions else { return .hidden }
        return actions.sessionAvailability(model.sessionForkAvailability(forking: false),
                                           conversationID: model.conversationID)
    }

    /// "Fork from here" on the replies of this session: the reply being
    /// forked shows "Forking…", the others are greyed out until it lands.
    private var replyForkAction: ReplyForkAction? {
        guard let actions, model.canManageConversation else { return nil }
        let model = self.model
        return ReplyForkAction(
            availability: { turnID in
                actions.replyAvailability(model.replyForkAvailability(turnID: turnID, forking: false),
                                          conversationID: model.conversationID, turnID: turnID)
            },
            perform: { turnID in startFork(at: .reply(turnID)) },
            explain: { reason in model.notice = reason }
        )
    }

    /// Fork this session at `point`, on its own connection (found, or the
    /// session resumed). The fork opens with this session under it, so Back
    /// returns here; a failure is said in the notice line.
    private func startFork(at point: ForkPoint) {
        guard let actions, let target = model.forkTarget else { return }
        let model = self.model
        actions.start(
            target, at: point, origin: .session(target.conversationID), title: model.summary?.title,
            client: client,
            resolveConnection: { try await model.resolveConnectionForOptions() },
            onConnection: { model.adoptForkConnection($0) },
            onError: { model.notice = $0 }
        )
    }

    private func toggleCameraTalk() {
        if cameraTalk.isEnabled {
            cameraTalk.setEnabled(false)
        } else if cameraTalk.needsIntro {
            showCameraTalkIntro = true
        } else {
            Task { await enableCameraTalk() }
        }
    }

    private func enableCameraTalk() async {
        switch await cameraTalk.enable() {
        case .enabled:
            break
        case .cameraDenied:
            model.notice = "Camera access is off for \(AppIdentity.displayName). Allow it in the Settings app to use the Camera Control to talk."
        case .noCamera:
            model.notice = "This device has no camera, so the Camera Control can't be used to talk."
        }
    }

    /// Tell the server (and the app's banner logic) whether this session is
    /// being looked at: on screen with the app in the foreground.
    private func updateLooking() {
        let looking = isVisible && scenePhase == .active
        model.setOnScreen(looking)
        if looking {
            PresenceTracker.shared.show(serverProfileID: server.id, conversationID: model.conversationID)
        } else {
            PresenceTracker.shared.hide(serverProfileID: server.id, conversationID: model.conversationID)
        }
    }

    private var content: some View {
        // Cross-fade loading ↔ loaded ↔ error instead of a hard cut — after a
        // network round-trip the spinner dissolving into the transcript reads far
        // calmer than a single-frame swap.
        Group {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading session…")
            case .failed(let message):
                InlineErrorView(message: message) {
                    Task { await model.load() }
                }
            case .loaded:
                loadedBody
            }
        }
        .transition(.opacity)
        .animation(Theme.Motion.content, value: model.phase)
    }

    private var loadedBody: some View {
        TranscriptView(
            turns: model.turns,
            pendingUserTurns: model.pendingUserTurns,
            liveTurn: model.liveTurn,
            liveOwnsInFlightReply: model.liveTurnFromReattach && !model.liveCopyIncomplete,
            agent: model.agentTypeForUI,
            turnsVersion: model.turnsVersion,
            scrollTick: model.scrollTick,
            stickTick: model.stickTick,
            onPinnedChange: { model.setPinnedToBottom($0) },
            turnsOffset: model.turnsOffset,
            hasOlderOnServer: model.hasOlderTurns,
            onLoadOlder: { await model.loadOlderTurns() },
            isLoadingOlder: model.isLoadingOlder,
            windowStart: model.transcriptWindowStart,
            onWindowStartChange: { model.transcriptWindowStart = $0 },
            // Decided once for this screen: the latest message, or where the
            // reader left the session.
            restore: model.restoreDecision(screen: holderID),
            onViewportChange: { model.noteViewport($0) },
            mediaContext: model.mediaPathContext,
            mediaPresence: model.mediaEnvironment?.library.presence
        ) {
            // No top banner on an existing session — its identity + stats now
            // live in the nav-bar "…" → Session Details, so messages start at
            // the top and pass under the frosted nav bar (ChatGPT-style). A
            // brand-new task still shows a compact setup card until the server
            // links a conversation.
            VStack(spacing: 12) {
                if model.summary == nil, model.isNewSession {
                    NewSessionHeaderCard(
                        agent: model.selectedAgent,
                        folder: model.folder,
                        isStarting: model.hasStartedFirstSend
                    )
                }
                if model.isEmptyTranscript {
                    EmptyStateView(
                        icon: "bubble.left.and.text.bubble.right",
                        title: "No messages yet",
                        message: "Send a message to start this session."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .environment(\.codegImageSource, model.imageSource)
        .environment(\.codegMedia, model.mediaEnvironment)
        // A link in a message to a picture, video, audio file or document in
        // the session opens it here; anything else opens as before.
        .environment(\.openURL, OpenURLAction { url in
            MediaLinks.open(url, in: model.mediaEnvironment) ? .handled : .systemAction
        })
        .environment(\.replyFork, replyForkAction)
        .environment(\.messageEdit, messageEditAction)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.28), value: model.pendingUserTurns)
        .animation(.snappy(duration: 0.28), value: model.liveTurn?.id)
        .safeAreaInset(edge: .bottom) {
            // The "jump to latest" affordance sits in the compose-bar inset — not
            // as a `List` overlay — so it is reliably above the bar and tappable
            // (an overlay anchored to the scroll view's bottom rendered *under* the
            // compose bar, which silently ate the tap). It is horizontally centered
            // and only present while the user has scrolled up.
            VStack(spacing: 0) {
                // Interactive prompt cards sit above everything in the inset: the
                // agent has paused and the user's next action is to respond here.
                // Fade only (no geometry transition) so the buttons' hit regions
                // aren't offset mid-animation. `.id` resets per-card state when a
                // fresh request replaces a showing one.
                if let pending = model.pendingPermission {
                    PermissionRequestCard(pending: pending, modeNote: model.permissionModeNote) { optionId in
                        await model.respondPermission(optionId: optionId)
                    }
                    .id(pending.requestId)
                    .transition(.opacity)
                    .zIndex(2)
                }
                if let question = model.pendingQuestion {
                    AskQuestionCard(pending: question) { answer in
                        await model.answerQuestion(answer)
                    }
                    .id(question.questionId)
                    .transition(.opacity)
                    .zIndex(2)
                }
                if let approval = model.pendingPlanApproval {
                    PlanApprovalCard(pending: approval) { decision, feedback in
                        await model.answerPlanApproval(decision: decision, feedback: feedback)
                    }
                    .id(approval.approvalId)
                    .transition(.opacity)
                    .zIndex(2)
                }
                if !model.stripNotes.isEmpty {
                    InsertedNotesView(notes: model.stripNotes)
                        .padding(.horizontal, ComposeBar.sideMargin(focused: composeFocused))
                        .transition(.opacity)
                }
                if !model.queuedMessages.isEmpty {
                    QueuedMessagesView(
                        items: model.queuedMessages,
                        canSendNow: !model.isInFlight || model.canInsertIntoTurn,
                        onSendNow: { model.sendQueuedNow($0) },
                        onEdit: { model.editQueued($0) },
                        onRemove: { model.removeQueued($0) }
                    )
                    .equatable()
                    .padding(.horizontal, ComposeBar.sideMargin(focused: composeFocused))
                    .transition(.opacity)
                }
                if model.canOfferContinue {
                    ContinueChip { model.sendContinue() }
                        .padding(.bottom, 2)
                        .transition(.opacity)
                }
                if !model.isPinnedToBottom {
                    // Something arrived below while the reader was scrolled up
                    // or away: said, never scrolled to.
                    JumpToLatestButton(newMessages: model.hasNewMessagesBelow) { model.userTappedScrollToBottom() }
                        .padding(.bottom, 10)
                        // Fade only — a `.scale` transition is scaleEffect-backed
                        // and can leave a residual transform that offsets the
                        // button's hit region from its pixels (the tap then falls
                        // through to the message text behind it). `zIndex` keeps it
                        // above the compose bar's glass during the cross-fade.
                        .transition(.opacity)
                        .zIndex(1)
                }
                ComposeBar(
                    text: $model.draft,
                    isInFlight: model.isInFlight,
                    notice: model.notice,
                    attachments: model.attachments,
                    canAttachMore: model.canAttachMore,
                    onAddAttachments: { model.addAttachments($0) },
                    onRemoveAttachment: { model.removeAttachment($0) },
                    onAddVideo: { model.addVideo($0) },
                    onRetryAttachment: { model.retryAttachment($0) },
                    attachmentsReady: model.attachmentsReady,
                    onNotice: { model.notice = $0 },
                    onSend: { model.sendFromComposer() },
                    onStop: { model.cancel() },
                    steering: ComposeSteering(
                        canInsert: model.canInsertIntoTurn,
                        deliverNow: model.canDeliverIntoHeldTurn
                    ),
                    onInsert: { model.insertIntoTurn() },
                    onQueue: { model.queueDraft() },
                    onDismissNotice: { model.notice = nil },
                    insertModel: model.insertModel,
                    dictationContext: DictationContext(folder: model.folder?.name, session: model.summary?.title),
                    dictationRefiner: client,
                    onFocusChange: { composeFocused = $0 }
                )
            }
            .animation(.snappy(duration: 0.26), value: composeFocused)
            .animation(.snappy(duration: 0.24), value: model.isPinnedToBottom)
            .animation(.snappy(duration: 0.24), value: model.hasNewMessagesBelow)
            .animation(.snappy(duration: 0.24), value: model.queuedMessages)
            .animation(.snappy(duration: 0.24), value: model.insertedNotes)
            .animation(.snappy(duration: 0.24), value: model.canOfferContinue)
            .animation(.snappy(duration: 0.26), value: model.pendingPermission?.id)
            .animation(.snappy(duration: 0.26), value: model.pendingQuestion?.id)
            .animation(.snappy(duration: 0.26), value: model.pendingPlanApproval?.id)
        }
    }
}

/// A floating glass affordance that re-pins the transcript to the newest message,
/// shown only while the user has scrolled up. Mirrors ChatGPT/Claude. When
/// something arrived below meanwhile, it says "New messages".
struct JumpToLatestButton: View {
    var newMessages = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // One face at a time, swapped at once: no cross-fade of the two
            // over each other.
            Group {
                if newMessages {
                    HStack(spacing: 6) {
                        Text("New messages")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .glassEffect(.regular, in: Capsule())
                    .hairlineBorder(20)
                    .contentShape(Capsule())
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular, in: Circle())
                        .hairlineBorder(20)
                        // An explicit hit shape so the whole disc is tappable (and the
                        // tap can't slip past its edge into the transcript underneath).
                        .contentShape(Circle())
                }
            }
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newMessages ? Text("New messages") : Text("Jump to latest"))
        .accessibilityHint(newMessages ? Text("Scrolls to the latest message") : Text(verbatim: ""))
    }
}

/// Identity card shown atop a new task before the server links a conversation
/// (the full `SessionHeaderView` takes over once the summary arrives). Reflects
/// the draft's chosen agent + folder, which are edited from the agent button in
/// the navigation bar until the first send.
private struct NewSessionHeaderCard: View {
    let agent: AgentType?
    let folder: FolderDetail?
    let isStarting: Bool

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 14) {
            HStack(spacing: 10) {
                if let agent {
                    AgentBadge(agent: agent)
                }
                if let folder {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9, weight: .semibold))
                        Text(folder.name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
                Spacer(minLength: 0)
                (isStarting ? Text("Starting…") : Text("Tap the agent avatar above to set up"))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }
}

// MARK: - Actions menu

/// The nav-bar "…" menu of per-conversation actions, mirroring codeg web's
/// per-conversation context menu: rename, pin, fork, details, status, delete.
/// Presented just after the agent avatar once the conversation is
/// server-linked.
private struct SessionActionsMenu: View {
    let model: SessionDetailViewModel
    /// "Fork Session": greyed out with the reason when it can't be taken now.
    let fork: ForkAvailability
    let onRename: () -> Void
    let onFork: () -> Void
    let onShowDetails: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button { Task { await model.togglePin() } } label: {
                if model.isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin")
                }
            }
            if fork != .hidden {
                ForkSessionMenuItem(availability: fork, action: onFork)
            }
            if let critical = model.criticalAction {
                Button { Task { await model.setCritical(critical.marks) } } label: {
                    Label(critical.title, systemImage: critical.symbol)
                }
            }
            Button(action: onShowDetails) {
                Label("Session Details", systemImage: "info.circle")
            }
            Menu {
                ForEach(ConversationStatus.selectable, id: \.self) { status in
                    Button { Task { await model.setStatus(status) } } label: {
                        if model.currentStatus == status {
                            Label(status.label, systemImage: "checkmark")
                        } else {
                            Text(status.label)
                        }
                    }
                }
            } label: {
                Label("Change Status", systemImage: "circle.dashed")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            // A plain ellipsis (no enclosing circle) reads lighter next to the
            // round agent avatar; the system toolbar glass is the only container.
            Image(systemName: "ellipsis")
                .accessibilityLabel("Session actions")
        }
    }
}

// MARK: - Session details sheet

/// The session identity + stats that used to sit in a top banner, now presented
/// on demand from the actions menu. Reuses `SessionHeaderView` for the identity
/// card and adds workspace / timing metadata.
private struct SessionDetailsSheet: View {
    let summary: ConversationSummary
    let stats: SessionStats?
    let folder: FolderDetail?
    let activity: SessionActivity
    let agentName: String
    /// The "Critical session" switches, nil where not offered.
    var critical: CriticalControls?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SessionHeaderView(summary: summary, stats: stats)
                    metadata
                    if let critical {
                        CriticalSessionSection(controls: critical)
                    }
                    if let selector = summary.selectorState, !selector.displayItems.isEmpty {
                        selectorCard(selector)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(CodegBackground())
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The model / effort / mode this conversation's session runs with
    /// (`selector_state`), as the server recorded it.
    private func selectorCard(_ selector: ConversationSelectorState) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(selector.displayItems.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().overlay(Theme.hairline) }
                DetailRow(label: LocalizedStringKey(item.label), value: Text(verbatim: item.value))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
    }

    private var metadata: some View {
        VStack(spacing: 0) {
            DetailRow(label: "Activity", value: Text(verbatim: activity.label(agentName: agentName)))
            Divider().overlay(Theme.hairline)
            DetailRow(label: "Status", value: Text(summary.status.label))
            Divider().overlay(Theme.hairline)
            if let folder {
                DetailRow(label: "Folder", value: Text(verbatim: folder.name))
                Divider().overlay(Theme.hairline)
            }
            DetailRow(label: "Messages", value: Text(verbatim: "\(summary.messageCount)"))
            Divider().overlay(Theme.hairline)
            DetailRow(label: "Created", value: Text(verbatim: summary.createdAt.formatted(date: .abbreviated, time: .shortened)))
            Divider().overlay(Theme.hairline)
            DetailRow(label: "Updated", value: Text(verbatim: summary.updatedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
    }
}

private struct DetailRow: View {
    let label: LocalizedStringKey
    /// A pre-built `Text` so callers can choose verbatim (dynamic data like folder
    /// names/dates) vs. localized (the status label) per row.
    let value: Text

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            value
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Critical session

/// What Session Details' "Critical session" switches show and do.
struct CriticalControls {
    let isOn: Bool
    /// Stall detection, on unless turned off.
    let stall: Bool
    /// Mark or unmark, and the stall detection (nil leaves it as it is).
    let set: (Bool, Bool?) -> Void
}

/// The desktop's Session Details "Critical session" section: mark the session
/// critical (the backend alerts when it sits idle, and again until you act),
/// and while it is, switch its stall detection.
struct CriticalSessionSection: View {
    let controls: CriticalControls

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("Critical session")
            } icon: {
                Image(systemName: controls.isOn ? "flag.fill" : "flag")
                    .foregroundStyle(controls.isOn ? Theme.danger : Theme.textSecondary)
            }
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 10)
            row(title: "Mark as critical", hint: "Alert me when this session sits idle, and again until I act.",
                isOn: Binding(get: { controls.isOn }, set: { controls.set($0, nil) }))
            if controls.isOn {
                Divider().overlay(Theme.hairline)
                row(title: "Alert when a turn may be stuck",
                    hint: "Also alert when a running turn streams nothing for the stall threshold.",
                    isOn: Binding(get: { controls.stall }, set: { controls.set(true, $0) }))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
    }

    private func row(title: LocalizedStringKey, hint: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
        .padding(.vertical, 10)
    }
}
