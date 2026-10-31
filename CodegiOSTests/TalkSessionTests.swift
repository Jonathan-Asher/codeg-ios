import XCTest
@testable import Codeg

/// Records what a session tells Talk.
@MainActor
private final class TalkObserverSpy: SessionTalkObserver {
    struct Live: Equatable {
        let turnID: String
        let text: String
        let isStreaming: Bool
    }

    private(set) var live: [Live] = []
    private(set) var ended: [(turnID: String, stopReason: String?)] = []
    private(set) var awaiting: [Bool] = []
    private(set) var background: [[MessageTurn]] = []
    private(set) var pendingChanges = 0

    func talkLiveText(turnID: String, text: String, isStreaming: Bool) {
        live.append(Live(turnID: turnID, text: text, isStreaming: isStreaming))
    }

    func talkTurnEnded(turnID: String, stopReason: String?) {
        ended.append((turnID, stopReason))
    }

    func talkAwaitingBackground(_ awaiting: Bool) {
        self.awaiting.append(awaiting)
    }

    func talkBackgroundTurns(_ turns: [MessageTurn]) {
        background.append(turns)
    }

    func talkPendingChanged() {
        pendingChanges += 1
    }
}

/// Wire frames for Talk's events.
private enum TalkWire {
    static func subAgentDelta(_ text: String, parent: String = "toolu_sub") -> EventStream.Frame {
        event(#""type": "content_delta", "text": "# + Fixtures.quoted(text) + #", "parent_tool_use_id": "# + Fixtures.quoted(parent))
    }

    static func backgroundActivity(outstanding: Int, turns: [String]) -> EventStream.Frame {
        event(#""type": "background_activity", "session_id": "s", "watermark": 1, "outstanding": \#(outstanding), "turns": ["#
              + turns.joined(separator: ", ") + "]")
    }

    static func backgroundTurn(_ id: String, _ text: String) -> String {
        #"{"id": "\#(id)", "role": "assistant", "timestamp": "2026-10-04T16:40:00.000Z", "blocks": [{"type": "text", "text": "#
            + Fixtures.quoted(text) + "}]}"
    }

    static let prompting = event(#""type": "status_changed", "status": "prompting""#)

    static let permission = event(#""type": "permission_request", "request_id": "perm-1", "tool_call": {"title": "Run the tests"}, "options": [{"option_id": "allow", "name": "Allow", "kind": "allow_once"}]"#)

    private static func event(_ fields: String) -> EventStream.Frame {
        Fixtures.event(#"{"seq": 30, "connection_id": "conn-1", "# + fields + "}")
    }
}

/// The session as Talk drives it, against a mock codeg server and scripted
/// event sockets: what is said goes as a spoken prompt or insert (never
/// touching the draft), the agent's own words reach Talk without its
/// sub-agents', background turns and cards are passed on, and Talk keeps the
/// socket attached while the session is idle.
@MainActor
final class TalkSessionTests: XCTestCase {
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

    private func openLiveSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: "running")) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory)
        await model.load()
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live, "attached to the running turn")
        return model
    }

    private func promptText(_ call: MockCodegServer.Call) -> String? {
        (call.body["blocks"] as? [[String: Any]])?.first?["text"] as? String
    }

    // MARK: - Spoken messages

    func testASpokenPromptGoesMarkedSpokenAndLeavesTheDraftAlone() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        model.draft = "half a typed thought"

        let route = await model.sendSpoken("  Run the tests  ")
        XCTAssertEqual(route, .prompt)
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let call = server.calls("acp_prompt")[0]
        XCTAssertEqual(call.body["spoken"] as? Bool, true)
        XCTAssertEqual(promptText(call), "Run the tests")
        XCTAssertEqual(model.draft, "half a typed thought", "the draft is untouched")
        XCTAssertEqual(model.pendingUserTurns.last?.spoken, true, "shown with the microphone at once")
    }

    func testATypedPromptCarriesNoSpokenField() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        model.draft = "Typed by hand"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertNil(server.calls("acp_prompt")[0].body["spoken"])
        XCTAssertEqual(model.pendingUserTurns.last?.spoken, false)
    }

    func testASpokenInsertGoesIntoTheTurnMarkedSpokenAndLeavesTheDraftAlone() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Working on it.", nativeSteering: true)),
        ])
        let model = await openLiveSession(factory)
        let socket = factory.opened[0]
        server.on("submit_session_feedback") { call in
            let text = call.body["text"] as? String ?? ""
            socket.push(Wire.feedbackSubmitted(id: "fb-1", text: text))
            return .body(Wire.note(id: "fb-1", text: text))
        }
        model.draft = "the draft stays"
        XCTAssertTrue(model.canInsertIntoTurn)

        let route = await model.sendSpoken("Stop and check the logs")
        XCTAssertEqual(route, .insert)
        let call = server.calls("submit_session_feedback").first
        XCTAssertEqual(call?.body["spoken"] as? Bool, true)
        XCTAssertEqual(call?.body["text"] as? String, "Stop and check the logs")
        XCTAssertTrue(server.calls("acp_prompt").isEmpty, "the turn goes on: nothing is cancelled or prompted")
        XCTAssertEqual(model.draft, "the draft stays")
        let placed = await eventually { model.liveTurn?.steeredMessages.first?.spoken == true }
        XCTAssertTrue(placed, "the message in the reply shows the microphone")
    }

    func testASpokenInsertIntoATurnThatJustEndedGoesAsASpokenPrompt() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Almost done.", nativeSteering: true)),
        ])
        let model = await openLiveSession(factory)
        let socket = factory.opened[0]
        server.on("submit_session_feedback") { _ in
            // The turn ends just before the message gets there.
            socket.push(Wire.turnComplete)
            Thread.sleep(forTimeInterval: 0.3)
            return .status(400, #"{"code": "no_active_turn", "message": "no active turn to send feedback to"}"#)
        }

        let route = await model.sendSpoken("And update the docs")
        XCTAssertEqual(route, .prompt)
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let prompt = server.calls("acp_prompt")[0]
        XCTAssertEqual(prompt.body["spoken"] as? Bool, true)
        XCTAssertEqual(promptText(prompt), "And update the docs")
        XCTAssertEqual(prompt.body["clientMessageId"] as? String,
                       server.calls("submit_session_feedback")[0].body["clientId"] as? String,
                       "the same message, under the same id")
    }

    func testASpokenMessageWhileTheAgentRepliesWithoutSteeringIsQueuedSpoken() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "prompting", liveText: "Thinking."))])
        let model = await openLiveSession(factory)
        XCTAssertFalse(model.canInsertIntoTurn)
        let route = await model.sendSpoken("Then deploy")
        XCTAssertEqual(route, .queued)
        XCTAssertEqual(model.queuedMessages.last?.text, "Then deploy")
        XCTAssertEqual(model.queuedMessages.last?.spoken, true)
        XCTAssertTrue(server.calls("submit_session_feedback").isEmpty)
    }

    func testTheOutboxKeepsSpokenThroughAFailedSendAndTheResend() async throws {
        server.on("acp_prompt") { _ in .fail(.networkConnectionLost) }
        server.on("acp_get_session_snapshot") { _ in .body(Fixtures.snapshotJSON(status: "connected")) }
        let model = await openIdleSession(StreamFactory([.attach(Fixtures.snapshot(status: "connected"))]))

        _ = await model.sendSpoken("Ship it")
        let kept = await eventually { model.queuedMessages.first?.failure != nil }
        XCTAssertTrue(kept)
        let item = try XCTUnwrap(model.queuedMessages.first)
        XCTAssertTrue(item.spoken)
        let stored = OutboxStore.load(serverKey: OutboxStore.serverKey(baseURL: server.client.baseURL),
                                      conversationID: Fixtures.conversationID)
        XCTAssertEqual(stored?.queue.first?.spoken, true, "stored as spoken")

        server.on("acp_prompt") { _ in .body("null") }
        model.sendQueuedNow(item.id)
        let resent = await eventually { self.server.calls("acp_prompt").count == 2 }
        XCTAssertTrue(resent)
        XCTAssertEqual(server.calls("acp_prompt")[1].body["spoken"] as? Bool, true)
        XCTAssertEqual(server.calls("acp_prompt")[1].body["clientMessageId"] as? String, item.clientMessageID)
    }

    func testStoredOutboxMessagesKeepSpokenAndOlderFilesStillRead() throws {
        let spoken = OutboxMessage(clientMessageID: "a", text: "said", images: [], holdUntilTurnEnd: false,
                                   failure: nil, spoken: true)
        let data = try JSONEncoder().encode(OutboxStore.Contents(queue: [spoken], inflight: []))
        let decoded = try JSONDecoder().decode(OutboxStore.Contents.self, from: data)
        XCTAssertEqual(decoded.queue.first?.spoken, true)

        let older = #"{"queue": [{"clientMessageID": "b", "text": "typed", "images": [], "holdUntilTurnEnd": false}], "inflight": []}"#
        let read = try JSONDecoder().decode(OutboxStore.Contents.self, from: Data(older.utf8))
        XCTAssertNil(read.queue.first?.spoken)
        XCTAssertEqual(read.queue.first?.text, "typed")
    }

    // MARK: - What Talk hears

    func testTalkHearsTheAgentsOwnWordsWithoutItsSubAgents() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        let spy = TalkObserverSpy()
        model.talkObserver = spy
        _ = await model.sendSpoken("Find the bug")
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let socket = factory.opened[0]

        socket.push(Wire.delta("Looking now."))
        socket.push(TalkWire.subAgentDelta("sub-agent notes"))
        socket.push(Wire.toolCall("t1"))
        socket.push(Wire.delta("Found it."))
        let heard = await eventually { spy.live.last?.text == "Looking now.\n\nFound it." }
        XCTAssertTrue(heard)
        XCTAssertFalse(spy.live.contains { $0.text.contains("sub-agent notes") })
        XCTAssertTrue(spy.live.allSatisfy { $0.isStreaming })
        XCTAssertEqual(Set(spy.live.map(\.turnID)).count, 1, "one turn")
        XCTAssertTrue(Rendered.thread(model).contains("agent: sub-agent notes"),
                      "the conversation still shows the sub-agent's text")

        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([Wire.user(0, "Find the bug"), Wire.agent(1, Wire.text("Looking now. Found it."))]))
        }
        socket.push(Wire.turnComplete)
        let ended = await eventually { spy.ended.count == 1 }
        XCTAssertTrue(ended)
        XCTAssertEqual(spy.ended.first?.stopReason, "end_turn")
        XCTAssertEqual(spy.ended.first?.turnID, spy.live.last?.turnID)
        XCTAssertEqual(spy.live.last?.isStreaming, false, "the final text comes before the end")
    }

    func testTheMainThreadTextIsJoinedInOrderAndOnlyGrows() {
        let live = LiveTurn()
        live.appendText("Checking")
        XCTAssertEqual(live.mainThreadText, "Checking")
        live.appendText(" the build.")
        live.appendText("helper output", subAgent: "toolu_1")
        live.appendText(" Still checking")
        XCTAssertEqual(live.segments.count, 3, "the sub-agent's text runs apart")
        XCTAssertEqual(live.mainThreadText, "Checking the build. Still checking")
        live.upsertToolCall(id: "t1", title: "Bash", kind: "execute", status: "in_progress", rawInput: nil,
                            rawOutput: nil, content: nil)
        XCTAssertEqual(live.mainThreadText, "Checking the build. Still checking\n\n", "a tool ends the paragraph")
        live.upsertToolCall(id: "t2", title: "Bash", kind: "execute", status: "in_progress", rawInput: nil,
                            rawOutput: nil, content: nil)
        live.appendThinking("hmm")
        live.appendText("Passed.")
        XCTAssertEqual(live.mainThreadText, "Checking the build. Still checking\n\nPassed.")
        live.insertSteered(id: "m1", serverID: nil, text: "and lint?", blocks: [], spoken: true)
        live.appendText("Lint is clean.")
        XCTAssertEqual(live.mainThreadText, "Checking the build. Still checking\n\nPassed.\n\nLint is clean.")
        XCTAssertEqual(live.steeredMessages.first?.spoken, true)
        XCTAssertEqual(live.steeredMessages.first?.turn.spoken, true)
    }

    func testTalkHearsBackgroundTurnsAndTheBackgroundHold() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Started the build.", nativeSteering: true)),
        ])
        let model = await openLiveSession(factory)
        let spy = TalkObserverSpy()
        model.talkObserver = spy
        XCTAssertEqual(spy.live.last?.text, "Started the build.", "attaching replays the live turn")
        let socket = factory.opened[0]

        socket.push(Wire.awaitingBackground(true))
        socket.push(TalkWire.backgroundActivity(outstanding: 1, turns: [TalkWire.backgroundTurn("bg-1", "The build passed.")]))
        let heard = await eventually { spy.background.count == 1 }
        XCTAssertTrue(heard)
        XCTAssertEqual(spy.background[0].first?.id, "bg-1")
        XCTAssertEqual(spy.background[0].first?.blocks, [.text("The build passed.")])
        XCTAssertEqual(model.backgroundOutstanding, 1)
        XCTAssertEqual(spy.awaiting.last, true)
        socket.push(Wire.awaitingBackground(false))
        let resumed = await eventually { spy.awaiting.last == false }
        XCTAssertTrue(resumed)
    }

    func testTalkHearsWhenACardAppearsAndGoes() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "prompting", liveText: "Let me run it."))])
        let model = await openLiveSession(factory)
        let spy = TalkObserverSpy()
        model.talkObserver = spy
        let before = spy.pendingChanges
        factory.opened[0].push(TalkWire.permission)
        let asked = await eventually { model.pendingPermission != nil }
        XCTAssertTrue(asked)
        XCTAssertEqual(spy.pendingChanges, before + 1)
        factory.opened[0].push(Fixtures.event(#"{"seq": 31, "connection_id": "conn-1", "type": "permission_resolved", "request_id": "perm-1"}"#))
        let cleared = await eventually { model.pendingPermission == nil }
        XCTAssertTrue(cleared)
        XCTAssertEqual(spy.pendingChanges, before + 2)
    }

    // MARK: - The idle watch

    func testWithoutTalkTheSocketClosesWhenTheTurnEnds() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        model.draft = "Build it"
        model.sendFromComposer()
        _ = await eventually { self.server.calls("acp_prompt").count == 1 }
        let socket = factory.opened[0]
        socket.push(Wire.turnComplete)
        let closed = await eventually { socket.isClosed }
        XCTAssertTrue(closed)
    }

    func testTalkKeepsTheSocketAttachedAfterTheTurnAndFollowsWhatComesNext() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        let spy = TalkObserverSpy()
        model.talkObserver = spy
        model.keepsStreamAttached = true

        _ = await model.sendSpoken("Build it")
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let socket = factory.opened[0]
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail([Wire.user(0, "Build it"), Wire.agent(1, Wire.text("Started the build."))]))
        }
        socket.push(Wire.delta("Started the build."))
        socket.push(Wire.turnComplete)
        let ended = await eventually { spy.ended.count == 1 }
        XCTAssertTrue(ended)
        let reconciled = await eventually { model.liveTurn == nil }
        XCTAssertTrue(reconciled)
        XCTAssertFalse(socket.isClosed, "kept as the idle watch")

        // Background work finishing outside a turn reaches Talk on it.
        socket.push(TalkWire.backgroundActivity(outstanding: 0, turns: [TalkWire.backgroundTurn("bg-1", "All green.")]))
        let heard = await eventually { spy.background.last?.first?.id == "bg-1" }
        XCTAssertTrue(heard)

        // A turn starts from elsewhere: the watch asks for a fresh snapshot,
        // and the one that shows it running hands over to the reattach.
        socket.push(TalkWire.prompting)
        let asked = await eventually { socket.attachedConnections.count == 2 }
        XCTAssertTrue(asked, "attached again for a fresh snapshot")
        socket.push(.snapshot(Fixtures.snapshot(status: "prompting", liveText: "Here's what the agents found.")))
        let adopted = await eventually { model.isInFlight && spy.live.last?.text == "Here's what the agents found." }
        XCTAssertTrue(adopted)
        XCTAssertNotEqual(spy.live.last?.turnID, spy.ended.first?.turnID, "a new turn")
        XCTAssertEqual(factory.opened.count, 1, "on the same socket")

        // That turn ends too, and the socket goes back to watching.
        socket.push(Wire.turnComplete)
        let endedAgain = await eventually { spy.ended.count == 2 }
        XCTAssertTrue(endedAgain)
        XCTAssertFalse(socket.isClosed)

        // Talk ends: the idle socket closes.
        _ = await eventually { model.liveTurn == nil }
        model.keepsStreamAttached = false
        XCTAssertTrue(socket.isClosed)
    }

    func testTalkKeepsAnIdleConnectionAttachedWhenTheSessionOpens() async {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = makeModel(factory)
        model.keepsStreamAttached = true
        await model.load()
        let attached = await eventually { !factory.opened.isEmpty }
        XCTAssertTrue(attached)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(factory.opened.filter { !$0.isClosed }.count, 1, "one socket, kept open while idle")
        XCTAssertFalse(model.isInFlight)
    }

    func testTalkingRidesThePresenceReportOnlyToAServerWithTalk() {
        let withTalk = WSClientMessage.presence(visible: false, focused: false, idleSecs: 0, conversationIds: [7],
                                                talking: true)
        let without = WSClientMessage.presence(visible: true, focused: true, idleSecs: 0, conversationIds: [7])
        func json(_ message: WSClientMessage) -> [String: Any] {
            let data = try! JSONEncoder().encode(message)
            return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        XCTAssertEqual(json(withTalk)["talking"] as? Bool, true)
        XCTAssertEqual(json(withTalk)["conversation_ids"] as? [Int], [7])
        XCTAssertNil(json(without)["talking"], "an older server never sees the key")
        XCTAssertEqual(json(without)["conversation_ids"] as? [Int], [7])
    }
}

