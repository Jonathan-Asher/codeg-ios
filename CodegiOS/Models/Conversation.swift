import SwiftUI

/// A project/workspace on a codeg server (Rust `FolderDetail`). The iOS app
/// treats folders as a filter dimension under a server, and uses `path` as the
/// `workingDir` when (re)connecting an agent.
struct FolderDetail: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let path: String
    let gitBranch: String?
    let defaultAgentType: AgentType?
    let lastOpenedAt: Date
    let sortOrder: Int
    let color: String
    /// Root folder this one was created under (worktree folders only); `nil` for
    /// a top-level folder. Drives the sidebar worktree-child hide and the branch
    /// switcher's root resolution. Decoded from `parent_id`; absent on older
    /// servers → `nil`.
    var parentId: Int?
    /// Server `kind`. `chat` scratch folders are hidden from the folder lists;
    /// `regular` is a user folder. Absent / unknown on older servers → `.regular`.
    var kind: FolderKind

    private enum CodingKeys: String, CodingKey {
        case id, name, path, gitBranch, defaultAgentType, lastOpenedAt, sortOrder, color, parentId, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        defaultAgentType = try c.decodeIfPresent(AgentType.self, forKey: .defaultAgentType)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        color = try c.decode(String.self, forKey: .color)
        parentId = try c.decodeIfPresent(Int.self, forKey: .parentId)
        // Tolerate an absent key (older server) and an unknown value (lenient
        // `FolderKind` decode) — neither should fail the whole folder.
        kind = (try? c.decodeIfPresent(FolderKind.self, forKey: .kind)) ?? .regular
    }

    /// Memberwise initializer (preserved for the few call sites that build a
    /// `FolderDetail` directly, e.g. previews/tests).
    init(
        id: Int, name: String, path: String, gitBranch: String?,
        defaultAgentType: AgentType?, lastOpenedAt: Date, sortOrder: Int,
        color: String, parentId: Int? = nil, kind: FolderKind = .regular
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.defaultAgentType = defaultAgentType
        self.lastOpenedAt = lastOpenedAt
        self.sortOrder = sortOrder
        self.color = color
        self.parentId = parentId
        self.kind = kind
    }

    /// True when this folder is a git worktree created under another folder.
    var isWorktree: Bool { parentId != nil }
}

/// Folder classification (Rust `FolderKind`). `chat` folders back chat-mode
/// scratch dirs and are hidden from folder lists; `regular` is a user folder.
/// `.other` is the escape hatch for an unknown wire value.
enum FolderKind: String, Codable, Hashable, Sendable {
    case regular
    case chat
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FolderKind(rawValue: raw) ?? .other
    }
}

/// Lifecycle status of a conversation row. Stored as a free-form string on the
/// wire; modeled as an enum with an `.other` escape hatch.
enum ConversationStatus: String, Codable, Hashable, Sendable {
    case inProgress = "in_progress"
    case pendingReview = "pending_review"
    case completed = "completed"
    case cancelled = "cancelled"
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationStatus(rawValue: raw) ?? .other
    }

    var label: LocalizedStringKey {
        switch self {
        case .inProgress: return "Running"
        case .pendingReview: return "Review"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        case .other: return "—"
        }
    }

    var tint: Color {
        switch self {
        case .inProgress: return Color(red: 0.42, green: 0.78, blue: 0.95)
        case .pendingReview: return Theme.warning
        case .completed: return Color(red: 0.52, green: 0.82, blue: 0.56)
        case .cancelled: return Color.secondary
        case .other: return Color.secondary
        }
    }

    var isLive: Bool { self == .inProgress }

    /// The real statuses a user can assign from the actions menu (excludes the
    /// `.other` decode escape hatch), in the order the web client lists them.
    static let selectable: [ConversationStatus] = [.inProgress, .pendingReview, .completed, .cancelled]
}

/// Posted (no payload) whenever a conversation is mutated from the detail
/// screen — renamed, pinned, status-changed, or deleted. The session list is a
/// separate view model with no `onAppear` reload, so it observes this to refetch
/// instead of showing a stale title/status or a still-tappable deleted row.
extension Notification.Name {
    static let conversationsDidChange = Notification.Name("codeg.conversationsDidChange")
    /// Posted (no payload) when the folder set changes outside the normal poll —
    /// e.g. a worktree folder was just registered from the branch switcher. Folder-
    /// backed lists (Folders tab, Chats grouping) observe it to refetch promptly
    /// instead of waiting for the 25s pulse.
    static let foldersDidChange = Notification.Name("codeg.foldersDidChange")
}

