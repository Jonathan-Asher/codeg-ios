import Foundation
@testable import Codeg

/// Sample sessions for the list screenshots and the ordering tests. Built from
/// the server's JSON shape and decoded with the app's own decoder, so they are
/// exactly what a real `list_all_conversations` response produces.
enum SampleSessions {
    struct Spec {
        var id: Int
        var folder: Int
        var title: String?
        var agent = "claude_code"
        /// Wire `status`: in_progress / pending_review / completed / cancelled.
        var status = "completed"
        var minutesAgo: Double
        /// Wire `turn_state`; nil sends `null`.
        var turnState: String? = nil
        var pinnedMinutesAgo: Double? = nil
        /// Minutes until the usage limit resets, for a paused session.
        var limitResetsIn: Double? = nil
        var messages = 12
    }

    static let folders: [Int: String] = [
        1: "codeg",
        2: "codeg-ios",
        3: "legalix",
        4: "blockrr",
    ]

    static let folderColors: [Int: String] = [
        1: "#6E8BFF",
        2: "#3CC7A0",
        3: "#E59A55",
        4: "#C27BF0",
    ]

    /// Sessions the attention snapshot marks as waiting for the user.
    static let needsYou: [Int: String] = [102: "permission"]

    static let specs: [Spec] = [
        Spec(id: 101, folder: 2, title: "Redesign the session list rows so each one reads as its own card",
             status: "in_progress", minutesAgo: 1, turnState: "running"),
        Spec(id: 102, folder: 1, title: "Fix the push token refresh after a server edit",
             agent: "codex", status: "in_progress", minutesAgo: 4, turnState: "running"),
        Spec(id: 103, folder: 3, title: "Draft the reply to the tax assessment",
             status: "in_progress", minutesAgo: 9, turnState: "interrupted"),
        Spec(id: 104, folder: 4, title: "Board: weekly status digest",
             agent: "gemini", status: "in_progress", minutesAgo: 22, limitResetsIn: 95),
        Spec(id: 105, folder: 2, title: "Camera Control shortcut for dictation",
             status: "pending_review", minutesAgo: 48, pinnedMinutesAgo: 30),
        Spec(id: 106, folder: 1, title: nil, agent: "pi", minutesAgo: 75),
        Spec(id: 107, folder: 3, title: "Summarise the hearing transcript and list the open questions for the client meeting on Thursday",
             agent: "open_code", minutesAgo: 140),
        Spec(id: 108, folder: 1, title: "Upgrade SeaORM and fix the migration test",
             agent: "codex", minutesAgo: 260),
        Spec(id: 109, folder: 2, title: "Voice typing: trim silence before decode",
             minutesAgo: 410, pinnedMinutesAgo: 400),
        Spec(id: 110, folder: 4, title: "Telegram bridge reconnect loop",
             agent: "gemini", status: "cancelled", minutesAgo: 620),
        Spec(id: 111, folder: 1, title: "Explain the event bridge",
             minutesAgo: 900),
        Spec(id: 112, folder: 3, title: "Contract review: clause 7 indemnity",
             minutesAgo: 1_300),
        Spec(id: 113, folder: 2, title: "Old crash in the terminal tab",
             minutesAgo: 3_000),
    ]

    static func all(now: Date = Date()) -> [ConversationSummary] {
        specs.map { decode($0, now: now) }
    }

    static func decode(_ spec: Spec, now: Date = Date()) -> ConversationSummary {
        let updated = now.addingTimeInterval(-spec.minutesAgo * 60)
        var object: [String: Any] = [
            "id": spec.id,
            "folder_id": spec.folder,
            "agent_type": spec.agent,
            "status": spec.status,
            "message_count": spec.messages,
            "created_at": iso(updated.addingTimeInterval(-3_600)),
            "updated_at": iso(updated),
            "turn_state": spec.turnState ?? NSNull(),
        ]
        if let title = spec.title { object["title"] = title }
        if let pinned = spec.pinnedMinutesAgo {
            object["pinned_at"] = iso(now.addingTimeInterval(-pinned * 60))
        }
        if let resetsIn = spec.limitResetsIn {
            object["limit_pause"] = [
                "resets_at": iso(now.addingTimeInterval(resetsIn * 60)),
                "state": "scheduled",
                "attempts": 0,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! CodegJSON.decoder.decode(ConversationSummary.self, from: data)
    }

    /// The Activity tab's split, as `ActivityModel` derives it.
    static func activitySplit(_ all: [ConversationSummary], now: Date = Date())
        -> (running: [ConversationSummary], recent: [ConversationSummary]) {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let running = all.filter { $0.status.isLive }.sorted { $0.updatedAt > $1.updatedAt }
        let recent = all.filter { !$0.status.isLive && $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
        return (running, recent)
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
