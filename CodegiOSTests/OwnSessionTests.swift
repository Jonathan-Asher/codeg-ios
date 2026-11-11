import XCTest
@testable import Codeg

/// A conversation the server has is connected with its own agent session,
/// never a brand-new one. A session opened from its saved copy shows before
/// the server has said which agent session its row holds: a model picked or a
/// message sent then waits for that (the pick shown as being applied) and
/// connects with the session the server names, also when the copy named
/// another or none, and a load that failed is read again for it. A row the
/// server says holds no session, and a new draft, start one without an id.
@MainActor
final class OwnSessionTests: XCTestCase {
    private var server: MockCodegServer!
    private var root: URL!
    private var models: [SessionDetailViewModel] = []
    private var gates: [ReplyGate] = []

    override func setUp() async throws {
        server = MockCodegServer()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("own-session-\(UUID().uuidString)")
        OutboxStore.rootOverride = root.appendingPathComponent("outbox", isDirectory: true)
    }

    override func tearDown() async throws {
        gates.forEach { $0.open() }
        gates = []
        models.forEach { $0.teardown() }
        models = []
        server = nil
        OutboxStore.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A gate the test opens to let the server answer.
    private func hold() -> ReplyGate {
        let gate = ReplyGate()
        gates.append(gate)
        return gate
    }

    private func makeModel(cache: TranscriptCache? = nil) -> SessionDetailViewModel {
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() }, transcriptCache: cache)
        models.append(model)
        return model
    }

    /// The conversation as the transcript cache kept it: its history, and the
    /// agent session its row held then (`external`, none when nil).
    private func savedCopy(external: String?) throws -> CachedTranscript {
        let session = external.map { #""external_id": "\#($0)", "# } ?? ""
        let json = """
        {"id": \(Fixtures.conversationID), "folder_id": 1, "title": "Migration", "agent_type": "claude_code",
         "status": "pending_review", \(session)"message_count": 2, "created_at": "2026-10-04T16:00:00Z",
         "updated_at": "2026-10-04T16:10:00Z", "turn_state": null}
        """
        let summary = try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(json.utf8))
        let turns = [
            MessageTurn(id: "turn-0", role: .user, blocks: [.text("Plan the migration")],
                        timestamp: Date(timeIntervalSince1970: 1_791_129_600), serverMillis: 1_791_129_600_000),
            MessageTurn(id: "turn-1", role: .assistant, blocks: [.text("Back up the database first.")],
                        timestamp: Date(timeIntervalSince1970: 1_791_129_601), serverMillis: 1_791_129_601_000),
        ]
        return CachedTranscript(conversationID: Fixtures.conversationID, savedAt: Date(), summary: summary,
                                selectorState: nil, sessionStats: nil, folder: nil, turnsOffset: 0,
                                prefixHash: nil, turnsTotal: turns.count, turns: turns)
    }

    private func cacheHolding(_ copy: CachedTranscript) async -> TranscriptCache {
        let cache = TranscriptCache(root: root.appendingPathComponent("cache", isDirectory: true))
        await cache.save(copy, serverKey: TranscriptCache.serverKey(for: server.client))
        return cache
    }

    /// The session opened from its saved copy, while the server's detail
    /// (which names `ext-7`) waits for `gate`.
    private func openFromSavedCopy(external: String?, holding gate: ReplyGate) async throws -> SessionDetailViewModel {
        let copy = try savedCopy(external: external)
        let cache = await cacheHolding(copy)
        server.on("get_folder_conversation") { _ in .held(gate, .body(Fixtures.detail())) }
        let model = makeModel(cache: cache)
        model.loadIfNeeded()
        let shown = await eventually { model.phase == .loaded && model.openedFromCache }
        XCTAssertTrue(shown, "the saved copy shows at once")
        XCTAssertEqual(model.turns.count, 2)
        return model
    }

    /// The server's detail with the row holding no agent session.
    private var detailWithoutSession: String {
        Fixtures.detail().replacingOccurrences(of: #""external_id": "ext-7""#, with: #""external_id": null"#)
    }

    // MARK: - Before the server has said

    func testAPickBeforeTheSessionLoadedWaitsForItsSessionAndThenApplies() async throws {
        let gate = hold()
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        server.on("acp_set_config_option") { _ in .body("null") }
        let snapshot = DraftPresetsTests.snapshotJSON(model: "small")
        server.on("acp_get_session_snapshot") { _ in .body(snapshot) }
        let model = try await openFromSavedCopy(external: nil, holding: gate)
        XCTAssertNil(model.summary?.externalId, "the saved copy names no agent session")
        XCTAssertFalse(model.optionsWaitForConnect, "an existing session applies a pick to its connection")

        let options = model.agentOptions
        options.selectConfig(optionId: "model", valueId: "small")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(server.calls("acp_connect").isEmpty, "no agent session started without the conversation's")
        XCTAssertTrue(server.calls("acp_find_connection_for_conversation").isEmpty, "nor looked for without it")
        XCTAssertTrue(server.calls("acp_set_config_option").isEmpty)
        XCTAssertEqual(options.selectedConfig["model"], "small", "the pick is kept")
        XCTAssertTrue(options.applying.contains("model"), "and shown as being applied")

        gate.open()
        let applied = await eventually { self.server.calls("acp_set_config_option").count == 1 }
        XCTAssertTrue(applied, "it goes once the server said which session the row holds")
        let connects = server.calls("acp_connect")
        XCTAssertEqual(connects.count, 1)
        XCTAssertEqual(connects.first?.body["sessionId"] as? String, "ext-7", "the conversation's own session")
        let set = server.calls("acp_set_config_option").first
        XCTAssertEqual(set?.body["connectionId"] as? String, "conn-9")
        XCTAssertEqual(set?.body["configId"] as? String, "model")
        XCTAssertEqual(set?.body["valueId"] as? String, "small")
        let settled = await eventually { options.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(options.selectedConfig["model"], "small")
        XCTAssertNil(options.errorNotice)
    }

    func testAMessageSentBeforeTheSessionLoadedGoesToTheSessionTheServerNames() async throws {
        let gate = hold()
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        // The saved copy is from before a fork elsewhere moved the row to ext-7.
        let model = try await openFromSavedCopy(external: "ext-6", holding: gate)

        model.draft = "Run the migration"
        model.sendFromComposer()
        XCTAssertEqual(model.pendingUserTurns.count, 1, "shown as sent")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(server.calls("acp_connect").isEmpty, "it waits for the server's word")
        XCTAssertTrue(server.calls("acp_prompt").isEmpty)
        XCTAssertEqual(model.sendState, .connecting)
        XCTAssertTrue(model.queuedMessages.isEmpty, "not given up on")

        gate.open()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(server.calls("acp_connect").count, 1)
        XCTAssertEqual(server.calls("acp_connect").first?.body["sessionId"] as? String, "ext-7",
                       "the row's session as the server says it, not the saved copy's")
        XCTAssertFalse(server.calls("acp_find_connection_for_conversation").contains {
            $0.body["sessionId"] as? String == "ext-6"
        }, "nor looked for by the saved copy's")
        XCTAssertEqual(server.calls("acp_prompt").first?.body["connectionId"] as? String, "conn-9")
        XCTAssertTrue(server.calls("acp_prompt")[0].text.contains("Run the migration"))
        XCTAssertNil(model.notice)
    }

    func testWhenTheLoadFailedTheConnectReadsTheSessionItself() async throws {
        let copy = try savedCopy(external: nil)
        let cache = await cacheHolding(copy)
        server.on("get_folder_conversation") { _ in .fail(.notConnectedToInternet) }
        let model = makeModel(cache: cache)
        await model.load()
        XCTAssertEqual(model.phase, .loaded, "the saved copy stays")
        XCTAssertNil(model.summary?.externalId)

        // The server is back.
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        server.on("acp_set_config_option") { _ in .body("null") }
        let snapshot = DraftPresetsTests.snapshotJSON(model: "small")
        server.on("acp_get_session_snapshot") { _ in .body(snapshot) }
        let reads = server.calls("get_folder_conversation").count
        model.agentOptions.selectConfig(optionId: "model", valueId: "small")
        let applied = await eventually { self.server.calls("acp_set_config_option").count == 1 }
        XCTAssertTrue(applied)
        XCTAssertEqual(server.calls("get_folder_conversation").count, reads + 1, "read once, for the connect")
        XCTAssertEqual(server.calls("acp_connect").first?.body["sessionId"] as? String, "ext-7")
        XCTAssertEqual(model.summary?.externalId, "ext-7", "the screen has it too")
    }

    // MARK: - No session to resume

    func testARowTheServerSaysHoldsNoSessionStartsOne() async throws {
        let detail = detailWithoutSession
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNil(model.summary?.externalId)

        model.draft = "Hello"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(server.calls("acp_connect").count, 1)
        XCTAssertNil(server.calls("acp_connect").first?.body["sessionId"], "the server said it holds none")
        XCTAssertEqual(server.calls("get_folder_conversation").count, 1, "the load's read said so; nothing read again")
    }

    func testANewDraftStillStartsItsSessionAtOnce() async throws {
        let folders = DraftPresetsTests.foldersJSON([DraftPresetsTests.alpha])
        let agents = DraftPresetsTests.agentsJSON(["codex"])
        server.on("acp_list_agents") { _ in .body(agents) }
        server.on("list_open_folder_details") { _ in .body(folders) }
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("create_conversation") { _ in .body("12") }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        // The new row's detail never answers: nothing waits for it.
        let gate = hold()
        server.on("get_folder_conversation") { _ in .held(gate, .body("null")) }
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, newSession: NewSessionRequest(), draftCatalog: nil) { _ in
            factory.make()
        }
        models.append(model)
        await model.load()

        model.draft = "Start the project"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let connect = server.calls("acp_connect").first
        XCTAssertEqual(server.calls("acp_connect").count, 1)
        XCTAssertNil(connect?.body["sessionId"], "a new session")
        XCTAssertEqual(connect?.body["agentType"] as? String, "codex")
        XCTAssertEqual(server.calls("acp_prompt").first?.body["conversationId"] as? Int, 12)
    }
}
