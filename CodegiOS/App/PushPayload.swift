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

    init(kind: String, serverID: String? = nil, conversationID: Int? = nil, folderID: Int? = nil) {
        self.kind = kind
        self.serverID = serverID
        self.conversationID = conversationID
        self.folderID = folderID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = Self.string(userInfo["kind"]) else { return nil }
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
        if let aps = userInfo["aps"] as? [AnyHashable: Any] {
            category = Self.string(aps["category"])
            threadID = Self.string(aps["thread-id"])
        }
    }

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

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}

/// Category and action identifiers the server names (§6).
enum PushCategory {
    static let critical = "CODEG_CRITICAL"
    static let permission = "CODEG_PERMISSION"
    static let session = "CODEG_SESSION"
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
            return .none
        }
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
