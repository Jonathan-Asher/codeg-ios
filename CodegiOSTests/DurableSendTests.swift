import XCTest
@testable import Codeg

/// A message the user sent is never lost before the server has it: a failed
/// send waits in the queue as "Not sent" (never back in the message bar), goes
/// again by itself under the same client id once the server answers, is not
/// delivered twice when the server already had it, and outlives the screen
/// and the app on disk.
@MainActor
final class DurableSendTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []

    override func setUp() async throws {
        server = MockCodegServer()
        OutboxStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
        if let root = OutboxStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        OutboxStore.rootOverride = nil
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

    private func promptIDs() -> [String] {
        server.calls("acp_prompt").compactMap { $0.body["clientMessageId"] as? String }
    }

    func testAMessageThatFailsWhileTheNextIsBeingWrittenKeepsBoth() async {
        server.on("acp_prompt") { _ in .fail(.notConnectedToInternet) }
        server.on("acp_get_session_snapshot") { _ in .fail(.notConnectedToInternet) }
        let model = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))

        model.draft = "First"
        model.sendFromComposer()
        model.draft = "Second, still typing"

        let kept = await eventually { model.queuedMessages.first?.text == "First" }
        XCTAssertTrue(kept, "the failed message waits in the queue")
        XCTAssertEqual(model.draft, "Second, still typing", "and what is being written is left alone")
        XCTAssertEqual(model.queuedMessages.first?.failure?.label, "Connection lost — will resend")
    }

    func testANotSentMessageGoesAgainByItselfUnderTheSameID() async {
        let attempts = Counter()
        server.on("acp_prompt") { _ in attempts.next() == 1 ? .fail(.networkConnectionLost) : .body("null") }
        server.on("acp_get_session_snapshot") { _ in .fail(.networkConnectionLost) }
        let model = await openIdleSession(StreamFactory([
            .attach(Fixtures.snapshot(status: "connected")),
            .attach(Fixtures.snapshot(status: "connected")),
        ]))

        model.draft = "Run the tests"
        model.sendFromComposer()

        let resent = await eventually(timeout: 10) { self.server.calls("acp_prompt").count == 2 }
        XCTAssertTrue(resent, "sent again once the server answers")
        let ids = promptIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "the same message, so the server can tell it is a repeat")
        let settled = await eventually { model.queuedMessages.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.draft, "")
    }

    func testAResendTheServerAlreadyHadIsNotDeliveredTwice() async {
        // The first attempt reached the server but its answer was lost, and
        // the server could not be asked about it: the resend is answered as a
        // duplicate.
        let attempts = Counter()
        server.on("acp_prompt") { _ in
            attempts.next() == 1 ? .fail(.timedOut) : .body(#"{"duplicate": true}"#)
        }
        server.on("acp_get_session_snapshot") { _ in .fail(.timedOut) }
        let model = await openIdleSession(StreamFactory([
            .attach(Fixtures.snapshot(status: "connected")),
            .attach(Fixtures.snapshot(status: "connected")),
            .attach(Fixtures.snapshot(status: "connected")),
        ]))

        model.draft = "Deploy it"
        model.sendFromComposer()

        let answered = await eventually(timeout: 10) { self.server.calls("acp_prompt").count == 2 }
        XCTAssertTrue(answered)
        let ids = promptIDs()
        XCTAssertEqual(ids.first, ids.last)
        let settled = await eventually { model.queuedMessages.isEmpty && !model.isInFlight }
        XCTAssertTrue(settled, "taken as delivered: nothing left to send, nothing shown as running")
        XCTAssertTrue(model.pendingUserTurns.isEmpty, "no second copy of the message on screen")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.calls("acp_prompt").count, 2, "and never sent a third time")
    }

    func testARefusedMessageWaitsForSendNow() async {
        server.on("acp_prompt") { _ in .status(413, #"{"code": "invalid_input", "message": "too large"}"#) }
        let model = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))

        model.draft = "A very large message"
        model.sendFromComposer()

        let kept = await eventually { model.queuedMessages.first?.failure != nil }
        XCTAssertTrue(kept)
        XCTAssertEqual(model.queuedMessages.first?.failure?.autoRetry, false)
        XCTAssertNotNil(model.notice, "a refusal is said, not only marked")
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(server.calls("acp_prompt").count, 1, "not sent into the same refusal again")
    }

    func testUnsentMessagesComeBackWhenTheSessionOpensAgain() async {
        server.on("acp_prompt") { _ in .status(413, #"{"code": "invalid_input", "message": "too large"}"#) }
        let first = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))
        first.draft = "Keep me"
        first.sendFromComposer()
        let kept = await eventually { first.queuedMessages.first?.failure != nil }
        XCTAssertTrue(kept)
        let id = first.queuedMessages.first?.clientMessageID
        first.teardown()

        // The app went away; the session opens again.
        let again = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))
        XCTAssertEqual(again.queuedMessages.map(\.text), ["Keep me"])
        XCTAssertEqual(again.queuedMessages.first?.clientMessageID, id)
        XCTAssertEqual(again.queuedMessages.first?.failure?.reason, .rejected)
    }

    func testAMessageOnItsWayWhenTheScreenClosedComesBackToBeSentAgain() async {
        server.on("acp_prompt") { _ in .fail(.cancelled) }
        let first = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))
        first.draft = "Halfway there"
        first.sendFromComposer()
        // The screen closes before the server answered.
        first.teardown()

        server.on("acp_prompt") { _ in .body("null") }
        let again = await openIdleSession(StreamFactory([
            .attach(Fixtures.snapshot(status: "connected")),
            .attach(Fixtures.snapshot(status: "connected")),
        ]))
        let resent = await eventually(timeout: 10) {
            self.server.calls("acp_prompt").contains { $0.body["clientMessageId"] as? String != nil }
                && again.queuedMessages.isEmpty
        }
        XCTAssertTrue(resent, "it goes again by itself")
        let texts = server.calls("acp_prompt").compactMap {
            (($0.body["blocks"] as? [[String: Any]])?.first?["text"]) as? String
        }
        XCTAssertTrue(texts.allSatisfy { $0 == "Halfway there" })
        let ids = Set(promptIDs())
        XCTAssertEqual(ids.count, 1, "every attempt under the one id")
    }

    func testFailureReasons() {
        XCTAssertEqual(SendFailure.classify(APIError.transport("The request timed out.")), .timeout)
        XCTAssertEqual(SendFailure.classify(APIError.transport("The network connection was lost.")), .network)
        XCTAssertEqual(SendFailure.classify(APIError.server(status: 503, code: nil, message: "restarting")), .server)
        XCTAssertEqual(SendFailure.classify(APIError.server(status: 500, code: "task_execution_failed",
                                                            message: "connection not found: c1")), .connection)
        XCTAssertEqual(SendFailure.classify(APIError.server(status: 413, code: nil, message: "too large")), .rejected)
        XCTAssertEqual(SendFailure.classify(APIError.unauthorized), .unauthorized)

        var failure = SendFailure.next(after: APIError.server(status: 500, code: nil, message: "boom"), previous: nil)
        XCTAssertTrue(failure.autoRetry)
        for _ in 1..<SendFailure.maxUnexpectedAttempts {
            failure = SendFailure.next(after: APIError.server(status: 500, code: nil, message: "boom"),
                                       previous: failure)
        }
        XCTAssertFalse(failure.autoRetry, "an unexpected error is tried a few times, then waits")
        var lost = SendFailure.next(after: APIError.transport("offline"), previous: nil)
        for _ in 0..<20 { lost = SendFailure.next(after: APIError.transport("offline"), previous: lost) }
        XCTAssertTrue(lost.autoRetry, "a lost connection is waited out")
        XCTAssertEqual(lost.retryDelay, 30)
    }

    func testTheOutboxRestoresWhatWasOnItsWayFirst() {
        let queued = OutboxMessage(clientMessageID: "q", text: "queued", images: [], holdUntilTurnEnd: true,
                                   failure: nil)
        let flying = OutboxMessage(clientMessageID: "f", text: "flying", images: [], holdUntilTurnEnd: true,
                                   failure: nil)
        let contents = OutboxStore.Contents(queue: [queued], inflight: [flying])
        OutboxStore.save(contents, serverKey: "s", conversationID: 1)
        let loaded = OutboxStore.load(serverKey: "s", conversationID: 1)
        XCTAssertEqual(loaded, contents)
        let restored = loaded?.restoredQueue ?? []
        XCTAssertEqual(restored.map(\.text), ["flying", "queued"])
        XCTAssertEqual(restored.first?.failure, .interrupted)
        XCTAssertEqual(restored.first?.holdUntilTurnEnd, false)
        OutboxStore.save(OutboxStore.Contents(), serverKey: "s", conversationID: 1)
        XCTAssertNil(OutboxStore.load(serverKey: "s", conversationID: 1))
    }
}

/// A thread-safe attempt counter for mock routes.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
