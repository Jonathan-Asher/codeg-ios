import Foundation

/// The custom fields of a codeg push (codeg `docs/ios-push.md` §5), read from
/// a notification's `userInfo`. Every field is optional on the wire except
/// `server_id` and `kind`; a payload without `kind` is not codeg's.
struct PushPayload: Equatable, Sendable {
    var serverID: String?
    var kind: String
    var alertID: String?
    var conversationID: Int?
    var folderID: Int?
    var agentType: String?
    var criticalKind: String?
    var needs: String?
    var connectionID: String?
    var requestID: String?
    var approveOptionID: String?
    var denyOptionID: String?
    var category: String?
    var threadID: String?
    /// `aps.badge`: how many items wait on the user on this server. Every
    /// push carries it on a server with the pending list; a `badge` push
    /// carries nothing else.
    var badge: Int?
    /// The item's id in `list_pending_items` (`needs_you` pushes).
    var pendingID: String?
    /// `permission`, `question` or `plan`.
    var pendingKind: String?
    /// When the session started waiting.
    var pendingSince: Date?
    /// A reminder of something still waiting (not the first push).
    var reminder = false
    /// `0` for the first push and the catch-up, `n` for the n-th reminder.
    var attempt: Int?
    /// A delegated sub-agent's item: its own session. `conversationID` is the
    /// parent, which is what opens.
    var askingConversationID: Int?
    /// Grok's plan approval waiting for a decision.
    var approvalID: String?
    /// The first question of a question push.
    var question: PushQuestion?

    init(kind: String, serverID: String? = nil, conversationID: Int? = nil, folderID: Int? = nil) {
        self.kind = kind
        self.serverID = serverID
        self.conversationID = conversationID
        self.folderID = folderID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = PushValue.string(userInfo["kind"]) else { return nil }
        self.kind = kind
        serverID = Self.string(userInfo["server_id"])
        alertID = Self.string(userInfo["alert_id"])
        conversationID = Self.int(userInfo["conversation_id"])
        folderID = Self.int(userInfo["folder_id"])
        agentType = Self.string(userInfo["agent_type"])
        criticalKind = Self.string(userInfo["critical_kind"])
        needs = Self.string(userInfo["needs"])
        connectionID = Self.string(userInfo["connection_id"])
        requestID = Self.string(userInfo["request_id"])
        approveOptionID = Self.string(userInfo["approve_option_id"])
        denyOptionID = Self.string(userInfo["deny_option_id"])
        pendingID = Self.string(userInfo["pending_id"])
        pendingKind = Self.string(userInfo["pending_kind"])
        pendingSince = Self.string(userInfo["pending_since"]).flatMap(ISO8601.parse)
        reminder = PushValue.bool(userInfo["reminder"]) ?? false
        attempt = Self.int(userInfo["attempt"])
        askingConversationID = Self.int(userInfo["asking_conversation_id"])
        approvalID = Self.string(userInfo["approval_id"])
        question = PushQuestion(userInfo["question"])
        if let aps = userInfo["aps"] as? [AnyHashable: Any] {
            category = Self.string(aps["category"])
            threadID = Self.string(aps["thread-id"])
            badge = Self.int(aps["badge"])
        }
    }

    /// A silent update of the icon badge (`kind: "badge"`).
    var isBadgeOnly: Bool { kind == "badge" }

    /// The fields to copy into a local follow-up notification ("already
    /// handled"), so tapping it opens the same session.
    var routingUserInfo: [String: Any] {
        var info: [String: Any] = ["kind": kind]
        if let serverID { info["server_id"] = serverID }
        if let conversationID { info["conversation_id"] = conversationID }
        if let folderID { info["folder_id"] = folderID }
        if let agentType { info["agent_type"] = agentType }
        return info
    }

    private static func string(_ value: Any?) -> String? { PushValue.string(value) }

    private static func int(_ value: Any?) -> Int? { PushValue.int(value) }
}

/// Category and action identifiers the server names (§6).
enum PushCategory {
    static let critical = "CODEG_CRITICAL"
    static let permission = "CODEG_PERMISSION"
    static let session = "CODEG_SESSION"
    /// A question; the extension may swap in a per-labels category with answer
    /// buttons (``QuestionCategory``).
    static let question = QuestionCategory.base
}

