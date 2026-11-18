import XCTest
@testable import Codeg

/// Activity's All Servers: every saved server's sessions in one feed, most
/// recent first; rows keyed by server and conversation (ids collide across
/// servers); a server that can't be reached keeps the others' rows and gets
/// a note; the choice and its default, remembered; a row on another server
/// selects that server and opens on Activity.
@MainActor
final class AllServersActivityTests: XCTestCase {
    private let now = Date()
    private let laptop = ServerProfile(name: "MacBook Pro", urlString: "http://laptop.test")
    private let studio = ServerProfile(name: "Mac Studio", urlString: "http://studio.test")

    private func session(_ id: Int, folder: Int = 1, minutesAgo: Double, running: Bool = false,
                         title: String? = nil) -> ConversationSummary {
        SampleSessions.decode(SampleSessions.Spec(
            id: id, folder: folder, title: title ?? "Session \(id)",
            status: running ? "in_progress" : "completed", minutesAgo: minutesAgo,
            turnState: running ? "running" : nil
        ), now: now)
    }

    private func json(_ sessions: [(id: Int, minutesAgo: Double, running: Bool)]) -> String {
        let items = sessions.map { item -> String in
            let updated = TranscriptTime.string(date: now.addingTimeInterval(-item.minutesAgo * 60))
            let status = item.running ? "in_progress" : "completed"
            let turn = item.running ? "\"running\"" : "null"
            return """
            {"id": \(item.id), "folder_id": 1, "title": "Session \(item.id)", "agent_type": "claude_code",
             "status": "\(status)", "message_count": 4, "created_at": "2026-11-01T08:00:00Z",
             "updated_at": "\(updated)", "turn_state": \(turn)}
            """
        }
        return "[" + items.joined(separator: ", ") + "]"
    }