/// A conversation/session persisted on a server (Rust `DbConversationSummary`).
struct ConversationSummary: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let folderId: Int
    /// `var` so the detail screen can optimistically reflect a rename before the
    /// server confirms (mirrors `pinnedAt`).
    var title: String?
    let agentType: AgentType
    /// `var` so a status change applies optimistically from the actions menu.
    var status: ConversationStatus
    let model: String?
    let gitBranch: String?
    let externalId: String?
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date
    /// When the user pinned this conversation (server `pinned_at`), or `nil` when
    /// not pinned. Servers that predate pinning (no field) decode to `nil`. A
    /// `var` so the list can optimistically flip it on a pin/unpin before the
    /// server confirms. Note: pinning does NOT bump `updatedAt` server-side — the
    /// "Pinned" group sorts by this timestamp instead.
    var pinnedAt: Date? = nil

    // MARK: Fork fields (codeg `fork/solution-plan`)

    /// Where the latest turn stands (`turn_state`): running, interrupted, or
    /// nil for no turn. See `turnStateReported` for an older server.
    var turnState: ConversationTurnState? = nil
    /// Whether the server sent `turn_state` at all (even as null). A server
    /// that predates it leaves this false, and activity falls back to `status`.
    var turnStateReported: Bool = false
    /// The user marked this conversation critical (alerts when it sits idle).
    var critical: Bool = false
    /// The usage-limit pause, when the last turn stopped on the account's limit.
    var limitPause: LimitPause? = nil
    /// Whether the session continues by itself once the limit resets.
    var limitAutoContinue: Bool = true
    /// The mode / model / effort this conversation's session last ran with.
    /// The decoder converts dictionary keys from snake_case too, which would
    /// mangle config ids like `reasoning_effort`, so this is filled from the raw
    /// JSON afterwards (`ConversationSelectorState.patch`), never here.
    var selectorState: ConversationSelectorState? = nil

    private enum CodingKeys: String, CodingKey {
        case id, folderId, title, agentType, status, model, gitBranch, externalId
        case messageCount, createdAt, updatedAt, pinnedAt
        case turnState, critical, limitPause, limitAutoContinue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        folderId = try c.decode(Int.self, forKey: .folderId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        agentType = try c.decode(AgentType.self, forKey: .agentType)
        status = try c.decode(ConversationStatus.self, forKey: .status)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        // The fork fields are all lenient: an unknown value or shape must never
        // fail the whole conversation list.
        turnStateReported = c.contains(.turnState)
        turnState = (try? c.decodeIfPresent(ConversationTurnState.self, forKey: .turnState)) ?? nil
        critical = (try? c.decodeIfPresent(Bool.self, forKey: .critical)) ?? false
        limitPause = (try? c.decodeIfPresent(LimitPause.self, forKey: .limitPause)) ?? nil
        limitAutoContinue = (try? c.decodeIfPresent(Bool.self, forKey: .limitAutoContinue)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(folderId, forKey: .folderId)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(agentType, forKey: .agentType)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try c.encodeIfPresent(externalId, forKey: .externalId)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encodeIfPresent(turnState, forKey: .turnState)
        try c.encode(critical, forKey: .critical)
        try c.encodeIfPresent(limitPause, forKey: .limitPause)
        try c.encode(limitAutoContinue, forKey: .limitAutoContinue)
    }

    /// Non-empty, trimmed user-provided title, or `nil` for an unnamed session.
    /// Render this verbatim (user data, never localized) and fall back to a
    /// localized "Untitled session" only when it is `nil`.
    var trimmedTitle: String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    /// Plain-text title for search/filtering (NOT for localized display — use
    /// `trimmedTitle` + a literal fallback at the render site for that).
    var displayTitle: String { trimmedTitle ?? "Untitled session" }

    var isPinned: Bool { pinnedAt != nil }
}

/// Rust `ConversationTurnState`.
enum ConversationTurnState: String, Codable, Hashable, Sendable {
    case running
    case interrupted
}

/// Rust `ConversationLimitResume`: waiting for the reset (`scheduled`), the
/// continuation being sent (`claimed`), or its turn running (`continuing`).
enum LimitResumeState: String, Codable, Hashable, Sendable {
    case scheduled
    case claimed
    case continuing
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LimitResumeState(rawValue: raw) ?? .other
    }
}

/// A conversation paused by the account's usage limit (Rust `LimitPause`).
struct LimitPause: Codable, Hashable, Sendable {
    let resetsAt: Date
    let state: LimitResumeState
    let attempts: Int

