import XCTest
@testable import Codeg

/// The codeg fork's live background status (`background` on the conversation
/// list): decoding, `SessionActivity` against the rules of codeg's
/// `deriveSessionActivity`, and where Activity and the folder counts put a
/// session with background work. Against a server without the field the app
/// behaves exactly as before.
@MainActor
final class BackgroundStatusTests: XCTestCase {
    private func summaryJSON(_ id: Int, status: String = "pending_review", turnState: String = "null",
                             hoursAgo: Double = 1, background: String? = nil) -> String {
        let updated = TranscriptTime.string(date: Date().addingTimeInterval(-hoursAgo * 3600))
        let bg = background.map { #", "background": \#($0)"# } ?? ""
        return """
        {"id": \(id), "folder_id": 1, "title": "Session \(id)", "agent_type": "claude_code", "status": "\(status)",
         "message_count": 4, "created_at": "2026-10-14T08:00:00Z", "updated_at": "\(updated)",
         "turn_state": \(turnState)\(bg)}
        """
    }

    private func decode(_ json: String) throws -> ConversationSummary {
        try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
    }

    private let twoTasks = """
    {"task_count": 2, "tasks": [
      {"id": "bm227ltpx", "kind": "shell", "label": "Wait for runs, then judge, recall, and aggregate"},
      {"id": "bq4s928n8", "kind": "monitor", "label": "main run: errors"}],
     "out_of_turn": false, "held_open": false}
    """

    // MARK: - Decoding

    func testDecodesTheBackgroundStatus() throws {
        let summary = try decode(summaryJSON(144, background: twoTasks))
        let bg = try XCTUnwrap(summary.background)
        XCTAssertEqual(bg.taskCount, 2)
        XCTAssertEqual(bg.tasks.map(\.kind), ["shell", "monitor"])
        XCTAssertFalse(bg.outOfTurn)
        XCTAssertFalse(bg.heldOpen)
        XCTAssertTrue(bg.isActive)
        XCTAssertEqual(bg.taskLines, [
            "Shell: Wait for runs, then judge, recall, and aggregate",
            "Monitor: main run: errors",
        ])
    }

    func testAnOlderServerHasNoBackground() throws {
        XCTAssertNil(try decode(summaryJSON(1)).background)
    }

    func testAnOddBackgroundNeverFailsTheList() throws {
        // A shape this build doesn't know (a string, a task without an id):
        // the session still decodes.
        XCTAssertNil(try decode(summaryJSON(1, background: #""busy""#)).background)
        let partial = try decode(summaryJSON(2, background: #"{"task_count": 3, "tasks": [{"kind": "shell"}]}"#))
        XCTAssertEqual(partial.background?.taskCount, 3)
        XCTAssertEqual(partial.background?.tasks, [])
        XCTAssertEqual(partial.background?.outOfTurn, false)
    }

    func testRoundTripsThroughTheCache() throws {
        let summary = try decode(summaryJSON(144, background: twoTasks))
        let again = try CodegJSON.decoder.decode(ConversationSummary.self,
                                                 from: CodegJSON.encoder.encode(summary))
        XCTAssertEqual(again.background, summary.background)
    }

    // MARK: - Activity

    func testTasksAfterTheTurnEndedReadAsBackground() throws {
        let summary = try decode(summaryJSON(144, background: twoTasks))
        XCTAssertEqual(SessionActivity.of(summary), .background(count: 2))
        XCTAssertEqual(SessionActivity.of(summary).label(), "Idle — 2 background tasks running")
    }

    func testTheAgentRunningATurnOfItsOwnIsWorking() throws {
        let summary = try decode(summaryJSON(144, background: #"{"task_count": 1, "out_of_turn": true}"#))
        XCTAssertEqual(SessionActivity.of(summary), .working)
        // A live idle connection doesn't know about that turn.
        var inputs = SessionActivityInputs(turnState: nil, connectionStatus: .connected)
        inputs.background = summary.background
        XCTAssertEqual(SessionActivity.derive(inputs), .working)
    }

    func testAHeldTurnReadsAsBackgroundNotWorking() throws {
        let summary = try decode(summaryJSON(144, status: "in_progress", turnState: #""running""#,
                                             background: #"{"task_count": 0, "held_open": true}"#))
        XCTAssertEqual(SessionActivity.of(summary), .background(count: 0))
        // This client's own prompting connection outranks it.
        var inputs = SessionActivityInputs(turnState: .running, connectionStatus: .prompting)
        inputs.background = summary.background
        XCTAssertEqual(SessionActivity.derive(inputs), .working)
    }

    func testAttentionAndInterruptionKeepTheirPlace() throws {
        let bg = ConversationBackground(taskCount: 1)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(attention: "question", background: bg)),
                       .needsYou)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .interrupted, background: bg)),
                       .interrupted)
        // A normal turn stays Working with tasks around it.
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .running, background: bg)),
                       .working)
    }

    func testWithoutTheFieldEverythingIsAsBefore() {
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: nil)), .idle)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .running)), .working)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: nil,
                                                                    background: ConversationBackground())),
                       .idle)
    }

    // MARK: - Lists

    func testActivityListsBackgroundWorkUnderRunning() async throws {
        let server = MockCodegServer()
        let sessions = [
            summaryJSON(1, status: "in_progress", turnState: #""running""#),
            summaryJSON(2, background: twoTasks),
            summaryJSON(3, hoursAgo: 40, background: #"{"task_count": 0, "out_of_turn": true}"#),
            summaryJSON(4),
            summaryJSON(5, background: #"{"task_count": 0, "out_of_turn": false, "held_open": false}"#),
        ]
        server.on("list_all_conversations") { _ in .body("[" + sessions.joined(separator: ", ") + "]") }
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body("[]") }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        XCTAssertEqual(Set(activity.running.map(\.id)), [1, 2, 3],
                       "an open turn, tasks after the turn, and a turn of the agent's own")
        XCTAssertEqual(Set(activity.recent.map(\.id)), [4, 5], "nothing in the background is not running")
        XCTAssertTrue(activity.earlier.isEmpty, "a running session never drops to Earlier, however old")
        XCTAssertEqual(activity.runningCount(folderID: 1), 3)
    }

    func testActivityAgainstAnOlderServerIsUnchanged() async throws {
        let server = MockCodegServer()
        let sessions = [summaryJSON(1, status: "in_progress", turnState: #""running""#), summaryJSON(2)]
        server.on("list_all_conversations") { _ in .body("[" + sessions.joined(separator: ", ") + "]") }
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body("[]") }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)
        XCTAssertEqual(activity.running.map(\.id), [1])
        XCTAssertEqual(activity.recent.map(\.id), [2])
        XCTAssertEqual(activity.runningCount(folderID: 1), 1)
    }
}
