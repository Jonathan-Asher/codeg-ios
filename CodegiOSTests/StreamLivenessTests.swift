import XCTest
@testable import Codeg

/// The event socket's liveness checks (1.3.23): the pong deadline, the health
/// probe that tells a slow server from a dead link, the open timeout and a
/// network change that checks the socket instead of dropping it. The rules on
/// their own, then ``EventStream`` on a scripted socket and a manual clock.
final class StreamLivenessTests: XCTestCase {

    // MARK: - The rules

    func testTheDeadlineFollowsTheRoundTripWithinItsBounds() {
        XCTAssertEqual(StreamLiveness.deadline(p95: nil, floor: 8), 8)
        XCTAssertEqual(StreamLiveness.deadline(p95: 1, floor: 8), 8)
        XCTAssertEqual(StreamLiveness.deadline(p95: 5, floor: 8), 15)
        XCTAssertEqual(StreamLiveness.deadline(p95: 20, floor: 8), 30)
        XCTAssertNil(StreamLiveness.p95([]))
        XCTAssertEqual(StreamLiveness.p95((1...19).map(Double.init) + [100]), 19)
    }

    func testAQuietSocketIsPingedAndAMissedPongIsProbedThenGivenUp() {
        var live = StreamLiveness(now: 0)
        XCTAssertEqual(live.nextCheckAt(), 10, "opening: the ready frame is due within 10 s")
        live.onInbound(now: 1, isPong: false)
        XCTAssertEqual(live.nextCheckAt(), 21, "idle: a ping after 20 s of quiet")
        live.streaming = true
        XCTAssertEqual(live.nextCheckAt(), 6, "a turn streaming: after 5 s")
        XCTAssertEqual(live.onCheck(now: 6), .ping)
        XCTAssertEqual(live.nextCheckAt(), 14, "the pong is due within 8 s")
        XCTAssertEqual(live.onCheck(now: 13.9), .wait)
        XCTAssertEqual(live.onCheck(now: 14), .probe)
        XCTAssertEqual(live.onProbeResult(now: 14.3, outcome: .unreachable, elapsed: 0.3), .dead)
    }

    func testAServerThatAnswersTheProbeKeepsItsSocketTwiceAtMost() {
        var live = StreamLiveness(now: 0)
        live.onInbound(now: 0, isPong: false)
        live.streaming = true
        XCTAssertEqual(live.onCheck(now: 5), .ping)
        XCTAssertEqual(live.onCheck(now: 13), .probe)
        XCTAssertEqual(live.onProbeResult(now: 13.5, outcome: .alive, elapsed: 0.5), .extend)
        XCTAssertEqual(live.onCheck(now: 21.4), .wait)
        XCTAssertEqual(live.onCheck(now: 21.5), .probe)
        XCTAssertEqual(live.onProbeResult(now: 22, outcome: .alive, elapsed: 0.5), .extend)
        XCTAssertEqual(live.onCheck(now: 30), .dead, "after two extensions the socket goes")
    }

    func testAnyFrameSettlesThePingAndAPongIsARoundTrip() {
        var live = StreamLiveness(now: 0)
        live.onInbound(now: 0, isPong: false)
        XCTAssertEqual(live.onCheck(now: 20), .ping)
        live.onInbound(now: 21, isPong: false)
        XCTAssertFalse(live.pingOutstanding)
        XCTAssertEqual(live.onCheck(now: 30), .wait)
        XCTAssertEqual(live.onCheck(now: 41), .ping)
        live.onInbound(now: 42.5, isPong: true)
        XCTAssertEqual(live.samples, [1.5])
    }

    func testANetworkChangeChecksTheSocketWithinFourSeconds() {
        var live = StreamLiveness(now: 0)
        live.onInbound(now: 0, isPong: false)
        XCTAssertTrue(live.onWake(now: 3), "a ping goes at once")
        XCTAssertEqual(live.nextCheckAt(), 7)
        XCTAssertFalse(live.onWake(now: 4), "one just sent keeps its deadline")
        XCTAssertEqual(live.onCheck(now: 7), .probe)
    }

