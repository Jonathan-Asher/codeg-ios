import XCTest
import UserNotifications
@testable import Codeg

/// Question and reminder pushes (codeg `docs/ios-push.md` §5–6): the new
/// payload fields, older servers without them, the per-question category the
/// notification service extension registers, the ANSWER_<i> action and the
/// answer request it sends, and the badge in the foreground.
@MainActor
final class PendingPushTests: XCTestCase {
    /// The doc's question reminder.
    private func questionReminder(options: [String] = ["SQLite", "Postgres"], answerable: Bool = true,
                                  multiSelect: Bool = false, count: Int = 1) -> [AnyHashable: Any] {
        [
            "aps": [
                "alert": ["title": "Fix the login bug",
                          "body": "codeg · Claude Code is still waiting for your answer (30 min)\nWhich database should we use?"],
                "sound": "default",
                "thread-id": "3f9c0a1b2c4d-42",
                "category": "CODEG_QUESTION",
                "interruption-level": "time-sensitive",
                "badge": NSNumber(value: 2),
                "mutable-content": NSNumber(value: 1),
            ] as [String: Any],
            "server_id": "3f9c0a1b2c4d",
            "kind": "needs_you",
            "alert_id": "9a8b",
            "conversation_id": NSNumber(value: 42),
            "folder_id": NSNumber(value: 7),
            "agent_type": "claude_code",
            "needs": "question",
            "pending_id": "question:5e0f",
            "pending_kind": "question",
            "pending_since": "2026-10-26T09:00:00Z",
            "reminder": NSNumber(value: true),
            "attempt": NSNumber(value: 2),
            "connection_id": "c41d",
            "question": [
                "question_id": "5e0f",
                "item_id": "a17c",
                "text": "Which database should we use?",
                "header": "Storage",
                "multi_select": NSNumber(value: multiSelect),
                "options": options,
                "count": NSNumber(value: count),
                "answerable": NSNumber(value: answerable),
            ] as [String: Any],
        ]
    }

    // MARK: - Payload

