import XCTest
@testable import Codeg

// MARK: - A codeg server behind URLProtocol

/// A codeg HTTP API answered in process. Each test makes its own, on its own
/// host, so tests can't see each other's routes or calls.
final class MockCodegServer: @unchecked Sendable {
    enum Reply {
        /// 200 with this JSON text (`"null"`, `"[]"`, `"\"conn-1\""`, an object…).
        case body(String)
        /// Any status with a JSON body.
        case status(Int, String)
        /// The request fails as the network would (a timeout, a lost connection).
        case fail(URLError.Code)
    }

    struct Call {
        let path: String
        let body: [String: Any]

        var text: String {
            (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    let host = "mock-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var routes: [String: (Call) -> Reply] = [:]
    private var log: [Call] = []

    init() {
        MockURLProtocol.register(self)
        // What every session screen asks for on open.
        on("list_all_folder_details") { _ in .body("[]") }
        on("acp_find_connection_for_conversation") { _ in .body("null") }
        on("acp_prompt") { _ in .body("null") }
    }

    deinit { MockURLProtocol.unregister(host) }

    var client: CodegClient {
        CodegClient(baseURL: URL(string: "http://\(host)")!, token: "test-token", session: Self.session)
    }

    func on(_ path: String, _ reply: @escaping (Call) -> Reply) {
        lock.withLock { routes[path] = reply }
    }

    func calls(_ path: String) -> [Call] {
        lock.withLock { log.filter { $0.path == path } }
    }

    fileprivate func answer(path: String, body: [String: Any]) -> Reply {
        let call = Call(path: path, body: body)
        let route = lock.withLock { () -> ((Call) -> Reply)? in
            log.append(call)
            return routes[path]
        }
        return route?(call) ?? .body("null")
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()
}

final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: MockCodegServer] = [:]

    static func register(_ server: MockCodegServer) { lock.withLock { servers[server.host] = server } }
    static func unregister(_ host: String) { lock.withLock { _ = servers.removeValue(forKey: host) } }
    private static func server(for host: String?) -> MockCodegServer? {
        guard let host else { return nil }
        return lock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = server.answer(path: url.lastPathComponent, body: Self.jsonBody(of: request))
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .body(let text):
            respond(status: 200, text: text, url: url)
        case .status(let status, let text):
            respond(status: status, text: text, url: url)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, text: String, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func jsonBody(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

// MARK: - A scripted event socket

/// Stands in for ``EventStream``: `.ready` on start, and on attach whatever its
/// script says. Tests push further frames, or drop it, by hand.
final class ScriptedStream: SessionEventStream, @unchecked Sendable {
    enum Script {
        /// The socket dies before the attach is confirmed, as it did on a
        /// frame over `URLSessionWebSocketTask`'s 1 MiB default.
        case dropOnAttach(String)
        /// The server confirms the attach with this snapshot.
        case attach(LiveSessionSnapshot)
    }

    let frames: AsyncStream<EventStream.Frame>
    private let continuation: AsyncStream<EventStream.Frame>.Continuation
    let script: Script
    private(set) var attachedConnections: [String] = []
    private(set) var isClosed = false

    init(_ script: Script) {
        self.script = script
        var captured: AsyncStream<EventStream.Frame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    func start() { continuation.yield(.ready) }

    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?) {
        attachedConnections.append(connectionId)
        switch script {
        case .dropOnAttach(let reason):
            drop(reason)
        case .attach(let snapshot):
            continuation.yield(.snapshot(snapshot))
        }
    }

    func detach(subscriptionId: String) {}

    func close() {
        isClosed = true
        continuation.finish()
    }

    func push(_ frame: EventStream.Frame) { continuation.yield(frame) }

    func drop(_ reason: String) {
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }
}

/// Hands the session screen one scripted socket per connection attempt.
@MainActor
final class StreamFactory {
    private var scripts: [ScriptedStream.Script]
    /// Used once the scripts run out.
    private let fallback: ScriptedStream.Script
    private(set) var opened: [ScriptedStream] = []

    init(_ scripts: [ScriptedStream.Script], fallback: ScriptedStream.Script = .attach(Fixtures.snapshot(status: "connected"))) {
        self.scripts = scripts
        self.fallback = fallback
    }

    func make() -> any SessionEventStream {
        let script = scripts.isEmpty ? fallback : scripts.removeFirst()
        let stream = ScriptedStream(script)
        opened.append(stream)
        return stream
    }
}

// MARK: - Wire fixtures

enum Fixtures {
    /// What `URLSessionWebSocketTask` reports for a frame over its limit (EMSGSIZE).
    static let messageTooLong = "The operation couldn’t be completed. Message too long"

    static let conversationID = 7

    static func detail(turnState: String? = nil, status: String = "pending_review") -> String {
        let state = turnState.map { "\"\($0)\"" } ?? "null"
        return """
        {"summary": {"id": \(conversationID), "folder_id": 1, "title": "PolylexAI - main",
          "agent_type": "claude_code", "status": "\(status)", "external_id": "ext-7",
          "message_count": 2, "created_at": "2026-10-04T16:00:00Z",
          "updated_at": "2026-10-04T16:20:00Z", "turn_state": \(state)},
         "turns": [], "session_stats": null, "in_flight_user_turn_id": null}
        """
    }

    static let connectionInfo = #"{"connection_id": "conn-1", "event_seq": 0}"#

    /// A snapshot as JSON text (the server's snake_case shape).
    static func snapshotJSON(status: String, liveText: String? = nil, awaitingBackground: Bool = false,
                             nativeSteering: Bool = false, backgroundOutstanding: Int = 0,
                             pendingUserMessageID: String? = nil,
                             feedback: [(id: String, text: String)] = []) -> String {
        var fields = [
            #""connection_id": "conn-1""#,
            #""conversation_id": 7"#,
            "\"status\": \"\(status)\"",
            "\"awaiting_background\": \(awaitingBackground)",
            "\"native_steering_available\": \(nativeSteering)",
            "\"background_outstanding\": \(backgroundOutstanding)",
            #""event_seq": 3"#,
        ]
        if let liveText {
            fields.append("\"live_message\": {\"id\": \"m1\", \"role\": \"assistant\", \"content\": [{\"kind\": \"text\", \"text\": \(quoted(liveText))}]}")
        }
        if let pendingUserMessageID {
            fields.append("\"pending_user_message\": {\"message_id\": \(quoted(pendingUserMessageID)), \"blocks\": []}")
        }
        if !feedback.isEmpty {
            let items = feedback.map {
                "{\"id\": \(quoted($0.id)), \"text\": \(quoted($0.text)), \"created_at\": \"2026-10-04T16:35:00Z\", \"status\": \"delivered\"}"
            }
            fields.append("\"feedback\": [\(items.joined(separator: ", "))]")
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    static func snapshot(status: String, liveText: String? = nil, awaitingBackground: Bool = false,
                         nativeSteering: Bool = false, backgroundOutstanding: Int = 0,
                         pendingUserMessageID: String? = nil,
                         feedback: [(id: String, text: String)] = []) -> LiveSessionSnapshot {
        let json = snapshotJSON(status: status, liveText: liveText, awaitingBackground: awaitingBackground,
                                nativeSteering: nativeSteering, backgroundOutstanding: backgroundOutstanding,
                                pendingUserMessageID: pendingUserMessageID, feedback: feedback)
        return try! CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(json.utf8))
    }

    static func event(_ json: String) -> EventStream.Frame {
        .event(try! CodegJSON.decoder.decode(EventEnvelope.self, from: Data(json.utf8)))
    }

    /// `text` as a JSON string literal.
    static func quoted(_ text: String) -> String {
        String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    }
}

/// Poll `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
