import SwiftUI
import Observation

/// Top-level navigation + selection state shared by both shells. Owns the
/// server store, the compact shell's per-tab navigation paths, the regular
/// shell's sidebar/content/detail selection, and the app-wide activity poller
/// that feeds the Activity tab and its badge.
@MainActor
@Observable
final class AppModel {
    let serverStore: ServerStore

    /// App-wide pulse of the selected server (running sessions, recents,
    /// folders) — the poll-based stand-in for the future persistent event hub.
    let activity = ActivityModel()

    /// The session screens' models, kept above the navigation containers so
    /// a rebuilt screen gets the same one (see `SessionModelStore`).
    let sessions: SessionModelStore

    /// Brings Activity's finished sessions into the transcript cache.
    let prefetcher: TranscriptPrefetcher

    /// The Chats list's model, shared by the list and a group pushed from it.
    @ObservationIgnored private var chatsList: (server: UUID, model: SessionListViewModel)?

    // MARK: - Server selection

    private static let lastServerKey = "codeg.lastSelectedServerID"

    var selectedServerID: ServerProfile.ID? {
        didSet {
            guard oldValue != selectedServerID else { return }
            resetServerScopedState()
            defaults.set(selectedServerID?.uuidString, forKey: Self.lastServerKey)
        }
    }

    // MARK: - Regular-width (iPad) selection

    /// Detail-column selection. Mutually exclusive with `pendingNewSession`.
    var selectedConversationID: Int?
    /// A "new task" occupying the detail column before its conversation exists.
    var pendingNewSession: NewSessionRequest?
    var sidebarSection: SidebarSection? = .chats
    /// Pushes within the content column (currently: project detail).
    var contentPath: [Route] = []

    // MARK: - Compact-width (iPhone) navigation

    // Typed route stacks (not opaque `NavigationPath`s) so navigation stays
    // inspectable — `open(_:)` can no-op when the destination is already on
    // top (e.g. tapping the running bar inside that very conversation).
    /// Remembered across launches, so the app (and a notification opened
    /// from the lock screen) comes back to the tab you were on.
    var selectedTab: AppTab = .chats {
        didSet {
            guard oldValue != selectedTab else { return }
            defaults.set(selectedTab.rawValue, forKey: Self.lastTabKey)
        }
    }
    var paths: [AppTab: [Route]] = [:]
    private static let lastTabKey = "codeg.lastSelectedTab"
    private let defaults: UserDefaults

    /// The Settings tab's stack is value-driven over `SettingsLeaf` (its own
    /// typed path, separate from the `Route` stacks above) so settings sub-screens
    /// stay out of the global deep-link routing while remaining programmatically
    /// pushable (e.g. `codeg://settings/<slug>`).
    var settingsPath: [SettingsLeaf] = []

    /// The conversation opened last, from any list or a notification. On
    /// iPhone nothing stays selected once you go back, so the lists mark this
    /// one as the session you came from.
    private(set) var lastOpenedConversationID: Int?

    /// The session the lists mark: the one open in the detail column (iPad),
    /// or the one opened last (iPhone).
    var markedConversationID: Int? {
        isCompact ? lastOpenedConversationID : selectedConversationID
    }

    /// Which shell is up, mirrored in by RootView so `open(_:)` can decide
    /// between a push (the tab shell) and a column selection (the split
    /// view). Always true on iPhone, in every orientation (`ShellLayout`).
    /// Changed through `setLayout(compact:)`, which carries the open screen
    /// across.
    private(set) var isCompact = false

    // MARK: - Presentation

    var serversSheetPresented = false
    var settingsSheetPresented = false

    init(serverStore: ServerStore? = nil, defaults: UserDefaults = .standard,
         sessions: SessionModelStore? = nil, transcriptCache: TranscriptCache? = .shared) {
        let store = serverStore ?? ServerStore()
        self.serverStore = store
        self.defaults = defaults
        let sessionStore = sessions ?? SessionModelStore()
        sessionStore.transcriptCache = transcriptCache
        self.sessions = sessionStore
        self.prefetcher = TranscriptPrefetcher(cache: transcriptCache)
        // Restore the last-used server, falling back to the first. With servers
        // demoted out of the tab bar there is no "pick a server" landing screen
        // anymore — the app must come up already pointed at a server.
        let persisted = defaults.string(forKey: Self.lastServerKey).flatMap(UUID.init)
        self.selectedServerID = store.servers.first { $0.id == persisted }?.id ?? store.servers.first?.id
        if let raw = defaults.string(forKey: Self.lastTabKey), let tab = AppTab(rawValue: raw) {
            self.selectedTab = tab
        }
        let activity = self.activity
        sessionStore.summaryLookup = { id in activity.conversations.first { $0.id == id } }
        activity.onRefreshed = { [weak self] in self?.activityRefreshed() }
        store.onChange = { [weak self] in self?.pruneTranscriptCache() }
        pruneTranscriptCache()
    }