// MARK: - Presence while talking

/// A socket that keeps what the client sends.
private final class PresenceSocket: EventSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var texts: [String] = []
    private var cancelled = false

    var sent: [[String: Any]] {
        lock.withLock { texts }.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func resume() {}
    func send(text: String) { lock.withLock { texts.append(text) } }
    func receive(_ completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.withLock { receiver = completion }
    }
    func sendPing(_ pongReceived: @escaping @Sendable (Error?) -> Void) { pongReceived(nil) }
    func cancel() { lock.withLock { cancelled = true } }

    func deliver(_ text: String) {
        let next = lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            let current = receiver
            receiver = nil
            return current
        }
        next?(.success(.string(text)))
    }
}

/// The phone tells the server it is talking with a session even with the
/// screen locked, keeping its presence socket open for it, and says so only
/// to a server that took `set_conversation_talk_mode`.
@MainActor
final class TalkPresenceTests: XCTestCase {
    private let readyFrame = #"{"channel": "__ready__", "payload": null}"#

    private func reporter(_ url: URL) -> (SessionPresenceReporter, PresenceSocket) {
        let socket = PresenceSocket()
        let reporter = SessionPresenceReporter(baseURL: url, token: "t") {
            EventStream(baseURL: url, token: "t", makeSocket: { _, _ in socket }, clock: SystemLivenessClock.shared,
                        probe: { .alive })
        }
        return (reporter, socket)
    }

