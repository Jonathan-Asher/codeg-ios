import XCTest
@testable import Codeg

// MARK: - A transcript server with the turn-window protocol

/// Plays a codeg server's `get_folder_conversation` (with `tailTurns` /
/// `fromIndex`) and `get_folder_conversation_turns` over a synthetic
/// transcript, on a ``MockCodegServer``. Its fingerprint is a separate,
/// byte-by-byte implementation of the server's (`prefix_fingerprint`), so
/// the app's own is checked against it rather than against itself.
final class WindowedTranscriptServer: @unchecked Sendable {
    struct Turn {
        var id: String
        var role: String
        var timestamp: String
        var text: String
    }

    private let lock = NSLock()
    private var _turns: [Turn]
    /// Answer as a server without windows (the whole transcript, no window fields).
    var legacy = false
    /// Pretend the server is behind: answer as if only this many turns existed.
    var visibleCount: Int?
    /// The conversation's status (`in_progress` while a turn runs).
    var status = "pending_review"

    var turns: [Turn] {
        get { lock.withLock { _turns } }
        set { lock.withLock { _turns = newValue } }
    }

    init(count: Int, start: Int64 = 1_791_129_600_000) {
        _turns = (0..<count).map { WindowedTranscriptServer.makeTurn(index: $0, start: start) }
    }

    static func makeTurn(index: Int, start: Int64 = 1_791_129_600_000) -> Turn {
        // A user prompt every fifth turn, replies between.
        let role = index % 5 == 0 ? "user" : "assistant"
        let millis = start + Int64(index) * 1_000 + Int64(index % 7) * 13
        return Turn(id: "turn-\(index)", role: role, timestamp: TranscriptTime.string(millis: millis),
                    text: "\(role) message \(index)")
    }

    func append(_ count: Int) {
        lock.withLock {
            let base = _turns.count
            _turns += (0..<count).map { WindowedTranscriptServer.makeTurn(index: base + $0) }
        }
    }

    func install(on server: MockCodegServer, conversationID: Int = Fixtures.conversationID) {
        server.on("get_folder_conversation") { [unowned self] call in .body(self.detail(call.body, id: conversationID)) }
        server.on("get_folder_conversation_turns") { [unowned self] call in .body(self.page(call.body)) }
    }

    // MARK: Responses

    private var served: [Turn] {
        let all = turns
        guard let visibleCount else { return all }
        return Array(all.prefix(visibleCount))
    }

    func detail(_ body: [String: Any], id: Int) -> String {
        let all = served
        let summary = """
        {"id": \(id), "folder_id": 1, "title": "Long session", "agent_type": "claude_code",
         "status": "\(status)", "external_id": "ext-\(id)", "message_count": \(all.count),
         "created_at": "2026-10-04T16:00:00Z", "updated_at": "2026-10-04T18:00:00Z", "turn_state": null}
        """
        if legacy {
            return #"{"summary": \#(summary), "turns": [\#(json(all[...]))], "session_stats": null}"#
        }
        let start: Int
        if let tail = body["tailTurns"] as? Int {
            start = alignBack(all, max(0, all.count - tail))
        } else if let from = body["fromIndex"] as? Int {
            start = min(from, all.count)
        } else {
            return #"{"summary": \#(summary), "turns": [\#(json(all[...]))], "session_stats": null}"#
        }
        return """
        {"summary": \(summary), "turns": [\(json(all[start...]))], "session_stats": null,
         "turns_offset": \(start), "turns_total": \(all.count), "prefix_hash": "\(Self.fingerprint(all[..<start]))"}
        """
    }

    func page(_ body: [String: Any]) -> String {
        let all = served
        let before = body["beforeIndex"] as? Int ?? 0
        let limit = body["limit"] as? Int ?? 150
        let end = min(before, all.count)
        let start = alignBack(all, max(0, end - limit))
        return """
        {"turns": [\(json(all[start..<end]))], "turns_offset": \(start), "turns_total": \(all.count),
         "assistant_turns_before_offset": 0, "prefix_hash": "\(Self.fingerprint(all[..<start]))",
         "prefix_hash_before_index": "\(Self.fingerprint(all[..<end]))"}
        """
    }

    private func alignBack(_ all: [Turn], _ start: Int) -> Int {
        var i = start
        while i > 0, i < all.count, all[i].role != "user" { i -= 1 }
        return i
    }

