import Foundation

// MARK: - Wire

/// How far a move takes the agent's own files (Rust `MoveMode`).
enum SessionMoveMode: String, Decodable, Equatable, Sendable {
    /// Everything moves: the agent continues in the new project's folder.
    case full
    /// Only the row moves: the agent keeps running in the folder it ran in.
    case listedOnly = "listed_only"

    /// An unknown mode reads as listed only, the move that promises less:
    /// the conversation's `working_dir` says where it runs either way.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionMoveMode(rawValue: raw) ?? .listedOnly
    }
}

/// Why a move is listed only (Rust `ListedOnlyReason`).
enum SessionMoveReason: String, Decodable, Equatable, Sendable {
    /// codeg can't move this agent's session files safely.
    case agentUnsupported = "agent_unsupported"
    /// The server's Claude Code adapter predates the relocation record.
    case claudeAdapterOutdated = "claude_adapter_outdated"
    /// The session's files aren't where the agent keeps them.
    case sessionFilesNotFound = "session_files_not_found"
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionMoveReason(rawValue: raw) ?? .other
    }
}

/// What `move_conversation_to_folder` answers (Rust `MoveConversationResult`).
struct SessionMoveResult: Decodable, Equatable, Sendable {
    /// The conversation as it is now: moved, or unchanged after a dry run.
    let conversation: ConversationSummary
    let mode: SessionMoveMode
    /// Set with `mode = listed_only`.
    var reason: SessionMoveReason?
    /// The delegation sub-sessions that moved (or would move) with it.
    var movedChildren: [Int] = []
    /// Nothing was changed: the answer says what a move would do.
    var dryRun: Bool = false

    private enum CodingKeys: String, CodingKey {
        case conversation, mode, reason, movedChildren, dryRun
    }

    init(conversation: ConversationSummary, mode: SessionMoveMode, reason: SessionMoveReason? = nil,
         movedChildren: [Int] = [], dryRun: Bool = false) {
        self.conversation = conversation
        self.mode = mode
        self.reason = reason
        self.movedChildren = movedChildren
        self.dryRun = dryRun
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(ConversationSummary.self, forKey: .conversation)
        mode = try c.decode(SessionMoveMode.self, forKey: .mode)
        reason = (try? c.decodeIfPresent(SessionMoveReason.self, forKey: .reason)) ?? nil
        movedChildren = (try? c.decodeIfPresent([Int].self, forKey: .movedChildren)) ?? []
        dryRun = (try? c.decodeIfPresent(Bool.self, forKey: .dryRun)) ?? false
    }
}

/// A move the server refused. codeg puts the refusal's code in the error's
/// `i18n_params.code` (its `i18n_key` is `errors.<code>`) beside an English
/// `message`; ``errorDescription`` says it in plain words per code.
struct SessionMoveRefusal: LocalizedError, Equatable, Sendable {
    /// The code as the server sent it (also one this app doesn't know).
    let code: String
    /// The server's English sentence, for a code this app doesn't know.
    let serverMessage: String

    /// The refusals codeg names (`session_move::MoveRefusal`).
    enum Code: String, CaseIterable, Sendable {
        case conversationNotFound = "conversation_not_found"
        case folderNotFound = "folder_not_found"
        case sameFolder = "same_folder"
        case chatConversation = "chat_conversation"
        case chatFolder = "chat_folder"
        case subsession
        case unsupportedConversation = "unsupported_conversation"
        case workTaskLinked = "work_task_linked"
        case conversationRunning = "conversation_running"
        case resumePending = "resume_pending"
        case runningElsewhere = "running_elsewhere"
        case sessionClosing = "session_closing"
        case moveFailed = "move_failed"
    }

    var known: Code? { Code(rawValue: code) }

    var errorDescription: String? {
        guard let known else { return serverMessage }
        return Self.message(for: known)
    }

    static func message(for code: Code) -> String {
        switch code {
        case .conversationNotFound:
            return String(localized: "This session no longer exists.")
        case .folderNotFound:
            return String(localized: "That project is no longer in the workspace.")
        case .sameFolder:
            return String(localized: "The session is already in that project.")
        case .chatConversation:
            return String(localized: "Chat sessions have no project to move from.")
        case .chatFolder:
            return String(localized: "A session can’t be moved into a chat.")
        case .subsession:
            return String(localized: "A sub-session moves with the session that started it.")
        case .unsupportedConversation:
            return String(localized: "This kind of session can’t be moved.")
        case .workTaskLinked:
            return String(localized: "A work task runs this session; it stays with the task’s project.")
        case .conversationRunning:
            return String(localized: "The session is working. Move it once its reply has finished.")
        case .resumePending:
            return String(localized: "The session is about to continue by itself. Move it once that’s done, or turn its automatic continuation off.")
        case .runningElsewhere:
            return String(localized: "Claude Code is running this session outside codeg. Move it once that process has finished.")
        case .sessionClosing:
            return String(localized: "The session’s agent is still closing. Try again in a moment.")
        case .moveFailed:
            return String(localized: "The session’s files couldn’t be moved, so nothing was changed.")
        }
    }

