import Foundation

/// Body for `acp_fork`. `conversationId` / `folderId` link a connection that
/// resumed the conversation but hasn't prompted yet (the server ignores them
/// once it is linked); no `forkFromTurnId` forks at the tail. No `mode` (left
/// out of the body) is the server's default, a plain branch ("Fork from
/// here"); an edit sends `edit_in_place` or `edit`.
struct AcpForkBody: Encodable, Sendable {
    let connectionId: String
    let conversationId: Int?
    let folderId: Int?
    let forkFromTurnId: String?
    var mode: ForkMode? = nil
}

/// Body for `acp_fork_to_new_conversation`: fork at a FINISHED reply into a
/// new conversation while a turn runs.
struct AcpForkToNewConversationBody: Encodable, Sendable {
    let connectionId: String
    let conversationId: Int?
    let forkFromTurnId: String
}

extension CodegClient {
    /// For the fork calls. `acp_fork` waits for the agent's `session/fork` and
    /// the resume of the fork; `acp_fork_to_new_conversation` launches an
    /// agent process of its own and waits up to the server's spawn handshake
    /// (180 s), as codeg web does with its 200 s connect timeout.
    static let forkSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 200
        cfg.timeoutIntervalForResource = 240
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Fork the live session between turns, in place (`acp_fork`): this row
    /// moves to the fork (`[Fork] …`) and `siblingConversationId` keeps the
    /// original. Throws `APIError.turnInProgress` while a turn runs.
    func fork(connectionId: String, conversationId: Int?, folderId: Int?,
              forkFromTurnId: String?, mode: ForkMode? = nil) async throws -> ForkResult {
        try await postJSON("acp_fork", AcpForkBody(
            connectionId: connectionId,
            conversationId: conversationId,
            folderId: folderId,
            forkFromTurnId: forkFromTurnId,
            mode: mode
        ), session: Self.forkSession)
    }

    /// Whether `acp_fork` takes an edit `mode` (codeg's "Edit message"). The
    /// server is asked to fork a connection that can't exist with a mode no
    /// server has: one that knows the modes refuses the body while reading
    /// it (422 "unknown variant") and touches nothing; an older one ignores
    /// the field and answers "connection not found"; one without forking
    /// answers `not_implemented`. Throws when the server can't be reached,
    /// so a blip isn't taken for an older server.
    func forkEditModesSupported() async throws -> Bool {
        struct Probe: Encodable {
            let connectionId: String
            let mode: String
        }
        do {
            _ = try await send("acp_fork", body: Probe(connectionId: "", mode: "codeg-ios-probe"),
                               session: Self.readSession)
            return false
        } catch let error as APIError {
            switch error {
            case .server(let status, _, _) where status == 422:
                return true
            case .server, .turnInProgress:
                return false
            default:
                throw error
            }
        }
    }

    /// Fork a finished reply into a new conversation while a turn runs
    /// (`acp_fork_to_new_conversation`). An agent that only forks between
    /// turns is refused (``APIError/isForkNeedsIdle``).
    func forkToNewConversation(connectionId: String, conversationId: Int?,
                               forkFromTurnId: String) async throws -> ForkToNewConversationResult {
        try await postJSON("acp_fork_to_new_conversation", AcpForkToNewConversationBody(
            connectionId: connectionId,
            conversationId: conversationId,
            forkFromTurnId: forkFromTurnId
        ), session: Self.forkSession)
    }

    /// Which fork endpoints the server has. Each is asked about a connection
    /// that can't exist (an empty id): a server with the endpoint answers
    /// "connection not found" and touches nothing; one without it answers
    /// `not_implemented`. Throws when the server can't be reached, so a blip
    /// isn't taken for an older server.
    func forkEndpoints() async throws -> ForkEndpoints {
        async let inPlace = endpointExists("acp_fork", AcpForkBody(
            connectionId: "", conversationId: nil, folderId: nil, forkFromTurnId: nil))
        async let toNew = endpointExists("acp_fork_to_new_conversation", AcpForkToNewConversationBody(
            connectionId: "", conversationId: nil, forkFromTurnId: ""))
        let (hasInPlace, hasToNew) = try await (inPlace, toNew)
        guard hasInPlace else { return .missing }
        return .available(toNewConversation: hasToNew)
    }

    private func endpointExists<Body: Encodable>(_ path: String, _ body: Body) async throws -> Bool {
        do {
            _ = try await send(path, body: body, session: Self.readSession)
            return true
        } catch let error as APIError {
            switch error {
            case .server where error.isEndpointMissing:
                return false
            case .server, .turnInProgress:
                return true
            default:
                throw error
            }
        }
    }
}

extension APIError {
    /// The server has no such endpoint: codeg's web mode answers an unknown
    /// command with 501 `not_implemented`; a 404 is read the same way.
    var isEndpointMissing: Bool {
        guard case .server(let status, let code, _) = self else { return false }
        return status == 501 || code == "not_implemented" || code == "unknown_command"
            || (status == 404 && code == nil)
    }

    /// The backend's "this agent can only fork between turns"
    /// (`AcpError::ForkNeedsIdle`), matched by text as codeg web's
    /// `isForkNeedsIdleRejection` does.
    var isForkNeedsIdle: Bool {
        guard case .server(_, _, let message) = self else { return false }
        return message.contains("can only fork between turns")
    }

    /// The connection the call named is gone (`AcpError::ConnectionNotFound`).
    var isConnectionNotFound: Bool {
        guard case .server(let status, let code, let message) = self else { return false }
        return code == "connection_not_found" || (status >= 400 && message.contains("connection not found"))
    }

    /// The connection vanished (``APIError/streamGone``).
    var isStreamGone: Bool {
        if case .streamGone = self { return true }
        return false
    }

    /// The server's own words, without the code and status the general
    /// description adds.
    var serverMessage: String {
        if case .server(_, _, let message) = self { return message }
        return errorDescription ?? "\(self)"
    }
}
