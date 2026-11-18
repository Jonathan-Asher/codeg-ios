import Foundation
import Observation

// MARK: - The choice

/// Which servers the Activity feed shows: every saved server in one feed, or
/// the selected one (which the whole app follows).
enum ActivityScope: String, Sendable {
    case allServers = "all"
    case selectedServer = "server"

    /// Where the choice is remembered.
    static let defaultsKey = "codeg.activity.scope"

    /// The scope for a saved choice. With one server there is nothing to
    /// combine. With two or more and nothing chosen yet, All Servers.
    static func resolve(saved: String?, serverCount: Int) -> ActivityScope {
        guard serverCount > 1 else { return .selectedServer }
        return saved.flatMap(ActivityScope.init(rawValue:)) ?? .allServers
    }
}

/// An item of Activity's title menu.
enum ActivityChoice: Hashable, Sendable {
    case allServers
    case server(UUID)

    /// The menu's items in order: All Servers (only with two or more
    /// servers), then each saved server.
    static func options(serverIDs: [UUID]) -> [ActivityChoice] {
        let servers = serverIDs.map(ActivityChoice.server)
        return serverIDs.count > 1 ? [.allServers] + servers : servers
    }

    /// The item that carries the checkmark.
    static func current(scope: ActivityScope, selectedServerID: UUID?) -> ActivityChoice? {
        if scope == .allServers { return .allServers }
        return selectedServerID.map(ActivityChoice.server)
    }
}

// MARK: - Rows

/// A row's identity in a feed that can hold several servers. Conversation
/// ids are only unique on one server (two servers can both have a
/// conversation 302), so rows, the marked row and anything anchored on a row
/// are keyed by both.
struct ActivityRowKey: Hashable, Sendable {
    /// Nil in a one-server feed.
    let server: UUID?
    let conversationID: Int
}

/// One row of the Activity feed, as plain data (``ActivityFeed`` renders
/// sample sessions from it in tests and screenshots).
struct ActivityRow: Identifiable, Equatable {
    /// The server the session is on; nil in a one-server feed.
    let server: UUID?
    let conversation: ConversationSummary
    var folderName: String?
    /// All Servers only: the server's name, as a caption on the row.
    var serverName: String?
    /// Where the row reads what waits on the user: the selected server's
    /// app-wide store, or another server's own snapshot.
    var attention: SessionRowAttention = .shared
    /// The rows' long-press actions (fork, pin, move…) work on the selected
    /// server; another server's row offers only Open and Copy Title.
    var offersSessionActions = true

    var id: ActivityRowKey { ActivityRowKey(server: server, conversationID: conversation.id) }

    /// The rows of one server's feed.
    static func rows(_ conversations: [ConversationSummary], folderNames: [Int: String]) -> [ActivityRow] {
        conversations.map { ActivityRow(server: nil, conversation: $0, folderName: folderNames[$0.folderId]) }
    }
}

/// "Couldn't reach …" over the All Servers feed, for one server.
struct ActivityServerNotice: Identifiable, Equatable {
    let server: UUID
    let serverName: String
    /// When the server last gave its lists (its rows on screen are from
    /// then); nil when it never did.
    let lastRefreshed: Date?
    /// The failure this notice is about; dismissing it hides it until the
    /// server answers and fails again.
    let since: Date

    var id: UUID { server }
}

// MARK: - Merging

/// One server's part of the All Servers feed, as plain data.
struct ActivityServerPart {
    let server: ServerProfile
    /// The selected server's rows read attention from the app-wide store and
    /// keep their long-press actions.
    var isSelected = false
    var running: [ConversationSummary] = []
    var recent: [ConversationSummary] = []
    var earlier: [ConversationSummary] = []
    var folderNames: [Int: String] = [:]
    var attention: [Int: String] = [:]
    var hasLoaded = false
    var isRefreshing = false
    var error: String?
    var failingSince: Date?
    var lastRefreshed: Date?

