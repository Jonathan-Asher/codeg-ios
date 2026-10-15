import XCTest
@testable import Codeg

/// Where a message the user sends lands in the conversation, on each of the
/// three ways the message bar's Send (and the Camera Control's send, which
/// calls the same `sendFromComposer`) can take, against a mock codeg server
/// and scripted event sockets:
///
/// - idle: an ordinary prompt, shown at once and replaced by the server's copy;
/// - the turn held open for background work, or "Insert into current turn":
///   delivered into the turn, and shown inside the reply where the agent took
///   it, never only above the message bar;
/// - the agent working: queued above the message bar, and in the conversation
///   once it is sent.
///
/// After the server's echo, a reconnect's snapshot, or the transcript the
/// turn is reconciled with, every message shows exactly once.
@MainActor
final class InsertPlacementTests: XCTestCase {
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

    private func makeModel(_ factory: StreamFactory) -> SessionDetailViewModel {
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID) { _ in
            factory.make()
        }
        models.append(model)
        return model
    }

    private func openIdleSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        return model
    }

    private func openLiveSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: "running")) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live, "attached to the running turn")
        return model
    }

    /// A turn held open for background work: the agent answered and is idle.
    private func openHeldSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        let model = await openLiveSession(factory)
        let ready = await eventually { model.canDeliverIntoHeldTurn }
        XCTAssertTrue(ready)
        return model
    }

    /// The server records the message, echoes it on the stream, then answers.
    private func acceptInserts(on socket: ScriptedStream, id: String = "fb-1", status: String = "delivered") {
        server.on("submit_session_feedback") { call in
            let text = call.body["text"] as? String ?? ""
            socket.push(Wire.feedbackSubmitted(id: id, text: text, status: status))
            return .body(Wire.note(id: id, text: text, status: status))
        }
    }

    // MARK: - Idle: an ordinary prompt

    func testAPromptShowsOnceBeforeAndAfterTheServersCopy() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        XCTAssertEqual(model.composerSendRoute, .send)

        model.draft = "Run the migration"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(Rendered.thread(model), ["you: Run the migration"])

        let socket = factory.opened[0]
        socket.push(Wire.delta("Migrated."))
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([Wire.user(0, "Run the migration"), Wire.agent(1, Wire.text("Migrated."))]))
        }
        socket.push(Wire.turnComplete)

        let reconciled = await eventually { model.liveTurn == nil && model.pendingUserTurns.isEmpty }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(Rendered.thread(model), ["you: Run the migration", "agent: Migrated."])
    }

    // MARK: - Held open for background work: delivered at once

    /// The reported bug: a message sent while the turn was held for background
    /// work stayed above the message bar, and the agent's answer to it streamed
    /// into the conversation above it.
    func testAMessageDeliveredIntoAHeldTurnIsInTheConversationWhereTheAgentTookIt() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openHeldSession(factory)
        let socket = factory.opened[0]
        acceptInserts(on: socket)
        XCTAssertEqual(model.composerSendRoute, .deliver, "a plain send goes into the held turn")

        model.draft = "Ship it"
        model.sendFromComposer()

        let placed = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed)
        XCTAssertTrue(model.stripNotes.isEmpty, "not left above the message bar")
        XCTAssertEqual(Rendered.thread(model), ["agent: Started the build.", "you, during the turn: Ship it"])
        XCTAssertNil(model.notice)
        XCTAssertEqual(server.calls("submit_session_feedback").count, 1)

        // The agent wakes and answers it in the same turn.
        socket.push(Wire.awaitingBackground(false))
        socket.push(Wire.delta("Shipping now."))
        let answered = await eventually { Rendered.thread(model).last == "agent: Shipping now." }
        XCTAssertTrue(answered)
        XCTAssertEqual(Rendered.thread(model),
                       ["agent: Started the build.", "you, during the turn: Ship it", "agent: Shipping now."])

        // The turn ends; the transcript has the agent's own copy of the message.
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([
                Wire.user(0, "Build it"), Wire.agent(1, Wire.text("Started the build.")),
                Wire.user(2, "Ship it"), Wire.agent(3, Wire.text("Shipping now.")),
            ]))
        }
        socket.push(Wire.turnComplete)
        let reconciled = await eventually { model.liveTurn == nil }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(Rendered.thread(model),
                       ["you: Build it", "agent: Started the build.", "you: Ship it", "agent: Shipping now."])
        XCTAssertTrue(model.stripNotes.isEmpty)
    }

    func testTheResponseAloneAlsoPutsTheMessageInTheConversation() async {
        // An echo that never arrives (a dropped frame): the response is enough.
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openHeldSession(factory)
        server.on("submit_session_feedback") { _ in .body(Wire.note(id: "fb-1", text: "Ship it")) }

        model.draft = "Ship it"
        model.sendFromComposer()

        let placed = await eventually { model.liveTurn?.steeredMessages.map(\.serverID) == ["fb-1"] }
        XCTAssertTrue(placed)
        XCTAssertTrue(model.stripNotes.isEmpty)

        // A late echo for the same note changes nothing.
        factory.opened[0].push(Wire.feedbackSubmitted(id: "fb-1", text: "Ship it"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Rendered.thread(model), ["agent: Started the build.", "you, during the turn: Ship it"])
    }

    func testAMessageThatIsStillOnItsWayWaitsAboveTheMessageBar() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openHeldSession(factory)
        let release = DispatchSemaphore(value: 0)
        server.on("submit_session_feedback") { _ in
            release.wait()
            return .body(Wire.note(id: "fb-1", text: "Ship it"))
        }

        model.draft = "Ship it"
        model.sendFromComposer()

        let waiting = await eventually { model.stripNotes.map(\.text) == ["Ship it"] }
        XCTAssertTrue(waiting, "on its way: above the message bar")
        XCTAssertEqual(InsertedNotesView.status(of: model.stripNotes[0]), "Inserting…")
        XCTAssertEqual(model.liveTurn?.steeredMessages.count, 0)

        release.signal()
        let placed = await eventually { model.stripNotes.isEmpty && model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed, "taken: in the conversation")
    }

    func testAMessageForAnAgentThatPullsItsNotesStaysAboveTheMessageBar() async {
        // No native steering on the server's side (it fell back to the
        // `check_user_feedback` tool): the agent reads the note as a tool
        // result, never as a message, as the desktop shows it.
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openHeldSession(factory)
        let socket = factory.opened[0]
        acceptInserts(on: socket, status: "pending")

        model.draft = "Ship it"
        model.sendFromComposer()

        let recorded = await eventually { model.stripNotes.first?.resolved == true }
        XCTAssertTrue(recorded)
        XCTAssertEqual(InsertedNotesView.status(of: model.stripNotes[0]), "Waiting for the agent")
        XCTAssertEqual(model.liveTurn?.steeredMessages.count, 0)

        socket.push(Wire.feedbackConsumed(["fb-1"]))
        let read = await eventually { model.stripNotes.first?.delivered == true }
        XCTAssertTrue(read)
        XCTAssertEqual(InsertedNotesView.status(of: model.stripNotes[0]), "Read by the agent")
    }

    func testContinueIntoAHeldTurnIsTheContinuedDivider() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openHeldSession(factory)
        acceptInserts(on: factory.opened[0])

        model.sendContinue()

        let placed = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed)
        XCTAssertEqual(Rendered.thread(model), ["agent: Started the build.", "continued"])
    }

    // MARK: - The agent working, with native steering: "Insert into current turn"

    func testAMessageInsertedWhileTheAgentWorksIsInTheReplyWhereItWent() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected", nativeSteering: true))])
        let model = await openIdleSession(factory)
        model.draft = "Run the tests"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 && model.canInsertIntoTurn }
        XCTAssertTrue(prompted)
        let socket = factory.opened[0]
        socket.push(Wire.toolCall("tool-1"))
        let running = await eventually { model.liveTurn?.toolCallIDs.contains("tool-1") == true }
        XCTAssertTrue(running)
        XCTAssertEqual(model.composerSendRoute, .enqueue, "a plain send waits for the turn's end")
        acceptInserts(on: socket)

        model.draft = "Also run the linter"
        model.insertIntoTurn()

        let placed = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed)
        XCTAssertEqual(Rendered.thread(model),
                       ["you: Run the tests", "tool: tool-1", "you, during the turn: Also run the linter"])

        // The tool that ran before it stays before it; the answer comes after.
        socket.push(Wire.toolUpdate("tool-1", status: "completed"))
        socket.push(Wire.delta("Tests and lint pass."))
        let answered = await eventually { Rendered.thread(model).last == "agent: Tests and lint pass." }
        XCTAssertTrue(answered)
        XCTAssertEqual(Rendered.thread(model), [
            "you: Run the tests", "tool: tool-1", "you, during the turn: Also run the linter",
            "agent: Tests and lint pass.",
        ])

        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([
                Wire.user(0, "Run the tests"), Wire.agent(1, Wire.tool("tool-1")),
                Wire.user(2, "Also run the linter"), Wire.agent(3, Wire.text("Tests and lint pass.")),
            ]))
        }
        socket.push(Wire.turnComplete)
        let reconciled = await eventually { model.liveTurn == nil && model.pendingUserTurns.isEmpty }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(Rendered.thread(model), [
            "you: Run the tests", "tool: tool-1", "you: Also run the linter", "agent: Tests and lint pass.",
        ])
    }

    func testAMessageSentIntoTheTurnFromTheDesktopIsInTheConversationToo() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Reading the logs.", nativeSteering: true)),
        ])
        let model = await openLiveSession(factory)

        factory.opened[0].push(Wire.feedbackSubmitted(id: "fb-9", text: "Check the staging logs too"))

        let shown = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(shown)
        XCTAssertEqual(Rendered.thread(model),
                       ["agent: Reading the logs.", "you, during the turn: Check the staging logs too"])
        XCTAssertTrue(model.stripNotes.isEmpty)
    }

    // MARK: - The agent working: queued, then sent

    func testAQueuedMessageIsInTheConversationOnceItIsSent() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Reading the logs.")),
        ])
        let model = await openLiveSession(factory)
        XCTAssertEqual(model.composerSendRoute, .enqueue)

        model.draft = "Next step"
        model.sendFromComposer()
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Next step"], "waiting above the message bar")
        XCTAssertFalse(Rendered.thread(model).contains { $0.contains("Next step") }, "not in the conversation yet")

        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([Wire.user(0, "Look at the logs"), Wire.agent(1, Wire.text("Reading the logs."))]))
        }
        factory.opened[0].push(Wire.turnComplete)

        let sent = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(sent, "sent when the turn ended")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(Rendered.thread(model).filter { $0 == "you: Next step" }.count, 1, "in the conversation, once")

        let socket = factory.opened[1]
        socket.push(Wire.delta("Done."))
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([
                Wire.user(0, "Look at the logs"), Wire.agent(1, Wire.text("Reading the logs.")),
                Wire.user(2, "Next step"), Wire.agent(3, Wire.text("Done.")),
            ]))
        }
        socket.push(Wire.turnComplete)
        let reconciled = await eventually { model.liveTurn == nil && model.pendingUserTurns.isEmpty }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(Rendered.thread(model),
                       ["you: Look at the logs", "agent: Reading the logs.", "you: Next step", "agent: Done."])
    }

    func testAQueuedMessageDeliveredIntoTheTurnOnceItIsHeldIsInTheConversation() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Working on it.", nativeSteering: true)),
        ])
        let model = await openLiveSession(factory)
        let socket = factory.opened[0]
        acceptInserts(on: socket)

        model.draft = "Then deploy"
        model.sendFromComposer()
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Then deploy"])

        // The agent answered; only background work holds the turn now.
        socket.push(Wire.awaitingBackground(true))

        let placed = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed)
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertTrue(model.stripNotes.isEmpty)
        XCTAssertEqual(Rendered.thread(model), ["agent: Working on it.", "you, during the turn: Then deploy"])
    }

    // MARK: - Recovery never takes a message out of the conversation

    func testAReconnectKeepsTheMessageWhereItWas() async {
        // After the drop, the snapshot's live message joins the text before
        // and after the message into one block and marks no message at all.
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build. Shipping now.",
                                      nativeSteering: true, backgroundOutstanding: 1,
                                      feedback: [(id: "fb-1", text: "Ship it")])),
        ])
        let model = await openHeldSession(factory)
        let socket = factory.opened[0]
        acceptInserts(on: socket)
        model.draft = "Ship it"
        model.sendFromComposer()
        let placed = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed)
        socket.push(Wire.delta(" Shipping now."))
        let answered = await eventually { Rendered.thread(model).last == "agent:  Shipping now." }
        XCTAssertTrue(answered)
        let before = model.liveTurn

        socket.drop("The network connection was lost.")

        let rebuilt = await eventually { factory.opened.count == 2 && model.liveTurn !== before }
        XCTAssertTrue(rebuilt, "reattached and rebuilt from the snapshot")
        XCTAssertEqual(Rendered.thread(model),
                       ["agent: Started the build.", "you, during the turn: Ship it", "agent:  Shipping now."])
    }

    func testAReplyTheServerNeverReconciledKeepsTheMessageWhereItWas() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", awaitingBackground: true,
                                      nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openHeldSession(factory)
        let socket = factory.opened[0]
        acceptInserts(on: socket)
        model.draft = "Ship it"
        model.sendFromComposer()
        let placed = await eventually { model.liveTurn?.steeredMessages.count == 1 }
        XCTAssertTrue(placed)
        socket.push(Wire.delta("Shipping now."))

        // The transcript never catches up: the reply is folded into the
        // conversation as the phone has it.
        socket.push(Wire.turnComplete)
        let folded = await eventually(timeout: 10) { model.liveTurn == nil }
        XCTAssertTrue(folded)
        XCTAssertEqual(Rendered.thread(model), ["agent: Started the build.", "you: Ship it", "agent: Shipping now."])
    }

    func testReturningToTheAppAfterAFailedReplyShowsThePromptOnce() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        model.draft = "Deploy it"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        factory.opened[0].push(Wire.delta("Deploying"))
        factory.opened[0].push(Fixtures.event(#"{"seq": 40, "connection_id": "conn-1", "type": "error", "message": "The agent crashed."}"#))
        let failed = await eventually { model.liveTurn?.isStreaming == false }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.pendingUserTurns.count, 1)

        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([Wire.user(0, "Deploy it"), Wire.agent(1, Wire.text("Deploying"))]))
        }
        await model.refreshOnForeground()

        XCTAssertNil(model.liveTurn)
        XCTAssertTrue(model.pendingUserTurns.isEmpty)
        XCTAssertEqual(Rendered.thread(model), ["you: Deploy it", "agent: Deploying"], "not twice")
    }
}