    func testASocketThatNeverOpensIsProbedAfterTenSeconds() {
        var live = StreamLiveness(now: 0)
        XCTAssertEqual(live.onCheck(now: 9.9), .wait)
        XCTAssertEqual(live.onCheck(now: 10), .probe)
        XCTAssertEqual(live.onProbeResult(now: 10.2, outcome: .unreachable, elapsed: 0.2), .dead)
    }

    // MARK: - The socket

    /// Stands in for `URLSessionWebSocketTask`: frames and pongs by hand.
    private final class FakeSocket: EventSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
        private var pongs: [@Sendable (Error?) -> Void] = []
        private var pings = 0
        private var cancelled = false

        var pingCount: Int { lock.withLock { pings } }
        var isCancelled: Bool { lock.withLock { cancelled } }

        func resume() {}
        func send(text: String) {}

        func receive(_ completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
            lock.withLock { receiver = completion }
        }

        func sendPing(_ pongReceived: @escaping @Sendable (Error?) -> Void) {
            lock.withLock {
                pongs.append(pongReceived)
                pings += 1
            }
        }

        func cancel() { lock.withLock { cancelled = true } }

        /// The server sends a text frame.
        func deliver(_ text: String) {
            let next = lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
                let current = receiver
                receiver = nil
                return current
            }
            next?(.success(.string(text)))
        }

        /// The pings so far get their pongs (`error` nil) or fail.
        func answerPings(error: Error? = nil) {
            let waiting = lock.withLock { () -> [@Sendable (Error?) -> Void] in
                let current = pongs
                pongs = []
                return current
            }
            waiting.forEach { $0(error) }
        }
    }

    /// Time that moves only when the test says.
    private final class ManualClock: LivenessClock, @unchecked Sendable {
        private final class Timer: LivenessTimer, @unchecked Sendable {
            let at: TimeInterval
            let work: @Sendable () -> Void
            private let lock = NSLock()
            private var cancelled = false
            init(at: TimeInterval, work: @escaping @Sendable () -> Void) {
                self.at = at
                self.work = work
            }
            var isCancelled: Bool { lock.withLock { cancelled } }
            func cancel() { lock.withLock { cancelled = true } }
        }

        private let lock = NSLock()
        private var current: TimeInterval = 0
        private var timers: [Timer] = []

        var now: TimeInterval { lock.withLock { current } }

        func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any LivenessTimer {
            lock.withLock {
                let timer = Timer(at: current + delay, work: work)
                timers.append(timer)
                return timer
            }
        }

        /// Move time on, running each timer that falls due, in order.
        func advance(by seconds: TimeInterval) {
            let target = now + seconds
            while let due = lock.withLock({ () -> Timer? in
                timers.removeAll { $0.isCancelled }
                guard let soonest = timers.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) else { return nil }
                timers.removeAll { $0 === soonest }
                current = max(current, soonest.at)
                return soonest
            }) {
                due.work()
            }
            lock.withLock { current = target }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    /// What a stream emitted.
    private final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: String?
        private var ready = 0
        var closedReason: String? { lock.withLock { reason } }
        var readyCount: Int { lock.withLock { ready } }

        init(_ stream: EventStream) {
            Task { [weak self] in
                for await frame in stream.frames {
                    guard let self else { return }
                    switch frame {
                    case .ready: self.lock.withLock { self.ready += 1 }
                    case .closed(let reason): self.lock.withLock { self.reason = reason ?? "closed" }
                    default: break
                    }
                }
            }
        }
    }

    private let readyFrame = #"{"channel": "__ready__", "payload": null}"#

    private func makeStream(probe: @escaping EventStream.Probe) -> (EventStream, FakeSocket, ManualClock, FrameLog) {
        let socket = FakeSocket()
        let clock = ManualClock()
        let stream = EventStream(baseURL: URL(string: "http://box.test")!, token: "t",
                                 makeSocket: { _, _ in socket }, clock: clock, probe: probe)
        let log = FrameLog(stream)
        return (stream, socket, clock, log)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testASocketThatStopsAnsweringIsClosedAfterItsDeadlineAndAFailedProbe() async {
        let probes = Counter()
        let (stream, socket, clock, log) = makeStream { probes.increment(); return .unreachable }
        stream.start()
        socket.deliver(readyFrame)
        let ready = await waitFor { log.readyCount == 1 }
        XCTAssertTrue(ready)
        stream.setStreaming(true)

        clock.advance(by: 5)
        XCTAssertEqual(socket.pingCount, 1, "a ping after 5 s of quiet while a turn streams")
        clock.advance(by: 7.9)
        XCTAssertEqual(probes.value, 0)
        XCTAssertNil(log.closedReason)

        clock.advance(by: 0.2)
        let closed = await waitFor { log.closedReason != nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(log.closedReason, EventStream.noAnswerReason)
        XCTAssertTrue(socket.isCancelled)
        XCTAssertEqual(probes.value, 1)
    }

    func testASlowServerThatAnswersTheProbeKeepsItsSocket() async throws {
        let (stream, socket, clock, log) = makeStream { .alive }
        stream.start()
        socket.deliver(readyFrame)
        stream.setStreaming(true)

        clock.advance(by: 5)
        clock.advance(by: 8)
        let repinged = await waitFor { socket.pingCount == 2 }
        XCTAssertTrue(repinged, "the socket is kept and pinged again")
        try await Task.sleep(for: .milliseconds(50))
        socket.answerPings()
        clock.advance(by: 10)
        XCTAssertNil(log.closedReason)
        XCTAssertFalse(socket.isCancelled)
        XCTAssertEqual(socket.pingCount, 3, "the next ping after quiet, as usual")
    }

    func testAFrameCountsAsAnAnswer() async {
        let probes = Counter()
        let (stream, socket, clock, log) = makeStream { probes.increment(); return .unreachable }
        stream.start()
        socket.deliver(readyFrame)
        stream.setStreaming(true)
        clock.advance(by: 5)
        socket.deliver(#"{"type": "pong"}"#)
        clock.advance(by: 9)
        XCTAssertEqual(probes.value, 0)
        XCTAssertNil(log.closedReason)
    }

    func testASocketThatNeverOpensIsClosedAfterTenSeconds() async {
        let (stream, socket, clock, log) = makeStream { .unreachable }
        stream.start()
        clock.advance(by: 9.9)
        XCTAssertNil(log.closedReason)
        clock.advance(by: 0.2)
        let closed = await waitFor { log.closedReason != nil }
        XCTAssertTrue(closed)
        XCTAssertTrue(socket.isCancelled)
    }

    func testANetworkChangeChecksTheSocketWithinFourSeconds() async {
        let probes = Counter()
        let (stream, socket, clock, log) = makeStream { probes.increment(); return .unreachable }
        stream.start()
        socket.deliver(readyFrame)
        stream.checkLink()
        XCTAssertEqual(socket.pingCount, 1, "pinged at once, not dropped")
        clock.advance(by: 3.9)
        XCTAssertEqual(probes.value, 0)
        clock.advance(by: 0.2)
        let closed = await waitFor { log.closedReason != nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(probes.value, 1)
    }

    func testAPingThatFailsEndsTheStreamAtOnce() async {
        let (stream, socket, clock, log) = makeStream { .alive }
        stream.start()
        socket.deliver(readyFrame)
        clock.advance(by: 20)
        XCTAssertEqual(socket.pingCount, 1)
        socket.answerPings(error: URLError(.networkConnectionLost))
        let closed = await waitFor { log.closedReason != nil }
        XCTAssertTrue(closed)
        XCTAssertTrue(socket.isCancelled)
    }

    func testAClosedStreamStopsChecking() {
        let (stream, socket, clock, _) = makeStream { .unreachable }
        stream.start()
        socket.deliver(readyFrame)
        stream.close()
        XCTAssertTrue(socket.isCancelled)
        clock.advance(by: 120)
        XCTAssertEqual(socket.pingCount, 0)
    }
}
