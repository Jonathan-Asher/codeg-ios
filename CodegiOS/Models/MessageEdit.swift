import Foundation

// MARK: - Wire

/// What `acp_fork` is for (Rust `ForkMode`, `src-tauri/src/acp/fork.rs`).
/// "Fork from here" sends no mode (a plain branch). An edit forks strictly:
/// a reply the agent can't name refuses the fork instead of falling back to
/// the tail, which still holds the message being replaced.
enum ForkMode: String, Encodable, Sendable {
    case branch
    /// "Edit message", keeping the original as a separate conversation,
    /// titled "… (before edit)".
    case edit
    /// "Edit message", continuing in place (the default): the row holding the
    /// original branch is hidden.
    case editInPlace = "edit_in_place"
}

// MARK: - Rules

/// Where editing a user message takes the conversation (codeg web's
/// `UserEditTarget`, `message-list-view.tsx`).
enum MessageEditTarget: Equatable, Sendable {
    /// Fork at the reply right before the message, up to and including it
    /// (its last turn), so the forked session ends exactly where the message
    /// was. `ready` is false only while that reply is still being written.
    case fork(forkPointID: String, ready: Bool)
    /// Nothing precedes the message: saving starts a new conversation.
    case first
}

/// Why Save can't run right now (web `UserEditBlock`). The Edit item greys
/// out and says so.
enum MessageEditBlock: Equatable, Sendable {
    case busy
    case queued
    case notReady

    /// web `editBusy`, `editQueued`, `editNotReady`.
    var reason: String {
        switch self {
        case .busy: return String(localized: "Can’t edit while a turn is running")
        case .queued: return String(localized: "Can’t edit while messages are waiting in the queue")
        case .notReady: return String(localized: "Can’t edit this message just yet — try again in a moment")
        }
    }
}

/// What saving an edit does, which decides the editor's wording.
enum MessageEditKind: Equatable, Sendable {
    /// The conversation continues from here with the edited message, in
    /// place of the original (`edit_in_place`, the default).
    case inPlace
    /// A new branch, the original kept as "… (before edit)" (`edit`).
    case newBranch
    /// The first message: a new conversation with the edited text.
    case newConversation

    init(target: MessageEditTarget, keepOriginal: Bool) {
        switch target {
        case .first: self = .newConversation
        case .fork: self = keepOriginal ? .newBranch : .inPlace
        }
    }

    /// The hint under the text (web `editHintInPlace`, `editHint`,
    /// `editHintNewConversation`).
    var hint: String {
        switch self {
        case .inPlace:
            return String(localized: "Saving continues this conversation from here with the edited message, in place of the original. File changes are not undone.")
        case .newBranch:
            return String(localized: "Saving starts a new branch from here. The original conversation stays in the sidebar, and file changes are not undone.")
        case .newConversation:
            return String(localized: "This is the first message, so saving starts a new conversation with it. This one stays as it is, and file changes are not undone.")
        }
    }

    /// Save's label while saving (web `editSavingInPlace`, `editSaving`,
    /// `editSavingNewConversation`).
    var savingLabel: String {
        switch self {
        case .inPlace: return String(localized: "Continuing from here…")
        case .newBranch: return String(localized: "Starting a new branch…")
        case .newConversation: return String(localized: "Opening a new conversation…")
        }
    }
}

/// Whether "Edit Message" is offered on a message, and if not, why.
enum MessageEditAvailability: Equatable, Sendable {
    /// Not offered (an older server, an agent whose fork can't land on a
    /// chosen message, a message with no reply right before it).
    case hidden
    case available(MessageEditTarget)
    /// Shown, greyed out, with the reason.
    case blocked(MessageEditTarget, MessageEditBlock)

    var isEnabled: Bool {
        if case .available = self { return true }
        return false
    }

    var target: MessageEditTarget? {
        switch self {
        case .hidden: return nil
        case .available(let target), .blocked(let target, _): return target
        }
    }

    var reason: String? {
        if case .blocked(_, let block) = self { return block.reason }
        return nil
    }
}

/// codeg web's edit rules (`src/lib/edit-message.ts`,
/// `computeUserEditTargets` in `message-list-view.tsx`) as plain functions.
enum MessageEditRules {
    /// Agents whose adapter forks EXACTLY at a named reply or refuses
    /// (`EDITABLE_AGENTS`, Rust `honours_fork_point_strictly`). Pi's falls
    /// back to the tail when it misses, so an edit there would quietly
    /// continue the original.
    static let editableAgents: Set<String> = ["claude_code", "codex", "deepseek"]

    static func supports(_ agent: AgentType) -> Bool {
        editableAgents.contains(agent.wireValue)
    }

