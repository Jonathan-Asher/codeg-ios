import XCTest
@testable import Codeg

/// `codeg://` session links: read as the desktop reads them
/// (`deep_link::parse_deep_link`), their `server` matched against the saved
/// servers as the desktop matches it (`match_server`), and opened on that
/// server, or an alert saying why not.
@MainActor
final class SessionLinkTests: XCTestCase {
    private static let boxID = "0123456789abcdef"
    private static let boxURL = "http://johnnyss-macbook-pro.tailfa9991.ts.net:3080"

    private func session(_ ref: String, _ server: String?) -> SessionLink {
        .session(ref: ref, server: server)
    }

    // MARK: Reading a link

    func testASessionLinkMayNameItsServer() {
        XCTAssertEqual(SessionLink.parse("codeg://session/319?server=\(Self.boxID)"), session("319", Self.boxID))
        XCTAssertEqual(SessionLink.parse("codeg://session/319/?server=Johnnysclawd#top"),
                       session("319", "Johnnysclawd"))
        // `codeg:` without slashes, and the segment in another case.
        XCTAssertEqual(SessionLink.parse("codeg:SESSION/codex_AbC?server=box"), session("codex_AbC", "box"))
        XCTAssertEqual(SessionLink.parse("CODEG://session/42"), session("42", nil))
        // Read as `URLSearchParams` reads it: decoded, `+` a space, trimmed,
        // the first `server`, every other parameter ignored.
        for query in [
            "server=My%20Box",
            "server=My+Box",
            "server=+My+Box+",
            "utm_source=notes&server=My%20Box&x",
            "server=My%20Box&server=Other",
            "s%65rver=My%20Box",
        ] {
            XCTAssertEqual(SessionLink.parse("codeg://session/7?\(query)"), session("7", "My Box"), query)
        }
    }

    func testAnEmptyServerIsNoServer() {
        for raw in [
            "codeg://session/7?server=",
            "codeg://session/7?server=%20%20",
            "codeg://session/7?server",
            "codeg://session/7?",
            "codeg://session/7?Server=box",
        ] {
            XCTAssertEqual(SessionLink.parse(raw), session("7", nil), raw)
        }
    }

    func testWhatCanNameNoSessionIsNoLink() {
        for raw in [
            "codeg://session/7?server=box%07",
            "codeg://session/7?server=a%0Ab",
            "codeg://workspace?conversationId=7&server=%00",
            "codeg://session/7?server=\(String(repeating: "a", count: 256))",
            "codeg://session/../x?server=box",
            "codeg://session/?server=box",
            "codeg://session/a%2Fb",
            "codeg://agent/codex?server=box",
            "codeg://harness/install?ref=acme/pdf-tools&server=box",
            "codeg://open",
            "codeg://",
            "codegplus://conversation/7",
            "https://example.com/session/7",
        ] {
            XCTAssertNil(SessionLink.parse(raw), raw)
        }
        let longest = String(repeating: "a", count: 255)
        XCTAssertEqual(SessionLink.parse("codeg://session/7?server=\(longest)"), session("7", longest))
    }

    func testAWorkspaceLinkMayNameItsServer() {
        XCTAssertEqual(
            SessionLink.parse("codeg://workspace?conversationId=9&folderId=3&agent=grok&server=\(Self.boxID)"),
            .workspace(conversationID: 9, folderID: 3, agent: "grok", server: Self.boxID)
        )
        XCTAssertEqual(SessionLink.parse("codeg://workspace?conversation_id=9"),
                       .workspace(conversationID: 9, folderID: nil, agent: nil, server: nil))
        XCTAssertNil(SessionLink.parse("codeg://workspace?server=box"), "still needs a conversation")
        XCTAssertNil(SessionLink.parse("codeg://workspace?conversationId=0"))
        let link = SessionLink.workspace(conversationID: 9, folderID: 3, agent: "grok", server: nil)
        XCTAssertEqual(link.lookup.ref, "9")
        XCTAssertEqual(link.lookup.folderID, 3)
        XCTAssertEqual(link.lookup.agent, "grok")
    }

