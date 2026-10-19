import XCTest
@testable import Codeg

/// Marking a session critical from the phone, as on the desktop: what the
/// list payload says, when Mark as Critical / Unmark Critical is offered, the
/// request body, and the session screen's mark shown at once and put back
/// when the server refuses it.
@MainActor
final class CriticalSessionTests: XCTestCase {
    private func summary(_ extra: String = #", "critical": false, "critical_stall": true"#) throws -> ConversationSummary {
        let json = """
        {"id": 7, "folder_id": 1, "title": "Topic", "agent_type": "claude_code", "status": "pending_review",
         "external_id": "ext-7", "message_count": 4, "created_at": "2026-10-14T08:00:00Z",
         "updated_at": "2026-10-14T08:20:00Z", "turn_state": null\(extra)}
        """
        return try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
    }

    func testTheListPayloadSaysWhetherASessionIsCritical() throws {
        let marked = try summary(#", "critical": true, "critical_stall": false, "parent_id": null"#)
        XCTAssertTrue(marked.criticalReported)
        XCTAssertTrue(marked.critical)
        XCTAssertFalse(marked.criticalStall)

        let older = try summary("")
        XCTAssertFalse(older.criticalReported, "a server without critical sessions sends no field")
        XCTAssertFalse(older.critical)

        // Kept through the transcript cache's round trip.
        let again = try CodegJSON.decoder.decode(ConversationSummary.self, from: CodegJSON.encoder.encode(marked))
        XCTAssertTrue(again.criticalReported)
        XCTAssertTrue(again.critical)
        XCTAssertFalse(again.criticalStall)
        let olderAgain = try CodegJSON.decoder.decode(ConversationSummary.self, from: CodegJSON.encoder.encode(older))
        XCTAssertFalse(olderAgain.criticalReported)
    }

    func testWhatTheMenusOffer() throws {
        XCTAssertEqual(CriticalSessionRules.action(for: try summary()), .mark)
        XCTAssertEqual(CriticalSessionRules.action(for: try summary(#", "critical": true"#)), .unmark)
        XCTAssertNil(CriticalSessionRules.action(for: try summary("")), "an older server: no item at all")
        XCTAssertNil(CriticalSessionRules.action(for: try summary(#", "critical": false, "parent_id": 3"#)),
                     "a sub-session is driven by its parent")
        XCTAssertEqual(CriticalSessionRules.action(for: try summary(#", "critical": true, "parent_id": 3"#)), .unmark,
                       "one marked anyway can still be unmarked")
        XCTAssertEqual(CriticalSessionRules.Action.mark.title, "Mark as Critical")
        XCTAssertEqual(CriticalSessionRules.Action.unmark.title, "Unmark Critical")
        XCTAssertEqual(CriticalSessionRules.failure("boom"), "Could not update the critical mark: boom")
    }

    func testTheRequestBody() async throws {
        let server = MockCodegServer()
        try await server.client.setCritical(conversationId: 7, critical: true)
        let mark = try XCTUnwrap(server.calls("update_conversation_critical").last)
        XCTAssertEqual(mark.body["conversationId"] as? Int, 7)
        XCTAssertEqual(mark.body["critical"] as? Bool, true)
        XCTAssertNil(mark.body["stall"], "the stall detection stays as it is")

        try await server.client.setCritical(conversationId: 7, critical: true, stall: false)
        XCTAssertEqual(server.calls("update_conversation_critical").last?.body["stall"] as? Bool, false)
        try await server.client.setCritical(conversationId: 7, critical: false)
        XCTAssertEqual(server.calls("update_conversation_critical").last?.body["critical"] as? Bool, false)
    }

    func testTheSessionScreenShowsTheMarkAtOnceAndPutsItBackOnARefusal() async throws {
        let server = MockCodegServer()
        let detail = """
        {"summary": {"id": 7, "folder_id": 1, "title": "Topic", "agent_type": "claude_code", "status": "pending_review",
          "external_id": "ext-7", "message_count": 0, "created_at": "2026-10-14T08:00:00Z",
          "updated_at": "2026-10-14T08:20:00Z", "turn_state": null, "critical": false, "critical_stall": true},
         "turns": [], "session_stats": null, "in_flight_user_turn_id": null}
        """
        server.on("get_folder_conversation") { _ in .body(detail) }
        let model = SessionDetailViewModel(client: server.client, conversationID: 7,
                                           makeEventStream: { _ in StreamFactory([]).make() }, transcriptCache: nil)
        model.loadIfNeeded()
        let loaded = await eventually { model.phase == .loaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.criticalAction, .mark)

        await model.setCritical(true)
        XCTAssertEqual(model.summary?.critical, true)
        XCTAssertEqual(model.criticalAction, .unmark)
        XCTAssertEqual(server.calls("update_conversation_critical").last?.body["critical"] as? Bool, true)

        // Stall detection off, from Session Details.
        await model.setCritical(true, stall: false)
        XCTAssertEqual(model.summary?.criticalStall, false)
        XCTAssertEqual(server.calls("update_conversation_critical").last?.body["stall"] as? Bool, false)

        server.on("update_conversation_critical") { _ in
            .status(500, #"{"code": "database_error", "message": "Database operation failed"}"#)
        }
        await model.setCritical(false)
        XCTAssertEqual(model.summary?.critical, true, "put back")
        XCTAssertEqual(model.notice?.hasPrefix("Could not update the critical mark: "), true)
        model.teardown()
    }
}
