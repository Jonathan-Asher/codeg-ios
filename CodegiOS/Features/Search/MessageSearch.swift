import Foundation

// MARK: - A hit

/// One message whose text matched, as codeg's `message_search` returns it
/// (`MessageSearchHit` in `db/service/message_search_service.rs`), best first.
/// The index holds the text of every top-level session's messages (not
/// reasoning or tool output), refreshed about once a minute.
struct MessageSearchHit: Decodable, Hashable, Sendable {
    let conversationId: Int
    let folderId: Int
    let agentType: AgentType
    let title: String?
    /// The turn's position in the whole transcript: the global index the
    /// turn-window protocol counts in (`turnsOffset + i`).
    let turnIdx: Int
    let role: MessageSearchRole
    /// An excerpt around the match, every matched word wrapped in
    /// `[[mark]]…[[/mark]]` (see ``MessageSnippet``).
    let snippet: String
    /// BM25, lower is better; 0 when no word was long enough for the index
    /// (those come most recently active first).
    let rank: Double

    /// The title to show, nil when there is none.
    var trimmedTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Whose message a hit is.
enum MessageSearchRole: String, Decodable, Hashable, Sendable {
    case user
    case assistant
    case system

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageSearchRole(rawValue: raw.lowercased()) ?? .system
    }
}

// MARK: - The excerpt

/// A hit's excerpt as plain text and the stretches the search matched.
///
/// The server marks matches as `[[mark]]…[[/mark]]` (deliberately not HTML,
/// so each client draws the highlight its own way). Whitespace runs, line
/// breaks included, fold into one space, so an excerpt reads as one short
/// paragraph; a mark left open runs to the end, and a stray closing mark is
/// dropped. Adjacent marks join.
struct MessageSnippet: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var text: String
        var marked: Bool
    }

    static let open = "[[mark]]"
    static let close = "[[/mark]]"

    let segments: [Segment]

    init(_ raw: String) {
        // Split on the tags.
        var pieces: [Segment] = []
        var marked = false
        var rest = Substring(raw)
        while !rest.isEmpty {
            let tag = marked ? Self.close : Self.open
            let other = marked ? Self.open : Self.close
            let next = rest.range(of: tag)
            let stray = rest.range(of: other)
            // A tag that doesn't fit (a second open inside a mark, a close
            // outside one) is dropped, keeping the text around it.
            if let stray, next.map({ stray.lowerBound < $0.lowerBound }) ?? true {
                pieces.append(Segment(text: String(rest[..<stray.lowerBound]), marked: marked))
                rest = rest[stray.upperBound...]
                continue
            }
            guard let next else {
                pieces.append(Segment(text: String(rest), marked: marked))
                break
            }
            pieces.append(Segment(text: String(rest[..<next.lowerBound]), marked: marked))
            rest = rest[next.upperBound...]
            marked.toggle()
        }

        // Fold whitespace across the pieces, trim the ends, join neighbours.
        var folded: [Segment] = []
        var lastWasSpace = true
        for piece in pieces {
            var text = ""
            for character in piece.text {
                if character.isWhitespace {
                    if !lastWasSpace { text.append(" ") }
                    lastWasSpace = true
                } else {
                    text.append(character)
                    lastWasSpace = false
                }
            }
            guard !text.isEmpty else { continue }
            if let last = folded.last, last.marked == piece.marked {
                folded[folded.count - 1].text += text
            } else {
                folded.append(Segment(text: text, marked: piece.marked))
            }
        }
        while let last = folded.last, last.text.hasSuffix(" ") {
            folded[folded.count - 1].text.removeLast()
            if folded[folded.count - 1].text.isEmpty { folded.removeLast() }
        }
        segments = folded
    }

    /// The excerpt without its marks.
    var text: String { segments.map(\.text).joined() }

    /// Where the matches are in ``text``. Counted in Unicode scalars, which
    /// add up across the joins (a mark may split a letter from its vowel
    /// sign, which then form one character).
    var marks: [Range<String.Index>] {
        let text = self.text
        var ranges: [Range<String.Index>] = []
        var at = text.startIndex
        for segment in segments {
            let end = text.unicodeScalars.index(at, offsetBy: segment.text.unicodeScalars.count)
            if segment.marked { ranges.append(at..<end) }
            at = end
        }
        return ranges
    }

    /// The matched stretches of text.
    var markedTexts: [String] { segments.filter(\.marked).map(\.text) }
}