    // MARK: Which server

    private let staging = UUID()
    private let box = UUID()

    private var servers: [SessionLinkServer] {
        [
            SessionLinkServer(id: staging, name: "Staging", baseURL: URL(string: "https://staging.example.com"),
                              identity: nil),
            SessionLinkServer(id: box, name: "Johnnysclawd", baseURL: URL(string: Self.boxURL),
                              identity: ServerIdentity(instanceId: Self.boxID, instanceName: "Johnnyss-MacBook-Pro",
                                                       imagePreviews: 1, urlString: Self.boxURL)),
        ]
    }

    func testAServerIsMatchedByIdNameOrHost() {
        let cases: [(String, UUID?)] = [
            // The instance id it gave, any case.
            (Self.boxID, box),
            (Self.boxID.uppercased(), box),
            // The name it was saved under, any case.
            ("Johnnysclawd", box),
            ("johnnysCLAWD", box),
            (" Johnnysclawd ", box),
            ("staging", staging),
            // Its host: alone, with the port, or as the URL.
            ("johnnyss-macbook-pro.tailfa9991.ts.net", box),
            ("Johnnyss-MacBook-Pro.tailfa9991.ts.net:3080", box),
            ("http://johnnyss-macbook-pro.tailfa9991.ts.net:3080/", box),
            ("https://johnnyss-macbook-pro.tailfa9991.ts.net:3080", box),
            ("staging.example.com", staging),
            ("https://staging.example.com:443", staging),
            // The name the instance gives itself.
            ("Johnnyss-MacBook-Pro", box),
            // Nothing that only looks close.
            ("johnnyss-macbook-pro.tailfa9991.ts.net:3081", nil),
            ("http://johnnyss-macbook-pro.tailfa9991.ts.net/", nil),
            ("johnnyss", nil),
            ("0123456789abcde", nil),
            ("somewhere-else", nil),
            ("", nil),
        ]
        for (wanted, expected) in cases {
            XCTAssertEqual(SessionLinkMatch.server(wanted, in: servers), expected, wanted)
        }
    }

    /// An instance id outranks every name, and a saved name outranks the
    /// name an instance gives itself.
    func testWhatIdentifiesAServerOutrightWins() {
        let mac = UUID()
        let named = [
            // Saved under the box's instance id, by hand.
            SessionLinkServer(id: mac, name: Self.boxID, baseURL: URL(string: "http://mac.local:3080"), identity: nil),
            SessionLinkServer(id: box, name: "Box", baseURL: URL(string: Self.boxURL),
                              identity: ServerIdentity(instanceId: Self.boxID, instanceName: "Staging",
                                                       urlString: Self.boxURL)),
            SessionLinkServer(id: staging, name: "Staging", baseURL: URL(string: "https://staging.example.com"),
                              identity: nil),
        ]
        XCTAssertEqual(SessionLinkMatch.server(Self.boxID, in: named), box)
        XCTAssertEqual(SessionLinkMatch.server("staging", in: named), staging)
        // The first of two servers with one name.
        let twins = [
            SessionLinkServer(id: box, name: "Box", baseURL: nil, identity: nil),
            SessionLinkServer(id: staging, name: "box", baseURL: nil, identity: nil),
        ]
        XCTAssertEqual(SessionLinkMatch.server("BOX", in: twins), box)
        // Without what it said about itself, an id matches nothing.
        XCTAssertNil(SessionLinkMatch.server(Self.boxID, in: [
            SessionLinkServer(id: box, name: "Box", baseURL: URL(string: Self.boxURL), identity: nil),
        ]))
    }