    @MainActor
    init(server: ServerProfile, activity: ActivityModel, isSelected: Bool) {
        self.server = server
        self.isSelected = isSelected
        running = activity.running
        recent = activity.recent
        earlier = activity.earlier
        folderNames = activity.folderNames
        attention = activity.attention
        hasLoaded = activity.hasLoaded
        isRefreshing = activity.isRefreshing
        error = activity.error
        failingSince = activity.failingSince
        lastRefreshed = activity.lastRefreshed
    }

    /// Sample data (tests and screenshots).
    init(server: ServerProfile, isSelected: Bool = false, running: [ConversationSummary] = [],
         recent: [ConversationSummary] = [], earlier: [ConversationSummary] = [],
         folderNames: [Int: String] = [:], attention: [Int: String] = [:], hasLoaded: Bool = true,
         failingSince: Date? = nil, lastRefreshed: Date? = nil) {
        self.server = server
        self.isSelected = isSelected
        self.running = running
        self.recent = recent
        self.earlier = earlier
        self.folderNames = folderNames
        self.attention = attention
        self.hasLoaded = hasLoaded
        self.failingSince = failingSince
        self.lastRefreshed = lastRefreshed
    }
}

/// The All Servers feed: every server's Running, Last 24 Hours and Earlier
/// in one, most recent first as on one server, each row captioned with its
/// server.
struct AllServersFeed: Equatable {
    var running: [ActivityRow] = []
    var recent: [ActivityRow] = []
    /// Every older session; the feed lists a page at a time.
    var earlier: [ActivityRow] = []
    var notices: [ActivityServerNotice] = []
    /// Some server has given its lists (or its saved copy).
    var hasLoaded = false
    var isRefreshing = false
    /// Nothing loaded anywhere: the first server's error.
    var firstError: String?
    /// When the lists were last updated, the newest of the servers'.
    var lastRefreshed: Date?

