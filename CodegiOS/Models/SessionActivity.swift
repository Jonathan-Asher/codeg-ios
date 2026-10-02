import Foundation

/// What a session is doing right now. A port of the codeg fork's
/// `src/lib/session-activity.ts` (`deriveSessionActivity`) and
/// `src/lib/background-idle.ts`.
///
/// The conversation's `status` is its review state (open / review / done /
/// cancelled) and cannot say whether a session is working, waiting for you,
/// idle for days, or cut off mid-turn. This can.
enum SessionActivity: Equatable, Sendable {
    /// A turn is in flight.
    case working
    /// A turn is in flight only because background work holds it open: the
    /// agent itself answered and is idle, and a message runs right away.
    /// Known only with this client's own live connection. `count` 0 means
    /// "running, count unknown".
    case background(count: Int)
    /// Blocked on a permission, a question or a plan approval.
    case needsYou
    /// Nothing is running.
    case idle
    /// The last turn was cut off before it finished.
    case interrupted
    /// The last turn stopped on the usage limit; the session continues by
    /// itself once the limit resets.
    case limitPaused(LimitPause)
    /// This client is opening the session. `phase` is the latest
    /// `attach_progress` phase, when one arrived.
    case connecting(phase: String?)
    /// This client's attempt to open the session failed.
    case connectFailed

    /// Whether a turn is running here and now (the row pulse, the badge).
    var isWorking: Bool { self == .working }
}

/// Inputs to ``SessionActivity/derive(_:)``, mirroring `SessionActivityInputs`.
struct SessionActivityInputs: Sendable {
    /// What the session is blocked on (`permission` / `question` /
    /// `plan_approval`), from the attention snapshot or a pending card.
    var attention: String? = nil
    /// The summary's `turn_state`.
    var turnState: ConversationTurnState? = nil
    /// Whether the server sends `turn_state` at all. False for a server that
    /// predates it; `status` is then the fallback.
    var turnStateReported: Bool = true
    /// The summary's review status, consulted only when `turn_state` is absent.
    var status: ConversationStatus? = nil
    /// This client's own live connection status, when it holds one.
    var connectionStatus: ConnectionStatus? = nil
    /// This client's own attempt to open the session.
    var connection: ConnectAttempt? = nil
    /// The live connection says its prompting turn is held for background
    /// work. Only meaningful with `connectionStatus == .prompting`.
    var awaitingBackground: Bool = false
    /// How many background tasks run (0 = unknown).
    var backgroundCount: Int = 0
    /// The summary's usage-limit pause.
    var limitPause: LimitPause? = nil

    enum ConnectAttempt: Equatable, Sendable {
        case connecting(phase: String?)
        case failed
    }
}

extension SessionActivity {
    /// `deriveSessionActivity`, rule for rule.
    static func derive(_ i: SessionActivityInputs) -> SessionActivity {
        // Blocked on the user outranks everything: the session IS mid-turn, but
        // it can't continue without you.
        if let attention = i.attention, !attention.isEmpty { return .needsYou }
        // Streaming here and now, or idle with background work holding the turn.
        if i.connectionStatus == .prompting {
            return i.awaitingBackground ? .background(count: max(0, i.backgroundCount)) : .working
        }
        // This client cannot reach the agent right now.
        switch i.connection {
        case .failed: return .connectFailed
        case .connecting(let phase): return .connecting(phase: phase)
        case nil: break
        }
        // A live connection sitting idle is first-hand proof that no turn runs.
        let liveAndIdle = i.connectionStatus == .connected
        if i.turnState != .running, let pause = i.limitPause, pause.isWaiting {
            return .limitPaused(pause)
        }
        if i.turnState == .interrupted { return .interrupted }
        if i.turnState == .running { return liveAndIdle ? .idle : .working }
        if !i.turnStateReported, i.status == .inProgress, !liveAndIdle {
            // Server predates `turn_state`: fall back to what the list always read.
            return .working
        }
        return .idle
    }

