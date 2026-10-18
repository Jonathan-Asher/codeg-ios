import Foundation

// MARK: - Wire types

/// A streaming capability for one workspace file (`workspace_media_capability`,
/// codeg's `MediaCapabilityIssued`). `url` is server-relative
/// (`/api/workspace_media/<token>/<name>`): the token in the path is the only
/// credential the byte endpoint takes, so a player can load it without a
/// Bearer header. It stays valid for `expiresInSecs` without use, each request
/// pushing that out, and for eight hours at most.
struct MediaCapability: Decodable, Sendable, Equatable {
    let token: String
    let url: String
    let filename: String
    let size: Int64
    let contentType: String
    let expiresInSecs: Int
}

/// Body for `workspace_media_capability`, `download_workspace_file` and
/// `read_workspace_file_base64`: `path` is relative to `rootPath` (no `..`, no
/// leading slash), the rule codeg applies to every workspace download.
struct WorkspaceFileBody: Encodable, Sendable {
    let rootPath: String
    let path: String
}

struct MediaRevokeBody: Encodable, Sendable {
    let token: String
}

// MARK: - Errors

/// Why a file from the session's folder can't be shown, in words for the card.
enum MediaError: LocalizedError, Equatable, Sendable {
    /// The server has no such endpoint (an older codeg answers 501).
    case unsupportedServer
    /// The capability endpoint only streams video; audio and pictures are
    /// downloaded instead.
    case notStreamable
    /// The path isn't inside the session's folder.
    case outsideFolder
    case missing
    case folderMissing
    /// The capability expired or was revoked (404 from the byte endpoint).
    case expired
    case tooLarge(Int64)
    /// AVFoundation can't play this file on the iPhone.
    case unplayable(String)
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedServer: return "This needs a newer codeg server."
        case .notStreamable: return "The server can't stream this file."
        case .outsideFolder: return "This file is outside the session's folder, so the server won't serve it."
        case .missing: return "The file is no longer there."
        case .folderMissing: return "The file's folder is no longer on the server."
        case .expired: return "The link to this file expired."
        case .tooLarge(let bytes):
            return "Too large to open on the iPhone (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
        case .unplayable(let detail): return detail
        case .server(let message): return message
        case .network(let detail): return "Network error: \(detail)"
        }
    }

    /// Read a failed workspace call. codeg's messages (`workspace_files.rs`,
    /// `folders.rs`) are matched as well as its codes, since `invalid_input`
    /// covers both a refused type and a path outside the folder.
    static func from(status: Int, code: String?, message: String?) -> MediaError {
        let text = (message ?? "").lowercased()
        switch status {
        case 501:
            return .unsupportedServer
        case 404:
            if text.contains("media link") || text.contains("expired") { return .expired }
            if text.contains("folder") { return .folderMissing }
            if code == "not_found" || text.contains("does not exist") { return .missing }
            return .unsupportedServer
        case 400:
            if text.contains("only video") || text.contains("streamed") { return .notStreamable }
            if text.contains("outside") || text.contains("..") || text.contains("relative")
                || text.contains("invalid path") { return .outsideFolder }
            if text.contains("not a file") { return .missing }
            return .server(message ?? "The server refused this file.")
        default:
            return .server(message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    static func from(_ error: Error) -> MediaError {
        if let media = error as? MediaError { return media }
        if let api = error as? APIError {
            switch api {
            case .server(let status, let code, let message):
                return from(status: status, code: code, message: message)
            case .transport(let detail): return .network(detail)
            case .unauthorized: return .server("Authentication failed. Check the server token.")
            default: return .server(api.errorDescription ?? "Something went wrong.")
            }
        }
        if let url = error as? URLError { return .network(url.localizedDescription) }
        return .server(error.localizedDescription)
    }

    /// Worth asking for a fresh capability and trying again.
    var isExpired: Bool { self == .expired }
}

// MARK: - Endpoints

/// The existence check lists directories through the folder browser's endpoint.
extension CodegClient: MediaDirectoryListing {}

extension CodegClient {
    /// Long transfers of whole files (pictures, audio on a server that can't
    /// stream it, documents): the overall cap allows a slow link.
    static let mediaSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    /// Mint a streaming capability for `path` under `rootPath`.
    func mediaCapability(rootPath: String, path: String) async throws -> MediaCapability {
        do {
            return try await postJSON("workspace_media_capability", WorkspaceFileBody(rootPath: rootPath, path: path))
        } catch {
            throw MediaError.from(error)
        }
    }

    /// Let go of a capability early. Best effort: it lapses on its own.
    func revokeMediaCapability(token: String) async {
        _ = try? await send("workspace_media_revoke", body: MediaRevokeBody(token: token))
    }

    /// The absolute URL of a capability's byte endpoint, under the configured
    /// base URL (so a server behind a reverse-proxy path keeps it).
    func mediaURL(for capability: MediaCapability) -> URL? {
        let path = capability.url.hasPrefix("/") ? String(capability.url.dropFirst()) : capability.url
        guard path.hasPrefix("api/workspace_media/"), !path.contains("..") else { return nil }
        // The name is already percent-encoded by the server; keep it as sent.
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/\(path)")
    }

    /// Download a whole workspace file (`download_workspace_file`) to a
    /// temporary location, refusing more than `maxBytes`. The caller moves or
    /// deletes the file.
    func downloadWorkspaceFile(rootPath: String, path: String, maxBytes: Int64) async throws -> URL {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("download_workspace_file")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? CodegJSON.encoder.encode(WorkspaceFileBody(rootPath: rootPath, path: path))
        // The mock server of the tests sends everything through its own session.
        let session = self.session === Self.defaultSession ? Self.mediaSession : self.session

        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(for: request)
        } catch {
            throw MediaError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: location)
            throw MediaError.network("Malformed response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: location)) ?? Data()
            try? FileManager.default.removeItem(at: location)
            if http.statusCode == 401 { throw MediaError.server("Authentication failed. Check the server token.") }
            let parsed = try? CodegJSON.decoder.decode(ServerError.self, from: data)
            throw MediaError.from(status: http.statusCode, code: parsed?.code, message: parsed?.message)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxBytes {
            try? FileManager.default.removeItem(at: location)
            throw MediaError.tooLarge(size)
        }
        // `download(for:)` deletes its file when the call returns; keep it.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)")
            .appendingPathExtension((path as NSString).pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
        } catch {
            throw MediaError.server("Couldn't keep the downloaded file: \(error.localizedDescription)")
        }
        return kept
    }
}

// MARK: - Attachment upload

/// A file uploaded with `upload_attachment` (codeg's `UploadAttachmentResult`):
/// where it now is on the server, under codeg's uploads directory.
struct UploadedAttachment: Decodable, Equatable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let mimeType: String?
}

/// Why an attachment didn't upload, in words for its chip.
enum AttachmentUploadError: LocalizedError, Equatable, Sendable {
    /// Over codeg's per-file limit (`UPLOAD_MAX_BYTES`).
    case tooLarge(limit: Int64)
    /// The server's total upload space is used up (`CODEG_UPLOAD_MAX_TOTAL_BYTES`).
    case quotaFull
    case unsupportedServer
    case unauthorized
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            return "The codeg server takes attachments up to \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
        case .quotaFull: return "The codeg server's upload space is full."
        case .unsupportedServer: return "This needs a newer codeg server."
        case .unauthorized: return "Authentication failed. Check the server token."
        case .server(let message): return message
        case .network(let detail): return "Network error: \(detail)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .server: return true
        default: return false
        }
    }

    /// codeg tags its upload refusals with an i18n key (`errors.upload.*`)
    /// and an English message; both are read.
    static func from(status: Int, data: Data) -> AttachmentUploadError {
        if status == 401 { return .unauthorized }
        if status == 501 || status == 404 { return .unsupportedServer }
        if status == 413 { return .tooLarge(limit: AttachmentUploadLimits.maxBytes) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let key = (object?["i18n_key"] as? String ?? object?["i18nKey"] as? String ?? "").lowercased()
        let text = message.lowercased()
        if key.hasSuffix("toolarge") || text.contains("maximum allowed size") {
            return .tooLarge(limit: AttachmentUploadLimits.maxBytes)
        }
        if key.hasSuffix("quotaexceeded") || text.contains("quota") { return .quotaFull }
        return .server(message)
    }
}

