import XCTest
@testable import Codeg

/// Where a session opens, and where Back goes from it: the tab and list it
/// was opened from, for sessions from Activity, a folder group, a
/// notification or a link; the shell an iPhone keeps in landscape; and an
/// iPad window resized between its split view and its tabs keeping the
/// open screen.
@MainActor
final class NavigationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var server: MockCodegServer!
    private var profile: ServerProfile!

    override func setUp() async throws {
        suite = "navigation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        server = MockCodegServer()
        profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        defaults.set(try JSONEncoder().encode([profile]), forKey: ServerStore.storageKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        server = nil
    }

    private func makeApp(compact: Bool = true) -> AppModel {
        let store = ServerStore(defaults: defaults)
        let mock = server!
        store.clientFactory = { _ in mock.client }
        let app = AppModel(serverStore: store, defaults: defaults, transcriptCache: nil)
        app.setLayout(compact: compact, initial: true)
        return app
    }

    // MARK: - Shell

    func testAnIPhoneKeepsItsTabsInLandscape() {
        // A Pro Max in landscape reports a regular width.
        XCTAssertTrue(ShellLayout.usesTabs(idiom: .phone, horizontalSizeClass: .regular))
        XCTAssertTrue(ShellLayout.usesTabs(idiom: .phone, horizontalSizeClass: .compact))
        XCTAssertFalse(ShellLayout.usesTabs(idiom: .pad, horizontalSizeClass: .regular))
        XCTAssertTrue(ShellLayout.usesTabs(idiom: .pad, horizontalSizeClass: .compact))
    }

    // MARK: - Back from a session

    func testASessionOpenedFromActivityGoesBackToActivity() {
        let app = makeApp()
        app.selectedTab = .activity
        app.open(.conversation(42))
        XCTAssertEqual(app.paths[.activity], [.conversation(42)])
        // Back pops the Activity tab's stack, onto Activity's own screen.
        app.paths[.activity]?.removeLast()
        XCTAssertEqual(app.selectedTab, .activity)
        XCTAssertEqual(app.paths[.activity], [])
    }

    func testANotificationOpensOnTheTabYouAreOn() {
        let app = makeApp()
        app.selectedTab = .activity
        app.openFromPush(serverID: profile.id, conversationID: 42)
        XCTAssertEqual(app.selectedTab, .activity, "not switched to Chats")
        XCTAssertEqual(app.paths[.activity], [.conversation(42)])
        XCTAssertNil(app.paths[.chats])
        XCTAssertEqual(app.markedConversationID, 42)
    }

    func testANotificationReplacesTheSessionOpenOnThatTab() {
        let app = makeApp()
        app.selectedTab = .projects
        app.paths[.projects] = [.project(3), .conversation(5)]
        app.openFromPush(serverID: profile.id, conversationID: 42)
        XCTAssertEqual(app.paths[.projects], [.project(3), .conversation(42)],
                       "Back returns to the folder, not to the session that was open")
    }

    func testANotificationFromSettingsOpensOnActivity() {
        let app = makeApp()
        app.selectedTab = .settings
        app.openFromPush(serverID: profile.id, conversationID: 42)
        XCTAssertEqual(app.selectedTab, .activity)
        XCTAssertEqual(app.paths[.activity], [.conversation(42)])
    }

    func testAConversationLinkOpensLikeANotification() throws {
        let app = makeApp()
        app.selectedTab = .search
        app.paths[.search] = [.conversation(1)]
        let url = try XCTUnwrap(URL(string: "\(AppIdentity.urlScheme)://conversation/42"))
        app.handle(url: url)
        XCTAssertEqual(app.selectedTab, .search)
        XCTAssertEqual(app.paths[.search], [.conversation(42)])
    }

    func testTheTabIsRememberedAcrossLaunches() {
        let first = makeApp()
        first.selectedTab = .activity
        let second = makeApp()
        XCTAssertEqual(second.selectedTab, .activity)
    }

    func testAFolderGroupIsAScreenSoBackFromASessionReturnsToIt() {
        let app = makeApp()
        app.selectedTab = .chats
        app.open(.sessionGroup(.folder(2)))
        app.open(.conversation(8))
        XCTAssertEqual(app.paths[.chats], [.sessionGroup(.folder(2)), .conversation(8)])
        app.paths[.chats]?.removeLast()
        XCTAssertEqual(app.paths[.chats], [.sessionGroup(.folder(2))], "Back lands on the folder's list")
    }

    // MARK: - iPad: split view and tabs

    func testAnIPadWindowResizedNarrowKeepsTheOpenSessionAndBack() {
        let app = makeApp(compact: false)
        app.sidebarSection = .activity
        app.open(.conversation(9))
        XCTAssertEqual(app.selectedConversationID, 9)

        app.setLayout(compact: true)
        XCTAssertTrue(app.isCompact)
        XCTAssertEqual(app.selectedTab, .activity)
        XCTAssertEqual(app.paths[.activity], [.conversation(9)])

        app.setLayout(compact: false)
        XCTAssertFalse(app.isCompact)
        XCTAssertEqual(app.sidebarSection, .activity)
        XCTAssertEqual(app.selectedConversationID, 9)
        XCTAssertEqual(app.contentPath, [])
    }

    func testFolderScreensCarryAcrossTheLayoutChange() {
        let app = makeApp(compact: false)
        app.open(.project(3))
        app.open(.conversation(4))
        app.setLayout(compact: true)
        XCTAssertEqual(app.selectedTab, .projects)
        XCTAssertEqual(app.paths[.projects], [.project(3), .conversation(4)])
        app.setLayout(compact: false)
        XCTAssertEqual(app.contentPath, [.project(3)])
        XCTAssertEqual(app.selectedConversationID, 4)
    }

    func testTheSameLayoutAgainChangesNothing() {
        let app = makeApp()
        app.selectedTab = .activity
        app.open(.conversation(42))
        app.setLayout(compact: true)
        XCTAssertEqual(app.paths[.activity], [.conversation(42)])
    }
}
