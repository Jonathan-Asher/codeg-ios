import Foundation

// MARK: - Wire shapes

/// What `acp_fork` did (Rust `ForkResultInfo`): forked IN PLACE. The
/// conversation's own row and connection moved to the forked session, titled
/// `[Fork] …`, and a new sibling row keeps the original history under the old
/// title.
struct ForkResult: Decodable, Equatable, Sendable {
    let forkedSessionId: String
    let originalSessionId: String
    /// The row that now holds the original (pre-fork) history.
    let siblingConversationId: Int
}

/// What `acp_fork_to_new_conversation` did (Rust `ForkToNewConversationInfo`):
/// forked a finished reply into a NEW row while a turn runs. The original row,
/// its connection and its running turn are untouched.
struct ForkToNewConversationResult: Decodable, Equatable, Sendable {
    let forkedSessionId: String
    let originalSessionId: String
    /// The new row, bound to the forked session.
    let conversationId: Int
    let folderId: Int
    /// `[Fork] …`, or nil for an untitled original.
    let title: String?
}

// MARK: - Outcome

/// Where a fork landed. Either way there is one row for the fork and one for
/// the original; they only differ in which row id is which.
enum ForkOutcome: Equatable, Sendable {
    /// Between turns: `conversationID` (the row the fork was asked on) is now
    /// the fork, and `result.siblingConversationId` holds the original.
    case inPlace(ForkResult, conversationID: Int)
    /// While a turn ran: a new row holds the fork, and `originalID` is the
    /// row the fork was asked on, unchanged.
    case newConversation(ForkToNewConversationResult, originalID: Int)

    /// The row to open: the fork.
    var forkConversationID: Int {
        switch self {
        case .inPlace(_, let id): return id
        case .newConversation(let result, _): return result.conversationId
        }
    }

    /// The row that keeps the original history.
    var originalConversationID: Int {
        switch self {
        case .inPlace(let result, _): return result.siblingConversationId
        case .newConversation(_, let id): return id
        }
    }

    var isInPlace: Bool {
        if case .inPlace = self { return true }
        return false
    }
}

// MARK: - Errors

/// Why a fork didn't happen, in the words codeg web uses.
enum ForkError: LocalizedError, Equatable {
    /// The server has no fork endpoints (`not_implemented`).
    case serverTooOld
    /// The agent doesn't advertise `session/fork` (snapshot `fork_supported`).
    case agentCannotFork(String)
    /// A turn runs and this agent only forks between turns
    /// (`AcpError::ForkNeedsIdle`, or a turn the web would grey out for).
    case betweenTurnsOnly
    /// A reply this phone has no server name for yet (web `forkNotReady`).
    case notReady
    /// A turn runs and no reply before it has finished yet.
    case noFinishedReply
    /// The agent connection couldn't be opened.
    case connectFailed(String)
    /// Anything else the server said (web `forkSessionFailed`).
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .serverTooOld:
            return String(localized: "This codeg server can’t fork sessions. Update codeg to fork from the phone.")
        case .agentCannotFork(let agent):
            return String(localized: "\(agent) can’t fork sessions.")
        case .betweenTurnsOnly:
            return String(localized: "Can’t fork yet: this agent can only fork between turns")
        case .notReady:
            return String(localized: "Can’t fork from this reply just yet — try again in a moment")
        case .noFinishedReply:
            return String(localized: "Can’t fork yet: no reply has finished in this session")
        case .connectFailed(let detail):
            return String(localized: "Couldn’t connect to the agent to fork: \(detail)")
        case .failed(let detail):
            return String(localized: "Failed to fork session: \(detail)")
        }
    }
}

// MARK: - Availability

/// Whether a fork action is offered, and if not, why.
enum ForkAvailability: Equatable, Sendable {
    /// Offered and enabled.
    case available
    /// Shown, greyed out, with the reason.
    case unavailable(String)
    /// A fork of this session is under way.
    case forking
    /// Not offered at all.
    case hidden

    var isEnabled: Bool { self == .available }

    /// The reason to show under a greyed-out item.
    var reason: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .forking: return String(localized: "Forking…")
        case .available, .hidden: return nil
        }
    }
}

/// What the server lets this phone fork with (`ForkCapabilities`).
enum ForkEndpoints: Equatable, Sendable {
    /// Not checked yet, or the check couldn't reach the server.
    case unknown
    /// `acp_fork` is there; `toNewConversation` says whether
    /// `acp_fork_to_new_conversation` (forking while a turn runs) is too.
    case available(toNewConversation: Bool)
    /// Neither endpoint: an older server.
    case missing
}

/// codeg web's rules for "Fork from here" and where a fork lands
/// (`src/lib/fork-from-turn.ts`, `message-list-view.tsx`), as plain functions.
enum SessionForkRules {
    /// Agents whose fork works while a turn runs (into a new conversation).
    /// Mirrors `FORK_WHILE_RUNNING_AGENTS` / Rust `forks_while_running`: only
    /// Claude Code's adapter forks safely from a transcript another process
    /// is still writing.
    static func forksWhileRunning(_ agent: AgentType) -> Bool {
        agent == .claudeCode
    }