    /// A summary's activity from its own fields, with no live connection.
    static func of(_ summary: ConversationSummary, attention: String? = nil) -> SessionActivity {
        derive(SessionActivityInputs(
            attention: attention,
            turnState: summary.turnState,
            turnStateReported: summary.turnStateReported,
            status: summary.status,
            limitPause: summary.limitPause
        ))
    }
}

// MARK: - Labels

extension SessionActivity {
    /// The one-line label (English; the app's other strings localize through
    /// the string catalog, these mirror `Folder.sessionActivity` in codeg).
    func label(agentName: String? = nil, now: Date = Date()) -> String {
        switch self {
        case .working: return "Working"
        case .background(let count):
            switch count {
            case 0: return "Idle — background work running"
            case 1: return "Idle — 1 background task running"
            default: return "Idle — \(count) background tasks running"
            }
        case .needsYou: return "Needs you"
        case .idle: return "Idle"
        case .interrupted: return "Interrupted"
        case .limitPaused(let pause):
            if pause.state == .claimed { return "Continuing — the usage limit has reset" }
            let parts = LimitResetFormat.parts(resetsAt: pause.resetsAt, now: now)
            return "Paused — limit resets at \(parts.time) (in \(parts.remaining))"
        case .connecting(let phase):
            guard let phase, let step = Self.attachPhaseLabel(phase, agentName: agentName) else {
                return "Connecting…"
            }
            return "Connecting… (\(step))"
        case .connectFailed: return "Couldn't connect"
        }
    }

    /// `ChatPanel.attachPhase` wording.
    static func attachPhaseLabel(_ phase: String, agentName: String?) -> String? {
        let agent = agentName ?? "the agent"
        switch phase {
        case "queued": return "waiting to start \(agent)"
        case "starting": return "starting \(agent)"
        case "resuming": return "resuming the \(agent) session"
        case "loading": return "loading the \(agent) session"
        case "creating": return "creating a \(agent) session"
        case "configuring": return "applying \(agent) session settings"
        default: return nil
        }
    }

    /// A short hint under the label.
    var hint: String {
        switch self {
        case .working: return "A turn is running right now."
        case .background: return "The agent has answered and is idle while its background work finishes. A message you send now runs right away."
        case .needsYou: return "The agent is waiting for you before it can go on."
        case .idle: return "Nothing is running. Send a message to start a turn."
        case .interrupted: return "The last turn was cut off before it finished. Continue picks it up where it left off."
        case .limitPaused: return "The account hit its usage limit. This session continues by itself shortly after the limit resets."
        case .connecting: return "The agent is opening this session."
        case .connectFailed: return "The agent could not be reached."
        }
    }

    /// Coarse kind for styling.
    enum Tone: Sendable { case active, attention, quiet, warning, paused }

    var tone: Tone {
        switch self {
        case .working, .connecting: return .active
        case .needsYou: return .attention
        case .idle, .background: return .quiet
        case .interrupted, .connectFailed: return .warning
        case .limitPaused: return .paused
        }
    }

    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .background: return "hourglass"
        case .needsYou: return "hand.raised.fill"
        case .idle: return "moon.zzz"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .limitPaused: return "pause.circle.fill"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .connectFailed: return "wifi.exclamationmark"
        }
    }
}

// MARK: - Usage-limit reset wording (`lib/limit-continue.ts`)

enum LimitResetFormat {
    struct Parts: Equatable, Sendable {
        let time: String
        let remaining: String
    }

    /// When the limit resets, as a clock time (with the day when it is not
    /// within the next 24 hours), and how long that is from now.
    static func parts(resetsAt: Date, now: Date = Date(), locale: Locale = .current,
                      timeZone: TimeZone = .current) -> Parts {
        let ms = resetsAt.timeIntervalSince(now) * 1000
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(ms < 24 * 3600 * 1000 ? "HH:mm" : "EEE MMM d HH:mm")
        return Parts(time: formatter.string(from: resetsAt), remaining: formatRemaining(ms: ms))
    }

