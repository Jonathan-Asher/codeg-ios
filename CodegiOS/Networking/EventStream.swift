import Foundation

// MARK: - WebSocket attach-protocol messages

/// Client→server attach-protocol message (Rust `ClientMsg`, tagged `action`).
/// Encode-only; snake_case wire keys are spelled explicitly (request encoder
/// does not convert keys).
enum WSClientMessage: Encodable, Sendable {
    case attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?)
    case detach(subscriptionId: String)
    case ping
    /// Who is looking (codeg fork `crate::presence`): this client is visible,
    /// focused, how long since the user touched it, and which sessions it shows.
    case presence(visible: Bool, focused: Bool, idleSecs: UInt64, conversationIds: [Int])

    private enum CodingKeys: String, CodingKey {
        case action
        case subscriptionId = "subscription_id"
        case connectionId = "connection_id"
        case sinceSeq = "since_seq"
        case visible, focused
        case idleSecs = "idle_secs"
        case conversationIds = "conversation_ids"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attach(let sub, let conn, let since):
            try c.encode("attach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
            try c.encode(conn, forKey: .connectionId)
            try c.encodeIfPresent(since, forKey: .sinceSeq)
        case .detach(let sub):
            try c.encode("detach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
        case .ping:
            try c.encode("ping", forKey: .action)
        case .presence(let visible, let focused, let idleSecs, let conversationIds):
            try c.encode("presence", forKey: .action)
            try c.encode(visible, forKey: .visible)
            try c.encode(focused, forKey: .focused)
            try c.encode(idleSecs, forKey: .idleSecs)
            try c.encode(conversationIds, forKey: .conversationIds)
        }
    }
}

/// Server→client attach-protocol message (Rust `ServerMsg`, tagged `type`).
/// Decoded with the shared `.convertFromSnakeCase` decoder, so keys are
/// camelCase here.
enum WSServerMessage: Decodable, Sendable {
    case snapshot(LiveSessionSnapshot)
    case replay([EventEnvelope])
    case event(EventEnvelope)
    case detached(reason: String)
    case pong
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, snapshot, events, envelope, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot":
            self = .snapshot(try c.decode(LiveSessionSnapshot.self, forKey: .snapshot))
        case "replay":
            self = .replay(try c.decodeIfPresent([EventEnvelope].self, forKey: .events) ?? [])
        case "event":
            self = .event(try c.decode(EventEnvelope.self, forKey: .envelope))
        case "detached":
            self = .detached(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "pong":
            self = .pong
        default:
            self = .unknown
        }
    }
}

// MARK: - The socket under an EventStream

/// The WebSocket an ``EventStream`` runs over: `URLSessionWebSocketTask` in the
/// app, a scripted one in the unit tests.
protocol EventSocket: AnyObject {
    func resume()
    func send(text: String)
    func receive(_ completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func sendPing(_ pongReceived: @escaping @Sendable (Error?) -> Void)
    func cancel()
}

/// The app's socket.
final class URLSessionEventSocket: EventSocket {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() { task.resume() }

    func send(text: String) {
        task.send(.string(text)) { _ in }
    }

    func receive(_ completion: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive { result in completion(result) }
    }

