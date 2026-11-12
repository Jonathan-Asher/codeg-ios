import Foundation

// MARK: - A session whose history is gone (codeg fork.230, `commands::lost_history`)

/// Why a session's history is gone, as far as the server can tell (Rust
/// `HistoryUnavailableReason`). An unknown value from a newer server reads as
/// `missing`.
enum HistoryUnavailableReason: String, Codable, Hashable, Sendable {
    /// The agent deletes sessions past an age, and this one was past it:
    /// Claude Code removes transcripts older than its `cleanupPeriodDays`.
    case agentCleanup = "agent_cleanup"
    /// The agent's record is gone for a reason codeg can't tell.
    case missing
}

/// The agent's own record of a session is gone (its transcript was deleted)
/// while codeg's records show the session had one: the conversation detail's
/// `history_unavailable` (Rust `HistoryUnavailable`). Such a session can be
/// neither resumed nor forked, so it opens read-only. A server that predates
/// it never sends the field.
struct HistoryUnavailable: Codable, Hashable, Sendable {
    var reason: HistoryUnavailableReason
    /// The age past which the agent deletes a session, in days
    /// (`agent_cleanup` only).
    var retentionDays: Int?
    /// How many of the session's turns the server's message search kept:
    /// their text, without tool calls or tool output.
    var savedTurns: Int

    init(reason: HistoryUnavailableReason = .missing, retentionDays: Int? = nil, savedTurns: Int = 0) {
        self.reason = reason
        self.retentionDays = retentionDays
        self.savedTurns = savedTurns
    }

    private enum CodingKeys: String, CodingKey {
        case reason, retentionDays, savedTurns
    }

    /// Lenient: an unknown reason reads as `missing`, a missing or odd count
    /// as nothing saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        reason = raw.flatMap(HistoryUnavailableReason.init(rawValue:)) ?? .missing
        let days = (try? c.decodeIfPresent(Int.self, forKey: .retentionDays)) ?? nil
        retentionDays = days.flatMap { $0 > 0 ? $0 : nil }
        savedTurns = max(0, ((try? c.decodeIfPresent(Int.self, forKey: .savedTurns)) ?? nil) ?? 0)
    }

    /// The agent's cleanup explains it, with the period it ran under.
    var cleanupDays: Int? {
        reason == .agentCleanup ? retentionDays : nil
    }
}

/// One turn's text as the server's message search kept it (Rust `SavedTurn`,
/// `get_conversation_saved_turns`), oldest first.
struct SavedTurn: Codable, Hashable, Sendable {
    /// The turn's position in the session as it was last read.
    var turnIdx: Int
    var role: TurnRole
    var content: String

    init(turnIdx: Int, role: TurnRole, content: String) {
        self.turnIdx = turnIdx
        self.role = role
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case turnIdx, role, content
    }

    /// Lenient, so one odd row never costs the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnIdx = ((try? c.decodeIfPresent(Int.self, forKey: .turnIdx)) ?? nil) ?? 0
        role = ((try? c.decodeIfPresent(TurnRole.self, forKey: .role)) ?? nil) ?? .system
        content = ((try? c.decodeIfPresent(String.self, forKey: .content)) ?? nil) ?? ""
    }
}

/// Which copy a session whose history is gone shows.
enum LostHistoryCopy: Equatable, Sendable {
    /// The transcript this iPhone kept of it: whole turns, tool calls and
    /// their output included.
    case iPhone
    /// The text the server's message search saved: the messages only.
    case saved

    /// The iPhone's copy wins when it holds at least as many turns as the
    /// server saved (its turns are whole, the server's are text only); the
    /// server's saved text otherwise, which then has more of the session.
    static func choose(heldTurns: Int, savedTurns: Int) -> LostHistoryCopy {
        heldTurns > 0 && heldTurns >= savedTurns ? .iPhone : .saved
    }
}

/// A connect this phone did not make, or the server refused, because the
/// session's history is gone.
struct HistoryUnavailableError: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "The agent no longer has this session’s history, so it can’t be resumed.")
    }

    /// `error` says the session's history is gone: this error, or the
    /// server's refusal (``APIError/isHistoryUnavailable``).
    static func matches(_ error: Error) -> Bool {
        if error is HistoryUnavailableError { return true }
        return (error as? APIError)?.isHistoryUnavailable == true
    }
}

// MARK: - "Start a new session from this"

