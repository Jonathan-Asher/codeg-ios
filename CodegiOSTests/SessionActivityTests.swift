import XCTest
@testable import Codeg

/// `SessionActivity.derive` against the rules of codeg's
/// `deriveSessionActivity` (src/lib/session-activity.ts).
final class SessionActivityTests: XCTestCase {
    private let resetsAt = Date(timeIntervalSince1970: 2_000_000_000)

    func testAttentionOutranksEverything() {
        let inputs = SessionActivityInputs(attention: "permission", turnState: .running,
                                           connectionStatus: .prompting)
        XCTAssertEqual(SessionActivity.derive(inputs), .needsYou)
    }

    func testPromptingIsWorkingUnlessHeldForBackground() {
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(connectionStatus: .prompting)), .working)
        let held = SessionActivityInputs(connectionStatus: .prompting, awaitingBackground: true, backgroundCount: 2)
        XCTAssertEqual(SessionActivity.derive(held), .background(count: 2))
    }

    func testConnectAttemptRanksAboveTurnState() {
        var inputs = SessionActivityInputs(turnState: .interrupted)
        inputs.connection = .connecting(phase: "resuming")
        XCTAssertEqual(SessionActivity.derive(inputs), .connecting(phase: "resuming"))
        inputs.connection = .failed
        XCTAssertEqual(SessionActivity.derive(inputs), .connectFailed)
    }

    func testLimitPauseWhileWaiting() {
        let pause = LimitPause(resetsAt: resetsAt, state: .scheduled)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(limitPause: pause)), .limitPaused(pause))
        let claimed = LimitPause(resetsAt: resetsAt, state: .claimed)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(limitPause: claimed)), .limitPaused(claimed))
        // `continuing` is the continuation's own turn: not paused any more.
        let continuing = LimitPause(resetsAt: resetsAt, state: .continuing)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(limitPause: continuing)), .idle)
        // A running turn wins over a stale pause.
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .running, limitPause: pause)),
                       .working)
    }

    func testTurnStates() {
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .interrupted)), .interrupted)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .running)), .working)
        // A live idle connection is first-hand proof nothing runs.
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: .running, connectionStatus: .connected)),
                       .idle)
        XCTAssertEqual(SessionActivity.derive(SessionActivityInputs(turnState: nil)), .idle)
    }

    func testOlderServerFallsBackToStatus() {
        let old = SessionActivityInputs(turnState: nil, turnStateReported: false, status: .inProgress)
        XCTAssertEqual(SessionActivity.derive(old), .working)
        // The fork server reports turn_state: in_progress review status alone means nothing.
        let fork = SessionActivityInputs(turnState: nil, turnStateReported: true, status: .inProgress)
        XCTAssertEqual(SessionActivity.derive(fork), .idle)
    }

    func testRemainingFormat() {
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: 0), "<1m")
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: 30_000), "1m")
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: 12 * 60_000), "12m")
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: (3 * 60 + 12) * 60_000), "3h 12m")
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: 3 * 3_600_000), "3h")
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: (2 * 24 + 4) * 3_600_000), "2d 4h")
        XCTAssertEqual(LimitResetFormat.formatRemaining(ms: 2 * 24 * 3_600_000), "2d")
    }

    func testLabels() {
        XCTAssertEqual(SessionActivity.background(count: 0).label(), "Idle — background work running")
        XCTAssertEqual(SessionActivity.background(count: 1).label(), "Idle — 1 background task running")
        XCTAssertEqual(SessionActivity.background(count: 3).label(), "Idle — 3 background tasks running")
        XCTAssertEqual(SessionActivity.connecting(phase: "starting").label(agentName: "Claude Code"),
                       "Connecting… (starting Claude Code)")
        let now = resetsAt.addingTimeInterval(-(3 * 3600 + 12 * 60))
        let label = SessionActivity.limitPaused(LimitPause(resetsAt: resetsAt, state: .scheduled)).label(now: now)
        XCTAssertTrue(label.hasPrefix("Paused — limit resets at "), label)
        XCTAssertTrue(label.hasSuffix("(in 3h 12m)"), label)
    }

    func testHeldTurnRouting() {
        XCTAssertEqual(HeldTurn.route(isPrompting: false, canDeliverNow: false), .send)
        XCTAssertEqual(HeldTurn.route(isPrompting: true, canDeliverNow: false), .enqueue)
        XCTAssertEqual(HeldTurn.route(isPrompting: true, canDeliverNow: true), .deliver)
        XCTAssertTrue(HeldTurn.canDeliver(status: .prompting, awaitingBackground: true, nativeSteering: true))
        XCTAssertFalse(HeldTurn.canDeliver(status: .prompting, awaitingBackground: true, nativeSteering: false))
        XCTAssertFalse(HeldTurn.canDeliver(status: .connected, awaitingBackground: true, nativeSteering: true))
    }

    func testContinuationDividers() {
        XCTAssertEqual(ContinuePrompt.variant(ofText: "continue"), .continued)
        XCTAssertEqual(ContinuePrompt.variant(ofText: "  continue\n"), .continued)
        XCTAssertNil(ContinuePrompt.variant(ofText: "continue with the tests"))
        XCTAssertNil(ContinuePrompt.variant(ofText: "Continue"))
        XCTAssertEqual(ContinuePrompt.variant(ofText: ContinuePrompt.resumeAfterRestart), .resumed)
        XCTAssertEqual(ContinuePrompt.variant(ofText: ContinuePrompt.limitContinue), .limit)

        let plain = MessageTurn(id: "u1", role: .user, blocks: [.text("continue")], timestamp: Date())
        XCTAssertEqual(ContinuePrompt.variant(of: plain), .continued)
        let withImage = MessageTurn(id: "u2", role: .user,
                                    blocks: [.text("continue"), .image(ImageData(data: "", mimeType: "image/png", uri: nil))],
                                    timestamp: Date())
        XCTAssertNil(ContinuePrompt.variant(of: withImage))
        let assistant = MessageTurn(id: "a1", role: .assistant, blocks: [.text("continue")], timestamp: Date())
        XCTAssertNil(ContinuePrompt.variant(of: assistant))
    }

    func testEndsWithAgentReply() {
        let user = MessageTurn(id: "u", role: .user, blocks: [.text("hi")], timestamp: Date())
        let reply = MessageTurn(id: "a", role: .assistant, blocks: [.text("hello")], timestamp: Date())
        let system = MessageTurn(id: "s", role: .system, blocks: [.text("note")], timestamp: Date())
        XCTAssertTrue(ContinuePrompt.endsWithAgentReply([user, reply, system]))
        XCTAssertFalse(ContinuePrompt.endsWithAgentReply([reply, user]))
        XCTAssertFalse(ContinuePrompt.endsWithAgentReply([]))
    }

    // MARK: - Decoding the fork's summary fields

    func testSummaryDecodesForkFields() throws {
        let json = """
        [{
          "id": 42, "folder_id": 7, "title": "Fix the login bug", "agent_type": "claude_code",
          "status": "in_progress", "model": "opus", "git_branch": "main", "external_id": "abc",
          "message_count": 3, "created_at": "2026-10-02T10:00:00Z", "updated_at": "2026-10-02T11:00:00.123456Z",
          "pinned_at": null, "turn_state": "interrupted", "critical": true,
          "limit_pause": {"resets_at": "2026-10-02T22:00:00Z", "state": "scheduled", "attempts": 1},
          "limit_auto_continue": false,
          "selector_state": {"modeId": "plan", "configValues": {"model": "opus", "reasoning_effort": "high", "fast": "false"}}
        }, {
          "id": 43, "folder_id": 7, "title": null, "agent_type": "codex", "status": "completed",
          "model": null, "git_branch": null, "external_id": null, "message_count": 0,
          "created_at": "2026-10-02T10:00:00Z", "updated_at": "2026-10-02T10:00:00Z"
        }]
        """
        let data = Data(json.utf8)
        let decoded = try CodegJSON.decoder.decode([ConversationSummary].self, from: data)
        let summaries = ConversationSelectorState.patch(decoded, from: data)
        XCTAssertEqual(summaries.count, 2)

        let first = summaries[0]
        XCTAssertEqual(first.turnState, .interrupted)
        XCTAssertTrue(first.turnStateReported)
        XCTAssertTrue(first.critical)
        XCTAssertEqual(first.limitPause?.state, .scheduled)
        XCTAssertEqual(first.limitPause?.attempts, 1)
        XCTAssertFalse(first.limitAutoContinue)
        // Config ids keep their snake_case: the raw JSON is read, not the decoder's.
        XCTAssertEqual(first.selectorState?.configValues["reasoning_effort"], "high")
        XCTAssertNil(first.selectorState?.configValues["reasoningEffort"])
        XCTAssertEqual(first.selectorState?.modeId, "plan")
        XCTAssertEqual(SessionActivity.of(first), .limitPaused(first.limitPause!))

        let second = summaries[1]
        XCTAssertFalse(second.turnStateReported)
        XCTAssertNil(second.selectorState)
        XCTAssertNil(second.limitPause)
    }

    func testSnapshotDecodesLiveSignals() throws {
        let json = """
        {"type": "snapshot", "snapshot": {"connection_id": "c1", "status": "prompting",
          "awaiting_background": true, "background_outstanding": 2, "native_steering_available": true}}
        """
        let message = try CodegJSON.decoder.decode(WSServerMessage.self, from: Data(json.utf8))
        guard case .snapshot(let snap) = message else { return XCTFail("not a snapshot") }
        XCTAssertTrue(snap.awaitingBackground)
        XCTAssertEqual(snap.backgroundOutstanding, 2)
        XCTAssertTrue(snap.nativeSteeringAvailable)
    }

    func testNewEventsDecode() throws {
        func event(_ json: String) throws -> AcpEvent {
            try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(json.utf8)).event
        }
        XCTAssertEqual(try event(#"{"seq":1,"connection_id":"c","type":"attach_progress","phase":"resuming","elapsed_ms":1200}"#),
                       .attachProgress(phase: "resuming", elapsedMs: 1200))
        XCTAssertEqual(try event(#"{"seq":2,"connection_id":"c","type":"awaiting_background","awaiting":true,"native_steering":true}"#),
                       .awaitingBackground(awaiting: true, nativeSteering: true))
        XCTAssertEqual(try event(#"{"seq":3,"connection_id":"c","type":"awaiting_background","awaiting":false}"#),
                       .awaitingBackground(awaiting: false, nativeSteering: false))
        XCTAssertEqual(try event(#"{"seq":4,"connection_id":"c","type":"background_activity","session_id":"s","outstanding":3,"watermark":1}"#),
                       .backgroundActivity(outstanding: 3))
        XCTAssertEqual(try event(#"{"seq":5,"connection_id":"c","type":"something_new"}"#),
                       .unknown(type: "something_new"))
    }
}
