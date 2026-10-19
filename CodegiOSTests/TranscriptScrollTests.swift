import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// The whole app (`RootView`) on the CI simulator, with a long session
/// (hundreds of turns of different lengths) served in windows by a mock
/// server, scrolled as a reader would:
///
/// - scrolling up brings older turns in (from what is held, then the server's
///   pages, fetched before the top is reached) without moving the row at the
///   top of the screen, measured on every display frame;
/// - leaving the session and coming back, and relaunching the app, opens it
///   where the reader was, with "New messages" for what arrived meanwhile;
/// - a notification opens it at the latest message.
///
/// The same scroll without the anchoring is measured too, and both go to
/// `transcript-scroll.txt` in the `session-list-screenshots` artifact.
@MainActor
final class TranscriptScrollTests: XCTestCase {
    private var server: MockCodegServer!
    private var transcript: WindowedTranscriptServer!
    private var suite: String!
    private var window: UIWindow?
    private var cacheRoot: URL!

    override func setUp() async throws {
        server = MockCodegServer()
        suite = "transcript-scroll-\(UUID().uuidString)"
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-cache-\(UUID().uuidString)")
        TranscriptScrollBridge.anchoringEnabled = true
        TranscriptScrollBridge.scrolledUpSizeAnchor = nil
        TranscriptScrollBridge.tracing = false
    }

