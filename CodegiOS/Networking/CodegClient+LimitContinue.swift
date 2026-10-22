import Foundation

/// A session paused on a usage limit (codeg's `acp::limit_continue`): the two
/// things the user can do about the pause before it continues by itself.
/// Both answer whether the conversation was still paused, and the server
/// broadcasts the row's new state to every client.
extension CodegClient {
    /// "Cancel auto-continue": the pause ends now and the turn is left
    /// interrupted, with the manual Continue. False when nothing was paused
    /// (it continued or settled meanwhile).
    func cancelLimitContinue(conversationId: Int) async throws -> Bool {
        try await postJSON("cancel_limit_continue", ConversationIdBody(conversationId: conversationId))
    }

    /// "Continue now": send the continuation right away, ahead of the reset.
    /// It may meet the limit again, which pauses it again. False when the
    /// conversation is not paused.
    func continueLimitNow(conversationId: Int) async throws -> Bool {
        try await postJSON("continue_limit_now", ConversationIdBody(conversationId: conversationId))
    }
}
