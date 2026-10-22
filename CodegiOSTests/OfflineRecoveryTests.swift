import XCTest
@testable import Codeg

/// A running turn on screen through a dead zone (1.3.23), against a mock
/// codeg server, scripted event sockets and a network monitor fed by hand:
/// no reconnect is attempted, or counted, without a network, one goes the
/// moment it is back, and a socket that won't come back keeps trying instead
/// of failing the turn after about 24 seconds.
@MainActor
final class OfflineRecoveryTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []
    private let wifi = NetworkPath(status: .satisfied, interfaces: ["wifi"])
    private let noNetwork = NetworkPath(status: .unsatisfied)

    /// Flips what a route answers from inside a test.
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

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

    private func prompting(_ text: String) -> ScriptedStream.Script {
        .attach(Fixtures.snapshot(status: "prompting", liveText: text))
    }

    /// A screen on a session whose turn runs on the server, attached.
    private func openRunningTurn(_ factory: StreamFactory, monitor: ConnectivityMonitor,
                                 status: LinkStatus? = nil) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: "running")) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in factory.make() },
                                           connectivity: monitor, linkStatus: status)
        models.append(model)
        await model.load()
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live)
        return model
    }

    // MARK: - The pace

    func testTheReconnectPace() {
        let backoff = (1...6).map { StreamReconnect.step(attempt: $0, immediately: false) }
        XCTAssertEqual(backoff, [.wait(.milliseconds(500)), .wait(.seconds(1)), .wait(.seconds(2)),
                                 .wait(.seconds(4)), .wait(.seconds(8)), .wait(.seconds(8))])
        XCTAssertEqual(StreamReconnect.step(attempt: 7, immediately: false), .checkServerThenWait(.seconds(30)),
                       "the budget spent: ask the server once, then slow down")
        XCTAssertEqual(StreamReconnect.step(attempt: 8, immediately: false), .wait(.seconds(30)))
        XCTAssertEqual(StreamReconnect.step(attempt: 500, immediately: false), .wait(.seconds(30)), "never gives up")
        XCTAssertEqual(StreamReconnect.step(attempt: 3, immediately: true), .wait(.zero), "the network is back: at once")
        XCTAssertEqual(StreamReconnect.step(attempt: 7, immediately: true), .checkServerThenWait(.zero))
    }

    // MARK: - A dead zone

    func testARunningTurnWaitsOutADeadZoneAndCarriesOnWhenTheNetworkIsBack() async throws {
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(wifi)
        let status = LinkStatus(connectivity: monitor)
        let factory = StreamFactory([prompting("Reading the logs")],
                                    fallback: prompting("Reading the logs and the config"))
        let model = await openRunningTurn(factory, monitor: monitor, status: status)

        // The phone loses its network, and with it the socket.
        monitor.apply(noNetwork)
        factory.opened[0].drop("The network connection was lost.")
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(factory.opened.count, 1, "no attempt without a network (1.3.22 had made two by now)")
        XCTAssertTrue(model.isInFlight, "the turn stays on screen")
        XCTAssertEqual(model.activity, .working)
        XCTAssertNil(model.notice)
        XCTAssertNil(model.liveTurn?.errorMessage)
        XCTAssertTrue(status.inputs.down, "the capsule says so")

        // Back: the socket goes at once and picks the turn up again.
        monitor.apply(wifi)
        let reattached = await eventually { factory.opened.count == 2 && !status.inputs.down }
        XCTAssertTrue(reattached)
        XCTAssertEqual(factory.opened[1].attachedConnections, ["conn-1"])
        XCTAssertTrue(model.isInFlight)
        XCTAssertNil(model.liveTurn?.errorMessage)
    }

    func testASocketThatWontComeBackKeepsTryingInsteadOfFailingTheTurn() async throws {
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(wifi)
        let drops = Array(repeating: ScriptedStream.Script.dropOnAttach("Could not connect to the server."),
                          count: StreamReconnect.budget + 3)
        let factory = StreamFactory([prompting("Reading the logs")] + drops,
                                    fallback: prompting("Reading the logs and the config"))
        let model = await openRunningTurn(factory, monitor: monitor)
        model.reconnectTiming = .init(base: .milliseconds(10), cap: .milliseconds(40), slow: .milliseconds(150))

        // The network is there but the server isn't: the transcript can't be read either.
        let serverDown = Switch()
        server.on("get_folder_conversation") { _ in
            serverDown.isOn ? .fail(.cannotConnectToHost) : .body(Fixtures.detail(turnState: "running"))
        }
        serverDown.isOn = true
        let readsBefore = server.calls("get_folder_conversation").count
        factory.opened[0].drop("The network connection was lost.")

        // Past the budget the server is asked once, and the socket goes on
        // trying (every 30 s in the app) with the turn still on screen.
        let pastBudget = await eventually(timeout: 10) { factory.opened.count >= StreamReconnect.budget + 3 }
        XCTAssertTrue(pastBudget)
        XCTAssertTrue(model.isInFlight, "the turn isn't failed")
        XCTAssertNil(model.liveTurn?.errorMessage)
        XCTAssertNotEqual(model.sendState, .error(SessionDetailViewModel.lostConnectionMessage))
        XCTAssertGreaterThan(server.calls("get_folder_conversation").count, readsBefore,
                             "the server was asked whether the turn ended")

        // The server comes back: the next try attaches and the turn carries on.
        serverDown.isOn = false
        let attached = await eventually(timeout: 10) {
            factory.opened.count == StreamReconnect.budget + 5 && factory.opened.last?.isClosed == false
        }
        XCTAssertTrue(attached)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(factory.opened.count, StreamReconnect.budget + 5, "attached: no more tries")
        XCTAssertTrue(model.isInFlight)
        XCTAssertNil(model.liveTurn?.errorMessage)
    }

    func testAConnectionTheServerLetGoStillFailsTheTurnAfterTheBudget() async throws {
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(wifi)
        let drops = Array(repeating: ScriptedStream.Script.dropOnAttach("Could not connect to the server."),
                          count: StreamReconnect.budget + 3)
        let factory = StreamFactory([prompting("Reading the logs")] + drops)
        let model = await openRunningTurn(factory, monitor: monitor)
        model.reconnectTiming = .init(base: .milliseconds(10), cap: .milliseconds(40), slow: .milliseconds(150))
        // The server answers, without a reply in the transcript and without
        // the connection: it let the agent go.
        server.on("acp_get_session_snapshot") { _ in .body("null") }

        factory.opened[0].drop("The network connection was lost.")
        let failed = await eventually(timeout: 10) {
            model.sendState == .error(SessionDetailViewModel.lostConnectionMessage)
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.liveTurn?.errorMessage, SessionDetailViewModel.lostConnectionMessage,
                       "the partial reply stays, with why it stopped")
        XCTAssertFalse(model.isInFlight)
    }
}