    var selectedServer: ServerProfile? {
        guard let id = selectedServerID else { return nil }
        return serverStore.servers.first { $0.id == id }
    }

    /// HTTP client for the selected server, if its token resolves.
    func selectedClient() -> CodegClient? {
        guard let server = selectedServer else { return nil }
        return serverStore.client(for: server)
    }

    // MARK: - Routing

    /// Open a destination from any entry point. Compact pushes onto the current
    /// tab's stack; regular routes to the appropriate column.
    func open(_ route: Route) {
        if case .conversation(let id) = route { lastOpenedConversationID = id }
        if isCompact {
            push(route, on: selectedTab)
            return
        }
        switch route {
        case .conversation(let id):
            pendingNewSession = nil
            selectedConversationID = id
        case .newSession(let request):
            selectedConversationID = nil
            pendingNewSession = request
        case .project:
            sidebarSection = .projects
            if contentPath.last != route { contentPath.append(route) }
        case .sessionGroup:
            sidebarSection = .chats
            if contentPath.last != route { contentPath.append(route) }
        }
    }

    // MARK: - Layout

    /// The shell changed between the tabs (compact) and the split view
    /// (regular). Only an iPad does this (a window resized across the
    /// boundary); an iPhone keeps the tabs in landscape too. The screen that
    /// was open stays open: the split view's sidebar section, content pushes
    /// and detail become a tab with that stack, and back.
    func setLayout(compact: Bool, initial: Bool = false) {
        guard !initial else { isCompact = compact; return }
        guard compact != isCompact else { return }
        if compact {
            let tab = sidebarSection.map(AppTab.init(section:)) ?? selectedTab
            var stack = contentPath
            if let pending = pendingNewSession {
                stack.append(.newSession(pending))
            } else if let id = selectedConversationID {
                stack.append(.conversation(id))
            }
            selectedTab = tab
            paths[tab] = stack
        } else {
            let stack = paths[selectedTab] ?? []
            if let section = SidebarSection(tab: selectedTab) { sidebarSection = section }
            let sessionIndex = stack.firstIndex(where: \.isSession)
            contentPath = Array(stack[..<(sessionIndex ?? stack.endIndex)])
            selectedConversationID = nil
            pendingNewSession = nil
            if let sessionIndex {
                switch stack[sessionIndex] {
                case .conversation(let id): selectedConversationID = id
                case .newSession(let request): pendingNewSession = request
                case .project, .sessionGroup: break
                }
            }
        }
        isCompact = compact
    }

    private func push(_ route: Route, on tab: AppTab) {
        var path = paths[tab, default: []]
        // Already there (e.g. the running bar tapped inside that conversation).
        guard path.last != route else { return }
        path.append(route)
        paths[tab] = path
    }

    /// Handle a deep link on the app's own scheme (`AppIdentity.urlScheme`,
    /// written `codeg://` below). `codeg://tab/<name>` switches tabs;
    /// `codeg://conversation/<id>` / `codeg://project/<id>` land on the owning
    /// tab with a fresh, predictable stack (so Back always returns to that
    /// tab's root, not to wherever the user happened to be).
    func handle(url: URL) {
        guard AppIdentity.owns(url) else { return }
        if url.host?.lowercased() == "tab",
           url.pathComponents.count > 1,
           let tab = AppTab(rawValue: url.pathComponents[1].lowercased()) {
            select(tab: tab)
            return
        }
        // `codeg://settings/<slug>` jumps straight to a Settings sub-screen (used
        // for screenshot verification, and harmless in production). The leaf is
        // honored on BOTH shells: compact pushes it onto the Settings tab; regular
        // presents the Settings sheet already pushed to it (the sheet binds the
        // same `settingsPath`).
        if url.host?.lowercased() == "settings",
           url.pathComponents.count > 1,
           let leaf = SettingsLeaf(slug: url.pathComponents[1]) {
            settingsPath = [leaf]
            if isCompact {
                selectedTab = .settings
            } else {
                settingsSheetPresented = true
            }
            return
        }
        guard let route = Route.from(url: url) else { return }
        if case .conversation(let id) = route {
            // Like a notification: on top of the screen you are on.
            openSessionFromOutside(conversationID: id)
            return
        }
        if isCompact {
            selectedTab = .projects
            paths[.projects] = [route]
        } else {
            contentPath = []
            open(route)
        }
    }

