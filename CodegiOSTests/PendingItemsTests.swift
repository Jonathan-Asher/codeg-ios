import XCTest
import UserNotifications
@testable import Codeg

/// "Waiting for you" (codeg fork `docs/ios-push.md` §9): the
/// `list_pending_items` shape, which items answer from the list, the store
/// that loads, follows and answers them, the event the sockets hand over,
/// the icon badge, and the reminder settings.
@MainActor
final class PendingItemsTests: XCTestCase {
    private var badges: [Int] = []
    private var profileID = UUID()

    override func setUp() async throws {
        badges = []
        profileID = UUID()
        let saved = profileID
        AppBadge.shared.setBadge = { [weak self] in self?.badges.append($0) }
        AppBadge.shared.savedServers = { [saved] }
        AppBadge.shared.isEnabled = { true }
    }

    override func tearDown() async throws {
        AppBadge.shared.forget(profileID)
        AppBadge.shared.setBadge = { count in
            Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
        }
        AppBadge.shared.savedServers = { Set(ServerStore.persistedServers().map(\.id)) }
        AppBadge.shared.isEnabled = { PushRegistration.shared.enabled }
    }

    // MARK: - Fixtures

    private static let question = """
    {"id": "question:5e0f", "kind": "question", "source": "question", "conversation_id": 42,
     "root_conversation_id": 42, "folder_id": 7, "folder_name": "codeg", "title": "Fix the login bug",
     "agent_type": "claude_code", "agent_label": "Claude Code", "connection_id": "c41d", "request_id": "5e0f",
     "asked_at": "2026-10-26T09:00:00.123456789Z", "text": "Which database should we use?",
     "options": [{"id": "SQLite", "label": "SQLite"}, {"id": "Postgres", "label": "Postgres"}],
     "question": {"item_id": "a17c", "header": "Storage", "multi_select": false, "count": 1},
     "queued": 0, "reminders_sent": 2, "last_reminded_at": "2026-10-26T09:30:00Z",
     "next_reminder_at": "2026-10-26T11:00:00Z", "phone_notified": true}
    """

    private static let subAgentPermission = """
    {"id": "permission:r9", "kind": "permission", "source": "permission", "conversation_id": 99,
     "root_conversation_id": 42, "folder_id": 7, "folder_name": "codeg", "title": null,
     "agent_type": "codex", "agent_label": "Codex", "connection_id": "c77", "request_id": "r9",
     "asked_at": "2026-10-26T08:00:00Z", "text": "Run `rm -rf build`",
     "options": [{"id": "allow_once", "label": "Allow", "kind": "allow_once"},
                 {"id": "reject_once", "label": "Deny", "kind": "reject_once"}],
     "queued": 0, "reminders_sent": 0, "last_reminded_at": null, "next_reminder_at": null,
     "phone_notified": false}
    """

    private static func snapshotJSON(_ items: [String], count: Int? = nil) -> String {
        "{\"items\": [\(items.joined(separator: ", "))], \"count\": \(count ?? items.count)}"
    }

