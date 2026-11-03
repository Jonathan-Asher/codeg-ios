import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// A reply the model's output limit cut off (the turn ended with ACP stop
/// reason `max_tokens`), against a mock codeg server and scripted event
/// sockets: the end of the transcript says so, with Continue, which sends
/// "continue" the way a typed message goes; the notice is for the latest
/// reply only, gone while a turn runs and once the next one starts, and
/// never there for any other stop reason. The live snapshot's
/// `last_stop_reason` keeps it through a reopen and through a reconnect
/// that missed the turn's end; an older server, without the field, changes
/// nothing.
@MainActor
final class OutputLimitTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []

    override func setUp() async throws {
        server = MockCodegServer()
        OutboxStore.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        // Another test's waiting card must not make this session "Needs you".
        AttentionStore.shared.set(nil, for: Fixtures.conversationID)
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
        if let root = OutboxStore.rootOverride { try? FileManager.default.removeItem(at: root) }
        OutboxStore.rootOverride = nil
    }

    private func makeModel(_ factory: StreamFactory, connectivity: ConnectivityMonitor? = nil) -> SessionDetailViewModel {
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() }, connectivity: connectivity)
        models.append(model)
        return model
    }

    /// A session with no live connection, opened.
    private func openIdleSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        return model
    }

    /// Send the guide request and let the agent stop at the output limit.
    private func cutOffReply(_ model: SessionDetailViewModel, _ factory: StreamFactory) async {
        model.draft = "Write the migration guide"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertFalse(model.showsOutputLimitNotice, "not while the turn runs")
        let socket = factory.opened[0]
        socket.push(Wire.delta("Step 1: back up the database. Step 2:"))
        server.on("get_folder_conversation") { _ in .body(Wire.detail(cutOffTurns)) }
        socket.push(Wire.turnEnded("max_tokens"))
        let reconciled = await eventually { model.liveTurn == nil && model.pendingUserTurns.isEmpty }
        XCTAssertTrue(reconciled)
        XCTAssertFalse(model.isInFlight)
    }

    /// The text of a prompt as it went to the server.
    private func promptText(_ call: MockCodegServer.Call?) -> String? {
        (call?.body["blocks"] as? [[String: Any]])?.first?["text"] as? String
    }

    // MARK: - Which turns

    func testOnlyTheOutputLimitCutsAReplyOff() {
        XCTAssertTrue(OutputLimitNotice.applies(to: "max_tokens"))
        for other in ["end_turn", "max_turn_requests", "refusal", "cancelled", "error"] {
            XCTAssertFalse(OutputLimitNotice.applies(to: other), other)
        }
        XCTAssertFalse(OutputLimitNotice.applies(to: nil))
    }

    func testTheSnapshotSaysHowTheConnectionsLastTurnEnded() throws {
        XCTAssertEqual(Fixtures.snapshot(status: "connected", lastStopReason: "max_tokens").lastStopReason, "max_tokens")
        // An older server never sends it; a newer one leaves it out while no turn ended.
        XCTAssertNil(Fixtures.snapshot(status: "connected").lastStopReason)
        // A shape this build doesn't expect is no reason, not a broken snapshot.
        let odd = try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(
            #"{"connection_id": "conn-1", "status": "connected", "last_stop_reason": 3}"#.utf8))
        XCTAssertNil(odd.lastStopReason)
        XCTAssertEqual(odd.status, .connected)
    }

    // MARK: - The notice and its Continue

    func testAReplyCutOffAtTheOutputLimitSaysSoWithContinue() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        await cutOffReply(model, factory)

        XCTAssertEqual(model.lastStopReason, "max_tokens")
        XCTAssertTrue(model.showsOutputLimitNotice, "it stays once the reply is the server's copy")
        XCTAssertFalse(model.canOfferContinue, "the notice's Continue stands in for the chip")
        XCTAssertEqual(Rendered.thread(model),
                       ["you: Write the migration guide", "agent: Step 1: back up the database. Step 2:"])

        // Continue sends "continue" the way a typed message goes: shown at
        // once (the Continued divider), and the notice is gone.
        model.sendContinue()
        XCTAssertFalse(model.showsOutputLimitNotice)
        XCTAssertTrue(model.isInFlight)
        XCTAssertEqual(Rendered.thread(model).last, "continued")
        let continued = await eventually { self.server.calls("acp_prompt").count == 2 }
        XCTAssertTrue(continued)
        XCTAssertEqual(promptText(server.calls("acp_prompt").last), ContinuePrompt.text)
        XCTAssertFalse(model.showsOutputLimitNotice, "not while that turn runs")

        // That turn ends as turns do: nothing to say.
        let socket = factory.opened[1]
        socket.push(Wire.delta("back up the config."))
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail(cutOffTurns + [Wire.user(2, "continue"), Wire.agent(3, Wire.text("back up the config."))]))
        }
        socket.push(Wire.turnComplete)
        let ended = await eventually { model.liveTurn == nil && !model.isInFlight }
        XCTAssertTrue(ended)
        XCTAssertEqual(model.lastStopReason, "end_turn")
        XCTAssertFalse(model.showsOutputLimitNotice)
    }

    func testAnyMessageSentHidesTheNoticeAndAnOrdinaryEndShowsNone() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await openIdleSession(factory)
        await cutOffReply(model, factory)
        XCTAssertTrue(model.showsOutputLimitNotice)

        model.draft = "Skip step 2"
        model.sendFromComposer()
        XCTAssertFalse(model.showsOutputLimitNotice, "a new turn: the notice is behind it")
        let prompted = await eventually { self.server.calls("acp_prompt").count == 2 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(promptText(server.calls("acp_prompt").last), "Skip step 2")

        let socket = factory.opened[1]
        socket.push(Wire.delta("Skipped it."))
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail(cutOffTurns + [Wire.user(2, "Skip step 2"), Wire.agent(3, Wire.text("Skipped it."))]))
        }
        socket.push(Wire.turnEnded("end_turn"))
        let ended = await eventually { model.liveTurn == nil && !model.isInFlight }
        XCTAssertTrue(ended)
        XCTAssertFalse(model.showsOutputLimitNotice)
        XCTAssertTrue(model.canOfferContinue, "the Continue chip is back for an ordinary reply")
    }

    func testTheNoticesRowHasItsOwnIDMarkerAndContinue() {
        var tapped = 0
        let node = TranscriptTimeline.outputLimitNode(OutputLimitNotice { tapped += 1 }, agent: .pi)
        XCTAssertEqual(node.id, TranscriptTimeline.outputLimitNodeID)
        XCTAssertNil(node.turnID, "no turn of its own")
        guard case .outputLimit(let notice) = node.content else { return XCTFail("\(node.content)") }
        notice.onContinue()
        XCTAssertEqual(tapped, 1)
        guard case .warning = node.marker else { return XCTFail("the warning marker") }
    }

    // MARK: - The server's word: a reopen

    /// A session whose last reply the output limit cut off, opened anew: its
    /// connection is idle, with the factory's first snapshot.
    private func reopen(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Wire.detail(cutOffTurns)) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        let released = await eventually { factory.opened.first?.isClosed == true }
        XCTAssertTrue(released, "an idle connection is let go, as before")
        return model
    }

    func testAReopenedSessionShowsTheNoticeFromTheServersWord() async {
        // The server keeps saying how the last turn ended until the next prompt starts.
        let cutOff = Fixtures.snapshot(status: "connected", lastStopReason: "max_tokens")
        let factory = StreamFactory([.attach(cutOff)], fallback: .attach(cutOff))
        let model = await reopen(factory)
        XCTAssertTrue(model.showsOutputLimitNotice)
        XCTAssertFalse(model.canOfferContinue)

        model.sendContinue()
        XCTAssertFalse(model.showsOutputLimitNotice)
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(promptText(server.calls("acp_prompt").first), ContinuePrompt.text)
        // The send's own attach snapshot predates its prompt: it doesn't bring the notice back.
        XCTAssertNil(model.lastStopReason)
        XCTAssertFalse(model.showsOutputLimitNotice)

        let socket = factory.opened[1]
        socket.push(Wire.delta("back up the config."))
        server.on("get_folder_conversation") { _ in
            .body(Wire.detail(cutOffTurns + [Wire.user(2, "continue"), Wire.agent(3, Wire.text("back up the config."))]))
        }
        socket.push(Wire.turnComplete)
        let ended = await eventually { model.liveTurn == nil && !model.isInFlight }
        XCTAssertTrue(ended)
        XCTAssertEqual(model.lastStopReason, "end_turn")
        XCTAssertFalse(model.showsOutputLimitNotice)
    }

    func testAReopenedSessionWithoutTheServersWordShowsNone() async {
        // An older server: no `last_stop_reason`.
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = await reopen(factory)
        XCTAssertNil(model.lastStopReason)
        XCTAssertFalse(model.showsOutputLimitNotice)
        XCTAssertTrue(model.canOfferContinue, "the chip, as before")
    }

    func testATurnStartedElsewhereHidesTheNotice() async {
        let factory = StreamFactory([
            .attach(Fixtures.snapshot(status: "connected", lastStopReason: "max_tokens")),
            .attach(Fixtures.snapshot(status: "prompting", liveText: "Looking at step 2.")),
        ])
        let model = await reopen(factory)
        XCTAssertTrue(model.showsOutputLimitNotice)

        // The desktop sent the next message; back on this screen, it runs.
        await model.refreshOnForeground()
        let adopted = await eventually { model.isInFlight }
        XCTAssertTrue(adopted)
        XCTAssertNil(model.lastStopReason)
        XCTAssertFalse(model.showsOutputLimitNotice)

        server.on("get_folder_conversation") { _ in
            .body(Wire.detail(cutOffTurns + [Wire.user(2, "Is step 2 needed?"),
                                             Wire.agent(3, Wire.text("Looking at step 2."))]))
        }
        factory.opened[1].push(Wire.turnComplete)
        let ended = await eventually { !model.isInFlight }
        XCTAssertTrue(ended)
        XCTAssertFalse(model.showsOutputLimitNotice)
    }

    func testAForkInPlaceLeavesTheNoticeWithTheOriginal() async {
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected", lastStopReason: "max_tokens"))])
        let model = await reopen(factory)
        XCTAssertTrue(model.showsOutputLimitNotice)

        // This row now holds the forked session, whose history ends at the fork.
        server.on("get_folder_conversation") { _ in .body(Wire.detail(Array(cutOffTurns.prefix(1)))) }
        await model.reloadAfterInPlaceFork(connectionID: nil)
        XCTAssertNil(model.lastStopReason)
        XCTAssertFalse(model.showsOutputLimitNotice)
    }

    // MARK: - The server's word: a reconnect that missed the end

    /// A running turn on screen whose socket drops; the turn ends meanwhile,
    /// so its `turn_complete` never arrives. The reconnect's snapshot and the
    /// server's answer after it say it ended, with `lastStopReason`.
    private func missTheEnd(lastStopReason: String?) async -> SessionDetailViewModel {
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(NetworkPath(status: .satisfied, interfaces: ["wifi"]))
        let ended = Fixtures.snapshotJSON(status: "connected", lastStopReason: lastStopReason)
        let factory = StreamFactory(
            [.attach(Fixtures.snapshot(status: "prompting", liveText: "Step 1: back up the database."))],
            fallback: .attach(Fixtures.snapshot(status: "connected", lastStopReason: lastStopReason)))
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: "running")) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = makeModel(factory, connectivity: monitor)
        model.reconnectTiming = .init(base: .milliseconds(10), cap: .milliseconds(40), slow: .milliseconds(150))
        await model.load()
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live)
        XCTAssertFalse(model.showsOutputLimitNotice)

        server.on("acp_get_session_snapshot") { _ in .body(ended) }
        server.on("get_folder_conversation") { _ in .body(Wire.detail(cutOffTurns)) }
        factory.opened[0].drop("The network connection was lost.")
        let settled = await eventually { !model.isInFlight }
        XCTAssertTrue(settled)
        XCTAssertGreaterThanOrEqual(factory.opened.count, 2, "it reconnected")
        return model
    }

    func testAReconnectThatMissedTheTurnsEndKeepsTheNotice() async {
        let model = await missTheEnd(lastStopReason: "max_tokens")
        XCTAssertEqual(model.lastStopReason, "max_tokens")
        XCTAssertTrue(model.showsOutputLimitNotice)
        XCTAssertFalse(model.canOfferContinue)
    }

    func testAReconnectWithoutTheServersWordEndsTheTurnAsBefore() async {
        let model = await missTheEnd(lastStopReason: nil)
        XCTAssertEqual(model.lastStopReason, "end_turn")
        XCTAssertFalse(model.showsOutputLimitNotice)
    }

    // MARK: - How it looks

    /// The end of a reply the output limit cut off, as the transcript draws
    /// it (the reply, its footer, then the notice), in light and dark and in
    /// Simplified Chinese: `output-limit-notice-*.png` in `$COMPOSE_SHOTS_DIR`.
    func testTheNoticeAtTheEndOfTheReply() throws {
        let now = Date()
        let turns = [
            MessageTurn(id: "u-1", role: .user, blocks: [.text("Write the migration guide for the new schema")],
                        timestamp: now.addingTimeInterval(-120)),
            MessageTurn(id: "a-1", role: .assistant, blocks: [.text("""
                ## Migration guide

                1. Back up the database with `pg_dump`.
                2. Run the schema migration, then check that every table
                """)], timestamp: now.addingTimeInterval(-110), durationMs: 104_000,
                        completedAt: now.addingTimeInterval(-6)),
        ]
        func transcript(_ locale: Locale) -> some View {
            ZStack {
                CodegBackground()
                TranscriptView(turns: turns, pendingUserTurns: [], liveTurn: nil, agent: .pi, turnsVersion: 1,
                               scrollTick: 0, stickTick: 0, onPinnedChange: { _ in },
                               outputLimitNotice: OutputLimitNotice {}) { EmptyView() }
            }
            .environment(\.locale, locale)
        }
        for style in Shot.styles {
            try Shot.capture("output-limit-notice", style, in: Shot.composeDirectory, settle: 1.5) {
                transcript(Locale(identifier: "en"))
            }
        }
        try Shot.capture("output-limit-notice-zh", .light, in: Shot.composeDirectory, settle: 1.5) {
            transcript(Locale(identifier: "zh-Hans"))
        }
    }
}

/// The reply the output limit cut off, as the server keeps it.
private let cutOffTurns = [
    Wire.user(0, "Write the migration guide"),
    Wire.agent(1, Wire.text("Step 1: back up the database. Step 2:")),
]