    private func select(tab: AppTab) {
        if isCompact {
            selectedTab = tab
            return
        }
        switch tab {
        case .chats, .search: sidebarSection = .chats
        case .projects: sidebarSection = .projects
        case .activity: sidebarSection = .activity
        // Open Settings at its root (not whatever leaf a prior deep link left).
        case .settings: settingsPath = []; settingsSheetPresented = true
        }
    }

    /// Open a session a notification pointed at: switch to its server if
    /// needed, then open it on top of the screen you were on, so Back returns
    /// there (see `openSessionFromOutside`).
    func openFromPush(serverID: ServerProfile.ID, conversationID: Int) {
        guard serverStore.servers.contains(where: { $0.id == serverID }) else { return }
        if selectedServerID != serverID { selectedServerID = serverID }
        serversSheetPresented = false
        settingsSheetPresented = false
        openSessionFromOutside(conversationID: conversationID)
    }

    /// A session opened from outside the lists (a notification, a link). On
    /// iPhone it goes on the tab you are on, in place of any session open
    /// there, so Back returns to the list, folder or search you were looking
    /// at: usually Activity. From Settings, which has no sessions, it opens
    /// on Activity. On iPad it fills the detail column next to the list you
    /// were on.
    func openSessionFromOutside(conversationID: Int) {
        let route = Route.conversation(conversationID)
        lastOpenedConversationID = conversationID
        if isCompact {
            let tab: AppTab = selectedTab == .settings ? .activity : selectedTab
            var stack = paths[tab] ?? []
            if let first = stack.firstIndex(where: \.isSession) { stack.removeSubrange(first...) }
            stack.append(route)
            selectedTab = tab
            paths[tab] = stack
        } else {
            if sidebarSection == nil { sidebarSection = .activity }
            open(route)
        }
    }

    // MARK: - Chats list

    /// The Chats list's model for `server`, shared by the list and the
    /// group screens pushed from it.
    func sessionListModel(server: ServerProfile, client: CodegClient) -> SessionListViewModel {
        if let chatsList, chatsList.server == server.id { return chatsList.model }
        let model = SessionListViewModel(client: client)
        chatsList = (server.id, model)
        return model
    }

    // MARK: - Transcript cache

    /// Drop cached transcripts of servers that are gone or whose URL or token
    /// changed: each server's folder is named after its endpoint and token.
    func pruneTranscriptCache() {
        guard let cache = sessions.transcriptCache else { return }
        let clients = serverStore.servers.map { serverStore.client(for: $0) }
        // A token the Keychain can't give right now (a launch before the
        // first unlock) is not a changed token: keep everything until it can.
        guard !clients.contains(where: { $0 == nil }) else { return }
        let keep = Set(clients.compactMap { $0 }.map(TranscriptCache.serverKey(for:)))
        Task { await cache.removeServers(except: keep) }
    }

    /// Activity refreshed: cache the sessions that just finished a turn.
    private func activityRefreshed() {
        guard let client = selectedClient() else { return }
        prefetcher.activityRefreshed(client: client,
                                     shown: activity.running + activity.recent,
                                     excluding: sessions.heldConversationIDs)
    }

    // MARK: - Server-scoped resets

    /// Conversation, folder, and route identities are all endpoint-local.
    /// Dropped when the selected server changes…
    private func resetServerScopedState() {
        selectedConversationID = nil
        lastOpenedConversationID = nil
        pendingNewSession = nil
        paths = [:]
        settingsPath = []
        contentPath = []
        activity.reset()
        sessions.removeAll()
        prefetcher.reset()
        chatsList = nil
        AttentionStore.shared.clear()
    }

    /// …and when the selected server is edited in place (same UUID, new
    /// URL/token) — the old endpoint's IDs may not exist on the new one.
    func selectedServerEndpointChanged() {
        resetServerScopedState()
        pruneTranscriptCache()
    }
}
