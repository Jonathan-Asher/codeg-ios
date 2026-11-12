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
        // codeg's limit-continue now resumes stopped sub-agents first; the
        // earlier wording still reads as the same divider in older transcripts.
        XCTAssertEqual(ContinuePrompt.variant(ofText: "Your usage limit has reset. First resume any sub-agents the limit stopped, each from where it stopped with its context intact rather than starting it over; then continue the task you were working on when the usage limit was reached. Do not repeat work that is already complete."), .limit)
        XCTAssertEqual(ContinuePrompt.variant(ofText: "Your usage limit has reset. Continue the task you were working on when the usage limit was reached; do not repeat work that is already complete.\n"), .limit)
        XCTAssertNil(ContinuePrompt.variant(ofText: "Your usage limit has reset."))

        let plain = MessageTurn(id: "u1", role: .user, blocks: [.text("continue")], timestamp: Date())
        XCTAssertEqual(ContinuePrompt.variant(of: plain), .continued)
        let withImage = MessageTurn(id: "u2", role: .user,
                                    blocks: [.text("continue"), .image(ImageData(data: "", mimeType: "image/png", uri: nil))],
                                    timestamp: Date())
        XCTAssertNil(ContinuePrompt.variant(of: withImage))
        let assistant = MessageTurn(id: "a1", role: .assistant, blocks: [.text("continue")], timestamp: Date())
        XCTAssertNil(ContinuePrompt.variant(of: assistant))
    }

    // MARK: - Resume after restart (codeg `lib/auto-resume.ts`)

    /// The background prompt as the server words it (`resume_prompt`).
    private var backgroundResume: String {
        [ContinuePrompt.resumeBackgroundHead,
         "- sub-agent: Review the parser (started 13:02)",
         "- background shell: sleep 900",
         ContinuePrompt.resumeBackgroundTail].joined(separator: "\n")
    }

    /// A cut-off turn that also had background work running.
    private var turnResumeWithList: String {
        ContinuePrompt.resumeAfterRestart + "\n\n" + ContinuePrompt.resumeTurnBackgroundHeader
            + "\n- monitor: main run: errors"
    }

    func testBothResumePromptsMatchByHowTheyStart() {
        XCTAssertEqual(ContinuePrompt.divider(ofText: ContinuePrompt.resumeAfterRestart),
                       ContinuePrompt.Divider(variant: .resumed))
        XCTAssertEqual(ContinuePrompt.variant(ofText: "  " + ContinuePrompt.resumeAfterRestart + "\n"), .resumed)
        XCTAssertEqual(ContinuePrompt.divider(ofText: turnResumeWithList),
                       ContinuePrompt.Divider(variant: .resumed, stopped: ["monitor: main run: errors"]))
        XCTAssertEqual(ContinuePrompt.divider(ofText: backgroundResume),
                       ContinuePrompt.Divider(variant: .resumedBackground,
                                              stopped: ["sub-agent: Review the parser (started 13:02)",
                                                        "background shell: sleep 900"]))
        // The hints the server adds after the list, and the line for work it
        // couldn't name, are as it wrote them: hints aren't items.
        let withHints = backgroundResume
            + "\n\nA codeg delegation continues under its task_id with resume_delegation; get_delegation_status reports it as interrupted until then."
        XCTAssertEqual(ContinuePrompt.divider(ofText: withHints)?.stopped.count, 2)
        let unnamed = ContinuePrompt.resumeBackgroundHead + "\n- background work codeg could not name\n"
            + ContinuePrompt.resumeBackgroundTail
        XCTAssertEqual(ContinuePrompt.divider(ofText: unnamed)?.stopped, ["background work codeg could not name"])
        let more = ContinuePrompt.resumeAfterRestart + "\n\n" + ContinuePrompt.resumeTurnBackgroundHeader
            + "\n- background shell: npm test\n- and 3 more background tasks"
        XCTAssertEqual(ContinuePrompt.divider(ofText: more)?.stopped, ["background shell: npm test", "and 3 more background tasks"])
        // The other dividers carry no list.
        XCTAssertEqual(ContinuePrompt.divider(ofText: "continue"), ContinuePrompt.Divider(variant: .continued))
        XCTAssertEqual(ContinuePrompt.divider(ofText: ContinuePrompt.limitContinue)?.stopped, [])
        XCTAssertEqual(ContinuePrompt.Variant.resumedBackground.label,
                       "Resumed after restart · background work was stopped")
    }

    func testAMessageAroundAResumePromptStaysAMessage() {
        XCTAssertNil(ContinuePrompt.divider(ofText: ContinuePrompt.resumeAfterRestart + " Also run the tests."))
        XCTAssertNil(ContinuePrompt.divider(ofText: ContinuePrompt.resumeAfterRestart + "\n\nAnd the docs."))
        XCTAssertNil(ContinuePrompt.divider(ofText: "Note this: " + ContinuePrompt.resumeAfterRestart))
        XCTAssertNil(ContinuePrompt.divider(ofText: "Why did you say “" + backgroundResume + "”?"))
        // The head alone, with no list, is not what the server sends.
        XCTAssertNil(ContinuePrompt.divider(ofText: ContinuePrompt.resumeBackgroundHead))
        XCTAssertNil(ContinuePrompt.divider(ofText: ContinuePrompt.resumeTurnBackgroundHeader + "\n- monitor: x"))
        // A message that only lists like one is a message.
        XCTAssertNil(ContinuePrompt.divider(ofText: "- sub-agent: Review the parser"))
    }

    func testAResumeTurnIsADividerOnlyAsText() {
        let resume = MessageTurn(id: "u1", role: .user, blocks: [.text(backgroundResume)], timestamp: Date())
        XCTAssertEqual(ContinuePrompt.divider(of: resume)?.variant, .resumedBackground)
        // Across text blocks it reads as one text, as the desktop joins them.
        let split = MessageTurn(id: "u2", role: .user,
                                blocks: [.text(ContinuePrompt.resumeBackgroundHead + "\n"),
                                         .text("- background shell: sleep 900\n" + ContinuePrompt.resumeBackgroundTail)],
                                timestamp: Date())
        XCTAssertEqual(ContinuePrompt.divider(of: split)?.stopped, ["background shell: sleep 900"])
        let withImage = MessageTurn(id: "u3", role: .user,
                                    blocks: [.text(turnResumeWithList),
                                             .image(ImageData(data: "", mimeType: "image/png", uri: nil))],
                                    timestamp: Date())
        XCTAssertNil(ContinuePrompt.divider(of: withImage))
        let assistant = MessageTurn(id: "a1", role: .assistant, blocks: [.text(backgroundResume)], timestamp: Date())
        XCTAssertNil(ContinuePrompt.divider(of: assistant))
        // A resume is never offered for editing, like any divider.
        let served = MessageTurn(id: "u4", role: .user, blocks: [.text(backgroundResume)], timestamp: Date(),
                                 serverMillis: 1_760_000_000_000)
        XCTAssertNil(MessageEditRules.target(for: "u4", in: [served], hasOlderTurns: false))
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

/// The resume dividers on the transcript's timeline.
@MainActor
final class ResumeDividerTimelineTests: XCTestCase {
    func testAResumeAfterARestartIsADividerWithWhatItStopped() {
        let prompt = [ContinuePrompt.resumeBackgroundHead,
                      "- sub-agent: Review the parser (started 13:02)",
                      "- background shell: sleep 900",
                      ContinuePrompt.resumeBackgroundTail].joined(separator: "\n")
        let resume = MessageTurn(id: "u1", role: .user, blocks: [.text(prompt)], timestamp: Date())
        let cutOff = MessageTurn(id: "u2", role: .user, blocks: [.text(ContinuePrompt.resumeAfterRestart)],
                                 timestamp: Date())
        let reply = MessageTurn(id: "a1", role: .assistant, blocks: [.text("Re-launched the parser review.")],
                                timestamp: Date())
        let later = MessageTurn(id: "a2", role: .assistant, blocks: [.text("Picked the migration back up.")],
                                timestamp: Date())
        let nodes = TranscriptTimeline.buildPersisted(turns: [resume, reply, cutOff, later], pending: [],
                                                      agent: .claudeCode, suppressInFlight: false)
        let dividers = nodes.compactMap { node -> ContinuePrompt.Divider? in
            if case .continuation(let divider) = node.content { return divider }
            return nil
        }
        XCTAssertEqual(dividers, [
            ContinuePrompt.Divider(variant: .resumedBackground,
                                   stopped: ["sub-agent: Review the parser (started 13:02)", "background shell: sleep 900"]),
            ContinuePrompt.Divider(variant: .resumed),
        ])
        XCTAssertFalse(nodes.contains { if case .user = $0.content { return true } else { return false } },
                       "neither shows as a message of the user's")
    }
}
