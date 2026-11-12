import XCTest
@testable import Codeg

/// A session whose agent no longer has its history (codeg fork.230,
/// `history_unavailable`; Claude Code's 30-day cleanup deletes transcripts):
/// the detail's field read with and without it, kept in the transcript cache;
/// the screen read-only (no message, Continue, fork, option change or Talk);
/// this iPhone's fuller copy kept over the server's shorter or empty answer;
/// the server's refusals and the agent's failed load mapped to that state; and
/// "Start a new session from this", whose draft holds the saved text and
/// sends nothing. Against a ``MockCodegServer``.
@MainActor
final class LostHistoryTests: XCTestCase {
    private var server: MockCodegServer!
    private var root: URL!
    private var models: [SessionDetailViewModel] = []
    private var gates: [ReplyGate] = []
    /// Answering for the server until the test ends.
    private var transcripts: [WindowedTranscriptServer] = []

    override func setUp() async throws {
        server = MockCodegServer()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lost-history-\(UUID().uuidString)")
        OutboxStore.rootOverride = root.appendingPathComponent("outbox", isDirectory: true)
    }

    override func tearDown() async throws {
        gates.forEach { $0.open() }
        gates = []
        models.forEach { $0.teardown() }
        models = []
        server = nil
        transcripts = []
        OutboxStore.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private let refusal = #"{"code": "not_found", "message": "Claude Code no longer has this session's history, so it can't be resumed [history_unavailable]"}"#

    private let savedTurnsJSON = """
    [{"turn_idx": 0, "role": "user", "content": "Do research on alternatives"},
     {"turn_idx": 1, "role": "assistant", "content": "I started **four** research tracks"},
     {"turn_idx": 3, "role": "user", "content": "What about Seedance 2.5?"}]
    """

    private func summaryJSON(title: String = "Higgsfield alternatives") -> String {
        """
        {"id": \(Fixtures.conversationID), "folder_id": 1, "title": "\(title)", "agent_type": "claude_code",
         "status": "completed", "external_id": "ext-7", "message_count": 0,
         "created_at": "2026-09-24T10:00:00Z", "updated_at": "2026-09-24T11:00:00Z", "turn_state": null}
        """
    }

    /// The detail of a session whose history is gone: no turns, and the verdict.
    private func lostDetail(saved: Int = 3, reason: String = "agent_cleanup", days: Int? = 30) -> String {
        let daysJSON = days.map { #", "retention_days": \#($0)"# } ?? ""
        return """
        {"summary": \(summaryJSON()), "turns": [], "session_stats": null, "in_flight_user_turn_id": null,
         "turns_offset": 0, "turns_total": 0, "prefix_hash": "\(TranscriptFingerprint.empty)",
         "history_unavailable": {"reason": "\(reason)"\(daysJSON), "saved_turns": \(saved)}}
        """
    }

    /// The same session while its transcript was still there.
    private var readableDetail: String {
        Fixtures.detail()
    }

    private func turn(_ index: Int, _ role: TurnRole, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: "turn-\(index)", role: role, blocks: blocks,
                    timestamp: Date(timeIntervalSince1970: 1_791_129_600 + Double(index)),
                    serverMillis: 1_791_129_600_000 + Int64(index) * 1_000)
    }

    /// What this iPhone kept of the session: `count` turns, prompts and
    /// replies, one of them a tool call with no text.
    private func keptTurns(_ count: Int) -> [MessageTurn] {
        (0..<count).map { index in
            switch index % 3 {
            case 0: return turn(index, .user, [.text("Prompt \(index)")])
            case 1: return turn(index, .assistant, [.toolUse(id: "tool-\(index)", name: "Read", inputPreview: nil, meta: nil)])
            default: return turn(index, .assistant, [.text("Reply \(index)")])
            }
        }
    }

    private func makeCache(holding turns: [MessageTurn], lost: HistoryUnavailable? = nil) async throws -> TranscriptCache {
        let summary = try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(summaryJSON().utf8))
        let entry = CachedTranscript(conversationID: Fixtures.conversationID, savedAt: Date(), summary: summary,
                                     selectorState: nil, sessionStats: nil, folder: nil, turnsOffset: 0,
                                     prefixHash: nil, turnsTotal: turns.count, turns: turns,
                                     historyUnavailable: lost)
        let cache = TranscriptCache(root: root.appendingPathComponent("cache", isDirectory: true))
        await cache.save(entry, serverKey: TranscriptCache.serverKey(for: server.client))
        return cache
    }