    /// The edit target of the user message `turnID` in the held transcript,
    /// nil when it can't be edited here: what comes right before it isn't a
    /// reply (another message, a system note, a compaction), or it is the
    /// first held turn while older ones are still on the server. Never the
    /// message's own id: a fork keeps its point, so forking AT the message
    /// would keep the very text the edit replaces. A Continue divider has no
    /// text worth editing.
    static func target(for turnID: String, in turns: [MessageTurn], hasOlderTurns: Bool,
                       replyStillRunning: Bool = false) -> MessageEditTarget? {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return nil }
        let message = turns[index]
        guard message.role == .user, ContinuePrompt.variant(of: message) == nil, isServerTurn(message)
        else { return nil }
        // The item before it, stepping over turns that render nothing.
        var previous = index - 1
        while previous >= 0, turns[previous].blocks.isEmpty { previous -= 1 }
        guard previous >= 0 else { return hasOlderTurns ? nil : .first }
        guard turns[previous].role == .assistant else { return nil }
        // The reply this is: the run of assistant turns ending at `previous`.
        var start = previous
        while start > 0, turns[start - 1].role == .assistant || turns[start - 1].blocks.isEmpty { start -= 1 }
        let reply = turns[start...previous].filter { $0.role == .assistant }
        guard !isCompactionOnly(reply) else { return nil }
        return .fork(forkPointID: turns[previous].id, ready: !replyStillRunning)
    }

    /// Why Save can't run now: a turn running or a message just sent that
    /// isn't a turn yet (an edit forking under it would carry it into the
    /// new branch), messages waiting in the queue (written after the message
    /// being edited, they would follow it into the branch), or the reply
    /// before it still being written. Another edit being saved counts as busy.
    static func block(_ target: MessageEditTarget, turnRunning: Bool, awaitingPersist: Bool,
                      queued: Bool, saving: Bool) -> MessageEditBlock? {
        if turnRunning || awaitingPersist || saving { return .busy }
        if queued { return .queued }
        if case .fork(_, let ready) = target, !ready { return .notReady }
        return nil
    }

    /// The text an edit starts from: the message's text blocks as sent,
    /// joined as codeg web joins them.
    static func editableText(_ turn: MessageTurn) -> String {
        turn.blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pictures a message carries, sent again unchanged with its edit.
    static func images(_ turn: MessageTurn) -> [ImageData] {
        turn.blocks.compactMap { block -> ImageData? in
            if case .image(let image) = block, !image.data.isEmpty, image.dataRef == nil { return image }
            return nil
        }
    }

    static func forkMode(keepOriginal: Bool) -> ForkMode {
        keepOriginal ? .edit : .editInPlace
    }

    /// The reply an edit forks at, found in a freshly read transcript (web
    /// `resolveEditForkPointInTranscript`), for a reply this phone has no
    /// server name for. The message is found by its place among the user
    /// turns, and its text has to match too; the fork point is the turn right
    /// before it, stepping over empty ones, and must be a reply.
    static func resolveForkPoint(in turns: [MessageTurn], userOrdinal: Int, messageText: String) -> String? {
        let users = turns.indices.filter { turns[$0].role == .user }
        guard userOrdinal >= 0, userOrdinal < users.count else { return nil }
        let index = users[userOrdinal]
        guard comparable(editableText(turns[index])) == comparable(messageText) else { return nil }
        var i = index - 1
        while i >= 0 {
            if turns[i].blocks.isEmpty { i -= 1; continue }
            return turns[i].role == .assistant ? turns[i].id : nil
        }
        return nil
    }

    /// A turn the server named (it has the server's exact time); one the
    /// phone made stands in until the next fetch replaces it.
    static func isServerTurn(_ turn: MessageTurn) -> Bool {
        turn.serverMillis != nil
    }

    /// Text compared as a person reads it: runs of whitespace are one space.
    private static func comparable(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A reply whose only content is a context compaction, shown as a
    /// divider rather than a reply (the web hoists it out of the thread).
    private static func isCompactionOnly(_ reply: [MessageTurn]) -> Bool {
        var compactionIDs: [String?] = []
        for block in reply.flatMap(\.blocks) {
            switch block {
            case .toolUse(let id, _, _, let meta) where ContextCompaction.matches(meta):
                compactionIDs.append(id)
            case .toolResult(let id, _, _, _) where compactionIDs.contains(id):
                continue
            case .text(let text), .thinking(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            default:
                return false
            }
        }
        return compactionIDs.count == 1
    }
}

// MARK: - Errors

/// Why an edit wasn't sent, in codeg web's words (`Folder.conversation.*`).
enum MessageEditError: LocalizedError, Equatable {
    case busy
    case queued
    case replyNotFound
    case historyFailed(keptOriginal: Bool)
    case newConversationFailed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return String(localized: "Can’t edit the message while a turn is running")
        case .queued:
            return String(localized: "Can’t edit the message while messages are waiting in the queue")
        case .replyNotFound:
            return Self.failedText(String(localized: "the reply before this message couldn’t be found in the saved conversation"))
        case .historyFailed(let keptOriginal):
            return keptOriginal
                ? String(localized: "The new branch was created, but its history didn’t load, so the edited message wasn’t sent. Try Save & send again.")
                : String(localized: "The conversation was rewound to this point, but its history didn’t load, so the edited message wasn’t sent. Try Save & send again.")
        case .newConversationFailed:
            return String(localized: "Couldn’t open a new conversation for the edited message")
        case .failed(let detail):
            return Self.failedText(detail)
        }
    }

    private static func failedText(_ detail: String) -> String {
        String(localized: "Couldn’t edit the message: \(detail)")
    }
}

/// The phone's "Keep the original as a separate conversation when editing"
/// (codeg web keeps it per browser, in Settings › General). Off by default:
/// an edit continues the same conversation.
enum MessageEditPreferences {
    static let keepOriginalKey = "codeg.editMessage.keepOriginal"

    static func keepOriginal(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: keepOriginalKey)
    }
}