enum PushActionID {
    static let ack = "ACK"
    static let snooze = "SNOOZE"
    static let approve = "APPROVE"
    static let open = "OPEN"
    /// `UNNotificationDefaultActionIdentifier`: the notification was tapped.
    static let tap = "com.apple.UNNotificationDefaultActionIdentifier"
    /// `UNNotificationDismissActionIdentifier`.
    static let dismiss = "com.apple.UNNotificationDismissActionIdentifier"
}

/// What to do with a notification response.
enum PushAction: Equatable, Sendable {
    /// Open the session (a tap, or OPEN).
    case open(conversationID: Int, folderID: Int?)
    /// `ack_critical_session`.
    case ack(conversationID: Int)
    /// `snooze_critical_session` for `minutes`.
    case snooze(conversationID: Int, minutes: Int)
    /// `acp_respond_permission` with the "allow once" option.
    case approve(connectionID: String, requestID: String, optionID: String)
    /// `acp_answer_question` with one option of a single-choice question.
    case answer(connectionID: String, questionID: String, itemID: String, label: String)
    /// Nothing to do (dismissed, a test push tapped, fields missing).
    case none
}

enum PushRouting {
    /// The snooze the SNOOZE action asks for.
    static let snoozeMinutes = 15

    /// Map an action identifier + payload to what to do.
    static func action(for identifier: String, payload: PushPayload) -> PushAction {
        switch identifier {
        case PushActionID.ack:
            guard let id = payload.conversationID else { return .none }
            return .ack(conversationID: id)
        case PushActionID.snooze:
            guard let id = payload.conversationID else { return .none }
            return .snooze(conversationID: id, minutes: snoozeMinutes)
        case PushActionID.approve:
            guard let conn = payload.connectionID, let req = payload.requestID,
                  let option = payload.approveOptionID else {
                // No "allow" option to pick from here: open the session instead.
                return payload.conversationID.map { .open(conversationID: $0, folderID: payload.folderID) } ?? .none
            }
            return .approve(connectionID: conn, requestID: req, optionID: option)
        case PushActionID.open, PushActionID.tap:
            guard let id = payload.conversationID else { return .none }
            return .open(conversationID: id, folderID: payload.folderID)
        default:
            guard let index = QuestionCategory.answerIndex(identifier) else { return .none }
            guard let question = payload.question, let conn = payload.connectionID,
                  question.options.indices.contains(index) else {
                // Nothing to answer with: open the session instead.
                return payload.conversationID.map { .open(conversationID: $0, folderID: payload.folderID) } ?? .none
            }
            return .answer(connectionID: conn, questionID: question.questionID, itemID: question.itemID,
                           label: question.options[index])
        }
    }

    /// The `acp_answer_question` answer an `.answer` action sends.
    static func answer(itemID: String, label: String) -> QuestionAnswer {
        QuestionAnswer(answers: [QuestionAnswerItem(questionId: itemID, labels: [label])], declined: false)
    }

    /// The saved server a push came from: the one whose recorded codeg
    /// `server_id` matches. With no match and a single saved server, that one
    /// (its id may not have been recorded yet).
    static func serverProfileID(for serverID: String?, recorded: [UUID: String], saved: [UUID]) -> UUID? {
        if let serverID, let match = recorded.first(where: { $0.value == serverID && saved.contains($0.key) }) {
            return match.key
        }
        return saved.count == 1 ? saved.first : nil
    }

    /// Whether a push arriving in the foreground is about the session that is
    /// on screen, in which case it is not shown as a banner.
    static func isAboutVisibleSession(_ payload: PushPayload, visibleServer: UUID?, visibleConversation: Int?,
                                      recorded: [UUID: String], saved: [UUID]) -> Bool {
        guard let visibleServer, let visibleConversation,
              let conversationID = payload.conversationID, conversationID == visibleConversation else { return false }
        return serverProfileID(for: payload.serverID, recorded: recorded, saved: saved) == visibleServer
    }
}
