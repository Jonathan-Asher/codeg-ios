import Foundation

/// Side questions: `/btw <question>` in the message bar, as on codeg's
/// desktop (`lib/side-question.ts`, the server's `acp::side_question`).
///
/// The session answers from its current context with no tools, while a turn
/// runs or between turns. Neither the question nor the answer goes into the
/// transcript, the queue or the running turn. The server keeps the exchanges
/// per conversation and sends the newest ones along with the next question,
/// so a follow-up builds on them. `/btw` alone reopens the answers.
///
/// Only a session whose agent adapter advertises it can answer
/// (`agentCapabilities._meta.codeg.sideQuestion`, which the server reports as
/// the snapshot's `side_question_supported` and the `codeg_extensions`
/// event): codeg's own Claude Code adapter, and its Pi adapter from the
/// release after fork.243.
struct SideQuestionCommand: Equatable, Sendable {
    /// What was asked; empty for a bare `/btw`, which reopens the answers.
    let question: String

    /// What the message bar's text asks for: a side question, or nil for
    /// anything else. Only a leading `/btw`, in any case, alone or followed
    /// by whitespace, counts: `/btwx` and a `/btw` in the middle of a
    /// message are ordinary text.
    static func parse(_ text: String) -> SideQuestionCommand? {
        let start = text.drop(while: \.isWhitespace)
        // `prefix` rather than `count`: a long pasted draft isn't walked
        // on every keystroke.
        let head = start.prefix(4)
        guard head.count == 4, head.lowercased() == "/btw" else { return nil }
        let rest = start.dropFirst(4)
        if let next = rest.first, !next.isWhitespace { return nil }
        return SideQuestionCommand(question: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One `/btw` exchange as the server keeps it (Rust
/// `side_question::SideQuestionRecord`, `rename_all = "camelCase"`): what
/// `acp_side_question` answers and `acp_list_side_questions` lists. `id` and
/// `conversationId` are null for a question asked of a connection no
/// conversation was bound to: answered, and kept nowhere.
struct SideQuestionRecord: Decodable, Hashable, Sendable {
    let id: Int?
    let conversationId: Int?
    let question: String
    /// Null when the agent answered with nothing at all.
    let answer: String?
    /// The answer is a notice from the agent ("(API error: …)", the model
    /// tried to call a tool), not the model's own words.
    let synthetic: Bool
    /// The agent's note that a fallback model answered after a refusal.
    let fallbackNotice: String?
    let createdAt: Date?

    init(id: Int?, conversationId: Int?, question: String, answer: String?, synthetic: Bool = false,
         fallbackNotice: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.question = question
        self.answer = answer
        self.synthetic = synthetic
        self.fallbackNotice = fallbackNotice
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, question, answer, synthetic, fallbackNotice, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? nil
        conversationId = (try? c.decodeIfPresent(Int.self, forKey: .conversationId)) ?? nil
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? ""
        answer = (try? c.decodeIfPresent(String.self, forKey: .answer)) ?? nil
        synthetic = (try? c.decodeIfPresent(Bool.self, forKey: .synthetic)) ?? false
        fallbackNotice = (try? c.decodeIfPresent(String.self, forKey: .fallbackNotice)) ?? nil
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
    }
}

/// Body of `acp_side_question` (Rust `AcpSideQuestionParams`). The server
/// runs it on `connectionId` when that is live and serves the conversation,
/// else on the conversation's live connection, else it reopens the
/// conversation's session to answer.
struct SideQuestionAskBody: Encodable, Sendable {
    let connectionId: String?
    let conversationId: Int?
    let question: String
}

/// Body of `acp_list_side_questions` (Rust `ConversationSideQuestionsParams`).
struct SideQuestionListBody: Encodable, Sendable {
    let conversationId: Int
}

/// Whether `/btw` goes to the server or stays in the message bar with a notice.
enum SideQuestionSupport: Equatable, Sendable {
    case supported
    case unsupported

    /// What the session's live connection said (`live`), else what a session
    /// of the same agent on this server said before (`remembered`), else a
    /// try for the agents whose codeg adapters answer side questions: the
    /// server says when it can't, and the question comes back to the message
    /// bar. Every other agent gets the notice without a request.
    static func resolve(live: Bool?, remembered: Bool?, agent: AgentType) -> SideQuestionSupport {
        if let live { return live ? .supported : .unsupported }
        if let remembered { return remembered ? .supported : .unsupported }
        switch agent {
        case .claudeCode, .pi: return .supported
        default: return .unsupported
        }
    }
}
