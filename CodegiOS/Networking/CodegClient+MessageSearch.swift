import Foundation

extension CodegClient {
    /// Messages of every session that hold all of `query`'s words
    /// (`message_search`, the full-text index codeg's ⌘K searches), best
    /// first. A codeg without it answers 501 `not_implemented`
    /// (``MessageSearch/isUnsupported(_:)``).
    func searchMessages(_ query: String, limit: Int = MessageSearch.limit) async throws -> [MessageSearchHit] {
        try await postJSON("message_search", MessageSearchBody(query: query, limit: limit), session: Self.readSession)
    }
}

/// Body for `message_search` (`MessageSearchParams`).
struct MessageSearchBody: Encodable, Sendable {
    let query: String
    let limit: Int
}
