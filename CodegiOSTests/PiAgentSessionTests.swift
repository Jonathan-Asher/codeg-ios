import SwiftUI
import XCTest
@testable import Codeg

/// Pi's sub-agent runs, background jobs and the runs Pi starts by itself on
/// the session screen, against a mock codeg server and scripted event
/// sockets fed what a fork.234 server sent (``PiCapturedWire``): the events
/// and snapshot fields decode; the cards follow the connection after their
/// turn; a run Pi started by itself opens as a turn with its divider, shows
/// its replies once, and stops with Stop; "Fork Session" forks the reply
/// before it; marks render as marks, and a job's polls as one card. An
/// older server sends none of it, and nothing changes.
@MainActor
final class PiAgentSessionTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []

    override func setUp() async throws {
        server = MockCodegServer()
        OutboxStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        AttentionStore.shared.set(nil, for: Fixtures.conversationID)
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
        if let root = OutboxStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        OutboxStore.rootOverride = nil
    }

    private func makeModel(_ factory: StreamFactory) -> SessionDetailViewModel {
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() })
        models.append(model)
        return model
    }

    // MARK: - Fixtures

    private static let jobCallID = "chatcmpl-tool-bb5cac9873c04aaf9d99a4941115ca02"

    /// A captured transcript as this screen's conversation: its first `keep`
    /// turns, and a turn in flight when `inFlight` names one.
    private func piDetail(_ json: String, keep: Int? = nil, inFlight: String? = nil) throws -> String {
        var detail = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var summary = try XCTUnwrap(detail["summary"] as? [String: Any])
        summary["id"] = Fixtures.conversationID
        if inFlight != nil {
            summary["status"] = "in_progress"
            summary["turn_state"] = "running"
        }
        detail["summary"] = summary
        if let keep, let turns = detail["turns"] as? [Any] { detail["turns"] = Array(turns.prefix(keep)) }
        detail["in_flight_user_turn_id"] = inFlight ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: detail)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func turns(_ json: String, keep: Int? = nil) throws -> [MessageTurn] {
        let detail = try CodegJSON.decoder.decode(ConversationDetail.self, from: Data(try piDetail(json, keep: keep).utf8))
        return detail.turns
    }

    /// A captured snapshot frame's snapshot, its connection renamed `conn-1`
    /// (the connection the mock server hands out).
    private func snapshot(_ frame: String) throws -> LiveSessionSnapshot {
        let renamed = frame.replacingOccurrences(of: "061259d5-e86c-4272-a931-2d99b8355dae", with: "conn-1")
            .replacingOccurrences(of: "593a7c88-e478-4c1c-83cc-b0250e396971", with: "conn-1")
            .replacingOccurrences(of: "8e928c2e-7d9c-4c8c-9106-b5a1295c0fe4", with: "conn-1")
        guard case .snapshot(let snap)? = EventStream.frames(from: Data(renamed.utf8)).first else {
            throw XCTSkip("not a snapshot frame")
        }
        return snap
    }

    /// A captured event, as the socket delivers it, on connection `conn-1`.
    private func event(_ envelope: String) -> EventStream.Frame {
        Fixtures.event(envelope
            .replacingOccurrences(of: "8e928c2e-7d9c-4c8c-9106-b5a1295c0fe4", with: "conn-1")
            .replacingOccurrences(of: "593a7c88-e478-4c1c-83cc-b0250e396971", with: "conn-1"))
    }

    private func decodedEvent(_ envelope: String) throws -> AcpEvent {
        try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(envelope.utf8)).event
    }

    /// A captured call's frame, applied to a live turn as the screen applies it.
    private func apply(_ envelope: String, to live: LiveTurn) throws {
        switch try decodedEvent(envelope) {
        case .toolCall(let id, let title, let kind, let status, let content, let rawInput, let rawOutput, let meta, _):
            live.upsertToolCall(id: id, title: title, kind: kind, status: status, rawInput: rawInput,
                                rawOutput: rawOutput, content: content, meta: meta)
        case .toolCallUpdate(let id, let title, let status, let content, let rawInput, let rawOutput, let append,
                             let meta, _):
            live.updateToolCall(id: id, title: title, status: status, rawInput: rawInput, rawOutput: rawOutput,
                                content: content, append: append, meta: meta)
        case let other:
            XCTFail("not a call: \(other)")
        }
    }

    // MARK: - The wire

    func testACardEventDecodes() throws {
        guard case .toolCard(let id, let meta) = try decodedEvent(PiCapturedWire.jobFinished) else {
            return XCTFail("not a tool card")
        }
        XCTAssertEqual(id, Self.jobCallID)
        XCTAssertEqual(BackgroundJob.parse(meta)?.state, .completed)
        guard case .toolCard(_, let runMeta) = try decodedEvent(PiCapturedWire.subagentFinished) else {
            return XCTFail("not a tool card")
        }
        XCTAssertEqual(SubagentRun.parse(runMeta)?.children.count, 2)
        // One this build can't read is an event it ignores, never a broken stream.
        XCTAssertEqual(try decodedEvent(#"{"seq": 9, "connection_id": "c", "type": "tool_card", "tool_call_id": "x"}"#),
                       .unknown(type: "tool_card"))
        XCTAssertEqual(try decodedEvent(#"{"seq": 9, "connection_id": "c", "type": "tool_card", "meta": {"a": 1}}"#),
                       .unknown(type: "tool_card"))
    }

    func testTheSnapshotCarriesTheCards() throws {
        let running = try snapshot(PiCapturedWire.runningSnapshot)
        XCTAssertEqual(running.status, .connected)
        XCTAssertEqual(running.toolCards.count, 2)
        XCTAssertEqual(running.toolCards.compactMap { SubagentRun.parse($0.meta)?.status }, [.failed, .running])
        // An older server has none, and a malformed entry is stepped over.
        XCTAssertTrue(Fixtures.snapshot(status: "connected").toolCards.isEmpty)
        let odd = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(#"""
            {"connection_id": "c", "status": "connected", "tool_cards": [{"tool_call_id": "a"}, 3,
             {"tool_call_id": "b", "meta": {"codeg.backgroundJob": {"state": "running"}}}]}
            """#.utf8))
        XCTAssertEqual(odd.toolCards.map(\.toolCallId), ["b"])
        XCTAssertEqual(odd.status, .connected)
    }

    // MARK: - Rendering

    func testMarksRenderAsMarksNotCards() throws {
        let live = LiveTurn()
        try apply(PiCapturedWire.jobWake, to: live)
        try apply(PiCapturedWire.compactionStart, to: live)
        live.upsertToolCall(id: "pi-note-1", title: "pi_notice", kind: "other", status: "completed", rawInput: nil,
                            rawOutput: nil, content: nil, meta: .object(["codeg.systemNote": .object([
                                "version": .number(1), "customType": .string("my-ext"),
                                "text": .string("Index rebuilt\n3 files changed"),
                            ])]))
        var parts = MessageRender.adaptLive(segments: live.segments, streamingID: nil, turnRunning: true)
        XCTAssertEqual(parts.count, 3)
        guard case .agentWake(let wake, _) = parts[0] else { return XCTFail("\(parts[0])") }
        XCTAssertEqual(wake.triggers.first?.kind, .jobExit)
        guard case .compaction(let running) = parts[1] else { return XCTFail("\(parts[1])") }
        XCTAssertTrue(running.running)
        guard case .systemNote(let note, _) = parts[2] else { return XCTFail("\(parts[2])") }
        XCTAssertEqual(note.text, "Index rebuilt\n3 files changed")

        // The notice arrives on the marker; the compaction ends.
        try apply(PiCapturedWire.jobWakeUpdate, to: live)
        try apply(PiCapturedWire.compactionEnd, to: live)
        parts = MessageRender.adaptLive(segments: live.segments, streamingID: nil, turnRunning: true)
        guard case .agentWake(let woken, _) = parts[0] else { return XCTFail("\(parts[0])") }
        XCTAssertEqual(woken.notes.count, 1)
        guard case .compaction(let done) = parts[1] else { return XCTFail("\(parts[1])") }
        XCTAssertEqual(done, CompactionMark(before: 7411, after: nil, running: false, durationMs: 891, error: nil))

        // Folded into the conversation (a reply never reconciled), the same.
        let folded = MessageRender.adaptTurn(live.snapshotAsMessageTurn())
        XCTAssertEqual(folded.count, 3)
        guard case .agentWake = folded[0], case .compaction = folded[1], case .systemNote = folded[2] else {
            return XCTFail("\(folded)")
        }
    }

    func testHistoryDrawsTheRunsTheDividerAndNotes() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        let nodes = TranscriptTimeline.buildPersisted(turns: history, pending: [], agent: .pi, suppressInFlight: false)
        let runs = nodes.filter {
            if case .tool(let vm) = $0.content { return SubagentRun.parse(vm.meta) != nil }
            return false
        }
        XCTAssertEqual(runs.count, 2, "each launch is one card")
        if case .tool(let vm) = runs[0].content {
            XCTAssertEqual(vm.bucket, .task)
            if case .subagentRun(_, _, _) = runs[0].marker {} else { XCTFail("the run's own marker") }
        }
        let wake = try XCTUnwrap(nodes.first { $0.id == "turn-4" })
        guard case .agentWake(let divider) = wake.content else { return XCTFail("\(wake.content)") }
        XCTAssertEqual(divider.triggers.count, 3)

        // A Pi session's System text is a small note; another agent's keeps its caption.
        let note = MessageTurn(id: "s-1", role: .system, blocks: [.text("Index rebuilt\n3 files changed")],
                               timestamp: Date())
        let piNodes = TranscriptTimeline.buildPersisted(turns: [note], pending: [], agent: .pi, suppressInFlight: false)
        guard case .systemNote(let text)? = piNodes.first?.content else { return XCTFail("a note") }
        XCTAssertEqual(text, "Index rebuilt\n3 files changed")
        let claudeNodes = TranscriptTimeline.buildPersisted(turns: [note], pending: [], agent: .claudeCode,
                                                            suppressInFlight: false)
        guard case .system? = claudeNodes.first?.content else { return XCTFail("a caption") }
    }

    func testAJobAndItsPollsStandApart() throws {
        func call(_ id: String, _ name: String, _ input: String, _ output: String, meta: AnyJSON? = nil) -> [ContentBlock] {
            [.toolUse(id: id, name: name, inputPreview: input, meta: meta),
             .toolResult(id: id, outputPreview: output, isError: false)]
        }
        let job = AnyJSON.object(["codeg.backgroundJob": .object(["state": .string("pending"), "id": .string("jb-1")])])
        let turn = MessageTurn(id: "a", role: .assistant, blocks:
            call("b1", "bash", #"{"command":"ls"}"#, "x")
            + call("j1", "bash", #"{"command":"sleep 60"}"#, "Command running in background with ID: jb-1", meta: job)
            + call("b2", "bash", #"{"command":"pwd"}"#, "/tmp")
            + call("b3", "bash", #"{"command":"date"}"#, "now")
            + call("p1", "bgj_wait", #"{"id":"jb-1"}"#, "[jb-1] running · 30s · sleep 60")
            + call("p2", "bgj_status", #"{"id":"jb-1"}"#, "[jb-1] completed (exit 0) · 60s · sleep 60"),
            timestamp: Date())
        let parts = MessageRender.adaptTurn(turn)
        let shapes: [String] = parts.map { part in
            switch part {
            case .tool(let vm): return "tool \(vm.id)"
            case .toolGroup(let items, _): return "group " + items.map(\.id).joined(separator: ",")
            case .jobPollGroup(let polls): return "polls " + polls.map(\.id).joined(separator: ",")
            default: return "other"
            }
        }
        XCTAssertEqual(shapes, ["tool b1", "tool j1", "group b2,b3", "polls p1,p2"],
                       "the job's own card stands alone, its polls make one card")
        if case .jobPollGroup(let polls) = parts[3] {
            let rows = JobPolls.rows(polls.map(\.jobPollCall))
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.outcome, .completed)
            XCTAssertEqual(rows.first?.pollCount, 2)
        }
        // The job's marker follows the job; a plain command's, the call.
        let nodes = TranscriptTimeline.buildPersisted(turns: [turn], pending: [], agent: .pi, suppressInFlight: false)
        let jobNode = try XCTUnwrap(nodes.first { $0.id == "tool-j1" })
        guard case .backgroundJob(let id, _, _) = jobNode.marker else { return XCTFail("the job's own marker") }
        XCTAssertEqual(id, "j1")
        let command = try XCTUnwrap(nodes.first { $0.id == "tool-b1" })
        guard case .tool(_, .done) = command.marker else { return XCTFail("the call's marker") }
        // Live, `bgj_run` reads as the command it runs.
        let live = ToolCallVM(id: "j2", rawName: "bgj_run", kind: "other", state: .done,
                              input: #"{"command":"sleep 6; echo bg-done"}"#, output: nil, content: nil, isError: false)
        XCTAssertEqual(live.bucket, .execute)
        XCTAssertEqual(live.displayTitle, "sleep 6; echo bg-done")
        XCTAssertTrue(live.isJobLaunch)
    }

    // MARK: - Where the run in flight starts

    func testAWokenRunHidesOnlyItsOwnRepliesBehindTheLiveCopy() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        let bash = "chatcmpl-tool-b99e2d67c4624cf68ec906ac7482a88d"
        let coverage = TranscriptTimeline.LiveCoverage(toolIDs: [bash], imageCount: 0)
        func shown(_ promptID: String?) -> [String] {
            var seen: [String] = []
            for node in TranscriptTimeline.buildPersisted(turns: history, pending: [], agent: .pi, suppressInFlight: true,
                                                          inFlightPromptID: promptID, liveCoverage: coverage) {
                if let id = node.turnID, seen.last != id { seen.append(id) }
            }
            return seen
        }
        // The server names the "woken by" turn: the run's own replies are the
        // live copy's, the reply before it stays.
        XCTAssertEqual(shown("turn-4"), ["turn-0", "turn-1", "turn-4"])
        XCTAssertTrue(TranscriptTimeline.inFlightWakeIsPersisted(in: history, promptID: "turn-4"),
                      "the persisted divider stands for the live one")
        XCTAssertFalse(TranscriptTimeline.inFlightWakeIsPersisted(in: history, promptID: "turn-0"))

        // None of the run is in the transcript yet: nothing is its copy. The
        // reply before it, all text, was hidden behind the live copy when the
        // last prompt stood in for the run's start.
        let replied = [
            MessageTurn(id: "u", role: .user, blocks: [.text("Start the job")], timestamp: Date()),
            MessageTurn(id: "a", role: .assistant, blocks: [.text("Started it.")], timestamp: Date()),
        ]
        let nodes = TranscriptTimeline.buildPersisted(
            turns: replied, pending: [], agent: .pi, suppressInFlight: true,
            inFlightPromptID: "pi-agent-turn-1794515559061",
            liveCoverage: TranscriptTimeline.LiveCoverage(toolIDs: [], imageCount: 0))
        XCTAssertTrue(nodes.contains { $0.turnID == "a" }, "the finished reply stays")
        XCTAssertNil(TranscriptTimeline.inFlightPromptIndex(in: replied, promptID: "pi-agent-turn-1794515559061"))
        XCTAssertEqual(TranscriptTimeline.inFlightPromptIndex(in: replied, promptID: nil), 0, "as before")
    }

    func testForkingDuringAWokenRunForksTheReplyBeforeIt() throws {
        let history = try turns(PiCapturedWire.historySubagents)
        XCTAssertEqual(SessionForkRules.latestFinishedReply(in: history, inFlightPromptID: "turn-4"), "turn-3",
                       "the reply that finished before Pi went on, not one before the last prompt")
        XCTAssertEqual(SessionForkRules.latestFinishedReply(in: history, inFlightPromptID: "pi-agent-turn-1794515495851"),
                       "turn-6", "none of the run in the transcript yet: every reply there finished")
        // A prompt in flight, as before.
        let prompted = history + [MessageTurn(id: "turn-7", role: .user, blocks: [.text("Thanks")], timestamp: Date())]
        XCTAssertEqual(SessionForkRules.latestFinishedReply(in: prompted, inFlightPromptID: "turn-7"), "turn-6")
        XCTAssertNil(SessionForkRules.latestFinishedReply(in: history, inFlightPromptID: nil),
                     "no reply before the last prompt")
    }

    // MARK: - The screen

    func testARunPiStartedByItselfOpensAsATurnAndStops() async throws {
        // Pi woke on the job's exit and is running `for i in …`: the server
        // says a turn runs (no prompt: the run's first reply isn't written
        // yet), and its snapshot is prompting.
        let woken = try snapshot(PiCapturedWire.wokenSnapshot)
        XCTAssertEqual(woken.status, .prompting)
        XCTAssertNil(woken.pendingUserMessageId)
        let factory = StreamFactory([.attach(woken)])
        let marker = "pi-agent-turn-1794515559061"
        let detail = try piDetail(PiCapturedWire.historyJob, keep: 3, inFlight: marker)
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        server.on("acp_cancel") { _ in .body("null") }
        let model = makeModel(factory)
        await model.load()
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live, "the run streams as a turn")
        let liveTurn = try XCTUnwrap(model.liveTurn)
        XCTAssertEqual(model.inFlightPromptID, marker)

        // Its divider opens it; the reply before it is still there.
        let liveNodes = TranscriptTimeline.buildLive(liveTurn, agent: .pi)
        guard case .agentWake(let wake)? = liveNodes.first?.content else { return XCTFail("the divider first") }
        XCTAssertEqual(wake.triggers.first?.kind, .jobExit)
        XCTAssertTrue(liveNodes.contains { if case .tool = $0.content { return true } else { return false } })
        let persisted = TranscriptTimeline.buildPersisted(
            turns: model.turns, pending: model.pendingUserTurns, agent: .pi,
            suppressInFlight: model.liveTurnFromReattach, inFlightPromptID: model.inFlightPromptID,
            liveCoverage: TranscriptTimeline.LiveCoverage(toolIDs: liveTurn.toolCallIDs, imageCount: 0))
        XCTAssertEqual(Set(persisted.compactMap(\.turnID)), ["turn-0", "turn-1"],
                       "the prompt, and the reply to it (one reply of two turns), stay")
        // The job's card came with the snapshot.
        let job = model.liveToolCards.meta(for: "chatcmpl-tool-fe182eb82ff94c0da23b30820dcc2305", own: nil,
                                           key: .backgroundJob)
        XCTAssertEqual(BackgroundJob.parse(job)?.state, .completed)

        // Stop stops it, as any turn.
        model.cancel()
        XCTAssertFalse(model.isInFlight)
        let cancelled = await eventually { self.server.calls("acp_cancel").count == 1 }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(server.calls("acp_cancel").first?.body["connectionId"] as? String, "conn-1")
    }

    func testAJobsCardFollowsTheConnectionAndTheRunItsExitStarts() async throws {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let empty = try piDetail(PiCapturedWire.historyJob, keep: 0)
        let launched = try piDetail(PiCapturedWire.historyJob, keep: 3)
        let all = try piDetail(PiCapturedWire.historyJob)
        let woken = try snapshot(PiCapturedWire.wokenSnapshot)
        server.on("get_folder_conversation") { _ in .body(empty) }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let model = makeModel(factory)
        model.workWatchGrace = 4
        await model.load()
        XCTAssertEqual(model.phase, .loaded)

        model.draft = "Use the bgj_run tool to run exactly `sleep 6; echo bg-done`."
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let socket = factory.opened[0]
        socket.push(event(PiCapturedWire.jobLaunch))
        socket.push(event(PiCapturedWire.jobRunning))
        socket.push(Wire.delta("STARTED"))
        server.on("get_folder_conversation") { _ in .body(launched) }
        socket.push(Wire.turnComplete)
        let reconciled = await eventually { model.liveTurn == nil && !model.isInFlight }
        XCTAssertTrue(reconciled)
        XCTAssertTrue(model.liveToolCards.hasActiveWork)
        XCTAssertEqual(BackgroundJob.parse(model.liveToolCards.cards[Self.jobCallID])?.state, .running)
        XCTAssertFalse(socket.isClosed, "the job still runs: the socket stays to follow it")

        // It exits after its turn: the chip follows.
        socket.push(event(PiCapturedWire.jobFinished))
        let exited = await eventually {
            BackgroundJob.parse(model.liveToolCards.cards[Self.jobCallID])?.state == .completed
        }
        XCTAssertTrue(exited)
        XCTAssertFalse(model.liveToolCards.hasActiveWork)
        XCTAssertFalse(socket.isClosed, "a little longer, for the run its exit starts")

        // Pi starts a run on that exit: it opens here as a turn.
        socket.push(Fixtures.event(#"{"seq": 34, "connection_id": "conn-1", "type": "status_changed", "status": "prompting"}"#))
        socket.push(.snapshot(woken))
        let woke = await eventually { model.isInFlight }
        XCTAssertTrue(woke)
        if let liveTurn = model.liveTurn {
            XCTAssertTrue(TranscriptTimeline.buildLive(liveTurn, agent: .pi).contains {
                if case .agentWake = $0.content { return true } else { return false }
            })
        }

        // It ends; nothing is left to follow, and the socket goes.
        server.on("get_folder_conversation") { _ in .body(all) }
        socket.push(Wire.turnComplete)
        let ended = await eventually { !model.isInFlight }
        XCTAssertTrue(ended)
        let released = await eventually(timeout: 10) { socket.isClosed }
        XCTAssertTrue(released, "once the last run or job ended and a while passed")
    }

    func testOpeningASessionWhoseRunStillGoesKeepsFollowingIt() async throws {
        let factory = StreamFactory([.attach(try snapshot(PiCapturedWire.runningSnapshot))])
        let detail = try piDetail(PiCapturedWire.historySubagents, keep: 4)
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory)
        await model.load()
        let cards = await eventually { model.liveToolCards.cards.count == 2 }
        XCTAssertTrue(cards)
        XCTAssertFalse(model.isInFlight, "no turn runs")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(factory.opened[0].isClosed, "the workflow still runs: the socket stays")

        // Its connection goes: the cards say nothing more, the transcript's take over.
        factory.opened[0].push(.detached(reason: "connection_gone"))
        let dropped = await eventually { model.liveToolCards.cards.isEmpty }
        XCTAssertTrue(dropped)
    }

    func testAnOlderServerChangesNothing() async throws {
        // No cards, no woken runs: an idle session is let go as before.
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let detail = try piDetail(PiCapturedWire.historySubagents)
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory)
        await model.load()
        let released = await eventually { factory.opened.first?.isClosed == true }
        XCTAssertTrue(released)
        XCTAssertTrue(model.liveToolCards.cards.isEmpty)
    }

    func testARowOpensTheChildsOwnSession() async throws {
        server.on("get_conversation") { _ in .body(PiCapturedWire.childSession) }
        let turns = try await server.client.agentSessionTurns(agentType: .pi,
                                                              sessionID: "01a1d175-4b29-767c-9768-40b41c0465e9")
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .assistant, .assistant])
        let call = try XCTUnwrap(server.calls("get_conversation").first)
        XCTAssertEqual(call.body["agentType"] as? String, "pi")
        XCTAssertEqual(call.body["conversationId"] as? String, "01a1d175-4b29-767c-9768-40b41c0465e9")
    }
}