// MARK: - Grouping, the rules, running a search

/// One session's hits: shown as one card with its best hit, the rest a tap away.
struct MessageSearchGroup: Identifiable, Equatable, Sendable {
    let conversationID: Int
    let folderID: Int
    let agentType: AgentType
    let title: String?
    /// Best first, as the server ranked them.
    let hits: [MessageSearchHit]

    var id: Int { conversationID }
    var best: MessageSearchHit { hits[0] }
    /// Hits beyond the best one.
    var more: ArraySlice<MessageSearchHit> { hits.dropFirst() }
}

/// A search request from outside the Search screen: the Chats filter's
/// "Search messages for …". `id` tells two requests for the same words apart.
struct SearchRequest: Equatable, Sendable {
    let id: Int
    let query: String
}

enum MessageSearch {
    /// Most hits one search shows (codeg's ⌘K asks for 40 too).
    static let limit = 40
    /// The index matches words of three or more characters (a trigram
    /// index); shorter ones would scan every message.
    static let minWordLength = 3

    /// What a message search came to.
    enum Outcome: Equatable, Sendable {
        /// No word long enough: titles only, with a quiet hint.
        case tooShort
        /// The server has no message search (an older codeg): titles only,
        /// said nowhere.
        case unsupported
        case failed(String)
        case found([MessageSearchGroup])
    }

    /// Whether `query` is searched in messages: it has a word of at least
    /// ``minWordLength`` characters. Shorter queries search titles only.
    static func canSearchMessages(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).contains { $0.count >= minWordLength }
    }

    /// The words of a query, for picking the row to open at.
    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Hits grouped by session, in the order of each session's best hit
    /// (the server sends the best first); a session's hits keep that order.
    static func group(_ hits: [MessageSearchHit]) -> [MessageSearchGroup] {
        var order: [Int] = []
        var bySession: [Int: [MessageSearchHit]] = [:]
        for hit in hits {
            if bySession[hit.conversationId] == nil { order.append(hit.conversationId) }
            bySession[hit.conversationId, default: []].append(hit)
        }
        return order.compactMap { id in
            guard let hits = bySession[id], let first = hits.first else { return nil }
            return MessageSearchGroup(conversationID: id, folderID: first.folderId, agentType: first.agentType,
                                      title: first.trimmedTitle, hits: hits)
        }
    }

    /// The server doesn't have `message_search`: codeg answers an unknown
    /// command with 501 `not_implemented`, and a proxy in front of an older
    /// one may say 404 or 405.
    static func isUnsupported(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        if error.isEndpointMissing { return true }
        if case .server(let status, _, _) = error { return status == 404 || status == 405 }
        return false
    }

    /// Search messages for `query` with `search` (the client's
    /// `searchMessages`), unless the query is too short. Never throws: a
    /// failure is an outcome, so the title results still show.
    static func run(_ query: String,
                    search: (String) async throws -> [MessageSearchHit]) async -> Outcome {
        guard canSearchMessages(query) else { return .tooShort }
        do {
            return .found(group(try await search(query)))
        } catch {
            if isUnsupported(error) { return .unsupported }
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Where a hit opens: its turn, with the query's words to find the row
    /// that holds them and light it.
    static func jumpRequest(for hit: MessageSearchHit, query: String) -> TranscriptJumpRequest {
        TranscriptJumpRequest(turnIndex: hit.turnIdx, terms: words(query))
    }
}
