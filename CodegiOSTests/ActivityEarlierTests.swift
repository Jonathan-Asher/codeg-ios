import XCTest
@testable import Codeg

/// Activity keeps its 24-hour window, and lists older sessions on demand
/// ("Earlier") instead of letting them vanish; the transcript prefetcher
/// picks the sessions that just finished a turn.
@MainActor
final class ActivityEarlierTests: XCTestCase {
    private func summary(_ id: Int, hoursAgo: Double, status: String = "pending_review") -> String {
        let updated = TranscriptTime.string(date: Date().addingTimeInterval(-hoursAgo * 3600))
        return """
        {"id": \(id), "folder_id": 1, "title": "Session \(id)", "agent_type": "claude_code", "status": "\(status)",
         "message_count": 4, "created_at": "2026-09-01T08:00:00Z", "updated_at": "\(updated)", "turn_state": null}
        """
    }

    private func decode(_ json: String) throws -> ConversationSummary {
        try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
    }

    func testOlderSessionsAreListedOnlyWhenAskedForAPageAtATime() async throws {
        let server = MockCodegServer()
        let older = (0..<25).map { summary(100 + $0, hoursAgo: 30 + Double($0)) }
        let all = [summary(1, hoursAgo: 0.1, status: "in_progress"), summary(2, hoursAgo: 3)] + older
        server.on("list_all_conversations") { _ in .body("[" + all.joined(separator: ", ") + "]") }
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body("[]") }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        XCTAssertEqual(activity.running.map(\.id), [1])
        XCTAssertEqual(activity.recent.map(\.id), [2], "the 24-hour window is kept")
        XCTAssertEqual(activity.earlier.count, 25)
        XCTAssertEqual(activity.earlier.first?.id, 100, "most recent first")
        XCTAssertEqual(activity.earlierShown, 0, "none until asked")

        activity.showMoreEarlier()
        XCTAssertEqual(activity.earlierShown, ActivityModel.earlierPage)
        activity.showMoreEarlier()
        XCTAssertEqual(activity.earlierShown, 25)
        activity.reset()
        XCTAssertEqual(activity.earlierShown, 0, "a new server starts folded")
    }

    func testEarlierSitsAtTheOldEndOfTheFeed() throws {
        let running = [try decode(summary(1, hoursAgo: 0.1, status: "in_progress"))]
        let recent = [try decode(summary(2, hoursAgo: 2)), try decode(summary(3, hoursAgo: 5))]
        let earlier = [try decode(summary(4, hoursAgo: 30)), try decode(summary(5, hoursAgo: 60))]

        let newestFirst = ActivityFeedLayout.sections(running: running, recent: recent, earlier: earlier,
                                                      newestAtBottom: false)
        XCTAssertEqual(newestFirst.map(\.kind), [.running, .recent, .earlier])
        XCTAssertEqual(newestFirst.flatMap(\.rows).map(\.id), [1, 2, 3, 4, 5])

        let newestAtBottom = ActivityFeedLayout.sections(running: running, recent: recent, earlier: earlier,
                                                         newestAtBottom: true)
        XCTAssertEqual(newestAtBottom.map(\.kind), [.earlier, .recent, .running])
        XCTAssertEqual(newestAtBottom.flatMap(\.rows).map(\.id), [5, 4, 3, 2, 1], "oldest at the top")
    }

    func testTheEarlierControlSaysWhatIsLeft() {
        XCTAssertEqual(ActivityFeedLayout.earlierControl(total: 0, shown: 0), .none)
        XCTAssertEqual(ActivityFeedLayout.earlierControl(total: 25, shown: 0), .show(total: 25))
        XCTAssertEqual(ActivityFeedLayout.earlierControl(total: 25, shown: 20), .more(remaining: 5))
        XCTAssertEqual(ActivityFeedLayout.earlierControl(total: 25, shown: 25), .allShown)
    }

    func testThePrefetcherPicksSessionsThatJustFinishedATurn() throws {
        let prefetcher = TranscriptPrefetcher(cache: nil)
        let idle = try decode(summary(1, hoursAgo: 1))
        let running = try decode(summary(2, hoursAgo: 0.05, status: "in_progress"))
        XCTAssertEqual(prefetcher.finished(shown: [idle, running], excluding: []), [], "first sight only records")

        let idleUpdated = try decode(summary(1, hoursAgo: 0.01))
        let finished = try decode(summary(2, hoursAgo: 0.05))
        XCTAssertEqual(Set(prefetcher.finished(shown: [idleUpdated, finished], excluding: [])), [1, 2])
        XCTAssertEqual(prefetcher.finished(shown: [idleUpdated, finished], excluding: []), [], "nothing new since")

        let again = try decode(summary(1, hoursAgo: 0.001))
        XCTAssertEqual(prefetcher.finished(shown: [again], excluding: [1]), [], "the session on screen keeps its own")
    }
}
