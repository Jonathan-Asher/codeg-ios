import XCTest
@testable import Codeg

/// The session lists saved for a start without a network (1.3.23): what is
/// saved and when it is rewritten, the size cap, what eviction leaves alone,
/// the protection of everything saved, and the Activity and Chats lists shown
/// from the saved copy until the network is back.
@MainActor
final class OfflineListsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static let folderJSON = """
    {"id": 1, "name": "codeg", "path": "/p/1", "git_branch": "main", "default_agent_type": null,
     "last_opened_at": "2026-09-01T08:00:00Z", "sort_order": 1, "color": "inherit", "parent_id": null,
     "kind": "regular"}
    """

    private static func summaryJSON(_ id: Int, minutesAgo: Double = 5, pinned: Bool = false) -> String {
        let updated = TranscriptTime.string(date: Date().addingTimeInterval(-minutesAgo * 60))
        let pin = pinned ? "\"\(updated)\"" : "null"
        return """
        {"id": \(id), "folder_id": 1, "title": "Session \(id)", "agent_type": "claude_code",
         "status": "pending_review", "message_count": 4, "created_at": "2026-09-01T08:00:00Z",
         "updated_at": "\(updated)", "turn_state": null, "pinned_at": \(pin)}
        """
    }

    private func summary(_ id: Int, minutesAgo: Double = 5, pinned: Bool = false) throws -> ConversationSummary {
        let json = Self.summaryJSON(id, minutesAgo: minutesAgo, pinned: pinned)
        return try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
    }

    private func folder() throws -> FolderDetail {
        try CodegJSON.decoder.decode(FolderDetail.self, from: Data(Self.folderJSON.utf8))
    }

    /// Lists with these sessions, session `n` updated `n` minutes ago.
    private func snapshot(_ ids: [Int]) throws -> SavedServerSnapshot {
        SavedServerSnapshot(
            folders: [try folder()], openFolders: [try folder()],
            conversations: try ids.map { try summary($0, minutesAgo: Double($0)) },
            groups: [FolderGroupDetail(id: 3, name: "Work", archived: true)],
            attention: [7: "permission"]
        )
    }

    private func transcript(_ id: Int) throws -> CachedTranscript {
        CachedTranscript(conversationID: id, savedAt: Date(), summary: try summary(id), selectorState: nil,
                         sessionStats: nil, folder: nil, turnsOffset: 0, prefixHash: nil, turnsTotal: 0,
                         turns: [])
    }

    /// A server whose list endpoints answer with these sessions.
    private func listServer(_ ids: [Int]) -> MockCodegServer {
        let server = MockCodegServer()
        let rows = ids.map { Self.summaryJSON($0) }.joined(separator: ", ")
        let folders = "[\(Self.folderJSON)]"
        server.on("list_all_conversations") { _ in .body("[\(rows)]") }
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("list_open_folder_details") { _ in .body(folders) }
        server.on("list_conversation_attention") { _ in .body("[]") }
        return server
    }

    private func fileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
    }

    /// Whether this device applies file protection at all (a simulator may not).
    private func platformAppliesProtection() throws -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = dir.appendingPathComponent("probe")
        try Data("x".utf8).write(to: probe, options: .completeFileProtection)
        return SavedFiles.protection(of: probe) == .complete
    }

    // MARK: - The saved lists

    func testTheListsComeBackWithTheDateTheServerGaveThem() async throws {
        let cache = ServerSnapshotCache(root: root)
        let savedAt = Date(timeIntervalSince1970: 1_791_000_000)
        let saved = await cache.save(try snapshot([1, 2, 3]), serverKey: "box", at: savedAt)
        XCTAssertTrue(saved)

        let loadedEntry = await cache.load(serverKey: "box")
        let loaded = try XCTUnwrap(loadedEntry)
        XCTAssertEqual(loaded.conversations.map(\.id), [1, 2, 3])
        XCTAssertEqual(loaded.folders.map(\.name), ["codeg"])
        XCTAssertEqual(loaded.openFolders?.map(\.id), [1])
        XCTAssertEqual(loaded.groups.first?.archived, true)
        XCTAssertEqual(loaded.attention, [7: "permission"])
        XCTAssertEqual(loaded.savedAt.timeIntervalSince1970, savedAt.timeIntervalSince1970, accuracy: 1)

        let other = await cache.load(serverKey: "another-server")
        XCTAssertNil(other)
    }

    func testUnchangedListsOnlyMoveTheirDate() async throws {
        let cache = ServerSnapshotCache(root: root)
        let lists = try snapshot([1, 2])
        let first = Date(timeIntervalSince1970: 1_791_000_000)
        await cache.save(lists, serverKey: "box", at: first)
        let file = await cache.file(serverKey: "box")
        let written = fileNumber(file)
        XCTAssertNotNil(written)

        // The 25-second pulse brings the same lists: the file isn't rewritten.
        await cache.save(lists, serverKey: "box", at: first.addingTimeInterval(600))
        XCTAssertEqual(fileNumber(file), written)
        let reloaded = await cache.load(serverKey: "box")
        XCTAssertEqual(reloaded?.savedAt.timeIntervalSince1970 ?? 0,
                       first.addingTimeInterval(600).timeIntervalSince1970, accuracy: 1)

        // Something changed: written again.
        await cache.save(try snapshot([1, 2, 3]), serverKey: "box", at: first.addingTimeInterval(700))
        XCTAssertNotEqual(fileNumber(file), written)
        let changed = await cache.load(serverKey: "box")
        XCTAssertEqual(changed?.conversations.count, 3)
    }

    func testListsOverTheCapKeepTheirNewestAndPinnedSessions() async throws {
        let cache = ServerSnapshotCache(root: root, capBytes: 4_000)
        var lists = try snapshot(Array(1...40))
        lists.conversations.append(try summary(99, minutesAgo: 9_999, pinned: true))
        let saved = await cache.save(lists, serverKey: "box")
        XCTAssertTrue(saved)

        let loaded = await cache.load(serverKey: "box")
        let ids = loaded?.conversations.map(\.id) ?? []
        XCTAssertFalse(ids.isEmpty)
        XCTAssertLessThan(ids.count, 41)
        XCTAssertTrue(ids.contains(99), "a pinned session is kept")
        XCTAssertTrue(ids.contains(1), "the newest is kept")
        XCTAssertFalse(ids.contains(40), "the oldest goes first")
        let file = await cache.file(serverKey: "box")
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? .max
        XCTAssertLessThanOrEqual(size, 4_000)
    }

    func testEvictionLeavesTheListsAloneAndRemovingAServerTakesThem() async throws {
        let lists = ServerSnapshotCache(root: root)
        // A cap so small every transcript is evicted at once.
        let transcripts = TranscriptCache(root: root, capBytes: 1)
        await lists.save(try snapshot([1]), serverKey: "box")
        await lists.save(try snapshot([2]), serverKey: "old-box")
        await transcripts.save(try transcript(5), serverKey: "box")

        let transcriptKept = await transcripts.contains(serverKey: "box", conversationID: 5)
        XCTAssertFalse(transcriptKept, "the transcript was evicted")
        let listsKept = await lists.load(serverKey: "box")
        XCTAssertNotNil(listsKept, "the lists never are")

        await transcripts.removeServers(except: ["box"])
        let removed = await lists.load(serverKey: "old-box")
        XCTAssertNil(removed, "a removed server's lists go with its folder")
        let kept = await lists.load(serverKey: "box")
        XCTAssertNotNil(kept)
    }

    // MARK: - File protection

    func testEverythingSavedIsUnreadableWhileThePhoneIsLocked() async throws {
        guard try platformAppliesProtection() else {
            throw XCTSkip("This device doesn't apply file protection")
        }
        let lists = ServerSnapshotCache(root: root)
        let transcripts = TranscriptCache(root: root)
        await lists.save(try snapshot([1]), serverKey: "box")
        await transcripts.save(try transcript(5), serverKey: "box")

        let folder = root.appendingPathComponent("box", isDirectory: true)
        let listsFile = await lists.file(serverKey: "box")
        for url in [root!, folder, listsFile, folder.appendingPathComponent("5.json")] {
            XCTAssertEqual(SavedFiles.protection(of: url), .complete, url.lastPathComponent)
        }
    }

    func testTranscriptsSavedBeforeGetProtected() async throws {
        guard try platformAppliesProtection() else {
            throw XCTSkip("This device doesn't apply file protection")
        }
        // What an earlier version saved, without protection.
        let folder = root.appendingPathComponent("box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("5.json")
        try Data("{}".utf8).write(to: old, options: .noFileProtection)
        XCTAssertNotEqual(SavedFiles.protection(of: old), .complete)

        // The first read of this launch protects what is there.
        let transcripts = TranscriptCache(root: root)
        _ = await transcripts.load(serverKey: "box", conversationID: 6)
        XCTAssertEqual(SavedFiles.protection(of: old), .complete)
        XCTAssertEqual(SavedFiles.protection(of: folder), .complete)
    }

    // MARK: - Lists shown from the saved copy

    func testActivityOpensOfflineFromTheSavedListsAndRefreshesWhenTheNetworkIsBack() async throws {
        let server = listServer([1, 2])
        let cache = ServerSnapshotCache(root: root)
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(NetworkPath(status: .satisfied, interfaces: ["wifi"]))

        // Online: the lists load and are saved.
        let first = ActivityModel()
        first.snapshotCache = cache
        first.connectivity = monitor
        await first.refresh(client: server.client)
        XCTAssertEqual(first.conversations.map(\.id).sorted(), [1, 2])
        XCTAssertNil(first.savedCopyDate)
        let key = TranscriptCache.serverKey(for: server.client)
        var saved: SavedServerSnapshot?
        for _ in 0..<100 where saved == nil {
            saved = await cache.load(serverKey: key)
            if saved == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(saved?.conversations.count, 2)

        // The next start has no network: the saved lists, with their date,
        // and no request that would only wait for one.
        monitor.apply(NetworkPath(status: .unsatisfied))
        let asked = server.calls("list_all_conversations").count
        let cold = ActivityModel()
        cold.snapshotCache = cache
        cold.connectivity = monitor
        await cold.refresh(client: server.client)
        XCTAssertTrue(cold.hasLoaded)
        XCTAssertNil(cold.error)
        XCTAssertEqual(cold.conversations.map(\.id).sorted(), [1, 2])
        XCTAssertNotNil(cold.savedCopyDate)
        XCTAssertEqual(cold.lastRefreshed, cold.savedCopyDate, "Activity's \"Updated …\" line shows its age")
        XCTAssertEqual(server.calls("list_all_conversations").count, asked)

        // The pulse waits for the network and refreshes the moment it is back.
        let pulse = Task { await cold.autoRefresh(client: server.client, interval: .seconds(60)) }
        defer { pulse.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.calls("list_all_conversations").count, asked, "nothing asked without a network")
        monitor.apply(NetworkPath(status: .satisfied, interfaces: ["cellular"]))
        let refreshed = await eventually { cold.savedCopyDate == nil }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(server.calls("list_all_conversations").count, asked + 1)
    }

    func testWithNothingSavedAnOfflineStartSaysSoAtOnce() async throws {
        let server = listServer([1])
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(NetworkPath(status: .unsatisfied))
        let activity = ActivityModel()
        activity.snapshotCache = ServerSnapshotCache(root: root)
        activity.connectivity = monitor
        await activity.refresh(client: server.client)
        XCTAssertFalse(activity.hasLoaded)
        XCTAssertEqual(activity.error, ActivityModel.offlineMessage)
        XCTAssertTrue(server.calls("list_all_conversations").isEmpty)
    }

    func testChatsShowTheSavedListsOfflineAndReloadWhenTheNetworkIsBack() async throws {
        let server = listServer([4, 5])
        let cache = ServerSnapshotCache(root: root)
        let savedAt = Date().addingTimeInterval(-3_600)
        await cache.save(try snapshot([4]), serverKey: TranscriptCache.serverKey(for: server.client), at: savedAt)
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(NetworkPath(status: .unsatisfied))

        let model = SessionListViewModel(client: server.client)
        model.useServices(snapshotCache: cache, connectivity: monitor, linkStatus: nil)
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.conversations.map(\.id), [4])
        XCTAssertEqual(model.savedCopyDate?.timeIntervalSince1970 ?? 0, savedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(model.lastLoadedAt, model.savedCopyDate)
        XCTAssertTrue(server.calls("list_all_conversations").isEmpty)

        monitor.apply(NetworkPath(status: .satisfied, interfaces: ["wifi"]))
        let reloaded = await eventually { model.savedCopyDate == nil }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(model.conversations.map(\.id).sorted(), [4, 5])
    }

    func testTheLastUpdatedLineSaysTheTimeOrTheDay() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 15))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 14, minute: 2))!
        XCTAssertEqual(LastUpdatedLine.text(for: earlier, now: now),
                       earlier.formatted(date: .omitted, time: .shortened))
        let yesterday = earlier.addingTimeInterval(-86_400)
        XCTAssertNotEqual(LastUpdatedLine.text(for: yesterday, now: now),
                          yesterday.formatted(date: .omitted, time: .shortened), "another day names the day")
    }
}
