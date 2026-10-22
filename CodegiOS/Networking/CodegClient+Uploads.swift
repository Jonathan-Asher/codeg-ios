import Foundation

// MARK: - Limits

/// What a codeg server takes as attachments (`upload_limits`, codeg fork.191's
/// `UploadLimitsInfo`). Video and audio have a cap of their own
/// (`maxMediaBytes`, 1 GiB by default, `CODEG_UPLOAD_MAX_MEDIA_BYTES`): they
/// are only linked from the prompt, never read back into it, so they may be
/// much larger than a picture.
struct ServerUploadLimits: Decodable, Equatable, Sendable {
    /// The resumable upload (`upload_attachment_create` and the calls after it).
    struct Resumable: Decodable, Equatable, Sendable {
        /// The piece size the server suggests (8 MiB); any size works.
        var chunkBytesHint: Int64?
        /// An upload with no request for this long is dropped (24 h).
        var idleTimeoutSecs: Int64?
        /// Uploads in progress at once, across every client.
        var maxActive: Int?
    }

    /// Pictures, documents and anything else.
    var maxFileBytes: Int64
    /// Video and audio (`mediaTypes`).
    var maxMediaBytes: Int64
    var mediaTypes: [String]?
    /// `CODEG_UPLOAD_MAX_TOTAL_BYTES`, when set.
    var maxTotalBytes: Int64?
    /// What that leaves right now.
    var remainingTotalBytes: Int64?
    var resumable: Resumable?
    /// False for ``legacy``: the server didn't say.
    var isReported = true

    private enum CodingKeys: String, CodingKey {
        case maxFileBytes, maxMediaBytes, mediaTypes, maxTotalBytes, remainingTotalBytes, resumable
    }

    init(maxFileBytes: Int64, maxMediaBytes: Int64, mediaTypes: [String]? = ["video/*", "audio/*"],
         maxTotalBytes: Int64? = nil, remainingTotalBytes: Int64? = nil, resumable: Resumable?,
         isReported: Bool = true) {
        self.maxFileBytes = maxFileBytes
        self.maxMediaBytes = maxMediaBytes
        self.mediaTypes = mediaTypes
        self.maxTotalBytes = maxTotalBytes
        self.remainingTotalBytes = remainingTotalBytes
        self.resumable = resumable
        self.isReported = isReported
    }

    /// A server before fork.191: 20 MiB for every file, in one request.
    static let legacy = ServerUploadLimits(maxFileBytes: AttachmentUploadLimits.maxBytes,
                                           maxMediaBytes: AttachmentUploadLimits.maxBytes,
                                           mediaTypes: nil, resumable: nil, isReported: false)

    /// The suggestion when the server gives none.
    static let defaultChunkBytes: Int64 = 8 * 1024 * 1024

    /// The cap for a file of `mimeType`: the media cap for video and audio.
    func limit(forMimeType mimeType: String) -> Int64 {
        let type = mimeType.lowercased()
        return type.hasPrefix("video/") || type.hasPrefix("audio/") ? maxMediaBytes : maxFileBytes
    }

    /// The size of each piece of a resumable upload: the server's hint, at
    /// most 64 MiB (a piece is read into memory).
    var chunkBytes: Int64 {
        guard let hint = resumable?.chunkBytesHint, hint > 0 else { return Self.defaultChunkBytes }
        return min(hint, 64 * 1024 * 1024)
    }
}

/// `upload_limits` asked once per server and kept: an answer for an hour, a
/// server that doesn't know the call for ten minutes (so an upgrade is seen).
actor UploadLimitsCache {
    static let shared = UploadLimitsCache()

    private var known: [String: (limits: ServerUploadLimits, at: Date)] = [:]
    private var running: [String: Task<ServerUploadLimits, Error>] = [:]

    static let reportedLifetime: TimeInterval = 60 * 60
    static let legacyLifetime: TimeInterval = 10 * 60

    func limits(for key: String, fetch: @escaping @Sendable () async throws -> ServerUploadLimits)
        async throws -> ServerUploadLimits {
        if let hit = known[key] {
            let lifetime = hit.limits.isReported ? Self.reportedLifetime : Self.legacyLifetime
            if Date().timeIntervalSince(hit.at) < lifetime { return hit.limits }
        }
        if let task = running[key] { return try await task.value }
        let task = Task { try await fetch() }
        running[key] = task
        defer { running[key] = nil }
        let limits = try await task.value
        known[key] = (limits, Date())
        return limits
    }

    /// Forget every answer (tests).
    func reset() {
        known = [:]
    }
}