    /// A compact span: `2d 4h`, `3h 12m`, `12m`, `<1m`.
    static func formatRemaining(ms: Double) -> String {
        let minutes = Int((max(0, ms) / 60_000).rounded(.up))
        if minutes < 1 { return "<1m" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }
}

// MARK: - Held turns (`lib/background-idle.ts`)

/// Where a plain send from the composer goes.
enum ComposerSendRoute: Equatable, Sendable {
    /// An ordinary prompt: the session is idle.
    case send
    /// Into the turn held open for background work, right away.
    case deliver
    /// The local queue, sent when the turn ends.
    case enqueue
}

enum HeldTurn {
    /// The connection is prompting only because background work holds the turn.
    static func isAwaitingBackground(status: ConnectionStatus?, awaitingBackground: Bool) -> Bool {
        status == .prompting && awaitingBackground
    }

    /// A message can be delivered into the held turn right now.
    static func canDeliver(status: ConnectionStatus?, awaitingBackground: Bool, nativeSteering: Bool) -> Bool {
        isAwaitingBackground(status: status, awaitingBackground: awaitingBackground) && nativeSteering
    }

    /// `routeComposerSend`: while the agent is really replying a plain send
    /// queues (the explicit "insert into current turn" is a separate action);
    /// while the turn is only held for background work it is delivered at once.
    static func route(isPrompting: Bool, canDeliverNow: Bool) -> ComposerSendRoute {
        if !isPrompting { return .send }
        if canDeliverNow { return .deliver }
        return .enqueue
    }
}

// MARK: - Continue (`lib/continue-turn.ts`, `lib/auto-resume.ts`, `lib/limit-continue.ts`)

enum ContinuePrompt {
    /// What the Continue action sends. Not localized: it goes to the agent.
    static let text = "continue"

    /// The backend's `RESUME_AFTER_RESTART_PROMPT`, verbatim.
    static let resumeAfterRestart =
        "codeg restarted while you were working, so your last turn was cut off. Anything that was running in the background (sub-agents, background shells, monitors) was stopped. Continue where you left off, re-launching anything that still needs to run."

    /// The backend's `LIMIT_CONTINUE_PROMPT`, verbatim.
    static let limitContinue =
        "Your usage limit has reset. Continue the task you were working on when the usage limit was reached; do not repeat work that is already complete."

    /// The kinds of "keep going" turn drawn as a divider instead of a bubble.
    enum Variant: String, Equatable, Sendable {
        /// The user's Continue.
        case continued
        /// codeg picked a turn back up after a restart.
        case resumed
        /// codeg continued once the usage limit reset.
        case limit

        var label: String {
            switch self {
            case .continued: return "Continued"
            case .resumed: return "Resumed after restart"
            case .limit: return "Continued after limit reset"
            }
        }

        var hint: String {
            switch self {
            case .continued: return "You asked the agent to keep going"
            case .resumed: return "codeg restarted in the middle of this turn and picked the session back up on its own"
            case .limit: return "The account's usage limit reset and codeg continued the session on its own"
            }
        }
    }

    /// Which divider a user message's text reads as, if any. Exact match on
    /// the trimmed text, as on the desktop.
    static func variant(ofText text: String) -> Variant? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Self.text { return .continued }
        if trimmed == resumeAfterRestart { return .resumed }
        if trimmed == limitContinue { return .limit }
        return nil
    }

    /// A user turn is a divider only when it is text alone: an image or any
    /// other block makes it a message the user wrote.
    static func variant(of turn: MessageTurn) -> Variant? {
        guard turn.role == .user, !turn.blocks.isEmpty else { return nil }
        var text = ""
        for block in turn.blocks {
            guard case .text(let t) = block else { return nil }
            text += t
        }
        return variant(ofText: text)
    }

    /// The thread's newest message is the agent's (system notices skipped).
    static func endsWithAgentReply(_ turns: [MessageTurn]) -> Bool {
        for turn in turns.reversed() {
            if turn.role == .system { continue }
            return turn.role == .assistant
        }
        return false
    }
}
