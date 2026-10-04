import Foundation

// MARK: - The session screen's event socket

/// What the session screen needs from its event socket. ``EventStream`` is the
/// real one; the unit tests use a scripted one.
protocol SessionEventStream: AnyObject, Sendable {
    var frames: AsyncStream<EventStream.Frame> { get }
    func start()
    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?)
    func detach(subscriptionId: String)
    func close()
}

extension EventStream: SessionEventStream {}

// MARK: - Attach handshake of a send

/// What a send does when its event socket doesn't attach. Only the prompt
/// itself can fail a send: the socket is retried a few times, and when it
/// still won't attach the prompt goes anyway and the stream is recovered once
/// the turn runs. A reconnect's attach snapshot carries the whole reply
/// streamed so far, so nothing is lost by attaching late.
enum StreamHandshake {
    /// Sockets a send opens before it prompts without one.
    static let maxAttempts = 3
    /// How long the server gets to confirm an attach. A healthy server answers
    /// at once with a snapshot (or a detach).
    static let attachTimeout: Duration = .seconds(12)

    enum Failure: Error, Equatable {
        /// The socket closed, or the server detached it for a passing reason
        /// (`lagged`, `server_shutdown`), before the attach was confirmed:
        /// a frame too large for the socket, a dropped LTE connection.
        case dropped(reason: String?)
        /// No confirmation within ``attachTimeout``.
        case timedOut
    }

    enum Next: Equatable {
        /// Open a fresh socket after this pause.
        case retry(after: Duration)
        /// Send the prompt without a stream and recover the stream afterwards.
        case promptWithoutStream
    }

    /// `attempt` counts from 1. A drop is retried with a short backoff; a
    /// timeout is not (another 12 seconds would only delay the message).
    static func next(after failure: Failure, attempt: Int) -> Next {
        switch failure {
        case .timedOut:
            return .promptWithoutStream
        case .dropped:
            guard attempt < maxAttempts else { return .promptWithoutStream }
            return .retry(after: .milliseconds(500 * (1 << max(0, attempt - 1))))
        }
    }
}

// MARK: - What an attach snapshot says about the turn

extension LiveSessionSnapshot {
    /// A permission, question or plan approval waits for the user.
    var hasPendingCard: Bool {
        pendingPermission != nil || pendingQuestion != nil || pendingPlanApproval != nil
    }

    /// A turn runs on this connection right now: the agent is prompting (also
    /// while the turn is only held open for background work), or the turn
    /// waits on a card. A `live_message` alone is not a turn: when the agent
    /// keeps working after its turn ended (it woke up for a background task's
    /// notification), the server collects that out-of-turn output into
    /// `live_message` while the connection is idle. The session list, the
    /// server and the codeg web client all read such a session as idle.
    var isTurnInFlight: Bool {
        status == .prompting || hasPendingCard
    }

    enum TurnPhase: Equatable, Sendable {
        /// A turn runs (see ``LiveSessionSnapshot/isTurnInFlight``).
        case running
        /// A prompt was taken (`pending_user_message` is set) and the agent is
        /// about to start on it.
        case starting
        /// No turn runs: the last one ended.
        case ended
        /// The agent's connection is down or failed.
        case connectionDown
    }

    /// What a reconnect makes of this snapshot while the screen shows a turn.
    var turnPhase: TurnPhase {
        if isTurnInFlight { return .running }
        switch status {
        case .disconnected?, .error?:
            return .connectionDown
        default:
            return pendingUserMessageId == nil ? .ended : .starting
        }
    }
}

// MARK: - Confirming an unclear send

enum SendConfirmation {
    /// The note the server recorded for a message sent into the running turn:
    /// the newest with the same text that isn't already matched to another
    /// message on screen. `submit_session_feedback` takes no client id, so the
    /// text is what ties a note to its message.
    static func recordedNote(text: String, in notes: [FeedbackNoteSnapshot],
                             excluding claimed: Set<String>) -> FeedbackNoteSnapshot? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return notes.last {
            !claimed.contains($0.id) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
    }

    /// The prompt with this client message id is the turn the server runs (or
    /// is about to run). The server echoes the id as the turn's
    /// `pending_user_message` until the turn ends.
    static func promptIsRunning(clientMessageID: String, in snapshot: LiveSessionSnapshot?) -> Bool {
        guard let id = snapshot?.pendingUserMessageId, !id.isEmpty else { return false }
        return id == clientMessageID
    }
}
