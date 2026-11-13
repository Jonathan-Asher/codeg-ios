import XCTest
@testable import Codeg

/// How the phone reads Pi's cards (fork.234): a sub-agent run, a background
/// job, the start of a run Pi began by itself, a notice no card claims and a
/// context compaction, from what a codeg server actually sent
/// (``PiCapturedWire``) and from shapes it never sends; which card a call
/// draws (the live one until the transcript has the end); a job's polls; and
/// where a run Pi started by itself begins in the transcript.
@MainActor
final class PiAgentCardsTests: XCTestCase {

    // MARK: - Reading the captured wire

    /// One frame's call and its `meta`, as the shared decoder reads them.
    private struct WireCall: Decodable {
        let toolCallId: String
        let title: String?
        let status: String?
        let meta: AnyJSON?
    }

    private struct WireDetail: Decodable {
        let turns: [MessageTurn]
        let inFlightUserTurnId: String?
    }

    private func call(_ json: String) throws -> WireCall {
        try CodegJSON.decoder.decode(WireCall.self, from: Data(json.utf8))
    }

    private func turns(_ json: String) throws -> [MessageTurn] {
        try CodegJSON.decoder.decode(WireDetail.self, from: Data(json.utf8)).turns
    }

    /// The `tool_cards` of a captured snapshot frame.
    private func snapshotCards(_ json: String) throws -> [ToolCardSnapshot] {
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let snapshot = try XCTUnwrap(frame["snapshot"] as? [String: Any])
        let cards = try JSONSerialization.data(withJSONObject: snapshot["tool_cards"] ?? [])
        return try CodegJSON.decoder.decode([ToolCardSnapshot].self, from: cards)
    }

    private func block(_ turns: [MessageTurn], _ turnID: String) throws -> AnyJSON? {
        let turn = try XCTUnwrap(turns.first { $0.id == turnID })
        for case .toolUse(_, _, _, let meta) in turn.blocks where meta != nil { return meta }
        return nil
    }

    // MARK: - Sub-agent runs

    func testALaunchStreamsInWithItsCard() throws {
        let launch = try call(PiCapturedWire.subagentLaunch)
        XCTAssertEqual(launch.title, "agent", "the server titles a launch the Agent card's way")
        let run = try XCTUnwrap(SubagentRun.parse(launch.meta))
        XCTAssertEqual(run.mode, "workflow")
        XCTAssertTrue(run.isAsync)
        XCTAssertEqual(run.status, .pending, "launched, not started")
        XCTAssertTrue(run.isLive)
        XCTAssertTrue(run.children.isEmpty)
        XCTAssertEqual(run.tone, .working)
    }

