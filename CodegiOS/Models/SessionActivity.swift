import Foundation

/// What a session is doing right now. A port of the codeg fork's
/// `src/lib/session-activity.ts` (`deriveSessionActivity`) and
/// `src/lib/background-idle.ts`.
///
/// The conversation's `status` is its review state (open / review / done /
/// cancelled) and cannot say whether a session is working, waiting for you,
/// idle for days, or cut off mid-turn. This can.
enum SessionActivity: Equatable, Sendable {
    /// A turn is in flight: one codeg sent, or one the agent runs by itself
    /// after its background work woke it (known from the server's
    /// `background.out_of_turn`; `turn_state` never shows it).
    case working
    /// The agent is idle while its background work runs: a turn held open
    /// only for background tasks (a message runs right away), or tasks still
    /// running after the turn ended. Known from this client's own live
    /// connection, or for any session from the server's `background`.
    /// `count` 0 means "running, count unknown".
    case background(count: Int)
    /// Blocked on a permission, a question or a plan approval.
    case needsYou
    /// Nothing is running.
    case idle
    /// The last turn was cut off before it finished.
    case interrupted
    /// The last turn stopped on the usage limit; the session continues by
    /// itself once the limit resets (or, paused by the account pool, once an
    /// account frees up). The pause carries why it waits.
    case limitPaused(LimitPause)
    /// The last turn stopped on a usage limit and no longer continues by
    /// itself: the continuations kept meeting the limit and gave up, or they
    /// were cancelled. The turn is interrupted, with the manual Continue.
    case limitStopped(LimitReason)
    /// This client is opening the session. `phase` is the latest
    /// `attach_progress` phase, when one arrived; `poolResumesAt` comes with
    /// `pool_wait` (every account of the account pool is at its limit).
    case connecting(phase: String?, poolResumesAt: Date? = nil)
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
    /// The summary's `limit_reason`: why the pause waits, or why the last
    /// turn stopped once the pause has ended.
    var limitReason: LimitReason? = nil
    /// The server's live background status (`background`): tasks running,
    /// the agent working out of turn, a turn held open. Nil when nothing and
    /// against an older server, which then reads exactly as before.
    var background: ConversationBackground? = nil

    enum ConnectAttempt: Equatable, Sendable {
        case connecting(phase: String?, poolResumesAt: Date? = nil)
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
        case .connecting(let phase, let poolResumesAt): return .connecting(phase: phase, poolResumesAt: poolResumesAt)
        case nil: break
        }
        // The agent runs a turn of its own (its background work woke it): no
        // turn codeg sent is in flight, so only the server's status knows.
        if i.background?.outOfTurn == true { return .working }
        // A live connection sitting idle is first-hand proof that no turn runs.
        let liveAndIdle = i.connectionStatus == .connected
        let tasks = max(0, i.background?.taskCount ?? 0)
        // The turn is held open only for background work, by the server's word.
        if i.background?.heldOpen == true, !liveAndIdle { return .background(count: tasks) }
        if i.turnState != .running, var pause = i.limitPause, pause.isWaiting {
            pause.reason = i.limitReason ?? .usageLimit
            return .limitPaused(pause)
        }
        if i.turnState == .interrupted {
            // `limitStopReason`: stopped on a usage limit, no pause left.
            if i.limitPause == nil, let reason = i.limitReason { return .limitStopped(reason) }
            return .interrupted
        }
        if i.turnState == .running {
            if !liveAndIdle { return .working }
            return tasks > 0 ? .background(count: tasks) : .idle
        }
        if !i.turnStateReported, i.status == .inProgress, !liveAndIdle {
            // Server predates `turn_state`: fall back to what the list always read.
            return .working
        }
        // The turn ended; the work it started didn't.
        if tasks > 0 { return .background(count: tasks) }
        return .idle
    }

    /// A summary's activity from its own fields, with no live connection.
    static func of(_ summary: ConversationSummary, attention: String? = nil) -> SessionActivity {
        derive(SessionActivityInputs(
            attention: attention,
            turnState: summary.turnState,
            turnStateReported: summary.turnStateReported,
            status: summary.status,
            limitPause: summary.limitPause,
            limitReason: summary.limitReason,
            background: summary.background
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
            if pause.isPool { return "Paused by usage limits — continues at \(parts.time)" }
            return "Paused — limit resets at \(parts.time) (in \(parts.remaining))"
        case .limitStopped: return "Stopped by usage limits"
        case .connecting(let phase, let poolResumesAt):
            if phase == "pool_wait", let poolResumesAt {
                let time = LimitResetFormat.parts(resetsAt: poolResumesAt, now: now).time
                return "Connecting… (all Claude subscriptions are at their limit — the next one frees at \(time))"
            }
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
        case "pool_wait": return "all Claude subscriptions are at their limit"
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
        case .limitPaused(let pause) where pause.isPool:
            return "Every Claude account behind the account pool is at its limit. This session continues by itself once one frees up."
        case .limitPaused: return "The account hit its usage limit. This session continues by itself shortly after the limit resets."
        case .limitStopped: return "The last turn stopped on a usage limit and no longer continues by itself. Continue it once the limit allows."
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
        case .interrupted, .connectFailed, .limitStopped: return .warning
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
        case .limitStopped: return "pause.circle"
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

    /// The backend's `LIMIT_CONTINUE_PROMPT`, verbatim. Since codeg's
    /// limit-continue also picks up the sub-agents the limit stopped.
    static let limitContinue =
        "Your usage limit has reset. First resume any sub-agents the limit stopped, each from where it stopped with its context intact rather than starting it over; then continue the task you were working on when the usage limit was reached. Do not repeat work that is already complete."

    /// The continuation's earlier wording, still in older transcripts.
    static let earlierLimitContinues = [
        "Your usage limit has reset. Continue the task you were working on when the usage limit was reached; do not repeat work that is already complete.",
    ]

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
        if trimmed == limitContinue || earlierLimitContinues.contains(trimmed) { return .limit }
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
