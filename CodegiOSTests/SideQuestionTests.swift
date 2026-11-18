import XCTest
@testable import Codeg

/// `/btw` side questions: what counts as one, the server's payloads, and a
/// session screen against a mock codeg server and scripted sockets. A side
/// question is never sent as a message, never queued, never put into the
/// running turn and never in the transcript.
@MainActor
final class SideQuestionTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []

    override func setUp() async throws {
        server = MockCodegServer()
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
    }

    // MARK: - Session helpers

    private func makeModel(_ factory: StreamFactory) -> SessionDetailViewModel {
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID) { _ in
            factory.make()
        }
        models.append(model)
        return model
    }

    /// A session with no live connection.
    private func openIdleSession(agent: String = "claude_code") async -> SessionDetailViewModel {
        let detail = Fixtures.detail().replacingOccurrences(of: #""claude_code""#, with: Fixtures.quoted(agent))
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let model = makeModel(StreamFactory([]))
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        return model
    }

    /// A session whose turn is running, attached to it.
    private func openLiveSession(_ snapshot: LiveSessionSnapshot) async -> (SessionDetailViewModel, StreamFactory) {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: "running")) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let factory = StreamFactory([.attach(snapshot)])
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live, "attached to the running turn")
        return (model, factory)
    }

    private func assertNothingWentToTheAgent(_ model: SessionDetailViewModel, file: StaticString = #filePath,
                                             line: UInt = #line) {
        XCTAssertTrue(server.calls("acp_prompt").isEmpty, "no prompt", file: file, line: line)
        XCTAssertTrue(server.calls("submit_session_feedback").isEmpty, "nothing into the turn", file: file, line: line)
        XCTAssertTrue(model.queuedMessages.isEmpty, "nothing queued", file: file, line: line)
        XCTAssertTrue(model.pendingUserTurns.isEmpty, "no message of yours", file: file, line: line)
        XCTAssertFalse(Rendered.thread(model).contains { $0.lowercased().contains("btw") },
                       "not in the conversation", file: file, line: line)
    }

    // MARK: - Parsing

    func testALeadingBtwInAnyCaseIsASideQuestion() {
        XCTAssertEqual(SideQuestionCommand.parse("/btw what are you reading?")?.question, "what are you reading?")
        XCTAssertEqual(SideQuestionCommand.parse("/BTW why?")?.question, "why?")
        XCTAssertEqual(SideQuestionCommand.parse("/Btw  why  ")?.question, "why")
        XCTAssertEqual(SideQuestionCommand.parse("  \n/bTw why")?.question, "why", "leading whitespace is fine")
        XCTAssertEqual(SideQuestionCommand.parse("/btw\twhy")?.question, "why")
        XCTAssertEqual(SideQuestionCommand.parse("/btw first line\nsecond line")?.question,
                       "first line\nsecond line")
    }

    func testBtwAloneReopensTheAnswers() {
        XCTAssertEqual(SideQuestionCommand.parse("/btw")?.question, "")
        XCTAssertEqual(SideQuestionCommand.parse("/BTW   ")?.question, "")
        XCTAssertEqual(SideQuestionCommand.parse(" /btw \n")?.question, "")
    }

    func testAnythingElseIsAMessage() {
        XCTAssertNil(SideQuestionCommand.parse("/btwx why"))
        XCTAssertNil(SideQuestionCommand.parse("/btw-later"))
        XCTAssertNil(SideQuestionCommand.parse("/btw?"))
        XCTAssertNil(SideQuestionCommand.parse("please /btw why"), "a /btw in the middle")
        XCTAssertNil(SideQuestionCommand.parse("first\n/btw why"), "a /btw on a later line")
        XCTAssertNil(SideQuestionCommand.parse("btw why"))
        XCTAssertNil(SideQuestionCommand.parse("//btw why"))
        XCTAssertNil(SideQuestionCommand.parse("/bt"))
        XCTAssertNil(SideQuestionCommand.parse(""))
    }

    // MARK: - Wire

    func testTheExchangeDecodesAsTheServerWritesIt() throws {
        let record = try CodegJSON.decoder.decode(SideQuestionRecord.self, from: Data(SideQuestionWire.record().utf8))
        XCTAssertEqual(record.id, 12)
        XCTAssertEqual(record.conversationId, 7)
        XCTAssertEqual(record.question, "What are you reading?")
        XCTAssertEqual(record.answer, "The **config** loader, `config.rs`.")
        XCTAssertFalse(record.synthetic)
        XCTAssertNil(record.fallbackNotice)
        XCTAssertNotNil(record.createdAt)
    }

    func testAnUnkeptExchangeAndTheHistoryDecode() throws {
        let json = """
        [\(SideQuestionWire.record(id: 3)),
         {"id": null, "conversationId": null, "question": "Asked of a connection", "answer": null,
          "synthetic": true, "fallbackNotice": "A fallback model answered.", "createdAt": "2026-11-18T10:16:00Z"}]
        """
        let records = try CodegJSON.decoder.decode([SideQuestionRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].id, 3)
        XCTAssertNil(records[1].id)
        XCTAssertNil(records[1].conversationId)
        XCTAssertNil(records[1].answer, "the agent answered with nothing")
        XCTAssertTrue(records[1].synthetic)
        XCTAssertEqual(records[1].fallbackNotice, "A fallback model answered.")
    }

    func testTheSnapshotAndTheEventSayWhetherTheAgentAnswers() throws {
        XCTAssertTrue(Fixtures.snapshot(status: "connected", sideQuestion: true).sideQuestionSupported)
        XCTAssertFalse(Fixtures.snapshot(status: "connected").sideQuestionSupported, "left out when false")

        let frame = #"{"seq": 4, "connection_id": "conn-1", "type": "codeg_extensions", "side_question": true, "prompt_suggestions": false}"#
        let envelope = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(frame.utf8))
        XCTAssertEqual(envelope.event, .codegExtensions(sideQuestion: true, promptSuggestions: false))
    }

    func testTheServersRefusalsReadAsUnsupported() {
        func refusal(_ status: Int, _ body: String) -> APIError {
            CodegClient.refusalError(status: status, body: Data(body.utf8))
        }
        XCTAssertTrue(refusal(400, #"{"code": "invalid_input", "message": "this agent cannot answer side questions"}"#)
            .isSideQuestionUnsupported)
        XCTAssertTrue(refusal(501, #"{"code": "not_implemented", "message": "API endpoint 'acp_side_question' is not available in web mode"}"#)
            .isSideQuestionUnsupported, "an older server")
        XCTAssertFalse(refusal(500, #"{"code": "task_execution_failed", "message": "\#(SideQuestionWire.timedOutMessage)"}"#)
            .isSideQuestionUnsupported)
        XCTAssertFalse(refusal(400, #"{"code": "invalid_input", "message": "invalid side question: the question is empty"}"#)
            .isSideQuestionUnsupported)
        XCTAssertFalse(refusal(404, #"{"code": "not_found", "message": "Connection not found: conn-9"}"#)
            .isSideQuestionUnsupported)
    }

    func testWhatTheSessionGoesBy() {
        XCTAssertEqual(SideQuestionSupport.resolve(live: true, remembered: false, agent: .codex), .supported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: false, remembered: true, agent: .claudeCode), .unsupported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: nil, remembered: false, agent: .claudeCode), .unsupported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: nil, remembered: true, agent: .codex), .supported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: nil, remembered: nil, agent: .claudeCode), .supported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: nil, remembered: nil, agent: .pi), .supported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: nil, remembered: nil, agent: .codex), .unsupported)
        XCTAssertEqual(SideQuestionSupport.resolve(live: nil, remembered: nil, agent: .gemini), .unsupported)
    }

    // MARK: - Mid-turn

    func testASideQuestionMidTurnIsAskedAndNeverQueued() async {
        let gate = ReplyGate()
        server.on("acp_side_question") { _ in .held(gate, .body(SideQuestionWire.record())) }
        let (model, _) = await openLiveSession(
            Fixtures.snapshot(status: "prompting", liveText: "Reading the logs.", sideQuestion: true))
        XCTAssertEqual(model.composerSendRoute, .enqueue, "a message would be queued")

        model.draft = "/btw What are you reading?"
        model.sendFromComposer()

        XCTAssertEqual(model.draft, "", "the question left the message bar")
        XCTAssertTrue(model.sideQuestions.isOpen)
        XCTAssertEqual(model.sideQuestions.current?.question, "What are you reading?")
        XCTAssertEqual(model.sideQuestions.current?.status, .pending)
        let asked = await eventually { self.server.calls("acp_side_question").count == 1 }
        XCTAssertTrue(asked)
        let body = server.calls("acp_side_question")[0].body
        XCTAssertEqual(body["connectionId"] as? String, "conn-1")
        XCTAssertEqual(body["conversationId"] as? Int, Fixtures.conversationID)
        XCTAssertEqual(body["question"] as? String, "What are you reading?")
        assertNothingWentToTheAgent(model)
        XCTAssertTrue(model.isInFlight, "the turn goes on")

        gate.open()
        let answered = await eventually { model.sideQuestions.current?.record?.id == 12 }
        XCTAssertTrue(answered)
        XCTAssertEqual(model.sideQuestions.current?.record?.answer, "The **config** loader, `config.rs`.")
        assertNothingWentToTheAgent(model)
    }

    func testQueueAndInsertIntoTheTurnTakeASideQuestionToo() async {
        server.on("acp_side_question") { call in
            let question = call.body["question"] as? String ?? ""
            return .body(SideQuestionWire.record(id: question == "which file?" ? 1 : 2, question: question))
        }
        let (model, _) = await openLiveSession(Fixtures.snapshot(
            status: "prompting", liveText: "Reading the logs.", nativeSteering: true, sideQuestion: true))
        XCTAssertTrue(model.canInsertIntoTurn)

        model.draft = "/BTW which file?"
        model.queueDraft()
        model.draft = "/btw and the next one?"
        model.insertIntoTurn()

        let asked = await eventually { self.server.calls("acp_side_question").count == 2 }
        XCTAssertTrue(asked)
        XCTAssertEqual(server.calls("acp_side_question").map { $0.body["question"] as? String },
                       ["which file?", "and the next one?"])
        XCTAssertEqual(model.draft, "")
        assertNothingWentToTheAgent(model)
        let settled = await eventually { model.sideQuestions.entries.allSatisfy { $0.record != nil } }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.sideQuestions.entries.count, 2)
        XCTAssertEqual(model.sideQuestions.index, 1, "the newest on screen")
    }

    func testAMessageMidTurnIsStillQueued() async {
        let (model, _) = await openLiveSession(
            Fixtures.snapshot(status: "prompting", liveText: "Reading the logs.", sideQuestion: true))
        model.draft = "/btwx is not a side question"
        model.sendFromComposer()
        XCTAssertEqual(model.queuedMessages.map(\.text), ["/btwx is not a side question"])
        XCTAssertTrue(server.calls("acp_side_question").isEmpty)
    }

    // MARK: - Between turns

    func testASideQuestionBetweenTurnsStartsNoTurn() async {
        server.on("acp_side_question") { _ in .body(SideQuestionWire.record()) }
        let model = await openIdleSession()

        model.draft = "/btw What are you reading?"
        model.sendFromComposer()

        let answered = await eventually { model.sideQuestions.current?.record != nil }
        XCTAssertTrue(answered)
        let body = server.calls("acp_side_question")[0].body
        XCTAssertNil(body["connectionId"], "no live connection: the server finds or opens the session")
        XCTAssertEqual(body["conversationId"] as? Int, Fixtures.conversationID)
        XCTAssertTrue(server.calls("acp_connect").isEmpty, "no connection of the phone's own")
        XCTAssertFalse(model.isInFlight)
        assertNothingWentToTheAgent(model)
    }

    func testBtwAloneReopensEarlierAnswers() async {
        server.on("acp_list_side_questions") { _ in
            .body("[\(SideQuestionWire.record(id: 1, question: "First?", answer: "One.")), \(SideQuestionWire.record(id: 2, question: "Second?", answer: "Two."))]")
        }
        let model = await openIdleSession()

        model.draft = "/btw"
        model.sendFromComposer()

        XCTAssertTrue(model.sideQuestions.isOpen)
        let loaded = await eventually { model.sideQuestions.entries.count == 2 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.sideQuestions.current?.question, "Second?", "the newest")
        XCTAssertEqual(server.calls("acp_list_side_questions").first?.body["conversationId"] as? Int,
                       Fixtures.conversationID)
        model.sideQuestions.step(-1)
        XCTAssertEqual(model.sideQuestions.current?.record?.answer, "One.")
        model.sideQuestions.step(-1)
        XCTAssertEqual(model.sideQuestions.index, 0, "no step before the first")
        XCTAssertTrue(server.calls("acp_side_question").isEmpty, "nothing asked")
        assertNothingWentToTheAgent(model)

        model.sideQuestions.close()
        XCTAssertFalse(model.sideQuestions.isOpen)
    }

    // MARK: - Sessions that can't answer

    func testAConnectionWithoutSideQuestionsKeepsTheTextWithANotice() async {
        let (model, _) = await openLiveSession(Fixtures.snapshot(status: "prompting", liveText: "Reading the logs."))
        XCTAssertEqual(model.sideQuestionSupport, .unsupported)

        model.draft = "/btw why?"
        model.sendFromComposer()
        model.queueDraft()
        model.insertIntoTurn()

        XCTAssertEqual(model.draft, "/btw why?", "the text stays")
        XCTAssertEqual(model.notice, SessionDetailViewModel.sideQuestionUnsupportedNotice)
        XCTAssertFalse(model.sideQuestions.isOpen)
        XCTAssertTrue(server.calls("acp_side_question").isEmpty)
        assertNothingWentToTheAgent(model)
    }

    func testTheAdaptersCodegExtensionsEventCounts() async {
        server.on("acp_side_question") { _ in .body(SideQuestionWire.record()) }
        let (model, factory) = await openLiveSession(
            Fixtures.snapshot(status: "prompting", liveText: "Reading the logs."))
        XCTAssertEqual(model.sideQuestionSupport, .unsupported)

        factory.opened[0].push(Fixtures.event(
            #"{"seq": 5, "connection_id": "conn-1", "type": "codeg_extensions", "side_question": true, "prompt_suggestions": true}"#))
        let heard = await eventually { model.sideQuestionSupport == .supported }
        XCTAssertTrue(heard)

        model.draft = "/btw why?"
        model.sendFromComposer()
        let asked = await eventually { self.server.calls("acp_side_question").count == 1 }
        XCTAssertTrue(asked)
        assertNothingWentToTheAgent(model)
    }

    func testAnotherAgentGetsTheNoticeWithoutARequest() async {
        let model = await openIdleSession(agent: "codex")
        model.draft = "/btw why?"
        model.sendFromComposer()
        XCTAssertEqual(model.draft, "/btw why?")
        XCTAssertEqual(model.notice, SessionDetailViewModel.sideQuestionUnsupportedNotice)
        XCTAssertTrue(server.calls("acp_side_question").isEmpty)
        assertNothingWentToTheAgent(model)
    }

    func testAnAgentTheServerRefusesGetsTheQuestionBack() async {
        server.on("acp_side_question") { _ in SideQuestionWire.unsupported }
        let model = await openIdleSession()

        model.draft = "/btw why?"
        model.sendFromComposer()

        let refused = await eventually { model.notice == SessionDetailViewModel.sideQuestionUnsupportedNotice }
        XCTAssertTrue(refused)
        XCTAssertEqual(model.draft, "/btw why?", "back in the message bar")
        XCTAssertFalse(model.sideQuestions.isOpen)
        XCTAssertTrue(model.sideQuestions.entries.isEmpty)
        assertNothingWentToTheAgent(model)

        // Remembered: the next one isn't asked.
        model.notice = nil
        model.sendFromComposer()
        XCTAssertEqual(model.notice, SessionDetailViewModel.sideQuestionUnsupportedNotice)
        XCTAssertEqual(server.calls("acp_side_question").count, 1)
    }

    func testAnOlderServerGetsTheQuestionBack() async {
        server.on("acp_side_question") { _ in SideQuestionWire.missingEndpoint }
        let model = await openIdleSession()
        model.draft = "/btw why?"
        model.sendFromComposer()
        let refused = await eventually { model.notice == SessionDetailViewModel.sideQuestionUnsupportedNotice }
        XCTAssertTrue(refused)
        XCTAssertEqual(model.draft, "/btw why?")
        assertNothingWentToTheAgent(model)
    }

    func testTextTypedMeanwhileIsKeptWhenTheServerRefuses() async {
        let gate = ReplyGate()
        server.on("acp_side_question") { _ in .held(gate, SideQuestionWire.unsupported) }
        let model = await openIdleSession()
        model.draft = "/btw why?"
        model.sendFromComposer()
        let asked = await eventually { self.server.calls("acp_side_question").count == 1 }
        XCTAssertTrue(asked)
        model.draft = "Something else"
        gate.open()
        let refused = await eventually { model.notice == SessionDetailViewModel.sideQuestionUnsupportedNotice }
        XCTAssertTrue(refused)
        XCTAssertEqual(model.draft, "Something else")
    }

    // MARK: - Cancel and failures

    func testCancelStopsWaiting() async {
        let gate = ReplyGate()
        server.on("acp_side_question") { _ in .held(gate, .body(SideQuestionWire.record())) }
        let (model, _) = await openLiveSession(
            Fixtures.snapshot(status: "prompting", liveText: "Reading the logs.", sideQuestion: true))
        model.draft = "/btw What are you reading?"
        model.sendFromComposer()
        let asked = await eventually { self.server.calls("acp_side_question").count == 1 }
        XCTAssertTrue(asked)
        guard let entry = model.sideQuestions.current else { return XCTFail("no side question on screen") }

        model.sideQuestions.cancel(entry.id)

        XCTAssertTrue(model.sideQuestions.entries.isEmpty)
        XCTAssertFalse(model.sideQuestions.isOpen, "nothing left to show")
        gate.open()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.sideQuestions.entries.isEmpty, "a late answer doesn't come back")
        XCTAssertTrue(model.isInFlight, "the turn goes on")
        assertNothingWentToTheAgent(model)
    }

    func testCancelKeepsTheEarlierAnswers() async {
        server.on("acp_list_side_questions") { _ in .body("[\(SideQuestionWire.record(id: 1, question: "First?"))]") }
        let gate = ReplyGate()
        server.on("acp_side_question") { _ in .held(gate, .body(SideQuestionWire.record(id: 2))) }
        let model = await openIdleSession()
        model.draft = "/btw Second?"
        model.sendFromComposer()
        let loaded = await eventually { model.sideQuestions.entries.count == 2 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.sideQuestions.current?.status, .pending)

        model.sideQuestions.cancel(model.sideQuestions.current!.id)

        XCTAssertEqual(model.sideQuestions.entries.map(\.question), ["First?"])
        XCTAssertTrue(model.sideQuestions.isOpen)
        XCTAssertEqual(model.sideQuestions.index, 0)
        gate.open()
    }

    func testAFailureSaysWhyAndCanBeAskedAgain() async {
        server.on("acp_side_question") { _ in
            .status(500, #"{"code": "task_execution_failed", "message": "\#(SideQuestionWire.timedOutMessage)"}"#)
        }
        let model = await openIdleSession()
        model.draft = "/btw why?"
        model.sendFromComposer()
        let failed = await eventually { model.sideQuestions.current?.status == .failed(SideQuestionWire.timedOutMessage) }
        XCTAssertTrue(failed)
        XCTAssertTrue(model.sideQuestions.isOpen)
        XCTAssertNil(model.notice)

        server.on("acp_side_question") { _ in .body(SideQuestionWire.record(question: "why?")) }
        model.sideQuestions.retry(model.sideQuestions.current!.id)
        let answered = await eventually { model.sideQuestions.current?.record != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(server.calls("acp_side_question").count, 2)
        XCTAssertEqual(model.sideQuestions.entries.count, 1)
        assertNothingWentToTheAgent(model)
    }

    /// The history, fetched while the question was on its way, already
    /// holds its answer: it shows once, on screen.
    func testAnAnswerAlreadyInTheHistoryIsShownOnce() async {
        server.on("acp_list_side_questions") { _ in
            .body("[\(SideQuestionWire.record(id: 1, question: "First?")), \(SideQuestionWire.record(id: 2, question: "Second?"))]")
        }
        let gate = ReplyGate()
        server.on("acp_side_question") { _ in .held(gate, .body(SideQuestionWire.record(id: 2, question: "Second?"))) }
        let model = await openIdleSession()
        model.draft = "/btw Second?"
        model.sendFromComposer()
        let loaded = await eventually { model.sideQuestions.entries.count == 3 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.sideQuestions.current?.status, .pending, "the question asked stays on screen")

        gate.open()
        let settled = await eventually { model.sideQuestions.entries.count == 2 }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.sideQuestions.entries.compactMap { $0.record?.id }, [1, 2])
        XCTAssertEqual(model.sideQuestions.current?.record?.id, 2)
    }
}

/// Payloads copied from the server's code, for the mock server's routes.
enum SideQuestionWire {
    /// `side_question::SideQuestionRecord` as serde writes it
    /// (`rename_all = "camelCase"`, chrono's nanosecond timestamp).
    static func record(id: Int = 12, question: String = "What are you reading?",
                       answer: String = "The **config** loader, `config.rs`.") -> String {
        """
        {"id": \(id), "conversationId": 7, "question": \(Fixtures.quoted(question)),
         "answer": \(Fixtures.quoted(answer)), "synthetic": false, "fallbackNotice": null,
         "createdAt": "2026-11-18T10:15:30.123456789Z"}
        """
    }

    /// `AcpError::SideQuestionUnsupported` through `side_question_error`.
    static let unsupported = MockCodegServer.Reply.status(
        400, #"{"code": "invalid_input", "message": "this agent cannot answer side questions"}"#)

    /// `api_not_found` on a server without `acp_side_question`.
    static let missingEndpoint = MockCodegServer.Reply.status(
        501, #"{"code": "not_implemented", "message": "API endpoint 'acp_side_question' is not available in web mode"}"#)

    /// `AcpError::SideQuestionTimedOut { secs: 180 }`.
    static let timedOutMessage =
        "The side question got no answer within 180 seconds, so codeg cancelled it. Try again, or ask in the conversation."
}
