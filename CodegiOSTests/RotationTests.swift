import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// The whole app (`RootView`) on the simulator, with a session open from
/// Activity whose turn is running, rotated to landscape and back. On a Plus
/// or Pro Max iPhone (CI runs an iPhone 17 Pro Max) landscape reports a
/// regular width, which used to swap the tab shell for the split view: the
/// session was torn down and left, its socket closed and reopened, and the
/// navigation stack was lost. Now nothing about the session changes.
///
/// The rotation is real (`requestGeometryUpdate`). If the simulator doesn't
/// turn, or its landscape width stays compact (a smaller iPhone), the test
/// sets the width class the rotation would have produced, which is what used
/// to rebuild the app. Portrait and landscape captures go to the
/// `session-list-screenshots` artifact (`rotation-*.png`).
@MainActor
final class RotationTests: XCTestCase {
    private var server: MockCodegServer!
    private var transcript: WindowedTranscriptServer!
    private var suite: String!
    private var window: UIWindow?
    private var host: UIHostingController<RootView>?

    override func setUp() async throws {
        server = MockCodegServer()
        suite = "rotation-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        await rotate(to: .portrait)
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        host = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        server = nil
        transcript = nil
    }

    func testRotatingInsideARunningSessionKeepsItsScreenModelAndSocket() async throws {
        let id = Fixtures.conversationID
        transcript = WindowedTranscriptServer(count: 60)
        transcript.status = "in_progress"
        transcript.install(on: server)
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body("[]") }
        server.on("list_all_conversations") { _ in
            .body("""
            [{"id": \(id), "folder_id": 1, "title": "Long session", "agent_type": "claude_code",
              "status": "in_progress", "message_count": 60, "created_at": "2026-10-04T16:00:00Z",
              "updated_at": "\(TranscriptTime.string(date: Date()))", "turn_state": "running"}]
            """)
        }

        // The app pointed at the mock server, its sessions' sockets scripted.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        defaults.set(try JSONEncoder().encode([profile]), forKey: ServerStore.storageKey)
        let serverStore = ServerStore(defaults: defaults)
        let mock = server!
        serverStore.clientFactory = { _ in mock.client }
        let factory = StreamFactory([], fallback: .attach(Fixtures.snapshot(status: "prompting", liveText: "Working on it")))
        let sessions = SessionModelStore()
        sessions.makeModel = { client, conversationID, _ in
            SessionDetailViewModel(client: client, conversationID: conversationID,
                                   makeEventStream: { _ in factory.make() }, transcriptCache: nil)
        }
        let app = AppModel(serverStore: serverStore, defaults: defaults, sessions: sessions, transcriptCache: nil)
        app.selectedTab = .activity

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: RootView(model: app))
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        self.host = host

        // Open the session from Activity; it loads and attaches to its turn.
        let shellUp = await eventually { app.isCompact }
        XCTAssertTrue(shellUp, "the tab shell came up")
        app.open(.conversation(id))
        let loaded = await eventually(timeout: 10) {
            sessions.existingModel(conversationID: id)?.phase == .loaded && factory.opened.count == 1
                && sessions.existingModel(conversationID: id)?.isInFlight == true
        }
        XCTAssertTrue(loaded, "the session opened and attached to its running turn")
        let model = try XCTUnwrap(sessions.existingModel(conversationID: id))
        model.draft = "half-written reply"
        let path = app.paths[.activity]
        let fetches = server.calls("get_folder_conversation").count
        try await Task.sleep(for: .milliseconds(600))
        try capture(window, "rotation-portrait")

        for orientation in [UIInterfaceOrientationMask.landscapeRight, .portrait, .landscapeLeft, .portrait] {
            let landscape = orientation != .portrait
            await rotate(to: orientation)
            if landscape, host.traitCollection.horizontalSizeClass != .regular {
                // Not a Pro Max, or the simulator didn't turn: what the
                // rotation does to the width class, which is what used to
                // rebuild the app.
                host.traitOverrides.horizontalSizeClass = .regular
            } else if !landscape {
                host.traitOverrides.remove(UITraitHorizontalSizeClass.self)
            }
            // Longer than the store waits before closing an unheld session.
            try await Task.sleep(for: .seconds(1.5))
            if landscape, orientation == .landscapeRight { try capture(window, "rotation-landscape") }

            let label = landscape ? "landscape" : "portrait"
            XCTAssertTrue(app.isCompact, "\(label): still the tab shell")
            XCTAssertEqual(app.selectedTab, .activity, label)
            XCTAssertEqual(app.paths[.activity], path, "\(label): the same screen, Back still goes to Activity")
            XCTAssertIdentical(sessions.existingModel(conversationID: id), model, "\(label): the same model")
            XCTAssertEqual(sessions.heldConversationIDs, [id], "\(label): the screen never let go of it")
            XCTAssertFalse(model.isSuspended, label)
            XCTAssertTrue(model.isInFlight, "\(label): the live turn is still there")
            XCTAssertEqual(model.draft, "half-written reply", label)
            XCTAssertEqual(factory.opened.count, 1, "\(label): no new socket")
            XCTAssertFalse(factory.opened[0].isClosed, "\(label): the socket was never closed")
            XCTAssertEqual(server.calls("get_folder_conversation").count, fetches, "\(label): no reload")
        }
        model.teardown()
    }

    // MARK: - Helpers

    private func rotate(to orientation: UIInterfaceOrientationMask) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let target: (UIInterfaceOrientation) -> Bool = orientation == .portrait ? { $0 == .portrait } : { $0.isLandscape }
        if target(scene.effectiveGeometry.interfaceOrientation) { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        _ = await eventually(timeout: 4) { target(scene.effectiveGeometry.interfaceOrientation) }
    }

    private func capture(_ window: UIWindow, _ name: String) throws {
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try FileManager.default.createDirectory(at: Shot.directory, withIntermediateDirectories: true)
        let url = Shot.directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("shot: \(url.path) (\(Int(window.bounds.width))x\(Int(window.bounds.height)) pt)")
    }
}
