import Foundation

/// Marking a session critical, as the desktop does (codeg's critical
/// sessions: `acp/critical_watch.rs`, `src/lib/critical-sessions.ts`). The
/// backend then alerts when the session sits idle (its turn ended, it waits
/// on you, it was interrupted), and, with stall detection on, when a working
/// turn goes silent; it repeats until you act. The phone already receives
/// those alerts as critical pushes.
enum CriticalSessionRules {
    /// What a session's menu offers.
    enum Action: Equatable, Sendable {
        case mark
        case unmark

        /// The desktop's words (`markCritical`, `unmarkCritical`).
        var title: String {
            switch self {
            case .mark: return String(localized: "Mark as Critical")
            case .unmark: return String(localized: "Unmark Critical")
            }
        }

        var symbol: String {
            switch self {
            case .mark: return "flag"
            case .unmark: return "flag.slash"
            }
        }

        /// The mark after the action.
        var marks: Bool { self == .mark }
    }

    /// Mark or unmark, or nil when not offered: a server without critical
    /// sessions (its summaries carry no `critical`), or a delegation
    /// sub-session, which its parent drives (one marked anyway can still be
    /// unmarked, as on the desktop).
    static func action(for summary: ConversationSummary) -> Action? {
        guard summary.criticalReported else { return nil }
        if summary.critical { return .unmark }
        return summary.parentId == nil ? .mark : nil
    }

    /// The failure, in the desktop's words (`criticalToggleFailed`).
    static func failure(_ detail: String) -> String {
        String(localized: "Could not update the critical mark: \(detail)")
    }
}

/// Body for `update_conversation_critical`. `stall` is left out to keep the
/// session's stall detection as it is.
struct UpdateConversationCriticalBody: Encodable, Sendable {
    let conversationId: Int
    let critical: Bool
    var stall: Bool? = nil
}

extension CodegClient {
    /// Mark or unmark a conversation critical (`update_conversation_critical`),
    /// and with `stall`, turn its stall detection on or off. Every client gets
    /// the row back through its next list read.
    func setCritical(conversationId: Int, critical: Bool, stall: Bool? = nil) async throws {
        _ = try await send("update_conversation_critical",
                           body: UpdateConversationCriticalBody(conversationId: conversationId,
                                                                critical: critical, stall: stall))
    }
}