    init(resetsAt: Date, state: LimitResumeState, attempts: Int = 0) {
        self.resetsAt = resetsAt
        self.state = state
        self.attempts = attempts
    }

    /// Waiting for the reset: the continuation has not run yet (`scheduled`)
    /// or is being sent (`claimed`). A `continuing` pause reads as working.
    var isWaiting: Bool { state == .scheduled || state == .claimed }
}

/// The selector values one conversation's session runs with (Rust
/// `ConversationSelectorState`, camelCase on the wire): the ACP mode and the
/// config option values by option id (`model`, `effort`, `fast`, …).
struct ConversationSelectorState: Hashable, Sendable {
    var modeId: String?
    var configValues: [String: String]

    init(modeId: String? = nil, configValues: [String: String] = [:]) {
        self.modeId = modeId
        self.configValues = configValues
    }

    var isEmpty: Bool { (modeId ?? "").isEmpty && configValues.isEmpty }

    /// Read from a `JSONSerialization` object, which keeps keys verbatim.
    init?(raw: Any?) {
        guard let dict = raw as? [String: Any] else { return nil }
        modeId = dict["modeId"] as? String
        var values: [String: String] = [:]
        if let config = dict["configValues"] as? [String: Any] {
            for (key, value) in config {
                switch value {
                case let s as String: values[key] = s
                case let n as NSNumber:
                    values[key] = CFGetTypeID(n) == CFBooleanGetTypeID()
                        ? (n.boolValue ? "true" : "false") : n.stringValue
                default: break
                }
            }
        }
        configValues = values
        if isEmpty { return nil }
    }

    /// `selector_state` per conversation id, read from a raw response body: a
    /// summary list, a single summary, or a detail with a `summary`.
    static func index(from data: Data) -> [Int: ConversationSelectorState] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var out: [Int: ConversationSelectorState] = [:]
        func visit(_ object: Any) {
            guard let dict = object as? [String: Any] else { return }
            if let summary = dict["summary"] { visit(summary) }
            guard let id = (dict["id"] as? NSNumber)?.intValue,
                  let state = ConversationSelectorState(raw: dict["selector_state"]) else { return }
            out[id] = state
        }
        if let list = root as? [Any] { list.forEach(visit) } else { visit(root) }
        return out
    }

    /// Fill `selectorState` on summaries decoded from `data`.
    static func patch(_ summaries: [ConversationSummary], from data: Data) -> [ConversationSummary] {
        let states = index(from: data)
        guard !states.isEmpty else { return summaries }
        return summaries.map { summary in
            var s = summary
            s.selectorState = states[summary.id]
            return s
        }
    }

    /// Display rows: the effort-like and model values first, then the mode,
    /// then anything else, as (label, value).
    var displayItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        let preferred = ["model", "effort", "reasoning_effort", "thought_level", "fast"]
        for key in preferred {
            if let v = configValues[key], !v.isEmpty { items.append((Self.label(for: key), v)) }
        }
        if let mode = modeId, !mode.isEmpty { items.append(("Mode", mode)) }
        for key in configValues.keys.sorted() where !preferred.contains(key) {
            if let v = configValues[key], !v.isEmpty { items.append((Self.label(for: key), v)) }
        }
        return items
    }

    static func label(for key: String) -> String {
        switch key {
        case "model": return "Model"
        case "effort", "reasoning_effort", "thought_level": return "Effort"
        case "fast": return "Fast"
        default:
            let words = key.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

/// Aggregate token/timing stats for a session (Rust `SessionStats`).
struct SessionStats: Codable, Hashable, Sendable {
    let totalUsage: TurnUsage?
    let totalTokens: Int?
    let totalDurationMs: Int
    let contextWindowUsedTokens: Int?
    let contextWindowMaxTokens: Int?
    let contextWindowUsagePercent: Double?
}

/// Full session detail incl. message history (Rust `DbConversationDetail`).
/// Decode-only: `MessageTurn`/`ContentBlock` are response shapes we never encode.
struct ConversationDetail: Decodable, Sendable {
    var summary: ConversationSummary
    let turns: [MessageTurn]
    let sessionStats: SessionStats?
    let inFlightUserTurnId: String?
}

/// Returned by `acp_find_connection_for_conversation` when a live ACP
/// connection already owns a conversation.
struct ConversationConnectionInfo: Codable, Sendable {
    let connectionId: String
    let eventSeq: UInt64
}

/// `health` endpoint response — used to validate a server profile.
struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
}
