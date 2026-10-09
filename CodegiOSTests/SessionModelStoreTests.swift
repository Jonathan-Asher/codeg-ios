import XCTest
@testable import Codeg

/// The session screens' models live above the navigation containers: a
/// screen rebuilt around a session (a layout change, a tab switched back)
/// gets the same model, and its sockets close only once no screen has held
/// it for a moment.
@MainActor
final class SessionModelStoreTests: XCTestCase {
    private var server: MockCodegServer!
    private var store: SessionModelStore!
    private let profile = ServerProfile(name: "Box", urlString: "http://box.test")

    override func setUp() async throws {
        server = MockCodegServer()
        store = SessionModelStore()
        store.transcriptCache = nil
        store.grace = .milliseconds(60)
    }

    override func tearDown() async throws {
        store.removeAll()
        store = nil
        server = nil
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    func testTheSameSessionGetsTheSameModel() {
        let client = server.client
        let first = store.model(server: profile, client: client, conversationID: 7)
        let again = store.model(server: profile, client: client, conversationID: 7)
        XCTAssertIdentical(first, again)
        XCTAssertNotIdentical(first, store.model(server: profile, client: client, conversationID: 8))
        // A new token is a new endpoint: a new model, never a stale client.
        let rotated = CodegClient(baseURL: client.baseURL, token: "another-token", session: MockCodegServer.session)
        XCTAssertNotIdentical(first, store.model(server: profile, client: rotated, conversationID: 7))
    }

    func testAScreenRebuiltAroundTheSessionKeepsItLive() async {
        let client = server.client
        let model = store.model(server: profile, client: client, conversationID: 7)
        let lease = store.lease(server: profile, client: client, target: .conversation(7))
        let old = UUID(), new = UUID()
        lease.acquire(old)
        // The old screen goes, the new one comes up a moment later.
        lease.release(old)
        try? await Task.sleep(for: .milliseconds(20))
        lease.acquire(new)
        await settle()
        XCTAssertFalse(model.isSuspended, "never closed in between")
        XCTAssertEqual(store.heldConversationIDs, [7])

        // The new screen appearing before the old one goes is fine too.
        let third = UUID()
        lease.acquire(third)
        lease.release(new)
        await settle()
        XCTAssertFalse(model.isSuspended)
    }

    func testASessionNoScreenShowsIsSuspendedAndResumesWhenShownAgain() async {
        let client = server.client
        let model = store.model(server: profile, client: client, conversationID: 7)
        let lease = store.lease(server: profile, client: client, target: .conversation(7))
        let screen = UUID()
        lease.acquire(screen)
        lease.release(screen)
        await settle()
        XCTAssertTrue(model.isSuspended, "its sockets closed once nothing showed it")
        XCTAssertTrue(store.heldConversationIDs.isEmpty)

        XCTAssertIdentical(store.model(server: profile, client: client, conversationID: 7), model,
                           "kept, so opening it again is instant")
        lease.acquire(UUID())
        await settle()
        XCTAssertFalse(model.isSuspended)
    }

    func testOnlyTheMostRecentSuspendedSessionsAreKept() async {
        let client = server.client
        var models: [SessionDetailViewModel] = []
        for id in 1...(SessionModelStore.keepSuspended + 3) {
            models.append(store.model(server: profile, client: client, conversationID: id))
            let lease = store.lease(server: profile, client: client, target: .conversation(id))
            let screen = UUID()
            lease.acquire(screen)
            lease.release(screen)
            try? await Task.sleep(for: .milliseconds(5))
        }
        await settle()
        XCTAssertNil(store.existingModel(conversationID: 1), "the oldest were let go")
        XCTAssertNotNil(store.existingModel(conversationID: SessionModelStore.keepSuspended + 3))
    }

    func testSwitchingServersClosesEverything() {
        let model = store.model(server: profile, client: server.client, conversationID: 7)
        store.removeAll()
        XCTAssertTrue(model.isSuspended)
        XCTAssertNil(store.existingModel(conversationID: 7))
    }
}