    private func cachedEntry(_ cache: TranscriptCache) async -> CachedTranscript? {
        await cache.load(serverKey: TranscriptCache.serverKey(for: server.client), conversationID: Fixtures.conversationID)
    }

    private func makeModel(cache: TranscriptCache? = nil, factory: StreamFactory? = nil) -> SessionDetailViewModel {
        let factory = factory ?? StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() }, transcriptCache: cache)
        models.append(model)
        return model
    }

    private func makeDraft(_ request: NewSessionRequest) -> SessionDetailViewModel {
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, newSession: request, draftCatalog: nil,
                                           makeEventStream: { _ in factory.make() })
        models.append(model)
        return model
    }

    /// A session whose history is gone, opened with nothing kept here: the
    /// server's saved text.
    private func openLostSession(saved: Int = 3) async -> SessionDetailViewModel {
        serveDetail(lostDetail(saved: saved))
        serveSavedTurns()
        let model = makeModel()
        await model.load()
        return model
    }

    /// The server answers the detail with `json` from now on.
    private func serveDetail(_ json: String) {
        server.on("get_folder_conversation") { _ in .body(json) }
    }

    private func serveSavedTurns() {
        let json = savedTurnsJSON
        server.on("get_conversation_saved_turns") { _ in .body(json) }
    }

    /// Every connect is refused as codeg refuses a session whose history is gone.
    private func refuseConnects() {
        let body = refusal
        server.on("acp_connect") { _ in .status(404, body) }
    }

    private func detail(_ json: String) throws -> ConversationDetail {
        try CodegJSON.decoder.decode(ConversationDetail.self, from: Data(json.utf8))
    }

    private func hold() -> ReplyGate {
        let gate = ReplyGate()
        gates.append(gate)
        return gate
    }

    // MARK: - Reading the field

    func testTheDetailReadsTheVerdictWhenItIsThere() throws {
        let lost = try detail(lostDetail(saved: 12))
        XCTAssertEqual(lost.historyUnavailable, HistoryUnavailable(reason: .agentCleanup, retentionDays: 30, savedTurns: 12))
        XCTAssertEqual(lost.historyUnavailable?.cleanupDays, 30)
        XCTAssertTrue(lost.turns.isEmpty)

        XCTAssertNil(try detail(readableDetail).historyUnavailable, "an older server, or a readable session")
        let missing = try detail(lostDetail(saved: 0, reason: "missing", days: nil)).historyUnavailable
        XCTAssertEqual(missing, HistoryUnavailable(reason: .missing, retentionDays: nil, savedTurns: 0))
        XCTAssertNil(missing?.cleanupDays)
        // A reason from a newer server reads as missing.
        XCTAssertEqual(try detail(lostDetail(reason: "wiped_by_admin")).historyUnavailable?.reason, .missing)
    }

    func testAnOddVerdictNeverCostsTheTranscript() throws {
        let odd = Fixtures.detail().replacingOccurrences(of: #""in_flight_user_turn_id": null"#,
                                                         with: #""in_flight_user_turn_id": null, "history_unavailable": "yes""#)
        let decoded = try detail(odd)
        XCTAssertNil(decoded.historyUnavailable)
        XCTAssertEqual(decoded.summary.id, Fixtures.conversationID)
        let null = Fixtures.detail().replacingOccurrences(of: #""in_flight_user_turn_id": null"#,
                                                          with: #""in_flight_user_turn_id": null, "history_unavailable": null"#)
        XCTAssertNil(try detail(null).historyUnavailable)
        let noCount = lostDetail().replacingOccurrences(of: #", "saved_turns": 3"#, with: "")
        XCTAssertEqual(try detail(noCount).historyUnavailable?.savedTurns, 0)

        let saved = try CodegJSON.decoder.decode([SavedTurn].self, from: Data(savedTurnsJSON.utf8))
        XCTAssertEqual(saved.map(\.turnIdx), [0, 1, 3])
        XCTAssertEqual(saved.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(saved[1].content, "I started **four** research tracks")
    }

    func testTheVerdictIsKeptInTheTranscriptCache() async throws {
        let lost = HistoryUnavailable(reason: .agentCleanup, retentionDays: 30, savedTurns: 3)
        let cache = try await makeCache(holding: keptTurns(4), lost: lost)
        let entry = await cachedEntry(cache)
        XCTAssertEqual(entry?.historyUnavailable, lost)
        XCTAssertEqual(entry?.turns.count, 4)

        // An entry saved before 1.4.7 has no such key.
        let older = try await makeCache(holding: keptTurns(2))
        let olderEntry = await cachedEntry(older)
        XCTAssertNil(olderEntry?.historyUnavailable)
        XCTAssertEqual(olderEntry?.turns.count, 2)
    }

    func testTheCacheNeverReplacesAKeptCopyWithFewerTurns() async throws {
        let lost = HistoryUnavailable(reason: .agentCleanup, retentionDays: 30, savedTurns: 3)
        let cache = try await makeCache(holding: keptTurns(5))
        guard var emptied = await cachedEntry(cache) else { return XCTFail("saved") }
        // What the prefetcher would write from the server's empty answer.
        emptied.turns = []
        emptied.turnsTotal = 0
        emptied.historyUnavailable = lost
        await cache.save(emptied, serverKey: TranscriptCache.serverKey(for: server.client))
        let kept = await cachedEntry(cache)
        XCTAssertEqual(kept?.turns.count, 5, "this iPhone's copy stays")
        XCTAssertEqual(kept?.historyUnavailable, lost, "with the verdict")
    }

    // MARK: - Read-only

    func testASessionWhoseHistoryIsGoneOpensReadOnlyOnTheSavedText() async throws {
        let model = await openLostSession()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.lostHistoryCopy, .saved)
        let loaded = await eventually { model.savedCopyReady }
        XCTAssertTrue(loaded)
        guard case .loaded(let saved) = model.savedCopy else { return XCTFail("the saved text") }
        XCTAssertEqual(saved.map(\.content), ["Do research on alternatives", "I started **four** research tracks",
                                              "What about Seedance 2.5?"])
        XCTAssertEqual(server.calls("get_conversation_saved_turns").first?.body["conversationId"] as? Int,
                       Fixtures.conversationID)
        XCTAssertTrue(server.calls("acp_find_connection_for_conversation").isEmpty, "nothing to reattach to")
    }

    func testNothingConnectsASessionWhoseHistoryIsGone() async throws {
        let model = await openLostSession()

        model.draft = "Keep going with the research"
        model.sendFromComposer()
        model.send()
        model.queueDraft()
        model.insertIntoTurn()
        XCTAssertFalse(model.canOfferContinue)
        model.sendContinue()
        XCTAssertFalse(model.showsOutputLimitNotice)
        let spoken = await model.sendSpoken("תמשיך")
        XCTAssertEqual(spoken, .queued)
        XCTAssertTrue(model.queuedMessages.isEmpty, "nothing waits to be sent either")
        XCTAssertEqual(model.draft, "Keep going with the research", "what was typed stays")

        XCTAssertEqual(model.sessionForkAvailability(forking: false), .hidden)
        XCTAssertEqual(model.replyForkAvailability(turnID: "turn-1", forking: false), .hidden)
        XCTAssertFalse(model.canEditMessages)
        do {
            _ = try await model.resolveConnectionForOptions()
            XCTFail("no connection for an option or a fork")
        } catch {
            XCTAssertTrue(error is HistoryUnavailableError)
        }

        TalkCenter.shared.start(model: model, client: server.client, serverProfileID: nil, lease: nil)
        XCTAssertNotNil(TalkCenter.shared.problem, "Talk says why it can't start")
        XCTAssertNil(TalkCenter.shared.controller)
        TalkCenter.shared.clearProblem()

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls("acp_connect").isEmpty)
        XCTAssertTrue(server.calls("acp_prompt").isEmpty)
        XCTAssertTrue(server.calls("submit_session_feedback").isEmpty)
    }

    func testAFullerCopyOnThisIPhoneIsKeptOverTheServersAnswer() async throws {
        let cache = try await makeCache(holding: keptTurns(6))
        serveDetail(lostDetail(saved: 3))
        let model = makeModel(cache: cache)
        await model.load()

        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.turns.count, 6, "the server's empty transcript didn't replace it")
        XCTAssertEqual(model.lostHistoryCopy, .iPhone)
        XCTAssertTrue(model.savedCopyReady)
        XCTAssertFalse(model.hasOlderTurns)
        XCTAssertTrue(server.calls("get_conversation_saved_turns").isEmpty, "the shorter saved text isn't needed")
        let kept = await eventuallyAsync { await self.cachedEntry(cache)?.historyUnavailable != nil }
        XCTAssertTrue(kept, "the verdict is saved")
        let entry = await cachedEntry(cache)
        XCTAssertEqual(entry?.turns.count, 6, "with the copy")

        // Opened again (from a notification, offline): read-only at once.
        let gate = hold()
        let lost = lostDetail(saved: 3)
        server.on("get_folder_conversation") { _ in .held(gate, .body(lost)) }
        let again = makeModel(cache: cache)
        again.loadIfNeeded()
        let shown = await eventually { again.phase == .loaded && again.openedFromCache }
        XCTAssertTrue(shown)
        XCTAssertTrue(again.isReadOnly, "before the server answers")
        XCTAssertEqual(again.lostHistoryCopy, .iPhone)
        XCTAssertEqual(again.turns.count, 6)
        gate.open()
        let updated = await eventually { again.freshness == .current }
        XCTAssertTrue(updated)
        XCTAssertEqual(again.turns.count, 6)
        XCTAssertTrue(server.calls("acp_connect").isEmpty)
    }

    func testTheServersSavedTextWinsWhenItHasMore() async throws {
        let cache = try await makeCache(holding: keptTurns(2))
        serveDetail(lostDetail(saved: 3))
        serveSavedTurns()
        let model = makeModel(cache: cache)
        await model.load()

        XCTAssertEqual(model.lostHistoryCopy, .saved)
        let loaded = await eventually { model.savedCopyReady }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.turns.count, 2, "this iPhone's copy is still kept, not shown")
        let saved = await eventuallyAsync { await self.cachedEntry(cache)?.historyUnavailable != nil }
        XCTAssertTrue(saved)
        let entry = await cachedEntry(cache)
        XCTAssertEqual(entry?.turns.count, 2)
    }

    func testAHistoryThatComesBackMakesItAnOrdinarySessionAgain() async throws {
        let model = await openLostSession()
        XCTAssertTrue(model.isReadOnly)

        let transcript = WindowedTranscriptServer(count: 10)
        transcripts.append(transcript)
        transcript.install(on: server)
        await model.refreshOnForeground()
        XCTAssertFalse(model.isReadOnly)
        XCTAssertNil(model.lostHistoryCopy)
        XCTAssertEqual(model.turns.count, 10)
    }

    func testASavedTextThatDidntLoadCanBeTriedAgain() async throws {
        serveDetail(lostDetail(saved: 3))
        server.on("get_conversation_saved_turns") { _ in .fail(.timedOut) }
        let model = makeModel()
        await model.load()
        let failed = await eventually { if case .failed = model.savedCopy { return true } else { return false } }
        XCTAssertTrue(failed)
        XCTAssertFalse(model.savedCopyReady)
        XCTAssertNil(model.newSessionFromSavedCopy(), "nothing to start from yet")

        serveSavedTurns()
        model.retrySavedCopy()
        let loaded = await eventually { model.savedCopyReady }
        XCTAssertTrue(loaded)
    }

    // MARK: - The server's refusal and the agent's failed load

    func testTheServersRefusalReadsAsLostHistory() throws {
        let refused = APIError.server(status: 404, code: "not_found",
                                      message: "Claude Code no longer has this session's history, so it can't be resumed [history_unavailable]")
        XCTAssertTrue(refused.isHistoryUnavailable)
        XCTAssertFalse(refused.isStaleConnection, "a fresh connect would only be refused again")
        XCTAssertTrue(APIError.server(status: 500, code: "history_unavailable", message: "gone").isHistoryUnavailable)
        let gone = APIError.server(status: 404, code: "not_found", message: "connection not found")
        XCTAssertFalse(gone.isHistoryUnavailable)
        XCTAssertTrue(gone.isStaleConnection)
        XCTAssertEqual(SendFailure.classify(refused), .rejected)
        XCTAssertEqual(SendFailure.classify(HistoryUnavailableError()), .rejected)
        XCTAssertFalse(SendFailure.next(after: refused, previous: nil).autoRetry)

        let event = try CodegJSON.decoder.decode(AcpEvent.self, from: Data(#"""
        {"type": "session_load_failed", "session_id": "ext-7", "message": "Resource not found", "code": "resource_not_found"}
        """#.utf8))
        XCTAssertEqual(event, .sessionLoadFailed(sessionId: "ext-7", message: "Resource not found", code: "resource_not_found"))
    }

    func testAConnectRefusedForLostHistoryMakesTheSessionReadOnly() async throws {
        serveDetail(readableDetail)
        refuseConnects()
        let model = makeModel()
        await model.load()
        XCTAssertFalse(model.isReadOnly)

        serveDetail(lostDetail(saved: 3))
        model.draft = "Run the migration"
        model.sendFromComposer()
        let readOnly = await eventually { model.historyUnavailable?.savedTurns == 3 }
        XCTAssertTrue(readOnly, "read-only, with the server's verdict")
        XCTAssertEqual(server.calls("acp_connect").count, 1, "not retried as a lost connection")
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Run the migration"], "the message is kept")
        XCTAssertEqual(model.queuedMessages.first?.failure?.autoRetry, false)
        XCTAssertTrue(model.pendingUserTurns.isEmpty)
        XCTAssertNil(model.liveTurn)
        XCTAssertNil(model.notice)

        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(server.calls("acp_connect").count, 1, "and never sent again by itself")
    }

    func testAnAgentWithNoRecordOfTheSessionMakesItReadOnly() async throws {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        serveDetail(readableDetail)
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let promptGate = hold()
        server.on("acp_prompt") { _ in
            .held(promptGate, .status(404, #"{"code": "connection_not_found", "message": "connection not found"}"#))
        }
        let model = makeModel(factory: factory)
        await model.load()

        // An older server: no verdict on the detail, only the agent's word.
        model.draft = "Run the migration"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        factory.opened[0].push(Fixtures.event(#"{"seq": 11, "connection_id": "conn-1", "type": "session_load_failed", "session_id": "ext-7", "message": "Resource not found", "code": "resource_not_found"}"#))
        factory.opened[0].push(Fixtures.event(#"{"seq": 12, "connection_id": "conn-1", "type": "status_changed", "status": "error"}"#))
        let readOnly = await eventually { model.isReadOnly }
        XCTAssertTrue(readOnly)
        XCTAssertEqual(model.historyUnavailable?.reason, .missing)

        promptGate.open()
        let kept = await eventually { model.queuedMessages.map(\.text) == ["Run the migration"] }
        XCTAssertTrue(kept, "the message waits to go with a new session")
        XCTAssertEqual(server.calls("acp_connect").count, 1, "no fresh connect for it")
        XCTAssertNil(model.liveTurn)
    }

    func testAGoneSessionIsReadOnlyWhenTheServerSaysItsHistoryIsGone() async throws {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        serveDetail(readableDetail)
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let promptGate = hold()
        server.on("acp_prompt") { _ in
            .held(promptGate, .status(404, #"{"code": "connection_not_found", "message": "connection not found"}"#))
        }
        let model = makeModel(factory: factory)
        await model.load()
        serveDetail(lostDetail(saved: 3))

        model.draft = "Run the migration"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        factory.opened[0].push(Fixtures.event(#"{"seq": 11, "connection_id": "conn-1", "type": "session_load_failed", "session_id": "ext-7", "message": "Claude Code process exited with code 1", "code": "session_unavailable"}"#))
        factory.opened[0].push(Fixtures.event(#"{"seq": 12, "connection_id": "conn-1", "type": "status_changed", "status": "error"}"#))
        let readOnly = await eventually { model.historyUnavailable?.reason == .agentCleanup }
        XCTAssertTrue(readOnly, "the server's verdict")
        promptGate.open()
        let kept = await eventually { model.queuedMessages.count == 1 }
        XCTAssertTrue(kept)
        XCTAssertEqual(server.calls("acp_connect").count, 1)
    }

    func testAnArchivedSessionIsNotTakenForALostOne() async throws {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        serveDetail(readableDetail)
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let model = makeModel(factory: factory)
        await model.load()
        let reads = server.calls("get_folder_conversation").count

        model.draft = "Run the migration"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        factory.opened[0].push(Fixtures.event(#"{"seq": 11, "connection_id": "conn-1", "type": "session_load_failed", "session_id": "ext-7", "message": "session ext-7 is archived", "code": "session_archived"}"#))
        factory.opened[0].push(Fixtures.event(#"{"seq": 12, "connection_id": "conn-1", "type": "status_changed", "status": "error"}"#))
        let failed = await eventually { !model.isInFlight }
        XCTAssertTrue(failed, "the turn failed as any connection error fails it")
        XCTAssertFalse(model.isReadOnly)
        XCTAssertEqual(server.calls("get_folder_conversation").count, reads, "no verdict asked for")
    }

    func testAForkOfASessionWhoseHistoryIsGoneSaysWhy() async throws {
        let capabilities = ForkCapabilities()
        server.on("acp_fork") { _ in .status(500, #"{"code": "connection_not_found", "message": "connection not found"}"#) }
        server.on("acp_fork_to_new_conversation") { _ in
            .status(500, #"{"code": "connection_not_found", "message": "connection not found"}"#)
        }
        server.on("acp_fork_conversation") { call in
            (call.body["conversationId"] as? Int) == 0
                ? .status(500, #"{"code": "task_execution_failed", "message": "Conversation not found: 0"}"#)
                : .status(500, #"{"code": "task_execution_failed", "message": "Claude Code no longer has this session's history, so it can't be resumed [history_unavailable]"}"#)
        }
        let target = ForkTarget(conversationID: 7, folderID: 1, agentType: .claudeCode, sessionID: "ext-7",
                                workingDir: "/w/repo")
        do {
            _ = try await SessionForker(client: server.client, capabilities: capabilities)
                .fork(target, at: .latest, wholeConversation: true)
            XCTFail("refused")
        } catch let error as ForkError {
            XCTAssertEqual(error, .historyUnavailable)
            XCTAssertEqual(error.errorDescription, "This session’s history is gone, so it can’t be forked.")
        }

        // A server without the whole-conversation fork: its connect is refused.
        let older = ForkCapabilities()
        server.on("acp_fork_conversation") { _ in .status(501, #"{"code": "not_implemented", "message": "Unknown command"}"#) }
        refuseConnects()
        do {
            _ = try await SessionForker(client: server.client, capabilities: older).fork(target, at: .latest)
            XCTFail("refused")
        } catch let error as ForkError {
            XCTAssertEqual(error, .historyUnavailable)
        }
    }

    // MARK: - Start a new session from this

    func testANewSessionStartsWithTheSavedTextAndSendsNothing() async throws {
        let model = await openLostSession()
        let loaded = await eventually { model.savedCopyReady }
        XCTAssertTrue(loaded)
        guard let request = model.newSessionFromSavedCopy() else { return XCTFail("a draft") }
        XCTAssertEqual(request.agent, .claudeCode, "the same agent")
        XCTAssertEqual(request.preselectedFolderID, 1, "in the same folder")
        XCTAssertNil(request.initialPrompt, "nothing sent by itself")
        guard let prefill = request.prefill else { return XCTFail("the saved text") }
        let preamble = SavedHistoryText.inlinePreamble(agentName: "Claude Code", title: "Higgsfield alternatives")
        XCTAssertTrue(prefill.text.hasPrefix(preamble + "\n\n# Higgsfield alternatives\n\n"), prefill.text)
        XCTAssertTrue(prefill.text.contains("The text codeg saved from an earlier Claude Code session"))
        XCTAssertTrue(prefill.text.contains("## User\n\nDo research on alternatives"))
        XCTAssertTrue(prefill.text.contains("## Claude Code\n\nI started **four** research tracks"))
        XCTAssertNil(prefill.document)

        let draft = makeDraft(request)
        await draft.load()
        XCTAssertEqual(draft.draft, prefill.text, "in the new session's message box")
        XCTAssertEqual(draft.selectedAgent, .claudeCode)
        XCTAssertTrue(draft.attachments.isEmpty)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls("create_conversation").isEmpty)
        XCTAssertTrue(server.calls("acp_connect").isEmpty)
        XCTAssertTrue(server.calls("acp_prompt").isEmpty)
    }

    func testTheCopyKeptOnThisIPhoneGoesIntoTheNewSession() async throws {
        let cache = try await makeCache(holding: keptTurns(6))
        serveDetail(lostDetail(saved: 2))
        let model = makeModel(cache: cache)
        await model.load()
        XCTAssertEqual(model.lostHistoryCopy, .iPhone)

        let prefill = model.newSessionFromSavedCopy()?.prefill
        let text = try XCTUnwrap(prefill?.text)
        XCTAssertTrue(text.contains("The text this iPhone kept of an earlier Claude Code session"), text)
        XCTAssertTrue(text.contains("## User\n\nPrompt 0"))
        XCTAssertTrue(text.contains("## Claude Code\n\nReply 2"))
        XCTAssertTrue(text.contains("## User\n\nPrompt 3"))
        XCTAssertEqual(text.components(separatedBy: "## Claude Code").count - 1, 2,
                       "a tool call without text isn't carried")
    }

    func testALongSavedTextIsAttachedAsAFile() async throws {
        let long = String(repeating: "pricing ", count: 800)
        let turns = [SavedTurn(turnIdx: 0, role: .user, content: "Compare the prices"),
                     SavedTurn(turnIdx: 1, role: .assistant, content: long)]
        let prefill = try XCTUnwrap(SavedHistoryText.prefill(
            conversationID: 7, title: "Prices", agentName: "Claude Code", turns: turns, source: .server))
        XCTAssertEqual(prefill.text, SavedHistoryText.attachedPreamble(agentName: "Claude Code", title: "Prices"))
        let document = try XCTUnwrap(prefill.document)
        XCTAssertEqual(document.fileName, "conversation-7.md")
        XCTAssertEqual(document.contents,
                       SavedHistoryText.markdown(title: "Prices", agentName: "Claude Code", turns: turns, source: .server))
        XCTAssertTrue(document.contents.contains("## User\n\nCompare the prices\n"))
        XCTAssertGreaterThan(document.contents.unicodeScalars.count, SavedHistoryText.inlineMaxChars)

        // The new session attaches it, to upload as any document.
        let draft = makeDraft(NewSessionRequest(preselectedFolderID: 1, agent: .claudeCode, prefill: prefill))
        await draft.load()
        XCTAssertEqual(draft.draft, prefill.text)
        XCTAssertEqual(draft.attachments.map(\.name), ["conversation-7.md"])
        XCTAssertTrue(server.calls("acp_prompt").isEmpty)
    }

    func testMessagesThatWerentSentGoWithIt() async throws {
        serveDetail(readableDetail)
        refuseConnects()
        serveSavedTurns()
        let model = makeModel()
        await model.load()
        serveDetail(lostDetail(saved: 3))
        model.draft = "Now compare their prices"
        model.sendFromComposer()
        let ready = await eventually { model.savedCopyReady && model.queuedMessages.count == 1 }
        XCTAssertTrue(ready)

        let text = try XCTUnwrap(model.newSessionFromSavedCopy()?.prefill?.text)
        XCTAssertTrue(text.hasSuffix("\n\n---\n\nNow compare their prices"), text)
        XCTAssertTrue(model.queuedMessages.isEmpty, "they moved to the new session")
    }

    func testWithNothingSavedTheNewSessionStartsEmpty() async throws {
        serveDetail(lostDetail(saved: 0, reason: "missing", days: nil))
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.lostHistoryCopy, .saved)
        XCTAssertEqual(model.savedCopy, .loaded([]), "nothing to ask the server for")
        XCTAssertTrue(server.calls("get_conversation_saved_turns").isEmpty)
        let request = try XCTUnwrap(model.newSessionFromSavedCopy())
        XCTAssertNil(request.prefill, "no preamble promising text that isn't there")
        XCTAssertEqual(request.agent, .claudeCode)
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
