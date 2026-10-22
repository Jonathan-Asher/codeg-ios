import Foundation

/// Dead-socket detection for the event socket that tells a dead link from a
/// slow server, with the rules of codeg web's `src/lib/transport/liveness.ts`.
///
/// A socket iOS still holds open can be dead: the phone left the network, the
/// tunnel dropped, the box went to sleep. Only a ping tells. But a pong can
/// also be late because the server is busy, or because it queues behind a
/// large frame on a slow link, and tearing a live socket down then costs a
/// reconnect on a server that is already struggling. So:
///
/// - **Deadline.** A pong is due within `clamp(3 × p95, 8 s, 30 s)` of its
///   ping, the p95 taken over recent pong delays and health-probe durations.
/// - **Probe before giving up.** A pong past its deadline triggers a health
///   request over HTTP. If the server answers, the socket is kept and the
///   deadline extended (twice at most); if not, the socket is dead.
/// - **Streaming.** While a turn streams on screen, a ping goes after 5 s of
///   quiet; otherwise after 20 s.
/// - **Opening.** A socket must hear from the server (its ready frame) within
///   10 s of opening, behind the same probe, so a connect that hangs (a
///   tailnet address whose machine is off) doesn't wait forever.
/// - **Network change.** Wi-Fi to LTE, or the network back: the socket must
///   answer within 4 s. A tunnelled connection often survives the switch, so
///   it is checked rather than dropped.
///
/// Pure: ``EventStream`` feeds it clock readings and frames, and acts on what
/// it returns. Times are seconds on a monotonic clock.
struct StreamLiveness {
    /// Quiet before a ping: idle, and while a turn streams on screen.
    static let idleQuiet: TimeInterval = 20
    static let streamQuiet: TimeInterval = 5
    /// Pong deadline floor, and the floor after a network change.
    static let deadlineFloor: TimeInterval = 8
    static let wakeFloor: TimeInterval = 4
    static let ceiling: TimeInterval = 30
    /// How long a new socket has to hear from the server.
    static let openTimeout: TimeInterval = 10
    /// Health-probe timeout floor and ceiling.
    static let probeFloor: TimeInterval = 8
    static let probeCeiling: TimeInterval = 20
    /// Slack past a probe's own timeout before it is given up on regardless.
    static let probeSafety: TimeInterval = 1
    /// Deadline extensions granted by answered probes, per ping.
    static let maxExtensions = 2
    /// Round-trip samples kept.
    static let sampleCount = 16

    enum Action: Equatable {
        /// Send a ping now.
        case ping
        /// The pong is overdue: ask the server over HTTP whether it is there.
        case probe
        /// Give the socket up.
        case dead
        case wait
    }

    /// What the health probe found.
    enum ProbeOutcome: Equatable, Sendable {
        case alive
        case unauthorized
        /// A network error or a status that isn't success.
        case unreachable
        case timeout
    }

    enum ProbeVerdict: Equatable {
        /// The server answered: keep the socket, ping it again, and wait out
        /// the new deadline.
        case extend
        case dead
        /// The ping settled while the probe ran.
        case ignored
    }

    private struct PendingPing {
        var sentAt: TimeInterval
        var dueAt: TimeInterval
        /// Set while a health probe for this ping is in flight.
        var probeStartedAt: TimeInterval?
        var probeTimeout: TimeInterval = 0
        var extensions = 0
    }

    /// Recent round trips, newest last. Kept across sockets.
    private(set) var samples: [TimeInterval] = []
    private var lastInboundAt: TimeInterval
    private var ping: PendingPing?
    /// The socket has heard from the server since it opened.
    private var heard = false
    /// A turn streams on screen (see ``streamQuiet``).
    var streaming = false

    init(now: TimeInterval) {
        lastInboundAt = now
        ping = Self.openCheck(now: now)
    }

    /// A fresh socket: restart the clock and wait for its first frame; keep
    /// the round-trip history.
    mutating func reset(now: TimeInterval) {
        lastInboundAt = now
        heard = false
        ping = Self.openCheck(now: now)
    }

    /// Opening is checked like a ping whose pong is the ready frame.
    private static func openCheck(now: TimeInterval) -> PendingPing {
        PendingPing(sentAt: now, dueAt: now + openTimeout)
    }

