import Foundation
import Observation

/// What this phone knows about forking on each server: which fork endpoints
/// the server has (checked once), and which agents said whether they can fork
/// (every live snapshot carries `fork_supported`). Keyed by server endpoint,
/// like the transcript cache.
@MainActor
@Observable
final class ForkCapabilities {
    static let shared = ForkCapabilities()

    private var endpointsByServer: [String: ForkEndpoints] = [:]
    private var agentForks: [String: [String: Bool]] = [:]
    /// What each agent's adapter said about forking while a turn runs.
    private var agentForksWhileRunning: [String: [String: Bool]] = [:]
    @ObservationIgnored private var probes: [String: Task<ForkEndpoints, Never>] = [:]
    /// Whether each server's `acp_fork` takes an edit mode.
    private var editModesByServer: [String: Bool] = [:]
    @ObservationIgnored private var editProbes: [String: Task<Bool?, Never>] = [:]

    func endpoints(for client: CodegClient) -> ForkEndpoints {
        endpointsByServer[TranscriptCache.serverKey(for: client)] ?? .unknown
    }

    /// Whether this server can edit messages (an edit `mode` on `acp_fork`);
    /// nil until checked.
    func editModes(for client: CodegClient) -> Bool? {
        editModesByServer[TranscriptCache.serverKey(for: client)]
    }

    /// Check once whether the server can edit messages. A check that couldn't
    /// reach the server leaves it unknown, to be tried again.
    @discardableResult
    func probeEditModesIfNeeded(client: CodegClient) async -> Bool? {
        let key = TranscriptCache.serverKey(for: client)
        if let known = editModesByServer[key] { return known }
        if let running = editProbes[key] { return await running.value }
        let task = Task { try? await client.forkEditModesSupported() }
        editProbes[key] = task
        let result = await task.value
        editProbes[key] = nil
        if let result { editModesByServer[key] = result }
        return result
    }

    /// Whether `agent` reported it can fork on this server; nil until a
    /// session of it was seen live.
    func agentForks(_ agent: AgentType, client: CodegClient) -> Bool? {
        agentForks[TranscriptCache.serverKey(for: client)]?[agent.wireValue]
    }

    /// Whether `agent`'s adapter said it forks while a turn runs on this
    /// server (`fork_while_running`); nil until a live session of it said so.
    func agentForksWhileRunning(_ agent: AgentType, client: CodegClient) -> Bool? {
        agentForksWhileRunning[TranscriptCache.serverKey(for: client)]?[agent.wireValue]
    }

    /// `whileRunning` counts only beside a fork the agent supports: the
    /// server reports it false until the adapter has started.
    func note(agent: AgentType, forks: Bool?, whileRunning: Bool? = nil, client: CodegClient) {
        guard let forks else { return }
        let key = TranscriptCache.serverKey(for: client)
        if agentForks[key]?[agent.wireValue] != forks {
            agentForks[key, default: [:]][agent.wireValue] = forks
        }
        if forks, let whileRunning, agentForksWhileRunning[key]?[agent.wireValue] != whileRunning {
            agentForksWhileRunning[key, default: [:]][agent.wireValue] = whileRunning
        }
    }

    func noteEndpointsMissing(client: CodegClient) {
        endpointsByServer[TranscriptCache.serverKey(for: client)] = .missing
    }

    /// Check the server's fork endpoints unless that is known. A check that
    /// couldn't reach the server leaves it unknown, to be tried again.
    @discardableResult
    func probeIfNeeded(client: CodegClient) async -> ForkEndpoints {
        let key = TranscriptCache.serverKey(for: client)
        if let known = endpointsByServer[key], known != .unknown { return known }
        if let running = probes[key] { return await running.value }
        let task = Task { (try? await client.forkEndpoints()) ?? .unknown }
        probes[key] = task
        let result = await task.value
        probes[key] = nil
        if result != .unknown { endpointsByServer[key] = result }
        return result
    }

