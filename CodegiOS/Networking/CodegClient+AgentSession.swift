import Foundation

extension CodegClient {
    /// An agent's own session, by its session id rather than a codeg
    /// conversation (`get_conversation`): a Pi sub-agent run's child, which
    /// lives in its parent's folder and is listed nowhere else. Read-only.
    func agentSessionTurns(agentType: AgentType, sessionID: String) async throws -> [MessageTurn] {
        let detail: AgentSessionDetail = try await postJSON(
            "get_conversation", AgentSessionBody(agentType: agentType.wireValue, conversationId: sessionID))
        return detail.turns
    }
}

/// Body for `get_conversation`: the agent and its own session id.
struct AgentSessionBody: Encodable, Sendable {
    let agentType: String
    let conversationId: String
}

/// The part of `get_conversation`'s answer the phone shows: the turns, any
/// that doesn't decode skipped.
struct AgentSessionDetail: Decodable, Sendable {
    let turns: [MessageTurn]

    private enum CodingKeys: String, CodingKey { case turns }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard var list = try? c.nestedUnkeyedContainer(forKey: .turns) else {
            turns = []
            return
        }
        var out: [MessageTurn] = []
        while !list.isAtEnd {
            if let turn = try? list.decode(MessageTurn.self) {
                out.append(turn)
            } else if (try? list.decode(SkippedTurn.self)) == nil {
                break
            }
        }
        turns = out
    }

    private struct SkippedTurn: Decodable {
        init(from decoder: Decoder) {}
    }
}
