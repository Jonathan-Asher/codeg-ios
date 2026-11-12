import Foundation

extension CodegClient {
    /// The text the server's message search kept of a conversation, oldest
    /// turn first (fork.230 `get_conversation_saved_turns`): the messages of
    /// a session whose history the agent deleted, without tool calls or tool
    /// output. A server that predates it doesn't have the route.
    func savedTurns(conversationId: Int) async throws -> [SavedTurn] {
        try await postJSON("get_conversation_saved_turns", ConversationIdBody(conversationId: conversationId),
                           session: Self.readSession)
    }
}
