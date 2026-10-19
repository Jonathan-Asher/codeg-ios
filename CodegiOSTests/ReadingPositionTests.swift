import CoreGraphics
import XCTest
@testable import Codeg

/// Where the reader was in a session, how it opens again, and what may move
/// the view: the saved position and its keying, the restore rule, the
/// anchoring math, picture headers that let a placeholder take the picture's
/// height, and the session model never pulling a reader down on a refresh.
@MainActor
final class ReadingPositionTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "reading-\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func position(_ id: String = "turn-40", turn: String? = "turn-40", offset: Double = 12,
                          atBottom: Bool = false, windowStart: Int? = 30, seen: Int = 120,
                          at date: Date = Date()) -> ReadingPosition {
        ReadingPosition(anchorID: id, anchorTurnID: turn, anchorTurnMillis: nil, offset: offset, atBottom: atBottom,
                        windowStart: windowStart, seenTurnEnd: seen, savedAt: date)
    }

    // MARK: - Store

    func testPositionsPersistAcrossLaunchesKeyedByServerAndConversation() {
        let defaults = scratchDefaults()
        let store = ReadingPositionStore(defaults: defaults)
        store.save(position("turn-40#2"), serverKey: "server-a", conversationID: 7)
        store.save(position("turn-90", turn: "turn-90"), serverKey: "server-b", conversationID: 7)
        store.save(position("turn-5", turn: "turn-5"), serverKey: "server-a", conversationID: 8)

        // A new store on the same defaults is the next launch.
        let relaunched = ReadingPositionStore(defaults: defaults)
        XCTAssertEqual(relaunched.position(serverKey: "server-a", conversationID: 7)?.anchorID, "turn-40#2")
        XCTAssertEqual(relaunched.position(serverKey: "server-b", conversationID: 7)?.anchorID, "turn-90",
                       "the same conversation id on another server is another session")
        XCTAssertEqual(relaunched.position(serverKey: "server-a", conversationID: 8)?.anchorID, "turn-5")
        XCTAssertNil(relaunched.position(serverKey: "server-a", conversationID: 9))
        XCTAssertEqual(ReadingPositionStore.key(serverKey: "server-a", conversationID: 7), "server-a#7")

        relaunched.remove(serverKey: "server-a", conversationID: 7)
        XCTAssertNil(ReadingPositionStore(defaults: defaults).position(serverKey: "server-a", conversationID: 7))
    }

    func testTheStoreKeepsTheMostRecentlySavedSessions() {
        let store = ReadingPositionStore(defaults: scratchDefaults())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(ReadingPositionStore.capacity + 5) {
            store.save(position(at: start.addingTimeInterval(Double(i))), serverKey: "s", conversationID: i)
        }
        XCTAssertEqual(store.count, ReadingPositionStore.capacity)
        XCTAssertNil(store.position(serverKey: "s", conversationID: 0), "the oldest went first")
        XCTAssertNil(store.position(serverKey: "s", conversationID: 4))
        XCTAssertNotNil(store.position(serverKey: "s", conversationID: 5))
        XCTAssertNotNil(store.position(serverKey: "s", conversationID: ReadingPositionStore.capacity + 4))
    }

    func testServersThatAreGoneLoseTheirPositions() {
        let store = ReadingPositionStore(defaults: scratchDefaults())
        store.save(position(), serverKey: "kept", conversationID: 1)
        store.save(position(), serverKey: "gone", conversationID: 1)
        store.removeServers(except: ["kept"])
        XCTAssertNotNil(store.position(serverKey: "kept", conversationID: 1))
        XCTAssertNil(store.position(serverKey: "gone", conversationID: 1))
    }

    // MARK: - The restore rule

    func testTheRestoreRule() {
        let saved = position()
        XCTAssertEqual(ReadingRestore.decide(saved: nil, openAtLatest: false), .bottom, "nothing saved")
        XCTAssertEqual(ReadingRestore.decide(saved: saved, openAtLatest: false), .anchored(saved),
                       "scrolled up when they left: back to that place")
        XCTAssertEqual(ReadingRestore.decide(saved: .bottom(seenTurnEnd: 120), openAtLatest: false), .bottom,
                       "at the latest message when they left: there again, following new replies")
        XCTAssertEqual(ReadingRestore.decide(saved: saved, openAtLatest: true), .bottom,
                       "a notification or a link: the latest message")
    }

    func testTheSavedRowIsFoundOrFallsBack() {
        let rows: [(id: String, turnID: String?)] = [
            ("turn-38", "turn-38"), ("turn-39#0", "turn-39"), ("turn-39#footer", "turn-39"),
            ("turn-40", "turn-40"), ("t-live", nil),
        ]
        let exact = ReadingRestore.resolve(position("turn-39#footer", turn: "turn-39", offset: 7), rows: rows)
        XCTAssertEqual(exact?.id, "turn-39#footer")
        XCTAssertEqual(exact?.offset, 7)

        // The reply was renumbered (a reload split its parts differently):
        // its first row, from the top.
        let renumbered = ReadingRestore.resolve(position("turn-39#4", turn: "turn-39", offset: 30), rows: rows)
        XCTAssertEqual(renumbered?.id, "turn-39#0")
        XCTAssertEqual(renumbered?.offset, 0)

        XCTAssertNil(ReadingRestore.resolve(position("turn-2", turn: "turn-2"), rows: rows),
                     "a row that is gone opens at the latest message")
    }

    /// Turn ids are positions (`turn-41`): after a rewrite the same id is
    /// another message, told apart by its server time.
    func testARewrittenHistoryOpensAtTheLatestMessage() {
        var saved = position("turn-1#0", turn: "turn-1")
        saved.anchorTurnMillis = 1_760_000_000_123
        let same = [MessageTurn(id: "turn-1", role: .assistant, blocks: [.text("a")], timestamp: Date(),
                                serverMillis: 1_760_000_000_123)]
        let rewritten = [MessageTurn(id: "turn-1", role: .assistant, blocks: [.text("b")], timestamp: Date(),
                                     serverMillis: 1_760_000_999_000)]
        XCTAssertTrue(ReadingRestore.isStillThere(saved, in: same))
        XCTAssertFalse(ReadingRestore.isStillThere(saved, in: rewritten))
        XCTAssertTrue(ReadingRestore.isStillThere(saved, in: []), "not held: it may come with the window")
    }

    func testTheWindowOpensWideEnoughForTheSavedRow() {
        let ids = (100..<220).map { "turn-\($0)" }
        // Held from global index 100; the row's turn is at 140.
        XCTAssertEqual(ReadingRestore.windowStart(for: position(turn: "turn-140", windowStart: 120),
                                                  turnIDs: ids, turnsOffset: 100), 120)
        XCTAssertEqual(ReadingRestore.windowStart(for: position(turn: "turn-140", windowStart: 160),
                                                  turnIDs: ids, turnsOffset: 100), 140,
                       "never starts after the row it must show")
        XCTAssertEqual(ReadingRestore.windowStart(for: position(turn: "turn-140", windowStart: nil),
                                                  turnIDs: ids, turnsOffset: 100), 140)
        XCTAssertNil(ReadingRestore.windowStart(for: position(turn: "turn-12"), turnIDs: ids, turnsOffset: 100),
                     "a turn not held can't be shown")
    }

    // MARK: - Anchoring math

    func testTheTopRowIsTheFirstStillShowing() {
        let rows: [ScrollAnchorMath.Row] = [
            .init(id: "top", minY: 0, maxY: 40, anchorable: false),
            .init(id: "a", minY: 40, maxY: 200),
            .init(id: "live", minY: 200, maxY: 500, persisted: false),
            .init(id: "b", minY: 500, maxY: 700),
        ]
        let partly = ScrollAnchorMath.topRow(rows, visibleTop: 150, visibleBottom: 900)
        XCTAssertEqual(partly?.id, "a")
        XCTAssertEqual(partly?.offset, 110, "the screen's top is 110 pt into the row")

        let onLive = ScrollAnchorMath.topRow(rows, visibleTop: 260, visibleBottom: 900)
        XCTAssertEqual(onLive?.id, "live")
        let saved = ScrollAnchorMath.topRow(rows, visibleTop: 260, visibleBottom: 900, preferPersisted: true)
        XCTAssertEqual(saved?.id, "b", "the saved row is one that survives the reply being reconciled")
        XCTAssertEqual(saved?.offset, -240, "it starts 240 pt below the top")

        XCTAssertNil(ScrollAnchorMath.topRow([rows[0]], visibleTop: 0, visibleBottom: 900), "chrome is never saved")
        XCTAssertEqual(ScrollAnchorMath.topRow(rows, visibleTop: 200, visibleBottom: 900)?.id, "live",
                       "a row that ends exactly at the top no longer shows")
    }

    func testRestoringPutsTheRowBackAtTheSameOffset() {
        let range = ScrollAnchorMath.offsetRange(contentHeight: 5000, viewportHeight: 900, topInset: 100, bottomInset: 80)
        XCTAssertEqual(range, -100...4180)
        // The row starts at 2000; the screen's top was 35 pt into it, under a
        // 100 pt bar: content offset 2000 + 35 - 100.
        XCTAssertEqual(ScrollAnchorMath.restoreOffsetY(rowMinY: 2000, offset: 35, topInset: 100, range: range), 1935)
        XCTAssertEqual(ScrollAnchorMath.restoreOffsetY(rowMinY: 4900, offset: 0, topInset: 100, range: range), 4180,
                       "never past the end")
        XCTAssertEqual(ScrollAnchorMath.restoreOffsetY(rowMinY: 0, offset: -50, topInset: 100, range: range), -100,
                       "never above the top")
        XCTAssertEqual(ScrollAnchorMath.offsetRange(contentHeight: 300, viewportHeight: 900, topInset: 100,
                                                    bottomInset: 80), -100 ... -100, "short content can't scroll")
    }

    /// Older turns go in above the reader: the content grows by their height
    /// and the held row's top moves down by it; the offset moves by exactly
    /// as much, so the row stays where it was on screen.
    func testPrependingKeepsTheHeldRowStill() {
        let before = ScrollAnchorMath.offsetRange(contentHeight: 6000, viewportHeight: 900, topInset: 100, bottomInset: 80)
        let rowMinY: CGFloat = 1200
        let contentOffset: CGFloat = 1150
        let screenY = rowMinY - contentOffset
        XCTAssertEqual(ScrollAnchorMath.lockedOffsetY(rowMinY: rowMinY, screenY: screenY, range: before), contentOffset)

        let inserted: CGFloat = 8432.5
        let after = ScrollAnchorMath.offsetRange(contentHeight: 6000 + inserted, viewportHeight: 900,
                                                 topInset: 100, bottomInset: 80)
        let newOffset = ScrollAnchorMath.lockedOffsetY(rowMinY: rowMinY + inserted, screenY: screenY, range: after)
        XCTAssertEqual(newOffset, contentOffset + inserted)
        XCTAssertEqual((rowMinY + inserted) - newOffset, screenY, "same place on screen")

        // A picture above it that loaded 64 pt taller than its placeholder.
        XCTAssertEqual(ScrollAnchorMath.lockedOffsetY(rowMinY: rowMinY + 64, screenY: screenY, range: before),
                       contentOffset + 64)
    }

    func testOlderTurnsComeInWithinOneAndAHalfScreensOfTheTop() {
        XCTAssertTrue(ScrollAnchorMath.isNearTop(contentOffsetY: 1200, topInset: 100, viewportHeight: 900))
        XCTAssertFalse(ScrollAnchorMath.isNearTop(contentOffsetY: 1260, topInset: 100, viewportHeight: 900))
        XCTAssertTrue(ScrollAnchorMath.isNearTop(contentOffsetY: -100, topInset: 100, viewportHeight: 900))
    }

    // MARK: - Picture sizes before decoding

    func testPictureSizesAreReadFromTheirHeaders() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png.append(contentsOf: [0, 0, 0x05, 0x28, 0, 0, 0x0B, 0x40, 8, 6, 0, 0, 0])
        XCTAssertEqual(ImageDimensions.size(ofBase64: png.base64EncodedString()), CGSize(width: 1320, height: 2880))

        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x40, 0x01, 0xF0, 0x00, 0, 0]) + Data(count: 24)
        XCTAssertEqual(ImageDimensions.size(of: gif), CGSize(width: 320, height: 240))

        // JPEG: SOI, a JFIF APP0 block, then SOF0 with height 600, width 800.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        jpeg.append(Data(count: 14))
        jpeg.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x58, 0x03, 0x20, 0x03])
        jpeg.append(Data(count: 16))
        XCTAssertEqual(ImageDimensions.size(of: jpeg), CGSize(width: 800, height: 600))

        // An Exif block may rotate it: left to the decode.
        var exif = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08])
        exif.append(Data(count: 6))
        exif.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x58, 0x03, 0x20, 0x03])
        exif.append(Data(count: 16))
        XCTAssertNil(ImageDimensions.size(of: exif))

        XCTAssertNil(ImageDimensions.size(ofBase64: "not a picture at all, just text"))
        XCTAssertEqual(TranscriptImages.aspect(of: ImageData(data: png.base64EncodedString(), mimeType: "image/png", uri: nil)),
                       1320.0 / 2880.0)
    }

    // MARK: - The session model

    private func makeModel(server: MockCodegServer, transcript: WindowedTranscriptServer, store: ReadingPositionStore,
                           factory: StreamFactory? = nil) -> SessionDetailViewModel {
        let factory = factory ?? StreamFactory([])
        transcript.install(on: server)
        return SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                      makeEventStream: { _ in factory.make() }, transcriptCache: nil,
                                      readingPositions: store)
    }

    func testASavedPositionOpensThereAndANotificationOpensAtTheLatestMessage() async {
        let server = MockCodegServer()
        let transcript = WindowedTranscriptServer(count: 300)
        let store = ReadingPositionStore(defaults: scratchDefaults())
        let key = TranscriptCache.serverKey(for: server.client)
        let saved = position("turn-250#0", turn: "turn-250", offset: 22, windowStart: 240, seen: 290)
        store.save(saved, serverKey: key, conversationID: Fixtures.conversationID)

        let model = makeModel(server: server, transcript: transcript, store: store)
        model.loadIfNeeded()
        let loaded = await eventually { model.phase == .loaded }
        XCTAssertTrue(loaded)

        let screen = UUID()
        XCTAssertEqual(model.restoreDecision(screen: screen), .anchored(saved))
        XCTAssertEqual(model.restoreDecision(screen: screen), .anchored(saved), "decided once per screen")
        XCTAssertEqual(model.seenTurnEnd, 290, "what arrived after it is new")
        model.setPinnedToBottom(false)
        XCTAssertTrue(model.hasNewMessagesBelow, "300 turns now, 290 seen: New messages")

        // A notification about this session, with no screen showing it.
        model.requestOpenAtLatest(onScreen: false)
        XCTAssertEqual(model.restoreDecision(screen: UUID()), .bottom)
        XCTAssertEqual(model.restoreDecision(screen: UUID()), .anchored(saved), "only the next screen")
        model.teardown()
    }

    func testTheViewportIsSavedAndAtTheBottomForgetsTheRow() {
        let server = MockCodegServer()
        let store = ReadingPositionStore(defaults: scratchDefaults())
        let model = makeModel(server: server, transcript: WindowedTranscriptServer(count: 10), store: store)
        let key = TranscriptCache.serverKey(for: server.client)
        model.transcriptWindowStart = 4

        // Not looked at (the screen went): saved at once.
        let anchor = TranscriptScrollBridge.Anchor(id: "turn-5#0", turnID: "turn-5", offset: 18)
        model.noteViewport(TranscriptViewport(anchor: anchor, atBottom: false))
        let saved = store.position(serverKey: key, conversationID: Fixtures.conversationID)
        XCTAssertEqual(saved?.anchorID, "turn-5#0")
        XCTAssertEqual(saved?.anchorTurnID, "turn-5")
        XCTAssertEqual(saved?.offset, 18)
        XCTAssertEqual(saved?.windowStart, 4)
        XCTAssertEqual(saved?.atBottom, false)

        model.noteViewport(TranscriptViewport(anchor: nil, atBottom: true))
        XCTAssertEqual(store.position(serverKey: key, conversationID: Fixtures.conversationID)?.atBottom, true)
        XCTAssertEqual(model.restoreDecision(screen: UUID()), .bottom)
    }

    /// A reattach to a running turn (the cold attach on open, a reconnect, the
    /// app coming back) used to force the transcript to the bottom. It now
    /// only follows there: `stickTick`, the forced re-pin, doesn't move.
    func testAReattachNeverPullsAReaderScrolledUpDown() async {
        let server = MockCodegServer()
        let transcript = WindowedTranscriptServer(count: 30)
        transcript.status = "in_progress"
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let factory = StreamFactory([], fallback: .attach(Fixtures.snapshot(status: "prompting", liveText: "Working on it")))
        let model = makeModel(server: server, transcript: transcript, store: ReadingPositionStore(defaults: scratchDefaults()),
                              factory: factory)
        model.loadIfNeeded()
        let attached = await eventually { model.phase == .loaded && model.isInFlight }
        XCTAssertTrue(attached, "attached to the running turn")
        let ticks = model.stickTick
        model.setPinnedToBottom(false)

        // The socket drops and the screen reconnects in place; then the app
        // comes back from the background.
        factory.opened.last?.drop("network lost")
        _ = await eventually(timeout: 4) { factory.opened.count >= 2 }
        await model.refreshOnForeground()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.stickTick, ticks, "nothing forced the view to the bottom")
        XCTAssertFalse(model.isPinnedToBottom)

        // The reply goes on below the reader: said, not scrolled to.
        factory.opened.last?.push(Fixtures.event(
            #"{"seq": 50, "connection_id": "conn-1", "type": "content_delta", "text": " and more"}"#))
        let told = await eventually(timeout: 4) { model.hasNewMessagesBelow }
        XCTAssertTrue(told, "the running reply grew below: New messages")
        XCTAssertEqual(model.stickTick, ticks)

        // The reader's own jump to the latest message still re-pins.
        model.userTappedScrollToBottom()
        XCTAssertEqual(model.stickTick, ticks &+ 1)
        XCTAssertFalse(model.hasNewMessagesBelow)
        model.teardown()
    }

    func testANotificationForAKeptSessionJumpsOrOpensAtTheLatestMessage() {
        let server = MockCodegServer()
        WindowedTranscriptServer(count: 10).install(on: server)
        let store = SessionModelStore()
        store.transcriptCache = nil
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        let positions = ReadingPositionStore(defaults: scratchDefaults())
        store.makeModel = { client, id, _ in
            SessionDetailViewModel(client: client, conversationID: id, makeEventStream: { _ in StreamFactory([]).make() },
                                   transcriptCache: nil, readingPositions: positions)
        }
        let key = TranscriptCache.serverKey(for: server.client)
        positions.save(position(), serverKey: key, conversationID: 3)
        positions.save(position(), serverKey: key, conversationID: 4)

        // Not made yet: the model made for it opens at the latest message.
        store.requestOpenAtLatest(conversationID: 3)
        let fresh = store.model(server: profile, client: server.client, conversationID: 3)
        XCTAssertEqual(fresh.restoreDecision(screen: UUID()), .bottom)

        // Kept, on screen: it jumps there now.
        let shown = store.model(server: profile, client: server.client, conversationID: 4)
        let lease = store.lease(server: profile, client: server.client, target: .conversation(4))
        let holder = UUID()
        lease.acquire(holder)
        shown.setPinnedToBottom(false)
        let ticks = shown.stickTick
        store.requestOpenAtLatest(conversationID: 4)
        XCTAssertEqual(shown.stickTick, ticks &+ 1)
        XCTAssertTrue(shown.isPinnedToBottom)
        lease.release(holder)
        store.removeAll()
    }
}
