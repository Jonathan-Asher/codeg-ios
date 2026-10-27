import XCTest
@testable import Codeg

/// Session recency (codeg fork `last_viewed_at`): the lists order by the
/// later of a session's last activity and the last time the user opened it,
/// and opening a session here tells the server (`mark_conversations_viewed`).
@MainActor
final class SessionRecencyTests: XCTestCase {
    private static let folderJSON = """
    {"id": 1, "name": "codeg", "path": "/p/1", "git_branch": "main", "default_agent_type": null,
     "last_opened_at": "2026-09-01T08:00:00Z", "sort_order": 1, "color": "inherit", "parent_id": null,
     "kind": "regular"}
    """

    private static func iso(minutesAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(-minutesAgo * 60))
    }

    private static func summaryJSON(_ id: Int, updatedMinutesAgo: Double, viewedMinutesAgo: Double?) -> String {
        let viewed = viewedMinutesAgo.map { "\"\(iso(minutesAgo: $0))\"" } ?? "null"
        return """
        {"id": \(id), "folder_id": 1, "title": "Session \(id)", "agent_type": "claude_code",
         "status": "pending_review", "message_count": 4, "created_at": "2026-09-01T08:00:00Z",
         "updated_at": "\(iso(minutesAgo: updatedMinutesAgo))", "turn_state": null, "pinned_at": null,
         "last_viewed_at": \(viewed)}
        """
    }

    func testDecodesLastViewedAtAndOrdersByTheLaterOfTheTwo() throws {
        let viewedLater = try CodegJSON.decoder.decode(
            ConversationSummary.self, from: Data(Self.summaryJSON(1, updatedMinutesAgo: 60, viewedMinutesAgo: 2).utf8))
        let lastViewed = try XCTUnwrap(viewedLater.lastViewedAt)
        XCTAssertEqual(viewedLater.recency, lastViewed)
        XCTAssertGreaterThan(viewedLater.recency, viewedLater.updatedAt)

        let activeLater = try CodegJSON.decoder.decode(
            ConversationSummary.self, from: Data(Self.summaryJSON(2, updatedMinutesAgo: 1, viewedMinutesAgo: 30).utf8))
        XCTAssertEqual(activeLater.recency, activeLater.updatedAt)

        // An older server sends no field: the last activity alone.
        let old = try CodegJSON.decoder.decode(ConversationSummary.self, from: Data("""
        {"id": 3, "folder_id": 1, "agent_type": "claude_code", "status": "completed", "message_count": 1,
         "created_at": "2026-09-01T08:00:00Z", "updated_at": "2026-09-02T08:00:00Z"}
        """.utf8))
        XCTAssertNil(old.lastViewedAt)
        XCTAssertEqual(old.recency, old.updatedAt)

        // Kept in the saved lists, which encode the summaries again.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try CodegJSON.decoder.decode(ConversationSummary.self, from: try encoder.encode(viewedLater))
        XCTAssertEqual(again.lastViewedAt?.timeIntervalSince1970 ?? 0, lastViewed.timeIntervalSince1970, accuracy: 1)
    }

    func testTheChatsListPutsARecentlyOpenedSessionFirst() async throws {
        let server = MockCodegServer()
        let rows = [
            Self.summaryJSON(10, updatedMinutesAgo: 5, viewedMinutesAgo: nil),
            Self.summaryJSON(11, updatedMinutesAgo: 120, viewedMinutesAgo: 1),
            Self.summaryJSON(12, updatedMinutesAgo: 30, viewedMinutesAgo: 200),
        ].joined(separator: ", ")
        server.on("list_all_conversations") { _ in .body("[\(rows)]") }
        server.on("list_all_folder_details") { _ in .body("[\(Self.folderJSON)]") }
        server.on("list_open_folder_details") { _ in .body("[\(Self.folderJSON)]") }
        server.on("list_conversation_attention") { _ in .body("[]") }

        let model = SessionListViewModel(client: server.client)
        await model.load()
        XCTAssertEqual(model.folderGroups(searchText: "").first?.conversations.map(\.id), [11, 10, 12])
    }

    func testOpeningASessionTellsTheServerOnceForTheBatch() async throws {
        let server = MockCodegServer()
        server.on("mark_conversations_viewed") { _ in .body("null") }
        let views = ConversationViews()
        let now = Date()
        views.record(42, client: server.client, at: now.addingTimeInterval(-2))
        views.record(7, client: server.client, at: now)
        views.record(42, client: server.client, at: now)
        await views.flush()

        let calls = server.calls("mark_conversations_viewed")
        XCTAssertEqual(calls.count, 1)
        let reports = try XCTUnwrap(calls.first?.body["views"] as? [[String: Any]])
        XCTAssertEqual(reports.map { $0["conversationId"] as? Int }, [7, 42])
        for report in reports {
            let age = try XCTUnwrap(report["ageMs"] as? Int)
            XCTAssertTrue((0..<10_000).contains(age), "\(age)")
        }
    }

    func testReportsCarryTheirAge() {
        let now = Date()
        let reports = ConversationViews.reports([5: now.addingTimeInterval(-1.5), 3: now.addingTimeInterval(1)], now: now)
        XCTAssertEqual(reports, [ConversationViewReport(conversationId: 3, ageMs: 0),
                                 ConversationViewReport(conversationId: 5, ageMs: 1500)])
    }

    func testAnOlderServerIsNotAskedAgain() async throws {
        let server = MockCodegServer()
        server.on("mark_conversations_viewed") { _ in .status(404, "{\"message\": \"Not Found\"}") }
        let views = ConversationViews()
        views.record(1, client: server.client)
        await views.flush()
        views.record(2, client: server.client)
        await views.flush()
        XCTAssertEqual(server.calls("mark_conversations_viewed").count, 1)
    }
}