    /// A server answering the list pulse with these sessions.
    private func listServer(_ sessions: [(id: Int, minutesAgo: Double, running: Bool)],
                            attention: String = "[]") -> MockCodegServer {
        let server = MockCodegServer()
        let body = json(sessions)
        server.on("list_all_conversations") { _ in .body(body) }
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body(attention) }
        server.on("list_folder_groups") { _ in .body("[]") }
        return server
    }

    /// Every list request fails as an unreachable host would (a laptop
    /// asleep).
    private func goDown(_ server: MockCodegServer) {
        for path in ["list_all_conversations", "list_open_folder_details", "list_all_folder_details",
                     "list_conversation_attention", "list_folder_groups"] {
            server.on(path) { _ in .fail(.cannotConnectToHost) }
        }
    }

    // MARK: - Merging

    func testEveryServersSessionsMergeMostRecentFirst() {
        let laptopPart = ActivityServerPart(
            server: laptop, isSelected: true,
            running: [session(1, minutesAgo: 2, running: true), session(2, minutesAgo: 30, running: true)],
            recent: [session(3, minutesAgo: 60), session(4, minutesAgo: 300)],
            earlier: [session(5, minutesAgo: 3_000)],
            folderNames: [1: "codeg"]
        )
        let studioPart = ActivityServerPart(
            server: studio,
            running: [session(10, minutesAgo: 10, running: true)],
            recent: [session(11, minutesAgo: 5), session(12, minutesAgo: 120)],
            earlier: [session(13, minutesAgo: 2_000), session(14, minutesAgo: 5_000)],
            folderNames: [1: "stalkrr"]
        )
        let feed = AllServersFeed.merge([laptopPart, studioPart])

        XCTAssertEqual(feed.running.map(\.conversation.id), [1, 10, 2])
        XCTAssertEqual(feed.recent.map(\.conversation.id), [11, 3, 12, 4])
        XCTAssertEqual(feed.earlier.map(\.conversation.id), [13, 5, 14])
        for rows in [feed.running, feed.recent, feed.earlier] {
            let times = rows.map(\.conversation.recency)
            XCTAssertEqual(times, times.sorted(by: >), "most recent first, whatever the server")
        }
        // Each row says where it is.
        XCTAssertEqual(feed.running.map(\.serverName), ["MacBook Pro", "Mac Studio", "MacBook Pro"])
        XCTAssertEqual(feed.recent.first?.folderName, "stalkrr", "a folder name from the row's own server")
        XCTAssertEqual(feed.running.first?.server, laptop.id)
        XCTAssertTrue(feed.hasLoaded)
        XCTAssertTrue(feed.notices.isEmpty)

        // The selected server's rows keep the app-wide attention and their
        // long-press actions; another server's don't.
        XCTAssertEqual(feed.running[0].attention, .shared)
        XCTAssertTrue(feed.running[0].offersSessionActions)
        XCTAssertEqual(feed.running[1].attention, .given(nil))
        XCTAssertFalse(feed.running[1].offersSessionActions)

        // A one-server feed has no captions.
        let single = ActivityRow.rows([session(1, minutesAgo: 2)], folderNames: [1: "codeg"])
        XCTAssertNil(single[0].serverName)
        XCTAssertNil(single[0].server)
    }

    func testCollidingConversationIDsStayApartByServer() {
        // Both servers have a conversation 302.
        let laptopPart = ActivityServerPart(
            server: laptop, isSelected: true,
            recent: [session(302, minutesAgo: 20, title: "Laptop's 302"), session(7, minutesAgo: 90)],
            attention: [302: "permission"]
        )
        let studioPart = ActivityServerPart(
            server: studio,
            recent: [session(302, minutesAgo: 40, title: "Studio's 302")],
            attention: [302: "question"]
        )
        let feed = AllServersFeed.merge([laptopPart, studioPart])
        let rows = feed.recent.filter { $0.conversation.id == 302 }
        XCTAssertEqual(rows.count, 2, "both sessions 302 are listed")
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "with keys of their own")
        XCTAssertEqual(rows.map(\.conversation.title), ["Laptop's 302", "Studio's 302"])
        XCTAssertEqual(rows.map(\.id), [ActivityRowKey(server: laptop.id, conversationID: 302),
                                        ActivityRowKey(server: studio.id, conversationID: 302)])

        // The feed's identities (ForEach, row animations, scroll anchors).
        let sections = ActivityFeedLayout.sections(running: feed.running, recent: feed.recent,
                                                   earlier: feed.earlier, newestAtBottom: true)
        let ids = sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count, "no two rows share an identity")
        XCTAssertEqual(ids.count, 3)

        // Only the selected server's 302 is the session opened last.
        let marked = ActivityRowKey(server: laptop.id, conversationID: 302)
        XCTAssertEqual(feed.recent.filter { $0.id == marked }.map(\.conversation.title), ["Laptop's 302"])

        // Each 302 reads what waits on the user from its own server: the
        // laptop's (selected) from the app-wide store, the studio's from its
        // own snapshot, never the other's.
        XCTAssertEqual(rows[0].attention, .shared)
        XCTAssertEqual(rows[1].attention, .given("question"))
    }

    // MARK: - A server down

    func testOneServerDownKeepsTheOthersRowsAndSaysWhichOne() async throws {
        let up = listServer([(id: 302, minutesAgo: 3, running: true), (id: 8, minutesAgo: 50, running: false)])
        let down = MockCodegServer()
        goDown(down)
        let selected = ActivityModel()
        await selected.refresh(client: up.client)
        let all = AllServersActivity()
        await all.refresh(others: [(id: studio.id, client: down.client)])

        let feed = all.feed(servers: [laptop, studio], selectedID: laptop.id, selected: selected)
        XCTAssertTrue(feed.hasLoaded, "one server down doesn't blank the feed")
        XCTAssertEqual(feed.running.map(\.conversation.id), [302])
        XCTAssertEqual(feed.recent.map(\.conversation.id), [8])
        XCTAssertEqual(feed.notices.map(\.serverName), ["Mac Studio"])
        XCTAssertNil(feed.notices.first?.lastRefreshed, "it never gave its lists")
        XCTAssertNil(feed.firstError)
        XCTAssertEqual(all.runningCount(servers: [laptop, studio], selectedID: laptop.id, selected: selected), 1)
        XCTAssertNil(AttentionStore.shared.kind(for: 302))
    }

    func testAServerThatWasUpGetsANoteOnlyOnceItsFailuresPersist() async throws {
        let laptopServer = listServer([(id: 1, minutesAgo: 2, running: true)])
        let studioServer = listServer([(id: 302, minutesAgo: 5, running: true), (id: 303, minutesAgo: 30, running: false)],
                                      attention: #"[{"conversation_id": 302, "kind": "permission"}]"#)
        let selected = ActivityModel()
        await selected.refresh(client: laptopServer.client)
        let all = AllServersActivity()
        let others = [(id: studio.id, client: studioServer.client)]
        await all.refresh(others: others)
        func feed() -> AllServersFeed { all.feed(servers: [laptop, studio], selectedID: laptop.id, selected: selected) }

        XCTAssertEqual(feed().running.map(\.conversation.id), [1, 302])
        XCTAssertEqual(all.runningCount(servers: [laptop, studio], selectedID: laptop.id, selected: selected), 2,
                       "the badge counts every server's running sessions")
        let studioRow = try XCTUnwrap(feed().running.first { $0.server == studio.id })
        XCTAssertEqual(studioRow.attention, .given("permission"), "its own attention snapshot")
        XCTAssertNil(AttentionStore.shared.kind(for: 302), "another server's attention stays out of the app-wide store")

        // The laptop goes to sleep: one failed pulse is a blip.
        goDown(studioServer)
        await all.refresh(others: others)
        XCTAssertTrue(feed().notices.isEmpty, "a single failure stays silent")
        XCTAssertEqual(feed().running.count, 2, "its last rows stay")

        // It persists (``ActivityModel/failuresBeforeAlerting``): a note, with
        // when its rows are from.
        await all.refresh(others: others)
        let notice = try XCTUnwrap(feed().notices.first)
        XCTAssertEqual(notice.serverName, "Mac Studio")
        XCTAssertNotNil(notice.lastRefreshed)
        XCTAssertEqual(feed().recent.map(\.conversation.id), [303], "the others' rows and its own last ones show")

        // Dismissed, it stays away while that failure lasts…
        all.dismiss(notice)
        await all.refresh(others: others)
        XCTAssertTrue(feed().notices.isEmpty)

        // …and comes back for the next one.
        let back = listServer([(id: 302, minutesAgo: 1, running: false)])
        await all.refresh(others: [(id: studio.id, client: back.client)])
        XCTAssertTrue(feed().notices.isEmpty)
        XCTAssertEqual(feed().running.map(\.conversation.id), [1])
        goDown(back)
        let againOthers = [(id: studio.id, client: back.client)]
        await all.refresh(others: againOthers)
        await all.refresh(others: againOthers)
        XCTAssertEqual(feed().notices.map(\.serverName), ["Mac Studio"])

        // Offline: the connection capsule speaks for every server, no notes.
        XCTAssertTrue(AllServersFeed.merge([ActivityServerPart(server: studio, failingSince: Date())],
                                           online: false).notices.isEmpty)
    }

    func testTheSelectedServerDownStillLeavesTheOthersRows() async throws {
        let down = MockCodegServer()
        goDown(down)
        let selected = ActivityModel()
        await selected.refresh(client: down.client)
        let studioServer = listServer([(id: 4, minutesAgo: 10, running: false)])
        let all = AllServersActivity()
        await all.refresh(others: [(id: studio.id, client: studioServer.client)])

        let feed = all.feed(servers: [laptop, studio], selectedID: laptop.id, selected: selected)
        XCTAssertTrue(feed.hasLoaded)
        XCTAssertEqual(feed.recent.map(\.conversation.id), [4])
        XCTAssertEqual(feed.notices.map(\.serverName), ["MacBook Pro"])
    }

    // MARK: - The choice

    func testTheDefaultChoiceDependsOnHowManyServersThereAre() {
        XCTAssertEqual(ActivityScope.resolve(saved: nil, serverCount: 1), .selectedServer)
        XCTAssertEqual(ActivityScope.resolve(saved: nil, serverCount: 2), .allServers)
        XCTAssertEqual(ActivityScope.resolve(saved: nil, serverCount: 3), .allServers)
        XCTAssertEqual(ActivityScope.resolve(saved: "server", serverCount: 2), .selectedServer)
        XCTAssertEqual(ActivityScope.resolve(saved: "all", serverCount: 2), .allServers)
        XCTAssertEqual(ActivityScope.resolve(saved: "all", serverCount: 1), .selectedServer,
                       "nothing to combine with one server")

        // The menu offers All Servers only with two or more.
        XCTAssertEqual(ActivityChoice.options(serverIDs: [laptop.id]), [.server(laptop.id)])
        XCTAssertEqual(ActivityChoice.options(serverIDs: [laptop.id, studio.id]),
                       [.allServers, .server(laptop.id), .server(studio.id)])
        XCTAssertEqual(ActivityChoice.current(scope: .allServers, selectedServerID: laptop.id), .allServers)
        XCTAssertEqual(ActivityChoice.current(scope: .selectedServer, selectedServerID: laptop.id), .server(laptop.id))

        let one = makeApp(servers: [laptop])
        XCTAssertFalse(one.activityShowsAllServers)
        XCTAssertEqual(one.activityChoice, .server(laptop.id))
        let two = makeApp(servers: [laptop, studio])
        XCTAssertTrue(two.activityShowsAllServers, "two servers and no choice yet: All Servers")
        XCTAssertEqual(two.activityChoice, .allServers)
    }

    func testTheChoiceIsRemembered() {
        let app = makeApp(servers: [laptop, studio])
        XCTAssertEqual(app.selectedServerID, laptop.id)

        // Picking a server selects it for the whole app, as Chats does.
        app.activityChoice = .server(studio.id)
        XCTAssertEqual(app.selectedServerID, studio.id)
        XCTAssertFalse(app.activityShowsAllServers)
        XCTAssertEqual(defaults.string(forKey: ActivityScope.defaultsKey), "server")
        let relaunched = makeApp(servers: [laptop, studio])
        XCTAssertFalse(relaunched.activityShowsAllServers, "the choice outlives the app")
        XCTAssertEqual(relaunched.selectedServerID, studio.id)

        relaunched.activityChoice = .allServers
        XCTAssertEqual(relaunched.selectedServerID, studio.id, "All Servers leaves the selection alone")
        XCTAssertTrue(makeApp(servers: [laptop, studio]).activityShowsAllServers)

        // An unknown server is no choice.
        relaunched.chooseActivity(.server(UUID()))
        XCTAssertTrue(relaunched.activityShowsAllServers)
    }

    // MARK: - Opening a row

    func testARowOnAnotherServerSelectsItAndBackReturnsToAllServers() {
        let app = makeApp(servers: [laptop, studio])
        app.selectedTab = .activity
        XCTAssertTrue(app.activityShowsAllServers)

        app.openActivityRow(ActivityRowKey(server: studio.id, conversationID: 302))
        XCTAssertEqual(app.selectedServerID, studio.id, "its server is selected first")
        XCTAssertEqual(app.selectedTab, .activity)
        XCTAssertEqual(app.paths[.activity], [.conversation(302)])
        XCTAssertEqual(app.markedConversationID, 302)

        // Back: the feed, still on All Servers.
        app.paths[.activity]?.removeLast()
        XCTAssertEqual(app.paths[.activity], [])
        XCTAssertTrue(app.activityShowsAllServers)

        // A row on the selected server just opens.
        app.openActivityRow(ActivityRowKey(server: studio.id, conversationID: 5))
        XCTAssertEqual(app.selectedServerID, studio.id)
        XCTAssertEqual(app.paths[.activity], [.conversation(5)])
    }

    func testOnIPadARowOnAnotherServerFillsTheDetailColumn() {
        let app = makeApp(servers: [laptop, studio], compact: false)
        app.sidebarSection = .activity
        app.openActivityRow(ActivityRowKey(server: studio.id, conversationID: 302))
        XCTAssertEqual(app.selectedServerID, studio.id)
        XCTAssertEqual(app.selectedConversationID, 302)
        XCTAssertEqual(app.sidebarSection, .activity)
        XCTAssertTrue(app.activityShowsAllServers)
    }

    // MARK: - Helpers

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "all-servers-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AttentionStore.shared.clear()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        AttentionStore.shared.clear()
    }

    private func makeApp(servers: [ServerProfile], compact: Bool = true) -> AppModel {
        defaults.set(try? JSONEncoder().encode(servers), forKey: ServerStore.storageKey)
        let store = ServerStore(defaults: defaults)
        let mock = MockCodegServer()
        store.clientFactory = { _ in mock.client }
        let app = AppModel(serverStore: store, defaults: defaults, transcriptCache: nil)
        app.setLayout(compact: compact, initial: true)
        return app
    }
}