    func sendPing(_ pongReceived: @escaping @Sendable (Error?) -> Void) {
        task.sendPing { error in pongReceived(error) }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - Time for the liveness checks

/// A timer from a ``LivenessClock``.
protocol LivenessTimer: AnyObject {
    func cancel()
}

/// Time and timers for the event socket's liveness checks; the unit tests
/// drive a manual one.
protocol LivenessClock: AnyObject {
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }
    /// Run `work` once after `delay` seconds, unless cancelled first.
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any LivenessTimer
}

/// The app's clock: uptime, and timers on a utility queue.
final class SystemLivenessClock: LivenessClock, @unchecked Sendable {
    static let shared = SystemLivenessClock()

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> any LivenessTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return DispatchLivenessTimer(item: item)
    }
}

private final class DispatchLivenessTimer: LivenessTimer, @unchecked Sendable {
    let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

// MARK: - EventStream

/// A live WebSocket connection to `/ws/events`. Emits decoded frames on
/// `frames`. Lifecycle: `start()` → await `.ready` → `attach(...)` → consume
/// `.event` frames → `close()`. Reconnection is the caller's responsibility
/// (Phase 1 reconnects by creating a fresh stream).
///
/// The stream notices a dead socket by itself (see ``StreamLiveness``): no
/// ready frame within 10 s of opening, or no pong to a ping within the
/// deadline and no answer to a health request either, ends it with a
/// `.closed` frame, as a socket error does.
final class EventStream: @unchecked Sendable {
    enum Frame: Sendable {
        case ready
        case snapshot(LiveSessionSnapshot)
        case replay([EventEnvelope])
        case event(EventEnvelope)
        case detached(reason: String)
        case pong
        case closed(reason: String?)
        /// The frame just delivered was shrunk by the server to fit this socket
        /// (`frame_cut`): it is an incomplete copy, and the transcript over HTTP
        /// holds the whole thing. Follows that frame.
        case frameCut
    }

    /// Why a socket the server stopped answering was closed.
    static let noAnswerReason = "The server stopped answering."

    /// How the stream checks whether the server is there when a pong is late:
    /// a health request over HTTP.
    typealias Probe = @Sendable () async -> StreamLiveness.ProbeOutcome

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let url: URL
    private let token: String
    private let makeSocket: (URL, [String]) -> any EventSocket
    private let clock: any LivenessClock
    private let probe: Probe
    private let lock = NSLock()
    private var socket: (any EventSocket)?
    private var isClosed = false
    /// Guarded by `lock`.
    private var liveness: StreamLiveness
    private var checkTimer: (any LivenessTimer)?

    /// Dedicated session for the long-lived event socket. `URLSession.shared`'s
    /// default `timeoutIntervalForRequest` (60s) is an *inactivity* timeout that,
    /// on a WebSocket, fires whenever the agent goes quiet — a long tool call, a
    /// pause for a permission prompt — and tears down a perfectly healthy stream,
    /// surfacing a spurious error even though the server is fine. A live agent
    /// owns the pacing, so the socket must be allowed to sit idle indefinitely;
    /// genuine death is instead detected by the liveness checks (pings with a
    /// pong deadline). (The browser WebSocket the web client uses has no such
    /// idle timeout — this brings parity.)
    static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 604_800   // 7 days — effectively no idle timeout
        cfg.timeoutIntervalForResource = 604_800
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// For the health probe of a late pong: fails at once without a network
    /// instead of waiting for one. The liveness check gives the probe up after
    /// its own timeout regardless.
    static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = StreamLiveness.probeCeiling
        cfg.timeoutIntervalForResource = StreamLiveness.probeCeiling
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// The largest frame a socket accepts, in bytes. `URLSessionWebSocketTask`
    /// defaults to 1 MiB, and codeg sends bigger frames: a `background_activity`
    /// event re-sends a whole growing out-of-turn turn on every update (1.3 to
    /// 1.5 MB were seen), and an attach snapshot carries a long turn's entire
    /// live message. Past the limit the receive fails with EMSGSIZE ("Message
    /// too long") and the socket is torn down, so this is set well above
    /// anything the server sends.
    static let maximumMessageSize = 64 * 1024 * 1024

    /// Make a socket task with the limits every codeg socket needs.
    static func makeTask(session: URLSession, url: URL, protocols: [String]) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = maximumMessageSize
        return task
    }

    convenience init(baseURL: URL, token: String, session: URLSession = EventStream.streamSession) {
        self.init(
            baseURL: baseURL, token: token,
            makeSocket: { url, protocols in
                URLSessionEventSocket(task: EventStream.makeTask(session: session, url: url, protocols: protocols))
            },
            clock: SystemLivenessClock.shared,
            probe: EventStream.healthProbe(baseURL: baseURL, token: token)
        )
    }

