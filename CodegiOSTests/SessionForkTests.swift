import XCTest
@testable import Codeg

/// Fork and Fork from here, as codeg web takes them (`fork-from-turn.ts`):
/// when each is offered (the server's endpoints, what the agent reported, a
/// running turn), the request bodies, where a fork lands (in place between
/// turns, a new conversation while a turn runs or starts under the request),
/// how refusals read, and where the fork opens with Back going to the list or
/// the original.
@MainActor
final class SessionForkTests: XCTestCase {
    private var server: MockCodegServer!
    private var capabilities: ForkCapabilities!

    override func setUp() async throws {
        server = MockCodegServer()
        capabilities = ForkCapabilities()
        ForkCapabilities.shared.reset()
    }

    override func tearDown() async throws {
        ForkCapabilities.shared.reset()
        server = nil
    }

    // MARK: - Fixtures

    private func turn(_ id: String, _ role: TurnRole, _ text: String = "text", fromServer: Bool = true) -> MessageTurn {
        MessageTurn(id: id, role: role, blocks: [.text(text)], timestamp: Date(),
                    serverMillis: fromServer ? 1_760_000_000_000 : nil)
    }

    /// prompt, reply in two turns, prompt, reply.
    private var transcript: [MessageTurn] {
        [turn("turn-0", .user), turn("turn-1", .assistant), turn("turn-2", .assistant),
         turn("turn-3", .user), turn("turn-4", .assistant)]
    }

    private func summaryJSON(_ id: Int = 7, agent: String = "claude_code", status: String = "pending_review",
                             turnState: String = "null", title: String = "Topic", background: String? = nil) -> String {
        let bg = background.map { #", "background": \#($0)"# } ?? ""
        return """
        {"id": \(id), "folder_id": 1, "title": "\(title)", "agent_type": "\(agent)", "status": "\(status)",
         "external_id": "ext-\(id)", "message_count": 4, "created_at": "2026-10-14T08:00:00Z",
         "updated_at": "\(TranscriptTime.string(date: Date()))", "turn_state": \(turnState)\(bg)}
        """
    }

    private func summary(_ id: Int = 7, agent: String = "claude_code", status: String = "pending_review",
                         turnState: String = "null", background: String? = nil) throws -> ConversationSummary {
        try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(summaryJSON(
            id, agent: agent, status: status, turnState: turnState, background: background).utf8))
    }

    private func turnJSON(_ id: String, _ role: String, _ text: String) -> String {
        #"{"id": "\#(id)", "role": "\#(role)", "blocks": [{"type": "text", "text": "\#(text)"}], "timestamp": "2026-10-14T08:00:00.000Z"}"#
    }

    private func detailJSON(id: Int = 7, title: String = "Topic", turns: [String], inFlight: String? = nil) -> String {
        let inFlightJSON = inFlight.map { "\"\($0)\"" } ?? "null"
        return """
        {"summary": \(summaryJSON(id, title: title)), "turns": [\(turns.joined(separator: ", "))],
         "session_stats": null, "in_flight_user_turn_id": \(inFlightJSON)}
        """
    }

