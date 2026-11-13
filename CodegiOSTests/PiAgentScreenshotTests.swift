import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// How Pi's delegated work looks on the phone, through the same window
/// capture as ``SessionListScreenshotTests``, from what a fork.234 server sent
/// (``PiCapturedWire``): in `$COMPOSE_SHOTS_DIR`, `pi-subagent-history-*.png`
/// (a failed and a finished run, the divider of the run Pi started when the
/// workflow finished), `pi-subagent-live-*.png` (a run going on after its
/// turn, its rows at work), `pi-subagent-open-*.png` (a run's result and what
/// the model saw, opened), `pi-job-*.png` (a job's chip, the run its exit
/// started, a job's polls in one card and Pi's compaction divider) and
/// `pi-subagent-session-*.png` (a lane's own session), in light and dark,
/// and in Simplified Chinese.
@MainActor
final class PiAgentScreenshotTests: XCTestCase {

    private func detail(_ json: String) throws -> ConversationDetail {
        try CodegJSON.decoder.decode(ConversationDetail.self, from: Data(json.utf8))
    }

    private func meta(_ envelope: String) throws -> AnyJSON? {
        switch try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(envelope.utf8)).event {
        case .toolCall(_, _, _, _, _, _, _, let meta, _): return meta
        case .toolCallUpdate(_, _, _, _, _, _, _, let meta, _): return meta
        case .toolCard(_, let meta): return meta
        default: return nil
        }
    }

    private func transcript(_ turns: [MessageTurn], cards: LiveToolCards, locale: Locale) -> some View {
        ZStack {
            CodegBackground()
            TranscriptView(turns: turns, pendingUserTurns: [], liveTurn: nil, agent: .pi, turnsVersion: 1,
                           scrollTick: 0, stickTick: 0, onPinnedChange: { _ in }) { EmptyView() }
        }
        .environment(\.liveToolCards, cards)
        .environment(\.openSubagentSession, OpenSubagentSessionAction { _ in })
        .environment(\.locale, locale)
    }

    private func shoot<Content: View>(_ name: String, settle: TimeInterval = 1.5,
                                      _ content: @escaping (Locale) -> Content) throws {
        for style in Shot.styles {
            try Shot.capture(name, style, in: Shot.composeDirectory, settle: settle) {
                content(Locale(identifier: "en"))
            }
        }
        try Shot.capture("\(name)-zh", .light, in: Shot.composeDirectory, settle: settle) {
            content(Locale(identifier: "zh-Hans"))
        }
    }

    // MARK: - Sub-agent runs

    func testARunInHistory() throws {
        // The first launch failed at once; the second ran two lanes; when the
        // workflow finished, Pi went on by itself.
        let turns = try detail(PiCapturedWire.historySubagents).turns
        try shoot("pi-subagent-history") { locale in
            self.transcript(turns, cards: LiveToolCards(), locale: locale)
        }
    }

    func testARunGoingOnAfterItsTurn() throws {
        // The launch turn ended ("LAUNCHED"); the connection's card shows the
        // lanes at work.
        let history = try detail(PiCapturedWire.historySubagents).turns
        let launchID = "chatcmpl-tool-e4ad7ff3e99647ceb7fa8b09991fdfb8"
        let launch = MessageTurn(id: "turn-2", role: .assistant, blocks: [
            .toolUse(id: launchID, name: "agent",
                     inputPreview: #"{"subagent_type":"scout","workflow":"parallel","args":{"tasks":[{"agent":"scout","task":"Use bash to run `sleep 6; ls / | wc -l` and reply with the number."},{"agent":"scout","task":"Use bash to run `sleep 9; ls ~ | wc -l` and reply with the number."}]},"async":true}"#,
                     meta: try meta(PiCapturedWire.subagentLaunch)),
            .toolResult(id: launchID, outputPreview: "Async workflow launched.", isError: false),
            .text("LAUNCHED"),
        ], timestamp: Date().addingTimeInterval(-20))
        let turns = [history[0], launch]
        let cards = LiveToolCards(cards: [launchID: try XCTUnwrap(try meta(PiCapturedWire.subagentRunning))])
        try shoot("pi-subagent-live") { locale in
            self.transcript(turns, cards: cards, locale: locale)
        }
    }

    func testARunOpened() throws {
        let finished = try XCTUnwrap(SubagentRun.parse(try meta(PiCapturedWire.subagentFinished)))
        let vm = ToolCallVM(id: "chatcmpl-tool-e4ad7ff3e99647ceb7fa8b09991fdfb8", rawName: "agent", kind: "other",
                            state: .done, input: #"{"subagent_type":"scout"}"#, output: nil, content: nil,
                            isError: false, meta: try meta(PiCapturedWire.subagentFinished))
        try shoot("pi-subagent-open", settle: 1.2) { locale in
            ZStack(alignment: .top) {
                CodegBackground()
                ScrollView {
                    SubagentRunCard(vm: vm, run: finished, resultOpen: true, notesOpen: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 70)
                }
            }
            .environment(\.openSubagentSession, OpenSubagentSessionAction { _ in })
            .environment(\.locale, locale)
        }
    }

    func testALanesOwnSession() throws {
        let child = try CodegJSON.decoder.decode(AgentSessionDetail.self, from: Data(PiCapturedWire.childSession.utf8))
        let ref = SubagentSessionRef(sessionID: "01a1d175-4b29-767c-9768-40b41c0465e9", label: "task-1",
                                     agent: "scout", isRunning: false)
        try shoot("pi-subagent-session", settle: 2) { locale in
            SubagentSessionSheet(ref: ref, load: { _ in child.turns })
                .environment(\.locale, locale)
        }
    }

    // MARK: - Background jobs

    func testAJobItsWokenRunPollsAndACompaction() throws {
        // The job ended; its exit woke Pi, which was stopped mid-command.
        var turns = try detail(PiCapturedWire.historyJob).turns
        // Then a job still going, checked twice, and a compaction.
        let jobID = "chatcmpl-tool-job2"
        let job = AnyJSON.object(["codeg.backgroundJob": .object([
            "version": .number(1), "tool": .string("bgj_run"), "id": .string("jb-mwe1a2b3-xk9q"),
            "state": .string("pending"),
        ])])
        let compaction = try meta(PiCapturedWire.compactionEnd)
        turns.append(MessageTurn(id: "u-9", role: .user, blocks: [.text("Now build the release in the background")],
                                 timestamp: Date().addingTimeInterval(-60)))
        turns.append(MessageTurn(id: "a-9", role: .assistant, blocks: [
            .toolUse(id: jobID, name: "bash", inputPreview: #"{"command":"npm run build:release"}"#, meta: job),
            .toolResult(id: jobID, outputPreview: "Command running in background with ID: jb-mwe1a2b3-xk9q (pid 9123).",
                        isError: false),
            .toolUse(id: "poll-1", name: "bgj_wait", inputPreview: #"{"id":"jb-mwe1a2b3-xk9q","timeout":60}"#, meta: nil),
            .toolResult(id: "poll-1", outputPreview: "[jb-mwe1a2b3-xk9q] running · 1m 0s · npm run build:release\n\n--- output tail ---\n> vite build\n✓ 412 modules transformed.",
                        isError: false),
            .toolUse(id: "poll-2", name: "bgj_status", inputPreview: #"{"id":"jb-mwe1a2b3-xk9q"}"#, meta: nil),
            .toolResult(id: "poll-2", outputPreview: "[jb-mwe1a2b3-xk9q] running · 1m 31s · npm run build:release",
                        isError: false),
            .toolUse(id: "pi-compaction-1-1a1aa656", name: "context_compaction", inputPreview: nil, meta: compaction),
            .toolResult(id: "pi-compaction-1-1a1aa656", outputPreview: nil, isError: false),
            .text("The release build is still running; I'll pick it up when it finishes."),
        ], timestamp: Date().addingTimeInterval(-50)))
        let running = AnyJSON.object(["codeg.backgroundJob": .object([
            "version": .number(1), "tool": .string("bgj_run"), "id": .string("jb-mwe1a2b3-xk9q"),
            "state": .string("running"), "live": .bool(true),
        ])])
        let cards = LiveToolCards(cards: [jobID: running])
        try shoot("pi-job") { locale in
            self.transcript(turns, cards: cards, locale: locale)
        }
    }
}
