import Foundation

// MARK: - The link

/// A codeg session link, as the desktop app and the agents on a codeg server
/// write them (codeg's `docs/url-scheme.md`):
///
/// - `codeg://session/<id>?server=<server>`: a session by codeg's id, or the
///   agent's own session id;
/// - `codeg://workspace?conversationId=<id>&server=<server>`, with an optional
///   `folderId` and `agent` the session must have.
///
/// `server` names the codeg instance the session lives on (an id from its
/// `/api/health`, a saved server's name, or its host); without it the
/// session is on the server the app shows. Read exactly as the desktop's
/// `parse_deep_link` reads it, so one link opens the same session on the
/// Mac and on the phone.
enum SessionLink: Equatable, Sendable {
    case session(ref: String, server: String?)
    case workspace(conversationID: Int, folderID: Int?, agent: String?, server: String?)

    /// The scheme these links use.
    static let scheme = "codeg"

    /// Longest `server` value, in characters.
    static let maxServerCharacters = 255

    var server: String? {
        switch self {
        case .session(_, let server), .workspace(_, _, _, let server): return server
        }
    }

    /// What `resolve_session_link` takes: the session's id (or the agent's),
    /// and the folder and agent it must have.
    var lookup: (ref: String, folderID: Int?, agent: String?) {
        switch self {
        case .session(let ref, _): return (ref, nil, nil)
        case .workspace(let id, let folder, let agent, _): return (String(id), folder, agent)
        }
    }

    /// The link `raw` is, or `nil` for anything else: another scheme,
    /// `codeg://` or `codeg://open` (just the app), a Harness link, or a
    /// link that can name no session (a `server` that can't be one, a
    /// malformed id).
    static func parse(_ raw: String) -> SessionLink? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        var rest: Substring
        if lower.hasPrefix("codeg://") {
            rest = raw.dropFirst("codeg://".count)
        } else if lower.hasPrefix("codeg:") {
            rest = raw.dropFirst("codeg:".count)
        } else {
            return nil
        }
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        var path = rest
        var query: Substring = ""
        if let mark = rest.firstIndex(of: "?") {
            path = rest[..<mark]
            query = rest[rest.index(after: mark)...]
        }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.lowercased() == "workspace" { return parseWorkspace(query: String(query)) }
        guard let slash = path.firstIndex(of: "/"), path[..<slash].lowercased() == "session" else { return nil }
        return parseSession(ref: String(path[path.index(after: slash)...]), query: String(query))
    }

    private static func parseSession(ref raw: String, query: String) -> SessionLink? {
        let ref = percentDecoded(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty, !ref.contains("/"), !ref.contains("\\"), ref.utf8.count <= 256 else { return nil }
        guard case .valid(let named) = serverValue(in: query) else { return nil }
        return .session(ref: ref, server: named)
    }

    private static func parseWorkspace(query: String) -> SessionLink? {
        var folderID: Int?
        var conversationID: Int?
        var agent: String?
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals]
            let value = percentDecoded(String(pair[pair.index(after: equals)...]))
            switch key {
            case "folderId", "folder_id":
                folderID = Int32(value).map(Int.init).flatMap { $0 > 0 ? $0 : nil }
            case "conversationId", "conversation_id":
                conversationID = Int32(value).map(Int.init).flatMap { $0 > 0 ? $0 : nil }
            case "agent":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { agent = trimmed }
            default:
                continue
            }
        }
        guard let conversationID else { return nil }
        guard case .valid(let named) = serverValue(in: query) else { return nil }
        return .workspace(conversationID: conversationID, folderID: folderID, agent: agent, server: named)
    }

    private enum ServerValue: Equatable {
        case valid(String?)
        case invalid
    }

    /// The query's `server`, read as `URLSearchParams` reads it: the first
    /// one, `+` as a space, percent-escapes decoded, trimmed. None when
    /// absent or empty; invalid past 255 characters or with a control
    /// character.
    private static func serverValue(in query: String) -> ServerValue {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard formDecoded(String(parts[0])) == "server" else { continue }
            let value = formDecoded(parts.count > 1 ? String(parts[1]) : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return .valid(nil) }
            if value.count > maxServerCharacters
                || value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return .invalid
            }
            return .valid(value)
        }
        return .valid(nil)
    }

    private static func percentDecoded(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }

    private static func formDecoded(_ raw: String) -> String {
        percentDecoded(raw.replacingOccurrences(of: "+", with: " "))
    }
}

// MARK: - Which server

/// A saved server as a link's `server` is matched against it.
struct SessionLinkServer: Equatable, Sendable {
    let id: UUID
    /// The name it was saved under.
    let name: String
    let baseURL: URL?
    /// What it last said about itself, if it ever did.
    let identity: ServerIdentity?
}