    /// Forget everything (tests).
    func reset() {
        endpointsByServer = [:]
        agentForks = [:]
        agentForksWhileRunning = [:]
        probes = [:]
        editModesByServer = [:]
        editProbes = [:]
    }
}

/// The session a fork is taken from.
struct ForkTarget: Equatable, Sendable {
    let conversationID: Int
    let folderID: Int
    let agentType: AgentType
    /// The row's agent session (`external_id`), to resume it when no
    /// connection is live.
    let sessionID: String?
    /// The folder the agent runs in.
    let workingDir: String?

    init(conversationID: Int, folderID: Int, agentType: AgentType, sessionID: String?, workingDir: String?) {
        self.conversationID = conversationID
        self.folderID = folderID
        self.agentType = agentType
        self.sessionID = sessionID
        self.workingDir = workingDir
    }

    init(summary: ConversationSummary, workingDir: String?) {
        self.init(conversationID: summary.id, folderID: summary.folderId, agentType: summary.agentType,
                  sessionID: summary.externalId, workingDir: workingDir)
    }
}

/// Where in the session to fork.
enum ForkPoint: Equatable, Sendable {
    /// "Fork from here" on a reply: the last turn of that reply. Between turns
    /// the fork lands there in place; while a turn runs it forks into a new
    /// conversation (an agent that can).
    case reply(String)
    /// "Fork Session": between turns, the whole session at its tail (a
    /// duplicate that continues on its own); while a turn runs, the latest
    /// reply that has finished.
    case latest
}

/// Takes a fork the way codeg web's `forkFromTurn` does, from a phone that may
/// have no live connection to the session yet:
///
/// 1. find the session's live connection, or resume it (`acp_connect` with
///    its session id), and wait until it is up;
/// 2. read whether the agent can fork and whether a turn runs from the
///    connection's snapshot;
/// 3. between turns, fork in place (`acp_fork`); while a turn runs, or when a
///    turn started under the request (`TurnInProgress`), fork a finished
///    reply into a new conversation (`acp_fork_to_new_conversation`) where the
///    agent can, and say "only between turns" where it can't.
@MainActor
struct SessionForker {
    let client: CodegClient
    var capabilities: ForkCapabilities = .shared
    /// How long a resumed connection may take to come up.
    var readyTimeout: Duration = .seconds(90)
    var pollInterval: Duration = .milliseconds(400)

    /// Fork `target` at `point`. `resolveConnection` gives a live connection
    /// id (the session screen's own); without one the forker finds or resumes
    /// it. `onConnection` hears the connection the fork ran on.
    func fork(
        _ target: ForkTarget,
        at point: ForkPoint,
        resolveConnection: (() async throws -> String)? = nil,
        onConnection: ((String) -> Void)? = nil
    ) async throws -> ForkOutcome {
        let endpoints = await capabilities.probeIfNeeded(client: client)
        if endpoints == .missing { throw ForkError.serverTooOld }
        var retried = false
        while true {
            do {
                let conn = try await connection(for: target, resolve: resolveConnection, fresh: retried)
                onConnection?(conn)
                let snapshot = try await waitUntilReady(conn)
                capabilities.note(agent: target.agentType, forks: snapshot.forkSupported,
                                  whileRunning: snapshot.forkWhileRunning, client: client)
                if snapshot.forkSupported == false {
                    throw ForkError.agentCannotFork(target.agentType.displayName)
                }
                return try await forkFromTurn(target, at: point, connection: conn,
                                              turnRunning: snapshot.status == .prompting,
                                              endpoints: endpoints,
                                              adapterForksWhileRunning: snapshot.forkWhileRunning)
            } catch let error as APIError where error.isConnectionNotFound || error.isStreamGone {
                // The connection went away between finding it and forking:
                // resume the session once more.
                guard !retried else { throw ForkError.failed(error.serverMessage) }
                retried = true
            } catch let error as APIError where error.isEndpointMissing {
                capabilities.noteEndpointsMissing(client: client)
                throw ForkError.serverTooOld
            } catch let error as APIError {
                throw ForkError.failed(error.serverMessage)
            }
        }
    }