    static let reasonBetweenTurns = String(localized: "This agent can only fork between turns")
    static let reasonNotReady = String(localized: "Can’t fork from this reply just yet — try again in a moment")
    static let reasonInFlight = String(localized: "This reply is still running. Fork from an earlier reply, or from this one once it finishes")
    static let reasonServerTooOld = String(localized: "Needs a newer codeg server")
    static let reasonAnotherFork = String(localized: "Another fork is in progress")

    /// A fork button's availability while a fork may be under way. Forks run
    /// one at a time (``SessionActions``): the button the fork was taken from
    /// shows "Forking…", every other offered one is greyed out with why, and a
    /// hidden one stays hidden. `theForkUnderWay` is nil while no fork runs,
    /// true for the button that started the one that does.
    static func whileForking(_ availability: ForkAvailability, theForkUnderWay: Bool?) -> ForkAvailability {
        guard let theForkUnderWay, availability != .hidden else { return availability }
        return theForkUnderWay ? .forking : .unavailable(reasonAnotherFork)
    }

    static func reasonAgentCannotFork(_ agent: AgentType) -> String {
        String(localized: "\(agent.displayName) can’t fork sessions")
    }

    /// The last turn of the latest reply that finished before a running turn's
    /// prompt, as codeg's `settle_mid_run_fork_point` decides: the prompt is
    /// `inFlightPromptID` when the server matched it, otherwise the last user
    /// turn of the transcript. nil when no reply comes before it.
    static func latestFinishedReply(in turns: [MessageTurn], inFlightPromptID: String?) -> String? {
        let promptIndex = inFlightPromptID.flatMap { id in turns.firstIndex { $0.id == id && $0.role == .user } }
            ?? turns.lastIndex { $0.role == .user }
        guard let promptIndex else { return nil }
        return turns[..<promptIndex].last { $0.role == .assistant && $0.serverMillis != nil }?.id
    }

    /// Availability of the session-level "Fork Session" on a list row, from
    /// what the list knows: the server's endpoints, what the agent reported,
    /// and whether a turn runs.
    static func listAvailability(
        endpoints: ForkEndpoints,
        agent: AgentType,
        agentForks: Bool?,
        turnRunning: Bool,
        forking: Bool
    ) -> ForkAvailability {
        if forking { return .forking }
        if endpoints == .missing { return .unavailable(reasonServerTooOld) }
        if agentForks == false { return .unavailable(reasonAgentCannotFork(agent)) }
        if turnRunning {
            if !forksWhileRunning(agent) { return .unavailable(reasonBetweenTurns) }
            if case .available(let toNew) = endpoints, !toNew { return .unavailable(reasonBetweenTurns) }
        }
        return .available
    }

    /// Whether a list summary says a turn runs: the turn state when the server
    /// reports it, else the in-progress status, or a turn held open only for
    /// background work (still a turn in flight on the connection).
    static func turnRunning(_ summary: ConversationSummary) -> Bool {
        if summary.background?.heldOpen == true { return true }
        if summary.turnStateReported { return summary.turnState == .running }
        return summary.status == .inProgress
    }

    /// Availability of "Fork from here" on the reply that ends at `turnID`, on
    /// the open session: hidden on an older server or when the reply isn't in
    /// `turns`; greyed out while a turn runs for an agent that only forks
    /// between turns, for the reply still being written, and for a reply the
    /// server has no name for unless it is the transcript's tail (the tail
    /// fork lands there anyway).
    static func replyAvailability(
        turnID: String,
        turns: [MessageTurn],
        pendingPrompt: Bool,
        endpoints: ForkEndpoints,
        agent: AgentType,
        agentForks: Bool?,
        turnRunning: Bool,
        forking: Bool
    ) -> ForkAvailability {
        if endpoints == .missing { return .hidden }
        guard let index = turns.firstIndex(where: { $0.id == turnID }), turns[index].role == .assistant
        else { return .hidden }
        if forking { return .forking }
        if agentForks == false { return .unavailable(reasonAgentCannotFork(agent)) }
        let isTail = index == turns.count - 1
        if turnRunning {
            if !forksWhileRunning(agent) { return .unavailable(reasonBetweenTurns) }
            if case .available(let toNew) = endpoints, !toNew { return .unavailable(reasonBetweenTurns) }
            // With the running prompt still on the phone (a send from here),
            // every reply in `turns` has finished. Otherwise the reply after
            // the last prompt is the one being written.
            if !pendingPrompt, let prompt = turns.lastIndex(where: { $0.role == .user }), index > prompt {
                return .unavailable(reasonInFlight)
            }
            if turns[index].serverMillis == nil { return .unavailable(reasonNotReady) }
            return .available
        }
        if turns[index].serverMillis == nil, !isTail { return .unavailable(reasonNotReady) }
        return .available
    }
}