// MARK: - The live turn's messages

@MainActor
final class SteeredMessageTests: XCTestCase {
    private func labels(_ live: LiveTurn) -> [String] {
        live.segments.map { segment in
            switch segment {
            case .text(let run): return "text \(run.fullText)"
            case .thinking(let run): return "thinking \(run.fullText)"
            case .tool(let call): return "tool \(call.id)"
            case .steered(let message): return "you \(message.text)"
            }
        }
    }

    private func tool(_ live: LiveTurn, _ id: String) {
        live.upsertToolCall(id: id, title: "Bash", kind: "execute", status: "completed", rawInput: nil,
                            rawOutput: "ok", content: nil)
    }

    func testAMessageGoesAtTheEndOfTheReplySoFarAndTheAnswerAfterIt() {
        let live = LiveTurn()
        live.appendText("Looking.")
        tool(live, "t1")
        live.appendText("Found it")
        XCTAssertTrue(live.insertSteered(id: "a", serverID: "fb-1", text: "Fix it too", blocks: []))
        live.appendText(", fixing")
        XCTAssertEqual(labels(live), ["text Looking.", "tool t1", "text Found it", "you Fix it too", "text , fixing"])
        XCTAssertFalse(live.endsWithSteered)
    }

    func testTheSameMessageIsShownOnce() {
        let live = LiveTurn()
        live.appendText("Working.")
        XCTAssertTrue(live.insertSteered(id: "a", serverID: nil, text: "Ship it", blocks: []))
        XCTAssertFalse(live.insertSteered(id: "a", serverID: "fb-1", text: "Ship it", blocks: []))
        XCTAssertEqual(live.steeredMessages.map(\.serverID), ["fb-1"], "the echo's id is recorded")
        XCTAssertFalse(live.insertSteered(id: "fb-fb-1", serverID: "fb-1", text: "Ship it", blocks: []))
        XCTAssertEqual(live.steeredMessages.count, 1)
        XCTAssertTrue(live.endsWithSteered)
    }

