import Foundation

/// Body for `move_conversation_to_folder` (codeg fork.227). No `dryRun` (left
/// out of the body) is a real move.
struct MoveConversationBody: Encodable, Sendable {
    let conversationId: Int
    let folderId: Int
    /// Only say what a move would do (its mode, or why it is refused); change
    /// nothing.
    var dryRun: Bool?
}

extension CodegClient {
    /// For moves: a real one closes the session's idle connection and waits
    /// (up to 5 s) for its agent to exit, and for Claude Code's own record of
    /// the session to go, before it moves the files; the first dry run reads
    /// the server's Claude adapter.
    static let moveSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// Move a conversation to another project with its files
    /// (`move_conversation_to_folder`), or with `dryRun` only say what a move
    /// would do. A refusal throws ``SessionMoveRefusal`` with its code (a 409
    /// among them, which ``send(_:rawBody:session:)`` would read as a running
    /// turn); anything else throws as `send` does, so a server without the
    /// move throws an error that ``APIError/isEndpointMissing``.
    func moveConversation(conversationId: Int, folderId: Int, dryRun: Bool) async throws -> SessionMoveResult {
        let body: Data
        do {
            body = try CodegJSON.encoder.encode(MoveConversationBody(
                conversationId: conversationId, folderId: folderId, dryRun: dryRun ? true : nil))
        } catch {
            throw APIError.decoding(String(describing: error))
        }
        let (status, data) = try await exchange("move_conversation_to_folder", rawBody: body,
                                                session: Self.moveSession)
        guard (200..<300).contains(status) else {
            if status != 401, let refusal = SessionMoveRefusal.parse(status: status, body: data) { throw refusal }
            throw Self.refusalError(status: status, body: data)
        }
        do { return try CodegJSON.decoder.decode(SessionMoveResult.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// Whether the server can move sessions. It is asked for a dry run of a
    /// conversation that can't exist (0, into folder 0): a server with the
    /// move refuses it (`conversation_not_found`) and touches nothing; one
    /// without it answers `not_implemented`. Throws when the server can't be
    /// reached, so a blip isn't taken for an older server.
    func moveEndpointAvailable() async throws -> Bool {
        do {
            _ = try await send("move_conversation_to_folder",
                               body: MoveConversationBody(conversationId: 0, folderId: 0, dryRun: true),
                               session: Self.readSession)
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