    /// A stream over sockets from `makeSocket`, timed by `clock`, asking
    /// `probe` when a pong is late (the unit tests' scripted socket and clock).
    init(baseURL: URL, token: String,
         makeSocket: @escaping (URL, [String]) -> any EventSocket,
         clock: any LivenessClock, probe: @escaping Probe) {
        self.token = token
        self.url = EventStream.websocketURL(from: baseURL)
        self.makeSocket = makeSocket
        self.clock = clock
        self.probe = probe
        self.liveness = StreamLiveness(now: clock.now)
        var captured: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    /// `POST /api/health` without waiting for a network.
    static func healthProbe(baseURL: URL, token: String) -> Probe {
        {
            let client = CodegClient(baseURL: baseURL, token: token, session: EventStream.probeSession)
            do {
                _ = try await client.send("health", body: EmptyBody())
                return .alive
            } catch APIError.unauthorized {
                return .unauthorized
            } catch {
                return .unreachable
            }
        }
    }

    /// Extra subprotocol that declares this socket an iOS client (codeg fork
    /// presence: a phone never counts as someone at the desk, but does count
    /// as looking at the session it shows). The server still selects only
    /// `codeg-events`, so servers without presence ignore it.
    static let iosClientProtocol = "codeg-client.ios"

    /// Extra subprotocol that tells the server how large a frame this socket
    /// takes. An iOS client that sends none is held to the 1 MiB default of
    /// `URLSessionWebSocketTask`, and the server shrinks bigger frames for it.
    static let maxFrameProtocol = "codeg-max-frame.\(maximumMessageSize)"

    /// Everything the event socket offers when it connects.
    static func protocols(token: String) -> [String] {
        ["codeg-events", "codeg-token.\(base64URLNoPad(token))", iosClientProtocol, maxFrameProtocol]
    }

    func start() {
        let newSocket = makeSocket(url, Self.protocols(token: token))
        lock.lock()
        socket = newSocket
        liveness.reset(now: clock.now)
        lock.unlock()
        newSocket.resume()
        receiveLoop()
        scheduleCheck()
    }

    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64? = nil) {
        send(.attach(subscriptionId: subscriptionId, connectionId: connectionId, sinceSeq: sinceSeq))
    }

    func detach(subscriptionId: String) { send(.detach(subscriptionId: subscriptionId)) }

    func ping() { send(.ping) }

    /// Report this client's presence (see ``WSClientMessage/presence``).
    func reportPresence(visible: Bool, focused: Bool, idleSecs: UInt64 = 0, conversationIds: [Int]) {
        send(.presence(visible: visible, focused: focused, idleSecs: idleSecs, conversationIds: conversationIds))
    }

    /// A turn streams on screen: ping after 5 s of quiet instead of 20 s.
    func setStreaming(_ streaming: Bool) {
        lock.lock()
        liveness.streaming = streaming
        lock.unlock()
        scheduleCheck()
    }

    /// The phone's network changed (Wi-Fi to LTE) or came back: the socket
    /// must answer within 4 s, or it is replaced. Not dropped outright: a
    /// tunnelled connection often survives the switch.
    func checkLink() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        let mustPing = liveness.onWake(now: clock.now)
        let current = socket
        lock.unlock()
        if mustPing { sendPing(current) }
        scheduleCheck()
    }

