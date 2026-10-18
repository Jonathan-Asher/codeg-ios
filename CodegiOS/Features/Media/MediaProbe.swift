import Foundation

/// What the first bytes of a stream say about it, read with one small Range
/// request before a player gets the URL. AVFoundation reports a link that
/// expired, a file that vanished or a format it can't play all as "The
/// operation could not be completed"; this tells them apart, in words.
struct MediaProbeResult: Equatable, Sendable {
    /// The whole file's length, from `Content-Range` (or `Content-Length` on a 200).
    let totalLength: Int64?
    let contentType: String?
    /// The server answered the Range with a 206.
    let acceptsRanges: Bool
    /// The bytes received (at most what was asked for).
    let head: Data

    /// A Matroska / WebM file (EBML header), which AVFoundation doesn't play.
    var isMatroska: Bool {
        head.count >= 4 && head.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3])
    }
}

enum MediaProbe {
    /// The span `start...end` (inclusive) of `url`, as `Range: bytes=start-end`.
    static func read(_ url: URL, start: Int64, end: Int64, session: URLSession) async throws -> MediaProbeResult {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MediaError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MediaError.network("Malformed response") }
        let type = http.value(forHTTPHeaderField: "Content-Type")
        switch http.statusCode {
        case 206:
            return MediaProbeResult(totalLength: totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range")),
                                    contentType: type, acceptsRanges: true, head: data)
        case 200:
            // A server that ignores Range sends the whole file; keep only the start.
            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            let wanted = Int(max(0, end - start + 1))
            return MediaProbeResult(totalLength: length, contentType: type, acceptsRanges: false,
                                    head: start == 0 ? data.prefix(wanted) : Data())
        case 416:
            // Asked past the end: the length is in `bytes */len`.
            return MediaProbeResult(totalLength: totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range")),
                                    contentType: type, acceptsRanges: true, head: Data())
        default:
            let parsed = try? CodegJSON.decoder.decode(ServerError.self, from: data)
            throw MediaError.from(status: http.statusCode, code: parsed?.code, message: parsed?.message)
        }
    }

    /// The first `count` bytes: is the link alive, does it seek, what is it.
    static func head(_ url: URL, count: Int64 = 16, session: URLSession) async throws -> MediaProbeResult {
        try await read(url, start: 0, end: max(0, count - 1), session: session)
    }

    /// `bytes 0-15/2048` → 2048; `bytes */2048` → 2048; nil when unknown (`*`).
    static func totalLength(contentRange: String?) -> Int64? {
        guard let value = contentRange, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// The session the probes go through: no cache, a short wait.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()
}
