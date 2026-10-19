import Foundation
import Observation

/// App-wide pulse of the selected server: a periodically refreshed snapshot of
/// its folders + conversations, from which the Activity tab, the bottom
/// "running" bar, the sidebar badge, and the Folders tab's running counts are
/// all derived.
///
/// This is the poll-based stand-in for the future persistent-WebSocket hub
/// (M4 in the redesign plan): the consumers are already shaped for live data,
/// only this data source swaps later.
@MainActor
@Observable
final class ActivityModel {
    private(set) var conversations: [ConversationSummary] = []
    /// The full folder set (`list_all_folder_details`) — for by-id lookups
    /// (`folderNames`, a conversation's folder by id, incl. worktree/chat folders).
    private(set) var folders: [FolderDetail] = []
    /// The workspace-visible folder set (`list_open_folder_details`, open+regular).
    /// The Folders tab renders `displayFolders` derived from this; running counts
    /// and per-folder conversation lists merge worktree children into their root.
    private(set) var openFolders: [FolderDetail] = []
    /// Whether `openFolders` has been fetched successfully at least once. Until it
    /// has, the display falls back to the full set; once it has, an empty result is
    /// respected (the server genuinely has no open folders) rather than re-falling
    /// back. Distinguishes a failed open-folders fetch from a legitimately empty one.
    private var openFoldersLoaded = false
    /// The desktop folder groups, read only for their archive flags (a folder in
    /// an archived group is archived). Kept across a failed fetch.
    private(set) var groups: [FolderGroupDetail] = []
    private(set) var lastRefreshed: Date?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false

    /// Monotonic token so a slow fetch can't clobber a newer one's results
    /// (also bumped by `reset()` to invalidate in-flight fetches).
    private var fetchGeneration = 0
    private var loadedEndpoint: String?

    /// Consecutive polls where *both* endpoints failed (after retries). Debounces
    /// the error banner so a single blip in the 25s pulse doesn't flash an error
    /// over an otherwise-fine list; the banner shows only once it persists.
    private var consecutiveFailures = 0
    private static let failuresBeforeAlerting = 2

    // MARK: - Derived