    func testWhatAServerSaidIsKeptForItsAddressOnly() {
        let suite = "identities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var profile = ServerProfile(name: "Box", urlString: Self.boxURL)
        let store = ServerIdentityStore(defaults: defaults)
        store.record(HealthResponse(status: "ok", version: "0.46.1", instanceId: Self.boxID,
                                    instanceName: " ", imagePreviews: 1), for: profile)
        XCTAssertEqual(store.identity(for: profile)?.instanceId, Self.boxID)
        XCTAssertNil(store.identity(for: profile)?.instanceName, "a blank name is no name")
        // Kept across launches.
        XCTAssertEqual(ServerIdentityStore(defaults: defaults).identity(for: profile)?.imagePreviews, 1)
        // Moved to another address: asked again.
        profile.urlString = "http://elsewhere:3080"
        XCTAssertNil(store.identity(for: profile))
        // Removed: forgotten.
        store.prune(keeping: [])
        XCTAssertNil(ServerIdentityStore(defaults: defaults).identity(for: ServerProfile(
            id: profile.id, name: "Box", urlString: Self.boxURL)))
    }

    // MARK: Opening a link

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "session-links-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private let mac = ServerProfile(name: "Mac", urlString: "http://jonathans-macbook.local:3080")
    private let theBox = ServerProfile(name: "Johnnysclawd", urlString: SessionLinkTests.boxURL)

    /// The Mac shown, the box saved second; each with its own mock server.
    private func makeApp(macServer: MockCodegServer, boxServer: MockCodegServer) -> AppModel {
        defaults.set(try? JSONEncoder().encode([mac, theBox]), forKey: ServerStore.storageKey)
        let store = ServerStore(defaults: defaults)
        let macID = mac.id
        store.clientFactory = { profile in profile.id == macID ? macServer.client : boxServer.client }
        let app = AppModel(serverStore: store, defaults: defaults, transcriptCache: nil)
        app.setLayout(compact: true, initial: true)
        app.selectedServerID = mac.id
        app.selectedTab = .activity
        return app
    }