    private func json(_ turns: ArraySlice<Turn>) -> String {
        turns.map { t in
            #"{"id": "\#(t.id)", "role": "\#(t.role)", "blocks": [{"type": "text", "text": "\#(t.text)"}], "timestamp": "\#(t.timestamp)"}"#
        }.joined(separator: ", ")
    }

    /// The server's fingerprint, written out byte by byte.
    static func fingerprint(_ turns: ArraySlice<Turn>) -> String {
        var bytes: [UInt8] = []
        for turn in turns {
            bytes.append(turn.role == "user" ? 0 : turn.role == "assistant" ? 1 : 2)
            let millis = UInt64(bitPattern: TranscriptTime.millis(turn.timestamp)!)
            for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((millis >> UInt64(shift)) & 0xff)) }
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

// MARK: - Times and fingerprints

final class TranscriptTimeTests: XCTestCase {
    func testReadsTheServersTimestampsToTheMillisecond() {
        XCTAssertEqual(TranscriptTime.millis("2026-10-04T16:00:00Z"), 1_791_129_600_000)
        XCTAssertEqual(TranscriptTime.millis("2026-10-04T16:00:05.25Z"), 1_791_129_605_250)
        XCTAssertEqual(TranscriptTime.millis("2026-10-04T16:00:09.999Z"), 1_791_129_609_999)
        // chrono cuts the fraction to milliseconds; it never rounds.
        XCTAssertEqual(TranscriptTime.millis("2026-10-09T11:41:43.178776Z"), 1_791_546_103_178)
        XCTAssertEqual(TranscriptTime.millis("2026-10-09T11:41:43.178999999Z"), 1_791_546_103_178)
        // An offset is the same instant.
        XCTAssertEqual(TranscriptTime.millis("2026-10-04T19:00:00.500+03:00"), 1_791_129_600_500)
        XCTAssertEqual(TranscriptTime.millis("1969-12-31T23:59:59.500Z"), -500)
    }

    func testRejectsWhatIsNotRFC3339() {
        for text in ["", "2026-10-04", "2026-10-04T16:00:00", "2026-13-04T16:00:00Z", "2026-10-04T16:00:00.Z",
                     "2026-10-04T16:00:00Zjunk", "yesterday"] {
            XCTAssertNil(TranscriptTime.millis(text), text)
        }
    }

    func testWritesMillisecondsThatReadBackTheSame() {
        for millis: Int64 in [0, 1_791_129_609_999, 1_791_546_103_178, -500, 951_782_400_123] {
            XCTAssertEqual(TranscriptTime.millis(TranscriptTime.string(millis: millis)), millis)
        }
        XCTAssertEqual(TranscriptTime.string(millis: 1_791_129_605_250), "2026-10-04T16:00:05.250Z")
    }

    func testATranscriptTurnKeepsTheServersMilliseconds() throws {
        let json = #"{"id": "turn-0", "role": "user", "blocks": [], "timestamp": "2026-10-09T11:41:43.178776Z"}"#
        let turn = try CodegJSON.decoder.decode(MessageTurn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.serverMillis, 1_791_546_103_178)
        XCTAssertEqual(turn.timestamp.timeIntervalSince1970, 1_791_546_103.178, accuracy: 0.0005)
    }
}

final class TranscriptFingerprintTests: XCTestCase {
    private func turn(_ role: TurnRole, _ text: String) -> MessageTurn {
        let millis = TranscriptTime.millis(text)!
        return MessageTurn(id: text, role: role, blocks: [], timestamp: Date(), serverMillis: millis)
    }

    /// Values computed by the server's algorithm outside the app.
    func testMatchesTheServersFingerprint() {
        let turns = [
            turn(.user, "2026-10-04T16:00:00.000Z"),
            turn(.assistant, "2026-10-04T16:00:05.250Z"),
            turn(.assistant, "2026-10-04T16:00:09.999Z"),
            turn(.user, "2026-10-04T16:01:00Z"),
        ]
        XCTAssertEqual(TranscriptFingerprint.extend(TranscriptFingerprint.empty, over: []), "cbf29ce484222325")
        XCTAssertEqual(TranscriptFingerprint.extend(TranscriptFingerprint.empty, over: turns[..<2]), "0de3836406d7e602")
        XCTAssertEqual(TranscriptFingerprint.extend(TranscriptFingerprint.empty, over: turns), "291bd7cb11685eb0")
        // Chained: extending the fingerprint of the first two by the rest.
        XCTAssertEqual(TranscriptFingerprint.extend("0de3836406d7e602", over: turns[2...]), "291bd7cb11685eb0")
    }