    // MARK: Deadlines

    /// 95th percentile by nearest rank, or nil with no samples.
    static func p95(_ samples: [TimeInterval]) -> TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, rank)]
    }

    /// `clamp(3 × p95, floor, ceiling)`; the floor alone with no samples.
    static func deadline(p95: TimeInterval?, floor: TimeInterval, ceiling: TimeInterval = ceiling) -> TimeInterval {
        guard let p95 else { return floor }
        return min(max(3 * p95, floor), max(floor, ceiling))
    }

    /// The pong deadline for a ping sent now.
    func deadline(floor: TimeInterval = deadlineFloor) -> TimeInterval {
        Self.deadline(p95: Self.p95(samples), floor: floor)
    }

    var probeTimeout: TimeInterval {
        Self.deadline(p95: Self.p95(samples), floor: Self.probeFloor, ceiling: Self.probeCeiling)
    }

    var pingOutstanding: Bool { ping != nil }
    var probeInFlight: Bool { ping?.probeStartedAt != nil }

    private var quiet: TimeInterval {
        streaming && heard ? Self.streamQuiet : Self.idleQuiet
    }

    private mutating func addSample(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples.append(seconds)
        if samples.count > Self.sampleCount { samples.removeFirst(samples.count - Self.sampleCount) }
    }

    // MARK: Events

    /// Any frame from the server proves the link alive and settles the ping.
    /// `isPong`: the frame answers our ping, so its delay is a sample.
    mutating func onInbound(now: TimeInterval, isPong: Bool) {
        if let ping, isPong, heard { addSample(now - ping.sentAt) }
        lastInboundAt = now
        heard = true
        ping = nil
    }

    /// When ``onCheck(now:)`` should next be consulted.
    func nextCheckAt() -> TimeInterval {
        guard let ping else { return lastInboundAt + quiet }
        if let started = ping.probeStartedAt {
            return started + ping.probeTimeout + Self.probeSafety
        }
        return ping.dueAt
    }

    mutating func onCheck(now: TimeInterval) -> Action {
        if var pending = ping {
            if let started = pending.probeStartedAt {
                // The probe has its own timeout; this only catches one that
                // never settled at all.
                return now >= started + pending.probeTimeout + Self.probeSafety ? .dead : .wait
            }
            if now < pending.dueAt { return .wait }
            if pending.extensions >= Self.maxExtensions { return .dead }
            pending.probeStartedAt = now
            pending.probeTimeout = probeTimeout
            ping = pending
            return .probe
        }
        if now - lastInboundAt >= quiet {
            ping = PendingPing(sentAt: now, dueAt: now + deadline())
            return .ping
        }
        return .wait
    }

    /// The health probe for the outstanding ping settled after `elapsed`.
    mutating func onProbeResult(now: TimeInterval, outcome: ProbeOutcome, elapsed: TimeInterval) -> ProbeVerdict {
        guard var pending = ping, pending.probeStartedAt != nil else { return .ignored }
        pending.probeStartedAt = nil
        if outcome == .alive || outcome == .timeout { addSample(elapsed) }
        guard outcome == .alive else {
            ping = pending
            return .dead
        }
        pending.extensions += 1
        pending.dueAt = now + deadline()
        ping = pending
        return .extend
    }

    /// The network changed or came back: the socket must answer within the
    /// wake deadline. Returns whether a ping must go out now; a recent one
    /// only has its deadline pulled in, and an older one is replaced, since a
    /// write is what makes a dead connection fail fast.
    mutating func onWake(now: TimeInterval) -> Bool {
        let wakeDeadline = deadline(floor: Self.wakeFloor)
        if var pending = ping {
            // A probe in flight is already deciding, within its own timeout.
            if pending.probeStartedAt != nil { return false }
            // Still opening: the ready frame is what is awaited.
            if !heard {
                pending.dueAt = min(pending.dueAt, now + wakeDeadline)
                ping = pending
                return false
            }
            if now - pending.sentAt < wakeDeadline {
                pending.dueAt = min(pending.dueAt, now + wakeDeadline)
                ping = pending
                return false
            }
        }
        ping = PendingPing(sentAt: now, dueAt: now + wakeDeadline)
        return true
    }
}