    func close() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        let current = socket
        checkTimer?.cancel()
        checkTimer = nil
        lock.unlock()
        guard !alreadyClosed else { return }
        current?.cancel()
        continuation.finish()
    }

    // MARK: - Private

    private func send(_ message: WSClientMessage) {
        guard let data = try? CodegJSON.encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); let current = socket; lock.unlock()
        current?.send(text: text)
    }

    private func receiveLoop() {
        lock.lock(); let current = socket; lock.unlock()
        current?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(reason: error.localizedDescription)
            case .success(let message):
                self.lock.lock()
                let closed = self.isClosed
                if !closed { self.liveness.onInbound(now: self.clock.now, isPong: false) }
                self.lock.unlock()
                self.handle(message)
                if !closed { self.receiveLoop() }
            }
        }
    }

    private func finish(reason: String?) {
        lock.lock()
        let already = isClosed
        isClosed = true
        checkTimer?.cancel()
        checkTimer = nil
        lock.unlock()
        guard !already else { return }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }

    /// The socket is dead: report it, then let it go.
    private func die(reason: String) {
        lock.lock(); let current = socket; lock.unlock()
        finish(reason: reason)
        current?.cancel()
    }

    // MARK: - Liveness

    /// Arm the check timer for when ``StreamLiveness`` next needs a look.
    /// Frames arriving in between need no new timer: a check that comes too
    /// early only waits again.
    private func scheduleCheck() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        checkTimer?.cancel()
        let delay = liveness.nextCheckAt() - clock.now
        checkTimer = clock.schedule(after: max(0, delay)) { [weak self] in self?.runCheck() }
    }

    private func runCheck() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        let now = clock.now
        let action = liveness.onCheck(now: now)
        let current = socket
        lock.unlock()
        switch action {
        case .wait:
            scheduleCheck()
        case .ping:
            sendPing(current)
            scheduleCheck()
        case .probe:
            runProbe(startedAt: now)
            scheduleCheck()
        case .dead:
            die(reason: Self.noAnswerReason)
        }
    }

    /// Send a WebSocket ping. Its pong settles the check; an error means the
    /// socket is gone.
    private func sendPing(_ target: (any EventSocket)?) {
        target?.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.die(reason: error.localizedDescription)
                return
            }
            self.lock.lock()
            if !self.isClosed { self.liveness.onInbound(now: self.clock.now, isPong: true) }
            self.lock.unlock()
        }
    }

    /// A pong is overdue: ask the server over HTTP whether it is there.
    private func runProbe(startedAt: TimeInterval) {
        let probe = self.probe
        Task { [weak self] in
            let outcome = await probe()
            guard let self else { return }
            self.lock.lock()
            guard !self.isClosed else { self.lock.unlock(); return }
            let now = self.clock.now
            let verdict = self.liveness.onProbeResult(now: now, outcome: outcome, elapsed: now - startedAt)
            let current = self.socket
            self.lock.unlock()
            switch verdict {
            case .extend:
                // A write is what makes a dead connection fail fast.
                self.sendPing(current)
                self.scheduleCheck()
            case .dead:
                self.die(reason: EventStream.noAnswerReason)
            case .ignored:
                break
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        decode(data)
    }

    private func decode(_ data: Data) {
        for frame in Self.frames(from: data) { continuation.yield(frame) }
    }

    /// The frames one text message carries: none (the legacy firehose, which
    /// is ignored but for its ready signal), one, or one followed by
    /// ``Frame/frameCut`` when the server shrank it.
    static func frames(from data: Data) -> [Frame] {
        // The socket multiplexes the legacy firehose ({channel, payload}) with
        // the attach protocol ({type, ...}). Route on which key is present.
        var cut = false
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let channel = obj["channel"] as? String {
                return channel == "__ready__" ? [.ready] : [] // other legacy global events are ignored
            }
            guard obj["type"] is String else { return [] }
            cut = (obj["frame_cut"] as? Bool) == true
        }
        guard let message = try? CodegJSON.decoder.decode(WSServerMessage.self, from: data) else { return [] }
        let frame: Frame
        switch message {
        case .snapshot(let snapshot): frame = .snapshot(snapshot)
        case .replay(let events): frame = .replay(events)
        case .event(let envelope): frame = .event(envelope)
        case .detached(let reason): frame = .detached(reason: reason)
        case .pong: frame = .pong
        case .unknown: return []
        }
        return cut ? [frame, .frameCut] : [frame]
    }

    // MARK: - Helpers

    static func base64URLNoPad(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func websocketURL(from baseURL: URL) -> URL {
        // Append the endpoint to the configured server URL so deployments under
        // a reverse-proxy path (e.g. https://host/codeg) keep their base path.
        let endpointURL = baseURL
            .appendingPathComponent("ws")
            .appendingPathComponent("events")
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)
        components?.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        components?.query = nil
        return components?.url ?? endpointURL
    }
}