    func testAPhoneMadeTurnHasNoFingerprint() {
        let local = MessageTurn(id: "pending", role: .user, blocks: [], timestamp: Date())
        XCTAssertNil(TranscriptFingerprint.extend(TranscriptFingerprint.empty, over: [local]))
        XCTAssertNil(TranscriptFingerprint.extend("not-hex", over: []))
    }
}

// MARK: - Window requests and merges

final class TranscriptSyncPlanTests: XCTestCase {
    private func window(offset: Int, count: Int, prefixHash: String?) -> TranscriptWindow {
        let turns = (offset..<(offset + count)).map { index -> MessageTurn in
            let millis = 1_791_129_600_000 + Int64(index) * 1000
            return MessageTurn(id: "turn-\(index)", role: index % 5 == 0 ? .user : .assistant, blocks: [],
                               timestamp: Date(), serverMillis: millis)
        }
        return TranscriptWindow(offset: offset, prefixHash: prefixHash, total: offset + count, turns: turns)
    }

    func testNothingHeldAsksForTheTail() {
        XCTAssertEqual(TranscriptSync.request(for: nil, overlap: 8), .tail(TranscriptSync.tailTurns))
    }

    func testAHeldWindowAsksOnlyForItsLastTurns() {
        let held = window(offset: 100, count: 50, prefixHash: "0123456789abcdef")
        guard case .from(let index, let expected) = TranscriptSync.request(for: held, overlap: 8) else {
            return XCTFail("expected a fromIndex request")
        }
        XCTAssertEqual(index, 142)
        XCTAssertEqual(expected, TranscriptFingerprint.extend("0123456789abcdef", over: held.turns[..<42]))
        // An overlap wider than the window starts at the window.
        guard case .from(let start, let hash) = TranscriptSync.request(for: held, overlap: 500) else {
            return XCTFail("expected a fromIndex request")
        }
        XCTAssertEqual(start, 100)
        XCTAssertEqual(hash, "0123456789abcdef")
    }

    func testAPhoneMadeTurnAtTheEndIsFetchedAgain() {
        var held = window(offset: 0, count: 10, prefixHash: TranscriptFingerprint.empty)
        held.turns.append(MessageTurn(id: "local", role: .assistant, blocks: [.text("kept")], timestamp: Date()))
        guard case .from(let index, _) = TranscriptSync.request(for: held, overlap: 2) else {
            return XCTFail("expected a fromIndex request")
        }
        XCTAssertEqual(index, 8, "counted back from the server's turns, not the phone's")
    }

    func testAJoiningResponseIsMerged() throws {
        let held = window(offset: 10, count: 20, prefixHash: "00000000000000aa")
        let request = TranscriptSync.request(for: held, overlap: 5)
        guard case .from(let index, let expected) = request else { return XCTFail() }
        var response = try detail(turns: Array(held.turns[(index - 10)...]) + [extraTurn(30), extraTurn(31)])
        response.turnsOffset = index
        response.turnsTotal = 32
        response.prefixHash = expected
        let outcome = try XCTUnwrap(TranscriptSync.merge(held: held, request: request, response: response))
        XCTAssertTrue(outcome.continuesHeld)
        XCTAssertEqual(outcome.window.offset, 10)
        XCTAssertEqual(outcome.window.end, 32)
        XCTAssertEqual(outcome.window.prefixHash, "00000000000000aa")
        XCTAssertEqual(outcome.detail.turns.count, 22)
    }

    func testARewrittenPrefixDoesNotJoin() throws {
        let held = window(offset: 0, count: 20, prefixHash: TranscriptFingerprint.empty)
        let request = TranscriptSync.request(for: held, overlap: 5)
        var response = try detail(turns: [extraTurn(15)])
        response.turnsOffset = 15
        response.turnsTotal = 16
        response.prefixHash = "ffffffffffffffff"
        XCTAssertNil(TranscriptSync.merge(held: held, request: request, response: response))
    }

    func testAnOlderServersWholeTranscriptIsTakenAsIs() throws {
        let held = window(offset: 0, count: 3, prefixHash: nil)
        let response = try detail(turns: (0..<5).map(extraTurn))
        let outcome = try XCTUnwrap(TranscriptSync.merge(held: held, request: .from(index: 0, expected: "x"),
                                                         response: response))
        XCTAssertFalse(outcome.continuesHeld)
        XCTAssertEqual(outcome.window.offset, 0)
        XCTAssertNil(outcome.window.prefixHash)
        XCTAssertEqual(outcome.window.turns.count, 5)
    }