    // MARK: - Steps

    private func connection(for target: ForkTarget, resolve: (() async throws -> String)?,
                            fresh: Bool) async throws -> String {
        if !fresh, let resolve { return try await resolve() }
        if !fresh, let found = try await client.findConnection(
            conversationId: target.conversationID, sessionId: target.sessionID, agentType: target.agentType
        )?.connectionId {
            return found
        }
        let prefs = SelectorPrefsStore.prefs(for: target.agentType)
        do {
            return try await client.connect(
                agentType: target.agentType,
                workingDir: target.workingDir,
                sessionId: target.sessionID,
                preferredModeId: prefs.modeId,
                preferredConfigValues: prefs.configValues
            )
        } catch let error as APIError {
            throw ForkError.connectFailed(error.serverMessage)
        }
    }

    /// Wait until the connection has started (`connected`, or `prompting` for
    /// a turn already running). `fork_supported` is reported before that.
    private func waitUntilReady(_ conn: String) async throws -> LiveSessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readyTimeout)
        while true {
            guard let snapshot = try await client.liveSessionSnapshot(connectionId: conn) else {
                throw APIError.streamGone
            }
            switch snapshot.status {
            case .connected?, .prompting?:
                return snapshot
            case .error?, .disconnected?:
                throw ForkError.connectFailed(String(localized: "the agent didn’t start"))
            case .connecting?, nil:
                break
            }
            guard clock.now < deadline else {
                throw ForkError.connectFailed(String(localized: "the agent took too long to start"))
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// codeg web's `forkFromTurn`: in place between turns, into a new
    /// conversation when a turn runs (or starts under the request).
    private func forkFromTurn(_ target: ForkTarget, at point: ForkPoint, connection conn: String,
                              turnRunning: Bool, endpoints: ForkEndpoints,
                              adapterForksWhileRunning: Bool?) async throws -> ForkOutcome {
        func intoNewConversation() async throws -> ForkOutcome {
            guard SessionForkRules.forksWhileRunning(target.agentType, adapter: adapterForksWhileRunning)
            else { throw ForkError.betweenTurnsOnly }
            if case .available(let toNew) = endpoints, !toNew { throw ForkError.betweenTurnsOnly }
            let reply: String
            switch point {
            case .reply(let id):
                reply = id
            case .latest:
                guard let latest = try await latestFinishedReply(target) else { throw ForkError.noFinishedReply }
                reply = latest
            }
            do {
                let result = try await client.forkToNewConversation(
                    connectionId: conn, conversationId: target.conversationID, forkFromTurnId: reply)
                return .newConversation(result, originalID: target.conversationID)
            } catch let error as APIError where error.isForkNeedsIdle {
                throw ForkError.betweenTurnsOnly
            } catch let error as APIError where error.isEndpointMissing {
                throw ForkError.betweenTurnsOnly
            }
        }

        if turnRunning { return try await intoNewConversation() }
        let turnID: String?
        switch point {
        case .reply(let id): turnID = id
        case .latest: turnID = nil
        }
        do {
            let result = try await client.fork(connectionId: conn, conversationId: target.conversationID,
                                               folderId: target.folderID, forkFromTurnId: turnID)
            return .inPlace(result, conversationID: target.conversationID)
        } catch APIError.turnInProgress {
            return try await intoNewConversation()
        }
    }

    /// The latest reply that finished before the running turn's prompt, read
    /// from a fresh transcript tail, as the server will check it.
    private func latestFinishedReply(_ target: ForkTarget) async throws -> String? {
        let detail = try await client.conversationDetail(id: target.conversationID, window: .tail(60))
        return SessionForkRules.latestFinishedReply(in: detail.turns, inFlightPromptID: detail.inFlightUserTurnId)
    }
}
