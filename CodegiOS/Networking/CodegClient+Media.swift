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