    func testAnOlderPageJoinsOnlyTheWindowItWasAskedFor() throws {
        let held = window(offset: 40, count: 10, prefixHash: "00000000000000bb")
        let pageJSON = """
        {"turns": [], "turns_offset": 40, "turns_total": 50, "assistant_turns_before_offset": 0,
         "prefix_hash": "00000000000000cc", "prefix_hash_before_index": "00000000000000bb"}
        """
        var page = try CodegJSON.decoder.decode(ConversationTurnsPage.self, from: Data(pageJSON.utf8))
        XCTAssertNotNil(TranscriptSync.prepend(page: page, to: held))
        let otherJSON = pageJSON.replacingOccurrences(of: "\"prefix_hash_before_index\": \"00000000000000bb\"",
                                                      with: "\"prefix_hash_before_index\": \"00000000000000dd\"")
        page = try CodegJSON.decoder.decode(ConversationTurnsPage.self, from: Data(otherJSON.utf8))
        XCTAssertNil(TranscriptSync.prepend(page: page, to: held), "the history before the window changed")
    }

    private func extraTurn(_ index: Int) -> MessageTurn {
        MessageTurn(id: "turn-\(index)", role: .assistant, blocks: [.text("new \(index)")], timestamp: Date(),
                    serverMillis: 1_791_129_600_000 + Int64(index) * 1000)
    }

    private func detail(turns: [MessageTurn]) throws -> ConversationDetail {
        let json = """
        {"summary": {"id": 7, "folder_id": 1, "title": "t", "agent_type": "claude_code", "status": "pending_review",
          "message_count": 0, "created_at": "2026-10-04T16:00:00Z", "updated_at": "2026-10-04T16:20:00Z"},
         "turns": [], "session_stats": null}
        """
        var detail = try CodegJSON.decoder.decode(ConversationDetail.self, from: Data(json.utf8))
        detail.turns = turns
        return detail
    }
}

// MARK: - The session screen against a windowed server

@MainActor
final class TranscriptWindowSessionTests: XCTestCase {
    private var server: MockCodegServer!
    private var transcript: WindowedTranscriptServer!
    private var models: [SessionDetailViewModel] = []
    private var cacheRoot: URL!

    override func setUp() async throws {
        server = MockCodegServer()
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
        transcript = nil
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func makeModel(cache: TranscriptCache? = nil) -> SessionDetailViewModel {
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() }, transcriptCache: cache)
        models.append(model)
        return model
    }

    private func windowRequests() -> [[String: Any]] {
        server.calls("get_folder_conversation").map(\.body)
    }

    func testALongSessionOpensWithItsLatestTurnsAndPagesOlderOnes() async {
        transcript = WindowedTranscriptServer(count: 400)
        transcript.install(on: server)
        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(windowRequests().first?["tailTurns"] as? Int, TranscriptSync.tailTurns)
        XCTAssertEqual(model.turnsOffset + model.turns.count, 400)
        XCTAssertLessThanOrEqual(model.turns.count, TranscriptSync.tailTurns + 5)
        XCTAssertEqual(model.turns.first?.role, .user, "the window starts on a prompt")
        XCTAssertTrue(model.hasOlderTurns)

        var pages = 0
        while model.hasOlderTurns, pages < 10 {
            let before = model.turnsOffset
            await model.loadOlderTurns()
            XCTAssertLessThan(model.turnsOffset, before)
            pages += 1
        }
        XCTAssertEqual(model.turnsOffset, 0)
        XCTAssertEqual(model.turns.count, 400)
        XCTAssertEqual(model.turns.map(\.id), (0..<400).map { "turn-\($0)" })
    }