// MARK: - Resumable upload wire types

/// Where a resumable upload stands: the answer to create, chunk and status
/// (`UploadSessionInfo`). `offset` is how many bytes the server holds; the
/// next piece starts there.
struct ResumableUploadState: Decodable, Equatable, Sendable {
    let uploadId: String
    let offset: Int64
    let size: Int64
    let complete: Bool
    var fileName: String?
    var mimeType: String?
    /// The per-file cap the upload was admitted under.
    var limit: Int64?
    var expiresInSecs: Int64?
}

struct CreateResumableUploadBody: Encodable, Sendable {
    let fileName: String
    let size: Int64
    let mimeType: String?
    /// The bucket, as `upload_attachment`'s `session_id` field.
    let sessionId: String?
}

struct ResumableUploadIdBody: Encodable, Sendable {
    let uploadId: String
}

// MARK: - Endpoints

extension CodegClient {
    /// Pieces of a resumable upload. A piece that sends nothing for a minute
    /// is given up (the server keeps what arrived); one waiting for the
    /// network waits up to half an hour.
    static let chunkSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 30 * 60
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    /// The key the per-server caches use.
    var uploadCacheKey: String { "\(baseURL.absoluteString)|\(token.hashValue)" }

    func attachmentUploadLimits() async throws -> ServerUploadLimits {
        let client = self
        return try await UploadLimitsCache.shared.limits(for: uploadCacheKey) {
            try await withNetworkRetry { try await client.fetchUploadLimits() }
        }
    }

    /// `upload_limits`, uncached. A server that doesn't know it (404, 405,
    /// 501) or answers something else gets the 20 MiB of every server before it.
    func fetchUploadLimits() async throws -> ServerUploadLimits {
        do {
            return try await postJSON("upload_limits", EmptyBody(), session: Self.readSession)
        } catch let error as APIError {
            switch error {
            case .server(let status, _, _) where [404, 405, 501].contains(status):
                return .legacy
            case .decoding:
                return .legacy
            default:
                throw error
            }
        }
    }

    func createResumableUpload(fileName: String, size: Int64, mimeType: String?,
                               bucket: String?) async throws -> ResumableUploadState {
        let body = CreateResumableUploadBody(fileName: fileName, size: size, mimeType: mimeType,
                                             sessionId: (bucket?.isEmpty ?? true) ? nil : bucket)
        return try await uploadCall("upload_attachment_create", json: body)
    }

    func uploadResumableChunk(uploadId: String, offset: Int64, data: Data,
                              progress: @escaping @Sendable (UploadChunkEvent) -> Void) async throws -> ResumableUploadState {
        try await uploadCall("upload_attachment_chunk", method: "PUT",
                             query: [URLQueryItem(name: "uploadId", value: uploadId),
                                     URLQueryItem(name: "offset", value: String(offset))],
                             body: data, contentType: "application/octet-stream",
                             session: Self.chunkSession, progress: progress)
    }

    func resumableUploadStatus(uploadId: String) async throws -> ResumableUploadState {
        try await uploadCall("upload_attachment_status", json: ResumableUploadIdBody(uploadId: uploadId))
    }

    func completeResumableUpload(uploadId: String) async throws -> UploadedAttachment {
        try await uploadCall("upload_attachment_complete", json: ResumableUploadIdBody(uploadId: uploadId))
    }

    func cancelResumableUpload(uploadId: String) async {
        let body = (try? CodegJSON.encoder.encode(ResumableUploadIdBody(uploadId: uploadId))) ?? Data()
        _ = try? await uploadRequest("upload_attachment_cancel", body: body, contentType: "application/json",
                                     session: Self.readSession)
    }