    func testARebuiltReplyGetsItsMessagesBackWhereTheyWere() {
        let live = LiveTurn()
        live.appendThinking("Plan.")
        live.appendText("Looking.")
        tool(live, "t1")
        live.appendText("Found it")
        live.insertSteered(id: "a", serverID: "fb-1", text: "Fix it too", blocks: [])
        live.appendText(", fixing")
        tool(live, "t2")
        live.insertSteered(id: "b", serverID: "fb-2", text: "And test it", blocks: [])
        live.appendText("Done")

        // What a snapshot rebuilds: the text around each message joined.
        let rebuilt = LiveTurn()
        rebuilt.appendThinking("Plan.")
        rebuilt.appendText("Looking.")
        tool(rebuilt, "t1")
        rebuilt.appendText("Found it, fixing")
        tool(rebuilt, "t2")
        rebuilt.appendText("Done, tested")

        rebuilt.adoptSteered(from: live)

        XCTAssertEqual(labels(rebuilt), [
            "thinking Plan.", "text Looking.", "tool t1", "text Found it", "you Fix it too", "text , fixing",
            "tool t2", "you And test it", "text Done, tested",
        ])
    }

    func testAMessageGoesAtTheEndWhenTheRebuiltCopyLacksWhatCameBeforeIt() {
        let live = LiveTurn()
        tool(live, "t1")
        live.insertSteered(id: "a", serverID: "fb-1", text: "Ship it", blocks: [])
        let trimmed = LiveTurn()
        trimmed.appendText("Summary")
        trimmed.adoptSteered(from: live)
        XCTAssertEqual(labels(trimmed), ["text Summary", "you Ship it"], "never dropped")
    }