    func testWhileTalkingThePresenceSocketStaysOpenWithTheScreenLocked() async {
        let url = URL(string: "http://talk-\(UUID().uuidString.lowercased()).test")!
        TalkServerSupport.shared.noteAccepted(url)
        defer { TalkServerSupport.shared.noteMissing(url) }
        let (reporter, socket) = reporter(url)

        reporter.update(conversationID: 7, looking: false, talking: true)
        socket.deliver(readyFrame)
        let reported = await eventually { socket.sent.contains { $0["action"] as? String == "presence" } }
        XCTAssertTrue(reported)
        let report = socket.sent.last { $0["action"] as? String == "presence" }
        XCTAssertEqual(report?["talking"] as? Bool, true)
        XCTAssertEqual(report?["visible"] as? Bool, false)
        XCTAssertEqual(report?["conversation_ids"] as? [Int], [7], "the session it talks with")
        XCTAssertFalse(socket.isCancelled, "open with nobody looking")

        // Talk ends with the screen still locked: said, then closed.
        reporter.update(conversationID: 7, looking: false, talking: false)
        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(socket.sent.last?["talking"] as? Bool, false)
        XCTAssertEqual(socket.sent.last?["conversation_ids"] as? [Int], [])
        XCTAssertLessThanOrEqual(SessionPresenceReporter.heartbeatInterval, .seconds(30))
    }