    /// The refusal in a codeg error body (`status` outside 2xx), or nil when
    /// the body names no move refusal (an older server, a proxy, a 401).
    /// The code comes from `i18n_params.code`, else from `i18n_key`'s
    /// `errors.<code>`.
    static func parse(status: Int, body: Data) -> SessionMoveRefusal? {
        guard !(200..<300).contains(status),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let params = object["i18n_params"] as? [String: Any] ?? object["i18nParams"] as? [String: Any]
        var code = (params?["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if code.isEmpty, let key = object["i18n_key"] as? String ?? object["i18nKey"] as? String,
           key.hasPrefix("errors.") {
            code = String(key.dropFirst("errors.".count))
        }
        guard !code.isEmpty else { return nil }
        let message = (object["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return SessionMoveRefusal(code: code, serverMessage: message)
    }
}

// MARK: - Rules

/// Whether a server can move sessions (`move_conversation_to_folder`, codeg
/// fork.227), as ``SessionMoveCapabilities`` found out.
enum SessionMoveSupport: Equatable, Sendable {
    /// Not checked yet, or the check couldn't reach the server.
    case unknown
    case available
    /// An older server, without the move.
    case missing
}

/// "Move to Project…" as plain functions: when it is offered, which projects
/// the picker lists, and what its preview and the banner after a move say.
enum SessionMoveRules {
    /// Whether "Move to Project…" is offered for `summary` on a server whose
    /// support is `support`: a top-level regular session (codeg web's
    /// `canMoveToProject`: a chat has no project to leave, a sub-session moves
    /// with its parent). Hidden on a server known to lack the move; offered
    /// while that isn't known yet, and the sheet finds out.
    static func offersMove(_ summary: ConversationSummary, support: SessionMoveSupport) -> Bool {
        guard support != .missing, summary.parentId == nil else { return false }
        if let kind = summary.kind, kind != .regular { return false }
        return true
    }

    /// The projects the picker lists for a session in folder `currentFolderID`:
    /// the server's open projects as the Folders tab shows them (`folders`,
    /// ``FolderVisibility/visibleFolders(_:)``, so no chat folders and no
    /// worktree hidden under its repo), without the session's own, matching
    /// `query` by name or path. Active projects first, then the archived ones,
    /// each in the Folders tab's order (the server's order, then by name).
    static func choices(_ folders: [FolderDetail], currentFolderID: Int, archivedIDs: Set<Int>,
                        query: String) -> (active: [FolderDetail], archived: [FolderDetail]) {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let matching = FolderVisibility.visibleFolders(folders).filter { folder in
            guard folder.id != currentFolderID, folder.kind != .chat else { return false }
            let haystack = "\(folder.name) \(folder.path)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let sorted = matching.sorted {
            $0.sortOrder != $1.sortOrder
                ? $0.sortOrder < $1.sortOrder
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (sorted.filter { !archivedIDs.contains($0.id) }, sorted.filter { archivedIDs.contains($0.id) })
    }

    /// What the picker says a move to `project` will do (a dry run's
    /// `result`), for `agent`'s session.
    static func preview(_ result: SessionMoveResult, project: String, agent: String) -> String {
        switch result.mode {
        case .full:
            return String(localized: "Moves the session and its files to \(project). Its next message rereads the session once.")
        case .listedOnly:
            // A dry run changes nothing: the session runs where it runs now.
            let path = result.conversation.workingDir ?? ""
            switch result.reason ?? .other {
            case .agentUnsupported:
                return String(localized: "\(agent) keeps its sessions tied to the folder they ran in, so this session can only be listed under \(project). It keeps running in \(path).")
            case .claudeAdapterOutdated:
                return String(localized: "The Claude Code adapter on the server is too old to move session files, so this session can only be listed under \(project). It keeps running in \(path).")
            case .sessionFilesNotFound:
                return String(localized: "This session’s files aren’t where \(agent) keeps them, so it can only be listed under \(project). It keeps running in \(path).")
            case .other:
                return String(localized: "This session can only be listed under \(project). It keeps running in \(path).")
            }
        }
    }

    /// The line under the preview about the sub-sessions that move with it,
    /// or nil when none do.
    static func childrenNote(_ result: SessionMoveResult) -> String? {
        let count = result.movedChildren.count
        guard count > 0 else { return nil }
        return String(localized: "Its \(count) sub-sessions move with it.")
    }

    /// What the banner says once a move to `project` happened.
    static func notice(_ result: SessionMoveResult, project: String) -> SessionMoveNotice {
        switch result.mode {
        case .full:
            return SessionMoveNotice(title: String(localized: "Moved to \(project)"), detail: nil)
        case .listedOnly:
            let detail = result.conversation.workingDir.map { String(localized: "It keeps running in \($0)") }
            return SessionMoveNotice(title: String(localized: "Listed under \(project)"), detail: detail)
        }
    }
}

/// The banner after a move: what happened, and for a session moved without
/// its files, where it keeps running. Each move's banner is a new one (`id`),
/// also when it says the same as the last.
struct SessionMoveNotice: Equatable, Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String?

    /// What VoiceOver announces.
    var spoken: String { [title, detail].compactMap { $0 }.joined(separator: ". ") }
}