    func testAMessageFromAnEarlierTurnIsNotCarriedIntoTheNextOne() {
        let live = LiveTurn()
        live.appendText("Working.")
        live.insertSteered(id: "a", serverID: "fb-1", text: "Ship it", blocks: [])
        let next = Fixtures.snapshot(status: "prompting", liveText: "A new turn.")
        let same = Fixtures.snapshot(status: "prompting", liveText: "Working.", feedback: [(id: "fb-1", text: "Ship it")])
        let message = live.steeredMessages[0]
        XCTAssertFalse(SessionDetailViewModel.steered(message, belongsTo: next))
        XCTAssertTrue(SessionDetailViewModel.steered(message, belongsTo: same))
    }

    func testTheFoldedReplyKeepsTheMessageBetweenItsHalves() {
        let live = LiveTurn()
        live.appendText("Started the build.")
        live.insertSteered(id: "a", serverID: "fb-1", text: "Ship it", blocks: [])
        live.appendText("Shipping now.")
        let turns = live.snapshotAsMessageTurns()
        XCTAssertEqual(turns.map(\.role), [.assistant, .user, .assistant])
        XCTAssertEqual(turns.map(\.blocks), [[.text("Started the build.")], [.text("Ship it")], [.text("Shipping now.")]])
        XCTAssertEqual(Set(turns.map(\.id)).count, 3)
        XCTAssertEqual(live.snapshotAsMessageTurn().blocks, [.text("Started the build."), .text("Shipping now.")])
    }