    func testARefreshFetchesOnlyWhatChanged() async {
        transcript = WindowedTranscriptServer(count: 300)
        transcript.install(on: server)
        let model = makeModel()
        await model.load()
        // Scrolled up once: the screen holds more than a refresh re-reads.
        await model.loadOlderTurns()
        XCTAssertEqual(model.turnsOffset, 30)
        let kept = Array(model.turns.prefix(150))

        transcript.append(3)
        await model.refreshOnForeground()

        let refresh = windowRequests().last
        XCTAssertNil(refresh?["tailTurns"])
        XCTAssertEqual(refresh?["fromIndex"] as? Int, 300 - TranscriptSync.reopenOverlap,
                       "only the last turns held, and the new ones, are fetched")
        XCTAssertEqual(model.turnsOffset, 30)
        XCTAssertEqual(model.turnsOffset + model.turns.count, 303)
        XCTAssertEqual(model.turns.last?.id, "turn-302")
        XCTAssertEqual(Array(model.turns.prefix(150)), kept, "the turns before them stay as they were")
    }

    func testRewrittenHistoryStartsOverFromTheEnd() async {
        transcript = WindowedTranscriptServer(count: 300)
        transcript.install(on: server)
        let model = makeModel()
        await model.load()

        // A compaction: the turns before the window are no longer the same.
        var turns = transcript.turns
        turns.removeSubrange(10..<20)
        transcript.turns = turns
        await model.refreshOnForeground()

        let requests = windowRequests()
        XCTAssertNotNil(requests.last?["tailTurns"], "the delta didn't join, so a fresh tail was fetched")
        XCTAssertEqual(model.turnsOffset + model.turns.count, 290)
        XCTAssertEqual(model.turns.last?.id, "turn-299")
    }

    func testAStaleReadNeverTakesTurnsAway() async {
        transcript = WindowedTranscriptServer(count: 200)
        transcript.install(on: server)
        let model = makeModel()
        await model.load()
        let shown = model.turns

        transcript.visibleCount = 195
        await model.refreshOnForeground()
        XCTAssertEqual(model.turns, shown, "a server behind the screen leaves the screen alone")
    }

    func testAnOlderServerStillGetsTheWholeTranscript() async {
        transcript = WindowedTranscriptServer(count: 30)
        transcript.legacy = true
        transcript.install(on: server)
        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.turns.count, 30)
        XCTAssertEqual(model.turnsOffset, 0)
        XCTAssertFalse(model.hasOlderTurns)
        transcript.append(2)
        await model.refreshOnForeground()
        XCTAssertEqual(model.turns.count, 32)
    }

    // MARK: Cache

    func testACachedSessionShowsAtOnceEvenWhenTheServerIsUnreachable() async throws {
        transcript = WindowedTranscriptServer(count: 200)
        transcript.install(on: server)
        let cache = TranscriptCache(root: cacheRoot)
        let first = makeModel(cache: cache)
        await first.load()
        let shown = first.turns
        // The save is debounced; give it a moment, then check it landed.
        let saved = await eventuallyAsync { await cache.contains(serverKey: TranscriptCache.serverKey(for: self.server.client),
                                                                 conversationID: Fixtures.conversationID) }
        XCTAssertTrue(saved)

        server.on("get_folder_conversation") { _ in .fail(.notConnectedToInternet) }
        let second = makeModel(cache: cache)
        await second.load()
        XCTAssertEqual(second.phase, .loaded, "the saved copy shows, not an error")
        XCTAssertTrue(second.openedFromCache)
        XCTAssertEqual(second.turns, shown)
        XCTAssertEqual(second.summary?.title, "Long session")
    }

    func testACachedSessionAsksOnlyForWhatChangedSinceItWasSaved() async throws {
        transcript = WindowedTranscriptServer(count: 250)
        transcript.install(on: server)
        let cache = TranscriptCache(root: cacheRoot)
        let first = makeModel(cache: cache)
        await first.load()
        let key = TranscriptCache.serverKey(for: server.client)
        _ = await eventuallyAsync { await cache.contains(serverKey: key, conversationID: Fixtures.conversationID) }

        transcript.append(4)
        let before = windowRequests().count
        let second = makeModel(cache: cache)
        await second.load()

        let requests = Array(windowRequests().dropFirst(before))
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?["tailTurns"], "no fresh tail: the cache's window is extended")
        XCTAssertNotNil(requests.first?["fromIndex"])
        XCTAssertEqual(second.turnsOffset + second.turns.count, 254)
        XCTAssertEqual(second.turns.last?.id, "turn-253")

        let updated = await eventuallyAsync {
            await cache.load(serverKey: key, conversationID: Fixtures.conversationID)?.turns.last?.id == "turn-253"
        }
        XCTAssertTrue(updated, "the cache holds what the screen now shows")
    }

    /// Poll an async condition until it holds or `timeout` passes.
    private func eventuallyAsync(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}