    private func snapshotJSON(status: String, forkSupported: Bool? = true) -> String {
        let fork = forkSupported.map { #", "fork_supported": \#($0)"# } ?? ""
        return #"{"connection_id": "conn-1", "conversation_id": 7, "status": "\#(status)", "event_seq": 3\#(fork)}"#
    }

    private let forkResult = #"{"forkedSessionId": "s2", "originalSessionId": "ext-7", "siblingConversationId": 8}"#
    private let newConversationResult = #"{"forkedSessionId": "s3", "originalSessionId": "ext-7", "conversationId": 9, "folderId": 1, "title": "[Fork] Topic"}"#
    private let connectionNotFound = #"{"code": "task_execution_failed", "message": "connection not found: "}"#
    private let notImplemented = #"{"code": "not_implemented", "message": "API endpoint is not available in web mode"}"#

    /// A server with both fork endpoints, a live connection `conn-1` whose
    /// snapshot reads `status`, and `acp_fork` answering an in-place fork.
    private func serveFork(status: String = "connected", forkSupported: Bool? = true) {
        let snapshot = snapshotJSON(status: status, forkSupported: forkSupported)
        let result = forkResult
        let missing = connectionNotFound
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        server.on("acp_get_session_snapshot") { _ in .body(snapshot) }
        server.on("acp_fork") { call in
            (call.body["connectionId"] as? String) == "" ? .status(500, missing) : .body(result)
        }
        server.on("acp_fork_to_new_conversation") { _ in .status(500, missing) }
    }

    private var target: ForkTarget {
        ForkTarget(conversationID: 7, folderID: 1, agentType: .claudeCode, sessionID: "ext-7", workingDir: "/w/repo")
    }

    private func forker() -> SessionForker {
        var forker = SessionForker(client: server.client, capabilities: capabilities)
        forker.pollInterval = .milliseconds(10)
        forker.readyTimeout = .seconds(3)
        return forker
    }

    /// The fork calls a test made, without the endpoint probes.
    private func forkCalls(_ path: String) -> [MockCodegServer.Call] {
        server.calls(path).filter { ($0.body["connectionId"] as? String) != "" }
    }

    // MARK: - Availability: a list row and the ⋯ menu

    func testForkSessionIsOfferedBetweenTurns() {
        XCTAssertEqual(SessionForkRules.listAvailability(
            endpoints: .available(toNewConversation: true), agent: .codex, agentForks: true,
            turnRunning: false, forking: false), .available)
        // Not checked yet: offered; the fork itself finds out.
        XCTAssertEqual(SessionForkRules.listAvailability(
            endpoints: .unknown, agent: .codex, agentForks: nil, turnRunning: false, forking: false), .available)
    }

    func testAnOlderServerGreysForkSessionOutAndSaysWhy() {
        let availability = SessionForkRules.listAvailability(
            endpoints: .missing, agent: .claudeCode, agentForks: nil, turnRunning: false, forking: false)
        XCTAssertEqual(availability, .unavailable(SessionForkRules.reasonServerTooOld))
        XCTAssertFalse(availability.isEnabled)
        XCTAssertEqual(availability.reason, "Needs a newer codeg server")
    }

    func testWhileATurnRunsOnlyAnAgentThatForksWhileRunningCanFork() {
        func running(_ agent: AgentType, _ endpoints: ForkEndpoints = .available(toNewConversation: true)) -> ForkAvailability {
            SessionForkRules.listAvailability(endpoints: endpoints, agent: agent, agentForks: true,
                                              turnRunning: true, forking: false)
        }
        XCTAssertEqual(running(.claudeCode), .available)
        XCTAssertEqual(running(.codex), .unavailable("This agent can only fork between turns"))
        XCTAssertEqual(running(.pi), .unavailable(SessionForkRules.reasonBetweenTurns))
        // A server with in-place forks only can't fork while a turn runs.
        XCTAssertEqual(running(.claudeCode, .available(toNewConversation: false)),
                       .unavailable(SessionForkRules.reasonBetweenTurns))
        XCTAssertTrue(SessionForkRules.forksWhileRunning(.claudeCode))
        XCTAssertFalse(SessionForkRules.forksWhileRunning(.codex))
    }

    func testAnAgentThatSaidItCantForkIsGreyedOut() {
        XCTAssertEqual(SessionForkRules.listAvailability(
            endpoints: .available(toNewConversation: true), agent: .cline, agentForks: false,
            turnRunning: false, forking: false), .unavailable("Cline can’t fork sessions"))
    }

    func testAForkUnderWayShowsAsForking() {
        let availability = SessionForkRules.listAvailability(
            endpoints: .available(toNewConversation: true), agent: .claudeCode, agentForks: true,
            turnRunning: false, forking: true)
        XCTAssertEqual(availability, .forking)
        XCTAssertFalse(availability.isEnabled)
        XCTAssertEqual(availability.reason, "Forking…")
    }

    func testARunningTurnIsReadFromTheListSummary() throws {
        XCTAssertTrue(SessionForkRules.turnRunning(try summary(status: "in_progress", turnState: #""running""#)))
        XCTAssertFalse(SessionForkRules.turnRunning(try summary(turnState: #""interrupted""#)))
        XCTAssertFalse(SessionForkRules.turnRunning(try summary()))
        // Background tasks after the turn ended are no turn in flight; a
        // turn held open for them is.
        XCTAssertFalse(SessionForkRules.turnRunning(try summary(background: #"{"task_count": 2}"#)))
        XCTAssertTrue(SessionForkRules.turnRunning(try summary(background: #"{"task_count": 1, "held_open": true}"#)))
        // An older server without turn_state: the in-progress status.
        var old = try summary(status: "in_progress")
        old.turnStateReported = false
        old.turnState = nil
        XCTAssertTrue(SessionForkRules.turnRunning(old))
    }

    // MARK: - Availability: Fork from here on a reply

    private func reply(_ turnID: String, turns: [MessageTurn]? = nil, pendingPrompt: Bool = false,
                       endpoints: ForkEndpoints = .available(toNewConversation: true),
                       agent: AgentType = .claudeCode, running: Bool = false) -> ForkAvailability {
        SessionForkRules.replyAvailability(turnID: turnID, turns: turns ?? transcript, pendingPrompt: pendingPrompt,
                                           endpoints: endpoints, agent: agent, agentForks: true,
                                           turnRunning: running, forking: false)
    }

    func testForkFromHereIsHiddenOnAnOlderServer() {
        XCTAssertEqual(reply("turn-2", endpoints: .missing), .hidden, "the transcript looks as in 1.3.10")
        XCTAssertEqual(reply("turn-3"), .hidden, "a user turn is no fork point")
        XCTAssertEqual(reply("gone"), .hidden)
    }

    func testBetweenTurnsEveryReplyForks() {
        XCTAssertEqual(reply("turn-2"), .available)
        XCTAssertEqual(reply("turn-4"), .available)
        XCTAssertEqual(reply("turn-4", agent: .codex), .available)
    }

    func testAReplyTheServerHasNoNameForForksOnlyAtTheTail() {
        // Built on the phone and never reconciled (codeg web's `live-…` reply).
        var turns = transcript
        turns[2] = turn("turn-2", .assistant, fromServer: false)
        XCTAssertEqual(reply("turn-2", turns: turns), .unavailable(SessionForkRules.reasonNotReady))
        turns[4] = turn("turn-4", .assistant, fromServer: false)
        XCTAssertEqual(reply("turn-4", turns: turns), .available, "the tail fork lands there anyway")
    }

    func testWhileATurnRunsFinishedRepliesForkAndTheOneBeingWrittenDoesnt() {
        // The running prompt (turn-3) is in the transcript: turn-4 is its reply.
        XCTAssertEqual(reply("turn-2", running: true), .available)
        XCTAssertEqual(reply("turn-4", running: true), .unavailable(SessionForkRules.reasonInFlight))
        // Sent from this phone, the running prompt is still on the phone: every
        // reply in the transcript has finished.
        XCTAssertEqual(reply("turn-4", pendingPrompt: true, running: true), .available)
        // An agent that only forks between turns greys them all out.
        XCTAssertEqual(reply("turn-2", agent: .codex, running: true), .unavailable(SessionForkRules.reasonBetweenTurns))
    }

    func testTheForkPointIsTheLastTurnOfTheReply() {
        let nodes = TranscriptTimeline.buildPersisted(turns: transcript, pending: [], agent: .claudeCode,
                                                      suppressInFlight: false)
        let footers = nodes.compactMap { node -> String? in
            if case .footer(_, _, let forkTurnID) = node.content { return forkTurnID }
            return nil
        }
        XCTAssertEqual(footers, ["turn-2", "turn-4"], "a reply persisted as two turns forks after both")
    }

    func testTheLatestFinishedReplyPrecedesTheRunningPrompt() {
        let turns = transcript + [turn("turn-5", .user)]
        XCTAssertEqual(SessionForkRules.latestFinishedReply(in: turns, inFlightPromptID: "turn-5"), "turn-4")
        // The server matched no prompt: the last user turn stands in for it.
        XCTAssertEqual(SessionForkRules.latestFinishedReply(in: transcript, inFlightPromptID: nil), "turn-2")
        XCTAssertEqual(SessionForkRules.latestFinishedReply(in: transcript, inFlightPromptID: "turn-3"), "turn-2")
        XCTAssertNil(SessionForkRules.latestFinishedReply(in: [turn("turn-0", .user)], inFlightPromptID: nil))
    }

    // MARK: - Wire

    func testDecodesWhetherTheAgentForks() throws {
        let snap = try CodegJSON.decoder.decode(LiveSessionSnapshot.self,
                                                from: Data(snapshotJSON(status: "connected").utf8))
        XCTAssertEqual(snap.forkSupported, true)
        let older = try CodegJSON.decoder.decode(LiveSessionSnapshot.self,
                                                 from: Data(snapshotJSON(status: "connected", forkSupported: nil).utf8))
        XCTAssertNil(older.forkSupported)
        let event = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(
            #"{"seq": 4, "connection_id": "conn-1", "type": "fork_supported", "supported": false}"#.utf8))
        XCTAssertEqual(event.event, .forkSupported(false))
    }

    func testDecodesBothForkResults() throws {
        let inPlace = try CodegJSON.decoder.decode(ForkResult.self, from: Data(forkResult.utf8))
        XCTAssertEqual(inPlace.siblingConversationId, 8)
        let new = try CodegJSON.decoder.decode(ForkToNewConversationResult.self, from: Data(newConversationResult.utf8))
        XCTAssertEqual(new.conversationId, 9)
        XCTAssertEqual(new.title, "[Fork] Topic")
    }

    // MARK: - Request bodies

    func testForkSendsTheConnectionTheRowAndTheReply() async throws {
        let result = forkResult
        server.on("acp_fork") { _ in .body(result) }
        _ = try await server.client.fork(connectionId: "conn-1", conversationId: 7, folderId: 1, forkFromTurnId: "turn-2")
        _ = try await server.client.fork(connectionId: "conn-1", conversationId: 7, folderId: 1, forkFromTurnId: nil)
        let calls = server.calls("acp_fork")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].body["connectionId"] as? String, "conn-1")
        XCTAssertEqual(calls[0].body["conversationId"] as? Int, 7)
        XCTAssertEqual(calls[0].body["folderId"] as? Int, 1)
        XCTAssertEqual(calls[0].body["forkFromTurnId"] as? String, "turn-2")
        XCTAssertNil(calls[0].body["mode"], "the server's default: a plain branch")
        XCTAssertNil(calls[1].body["forkFromTurnId"], "no turn: a fork at the tail")
    }

    func testForkToANewConversationSendsTheFinishedReply() async throws {
        let result = newConversationResult
        server.on("acp_fork_to_new_conversation") { _ in .body(result) }
        let new = try await server.client.forkToNewConversation(connectionId: "conn-1", conversationId: 7,
                                                                forkFromTurnId: "turn-2")
        XCTAssertEqual(new.conversationId, 9)
        let body = try XCTUnwrap(server.calls("acp_fork_to_new_conversation").first?.body)
        XCTAssertEqual(body["connectionId"] as? String, "conn-1")
        XCTAssertEqual(body["conversationId"] as? Int, 7)
        XCTAssertEqual(body["forkFromTurnId"] as? String, "turn-2")
    }

    func testTheEndpointCheckTellsAnOlderServerApart() async throws {
        let missing = notImplemented
        let gone = connectionNotFound
        server.on("acp_fork") { _ in .status(501, missing) }
        server.on("acp_fork_to_new_conversation") { _ in .status(501, missing) }
        let older = try await server.client.forkEndpoints()
        XCTAssertEqual(older, .missing)
        XCTAssertEqual(server.calls("acp_fork").first?.body["connectionId"] as? String, "",
                       "asked about a connection that can’t exist")

        server.on("acp_fork") { _ in .status(500, gone) }
        let inPlaceOnly = try await server.client.forkEndpoints()
        XCTAssertEqual(inPlaceOnly, .available(toNewConversation: false))

        server.on("acp_fork_to_new_conversation") { _ in .status(500, gone) }
        let both = try await server.client.forkEndpoints()
        XCTAssertEqual(both, .available(toNewConversation: true))

        server.on("acp_fork") { _ in .fail(.notConnectedToInternet) }
        do {
            _ = try await server.client.forkEndpoints()
            XCTFail("an unreachable server is not an older one")
        } catch {}
        let checked = await capabilities.probeIfNeeded(client: server.client)
        XCTAssertEqual(checked, .unknown, "tried again later")
    }

    // MARK: - Where the fork lands, and refusals

    func testBetweenTurnsTheForkIsInPlace() async throws {
        serveFork()
        let outcome = try await forker().fork(target, at: .reply("turn-2"))
        XCTAssertEqual(outcome, .inPlace(try CodegJSON.decoder.decode(ForkResult.self, from: Data(forkResult.utf8)),
                                         conversationID: 7))
        XCTAssertEqual(outcome.forkConversationID, 7, "this row moved to the fork")
        XCTAssertEqual(outcome.originalConversationID, 8, "the sibling keeps the original")
        XCTAssertEqual(forkCalls("acp_fork").first?.body["forkFromTurnId"] as? String, "turn-2")
        XCTAssertTrue(forkCalls("acp_fork_to_new_conversation").isEmpty)
        XCTAssertEqual(capabilities.agentForks(.claudeCode, client: server.client), true)
    }

    func testForkSessionBetweenTurnsForksTheWholeSession() async throws {
        serveFork()
        _ = try await forker().fork(target, at: .latest)
        let body = try XCTUnwrap(forkCalls("acp_fork").first?.body)
        XCTAssertNil(body["forkFromTurnId"], "at the tail: a duplicate that continues on its own")
        XCTAssertEqual(body["conversationId"] as? Int, 7, "links a resumed connection to its row")
        XCTAssertEqual(body["folderId"] as? Int, 1)
    }

    func testWithNoLiveConnectionTheSessionIsResumed() async throws {
        serveFork()
        server.on("acp_find_connection_for_conversation") { _ in .body("null") }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        var snapshots = [snapshotJSON(status: "connecting"), snapshotJSON(status: "connected")]
        server.on("acp_get_session_snapshot") { _ in .body(snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]) }
        var used: String?
        _ = try await forker().fork(target, at: .reply("turn-2"), onConnection: { used = $0 })
        let connect = try XCTUnwrap(server.calls("acp_connect").first?.body)
        XCTAssertEqual(connect["sessionId"] as? String, "ext-7")
        XCTAssertEqual(connect["workingDir"] as? String, "/w/repo")
        XCTAssertEqual(connect["agentType"] as? String, "claude_code")
        XCTAssertEqual(used, "conn-1")
        XCTAssertEqual(server.calls("acp_get_session_snapshot").count, 2, "waited for it to come up")
        XCTAssertEqual(forkCalls("acp_fork").count, 1)
    }

    func testATurnThatStartedUnderTheForkForksIntoANewConversation() async throws {
        serveFork()
        let result = newConversationResult
        server.on("acp_fork") { call in
            (call.body["connectionId"] as? String) == ""
                ? .status(500, #"{"message": "connection not found: "}"#)
                : .status(409, #"{"code": "turn_in_progress", "message": "turn already in progress for this connection"}"#)
        }
        server.on("acp_fork_to_new_conversation") { call in
            (call.body["connectionId"] as? String) == "" ? .status(500, #"{"message": "connection not found: "}"#) : .body(result)
        }
        let outcome = try await forker().fork(target, at: .reply("turn-2"))
        XCTAssertEqual(outcome.forkConversationID, 9)
        XCTAssertEqual(outcome.originalConversationID, 7, "the original is untouched")
        XCTAssertFalse(outcome.isInPlace)
        XCTAssertEqual(forkCalls("acp_fork_to_new_conversation").first?.body["forkFromTurnId"] as? String, "turn-2")
    }

    func testWhileATurnRunsAnAgentThatOnlyForksBetweenTurnsIsTold() async throws {
        serveFork(status: "prompting")
        let codex = ForkTarget(conversationID: 7, folderID: 1, agentType: .codex, sessionID: "ext-7", workingDir: nil)
        do {
            _ = try await forker().fork(codex, at: .reply("turn-2"))
            XCTFail("no fork")
        } catch let error as ForkError {
            XCTAssertEqual(error, .betweenTurnsOnly)
            XCTAssertEqual(error.errorDescription, "Can’t fork yet: this agent can only fork between turns")
        }
        XCTAssertTrue(forkCalls("acp_fork").isEmpty)
        XCTAssertTrue(forkCalls("acp_fork_to_new_conversation").isEmpty)
    }

    func testTheServerSayingOnlyBetweenTurnsReadsTheSame() async throws {
        serveFork(status: "prompting")
        server.on("acp_fork_to_new_conversation") { call in
            (call.body["connectionId"] as? String) == ""
                ? .status(500, #"{"message": "connection not found: "}"#)
                : .status(400, #"{"code": "invalid_input", "message": "this agent can only fork between turns"}"#)
        }
        do {
            _ = try await forker().fork(target, at: .reply("turn-2"))
            XCTFail("no fork")
        } catch let error as ForkError {
            XCTAssertEqual(error, .betweenTurnsOnly)
        }
    }

    func testForkSessionWhileATurnRunsForksTheLatestFinishedReply() async throws {
        serveFork(status: "prompting")
        let detail = detailJSON(turns: [turnJSON("turn-0", "user", "one?"), turnJSON("turn-1", "assistant", "ONE"),
                                        turnJSON("turn-2", "user", "count"), turnJSON("turn-3", "assistant", "1 2 3")],
                                inFlight: "turn-2")
        let result = newConversationResult
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_fork_to_new_conversation") { call in
            (call.body["connectionId"] as? String) == "" ? .status(500, #"{"message": "connection not found: "}"#) : .body(result)
        }
        let outcome = try await forker().fork(target, at: .latest)
        XCTAssertEqual(outcome.forkConversationID, 9)
        XCTAssertEqual(forkCalls("acp_fork_to_new_conversation").first?.body["forkFromTurnId"] as? String, "turn-1",
                       "the reply before the running prompt, not the one being written")
        XCTAssertTrue(forkCalls("acp_fork").isEmpty)
    }

    func testAnAgentThatCantForkIsToldAndRemembered() async throws {
        serveFork(forkSupported: false)
        do {
            _ = try await forker().fork(target, at: .latest)
            XCTFail("no fork")
        } catch let error as ForkError {
            XCTAssertEqual(error, .agentCannotFork("Claude Code"))
        }
        XCTAssertEqual(capabilities.agentForks(.claudeCode, client: server.client), false)
        XCTAssertTrue(forkCalls("acp_fork").isEmpty)
    }

    func testAnOlderServerIsToldBeforeAnyAgentIsStarted() async throws {
        let missing = notImplemented
        server.on("acp_fork") { _ in .status(501, missing) }
        server.on("acp_fork_to_new_conversation") { _ in .status(501, missing) }
        do {
            _ = try await forker().fork(target, at: .latest)
            XCTFail("no fork")
        } catch let error as ForkError {
            XCTAssertEqual(error, .serverTooOld)
        }
        XCTAssertTrue(server.calls("acp_find_connection_for_conversation").isEmpty)
        XCTAssertTrue(server.calls("acp_connect").isEmpty)
        XCTAssertEqual(capabilities.endpoints(for: server.client), .missing)
    }

    func testOtherRefusalsSayWhatTheServerSaid() async throws {
        serveFork()
        server.on("acp_fork") { call in
            (call.body["connectionId"] as? String) == ""
                ? .status(500, #"{"message": "connection not found: "}"#)
                : .status(400, #"{"code": "invalid_input", "message": "the agent cannot fork at this reply"}"#)
        }
        do {
            _ = try await forker().fork(target, at: .reply("turn-2"))
            XCTFail("no fork")
        } catch let error as ForkError {
            XCTAssertEqual(error.errorDescription, "Failed to fork session: the agent cannot fork at this reply")
        }
    }

    // MARK: - Opening the fork

    private func makeApp(compact: Bool = true) -> (AppModel, String) {
        let suite = "fork-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        defaults.set(try! JSONEncoder().encode([profile]), forKey: ServerStore.storageKey)
        let store = ServerStore(defaults: defaults)
        let mock = server!
        store.clientFactory = { _ in mock.client }
        let app = AppModel(serverStore: store, defaults: defaults, transcriptCache: nil)
        app.setLayout(compact: compact, initial: true)
        return (app, suite)
    }

    private var inPlace: ForkOutcome {
        .inPlace(ForkResult(forkedSessionId: "s2", originalSessionId: "ext-7", siblingConversationId: 8),
                 conversationID: 7)
    }

    private var intoNew: ForkOutcome {
        .newConversation(ForkToNewConversationResult(forkedSessionId: "s3", originalSessionId: "ext-7",
                                                     conversationId: 9, folderId: 1, title: "[Fork] Topic"),
                         originalID: 7)
    }

    func testAForkFromActivityOpensOnTopOfActivity() {
        let (app, suite) = makeApp()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        app.selectedTab = .activity
        app.openFork(intoNew, from: .list)
        XCTAssertEqual(app.paths[.activity], [.conversation(9)], "Back returns to Activity")
        XCTAssertEqual(app.markedConversationID, 9)
    }

    func testAnInPlaceForkFromTheSessionPutsTheOriginalUnderIt() {
        let (app, suite) = makeApp()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        app.selectedTab = .chats
        app.paths[.chats] = [.sessionGroup(.folder(1)), .conversation(7)]
        app.openFork(inPlace, from: .session(7))
        XCTAssertEqual(app.paths[.chats], [.sessionGroup(.folder(1)), .conversation(8), .conversation(7)],
                       "row 7 is the fork now; Back goes to the original in row 8, then to the folder")
    }

    func testAForkIntoANewConversationGoesOnTopOfTheOriginal() {
        let (app, suite) = makeApp()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        app.selectedTab = .activity
        app.paths[.activity] = [.conversation(7)]
        app.openFork(intoNew, from: .session(7))
        XCTAssertEqual(app.paths[.activity], [.conversation(7), .conversation(9)])
    }

    func testOnIPadTheForkFillsTheDetailColumn() {
        let (app, suite) = makeApp(compact: false)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        app.selectedConversationID = 7
        app.openFork(intoNew, from: .session(7))
        XCTAssertEqual(app.selectedConversationID, 9)
        app.openFork(inPlace, from: .list)
        XCTAssertEqual(app.selectedConversationID, 7, "after an in-place fork row 7 is the fork")
    }

    func testForkFromAnActivityRowOpensTheForkAndRefreshesTheLists() async throws {
        ForkCapabilities.shared.reset()
        let (app, suite) = makeApp()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        serveFork()
        let list = "[" + summaryJSON(7) + ", " + summaryJSON(8) + "]"
        server.on("list_all_conversations") { _ in .body(list) }
        server.on("list_open_folder_details") { _ in .body("[]") }
        server.on("list_conversation_attention") { _ in .body("[]") }
        app.selectedTab = .activity
        let row = try summary(7)
        XCTAssertEqual(app.actions.forkAvailability(for: row), .available)

        app.actions.fork(row)
        XCTAssertEqual(app.actions.forkAvailability(for: row), .forking)
        let opened = await eventually { app.paths[.activity] == [.conversation(7)] }
        XCTAssertTrue(opened, "the fork (row 7, in place) opens on top of Activity")
        XCTAssertTrue(app.actions.forking.isEmpty)
        XCTAssertNil(app.actions.alert)
        XCTAssertFalse(server.calls("list_all_conversations").isEmpty, "the lists show both rows at once")
        XCTAssertNil(forkCalls("acp_fork").first?.body["forkFromTurnId"])
    }

    func testAFailedForkFromARowSaysWhy() async throws {
        let (app, suite) = makeApp()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        serveFork(status: "prompting")
        app.selectedTab = .activity
        app.actions.fork(try summary(7, agent: "codex"))
        let alerted = await eventually { app.actions.alert != nil }
        XCTAssertTrue(alerted)
        XCTAssertEqual(app.actions.alert?.message, "Can’t fork yet: this agent can only fork between turns")
        XCTAssertEqual(app.paths[.activity] ?? [], [], "nothing opened")
    }

    // MARK: - The session after an in-place fork

    func testAnInPlaceForkReloadsTheSessionAsTheFork() async throws {
        let before = detailJSON(turns: [turnJSON("turn-0", "user", "one?"), turnJSON("turn-1", "assistant", "ONE"),
                                        turnJSON("turn-2", "user", "two?"), turnJSON("turn-3", "assistant", "TWO")])
        let after = detailJSON(title: "[Fork] Topic",
                               turns: [turnJSON("turn-0", "user", "one?"), turnJSON("turn-1", "assistant", "ONE")])
        var detail = before
        server.on("get_folder_conversation") { _ in .body(detail) }
        let model = SessionDetailViewModel(client: server.client, conversationID: 7) { _ in
            ScriptedStream(.attach(Fixtures.snapshot(status: "connected")))
        }
        defer { model.teardown() }
        await model.load()
        XCTAssertEqual(model.turns.count, 4)

        detail = after
        await model.reloadAfterInPlaceFork(connectionID: "conn-1")
        XCTAssertEqual(model.turns.map(\.id), ["turn-0", "turn-1"], "the fork's shorter history replaces the original's")
        XCTAssertEqual(model.summary?.title, "[Fork] Topic")
        XCTAssertEqual(model.phase, .loaded)
    }
}
