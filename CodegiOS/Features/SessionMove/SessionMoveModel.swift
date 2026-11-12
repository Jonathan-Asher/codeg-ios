import Foundation
import Observation

/// Whether each server can move a session to another project
/// (`move_conversation_to_folder`), checked once per server, as the fork
/// endpoints are (``ForkCapabilities``). Keyed by the server's address: the
/// endpoint is the server's whatever the token, and a row's menu asks
/// without building a client (which reads the token from the Keychain).
@MainActor
@Observable
final class SessionMoveCapabilities {
    static let shared = SessionMoveCapabilities()

    private var supportByServer: [String: SessionMoveSupport] = [:]
    @ObservationIgnored private var probes: [String: Task<SessionMoveSupport, Never>] = [:]

    private static func key(_ baseURL: URL) -> String { baseURL.absoluteString }

    func support(for client: CodegClient) -> SessionMoveSupport {
        support(baseURL: client.baseURL)
    }

    func support(baseURL: URL) -> SessionMoveSupport {
        supportByServer[Self.key(baseURL)] ?? .unknown
    }

    /// Check the server unless that is known. A check that couldn't reach the
    /// server leaves it unknown, to be tried again.
    @discardableResult
    func probeIfNeeded(client: CodegClient) async -> SessionMoveSupport {
        let key = Self.key(client.baseURL)
        if let known = supportByServer[key], known != .unknown { return known }
        if let running = probes[key] { return await running.value }
        let task = Task { () -> SessionMoveSupport in
            guard let available = try? await client.moveEndpointAvailable() else { return .unknown }
            return available ? .available : .missing
        }
        probes[key] = task
        let result = await task.value
        probes[key] = nil
        if result != .unknown { supportByServer[key] = result }
        return result
    }

    /// A move (or its dry run) found the server without the move: the menus
    /// stop offering it.
    func noteMissing(client: CodegClient) {
        supportByServer[Self.key(client.baseURL)] = .missing
    }

    /// A dry run went through: the server moves sessions.
    func noteAvailable(client: CodegClient) {
        let key = Self.key(client.baseURL)
        if supportByServer[key] != .available { supportByServer[key] = .available }
    }

    /// Forget everything (tests).
    func reset() {
        supportByServer = [:]
        probes = [:]
    }
}

/// "Move to Project…" asked for: the session, and the server it is on.
struct SessionMoveRequest: Identifiable {
    let id = UUID()
    let conversation: ConversationSummary
    let client: CodegClient
    let serverID: UUID
}

/// The project picker's state: the project picked, what a move there would
/// do (a dry run on every pick, as codeg web's dialog does), and the move.
@MainActor
@Observable
final class SessionMoveModel {
    /// What the picker says under the list.
    enum Preview: Equatable {
        /// Nothing picked yet.
        case idle
        /// The dry run for the project picked is on its way.
        case checking(folderID: Int)
        /// The move can go: what it will do.
        case ready(folderID: Int, result: SessionMoveResult)
        /// The server refused the move (or couldn't be asked): why.
        case refused(folderID: Int, message: String)
        /// The server has no move (an older codeg).
        case serverTooOld
    }

    let conversation: ConversationSummary
    let client: CodegClient
    @ObservationIgnored let capabilities: SessionMoveCapabilities

    /// The search field's text.
    var query = ""
    private(set) var picked: FolderDetail?
    private(set) var preview: Preview = .idle
    /// The move is on its way: the list and Cancel wait for it.
    private(set) var isMoving = false

    /// Hears a move that happened, with the project it went to.
    @ObservationIgnored var onMoved: ((SessionMoveResult, FolderDetail) -> Void)?

    /// Only the answer to the latest pick may land.
    @ObservationIgnored private var generation = 0

    init(conversation: ConversationSummary, client: CodegClient, capabilities: SessionMoveCapabilities? = nil) {
        self.conversation = conversation
        self.client = client
        self.capabilities = capabilities ?? .shared
    }

    /// The Move button is enabled: the dry run for the project picked says the
    /// move can go.
    var canMove: Bool {
        guard !isMoving, let picked, case .ready(let folderID, _) = preview else { return false }
        return folderID == picked.id
    }

    /// Pick `folder`: ask the server what a move there would do. Picking it
    /// again asks again (after a refusal, say).
    func pick(_ folder: FolderDetail) {
        guard !isMoving else { return }
        picked = folder
        generation += 1
        let mine = generation
        preview = .checking(folderID: folder.id)
        Task {
            let outcome = await check(folder)
            guard mine == generation else { return }
            preview = outcome
        }
    }

    /// Move the session to the project picked, once its dry run said it can
    /// go. A refusal now (a turn started meanwhile, say) takes the preview's
    /// place, and the picker stays open.
    func move() async {
        guard canMove, let folder = picked else { return }
        isMoving = true
        generation += 1
        defer { isMoving = false }
        do {
            let result = try await client.moveConversation(conversationId: conversation.id, folderId: folder.id,
                                                           dryRun: false)
            onMoved?(result, folder)
        } catch is CancellationError {
            // Nothing to say.
        } catch {
            preview = failure(error, folderID: folder.id, moving: true)
        }
    }

    private func check(_ folder: FolderDetail) async -> Preview {
        do {
            let result = try await client.moveConversation(conversationId: conversation.id, folderId: folder.id,
                                                           dryRun: true)
            capabilities.noteAvailable(client: client)
            return .ready(folderID: folder.id, result: result)
        } catch {
            return failure(error, folderID: folder.id, moving: false)
        }
    }

    /// What a failed dry run or move says: the refusal in plain words, "needs
    /// a newer server" for a server without the move, else what went wrong.
    private func failure(_ error: Error, folderID: Int, moving: Bool) -> Preview {
        if let refusal = error as? SessionMoveRefusal {
            return .refused(folderID: folderID, message: refusal.errorDescription ?? refusal.serverMessage)
        }
        if let api = error as? APIError, api.isEndpointMissing {
            capabilities.noteMissing(client: client)
            return .serverTooOld
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .refused(folderID: folderID, message: moving
                        ? String(localized: "Couldn’t move the session: \(message)")
                        : String(localized: "Couldn’t check the move: \(message)"))
    }
}