    /// Sessions currently running, most recently updated first: an open
    /// turn, or work in the background (tasks running after the turn ended,
    /// the agent running a turn of its own, a turn held open) — see
    /// ``ConversationSummary/isRunningForLists``.
    var running: [ConversationSummary] {
        conversations.filter { $0.isRunningForLists }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Non-running sessions touched in the last 24 hours, most recent first.
    /// Sessions of archived folders are left out (see ``FolderArchive``); a
    /// running one still shows in ``running``.
    var recent: [ConversationSummary] {
        let cutoff = Self.recentCutoff()
        let archived = archivedFolderIDs
        return conversations.filter {
            !$0.isRunningForLists && $0.updatedAt >= cutoff && !archived.contains($0.folderId)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Non-running sessions last touched before the last 24 hours, most
    /// recent first. Activity lists them only on demand ("Earlier"). Archived
    /// folders' sessions are left out here too.
    var earlier: [ConversationSummary] {
        let cutoff = Self.recentCutoff()
        let archived = archivedFolderIDs
        return conversations.filter {
            !$0.isRunningForLists && $0.updatedAt < cutoff && !archived.contains($0.folderId)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// How many of `earlier` Activity shows: none until asked, then a page
    /// more each time. Kept here (not in the view) so it survives opening a
    /// session and coming back, and resets with the server.
    private(set) var earlierShown = 0
    static let earlierPage = 20

    func showMoreEarlier() {
        earlierShown = min(earlier.count, earlierShown + Self.earlierPage)
    }

    private static func recentCutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-24 * 3600)
    }

    /// Called after each refresh that loaded the list (the transcript
    /// prefetcher looks for sessions that just finished a turn).
    @ObservationIgnored var onRefreshed: (@MainActor () -> Void)?

    /// The folder set the display + grouping derive from: the open set normally,
    /// but the FULL set as a fallback when the open-folders endpoint failed while
    /// the full one succeeded — so the Folders tab / grouping degrade to showing
    /// everything (still hiding chat + worktree children) rather than going empty.
    private var displaySource: [FolderDetail] { openFoldersLoaded ? openFolders : folders }

    /// Worktree-child folder id → root id, over `displaySource`. Computed so it
    /// always tracks the rendered folder set (never goes stale vs `conversations`).
    var childToParent: [Int: Int] { FolderVisibility.childToParent(displaySource) }

    /// Folders shown as rows in the Folders tab: open + regular, with worktree
    /// children of an open root hidden (their sessions fold into the root). Sorted
    /// by the view.
    var displayFolders: [FolderDetail] {
        FolderVisibility.visibleFolders(displaySource)
    }

    /// The archived folders among the displayed set: on their own, through an
    /// archived desktop group, or a worktree through its repo. Empty against a
    /// server that predates archiving, so everything behaves as before.
    var archivedFolderIDs: Set<Int> {
        FolderArchive.archivedIDs(folders: displaySource, groups: groups, childToParent: childToParent)
    }

    /// Whether the server knows about archiving (it sent the flag).
    var archiveSupported: Bool { FolderArchive.isSupported(folders) || FolderArchive.isSupported(openFolders) }

    /// What a folder's menu offers (Archive, Unarchive, Unarchive Group, or
    /// nothing on an older server).
    func archiveState(of folder: FolderDetail) -> FolderArchive.State {
        FolderArchive.state(of: folder, groups: groups, supported: archiveSupported)
    }

    /// The desktop group a folder sits in, if the server sent it.
    func group(of folder: FolderDetail) -> FolderGroupDetail? {
        folder.groupId.flatMap { id in groups.first { $0.id == id } }
    }

    /// `folderId -> name` lookup for row labels — over the FULL set so a worktree
    /// or chat folder id still resolves.
    var folderNames: [Int: String] {
        Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Running-session count per folder, for the Projects tab's badges. A root
    /// folder's count includes its (hidden) worktree children's running sessions,
    /// matching the web's merged grouping.
    func runningCount(folderID: Int) -> Int {
        conversations.lazy.filter {
            FolderVisibility.mergedFolderId($0.folderId, childToParent: self.childToParent) == folderID
                && $0.isRunningForLists
        }.count
    }

    /// Conversations in one folder (worktree children merged into the root), most
    /// recent first (Project detail reuses the already-loaded snapshot instead of
    /// refetching).
    func conversations(in folderID: Int) -> [ConversationSummary] {
        conversations.filter {
            FolderVisibility.mergedFolderId($0.folderId, childToParent: childToParent) == folderID
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Lifecycle

    /// Drop everything (server switched / removed). Also invalidates any fetch
    /// still in flight against the old endpoint.
    func reset() {
        fetchGeneration += 1
        conversations = []
        folders = []
        openFolders = []
        openFoldersLoaded = false
        groups = []
        hasLoaded = false
        isRefreshing = false
        error = nil
        lastRefreshed = nil
        loadedEndpoint = nil
        consecutiveFailures = 0
        earlierShown = 0
    }

    /// Clears a surfaced refresh-error banner (a failed refresh over a list that
    /// still has rows). The next refresh also clears it.
    func dismissError() { error = nil }

    /// One fetch against the given client. Endpoint changes clear stale data
    /// first so a slow old server's rows never show under a new server's name.
    /// Show a critical mark at once, before the server confirms it (the next
    /// refresh brings the server's own).
    func setCriticalLocally(_ conversationID: Int, _ critical: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].critical = critical
    }

    func refresh(client: CodegClient?) async {
        guard let client else {
            reset()
            return
        }
        let endpoint = "\(client.baseURL.absoluteString)|\(client.token)"
        if endpoint != loadedEndpoint {
            reset()
            loadedEndpoint = endpoint
        }
        fetchGeneration += 1
        let token = fetchGeneration
        isRefreshing = true
        defer { if token == fetchGeneration { isRefreshing = false } }

        let result = await client.loadServerSnapshot()
        guard token == fetchGeneration else { return }
        if result.cancelled { return }

        // Partial success: apply whichever endpoint returned, keep the prior value
        // for one that failed (orphaned rows fall into the "Other" safety net).
        if let loaded = result.folders { folders = loaded }
        if let loaded = result.openFolders { openFolders = loaded; openFoldersLoaded = true }
        if let loaded = result.conversations { conversations = loaded }
        if let loaded = result.groups { groups = loaded }
        AttentionStore.shared.update(result.attention)

        if result.anySucceeded {
            hasLoaded = true
            error = nil
            lastRefreshed = Date()
            consecutiveFailures = 0
            if result.conversations != nil { onRefreshed?() }
        } else {
            // Both failed after retries. Debounce so a lone blip in the periodic
            // pulse stays silent; surface it once it persists (or on first load,
            // where there's nothing on screen yet).
            consecutiveFailures += 1
            if !hasLoaded || consecutiveFailures >= Self.failuresBeforeAlerting {
                error = result.message
            }
        }
    }

    // MARK: - Archive

    /// Archive or unarchive one folder. The change shows at once and is put
    /// back if the server refuses it (the error is rethrown for the view to
    /// show). Presentational only: the folder stays open, its sessions are
    /// untouched, and a running one keeps running.
    func setArchived(folderID: Int, archived: Bool, client: CodegClient?) async throws {
        guard let client else { return }
        let previousFolders = folders
        let previousOpen = openFolders
        folders = Self.patch(folders, id: folderID, archived: archived)
        openFolders = Self.patch(openFolders, id: folderID, archived: archived)
        do {
            try await client.setFolderArchived(folderId: folderID, archived: archived)
        } catch {
            folders = previousFolders
            openFolders = previousOpen
            throw error
        }
        NotificationCenter.default.post(name: .foldersDidChange, object: nil)
    }

    /// Archive or unarchive a desktop folder group, every folder in it
    /// following. Same optimistic shape as ``setArchived(folderID:archived:client:)``.
    func setGroupArchived(groupID: Int, archived: Bool, client: CodegClient?) async throws {
        guard let client else { return }
        let previous = groups
        groups = groups.map { group in
            guard group.id == groupID else { return group }
            var next = group
            next.archived = archived
            return next
        }
        do {
            try await client.setFolderGroupArchived(groupId: groupID, archived: archived)
        } catch {
            groups = previous
            throw error
        }
        NotificationCenter.default.post(name: .foldersDidChange, object: nil)
    }

    private static func patch(_ list: [FolderDetail], id: Int, archived: Bool) -> [FolderDetail] {
        list.map { folder in
            guard folder.id == id else { return folder }
            var next = folder
            next.archived = archived
            return next
        }
    }

    /// Long-running refresh loop — run from a SwiftUI `.task(id:)` so it is
    /// cancelled and restarted with the scene phase and server identity.
    func autoRefresh(client: CodegClient?, interval: Duration = .seconds(25)) async {
        while !Task.isCancelled {
            await refresh(client: client)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
