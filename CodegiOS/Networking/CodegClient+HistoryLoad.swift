import Foundation

/// What the last history read of a session cost: the bytes that crossed the
/// network (as received, compressed), the answer's size once decoded, the
/// whole read's time, and the server's share of it when the server said
/// (`Server-Timing: app;dur=…`, sent by servers with history previews). The
/// session's details show it, so a slow open can be told apart: a big answer,
/// a slow network or a slow server.
struct HistoryLoadTiming: Equatable, Sendable {
    /// Body bytes received, as they crossed the network.
    var wireBytes: Int
    /// The body's size once decompressed.
    var bodyBytes: Int
    /// From sending the request to the decoded answer, in seconds.
    var total: TimeInterval
    /// The server's own time, in seconds, when it said.
    var server: TimeInterval?
    /// Pictures that came as previews.
    var previews: Int = 0

    /// The rest of `total`: the network, and decoding on the phone.
    var network: TimeInterval? {
        server.map { max(0, total - $0) }
    }

    /// "40 KB in 0.31 s", then the server's and the network's share when
    /// the server said.
    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(wireBytes), countStyle: .file)
        let loaded = String(localized: "\(size) in \(Self.seconds(total))")
        guard let server, let network else { return loaded }
        return String(localized: "\(loaded) · server \(Self.seconds(server)), network \(Self.seconds(network))")
    }

    static func seconds(_ value: TimeInterval) -> String {
        let format = value < 0.1 ? "%.3f s" : "%.2f s"
        return String(format: format, locale: Locale.current, value)
    }

    /// The `app` metric of a `Server-Timing` header, in seconds
    /// (`app;dur=12.3, img;dur=4.5` → 0.0123).
    static func serverSeconds(fromServerTiming header: String?) -> TimeInterval? {
        guard let header else { return nil }
        for metric in header.split(separator: ",") {
            let parts = metric.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first == "app" else { continue }
            for parameter in parts.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2, pair[0].lowercased() == "dur", let millis = Double(pair[1]), millis >= 0 {
                    return millis / 1000
                }
            }
        }
        return nil
    }
}

/// Collects a task's metrics: how many body bytes actually came over the
/// network.
private final class ResponseBytesMeter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64?

    var wireBytes: Int? {
        lock.withLock { received.map { Int($0) } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let bytes = metrics.transactionMetrics.reduce(Int64(0)) { $0 + $1.countOfResponseBodyBytesReceived }
        lock.withLock { received = bytes }
    }
}

extension CodegClient {
    /// `get_folder_conversation` with a turn window, timed (see
    /// ``HistoryLoadTiming``). Asks for picture previews; a server without
    /// them ignores that and sends the pictures whole.
    func conversationDetailTimed(id: Int, window: TranscriptSync.Request) async throws
        -> (detail: ConversationDetail, timing: HistoryLoadTiming) {
        var body = ConversationWindowBody(conversationId: id)
        switch window {
        case .tail(let count): body.tailTurns = count
        case .from(let index, _): body.fromIndex = index
        }
        let encoded: Data
        do { encoded = try CodegJSON.encoder.encode(body) }
        catch { throw APIError.decoding(String(describing: error)) }

        let meter = ResponseBytesMeter()
        let started = Date()
        let (status, data, response) = try await meteredExchange("get_folder_conversation", rawBody: encoded,
                                                                 delegate: meter)
        guard (200..<300).contains(status) else { throw Self.refusalError(status: status, body: data) }
        let detail = try decodeConversationDetail(data)
        let total = Date().timeIntervalSince(started)
        let timing = HistoryLoadTiming(
            wireBytes: meter.wireBytes.flatMap { $0 > 0 ? $0 : nil } ?? data.count,
            bodyBytes: data.count,
            total: total,
            server: HistoryLoadTiming.serverSeconds(fromServerTiming: response?.value(forHTTPHeaderField: "Server-Timing")),
            previews: FullImages.previewCount(in: detail.turns)
        )
        return (detail, timing)
    }

    /// One `POST /api/<path>`, as ``exchange(_:rawBody:session:)`` sends it,
    /// with a task delegate and the response's headers.
    private func meteredExchange(_ path: String, rawBody: Data, delegate: URLSessionTaskDelegate) async throws
        -> (status: Int, body: Data, response: HTTPURLResponse?) {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            throw APIError.transport((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("Malformed response") }
        return (http.statusCode, data, http)
    }

    /// The full picture behind a history preview: `GET <ref>` with the
    /// token. A refusal throws as any call's does.
    func fullImageData(ref: String) async throws -> Data {
        guard let request = ImageSource(baseURL: baseURL, token: token).request(for: ref) else {
            throw APIError.transport("Malformed image reference")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("Malformed response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.refusalError(status: http.statusCode, body: data) }
        return data
    }
}