enum SessionLinkMatch {
    /// The saved server a link's `server` names, in the desktop's order
    /// (`deep_link::match_server`), so that what names an instance outright
    /// is never overridden by a name that only happens to match:
    ///
    /// 1. the instance id a server gave (`/api/health`'s `instanceId`);
    /// 2. the name it was saved under, in any case;
    /// 3. its host: alone, with its port, or as a whole URL;
    /// 4. the name the instance gives itself (`instanceName`).
    ///
    /// The first server (in the saved order) that matches wins.
    static func server(_ wanted: String, in servers: [SessionLinkServer]) -> UUID? {
        let wanted = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let hit = servers.first(where: { server in
            server.identity?.instanceId.map { $0.caseInsensitiveCompare(wanted) == .orderedSame } ?? false
        }) {
            return hit.id
        }
        if let hit = servers.first(where: { sameName($0.name, wanted) }) { return hit.id }
        if let hit = servers.first(where: { namesHost(wanted, of: $0.baseURL) }) { return hit.id }
        if let hit = servers.first(where: { sameName($0.identity?.instanceName ?? "", wanted) }) { return hit.id }
        return nil
    }

    static func sameName(_ name: String, _ wanted: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.lowercased() == wanted.lowercased()
    }

    /// Whether `wanted` names the host `baseURL` points at: the host, the
    /// host with the port the URL gives, or a URL to the same host and port.
    static func namesHost(_ wanted: String, of baseURL: URL?) -> Bool {
        guard let baseURL, let host = baseURL.host, !host.isEmpty else { return false }
        if wanted.contains("://") {
            guard let other = URLComponents(string: wanted), let otherHost = other.host else { return false }
            return otherHost.lowercased() == host.lowercased()
                && port(other.port, scheme: other.scheme) == port(baseURL.port, scheme: baseURL.scheme)
        }
        if wanted.lowercased() == host.lowercased() { return true }
        guard let port = baseURL.port else { return false }
        return wanted.lowercased() == "\(host):\(port)".lowercased()
    }

    /// A URL's port, or its scheme's default (`port_or_known_default`).
    private static func port(_ port: Int?, scheme: String?) -> Int? {
        if let port { return port }
        switch scheme?.lowercased() {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }
}

// MARK: - Who each server is

/// What a saved server last said about itself in `/api/health`: who it is
/// (its instance id and name, which a link's `server` names) and whether it
/// sends history pictures as previews. Kept with the address it was learned
/// from: once the server is edited to another address, it is asked again.
struct ServerIdentity: Codable, Equatable, Sendable {
    var instanceId: String?
    var instanceName: String?
    var imagePreviews: Int?
    /// The server's address when it said so.
    var urlString: String
}

/// ``ServerIdentity`` per saved server, in the defaults.
@MainActor
final class ServerIdentityStore {
    static let defaultsKey = "codeg.serverIdentities.v1"

    private let defaults: UserDefaults
    private var identities: [String: ServerIdentity]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: ServerIdentity].self, from: data) {
            identities = saved
        } else {
            identities = [:]
        }
    }

    /// What `profile` said about itself at its current address.
    func identity(for profile: ServerProfile) -> ServerIdentity? {
        identities[profile.id.uuidString].flatMap { $0.urlString == profile.urlString ? $0 : nil }
    }

    func record(_ health: HealthResponse, for profile: ServerProfile) {
        let identity = ServerIdentity(instanceId: health.instanceId?.nilIfBlank,
                                      instanceName: health.instanceName?.nilIfBlank,
                                      imagePreviews: health.imagePreviews,
                                      urlString: profile.urlString)
        guard identities[profile.id.uuidString] != identity else { return }
        identities[profile.id.uuidString] = identity
        save()
    }

    /// Forget the servers no longer saved.
    func prune(keeping ids: Set<UUID>) {
        let keep = Set(ids.map(\.uuidString))
        let before = identities.count
        identities = identities.filter { keep.contains($0.key) }
        if identities.count != before { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(identities) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

// MARK: - Finding the session

/// What a server said about a link's session.
enum SessionLinkLookup: Equatable, Sendable {
    /// The session, by codeg's id on that server.
    case found(Int)
    /// No live session there answers to the link.
    case notFound
    /// A server from before session links (no `resolve_session_link`).
    case unsupported
}

/// `resolve_session_link`'s answer.
private struct SessionLinkTarget: Decodable {
    let conversationId: Int
}

private struct ResolveSessionLinkBody: Encodable {
    let sessionRef: String
    var folderId: Int?
    var agent: String?
}

extension CodegClient {
    /// Look a link's session up on this server: codeg's id, or the agent's
    /// own session id, checked against the folder and agent when given.
    func resolveSessionLink(ref: String, folderID: Int?, agent: String?) async throws -> SessionLinkLookup {
        let body = ResolveSessionLinkBody(sessionRef: ref, folderId: folderID, agent: agent)
        let encoded: Data
        do { encoded = try CodegJSON.encoder.encode(body) }
        catch { throw APIError.decoding(String(describing: error)) }
        let (status, data) = try await exchange("resolve_session_link", rawBody: encoded, session: Self.readSession)
        // An older server answers an endpoint it doesn't have with 501 (or,
        // behind some proxies, 404).
        if status == 501 || status == 404 { return .unsupported }
        guard (200..<300).contains(status) else { throw Self.refusalError(status: status, body: data) }
        guard let target = try? CodegJSON.decoder.decode(SessionLinkTarget?.self, from: data) else {
            return .notFound
        }
        return .found(target.conversationId)
    }
}
