import Foundation

/// Keeps the transcripts of Activity's sessions in `TranscriptCache` as they
/// finish turns, so opening one draws at once with nothing left to fetch.
///
/// After each Activity refresh it looks for sessions shown there (running or
/// touched in the last 24 hours) that just finished a turn: no longer
/// running, and either updated since the last refresh or running at the last
/// refresh. For each (a few per refresh, one at a time):
/// - one already cached gets only what changed (`TranscriptSync`), a few KB;
/// - one never opened gets its latest turns, but only on Wi-Fi or another
///   unmetered, unconstrained network, and only from a server known to send
///   windows, so this never pulls a whole transcript in the background.
/// The session on screen is skipped: its own screen keeps its cache entry.
@MainActor
final class TranscriptPrefetcher {
    private let cache: TranscriptCache?
    /// Each shown session's `updatedAt` at the last refresh, and whether it ran.
    private var lastSeen: [Int: (updatedAt: Date, live: Bool)] = [:]
    private var task: Task<Void, Never>?
    /// At most this many sessions per refresh.
    static let perRefresh = 4

    /// A session that can only reach the network on Wi-Fi (or Ethernet):
    /// iOS refuses its requests on cellular, a personal hotspot, or Low Data
    /// Mode.
    static let unmeteredSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.allowsExpensiveNetworkAccess = false
        cfg.allowsConstrainedNetworkAccess = false
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    init(cache: TranscriptCache?) {
        self.cache = cache
    }

    func reset() {
        task?.cancel()
        task = nil
        lastSeen = [:]
    }

    /// The sessions that just finished a turn, given Activity's latest list.
    /// The first sighting of a session only records it.
    func finished(shown: [ConversationSummary], excluding: Set<Int>) -> [Int] {
        var due: [Int] = []
        for conv in shown {
            let live = conv.status.isLive
            if let seen = lastSeen[conv.id], !live, !excluding.contains(conv.id),
               conv.updatedAt > seen.updatedAt || seen.live {
                due.append(conv.id)
            }
            lastSeen[conv.id] = (conv.updatedAt, live)
        }
        return due
    }

    func activityRefreshed(client: CodegClient, shown: [ConversationSummary], excluding: Set<Int>) {
        let due = finished(shown: shown, excluding: excluding)
        guard let cache, !due.isEmpty, task == nil else { return }
        let ids = Array(due.prefix(Self.perRefresh))
        let summaries = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        task = Task { [weak self] in
            await Self.prefetch(ids, summaries: summaries, client: client, cache: cache)
            self?.task = nil
        }
    }

    private static func prefetch(_ ids: [Int], summaries: [Int: ConversationSummary],
                                 client: CodegClient, cache: TranscriptCache) async {
        let key = TranscriptCache.serverKey(for: client)
        let serverHasWindows = TranscriptSync.windowedServers.contains(key)
        for id in ids {
            guard !Task.isCancelled else { return }
            if let entry = await cache.load(serverKey: key, conversationID: id) {
                // Only a window from a server with windows: an older server
                // would send the whole transcript.
                guard entry.prefixHash != nil,
                      let outcome = try? await TranscriptSync.fetch(client: client, id: id, held: entry.window,
                                                                    overlap: TranscriptSync.liveOverlap),
                      outcome.window.end >= entry.window.end || !outcome.continuesHeld
                else { continue }
                if outcome.window.prefixHash != nil { TranscriptSync.noteWindowed(serverKey: key) }
                await cache.save(Self.entry(id: id, outcome: outcome, folder: entry.folder), serverKey: key)
            } else if serverHasWindows || TranscriptSync.windowedServers.contains(key), summaries[id] != nil {
                let unmetered = CodegClient(baseURL: client.baseURL, token: client.token, session: unmeteredSession)
                guard let outcome = try? await TranscriptSync.fetch(client: unmetered, id: id, held: nil, overlap: 0),
                      outcome.window.prefixHash != nil
                else { continue }
                await cache.save(Self.entry(id: id, outcome: outcome, folder: nil), serverKey: key)
            }
        }
    }

    private static func entry(id: Int, outcome: TranscriptSync.Outcome, folder: FolderDetail?) -> CachedTranscript {
        CachedTranscript(
            conversationID: id, savedAt: Date(), summary: outcome.detail.summary,
            selectorState: outcome.detail.summary.selectorState, sessionStats: outcome.detail.sessionStats,
            folder: folder, turnsOffset: outcome.window.offset, prefixHash: outcome.window.prefixHash,
            turnsTotal: outcome.window.total, turns: outcome.window.turns
        )
    }
}