    private static func health(id: String, name: String) -> MockCodegServer.Reply {
        .body(#"{"status":"ok","version":"0.46.1-fork.248","instanceId":"\#(id)","instanceName":"\#(name)","imagePreviews":1}"#)
    }

    func testALinkNamingAnotherServerByItsIdOpensTheSessionThere() async throws {
        let macServer = MockCodegServer()
        let boxServer = MockCodegServer()
        macServer.on("health") { _ in Self.health(id: "fedcba9876543210", name: "Jonathans-MacBook-Pro") }
        boxServer.on("health") { _ in Self.health(id: Self.boxID, name: "Johnnyss-MacBook-Pro") }
        boxServer.on("resolve_session_link") { call in
            call.body["sessionRef"] as? String == "319"
                ? .body(#"{"folderId":3,"conversationId":319,"agent":"claude_code"}"#)
                : .body("null")
        }
        let app = makeApp(macServer: macServer, boxServer: boxServer)

        // Nothing matched at first: both servers were asked who they are.
        await app.openSessionLink(try XCTUnwrap(URL(string: "codeg://session/319?server=\(Self.boxID)")))
        XCTAssertEqual(app.selectedServerID, theBox.id)
        XCTAssertEqual(app.paths[app.selectedTab]?.last, .conversation(319))
        XCTAssertNil(app.actions.alert)
        XCTAssertEqual(boxServer.calls("health").count, 1)
        XCTAssertEqual(app.serverIdentities.identity(for: theBox)?.instanceId, Self.boxID)

        // Learned: the next link goes straight to the lookup.
        app.selectedServerID = mac.id
        await app.openSessionLink(try XCTUnwrap(URL(string: "codeg://session/319?server=\(Self.boxID)")))
        XCTAssertEqual(app.selectedServerID, theBox.id)
        XCTAssertEqual(boxServer.calls("health").count, 1, "not asked again")
    }

    func testALinkWithoutAServerUsesTheOneShown() async throws {
        let macServer = MockCodegServer()
        let boxServer = MockCodegServer()
        macServer.on("resolve_session_link") { _ in .body(#"{"folderId":1,"conversationId":12,"agent":"codex"}"#) }
        let app = makeApp(macServer: macServer, boxServer: boxServer)
        await app.openSessionLink(try XCTUnwrap(URL(string: "codeg://session/thread_abc")))
        XCTAssertEqual(app.selectedServerID, mac.id)
        XCTAssertEqual(app.paths[app.selectedTab]?.last, .conversation(12))
        XCTAssertEqual(macServer.calls("resolve_session_link").first?.body["sessionRef"] as? String, "thread_abc")
        XCTAssertTrue(boxServer.calls("resolve_session_link").isEmpty)
    }

    func testAMissingSessionSaysSo() async throws {
        let macServer = MockCodegServer()
        let boxServer = MockCodegServer()
        let app = makeApp(macServer: macServer, boxServer: boxServer)
        // The box saved as "Johnnysclawd": matched by name, no probe needed.
        await app.openSessionLink(try XCTUnwrap(URL(string: "codeg://session/999?server=johnnysclawd")))
        XCTAssertEqual(app.actions.alert?.title, String(localized: "Session Not Found"))
        XCTAssertEqual(app.selectedServerID, mac.id, "stays where it was")
        XCTAssertNil(app.paths[app.selectedTab]?.last)
        XCTAssertTrue(boxServer.calls("health").isEmpty)
    }

    func testAnUnknownServerSaysSo() async throws {
        let macServer = MockCodegServer()
        let boxServer = MockCodegServer()
        macServer.on("health") { _ in Self.health(id: "fedcba9876543210", name: "Jonathans-MacBook-Pro") }
        boxServer.on("health") { _ in Self.health(id: Self.boxID, name: "Johnnyss-MacBook-Pro") }
        let app = makeApp(macServer: macServer, boxServer: boxServer)
        await app.openSessionLink(try XCTUnwrap(URL(string: "codeg://session/5?server=office-server")))
        XCTAssertEqual(app.actions.alert?.title, String(localized: "Unknown Server"))
        XCTAssertTrue(app.actions.alert?.message.contains("office-server") ?? false)
        XCTAssertNil(app.paths[app.selectedTab]?.last)
    }

    func testAServerFromBeforeSessionLinksOpensCodegsOwnId() async throws {
        let macServer = MockCodegServer()
        let boxServer = MockCodegServer()
        boxServer.on("resolve_session_link") { _ in
            .status(501, #"{"code":"not_implemented","message":"API endpoint 'resolve_session_link' is not available"}"#)
        }
        let app = makeApp(macServer: macServer, boxServer: boxServer)
        await app.openSessionLink(try XCTUnwrap(URL(string: "codeg://workspace?conversationId=44&server=Johnnysclawd")))
        XCTAssertEqual(app.selectedServerID, theBox.id)
        XCTAssertEqual(app.paths[app.selectedTab]?.last, .conversation(44))
    }

    func testTheAppOpensCodegLinksFromOutside() async throws {
        let macServer = MockCodegServer()
        let boxServer = MockCodegServer()
        macServer.on("resolve_session_link") { _ in .body(#"{"folderId":1,"conversationId":8,"agent":"codex"}"#) }
        let app = makeApp(macServer: macServer, boxServer: boxServer)
        app.handle(url: try XCTUnwrap(URL(string: "codeg://session/8")))
        let opened = await eventually { app.paths[app.selectedTab]?.last == .conversation(8) }
        XCTAssertTrue(opened)
        // The app's own links still work as before.
        app.handle(url: try XCTUnwrap(URL(string: "\(AppIdentity.urlScheme)://conversation/42")))
        XCTAssertEqual(app.paths[app.selectedTab]?.last, .conversation(42))
    }
}
