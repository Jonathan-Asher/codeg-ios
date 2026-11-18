import Foundation

extension CodegClient {
    /// For `acp_side_question`. The server waits up to three minutes for the
    /// answer (`CODEG_SIDE_QUESTION_TIMEOUT_SECS`) and then cancels it, and
    /// for a conversation nothing has open it first reopens the session
    /// (its attach waits up to 90 s). Nothing comes back until the answer, so
    /// the idle timeout is the whole wait: codeg's desktop allows 8½ minutes,
    /// so the server always answers first, with its own message.
    static let sideQuestionSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 510
        cfg.timeoutIntervalForResource = 540
        return URLSession(configuration: cfg)
    }()

    /// Ask a side question (`/btw`): answered from the session's context with
    /// no tools, while a turn runs or between turns, and kept out of the
    /// transcript and the queue. Resolves with the exchange as the server
    /// stored it. Cancelling the task stops the wait; the server may still
    /// finish and keep the answer in the conversation's side questions.
    func askSideQuestion(connectionId: String?, conversationId: Int?, question: String) async throws
        -> SideQuestionRecord {
        try await postJSON("acp_side_question",
                           SideQuestionAskBody(connectionId: connectionId, conversationId: conversationId,
                                               question: question),
                           session: Self.sideQuestionSession)
    }

    /// The conversation's side questions, oldest first (the newest 200).
    func sideQuestions(conversationId: Int) async throws -> [SideQuestionRecord] {
        try await postJSON("acp_list_side_questions", SideQuestionListBody(conversationId: conversationId),
                           session: Self.readSession)
    }
}

extension APIError {
    /// The server can't answer side questions for this session: its agent's
    /// adapter doesn't offer them (`AcpError::SideQuestionUnsupported`, a 400
    /// `invalid_input` "this agent cannot answer side questions"), or the
    /// server predates them (no `acp_side_question`, 501 `not_implemented`).
    var isSideQuestionUnsupported: Bool {
        if isEndpointMissing { return true }
        guard case .server(let status, let code, let message) = self else { return false }
        return code == "side_question_unsupported"
            || (status == 400 && message.lowercased().contains("cannot answer side questions"))
    }
}