    func testParsesEveryNewField() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: questionReminder()))
        XCTAssertEqual(payload.kind, "needs_you")
        XCTAssertEqual(payload.needs, "question")
        XCTAssertEqual(payload.category, PushCategory.question)
        XCTAssertEqual(payload.badge, 2)
        XCTAssertEqual(payload.pendingID, "question:5e0f")
        XCTAssertEqual(payload.pendingKind, "question")
        XCTAssertEqual(payload.pendingSince, ISO8601.parse("2026-10-26T09:00:00Z"))
        XCTAssertTrue(payload.reminder)
        XCTAssertEqual(payload.attempt, 2)
        XCTAssertEqual(payload.connectionID, "c41d")
        XCTAssertNil(payload.askingConversationID)
        XCTAssertFalse(payload.isBadgeOnly)
        let question = try XCTUnwrap(payload.question)
        XCTAssertEqual(question, PushQuestion(questionID: "5e0f", itemID: "a17c",
                                              text: "Which database should we use?", header: "Storage",
                                              multiSelect: false, options: ["SQLite", "Postgres"], count: 1,
                                              answerable: true))
    }

    func testSubAgentAndPlanFields() throws {
        var info = questionReminder()
        info["asking_conversation_id"] = NSNumber(value: 99)
        info["approval_id"] = "appr-1"
        info["reminder"] = NSNumber(value: false)
        info["attempt"] = NSNumber(value: 0)
        let payload = try XCTUnwrap(PushPayload(userInfo: info))
        XCTAssertEqual(payload.askingConversationID, 99)
        XCTAssertEqual(payload.approvalID, "appr-1")
        XCTAssertFalse(payload.reminder)
        XCTAssertEqual(payload.attempt, 0)
        // The parent opens.
        XCTAssertEqual(PushRouting.action(for: PushActionID.tap, payload: payload), .open(conversationID: 42, folderID: 7))
    }

    func testAnOlderServerSendsNoneOfThem() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: [
            "aps": ["alert": ["title": "t", "body": "b"], "category": "CODEG_PERMISSION"] as [String: Any],
            "server_id": "s1", "kind": "needs_you", "needs": "permission",
            "conversation_id": NSNumber(value: 5), "connection_id": "c", "request_id": "r",
        ]))
        XCTAssertNil(payload.badge)
        XCTAssertNil(payload.pendingID)
        XCTAssertNil(payload.pendingKind)
        XCTAssertNil(payload.pendingSince)
        XCTAssertFalse(payload.reminder)
        XCTAssertNil(payload.attempt)
        XCTAssertNil(payload.question)
        XCTAssertNil(payload.askingConversationID)
        XCTAssertNil(payload.approvalID)
    }

    func testBadgeOnlyPush() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: [
            "aps": ["badge": NSNumber(value: 1)] as [String: Any],
            "server_id": "3f9c0a1b2c4d", "kind": "badge", "alert_id": "x",
        ]))
        XCTAssertTrue(payload.isBadgeOnly)
        XCTAssertEqual(payload.badge, 1)
        XCTAssertNil(payload.conversationID)
        XCTAssertEqual(PushRouting.action(for: PushActionID.tap, payload: payload), .none)
    }

    func testAQuestionWithoutIDsIsNoQuestion() {
        XCTAssertNil(PushQuestion(["text": "Which?", "options": ["a"]] as [String: Any]))
        XCTAssertNil(PushQuestion(nil))
    }

    // MARK: - The answer action

    func testAnswerActionPicksTheLabel() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: questionReminder()))
        XCTAssertEqual(PushRouting.action(for: "ANSWER_1", payload: payload),
                       .answer(connectionID: "c41d", questionID: "5e0f", itemID: "a17c", label: "Postgres"))
        XCTAssertEqual(PushRouting.action(for: "ANSWER_0", payload: payload),
                       .answer(connectionID: "c41d", questionID: "5e0f", itemID: "a17c", label: "SQLite"))
        // Out of range, or nothing to answer with: open instead.
        XCTAssertEqual(PushRouting.action(for: "ANSWER_5", payload: payload), .open(conversationID: 42, folderID: 7))
        var info = questionReminder()
        info["question"] = nil
        let bare = try XCTUnwrap(PushPayload(userInfo: info))
        XCTAssertEqual(PushRouting.action(for: "ANSWER_0", payload: bare), .open(conversationID: 42, folderID: 7))
        XCTAssertEqual(PushRouting.action(for: "ANSWER_x", payload: payload), .none)
    }

    func testTheAnswerEncodesAsTheServerReadsIt() throws {
        let data = try CodegJSON.encoder.encode(PushRouting.answer(itemID: "a17c", label: "Postgres"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["declined"] as? Bool, false)
        let answers = try XCTUnwrap(object["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0]["questionId"] as? String, "a17c")
        XCTAssertEqual(answers[0]["labels"] as? [String], ["Postgres"])
    }

    func testTheAnswerRequest() async throws {
        let server = MockCodegServer()
        server.on("acp_answer_question") { _ in .body("null") }
        try await server.client.answerQuestion(connectionId: "c41d", questionId: "5e0f",
                                               answer: PushRouting.answer(itemID: "a17c", label: "Postgres"))
        let call = try XCTUnwrap(server.calls("acp_answer_question").first)
        XCTAssertEqual(call.body["connectionId"] as? String, "c41d")
        XCTAssertEqual(call.body["questionId"] as? String, "5e0f")
        let answer = try XCTUnwrap(call.body["answer"] as? [String: Any])
        let item = try XCTUnwrap((answer["answers"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["questionId"] as? String, "a17c")
        XCTAssertEqual(item["labels"] as? [String], ["Postgres"])
        XCTAssertEqual(answer["declined"] as? Bool, false)
    }

    // MARK: - The category per question

    func testWhichQuestionsGetButtons() {
        let one = PushQuestion(questionID: "q", itemID: "i", options: ["Yes", "No"], answerable: true)
        XCTAssertEqual(QuestionCategory.buttonLabels(for: one), ["Yes", "No"])
        var four = one
        four.options = ["a", "b", "c", "d"]
        XCTAssertEqual(QuestionCategory.buttonLabels(for: four), ["a", "b", "c", "d"])
        var five = one
        five.options = ["a", "b", "c", "d", "e"]
        XCTAssertNil(QuestionCategory.buttonLabels(for: five), "more than iOS shows: Open only")
        var multi = one
        multi.multiSelect = true
        XCTAssertNil(QuestionCategory.buttonLabels(for: multi))
        var notAnswerable = one
        notAnswerable.answerable = false
        XCTAssertNil(QuestionCategory.buttonLabels(for: notAnswerable))
        var several = one
        several.count = 2
        XCTAssertNil(QuestionCategory.buttonLabels(for: several))
        var freeText = one
        freeText.options = []
        XCTAssertNil(QuestionCategory.buttonLabels(for: freeText))
    }

    func testTheCategoryIDIsStablePerLabels() {
        let id = QuestionCategory.identifier(for: ["SQLite", "Postgres"])
        XCTAssertTrue(id.hasPrefix("CODEG_QUESTION."))
        XCTAssertEqual(id.count, "CODEG_QUESTION.".count + 16)
        XCTAssertEqual(id, QuestionCategory.identifier(for: ["SQLite", "Postgres"]))
        XCTAssertNotEqual(id, QuestionCategory.identifier(for: ["Postgres", "SQLite"]))
        XCTAssertNotEqual(QuestionCategory.identifier(for: ["ab", "c"]), QuestionCategory.identifier(for: ["a", "bc"]))
        XCTAssertTrue(QuestionCategory.isPerQuestion(id))
        XCTAssertFalse(QuestionCategory.isPerQuestion(QuestionCategory.base))
    }

    func testTheCategoryHasOneActionPerLabelThenOpen() {
        let category = QuestionCategory.make(labels: ["SQLite", "Postgres"], openTitle: "Open")
        XCTAssertEqual(category.identifier, QuestionCategory.identifier(for: ["SQLite", "Postgres"]))
        XCTAssertEqual(category.actions.map(\.identifier), ["ANSWER_0", "ANSWER_1", "OPEN"])
        XCTAssertEqual(category.actions.map(\.title), ["SQLite", "Postgres", "Open"])
        for answer in category.actions.prefix(2) {
            XCTAssertTrue(answer.options.contains(.authenticationRequired))
            XCTAssertFalse(answer.options.contains(.foreground), "answers run in the background")
        }
        XCTAssertTrue(category.actions[2].options.contains(.foreground))
        let full = QuestionCategory.make(labels: ["a", "b", "c", "d"], openTitle: "Open")
        XCTAssertEqual(full.actions.map(\.identifier), ["ANSWER_0", "ANSWER_1", "ANSWER_2", "ANSWER_3"])
        XCTAssertEqual(QuestionCategory.answerIndex("ANSWER_3"), 3)
        XCTAssertNil(QuestionCategory.answerIndex("OPEN"))
        XCTAssertNil(QuestionCategory.answerIndex("ANSWER_"))
    }

    func testRegisteringKeepsTheFixedCategoriesAndCapsThePerQuestionOnes() {
        let fixed = PushRegistration.categories
        var existing = fixed
        for i in 0..<40 {
            existing.insert(QuestionCategory.make(labels: ["option \(i)"], openTitle: "Open"))
        }
        let new = QuestionCategory.make(labels: ["Yes", "No"], openTitle: "Open")
        let merged = QuestionCategory.merged(existing, adding: new)
        XCTAssertTrue(merged.contains { $0.identifier == new.identifier })
        for category in fixed {
            XCTAssertTrue(merged.contains { $0.identifier == category.identifier }, category.identifier)
        }
        XCTAssertEqual(merged.filter { QuestionCategory.isPerQuestion($0.identifier) }.count, QuestionCategory.keep)

        // The app's launch keeps what the extension registered.
        let relaunch = QuestionCategory.preserving([new], fixed: fixed)
        XCTAssertTrue(relaunch.contains { $0.identifier == new.identifier })
        XCTAssertEqual(relaunch.count, fixed.count + 1)
        XCTAssertTrue(fixed.contains { $0.identifier == PushCategory.question })
        XCTAssertTrue(fixed.contains { $0.identifier == PushCategory.permission })
    }

    func testReminderSubtitle() {
        let text = QuestionPushWording.reminderSubtitle(attempt: 2)
        XCTAssertTrue(text.contains("2"), text)
        XCTAssertNotEqual(text, QuestionPushWording.reminderSubtitle(attempt: 3))
    }

    // MARK: - Foreground

    func testForegroundNeverShowsABadgeOnlyPushAndNeverSetsTheBadgeItself() throws {
        let all: UNNotificationPresentationOptions = [.banner, .list, .sound]
        let badge = try XCTUnwrap(PushPayload(userInfo: [
            "aps": ["badge": NSNumber(value: 3)] as [String: Any], "kind": "badge",
        ]))
        XCTAssertEqual(PushRegistration.foregroundOptions(for: badge, all: all, aboutVisibleSession: false), [])
        let question = try XCTUnwrap(PushPayload(userInfo: questionReminder()))
        XCTAssertEqual(PushRegistration.foregroundOptions(for: question, all: all, aboutVisibleSession: false), all)
        XCTAssertEqual(PushRegistration.foregroundOptions(for: question, all: all, aboutVisibleSession: true), [])
        XCTAssertFalse(PushRegistration.foregroundOptions(for: question, all: all, aboutVisibleSession: false)
            .contains(.badge))
    }
}