    func testAServerWithoutTalkNeverSeesTalking() async {
        let url = URL(string: "http://old-\(UUID().uuidString.lowercased()).test")!
        let (reporter, socket) = reporter(url)
        reporter.update(conversationID: 7, looking: true, talking: true)
        socket.deliver(readyFrame)
        let reported = await eventually { socket.sent.contains { $0["action"] as? String == "presence" } }
        XCTAssertTrue(reported)
        XCTAssertTrue(socket.sent.allSatisfy { $0["talking"] == nil })
        reporter.stop()
    }

    func testTheTalkModeCallMarksTheServer() async throws {
        let server = MockCodegServer()
        server.on("set_conversation_talk_mode") { _ in .body("null") }
        try await server.client.setConversationTalkMode(conversationId: 7, enabled: true)
        XCTAssertTrue(TalkServerSupport.shared.accepts(server.client.baseURL))
        let call = try XCTUnwrap(server.calls("set_conversation_talk_mode").first)
        XCTAssertEqual(call.body["conversationId"] as? Int, 7)
        XCTAssertEqual(call.body["enabled"] as? Bool, true)

        // A conversation the server doesn't know says nothing about the server.
        server.on("set_conversation_talk_mode") { _ in
            .status(404, #"{"code": "not_found", "message": "conversation not found"}"#)
        }
        do {
            try await server.client.setConversationTalkMode(conversationId: 8, enabled: true)
            XCTFail("an unknown conversation is an error")
        } catch {
            XCTAssertFalse(TalkServerSupport.isMissingRoute(error))
        }
        XCTAssertTrue(TalkServerSupport.shared.accepts(server.client.baseURL))

        // An older server doesn't have the endpoint.
        server.on("set_conversation_talk_mode") { _ in
            .status(501, #"{"code": "not_implemented", "message": "API endpoint 'set_conversation_talk_mode' is not available in web mode"}"#)
        }
        do {
            try await server.client.setConversationTalkMode(conversationId: 7, enabled: false)
            XCTFail("an older server refuses")
        } catch {
            XCTAssertTrue(TalkServerSupport.isMissingRoute(error))
        }
        XCTAssertFalse(TalkServerSupport.shared.accepts(server.client.baseURL))
    }

    func testTalkSettingsRoundTrip() async throws {
        let server = MockCodegServer()
        server.on("get_talk_settings") { _ in .body(#"{"language": "he", "address": "masculine"}"#) }
        server.on("update_talk_settings") { call in
            let settings = call.body["settings"] as? [String: Any] ?? [:]
            return .body(#"{"language": "\#(settings["language"] as? String ?? "")", "address": "\#(settings["address"] as? String ?? "")"}"#)
        }
        let settings = try await server.client.getTalkSettings()
        XCTAssertEqual(settings, TalkSettings(language: .hebrew, address: .masculine))
        let kept = try await server.client.updateTalkSettings(TalkSettings(language: .auto, address: .feminine))
        XCTAssertEqual(kept, TalkSettings(language: .auto, address: .feminine))
        let unknown = try CodegJSON.decoder.decode(TalkSettings.self, from: Data(#"{"language": "fr", "address": "x"}"#.utf8))
        XCTAssertEqual(unknown, TalkSettings())
    }
}

// MARK: - Decoding

/// What the server says about Talk decodes, and an older server's shapes
/// still do.
final class TalkDecodingTests: XCTestCase {
    private func event(_ json: String) throws -> AcpEvent {
        try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(json.utf8)).event
    }

    func testSubAgentDeltasAndBackgroundTurnsDecode() throws {
        XCTAssertEqual(try event(#"{"seq":1,"connection_id":"c","type":"content_delta","text":"hi"}"#),
                       .contentDelta(text: "hi"))
        XCTAssertEqual(try event(#"{"seq":2,"connection_id":"c","type":"content_delta","text":"sub","parent_tool_use_id":"toolu_9"}"#),
                       .contentDelta(text: "sub", parentToolUseId: "toolu_9"))
        let activity = try event(#"""
        {"seq":3,"connection_id":"c","type":"background_activity","session_id":"s","outstanding":2,"watermark":9,
         "turns":[{"id":"bg-0-1","role":"assistant","timestamp":"2026-10-04T16:40:00.000Z","blocks":[{"type":"text","text":"Done."}]},
                  {"id":"broken"}]}
        """#)
        guard case .backgroundActivity(let outstanding, let turns) = activity else { return XCTFail("\(activity)") }
        XCTAssertEqual(outstanding, 2)
        XCTAssertEqual(turns.map(\.id), ["bg-0-1"], "a malformed turn is skipped, the rest kept")
    }

    func testTheMicMarkerDecodesAndSurvivesTheCache() throws {
        let spoken = try CodegJSON.decoder.decode(MessageTurn.self, from: Data(#"""
        {"id":"turn-3","role":"user","timestamp":"2026-10-04T16:40:00.000Z","blocks":[{"type":"text","text":"תריץ את הבדיקות"}],"spoken":true}
        """#.utf8))
        XCTAssertTrue(spoken.spoken)
        let typed = try CodegJSON.decoder.decode(MessageTurn.self, from: Data(#"""
        {"id":"turn-4","role":"user","timestamp":"2026-10-04T16:41:00.000Z","blocks":[{"type":"text","text":"typed"}]}
        """#.utf8))
        XCTAssertFalse(typed.spoken)
        let cached = try CodegJSON.decoder.decode(MessageTurn.self, from: CodegJSON.encoder.encode(spoken))
        XCTAssertTrue(cached.spoken)
        XCTAssertEqual(cached, spoken)
    }

    func testANoteSaysWhetherItWasSpoken() throws {
        let note = try CodegJSON.decoder.decode(FeedbackNoteSnapshot.self, from: Data(#"""
        {"id":"fb-1","text":"עצור","status":"delivered","spoken":true}
        """#.utf8))
        XCTAssertTrue(note.spoken)
        XCTAssertFalse(FeedbackNoteSnapshot(id: "x", text: "y").spoken)
    }

    func testTheLiveMessageKeepsSubAgentText() throws {
        let snapshot = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(#"""
        {"connection_id":"conn-1","status":"prompting","live_message":{"content":[
          {"kind":"text","text":"Mine."},{"kind":"text","text":"Theirs.","parent_tool_use_id":"toolu_2"}]}}
        """#.utf8))
        let blocks = try XCTUnwrap(snapshot.liveMessage?.content)
        guard case .text("Mine.", let none) = blocks[0], case .text("Theirs.", let parent) = blocks[1] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertNil(none)
        XCTAssertEqual(parent, "toolu_2")
    }

    func testAConversationSaysWhetherTalkIsOn() throws {
        func summary(_ extra: String) throws -> ConversationSummary {
            try CodegJSON.decoder.decode(ConversationSummary.self, from: Data("""
            {"id": 7, "folder_id": 1, "title": "t", "agent_type": "claude_code", "status": "pending_review",
             "message_count": 1, "created_at": "2026-10-04T16:00:00Z", "updated_at": "2026-10-04T16:20:00Z"\(extra)}
            """.utf8))
        }
        let on = try summary(#", "talk_mode": true"#)
        XCTAssertTrue(on.talkMode)
        XCTAssertTrue(on.talkModeReported)
        XCTAssertTrue(try summary(#", "talk_mode": "on""#).talkMode)
        XCTAssertFalse(try summary(#", "talk_mode": "ending""#).talkMode)
        let older = try summary("")
        XCTAssertFalse(older.talkMode)
        XCTAssertFalse(older.talkModeReported)
        let cached = try CodegJSON.decoder.decode(ConversationSummary.self, from: CodegJSON.encoder.encode(on))
        XCTAssertTrue(cached.talkMode)
    }
}