    private func decode(_ json: String) throws -> PendingSnapshot {
        try CodegJSON.decoder.decode(PendingSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - The list

    func testDecodesTheListOldestFirst() throws {
        let snapshot = try decode(Self.snapshotJSON([Self.question, Self.subAgentPermission]))
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.items.map(\.id), ["permission:r9", "question:5e0f"])

        let question = snapshot.items[1]
        XCTAssertEqual(question.knownKind, .question)
        XCTAssertEqual(question.source, "question")
        XCTAssertEqual(question.conversationId, 42)
        XCTAssertEqual(question.rootConversationId, 42)
        XCTAssertFalse(question.isSubAgent)
        XCTAssertEqual(question.displayTitle, "Fix the login bug")
        XCTAssertEqual(question.agentLabel, "Claude Code")
        XCTAssertEqual(question.connectionId, "c41d")
        XCTAssertEqual(question.requestId, "5e0f")
        let asked = try XCTUnwrap(ISO8601.parse("2026-10-26T09:00:00Z"))
        XCTAssertEqual(question.askedAt.timeIntervalSince1970, asked.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(question.text, "Which database should we use?")
        XCTAssertEqual(question.question?.itemId, "a17c")
        XCTAssertEqual(question.remindersSent, 2)
        XCTAssertEqual(question.quickAnswers, ["SQLite", "Postgres"])

        let permission = snapshot.items[0]
        XCTAssertEqual(permission.knownKind, .permission)
        XCTAssertTrue(permission.isSubAgent)
        XCTAssertEqual(permission.rootConversationId, 42, "a sub-agent's item opens its parent")
        XCTAssertEqual(permission.displayTitle, "codeg", "no title: the folder")
        XCTAssertEqual(permission.options.first?.kind, "allow_once")
        XCTAssertNil(permission.quickAnswers, "permissions open the session")
    }

    func testOnlyOneShortSingleChoiceQuestionAnswersFromTheList() throws {
        let base = try decode(Self.snapshotJSON([Self.question])).items[0]
        var multi = base
        multi.question?.multiSelect = true
        XCTAssertNil(multi.quickAnswers)
        var several = base
        several.question?.count = 3
        XCTAssertNil(several.quickAnswers)
        var freeText = base
        freeText.options = []
        XCTAssertNil(freeText.quickAnswers)
        var many = base
        many.options = (1...7).map { PendingOption(id: "\($0)", label: "Option \($0)") }
        XCTAssertNil(many.quickAnswers)
        var long = base
        long.options = [PendingOption(id: "x", label: String(repeating: "x", count: 61))]
        XCTAssertNil(long.quickAnswers)
        let secretJSON = Self.question.replacingOccurrences(of: "\"count\": 1}", with: "\"count\": 1, \"secret\": true}")
        let secret = try decode(Self.snapshotJSON([secretJSON])).items[0]
        XCTAssertEqual(secret.question?.secret, true)
        XCTAssertNil(secret.quickAnswers, "a secret is answered in the session")
        XCTAssertEqual(base.question?.secret, false)
    }

    func testOneOddItemDoesNotHideTheRest() throws {
        let snapshot = try decode(Self.snapshotJSON([Self.question, "{\"id\": 5}"], count: 2))
        XCTAssertEqual(snapshot.items.map(\.id), ["question:5e0f"])
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(try decode("{}"), PendingSnapshot.empty)
    }

    func testTheAnswerFromTheList() throws {
        let item = try decode(Self.snapshotJSON([Self.question])).items[0]
        let answer = try XCTUnwrap(item.answer(label: "Postgres"))
        XCTAssertEqual(answer.answers.first?.questionId, "a17c")
        XCTAssertEqual(answer.answers.first?.labels, ["Postgres"])
        XCTAssertFalse(answer.declined)
    }

    // MARK: - The store

    private func store(on server: MockCodegServer) -> PendingItemsStore {
        let store = PendingItemsStore()
        store.bind(client: server.client, serverProfileID: profileID)
        return store
    }

    func testLoadsTheListAndSetsTheBadge() async throws {
        let server = MockCodegServer()
        server.on("list_pending_items") { _ in .body(Self.snapshotJSON([Self.question, Self.subAgentPermission])) }
        let store = store(on: server)
        await store.refresh()
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.supported, true)
        XCTAssertEqual(store.visibleItems.map(\.id), ["permission:r9", "question:5e0f"])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(badges.last, 2)
    }

    func testAnOlderServerShowsNothingAndClearsItsBadge() async throws {
        let server = MockCodegServer()
        server.on("list_pending_items") { _ in .status(404, "{\"message\": \"Not Found\"}") }
        let store = store(on: server)
        await store.refresh()
        XCTAssertEqual(store.supported, false)
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertEqual(badges.last, 0)
    }

    func testAFailedLoadKeepsWhatIsShown() async throws {
        let server = MockCodegServer()
        server.on("list_pending_items") { _ in .body(Self.snapshotJSON([Self.question])) }
        let store = store(on: server)
        await store.refresh()
        server.on("list_pending_items") { _ in .fail(.notConnectedToInternet) }
        await store.refresh()
        XCTAssertEqual(store.visibleItems.map(\.id), ["question:5e0f"])
    }

    func testTheEventReplacesTheList() throws {
        let server = MockCodegServer()
        let store = store(on: server)
        let payload = Data(Self.snapshotJSON([Self.subAgentPermission]).utf8)
        store.receive(channel: "app://pending-items", payload: payload, from: server.client.baseURL)
        XCTAssertEqual(store.visibleItems.map(\.id), ["permission:r9"])
        XCTAssertEqual(badges.last, 1)
        // Another server's socket, or another channel: ignored.
        store.receive(channel: "app://pending-items", payload: Data(Self.snapshotJSON([]).utf8),
                      from: URL(string: "http://elsewhere.test")!)
        store.receive(channel: "app://other", payload: Data(Self.snapshotJSON([]).utf8), from: server.client.baseURL)
        XCTAssertEqual(store.visibleItems.map(\.id), ["permission:r9"])
        // Everything answered: an empty list and a cleared badge.
        store.receive(channel: "app://pending-items", payload: Data(Self.snapshotJSON([]).utf8),
                      from: server.client.baseURL)
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertEqual(badges.last, 0)
    }

    func testAnotherServerStartsEmpty() async throws {
        let server = MockCodegServer()
        server.on("list_pending_items") { _ in .body(Self.snapshotJSON([Self.question])) }
        let store = store(on: server)
        await store.refresh()
        let other = MockCodegServer()
        store.bind(client: other.client, serverProfileID: UUID())
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertFalse(store.hasLoaded)
        store.reset()
        XCTAssertNil(store.serverProfileID)
    }

    func testAnsweringFromTheList() async throws {
        let server = MockCodegServer()
        var listed = [Self.question]
        server.on("list_pending_items") { _ in .body(Self.snapshotJSON(listed)) }
        server.on("acp_answer_question") { _ in
            listed = []
            return .body("null")
        }
        let store = store(on: server)
        await store.refresh()
        let item = try XCTUnwrap(store.visibleItems.first)
        await store.answer(item, label: "Postgres")

        let call = try XCTUnwrap(server.calls("acp_answer_question").first)
        XCTAssertEqual(call.body["connectionId"] as? String, "c41d")
        XCTAssertEqual(call.body["questionId"] as? String, "5e0f", "the set's id is the item's request_id")
        let sent = try XCTUnwrap(((call.body["answer"] as? [String: Any])?["answers"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["questionId"] as? String, "a17c")
        XCTAssertEqual(sent["labels"] as? [String], ["Postgres"])
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertNil(store.answerError)
        XCTAssertEqual(badges.last, 0)
    }

    func testAnAnswerThatFailsBringsTheItemBackWithTheReason() async throws {
        let server = MockCodegServer()
        server.on("list_pending_items") { _ in .body(Self.snapshotJSON([Self.question])) }
        server.on("acp_answer_question") { _ in .status(500, "{\"message\": \"agent went away\"}") }
        let store = store(on: server)
        await store.refresh()
        await store.answer(store.visibleItems[0], label: "SQLite")
        XCTAssertEqual(store.visibleItems.map(\.id), ["question:5e0f"])
        XCTAssertNotNil(store.answerError)
        store.dismissAnswerError()
        XCTAssertNil(store.answerError)
    }

    func testAnsweredElsewhereMeanwhileSaysNothing() async throws {
        let server = MockCodegServer()
        var listed = [Self.question]
        server.on("list_pending_items") { _ in .body(Self.snapshotJSON(listed)) }
        server.on("acp_answer_question") { _ in
            listed = []
            return .status(404, "{\"message\": \"no pending question\"}")
        }
        let store = store(on: server)
        await store.refresh()
        await store.answer(store.visibleItems[0], label: "SQLite")
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertNil(store.answerError)
    }

    // MARK: - The event on the sockets

    func testEverySocketHandsOverThePendingEvent() throws {
        let frame = #"{"channel": "app://pending-items", "payload": {"items": [], "count": 0}}"#
        let routed = EventStream.route(Data(frame.utf8))
        XCTAssertTrue(routed.frames.isEmpty)
        let global = try XCTUnwrap(routed.global)
        XCTAssertEqual(global.channel, "app://pending-items")
        XCTAssertEqual(try decode(String(decoding: global.payload, as: UTF8.self)), .empty)

        let other = EventStream.route(Data(#"{"channel": "acp://event", "payload": {"x": 1}}"#.utf8))
        XCTAssertNil(other.global)
        XCTAssertTrue(other.frames.isEmpty)
        let ready = EventStream.route(Data(#"{"channel": "__ready__", "payload": null}"#.utf8))
        XCTAssertNil(ready.global)
        guard let first = ready.frames.first, case .ready = first else { return XCTFail("ready") }
    }

    // MARK: - The badge

    func testTheBadgeSumsTheSavedServers() {
        let a = UUID(), b = UUID(), gone = UUID()
        XCTAssertEqual(AppBadge.total([a: 2, b: 3, gone: 4], saved: [a, b]), 5)
        XCTAssertEqual(AppBadge.total([:], saved: [a]), 0)
        XCTAssertEqual(AppBadge.total([a: -1], saved: [a]), 0)
    }

    func testNoBadgeWithNotificationsOff() {
        AppBadge.shared.isEnabled = { false }
        AppBadge.shared.set(4, for: profileID)
        XCTAssertEqual(badges.last, 0)
        AppBadge.shared.isEnabled = { true }
        AppBadge.shared.apply()
        XCTAssertEqual(badges.last, 4)
    }

    // MARK: - Reminder settings

    func testReminderSettingsRoundTrip() throws {
        let json = """
        {"enabled": true, "steps_secs": [300, 1800, 7200], "repeat_secs": 14400, "quiet_hours": true,
         "quiet_start_min": 1320, "quiet_end_min": 420, "timezone": "Asia/Jerusalem"}
        """
        let settings = try CodegJSON.decoder.decode(PendingReminderSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.stepsSecs, [300, 1800, 7200])
        XCTAssertEqual(settings.repeatSecs, 14_400)
        XCTAssertTrue(settings.quietHours)
        XCTAssertEqual(settings.quietStartMin, 22 * 60)
        XCTAssertEqual(settings.quietEndMin, 7 * 60)
        XCTAssertEqual(settings.timezone, "Asia/Jerusalem")
        XCTAssertEqual(try CodegJSON.decoder.decode(PendingReminderSettings.self, from: Data("{}".utf8)),
                       PendingReminderSettings())

        let data = try CodegJSON.encoder.encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["steps_secs"] as? [Int], [300, 1800, 7200])
        XCTAssertEqual(object["repeat_secs"] as? Int, 14_400)
        XCTAssertEqual(object["quiet_start_min"] as? Int, 1320)
        XCTAssertEqual(object["quiet_hours"] as? Bool, true)
        XCTAssertNil(object["stepsSecs"])
    }

    func testSavingReminderSettingsSendsThemUnderSettings() async throws {
        let server = MockCodegServer()
        server.on("update_pending_reminder_settings") { call in
            let settings = call.body["settings"] as? [String: Any] ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: settings)) ?? Data("{}".utf8)
            return .body(String(decoding: data, as: UTF8.self))
        }
        var settings = PendingReminderSettings()
        settings.repeatSecs = 0
        settings.timezone = "Europe/Paris"
        let saved = try await server.client.updatePendingReminderSettings(settings)
        XCTAssertEqual(saved.repeatSecs, 0)
        XCTAssertEqual(saved.timezone, "Europe/Paris")
        let body = try XCTUnwrap(server.calls("update_pending_reminder_settings").first?.body["settings"] as? [String: Any])
        XCTAssertEqual(body["repeat_secs"] as? Int, 0)
        XCTAssertEqual(ReminderText.repeating(0), String(localized: "Never"))
        XCTAssertFalse(ReminderText.steps([300, 1800]).isEmpty)
    }
}
