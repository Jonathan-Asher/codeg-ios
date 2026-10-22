import XCTest
@testable import Codeg

/// The network monitor (1.3.23) with path reports fed by hand, and what the
/// link capsule says when (a port of codeg web's `connection-display.ts`).
@MainActor
final class ConnectivityTests: XCTestCase {
    private let wifi = NetworkPath(status: .satisfied, interfaces: ["wifi"])
    private let cellular = NetworkPath(status: .satisfied, interfaces: ["cellular"])
    private let noNetwork = NetworkPath(status: .unsatisfied)

    @MainActor
    private final class EventLog {
        var events: [ConnectivityMonitor.Event] = []
        var done = false
        var cancelled = false
    }

    /// Hands path reports to the monitor the way `NWPathMonitor` does: from
    /// another queue.
    private final class ScriptedPathSource: NetworkPathSource, @unchecked Sendable {
        private var onUpdate: (@Sendable (NetworkPath) -> Void)?
        func start(_ onUpdate: @escaping @Sendable (NetworkPath) -> Void) { self.onUpdate = onUpdate }
        func cancel() { onUpdate = nil }
        func report(_ path: NetworkPath) {
            let deliver = onUpdate
            DispatchQueue.global().async { deliver?(path) }
        }
    }

    // MARK: - The monitor

    func testWhatEachPathReportMeans() {
        XCTAssertNil(ConnectivityMonitor.event(from: .unknown, to: wifi), "the first report only sets the state")
        XCTAssertEqual(ConnectivityMonitor.event(from: .unknown, to: noNetwork), .wentOffline)
        XCTAssertEqual(ConnectivityMonitor.event(from: wifi, to: noNetwork), .wentOffline)
        XCTAssertEqual(ConnectivityMonitor.event(from: noNetwork, to: cellular), .cameOnline)
        XCTAssertEqual(ConnectivityMonitor.event(from: wifi, to: cellular), .pathChanged)
        XCTAssertNil(ConnectivityMonitor.event(from: wifi, to: wifi))
        XCTAssertNil(ConnectivityMonitor.event(from: noNetwork, to: noNetwork))
    }

    func testTheMonitorFollowsThePathAndTellsItsObservers() {
        var now = Date(timeIntervalSince1970: 1_000)
        let monitor = ConnectivityMonitor(source: nil, now: { now })
        let log = EventLog()
        let observation = monitor.observe { log.events.append($0) }
        XCTAssertTrue(monitor.isOnline, "nothing is held back before the first report")

        monitor.apply(wifi)
        monitor.apply(noNetwork)
        XCTAssertFalse(monitor.isOnline)
        XCTAssertEqual(monitor.offlineSince, now)
        now = now.addingTimeInterval(120)
        monitor.apply(cellular)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertNil(monitor.offlineSince)
        monitor.apply(wifi)
        XCTAssertEqual(log.events, [.wentOffline, .cameOnline, .pathChanged])
        withExtendedLifetime(observation) {}
    }

    func testReportsFromTheSystemQueueReachTheMonitor() async {
        let source = ScriptedPathSource()
        let monitor = ConnectivityMonitor(source: source)
        source.report(noNetwork)
        let offline = await eventually { !monitor.isOnline }
        XCTAssertTrue(offline)
        source.report(wifi)
        let online = await eventually { monitor.isOnline }
        XCTAssertTrue(online)
    }