    override func tearDown() async throws {
        TranscriptScrollBridge.anchoringEnabled = true
        TranscriptScrollBridge.scrolledUpSizeAnchor = nil
        TranscriptScrollBridge.tracing = false
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: cacheRoot)
        server = nil
        transcript = nil
    }

    // MARK: - Tests

    func testOlderMessagesComeInWithoutMovingTheView() async throws {
        installLongTranscript(count: 700)
        TranscriptScrollBridge.tracing = true
        let harness = try launch()
        let (model, bridge) = try await open(harness)
        let measure = try await scrollUpThroughHistory(model: model, bridge: bridge, steps: 40)
        record("anchored", measure)

        XCTAssertGreaterThanOrEqual(measure.reveals, 3, "older turns came in as the reader scrolled up")
        XCTAssertGreaterThanOrEqual(server.calls("get_folder_conversation_turns").count, 2,
                                    "older pages were fetched from the server on the way")
        XCTAssertEqual(measure.lost, 0, "the row at the top of the screen never left the list")
        XCTAssertLessThanOrEqual(measure.maxShift, 1,
                                 "the row at the top of the screen never moved, on any frame (worst \(measure.maxShift) pt)")
        XCTAssertGreaterThan(bridge.corrections, 0, "the bridge held the row through the inserts")
        model.teardown()
    }

    /// The same scroll with the anchoring off: what the reader saw before.
    func testTheSameScrollWithoutAnchoringIsMeasured() async throws {
        installLongTranscript(count: 700)
        TranscriptScrollBridge.anchoringEnabled = false
        let harness = try launch()
        let (model, bridge) = try await open(harness)
        let measure = try await scrollUpThroughHistory(model: model, bridge: bridge, steps: 40)
        record("without anchoring", measure)
        XCTAssertGreaterThan(measure.samples, 0)
        model.teardown()
    }

    /// SwiftUI's bottom size-change anchor while scrolled up, with and
    /// without the bridge (the old transcript kept `.bottom` for every role).
    func testTheBottomSizeAnchorIsMeasured() async throws {
        installLongTranscript(count: 700)
        TranscriptScrollBridge.scrolledUpSizeAnchor = .bottom
        TranscriptScrollBridge.anchoringEnabled = false
        let harness = try launch()
        let (model, bridge) = try await open(harness)
        record("bottom size anchor, no bridge", try await scrollUpThroughHistory(model: model, bridge: bridge, steps: 30))
        model.teardown()
    }

    func testTheBottomSizeAnchorWithTheBridgeIsMeasured() async throws {
        installLongTranscript(count: 700)
        TranscriptScrollBridge.scrolledUpSizeAnchor = .bottom
        TranscriptScrollBridge.tracing = true
        let harness = try launch()
        let (model, bridge) = try await open(harness)
        record("bottom size anchor with the bridge", try await scrollUpThroughHistory(model: model, bridge: bridge, steps: 30))
        model.teardown()
    }

    func testLeavingAndComingBackKeepsTheReadersPlace() async throws {
        installLongTranscript(count: 400)
        let harness = try launch()
        var (model, bridge) = try await open(harness)
        let height = try XCTUnwrap(bridge.collectionView).bounds.height
        for _ in 0..<4 {
            bridge.scrollAsUser(by: -height * 0.9)
            try await Task.sleep(for: .milliseconds(300))
        }
        bridge.scrollAsUser(by: -37)
        try await Task.sleep(for: .milliseconds(400))
        let saved = try XCTUnwrap(model.readingPosition)
        XCTAssertFalse(saved.atBottom)
        let before = try XCTUnwrap(bridge.screenY(of: saved.anchorID))
        XCTAssertEqual(before, -CGFloat(saved.offset), accuracy: 0.5)

        // Back to Activity, long enough for the session to be let go, and a
        // reply arrives meanwhile.
        harness.app.paths[.activity] = []
        let released = await eventually(timeout: 5) { model.isSuspended }
        XCTAssertTrue(released, "the session was let go (held by \(harness.sessions.heldConversationIDs))")
        transcript.append(5)

        (model, bridge) = try await open(harness, settle: false)
        let back = await eventually { bridge.screenY(of: saved.anchorID).map { abs($0 - before) <= 1 } ?? false }
        XCTAssertTrue(back, "the same row at the same place (\(String(describing: bridge.screenY(of: saved.anchorID))) vs \(before))")
        XCTAssertFalse(model.isPinnedToBottom)
        let told = await eventually { model.hasNewMessagesBelow }
        XCTAssertTrue(told, "New messages for the reply that arrived")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(bridge.screenY(of: saved.anchorID) ?? .infinity, before, accuracy: 1,
                       "the refresh that brought the reply didn't move the view")
        try capture("transcript-returned-new-messages")

        // A notification about the session opens it at the latest message.
        harness.app.paths[.activity] = []
        try await Task.sleep(for: .seconds(1))
        let serverID = try XCTUnwrap(harness.app.selectedServerID)
        TranscriptScrollBridge.current = nil
        harness.app.openFromPush(serverID: serverID, conversationID: Fixtures.conversationID)
        let atLatest = await eventually {
            guard let current = TranscriptScrollBridge.current, let view = current.collectionView,
                  view.window != nil else { return false }
            return model.isPinnedToBottom && Self.isAtBottom(view)
        }
        XCTAssertTrue(atLatest, "the notification opened at the latest message")
        model.teardown()
    }

    /// The same screen coming back from another tab used to scroll to the
    /// bottom as it appeared again.
    func testAnotherTabAndBackKeepsThePlace() async throws {
        installLongTranscript(count: 300)
        let harness = try launch()
        let (model, bridge) = try await open(harness)
        let height = try XCTUnwrap(bridge.collectionView).bounds.height
        for _ in 0..<3 {
            bridge.scrollAsUser(by: -height * 0.9)
            try await Task.sleep(for: .milliseconds(300))
        }
        let anchor = try XCTUnwrap(bridge.topAnchor(preferPersisted: true))
        let before = try XCTUnwrap(bridge.screenY(of: anchor.id))
        harness.app.selectedTab = .chats
        try await Task.sleep(for: .milliseconds(1200))
        harness.app.selectedTab = .activity
        let back = await eventually(timeout: 4) {
            TranscriptScrollBridge.current?.collectionView?.window != nil
                && TranscriptScrollBridge.current?.screenY(of: anchor.id).map { abs($0 - before) <= 1 } == true
        }
        try await Task.sleep(for: .milliseconds(600))
        let now = TranscriptScrollBridge.current?.screenY(of: anchor.id)
        XCTAssertTrue(back && now.map { abs($0 - before) <= 1 } == true,
                      "back from another tab at the same place (\(String(describing: now)) vs \(before))")
        XCTAssertFalse(model.isPinnedToBottom)

        // Back to Activity: the session is let go once no screen holds it.
        harness.app.paths[.activity] = []
        let released = await eventually(timeout: 4) { model.isSuspended }
        XCTAssertTrue(released, "let go after Back (held by \(harness.sessions.heldConversationIDs))")
        model.teardown()
    }

    func testTheReadingPositionSurvivesARelaunch() async throws {
        installLongTranscript(count: 300)
        let cache = TranscriptCache(root: cacheRoot)
        let harness = try launch(cache: cache)
        let (model, bridge) = try await open(harness)
        let height = try XCTUnwrap(bridge.collectionView).bounds.height
        for _ in 0..<3 {
            bridge.scrollAsUser(by: -height * 0.8)
            try await Task.sleep(for: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(300))
        let saved = try XCTUnwrap(model.readingPosition)
        let before = try XCTUnwrap(bridge.screenY(of: saved.anchorID))
        harness.app.paths[.activity] = []
        // Long enough for the cache to write and the session to be let go.
        try await Task.sleep(for: .seconds(1.5))
        let key = TranscriptCache.serverKey(for: server.client)
        let stored = ReadingPositionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(stored.position(serverKey: key, conversationID: Fixtures.conversationID)?.anchorID,
                       saved.anchorID, "saved when the screen went")
        harness.sessions.removeAll()
        model.teardown()

        // The next launch: a new app over the same defaults and cache.
        let relaunched = try launch(cache: cache)
        let (again, bridgeAgain) = try await open(relaunched, settle: false)
        let back = await eventually { bridgeAgain.screenY(of: saved.anchorID).map { abs($0 - before) <= 1 } ?? false }
        XCTAssertTrue(back, "opened where the reader was before the relaunch")
        XCTAssertFalse(again.isPinnedToBottom)
        again.teardown()
    }

    // MARK: - Scrolling up, measured

    struct Measure {
        var steps = 0
        /// Steps during which older turns came into the list.
        var reveals = 0
        /// Display frames looked at.
        var samples = 0
        /// The most the top row moved on screen without the reader scrolling.
        var maxShift: CGFloat = 0
        var shifts: [CGFloat] = []
        /// Times the top row couldn't be found afterwards.
        var lost = 0
        /// What the bridge saw during reveals that moved the row.
        var traces: [String] = []
        /// Steps where the row's cell was handed to another row meanwhile
        /// (its frames then measured another row).
        var cellsReused = 0
    }

    /// Scroll up two screens at a time. Right after each scroll, note
    /// the row at the top of the screen and where it is; then, while older
    /// turns come in (or not), look at it on every display frame for half a
    /// second.
    private func scrollUpThroughHistory(model: SessionDetailViewModel, bridge: TranscriptScrollBridge,
                                        steps: Int) async throws -> Measure {
        var measure = Measure()
        let view = try XCTUnwrap(bridge.collectionView)
        for _ in 0..<steps {
            bridge.scrollAsUser(by: -view.bounds.height * 2)
            measure.steps += 1
            guard let anchor = bridge.topAnchor(preferPersisted: false),
                  let start = bridge.screenY(of: anchor.id),
                  let cell = bridge.cell(for: anchor.id) else {
                measure.lost += 1
                continue
            }
            // Where the row's cell is drawn, in the window: what the reader sees.
            let drawnStart = cell.convert(cell.bounds, to: nil).minY
            let window = model.transcriptWindowStart
            let offset = model.turnsOffset
            #if DEBUG
            bridge.clearTrace()
            #endif
            var worst: CGFloat = 0
            var frames = 0
            let sampler = FrameSampler {
                // Under the cover the reader sees the picture of the screen.
                guard !bridge.isCovered else { return }
                frames += 1
                worst = max(worst, abs(cell.convert(cell.bounds, to: nil).minY - drawnStart))
            }
            sampler.start()
            try await Task.sleep(for: .milliseconds(500))
            sampler.stop()
            // Settled: the row (by id, through the list as it is now) is where
            // it was, and its cell is the one that was measured.
            if let y = bridge.screenY(of: anchor.id) {
                worst = max(worst, abs(y - start))
                if bridge.cell(for: anchor.id) !== cell { measure.cellsReused += 1 }
            } else {
                measure.lost += 1
            }
            measure.samples += frames
            if model.transcriptWindowStart != window || model.turnsOffset != offset {
                measure.reveals += 1
                measure.shifts.append(worst)
                #if DEBUG
                if worst > 1, measure.traces.count < 2, !bridge.trace.isEmpty {
                    measure.traces.append("reveal moved the top row \(worst) pt (anchor \(anchor.id) at \(start)):\n"
                                          + bridge.trace.prefix(160).joined(separator: "\n"))
                }
                #endif
            }
            measure.maxShift = max(measure.maxShift, worst)
            if model.turnsOffset == 0, (model.transcriptWindowStart ?? 1) == 0, Self.isAtTop(view) { break }
        }
        return measure
    }

    private func record(_ label: String, _ measure: Measure) {
        let shifts = measure.shifts.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        let cover = TranscriptScrollBridge.current.map {
            "covered \($0.coveredFrames) frames, longest cover \(Int($0.longestCover * 1000)) ms; "
        } ?? ""
        let line = "\(label): \(cover)\(measure.steps) scrolls, \(measure.reveals) with older turns coming in, "
            + "\(measure.samples) frames; top row moved at most \(String(format: "%.1f", measure.maxShift)) pt; "
            + "per reveal [\(shifts)] pt; lost \(measure.lost); cells reused \(measure.cellsReused)"
        print("transcript-scroll: \(line)")
        try? FileManager.default.createDirectory(at: Shot.directory, withIntermediateDirectories: true)
        let url = Shot.directory.appendingPathComponent("transcript-scroll.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let traces = measure.traces.isEmpty ? "" : measure.traces.joined(separator: "\n\n") + "\n"
        try? (existing + line + "\n" + traces).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Setup

    /// Turns of different lengths (one to eleven sentences), a prompt every
    /// fifth, so rows have many heights.
    private func installLongTranscript(count: Int) {
        let long = WindowedTranscriptServer(count: count)
        long.turns = long.turns.enumerated().map { index, turn in
            var turn = turn
            let words = String(repeating: "Words in turn \(index) that wrap across the column. ",
                               count: 1 + (index * 7) % 11)
            turn.text = "\(turn.role) message \(index). \(words)"
            return turn
        }
        long.install(on: server)
        transcript = long
    }

    struct Harness {
        let app: AppModel
        let sessions: SessionModelStore
    }

    private func launch(cache: TranscriptCache? = nil) throws -> Harness {
        let id = Fixtures.conversationID
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body("[]") }
        server.on("list_all_conversations") { _ in
            .body("""
            [{"id": \(id), "folder_id": 1, "title": "Long session", "agent_type": "claude_code",
              "status": "pending_review", "message_count": 700, "created_at": "2026-10-04T16:00:00Z",
              "updated_at": "\(TranscriptTime.string(date: Date()))", "turn_state": null}]
            """)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        if defaults.data(forKey: ServerStore.storageKey) == nil {
            defaults.set(try JSONEncoder().encode([profile]), forKey: ServerStore.storageKey)
        }
        let serverStore = ServerStore(defaults: defaults)
        let mock = server!
        serverStore.clientFactory = { _ in mock.client }
        let positions = ReadingPositionStore(defaults: defaults)
        let sessions = SessionModelStore()
        sessions.makeModel = { client, conversationID, cache in
            SessionDetailViewModel(client: client, conversationID: conversationID,
                                   makeEventStream: { _ in StreamFactory([]).make() },
                                   transcriptCache: cache, readingPositions: positions)
        }
        let app = AppModel(serverStore: serverStore, defaults: defaults, sessions: sessions,
                           transcriptCache: cache, readingPositions: positions)
        app.selectedTab = .activity

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: RootView(model: app))
        window.isHidden = false
        self.window?.isHidden = true
        self.window?.rootViewController = nil
        self.window = window
        return Harness(app: app, sessions: sessions)
    }

    /// Open the session from Activity and wait for its list.
    private func open(_ harness: Harness, settle: Bool = true) async throws
        -> (SessionDetailViewModel, TranscriptScrollBridge) {
        let id = Fixtures.conversationID
        let up = await eventually { harness.app.isCompact }
        XCTAssertTrue(up, "the tab shell came up")
        TranscriptScrollBridge.current = nil
        harness.app.open(.conversation(id))
        let ready = await eventually(timeout: 10) {
            harness.sessions.existingModel(conversationID: id)?.phase == .loaded
                && TranscriptScrollBridge.current?.collectionView?.window != nil
        }
        XCTAssertTrue(ready, "the session opened and its list was reached")
        let model = try XCTUnwrap(harness.sessions.existingModel(conversationID: id))
        let bridge = try XCTUnwrap(TranscriptScrollBridge.current)
        if settle {
            let bottom = await eventually { bridge.collectionView.map(Self.isAtBottom) ?? false }
            XCTAssertTrue(bottom, "opened at the latest message")
            try await Task.sleep(for: .milliseconds(400))
        }
        return (model, bridge)
    }

    private static func isAtBottom(_ view: UICollectionView) -> Bool {
        let range = ScrollAnchorMath.offsetRange(contentHeight: view.contentSize.height,
                                                 viewportHeight: view.bounds.height,
                                                 topInset: view.adjustedContentInset.top,
                                                 bottomInset: view.adjustedContentInset.bottom)
        return view.contentOffset.y >= range.upperBound - 90
    }

    private static func isAtTop(_ view: UICollectionView) -> Bool {
        view.contentOffset.y <= -view.adjustedContentInset.top + 1
    }

    private func capture(_ name: String) throws {
        guard let window else { return }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try FileManager.default.createDirectory(at: Shot.directory, withIntermediateDirectories: true)
        try data.write(to: Shot.directory.appendingPathComponent("\(name).png"))
    }
}

/// Calls `sample` on every display frame, at the start of the frame: what the
/// previous frame put on screen.
@MainActor
final class FrameSampler: NSObject {
    private var link: CADisplayLink?
    private let sample: () -> Void

    init(_ sample: @escaping () -> Void) {
        self.sample = sample
        super.init()
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { sample() }
}