    // MARK: Plumbing

    private func uploadCall<Body: Encodable, Answer: Decodable>(_ path: String, json body: Body) async throws -> Answer {
        let encoded: Data
        do { encoded = try CodegJSON.encoder.encode(body) } catch {
            throw AttachmentUploadError.server("The upload request couldn't be written.")
        }
        return try await uploadCall(path, body: encoded, contentType: "application/json", session: Self.uploadSession)
    }

    private func uploadCall<Answer: Decodable>(_ path: String, method: String = "POST", query: [URLQueryItem] = [],
                                               body: Data, contentType: String, session: URLSession,
                                               progress: (@Sendable (UploadChunkEvent) -> Void)? = nil) async throws -> Answer {
        let data = try await uploadRequest(path, method: method, query: query, body: body, contentType: contentType,
                                           session: session, progress: progress)
        do {
            return try CodegJSON.decoder.decode(Answer.self, from: data)
        } catch {
            throw AttachmentUploadError.server("The server's answer to the upload couldn't be read.")
        }
    }

    /// One upload request. Unlike ``send(_:rawBody:session:)`` it keeps a
    /// refusal's i18n key and parameters (a 409 is an offset to resume from,
    /// not a running turn), and reports the body's progress.
    private func uploadRequest(_ path: String, method: String = "POST", query: [URLQueryItem] = [], body: Data,
                               contentType: String, session preferred: URLSession,
                               progress: (@Sendable (UploadChunkEvent) -> Void)? = nil) async throws -> Data {
        var url = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // The mock server of the tests sends everything through its own session.
        let session = self.session === Self.defaultSession ? preferred : self.session
        let delegate = progress.map { report in
            UploadProgressDelegate(onWaiting: { report(.waitingForNetwork) }) { sent, _ in report(.sent(sent)) }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AttachmentUploadError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AttachmentUploadError.network("Malformed response") }
        // A proxy that refuses PUT: the server takes the piece as a POST too.
        if http.statusCode == 405, method == "PUT" {
            return try await uploadRequest(path, method: "POST", query: query, body: body, contentType: contentType,
                                           session: preferred, progress: progress)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AttachmentUploadError.from(status: http.statusCode, data: data,
                                             fallbackLimit: AttachmentUploadLimits.maxBytes)
        }
        return data
    }
}

// MARK: - stat_paths

/// One path's answer from `stat_paths` (codeg fork.191's `PathStat`).
/// `exists`, `isFile` and `isDir` are nil when the path wasn't allowed
/// (`reason`) or couldn't be checked (`error`).
struct PathStat: Decodable, Equatable, Sendable {
    let path: String
    let allowed: Bool
    var exists: Bool?
    var isFile: Bool?
    var isDir: Bool?
    var size: Int64?
    var modifiedMs: Int64?
    /// `outsideRoots`, `symlinkEscape` or `invalidPath`.
    var reason: String?
    var error: String?
}

struct StatPathsBody: Encodable, Sendable {
    let paths: [String]
    let rootPaths: [String]
}

/// Whether a batch of files is on the server, in one request (`stat_paths`).
protocol MediaPathStatting: Sendable {
    func statPaths(_ paths: [String], roots: [String]) async throws -> [PathStat]
}

extension CodegClient: MediaPathStatting {
    /// Paths per request (`STAT_PATHS_MAX`).
    static let statPathsMax = 200
    /// Roots per request (`STAT_ROOTS_MAX`).
    static let statRootsMax = 32

    /// Stat up to ``statPathsMax`` absolute paths. Each must lie under one of
    /// `roots` (codeg's uploads directory always counts); one outside them
    /// comes back `allowed: false`.
    func statPaths(_ paths: [String], roots: [String]) async throws -> [PathStat] {
        try await postJSON("stat_paths", StatPathsBody(paths: paths, rootPaths: roots), session: Self.readSession)
    }
}