    func testWaitingForTheNetworkEndsWhenItIsBackOrTheWaitIsCancelled() async throws {
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(noNetwork)
        let log = EventLog()
        let waiter = Task { await monitor.waitUntilOnline(); log.done = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(log.done)
        monitor.apply(wifi)
        let resumed = await eventually { log.done }
        XCTAssertTrue(resumed)

        monitor.apply(noNetwork)
        let cancelled = Task { await monitor.waitUntilOnline(); log.cancelled = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(log.cancelled)
        cancelled.cancel()
        let ended = await eventually { log.cancelled }
        XCTAssertTrue(ended)
        XCTAssertFalse(monitor.isOnline)
        _ = waiter
    }

    // MARK: - What the capsule says

    private func inputs(down: Bool, syncing: Bool = false, online: Bool = true,
                        visible: Bool = true) -> ConnectionDisplayInputs {
        ConnectionDisplayInputs(down: down, syncing: syncing, online: online, visible: visible)
    }

    func testADropSaysReconnectingAfterASecondThenOfflineThenBackOnline() {
        var tracker = ConnectionDisplayTracker()
        let start = Date(timeIntervalSince1970: 0)

        var result = tracker.update(inputs(down: true), now: start)
        XCTAssertEqual(result.display, .none)
        XCTAssertEqual(result.nextAt, start + 1)
        result = tracker.update(inputs(down: true), now: start + 1)
        XCTAssertEqual(result.display, .reconnecting)
        XCTAssertEqual(result.nextAt, start + 10)
        result = tracker.update(inputs(down: true), now: start + 10)
        XCTAssertEqual(result.display, .offline)

        result = tracker.update(inputs(down: false), now: start + 120)
        XCTAssertEqual(result.display, .backOnline)
        XCTAssertEqual(result.nextAt, start + 122)
        result = tracker.update(inputs(down: false), now: start + 122)
        XCTAssertEqual(result.display, .none)
    }

    func testNoNetworkIsOfflineAfterTheFirstSecond() {
        var tracker = ConnectionDisplayTracker()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(tracker.update(inputs(down: true, online: false), now: start).display, .none)
        XCTAssertEqual(tracker.update(inputs(down: true, online: false), now: start + 1).display, .offline)
    }

    func testAFlapUnderASecondShowsNothing() {
        var tracker = ConnectionDisplayTracker()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(tracker.update(inputs(down: true, online: false), now: start).display, .none)
        let back = tracker.update(inputs(down: false), now: start + 0.4)
        XCTAssertEqual(back.display, .none, "no \"Back online\" for what was never shown")
        XCTAssertNil(back.nextAt)
    }

    func testTheFirstRefreshAfterAnOutageSaysUpdating() {
        var tracker = ConnectionDisplayTracker()
        let start = Date(timeIntervalSince1970: 0)
        _ = tracker.update(inputs(down: true, online: false), now: start)
        XCTAssertEqual(tracker.update(inputs(down: true, online: false), now: start + 2).display, .offline)
        XCTAssertEqual(tracker.update(inputs(down: false, syncing: true), now: start + 30).display, .updating)
        XCTAssertEqual(tracker.update(inputs(down: false), now: start + 31).display, .backOnline)
    }

    func testTimeInTheBackgroundDoesNotCount() {
        var tracker = ConnectionDisplayTracker()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(tracker.update(inputs(down: true, visible: false), now: start).display, .none)
        XCTAssertEqual(tracker.update(inputs(down: true, visible: false), now: start + 60).display, .none)
        XCTAssertEqual(tracker.update(inputs(down: true), now: start + 61).display, .none)
        XCTAssertEqual(tracker.update(inputs(down: true), now: start + 62).display, .reconnecting)
    }

    func testTheAppsLinkStateFollowsThePulseTheNetworkAndTheSockets() async {
        let monitor = ConnectivityMonitor(source: nil)
        monitor.apply(wifi)
        let status = LinkStatus(connectivity: monitor)

        status.pulseFailed(unreachable: true)
        XCTAssertTrue(status.inputs.down)
        status.pulseSucceeded(at: Date(timeIntervalSince1970: 500))
        XCTAssertFalse(status.inputs.down)
        XCTAssertEqual(status.lastContact, Date(timeIntervalSince1970: 500))
        status.pulseFailed(unreachable: false)
        XCTAssertFalse(status.inputs.down, "a server that answered with an error is up")

        let screen = ObjectIdentifier(self)
        status.setStream(screen, down: true)
        XCTAssertTrue(status.inputs.down)
        status.setStream(screen, down: false)
        XCTAssertFalse(status.inputs.down)

        monitor.apply(noNetwork)
        XCTAssertTrue(status.inputs.down)
        XCTAssertFalse(status.inputs.online)
        let offline = await eventually(timeout: 4) { status.display == .offline }
        XCTAssertTrue(offline, "no network: \"Offline\" after a second")

        monitor.apply(wifi)
        let back = await eventually(timeout: 4) { status.display == .backOnline }
        XCTAssertTrue(back)
        let gone = await eventually(timeout: 4) { status.display == .none }
        XCTAssertTrue(gone)
    }

    func testSavedListsDateTheOfflineCapsule() {
        let status = LinkStatus(connectivity: nil)
        status.showingSavedLists(savedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(status.lastContact, Date(timeIntervalSince1970: 100))
        status.pulseSucceeded(at: Date(timeIntervalSince1970: 900))
        status.showingSavedLists(savedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(status.lastContact, Date(timeIntervalSince1970: 900), "an older copy never makes it look older")
    }
}