/// What codeg accepts through `upload_attachment`.
enum AttachmentUploadLimits {
    /// `UPLOAD_MAX_BYTES` (`web/handlers/files.rs`): 20 MiB per file.
    static let maxBytes: Int64 = 20 * 1024 * 1024
}

/// Uploads a file the way codeg web attaches one.
protocol AttachmentUploading: Sendable {
    func uploadAttachment(fileURL: URL, fileName: String, mimeType: String, bucket: String?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedAttachment
}

extension CodegClient: AttachmentUploading {
    /// Uploads take as long as the link needs; a stalled one gives up after a minute.
    static let uploadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 900
        cfg.waitsForConnectivity = true
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    /// Upload a file to codeg's uploads directory (`upload_attachment`, a
    /// multipart `file` and the `session_id` bucket), as codeg web does for an
    /// attachment that isn't a picture. The answer's `path` is what the prompt
    /// links to. Refuses over ``AttachmentUploadLimits/maxBytes`` before sending.
    func uploadAttachment(fileURL: URL, fileName: String, mimeType: String, bucket: String?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedAttachment {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw AttachmentUploadError.server("The file is empty.") }
        guard size <= AttachmentUploadLimits.maxBytes else {
            throw AttachmentUploadError.tooLarge(limit: AttachmentUploadLimits.maxBytes)
        }
        let file: Data
        do { file = try Data(contentsOf: fileURL, options: .mappedIfSafe) } catch {
            throw AttachmentUploadError.server("Couldn't read the file: \(error.localizedDescription)")
        }
        let boundary = "codeg-ios-\(UUID().uuidString)"
        let body = Self.multipartBody(boundary: boundary, bucket: bucket, fileName: fileName,
                                      mimeType: mimeType, file: file)

        let url = baseURL.appendingPathComponent("api").appendingPathComponent("upload_attachment")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // The mock server of the tests sends everything through its own session.
        let session = self.session === Self.defaultSession ? Self.uploadSession : self.session

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: UploadProgressDelegate(onProgress: progress))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AttachmentUploadError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AttachmentUploadError.network("Malformed response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AttachmentUploadError.from(status: http.statusCode, data: data)
        }
        progress(1)
        do {
            return try CodegJSON.decoder.decode(UploadedAttachment.self, from: data)
        } catch {
            throw AttachmentUploadError.server("The server's answer to the upload couldn't be read.")
        }
    }

    /// `multipart/form-data` with the bucket first, then the file.
    static func multipartBody(boundary: String, bucket: String?, fileName: String, mimeType: String, file: Data) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        if let bucket, !bucket.isEmpty {
            line("--\(boundary)")
            line(#"Content-Disposition: form-data; name="session_id""#)
            line("")
            line(bucket)
        }
        let safeName = fileName.unicodeScalars
            .filter { $0 != "\r" && $0 != "\n" }
            .map { $0 == "\"" || $0 == "\\" ? "_" : String($0) }
            .joined()
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(file)
        line("")
        line("--\(boundary)--")
        return body
    }
}

/// Reports how much of a request body has gone out.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
