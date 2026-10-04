import XCTest
@testable import Codeg

/// The session screen against a mock codeg server and scripted event sockets:
/// a socket that dies (a frame over the old 1 MiB limit, a dropped LTE
/// connection) must never fail or lose a send, an unclear prompt or insert is
/// checked against the server before it is reported as failed, and an idle
/// connection is never shown as a running turn.
@MainActor
final class SendRecoveryTests: XCTestCase {
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

    /// A screen opened on a session with no live connection, ready to send.
    private func openIdleSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(factory.opened.isEmpty, "nothing to attach to on open")
        return model
    }

    /// A screen opened on a session whose turn runs on the server.
    private func openLiveSession(_ factory: StreamFactory, turnState: String? = "running") async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: turnState)) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        return model
    }

    // MARK: - The reported bug: "Network error: … Message too long"

    func testASocketThatDiesOnAnOversizedFrameDuringTheAttachDoesNotFailTheSend() async {
        let factory = StreamFactory([
            .dropOnAttach(Fixtures.messageTooLong),
            .attach(Fixtures.snapshot(status: "connected")),
        ])
        let model = await openIdleSession(factory)

        model.draft = "Run the migration"
        model.sendFromComposer()

        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted, "the prompt went out after a fresh socket attached")
        XCTAssertNil(model.notice, "no network error banner")
        XCTAssertEqual(model.draft, "", "the message isn't handed back to the composer")
        XCTAssertEqual(model.pendingUserTurns.count, 1)
        XCTAssertTrue(model.isInFlight)
        XCTAssertEqual(factory.opened.count, 2)
        XCTAssertTrue(server.calls("acp_prompt")[0].text.contains("Run the migration"))
    }

    func testWhenNoSocketAttachesThePromptStillGoesAndTheStreamRecovers() async {
        let factory = StreamFactory([
            .dropOnAttach(Fixtures.messageTooLong),
            .dropOnAttach(Fixtures.messageTooLong),
            .dropOnAttach(Fixtures.messageTooLong),
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Migrating the schema")),
        ])
        let model = await openIdleSession(factory)

        model.draft = "Run the migration"
        model.sendFromComposer()

        let recovered = await eventually {
            model.liveTurn?.snapshotAsMessageTurn().blocks.contains(.text("Migrating the schema")) == true
        }
        XCTAssertTrue(recovered, "the reconnect adopted what the agent streamed meanwhile")
        XCTAssertEqual(server.calls("acp_prompt").count, 1)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.isInFlight)
        XCTAssertEqual(factory.opened.count, 4)
    }

    func testAPromptWhoseResponseIsLostCountsWhenTheServerRunsIt() async {
        var clientMessageID = ""
        server.on("acp_prompt") { call in
            clientMessageID = call.body["clientMessageId"] as? String ?? ""
            return .fail(.networkConnectionLost)
        }
        server.on("acp_get_session_snapshot") { _ in
            .body(Fixtures.snapshotJSON(status: "prompting", pendingUserMessageID: clientMessageID))
        }
        let model = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))

        model.draft = "Deploy it"
        model.sendFromComposer()

        let checked = await eventually { !self.server.calls("acp_get_session_snapshot").isEmpty }
        XCTAssertTrue(checked, "the server was asked whether it took the prompt")
        // A prompt the server didn't confirm would fail within the checks' window.
        let failedAnyway = await eventually(timeout: 2.5) { model.notice != nil }
        XCTAssertFalse(failedAnyway)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.pendingUserTurns.count, 1)
        XCTAssertTrue(model.isInFlight)
        XCTAssertEqual(server.calls("acp_prompt").count, 1, "never sent twice")
    }

    func testAPromptLostForGoodIsHandedBack() async {
        server.on("acp_prompt") { _ in .fail(.networkConnectionLost) }
        server.on("acp_get_session_snapshot") { _ in .body(Fixtures.snapshotJSON(status: "connected")) }
        let model = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))

        model.draft = "Deploy it"
        model.sendFromComposer()

        let failed = await eventually { model.notice != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.draft, "Deploy it", "a prompt the server never took goes back to the composer")
        XCTAssertTrue(model.pendingUserTurns.isEmpty)
        XCTAssertFalse(model.isInFlight)
    }

    func testATurnThisScreenDidNotKnowAboutQueuesTheMessage() async {
        server.on("acp_prompt") { _ in .status(409, #"{"code": "turn_in_progress", "message": "busy"}"#) }
        server.on("acp_get_session_snapshot") { _ in
            .body(Fixtures.snapshotJSON(status: "prompting", pendingUserMessageID: "sent-from-the-desktop"))
        }
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "connected")),
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Working on the desktop's request")),
        ])
        let model = await openIdleSession(factory)
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }

        model.draft = "And then the docs"
        model.sendFromComposer()

        let queued = await eventually { model.queuedMessages.first?.text == "And then the docs" }
        XCTAssertTrue(queued, "kept for the end of the running turn")
        XCTAssertEqual(model.draft, "")
        XCTAssertNotNil(model.notice)
        let attached = await eventually { model.isInFlight }
        XCTAssertTrue(attached, "attached to the running turn so the queue moves when it ends")
    }

    // MARK: - Messages into a running turn

    func testAnInsertWhoseResponseTimesOutIsKeptWhenTheServerRecordedIt() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Done. Waiting on the build.",
                                      awaitingBackground: true, nativeSteering: true, backgroundOutstanding: 1)),
        ])
        let model = await openLiveSession(factory)
        let ready = await eventually { model.canDeliverIntoHeldTurn }
        XCTAssertTrue(ready)
        server.on("submit_session_feedback") { _ in .fail(.timedOut) }
        server.on("acp_get_session_snapshot") { _ in
            .body(Fixtures.snapshotJSON(status: "prompting", awaitingBackground: true, nativeSteering: true,
                                        feedback: [(id: "fb-1", text: "Ship it")]))
        }

        model.draft = "Ship it"
        model.sendFromComposer()

        let confirmed = await eventually { model.insertedNotes.first?.serverID == "fb-1" }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(model.insertedNotes.first?.delivered, true)
        XCTAssertNil(model.notice, "no false network error")
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(server.calls("submit_session_feedback").count, 1, "never sent twice")
    }

    func testAnInsertTheServerNeverGotIsHandedBack() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", awaitingBackground: true, nativeSteering: true)),
        ])
        let model = await openLiveSession(factory)
        let ready = await eventually { model.canDeliverIntoHeldTurn }
        XCTAssertTrue(ready)
        server.on("submit_session_feedback") { _ in .fail(.timedOut) }
        server.on("acp_get_session_snapshot") { _ in
            .body(Fixtures.snapshotJSON(status: "prompting", awaitingBackground: true, nativeSteering: true))
        }

        model.draft = "Ship it"
        model.sendFromComposer()

        let failed = await eventually { model.notice != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.draft, "Ship it")
        XCTAssertTrue(model.insertedNotes.isEmpty)
    }

    // MARK: - Working on the list, idle on the screen (and back)

    func testAnIdleConnectionWithOutOfTurnOutputIsNotShownAsWorking() async {
        // The list reads `turn_state` (none) as idle; the connection is idle
        // too, with output the agent produced after its turn ended.
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "connected", liveText: "The background job finished.",
                                      backgroundOutstanding: 1)),
        ])
        let model = await openLiveSession(factory, turnState: nil)

        let released = await eventually { factory.opened.first?.isClosed == true }
        XCTAssertTrue(released, "the idle connection is let go")
        XCTAssertNil(model.liveTurn)
        XCTAssertFalse(model.isInFlight)
        XCTAssertEqual(model.activity, .idle)
        XCTAssertEqual(model.activity, SessionActivity.of(model.summary!), "the screen agrees with the list")
    }

    func testARunningTurnIsStillShownAsWorking() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Reading the logs")),
        ])
        let model = await openLiveSession(factory)

        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live)
        XCTAssertEqual(model.activity, .working)
    }

    func testATurnThatEndedWhileTheSocketWasDownSettlesAndTheQueueMoves() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Reading the logs")),
            .attach(Fixtures.snapshot(status: "connected")),
        ])
        server.on("acp_get_session_snapshot") { _ in .body(Fixtures.snapshotJSON(status: "connected")) }
        let model = await openLiveSession(factory)
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live)

        model.draft = "Next step"
        model.sendFromComposer()
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Next step"])

        // The socket dies on an oversized frame; meanwhile the turn ends.
        factory.opened[0].drop(Fixtures.messageTooLong)

        let sent = await eventually(timeout: 10) { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(sent, "the queued message went once the missed turn end was settled")
        XCTAssertTrue(server.calls("acp_prompt").first?.text.contains("Next step") == true)
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertNil(model.notice)
    }

    func testASocketThatDropsBeforeTheReattachSnapshotTriesAgain() async {
        let factory = StreamFactory([
            .dropOnAttach(Fixtures.messageTooLong),
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Reading the logs")),
        ])
        let model = await openLiveSession(factory)

        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live, "the session's running turn is attached after the drop")
        XCTAssertEqual(factory.opened.count, 2)
    }
}
