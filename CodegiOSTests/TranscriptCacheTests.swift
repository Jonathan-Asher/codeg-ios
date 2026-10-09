import XCTest
@testable import Codeg

/// The on-device transcript cache: what it keeps, how it stays inside its
/// size cap (least recently used first), and that a server whose URL or
/// token changes starts from nothing. Every transcript here is synthetic.
final class TranscriptCacheTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tcache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func summary(_ id: Int) throws -> ConversationSummary {
        let json = """
        {"id": \(id), "folder_id": 1, "title": "Session \(id)", "agent_type": "codex", "status": "pending_review",
         "message_count": 3, "created_at": "2026-10-01T08:00:00Z", "updated_at": "2026-10-02T09:30:00Z",
         "turn_state": null, "pinned_at": null}
        """
        return try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
    }

    private func entry(_ id: Int, turns count: Int = 3, padding: Int = 0) throws -> CachedTranscript {
        let picture = ImageData(data: String(repeating: "A", count: 64), mimeType: "image/png", uri: nil)
        let turns = (0..<count).map { index in
            let millis = 1_791_129_600_000 + Int64(index) * 1000 + 7
            return MessageTurn(
                id: "turn-\(index)",
                role: index == 0 ? .user : .assistant,
                blocks: index == 0
                    ? [.text("Draw the chart" + String(repeating: " ", count: padding)), .image(picture)]
                    : [.thinking("Planning"),
                       .toolUse(id: "t\(index)", name: "Read", inputPreview: "{\"path\":\"a.png\"}",
                                meta: .object(["codeg.delegation": .object(["status": .string("done")])])),
                       .toolResult(id: "t\(index)", outputPreview: "ok", isError: false, images: [picture]),
                       .text("Here it is.")],
                timestamp: Date(timeIntervalSince1970: Double(millis) / 1000),
                usage: TurnUsage(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 0, cacheReadInputTokens: 5),
                durationMs: 1200,
                model: "gpt-5",
                serverMillis: millis
            )
        }
        var summary = try summary(id)
        summary.selectorState = ConversationSelectorState(modeId: "plan", configValues: ["reasoning_effort": "high"])
        return CachedTranscript(conversationID: id, savedAt: Date(), summary: summary,
                                selectorState: summary.selectorState, sessionStats: nil, folder: nil,
                                turnsOffset: 40, prefixHash: "0123456789abcdef", turnsTotal: 40 + count, turns: turns)
    }

    func testATranscriptComesBackAsItWasSaved() async throws {
        let cache = TranscriptCache(root: root)
        let saved = try entry(7)
        await cache.save(saved, serverKey: "server-a")
        let loaded = try await XCTUnwrapAsync(await cache.load(serverKey: "server-a", conversationID: 7))

        XCTAssertEqual(loaded.turns, saved.turns, "blocks, pictures, tool meta, usage and exact times")
        var summary = loaded.summary
        summary.selectorState = loaded.selectorState
        XCTAssertEqual(summary, saved.summary, "the selector state is kept beside the summary")
        XCTAssertEqual(loaded.selectorState?.configValues["reasoning_effort"], "high",
                       "config ids keep their underscores")
        XCTAssertEqual(loaded.turnsOffset, 40)
        XCTAssertEqual(loaded.prefixHash, "0123456789abcdef")
        XCTAssertEqual(loaded.window.end, 43)
        let missing = await cache.load(serverKey: "server-b", conversationID: 7)
        XCTAssertNil(missing, "another server's folder")
    }

    func testOnlyTheServersTurnsAreKept() async throws {
        let cache = TranscriptCache(root: root)
        var saved = try entry(8)
        saved.turns.append(MessageTurn(id: "unreconciled", role: .assistant, blocks: [.text("kept on the phone")],
                                       timestamp: Date()))
        await cache.save(saved, serverKey: "s")
        let loaded = await cache.load(serverKey: "s", conversationID: 8)
        XCTAssertEqual(loaded?.turns.count, 3)
        XCTAssertNil(loaded?.turns.first { $0.serverMillis == nil })
    }

    func testStaysUnderItsCapByDroppingTheLeastRecentlyUsed() async throws {
        // Each entry is about 10 KB; the cap holds about four.
        let cache = TranscriptCache(root: root, capBytes: 44_000)
        for id in 1...3 {
            await cache.save(try entry(id, padding: 10_000), serverKey: "s")
            try await Task.sleep(for: .milliseconds(20))
        }
        // Opening 1 makes it the most recently used.
        _ = await cache.load(serverKey: "s", conversationID: 1)
        try await Task.sleep(for: .milliseconds(20))
        for id in 4...5 {
            await cache.save(try entry(id, padding: 10_000), serverKey: "s")
            try await Task.sleep(for: .milliseconds(20))
        }
        let total = await cache.totalBytes()
        XCTAssertLessThanOrEqual(total, 44_000)
        let kept1 = await cache.contains(serverKey: "s", conversationID: 1)
        let kept2 = await cache.contains(serverKey: "s", conversationID: 2)
        let kept5 = await cache.contains(serverKey: "s", conversationID: 5)
        XCTAssertTrue(kept1, "recently opened")
        XCTAssertFalse(kept2, "the least recently used went first")
        XCTAssertTrue(kept5, "just saved")
    }

    func testAChangedURLOrTokenStartsFromNothing() async throws {
        let cache = TranscriptCache(root: root)
        let url = URL(string: "http://box.example:3080")!
        let old = TranscriptCache.serverKey(baseURL: url, token: "old-token")
        let new = TranscriptCache.serverKey(baseURL: url, token: "new-token")
        let moved = TranscriptCache.serverKey(baseURL: URL(string: "http://box2.example:3080")!, token: "old-token")
        XCTAssertNotEqual(old, new)
        XCTAssertNotEqual(old, moved)
        XCTAssertFalse(old.contains("old-token"), "the token is never written out")

        await cache.save(try entry(9), serverKey: old)
        await cache.save(try entry(9), serverKey: new)
        await cache.removeServers(except: [new])
        let oldGone = await cache.contains(serverKey: old, conversationID: 9)
        let newKept = await cache.contains(serverKey: new, conversationID: 9)
        XCTAssertFalse(oldGone)
        XCTAssertTrue(newKept)
    }

    func testAFileFromAnotherFormatIsDropped() async throws {
        let cache = TranscriptCache(root: root)
        var saved = try entry(10)
        saved.version = 999
        await cache.save(saved, serverKey: "s")
        let loaded = await cache.load(serverKey: "s", conversationID: 10)
        XCTAssertNil(loaded)
        let stillThere = await cache.contains(serverKey: "s", conversationID: 10)
        XCTAssertFalse(stillThere)
    }
}

/// `XCTUnwrap` for an async expression.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