    func testARunningRunHasARowPerLaneWithItsCurrentTool() throws {
        let card = try call(PiCapturedWire.subagentRunning)
        let run = try XCTUnwrap(SubagentRun.parse(card.meta))
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.agent, "scout", "the agent both lanes share")
        XCTAssertEqual(run.children.map(\.key), ["task-1", "task-2"])
        XCTAssertEqual(run.children.map(\.status), [.running, .running])
        XCTAssertEqual(run.children.map(\.currentTool), ["bash", "bash"])
        XCTAssertEqual(run.notes.first?.kind, "launch", "the launch receipt is the first thing the model saw")
    }

    func testAFinishedRunCarriesItsResultTokensAndSessions() throws {
        let card = try call(PiCapturedWire.subagentFinished)
        let run = try XCTUnwrap(SubagentRun.parse(card.meta))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.tone, .done)
        XCTAssertEqual(run.durationMs, 12765)
        XCTAssertEqual(run.tokens, 3657)
        XCTAssertTrue(run.result?.hasPrefix("Workflow completed with 2 child run(s).") == true)
        XCTAssertEqual(run.children.map(\.tokens), [1291, 2366])
        XCTAssertEqual(run.children.map(\.turns), [3, 3])
        XCTAssertEqual(run.children.map(\.sessionId),
                       ["01a1d175-4b29-767c-9768-40b41c0465e9", "01a1d175-4b38-7757-9408-94622cd51dfa"])
        XCTAssertEqual(run.children.map(\.currentTool), [nil, nil], "no activity once a lane ended")
        XCTAssertEqual(PiCardValue.firstLine(run.children[1].result ?? ""),
                       "The command `sleep 9; ls ~ | wc -l` produced the result: **181**")
    }

    func testTheTranscriptHasTheSameCards() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        // The first launch failed at once: its card says why.
        let failed = try XCTUnwrap(SubagentRun.parse(try block(history, "turn-1")))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.tone, .failed)
        XCTAssertTrue(failed.error?.hasPrefix("workflow 'parallel' args contain unsupported fields: async.") == true)
        XCTAssertFalse(failed.isLive)
        // The second ran both lanes; the transcript counts every child's usage.
        let done = try XCTUnwrap(SubagentRun.parse(try block(history, "turn-2")))
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.tokens, 8777)
        XCTAssertEqual(done.children.map(\.label), ["task-1", "task-2"])
        XCTAssertEqual(done.children.map(\.status), [.completed, .completed])
        XCTAssertEqual(done.children.first?.sessionId, "01a1d175-4b29-767c-9768-40b41c0465e9")
        XCTAssertEqual(done.notes.map(\.kind), ["launch", "child", "child", "result"])
    }

    func testOddRunShapesAreNoCard() {
        XCTAssertNil(SubagentRun.parse(nil))
        XCTAssertNil(SubagentRun.parse(.object(["codeg.subagentRun": .string("running")])))
        XCTAssertNil(SubagentRun.parse(.object(["codeg.subagentRun": .object(["status": .string("exploded")])])),
                     "a status this build doesn't know")
        let run = SubagentRun.parse(.object(["codeg.subagentRun": .object([
            "status": .string("failed"),
            "children": .array([
                .object(["label": .string("no key")]),
                .object(["key": .string("k"), "status": .string("weird"), "tokens": .number(-3),
                         "exchanges": .array([.object(["answer": .string("no question")]),
                                              .object(["question": .string("Q?")])]),
                         "attention": .array([.string(""), .string("Still waiting?"), .number(1)])]),
            ]),
            "notes": .array([.object(["kind": .string("result")]), .object(["text": .string("raw")])]),
        ])]))
        XCTAssertEqual(run?.mode, "single")
        XCTAssertEqual(run?.children.count, 1, "a row needs a key")
        let row = run?.children.first
        XCTAssertNil(row?.status)
        XCTAssertNil(row?.tokens)
        XCTAssertEqual(row?.label, "k")
        XCTAssertEqual(row?.exchanges, [SubagentRunExchange(question: "Q?", answer: nil)])
        XCTAssertEqual(row?.attention, ["Still waiting?"])
        XCTAssertEqual(run?.notes, [ModelNote(kind: "notice", text: "raw")])
        XCTAssertEqual(run?.tone, .failed)
    }

    func testAHistoryRunWithoutAnOutcomeIsQuietALiveOneQueuedIsWorking() {
        func run(_ status: String, live: Bool) -> SubagentRun? {
            var card: [String: AnyJSON] = ["status": .string(status)]
            if live { card["live"] = .bool(true) }
            return SubagentRun.parse(.object(["codeg.subagentRun": .object(card)]))
        }
        XCTAssertEqual(run("pending", live: false)?.tone, .quiet, "launched; the transcript never saw the end")
        XCTAssertEqual(run("pending", live: true)?.tone, .working)
        XCTAssertEqual(run("paused", live: true)?.tone, .quiet)
        XCTAssertEqual(run("stopped", live: false)?.tone, .quiet)
    }

    // MARK: - Background jobs

    func testAJobReadsRunningThenHowItEnded() throws {
        let launch = try call(PiCapturedWire.jobLaunch)
        XCTAssertEqual(launch.title, "bgj_run")
        let running = try XCTUnwrap(BackgroundJob.parse(launch.meta))
        XCTAssertEqual(running.state, .running)
        XCTAssertTrue(running.isLive)
        XCTAssertNil(running.exitCode)

        let finished = try XCTUnwrap(BackgroundJob.parse(try call(PiCapturedWire.jobFinished).meta))
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertEqual(finished.duration, "6s")
        XCTAssertEqual(finished.id, "jb-mwdzg9r8-rist")

        // The server's card after the run that exit woke: the output tail
        // and the notice as the model read it.
        let cards = try snapshotCards(PiCapturedWire.jobSnapshot)
        XCTAssertEqual(cards.map(\.toolCallId), ["chatcmpl-tool-bb5cac9873c04aaf9d99a4941115ca02"])
        let last = try XCTUnwrap(BackgroundJob.parse(cards.first?.meta))
        XCTAssertEqual(last.tail, "bg-done")
        XCTAssertTrue(last.notice?.hasPrefix("[bg-jobs] Background job jb-mwdzg9r8-rist completed (exit 0)") == true)

        // History: the same chip, from the exit notice in the transcript.
        let history = try turns(PiCapturedWire.historyJob)
        let job = try XCTUnwrap(BackgroundJob.parse(try block(history, "turn-1")))
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.duration, "25s")
        XCTAssertFalse(job.isLive)
    }

    func testJobShapesAreLenient() {
        XCTAssertNil(BackgroundJob.parse(.object(["codeg.backgroundJob": .object(["state": .string("melted")])])))
        let killed = BackgroundJob.parse(.object(["codeg.backgroundJob": .object([
            "state": .string("killed"), "exitCode": .null, "killedBy": .string("bgj_kill"), "duration": .string(""),
        ])]))
        XCTAssertEqual(killed?.state, .killed)
        XCTAssertEqual(killed?.killedBy, "bgj_kill")
        XCTAssertNil(killed?.exitCode)
        XCTAssertNil(killed?.duration, "an empty duration is none")
        let failed = BackgroundJob.parse(.object(["codeg.backgroundJob": .object([
            "state": .string("failed"), "exitCode": .number(-1),
        ])]))
        XCTAssertEqual(failed?.exitCode, -1, "an exit code can be negative")
    }

    // MARK: - Runs Pi started by itself, notices

    func testTheWakeMarkerSaysWhatWokePi() throws {
        let marker = try call(PiCapturedWire.jobWake)
        XCTAssertEqual(marker.title, "agent_wake")
        let first = try XCTUnwrap(AgentWake.parse(marker.meta))
        XCTAssertEqual(first.triggers.map(\.kind), [.jobExit])
        XCTAssertTrue(first.notes.isEmpty, "the notice's text comes in a moment later")
        let update = try call(PiCapturedWire.jobWakeUpdate)
        XCTAssertEqual(update.toolCallId, marker.toolCallId)
        let wake = try XCTUnwrap(AgentWake.parse(update.meta))
        XCTAssertEqual(wake.notes.count, 1)
        XCTAssertTrue(wake.notes[0].text.hasPrefix("[bg-jobs] Background job jb-mwdzg9r8-rist completed"))

        let settled = try XCTUnwrap(AgentWake.parse(try call(PiCapturedWire.subagentWake).meta))
        XCTAssertEqual(settled.triggers.first?.kind, .subagentSettled)
    }

    func testHistoryDrawsTheWakeOnASystemTurnOfItsOwn() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        let marker = try XCTUnwrap(history.first { $0.id == "turn-4" })
        XCTAssertEqual(marker.role, .system)
        let wake = try XCTUnwrap(AgentWake.of(marker))
        XCTAssertEqual(wake.triggers.map(\.kind), [.subagentSettled, .subagentSettled, .subagentSettled])
        XCTAssertEqual(wake.notes.count, 3)
        XCTAssertTrue(InFlightAnchor.canAnchor(marker))
        XCTAssertNil(AgentWake.of(try XCTUnwrap(history.first { $0.id == "turn-3" })))
    }

    func testAnUnknownWakeKindIsAnExtensionsAndNoTriggersIsNoMarker() {
        let wake = AgentWake.parse(.object(["codeg.agentWake": .object(["triggers": .array([
            .object(["kind": .string("somethingNew"), "text": .string("hello")]),
        ])])]))
        XCTAssertEqual(wake?.triggers.first?.kind, .extension)
        XCTAssertNil(AgentWake.parse(.object(["codeg.agentWake": .object(["triggers": .array([])])])))
        XCTAssertNil(AgentWake.parse(.object(["codeg.agentWake": .object([:])])))
    }

    func testANoticeNoCardClaimsIsASystemNote() {
        // `acp::pi_meta` sends it as a `pi_notice` call (`system_note_meta`).
        let note = PiSystemNote.parse(.object(["codeg.systemNote": .object([
            "version": .number(1), "customType": .string("my-ext"),
            "text": .string("Index rebuilt\n3 files changed"),
        ])]))
        XCTAssertEqual(note?.customType, "my-ext")
        XCTAssertEqual(note?.text, "Index rebuilt\n3 files changed")
        XCTAssertNil(PiSystemNote.parse(.object(["codeg.systemNote": .object(["text": .string("  ")])])))
    }

    // MARK: - Context compaction

    func testPisCompactionObjectIsACompaction() throws {
        let start = try call(PiCapturedWire.compactionStart)
        XCTAssertEqual(start.status, "in_progress")
        XCTAssertTrue(ContextCompaction.matches(start.meta), "the versioned object, not only `true`")
        let end = try call(PiCapturedWire.compactionEnd)
        XCTAssertTrue(ContextCompaction.matches(end.meta))
        XCTAssertEqual(ContextCompaction.tokens(end.meta).before, 7411)
        XCTAssertNil(ContextCompaction.tokens(end.meta).after, "Pi has no count after")
        XCTAssertEqual(ContextCompaction.durationMs(end.meta), 891)
        XCTAssertNil(ContextCompaction.error(end.meta))
    }

    func testEveryCompactionShapeStillReads() {
        // Grok's boolean with sibling counts.
        let grok = AnyJSON.object(["contextCompaction": .bool(true), "tokensBefore": .number(9000),
                                   "tokensAfter": .number(1200)])
        XCTAssertTrue(ContextCompaction.matches(grok))
        XCTAssertEqual(ContextCompaction.tokens(grok).before, 9000)
        XCTAssertEqual(ContextCompaction.tokens(grok).after, 1200)
        // Claude Code's object with both counts, and a failed one.
        let claude = AnyJSON.object(["contextCompaction": .object(["version": .number(1), "preTokens": .number(150_000),
                                                                   "postTokens": .number(12_000)])])
        XCTAssertEqual(ContextCompaction.tokens(claude).after, 12_000)
        let failed = AnyJSON.object(["contextCompaction": .object(["version": .number(1), "error": .string("no model")])])
        XCTAssertEqual(ContextCompaction.error(failed), "no model")
        // Not a compaction.
        XCTAssertFalse(ContextCompaction.matches(.object(["contextCompaction": .bool(false)])))
        XCTAssertFalse(ContextCompaction.matches(.object(["contextCompaction": .object([:])])))
        XCTAssertFalse(ContextCompaction.matches(.object(["contextCompaction": .object(["version": .number(0)])])))
        XCTAssertFalse(ContextCompaction.matches(.object(["contextCompaction": .object(["version": .number(1.5)])])))
        XCTAssertFalse(ContextCompaction.matches(nil))
    }

    // MARK: - Which card a call draws

    func testTheLiveCardWinsUntilTheTranscriptHasTheEnd() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        let ownSettled = try block(history, "turn-2")
        let liveFinished = try call(PiCapturedWire.subagentFinished).meta
        let liveRunning = try call(PiCapturedWire.subagentRunning).meta
        // The transcript saw the run end: its card is what every reload draws.
        XCTAssertEqual(ToolCardMerge.effective(own: ownSettled, live: liveFinished, key: .subagentRun), ownSettled)
        XCTAssertEqual(ToolCardMerge.effective(own: ownSettled, live: liveRunning, key: .subagentRun), ownSettled)
        // The call's own copy of a live card (the turn that launched it):
        // the connection's newer card wins.
        let ownLive = try call(PiCapturedWire.subagentLaunch).meta
        XCTAssertEqual(ToolCardMerge.effective(own: ownLive, live: liveRunning, key: .subagentRun), liveRunning)
        // History that only knows the launch ("result pending") gives way.
        let pending = AnyJSON.object(["codeg.subagentRun": .object(["status": .string("pending")])])
        XCTAssertEqual(ToolCardMerge.effective(own: pending, live: liveFinished, key: .subagentRun), liveFinished)
        // No live card, or one that isn't this kind: the call's own.
        XCTAssertEqual(ToolCardMerge.effective(own: pending, live: nil, key: .subagentRun), pending)
        let jobCard = try call(PiCapturedWire.jobFinished).meta
        XCTAssertEqual(ToolCardMerge.effective(own: pending, live: jobCard, key: .subagentRun), pending)
    }

    func testAJobsChipFollowsTheSameRule() throws {
        let history = try turns(PiCapturedWire.historyJob)
        let ownSettled = try block(history, "turn-1")
        let live = try call(PiCapturedWire.jobFinished).meta
        XCTAssertEqual(ToolCardMerge.effective(own: ownSettled, live: live, key: .backgroundJob), ownSettled)
        let noExit = AnyJSON.object(["codeg.backgroundJob": .object(["state": .string("pending")])])
        XCTAssertEqual(ToolCardMerge.effective(own: noExit, live: live, key: .backgroundJob), live)
        let launchCopy = try call(PiCapturedWire.jobLaunch).meta
        XCTAssertEqual(ToolCardMerge.effective(own: launchCopy, live: live, key: .backgroundJob), live)
        XCTAssertTrue(ToolCardMerge.settledInTranscript(ownSettled, key: .backgroundJob))
        XCTAssertFalse(ToolCardMerge.settledInTranscript(launchCopy, key: .backgroundJob))
    }

    func testTheConnectionsCardsComeFromEventsAndSnapshots() throws {
        let cards = LiveToolCards()
        let launch = try call(PiCapturedWire.subagentLaunch)
        XCTAssertEqual(cards.meta(for: launch.toolCallId, own: launch.meta, key: .subagentRun), launch.meta,
                       "nothing heard yet: the call's own")
        // A fresh attach while the run went on: both launches' cards.
        let snapshot = try snapshotCards(PiCapturedWire.runningSnapshot)
        XCTAssertEqual(snapshot.count, 2)
        cards.merge(snapshot, connectionID: "conn-a")
        XCTAssertTrue(cards.hasActiveWork, "the workflow still runs")
        let running = try XCTUnwrap(SubagentRun.parse(cards.meta(for: launch.toolCallId, own: launch.meta,
                                                                 key: .subagentRun)))
        XCTAssertEqual(running.status, .running)
        // Its newest card, as a `tool_card` event.
        let finished = try call(PiCapturedWire.subagentFinished)
        cards.apply(toolCallID: finished.toolCallId, meta: try XCTUnwrap(finished.meta))
        XCTAssertEqual(SubagentRun.parse(cards.meta(for: launch.toolCallId, own: launch.meta,
                                                    key: .subagentRun))?.status, .completed)
        XCTAssertFalse(cards.hasActiveWork)
        // A snapshot without cards (an older server) leaves them be; one of
        // the same connection only replaces the calls it lists.
        cards.merge([], connectionID: "conn-a")
        XCTAssertEqual(cards.cards.count, 2)
        // Another connection (the agent restarted): the old cards are dead.
        cards.merge([], connectionID: "conn-b")
        XCTAssertTrue(cards.cards.isEmpty)
        cards.apply(toolCallID: "", meta: try XCTUnwrap(finished.meta))
        cards.apply(toolCallID: "x", meta: .string("not a card"))
        XCTAssertTrue(cards.cards.isEmpty, "no id, or no card: nothing")
        let job = try call(PiCapturedWire.jobLaunch)
        cards.apply(toolCallID: job.toolCallId, meta: try XCTUnwrap(job.meta))
        XCTAssertTrue(cards.hasActiveWork, "a job running")
        cards.removeAll()
        XCTAssertTrue(cards.cards.isEmpty)
    }

    // MARK: - Background job polls

    func testAPollsReportReadsAsCodegWebReadsIt() {
        let report = JobPollReport.parse("[jb-a1] completed (exit 0) · 3m 52s · npm run build\n\n--- output tail ---\nok\n")
        XCTAssertEqual(report?.jobID, "jb-a1")
        XCTAssertEqual(report?.outcome, .completed)
        XCTAssertEqual(report?.exitCode, 0)
        XCTAssertEqual(report?.command, "npm run build")
        XCTAssertEqual(report?.output, "ok")
        // Older builds' spelling, and a non-zero exit.
        XCTAssertEqual(JobPollReport.parse("[jb-a1] completed exit 2 · 9s · make")?.outcome, .failed)
        XCTAssertEqual(JobPollReport.parse("[jb-a1] failed (exit 1) · 9s · make")?.exitCode, 1)
        XCTAssertEqual(JobPollReport.parse("[jb-a1] killed (bgj_kill) · 9s · make")?.outcome, .stopped)
        XCTAssertEqual(JobPollReport.parse("[jb-a1] ended (exit code unknown) · 9s · make")?.outcome, .completed)
        XCTAssertEqual(JobPollReport.parse("[jb-a1] running · 1m 2s · sleep 90\n\n--- output tail ---\n(no output)")?
            .output, nil, "nothing to show")
        XCTAssertEqual(JobPollReport.parse("Already finished: [jb-a1] completed (exit 0) · 1s · true")?.jobID, "jb-a1")
        let kill = JobPollReport.parse("Sent SIGTERM to jb-a1 (sleep 40); SIGKILL follows in 5s if it ignores it.")
        XCTAssertEqual(kill?.outcome, .stopped)
        XCTAssertEqual(kill?.command, "sleep 40")
        XCTAssertNil(JobPollReport.parse("total 12\ndrwxr-xr-x  3 dev staff"))
        XCTAssertNil(JobPollReport.parse("[not-a-job] completed (exit 0) · 1s · x"))
        XCTAssertNil(JobPollReport.parse(nil))
    }

    func testPollsMergeIntoOneRowPerJob() {
        let calls = [
            JobPollCall(callID: "p1", input: #"{"id":"jb-a"}"#, output: "[jb-a] running · 10s · make", isError: false,
                        finished: true),
            JobPollCall(callID: "p2", input: #"{"id":"jb-b"}"#, output: "[jb-b] running · 3s · npm test\n\n--- output tail ---\n1 passed",
                        isError: false, finished: true),
            JobPollCall(callID: "p3", input: #"{"id":"jb-a"}"#,
                        output: "[jb-a] completed (exit 0) · 40s · make\n\n--- output tail ---\nbuilt", isError: false,
                        finished: true),
            // A wait still waiting: its job comes from its arguments.
            JobPollCall(callID: "p4", input: #"{"id":"jb-b","timeout":120}"#, output: nil, isError: false, finished: false),
        ]
        let rows = JobPolls.rows(calls)
        XCTAssertEqual(rows.map(\.jobID), ["jb-a", "jb-b"])
        XCTAssertEqual(rows.map(\.pollCount), [2, 2])
        XCTAssertEqual(rows[0].outcome, .completed)
        XCTAssertEqual(rows[0].output, "built", "the freshest output")
        XCTAssertFalse(rows[0].inFlight)
        XCTAssertEqual(rows[1].outcome, .running)
        XCTAssertTrue(rows[1].inFlight)
        XCTAssertEqual(rows[1].command, "npm test")
        XCTAssertEqual(rows[1].output, "1 passed")
        // A poll that failed outright with no job line.
        let failed = JobPolls.rows([JobPollCall(callID: "p9", input: #"{"id":"jb-c"}"#, output: "No such job",
                                                isError: true, finished: true)])
        XCTAssertEqual(failed.first?.outcome, .failed)
        XCTAssertEqual(failed.first?.jobID, "jb-c")
        XCTAssertTrue(JobPolls.isPoll("bgj_wait"))
        XCTAssertTrue(JobPolls.isPoll("BGJ_STATUS"))
        XCTAssertFalse(JobPolls.isPoll("bgj_run"))
    }

    // MARK: - Where a run Pi started by itself begins

    func testTheWakeMarkerAnchorsARunPiStartedItself() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        // A prompt: its own turn, as before.
        XCTAssertEqual(InFlightAnchor.index(in: history, promptID: "turn-0"), 0)
        // The server names the "woken by" System turn: the run begins there,
        // after the reply that answered the prompt.
        XCTAssertEqual(InFlightAnchor.index(in: history, promptID: "turn-4"), 4)
        // Before any of the run is in the transcript: after all of it.
        XCTAssertEqual(InFlightAnchor.index(in: history, promptID: "pi-agent-turn-1794515495851"), history.count)
        // Unknown or no id: the last prompt.
        XCTAssertEqual(InFlightAnchor.index(in: history, promptID: "gone"), 0)
        XCTAssertEqual(InFlightAnchor.index(in: history, promptID: nil), 0)
        // A System turn that isn't a wake marker anchors nothing.
        let note = MessageTurn(id: "s-1", role: .system, blocks: [.text("Model changed")], timestamp: Date())
        XCTAssertNil(InFlightAnchor.index(in: [note], promptID: "s-1"))
        XCTAssertTrue(InFlightAnchor.isPiAgentTurnMarker("pi-agent-turn-1"))
        XCTAssertFalse(InFlightAnchor.isPiAgentTurnMarker("turn-4"))
        XCTAssertFalse(InFlightAnchor.isPiAgentTurnMarker(nil))
    }

    // MARK: - Small print

    func testCountsAndFirstLines() {
        XCTAssertEqual(PiCardValue.compactCount(999), "999")
        XCTAssertEqual(PiCardValue.compactCount(1000), "1K")
        XCTAssertEqual(PiCardValue.compactCount(7921), "7.9K")
        XCTAssertEqual(PiCardValue.compactCount(15_900), "15.9K")
        XCTAssertEqual(PiCardValue.compactCount(250_400), "250K")
        XCTAssertEqual(PiCardValue.compactCount(1_250_000), "1.3M")
        XCTAssertEqual(PiCardValue.firstLine("\n\n  First line  \nsecond"), "First line")
        XCTAssertEqual(PiCardValue.firstLine("   \n"), "")
    }
}