    func testAMessageSplitsAMultibyteRunOnACharacterBoundary() {
        let live = LiveTurn()
        live.appendText("שלום")
        live.insertSteered(id: "a", serverID: "fb-1", text: "עוד", blocks: [])
        let rebuilt = LiveTurn()
        rebuilt.appendText("שלום עולם")
        rebuilt.adoptSteered(from: live)
        XCTAssertEqual(labels(rebuilt), ["text שלום", "you עוד", "text  עולם"])
    }

    func testTheEventCarriesTheNotesStatusTimeAndPictures() throws {
        let json = #"""
        {"seq": 5, "connection_id": "conn-1", "type": "feedback_submitted",
         "item": {"id": "fb-1", "text": "See [image]", "created_at": "2026-10-15T11:41:25.995634Z",
                  "status": "delivered", "delivered_at": "2026-10-15T11:41:25.995634Z",
                  "blocks": [{"type": "text", "text": "See"}, {"type": "image", "data": "AAAA", "mime_type": "image/png"}]}}
        """#
        let envelope = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(json.utf8))
        guard case .feedbackSubmitted(let note) = envelope.event else { return XCTFail("\(envelope.event)") }
        XCTAssertEqual(note.id, "fb-1")
        XCTAssertEqual(note.status, .delivered)
        XCTAssertEqual(note.createdAtMillis, TranscriptTime.millis("2026-10-15T11:41:25.995Z"))
        XCTAssertEqual(note.displayBlocks.count, 2, "what was sent, not the words for it")
        XCTAssertEqual(note.displayBlocks.first, .text("See"))

        let pending = try CodegJSON.decoder.decode(FeedbackNoteSnapshot.self, from: Data(
            #"{"id": "fb-2", "text": "Later", "created_at": "2026-10-15T11:41:25Z", "status": "pending"}"#.utf8))
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.displayBlocks, [.text("Later")])
    }
}

// MARK: - What the transcript shows

/// The conversation as the transcript renders it (`TranscriptView.nodes`), as
/// short labels: the user's messages, the agent's text and its tool calls.
@MainActor
enum Rendered {
    static func thread(_ model: SessionDetailViewModel) -> [String] {
        let suppress = model.liveTurn != nil && model.liveTurnFromReattach && !model.liveCopyIncomplete
        let coverage = suppress
            ? model.liveTurn.map { TranscriptTimeline.LiveCoverage(toolIDs: $0.toolCallIDs, imageCount: $0.imageCount) }
            : nil
        var nodes = TranscriptTimeline.buildPersisted(turns: model.turns, pending: model.pendingUserTurns,
                                                      agent: .claudeCode, suppressInFlight: suppress,
                                                      liveCoverage: coverage)
        if let live = model.liveTurn { nodes += TranscriptTimeline.buildLive(live, agent: .claudeCode) }
        return nodes.compactMap(label)
    }

    private static func label(_ node: TimelineNode) -> String? {
        switch node.content {
        case .user(let turn): return "you: " + text(turn)
        case .insertedUser(let turn): return "you, during the turn: " + text(turn)
        case .continuation: return "continued"
        case .assistantText(let text): return "agent: " + text
        case .liveText(let run, _): return "agent: " + run.fullText
        case .tool(let vm): return "tool: " + vm.id
        case .toolGroup(let items, _): return "tools: " + items.map(\.id).joined(separator: ",")
        default: return nil
        }
    }

    private static func text(_ turn: MessageTurn) -> String {
        turn.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: " ")
    }
}

// MARK: - Wire fixtures

enum Wire {
    static func note(id: String, text: String, status: String = "delivered") -> String {
        """
        {"id": \(Fixtures.quoted(id)), "text": \(Fixtures.quoted(text)), "created_at": "2026-10-04T16:35:00.123456Z",
         "status": "\(status)"\(status == "delivered" ? #", "delivered_at": "2026-10-04T16:35:00.123456Z""# : "")}
        """
    }

    static func feedbackSubmitted(id: String, text: String, status: String = "delivered") -> EventStream.Frame {
        event(#""type": "feedback_submitted", "item": "# + note(id: id, text: text, status: status))
    }

    static func feedbackConsumed(_ ids: [String]) -> EventStream.Frame {
        let list = ids.map(Fixtures.quoted).joined(separator: ", ")
        return event(#""type": "feedback_consumed", "delivered_at": "2026-10-04T16:36:00Z", "ids": ["# + list + "]")
    }

    static func delta(_ text: String) -> EventStream.Frame {
        event(#""type": "content_delta", "text": "# + Fixtures.quoted(text))
    }

    static func toolCall(_ id: String) -> EventStream.Frame {
        event(#""type": "tool_call", "title": "Run the tests", "kind": "execute", "status": "in_progress", "tool_call_id": "# + Fixtures.quoted(id))
    }

    static func toolUpdate(_ id: String, status: String) -> EventStream.Frame {
        event(#""type": "tool_call_update", "status": "\#(status)", "tool_call_id": "# + Fixtures.quoted(id))
    }

    static func awaitingBackground(_ awaiting: Bool) -> EventStream.Frame {
        event(#""type": "awaiting_background", "native_steering": true, "awaiting": "# + (awaiting ? "true" : "false"))
    }

    static let turnComplete = event(#""type": "turn_complete", "stop_reason": "end_turn""#)

    private static func event(_ fields: String) -> EventStream.Frame {
        Fixtures.event(#"{"seq": 20, "connection_id": "conn-1", "# + fields + "}")
    }

    // A transcript as `get_folder_conversation` returns it.

    static func detail(_ turns: [String]) -> String {
        Fixtures.detail().replacingOccurrences(of: #""turns": []"#, with: #""turns": ["# + turns.joined(separator: ", ") + "]")
    }

    static func user(_ index: Int, _ text: String) -> String {
        turn(index, "user", Wire.text(text))
    }

    static func agent(_ index: Int, _ blocks: String) -> String {
        turn(index, "assistant", blocks)
    }

    static func text(_ text: String) -> String {
        #"{"type": "text", "text": "# + Fixtures.quoted(text) + "}"
    }

    static func tool(_ id: String) -> String {
        let quoted = Fixtures.quoted(id)
        return #"{"type": "tool_use", "tool_use_id": "# + quoted + #", "tool_name": "Bash"}, "#
            + #"{"type": "tool_result", "tool_use_id": "# + quoted + #", "output_preview": "ok", "is_error": false}"#
    }

    private static func turn(_ index: Int, _ role: String, _ blocks: String) -> String {
        #"{"id": "turn-\#(index)", "role": "\#(role)", "timestamp": "2026-10-04T16:\#(30 + index):00.000Z", "blocks": ["#
            + blocks + "]}"
    }
}