    /// Combines the parts (in the saved servers' order). A server that
    /// fails keeps its last rows, and the others' show regardless; once its
    /// failure persists it gets a notice, unless that was dismissed
    /// (`dismissed`: the failure each dismissed notice was about) or the
    /// phone is offline (the connection capsule says so for all of them).
    static func merge(_ parts: [ActivityServerPart], dismissed: [UUID: Date] = [:], online: Bool = true) -> AllServersFeed {
        var feed = AllServersFeed()
        var order: [UUID: Int] = [:]
        for (index, part) in parts.enumerated() { order[part.server.id] = index }

        func rows(_ pick: (ActivityServerPart) -> [ConversationSummary]) -> [ActivityRow] {
            parts.flatMap { part in
                pick(part).map { conversation in
                    ActivityRow(
                        server: part.server.id,
                        conversation: conversation,
                        folderName: part.folderNames[conversation.folderId],
                        serverName: part.server.name,
                        attention: part.isSelected ? .shared : .given(part.attention[conversation.id]),
                        offersSessionActions: part.isSelected
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.conversation.recency != rhs.conversation.recency {
                    return lhs.conversation.recency > rhs.conversation.recency
                }
                let left = lhs.server.flatMap { order[$0] } ?? 0
                let right = rhs.server.flatMap { order[$0] } ?? 0
                if left != right { return left < right }
                return lhs.conversation.id > rhs.conversation.id
            }
        }

        feed.running = rows(\.running)
        feed.recent = rows(\.recent)
        feed.earlier = rows(\.earlier)
        feed.hasLoaded = parts.contains { $0.hasLoaded }
        feed.isRefreshing = parts.contains { $0.isRefreshing }
        feed.firstError = feed.hasLoaded ? nil : parts.lazy.compactMap(\.error).first
        feed.lastRefreshed = parts.compactMap(\.lastRefreshed).max()
        if online {
            feed.notices = parts.compactMap { part in
                guard let since = part.failingSince, dismissed[part.server.id] != since else { return nil }
                return ActivityServerNotice(server: part.server.id, serverName: part.server.name,
                                            lastRefreshed: part.hasLoaded ? part.lastRefreshed : nil, since: since)
            }
        }
        return feed
    }

}

// MARK: - The other servers' pulses

/// All Servers: a pulse for every saved server besides the selected one,
/// whose pulse stays ``AppModel/activity`` (the app-wide one that feeds the
/// Folders counts, the pending list and the rest, undisturbed). Each is an
/// ``ActivityModel`` of its own, with the same fetch, saved lists and
/// failure debounce, that keeps its attention to itself and leaves the
/// connection capsule to the selected server. They poll only while All
/// Servers is chosen and the app is in front (`run`, from RootView).
@MainActor
@Observable
final class AllServersActivity {
    /// The other servers' pulses, by server.
    private(set) var models: [UUID: ActivityModel] = [:]
    /// Dismissed notices: the failure each was about, by server.
    private(set) var dismissed: [UUID: Date] = [:]
    /// How many older sessions the feed lists (a page more each time).
    private(set) var earlierShown = 0

    @ObservationIgnored var snapshotCache: ServerSnapshotCache?
    @ObservationIgnored var connectivity: ConnectivityMonitor?

    /// The pulse of `serverID`, made on first use.
    func model(for serverID: UUID) -> ActivityModel {
        if let model = models[serverID] { return model }
        let model = ActivityModel()
        model.publishesAttention = false
        model.snapshotCache = snapshotCache
        model.connectivity = connectivity
        models[serverID] = model
        return model
    }

    /// Drop the pulses of servers that are gone or selected now.
    func keep(only serverIDs: Set<UUID>) {
        let gone = models.keys.filter { !serverIDs.contains($0) }
        for id in gone { models[id] = nil }
    }

    /// The feed: the selected server from `selected`, every other from its
    /// own pulse, in the saved servers' order. Read from a view's body, so
    /// it makes nothing: a server whose pulse hasn't started (or that has
    /// no token to start one) has nothing to show yet.
    func feed(servers: [ServerProfile], selectedID: UUID?, selected: ActivityModel) -> AllServersFeed {
        let parts = servers.map { server -> ActivityServerPart in
            if server.id == selectedID {
                return ActivityServerPart(server: server, activity: selected, isSelected: true)
            }
            if let model = models[server.id] {
                return ActivityServerPart(server: server, activity: model, isSelected: false)
            }
            return ActivityServerPart(server: server, hasLoaded: false)
        }
        return AllServersFeed.merge(parts, dismissed: dismissed, online: connectivity?.isOnline ?? true)
    }

    /// Running sessions on every server (the Activity tab's badge): the
    /// feed's Running rows, without building the feed.
    func runningCount(servers: [ServerProfile], selectedID: UUID?, selected: ActivityModel) -> Int {
        servers.reduce(0) { count, server in
            if server.id == selectedID { return count + selected.running.count }
            return count + (models[server.id]?.running.count ?? 0)
        }
    }

    /// Hide a server's notice until it answers and fails again.
    func dismiss(_ notice: ActivityServerNotice) {
        dismissed[notice.server] = notice.since
    }

    func showMoreEarlier(total: Int) {
        earlierShown = min(total, earlierShown + ActivityModel.earlierPage)
    }

    /// Polls every other server at the pulse's cadence until cancelled.
    /// Each one keeps its own pace, so a server that times out never holds
    /// the others back.
    func run(others: [(id: UUID, client: CodegClient)], interval: Duration = .seconds(25)) async {
        keep(only: Set(others.map(\.id)))
        let pulses = others.map { (model: model(for: $0.id), client: $0.client) }
        await withTaskGroup(of: Void.self) { group in
            for pulse in pulses {
                group.addTask { await pulse.model.autoRefresh(client: pulse.client, interval: interval) }
            }
        }
    }

    /// One refresh of every other server at once (pull to refresh).
    func refresh(others: [(id: UUID, client: CodegClient)]) async {
        let pulses = others.map { (model: model(for: $0.id), client: $0.client) }
        await withTaskGroup(of: Void.self) { group in
            for pulse in pulses {
                group.addTask { await pulse.model.refresh(client: pulse.client) }
            }
        }
    }
}
