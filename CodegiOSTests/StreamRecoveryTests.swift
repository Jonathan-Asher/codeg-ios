import XCTest
@testable import Codeg

/// The pieces of stream recovery that need no server: the socket's frame-size
/// limit, the attach handshake's retry rule, what a snapshot says about the
/// turn, and how an unclear send is matched to what the server recorded.
final class StreamRecoveryTests: XCTestCase {

    // MARK: Frame size

    func testSocketsAcceptFramesFarAboveTheOneMegabyteDefault() {
        XCTAssertEqual(EventStream.maximumMessageSize, 64 * 1024 * 1024)
        let session = URLSession(configuration: .ephemeral)
        let task = EventStream.makeTask(session: session, url: URL(string: "ws://127.0.0.1:9/ws/events")!,
                                        protocols: ["codeg-events"])
        defer { task.cancel() }
        XCTAssertEqual(task.maximumMessageSize, 64 * 1024 * 1024)
        // The 1.3 to 1.5 MB background-activity events that broke the socket fit.
        XCTAssertGreaterThan(task.maximumMessageSize, 1_500_000)
    }

    // MARK: Attach handshake

    func testADroppedAttachIsRetriedWithBackoffThenThePromptGoesWithoutAStream() {
        let drop = StreamHandshake.Failure.dropped(reason: Fixtures.messageTooLong)
        XCTAssertEqual(StreamHandshake.next(after: drop, attempt: 1), .retry(after: .milliseconds(500)))
        XCTAssertEqual(StreamHandshake.next(after: drop, attempt: 2), .retry(after: .milliseconds(1000)))
        XCTAssertEqual(StreamHandshake.next(after: drop, attempt: 3), .promptWithoutStream)
        XCTAssertEqual(StreamHandshake.next(after: drop, attempt: 9), .promptWithoutStream)
    }

    func testAHungAttachIsNotWaitedForAgain() {
        XCTAssertEqual(StreamHandshake.next(after: .timedOut, attempt: 1), .promptWithoutStream)
    }

    // MARK: What a snapshot says about the turn

    func testOutOfTurnOutputOnAnIdleConnectionIsNotATurn() {
        // The agent kept working after its turn ended (a background task's
        // notification woke it): the server collects that into `live_message`
        // while the connection is idle. The session list reads it as idle, so
        // must the session screen.
        let ghost = Fixtures.snapshot(status: "connected", liveText: "The build finished; all green.",
                                      backgroundOutstanding: 2)
        XCTAssertNotNil(ghost.liveMessage)
        XCTAssertFalse(ghost.isTurnInFlight)
        XCTAssertEqual(ghost.turnPhase, .ended)
    }

    func testPromptingOrAWaitingCardIsATurn() {
        XCTAssertTrue(Fixtures.snapshot(status: "prompting").isTurnInFlight)
        let held = Fixtures.snapshot(status: "prompting", awaitingBackground: true, nativeSteering: true)
        XCTAssertTrue(held.isTurnInFlight)
        XCTAssertEqual(held.turnPhase, .running)

        let json = """
        {"connection_id": "conn-1", "status": "connected",
         "pending_permission": {"request_id": "p1", "tool_call": {}, "options": []}}
        """
        let blocked = try! CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(json.utf8))
        XCTAssertNotNil(blocked.pendingPermission)
        XCTAssertTrue(blocked.isTurnInFlight)
        XCTAssertEqual(blocked.turnPhase, .running)
    }

    func testAPromptTakenButNotStartedIsStarting() {
        let snap = Fixtures.snapshot(status: "connected", pendingUserMessageID: "client-1")
        XCTAssertEqual(snap.pendingUserMessageId, "client-1")
        XCTAssertEqual(snap.turnPhase, .starting)
    }

    func testADeadConnectionIsDown() {
        XCTAssertEqual(Fixtures.snapshot(status: "disconnected").turnPhase, .connectionDown)
        XCTAssertEqual(Fixtures.snapshot(status: "error").turnPhase, .connectionDown)
    }

    func testTheSnapshotCarriesTheTurnsDeliveredMessages() {
        let snap = Fixtures.snapshot(status: "prompting", feedback: [(id: "fb-1", text: "Ship it")])
        XCTAssertEqual(snap.feedback, [FeedbackNoteSnapshot(id: "fb-1", text: "Ship it")])
        // An older server sends neither field.
        let bare = try! CodegJSON.decoder.decode(LiveSessionSnapshot.self,
                                                 from: Data(#"{"status": "connected"}"#.utf8))
        XCTAssertNil(bare.pendingUserMessageId)
        XCTAssertEqual(bare.feedback, [])
    }

    // MARK: Confirming an unclear send

    func testARecordedMessageIsFoundByItsText() {
        let notes = [FeedbackNoteSnapshot(id: "fb-1", text: "Ship it"),
                     FeedbackNoteSnapshot(id: "fb-2", text: "Also bump the version")]
        XCTAssertEqual(SendConfirmation.recordedNote(text: "  Ship it\n", in: notes, excluding: [])?.id, "fb-1")
        XCTAssertNil(SendConfirmation.recordedNote(text: "Ship it", in: notes, excluding: ["fb-1"]))
        XCTAssertNil(SendConfirmation.recordedNote(text: "Something else", in: notes, excluding: []))
        XCTAssertNil(SendConfirmation.recordedNote(text: "  ", in: notes, excluding: []))
        // The same words sent twice in a turn: the newest unclaimed one.
        let twice = notes + [FeedbackNoteSnapshot(id: "fb-3", text: "Ship it")]
        XCTAssertEqual(SendConfirmation.recordedNote(text: "Ship it", in: twice, excluding: [])?.id, "fb-3")
        XCTAssertEqual(SendConfirmation.recordedNote(text: "Ship it", in: twice, excluding: ["fb-3"])?.id, "fb-1")
    }

    func testAPromptIsConfirmedOnlyByItsOwnClientMessageID() {
        let running = Fixtures.snapshot(status: "prompting", pendingUserMessageID: "client-1")
        XCTAssertTrue(SendConfirmation.promptIsRunning(clientMessageID: "client-1", in: running))
        XCTAssertFalse(SendConfirmation.promptIsRunning(clientMessageID: "client-2", in: running))
        XCTAssertFalse(SendConfirmation.promptIsRunning(clientMessageID: "client-1",
                                                        in: Fixtures.snapshot(status: "prompting")))
        XCTAssertFalse(SendConfirmation.promptIsRunning(clientMessageID: "client-1", in: nil))
    }
}