/// What "Start a new session from this" puts in the new session's message
/// box: codeg's `buildSavedHistoryPrefill` over its `saved_history_markdown`.
/// A short preamble with the saved text under it, or, when the text is
/// longer than a message box takes, the preamble with the text attached as a
/// Markdown file. Messages this session never sent follow, so they aren't
/// lost. Nothing is sent: the person reads, edits and sends it.
enum SavedHistoryText {
    /// Where the turns come from.
    enum Source: Sendable {
        /// The text the server's message search saved.
        case server
        /// The copy this iPhone kept.
        case iPhone
    }

    /// Up to this many characters the saved text goes in the message box as
    /// it is; longer, it is attached as a file (the server's
    /// `INLINE_EXPORT_MAX_CHARS`).
    static let inlineMaxChars = 4_000

    /// The text of the copy this iPhone kept, a turn each, as the server's
    /// message search keeps a turn: its text blocks only. Turns without
    /// text are left out. `offset` is the global index of `kept[0]`.
    static func turns(from kept: [MessageTurn], offset: Int = 0) -> [SavedTurn] {
        kept.enumerated().compactMap { index, turn in
            let text = turn.blocks.compactMap { block -> String? in
                guard case .text(let t) = block else { return nil }
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            return SavedTurn(turnIdx: offset + index, role: turn.role, content: text)
        }
    }

    /// The turns as one Markdown document: a heading, a line saying what it
    /// is and what it lacks, then each turn under its speaker. Written for
    /// the agent that reads it, so in English whatever the app's language.
    static func markdown(title: String?, agentName: String, turns: [SavedTurn], source: Source) -> String {
        let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownTitle = (heading?.isEmpty == false ? heading : nil) ?? "Untitled session"
        let what: String
        switch source {
        case .server:
            what = "The text codeg saved from an earlier \(agentName) session whose history \(agentName) no longer has: the messages only. Tool calls and their output were not kept, and messages too long to index are left out."
        case .iPhone:
            what = "The text this iPhone kept of an earlier \(agentName) session whose history \(agentName) no longer has: the messages only. Tool calls and their output are left out."
        }
        var out = "# \(shownTitle)\n\n\(what)\n"
        for turn in turns {
            let speaker: String
            switch turn.role {
            case .user: speaker = "User"
            case .assistant: speaker = agentName
            case .system: speaker = "System"
            }
            out += "\n## \(speaker)\n\n\(turn.content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return out
    }

    /// The preamble over saved text that follows it in the message box.
    static func inlinePreamble(agentName: String, title: String) -> String {
        String(localized: "This continues an earlier \(agentName) session, “\(title)”, whose history \(agentName) no longer has. Below is the text saved from it: the messages only, without tool calls or their output. Take it as context for what I ask next.")
    }

    /// The preamble over saved text attached as a file.
    static func attachedPreamble(agentName: String, title: String) -> String {
        String(localized: "This continues an earlier \(agentName) session, “\(title)”, whose history \(agentName) no longer has. The attached file holds the text saved from it: the messages only, without tool calls or their output. Take it as context for what I ask next.")
    }

    /// The file a long saved text is attached as.
    static func fileName(conversationID: Int) -> String { "conversation-\(conversationID).md" }

    /// The new session's message box: the saved text with its preamble
    /// (inline, or attached when long), then `unsent` (messages this session
    /// never sent, each as its text) and `pictures` (theirs). With nothing
    /// saved there is no preamble, which would promise text that isn't
    /// there; nil when there is nothing at all to carry.
    static func prefill(conversationID: Int, title: String?, agentName: String, turns: [SavedTurn],
                        source: Source, unsent: [String] = [], pictures: [Attachment] = []) -> ComposerPrefill? {
        let carried = unsent.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownTitle = (trimmedTitle?.isEmpty == false ? trimmedTitle : nil) ?? String(localized: "Untitled session")
        guard !turns.isEmpty else {
            guard !carried.isEmpty || !pictures.isEmpty else { return nil }
            return ComposerPrefill(text: carried, pictures: pictures)
        }
        let document = markdown(title: title, agentName: agentName, turns: turns, source: source)
        if document.unicodeScalars.count <= inlineMaxChars {
            var text = inlinePreamble(agentName: agentName, title: shownTitle) + "\n\n"
                + document.trimmingCharacters(in: .whitespacesAndNewlines)
            // A rule keeps the message from reading as part of the last turn.
            if !carried.isEmpty { text += "\n\n---\n\n" + carried }
            return ComposerPrefill(text: text, pictures: pictures)
        }
        var text = attachedPreamble(agentName: agentName, title: shownTitle)
        if !carried.isEmpty { text += "\n\n" + carried }
        return ComposerPrefill(
            text: text,
            document: ComposerPrefill.Document(fileName: fileName(conversationID: conversationID), contents: document),
            pictures: pictures
        )
    }
}
