import Foundation

// What waits on the user (codeg fork `docs/ios-push.md` §9) and when a
// conversation was last opened (`mark_conversations_viewed`).

private struct UpdatePendingReminderSettingsBody: Encodable, Sendable {
    let settings: PendingReminderSettings
}

/// One opened conversation, reported by its age so the phone's clock does
/// not matter (Rust `ConversationViewReport`).
struct ConversationViewReport: Encodable, Hashable, Sendable {
    let conversationId: Int
    let ageMs: Int
}

private struct MarkConversationsViewedBody: Encodable, Sendable {
    let views: [ConversationViewReport]
}

extension CodegClient {
    /// Everything waiting on the user, oldest first, and the count.
    func listPendingItems() async throws -> PendingSnapshot {
        try await postJSON("list_pending_items", EmptyBody(), session: Self.readSession)
    }

    func getPendingReminderSettings() async throws -> PendingReminderSettings {
        try await postJSON("get_pending_reminder_settings", EmptyBody(), session: Self.readSession)
    }

    /// Store the reminder settings; the server answers with what it kept
    /// (clamped, sorted).
    func updatePendingReminderSettings(_ settings: PendingReminderSettings) async throws -> PendingReminderSettings {
        try await postJSON("update_pending_reminder_settings", UpdatePendingReminderSettingsBody(settings: settings))
    }

    /// Answer a waiting single-choice question with one of its labels.
    func answerPendingQuestion(_ item: PendingItem, label: String) async throws {
        guard let answer = item.answer(label: label) else { throw APIError.decoding("not a question") }
        try await answerQuestion(connectionId: item.connectionId, questionId: item.requestId, answer: answer)
    }

    /// Record that the user opened these conversations (the lists order by
    /// the later of this and the last activity).
    func markConversationsViewed(_ views: [ConversationViewReport]) async throws {
        _ = try await send("mark_conversations_viewed", body: MarkConversationsViewedBody(views: views))
    }
}
