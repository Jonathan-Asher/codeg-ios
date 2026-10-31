import Foundation

// MARK: - Prefix fingerprint

/// The codeg server's structural fingerprint of a run of turns
/// (`commands::turn_window::prefix_fingerprint`): FNV-1a 64 over each turn's
/// role tag byte and its timestamp's epoch milliseconds as 8 little-endian
/// bytes, chained turn after turn. It ignores ids and content, so it proves
/// that no turn was inserted, removed or moved, not that none was edited.
/// The web client mirrors the same function.
enum TranscriptFingerprint {
    /// The fingerprint of no turns (the FNV-1a offset basis).
    static let empty = "cbf29ce484222325"

    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// `seed` extended over `turns`, or `nil` when the seed isn't 16 hex
    /// digits or a turn has no server timestamp (a turn made on the phone).
    static func extend<S: Sequence>(_ seed: String, over turns: S) -> String? where S.Element == MessageTurn {
        guard seed.utf8.count == 16, var hash = UInt64(seed, radix: 16) else { return nil }
        for turn in turns {
            guard let millis = turn.serverMillis else { return nil }
            hash = (hash ^ UInt64(tag(turn.role))) &* prime
            var value = UInt64(bitPattern: millis)
            for _ in 0..<8 {
                hash = (hash ^ (value & 0xff)) &* prime
                value >>= 8
            }
        }
        return hex(hash)
    }

    static func tag(_ role: TurnRole) -> UInt8 {
        switch role {
        case .user: return 0
        case .assistant: return 1
        case .system: return 2
        }
    }

    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

// MARK: - Window sync

/// What a session screen (or the on-device cache) holds of one transcript:
/// `turns` are the whole transcript's `[offset ..< offset + turns.count]`.
struct TranscriptWindow: Equatable, Sendable {
    var offset: Int = 0
    /// Fingerprint of the turns before `offset`. `nil` with `offset == 0`
    /// means the whole transcript, as an older server sends it.
    var prefixHash: String?
    /// The whole transcript's length at the last fetch, when the server said.
    var total: Int?
    var turns: [MessageTurn] = []

    /// One past the global index of the last turn held.
    var end: Int { offset + turns.count }
    /// Turns before the window that the server can still send.
    var hasOlder: Bool { offset > 0 }

    /// The leading turns that came from the server. A reply the phone kept
    /// without the server's copy sits at the end, never in the middle.
    var serverTurns: ArraySlice<MessageTurn> {
        let count = turns.firstIndex(where: { $0.serverMillis == nil }) ?? turns.count
        return turns[..<count]
    }

    /// The fingerprint of the turns before global index `index`, extending
    /// the window's own over the turns it holds before `index`.
    func fingerprint(before index: Int) -> String? {
        guard index >= offset, index <= offset + serverTurns.count else { return nil }
        let seed = prefixHash ?? (offset == 0 ? TranscriptFingerprint.empty : nil)
        guard let seed else { return nil }
        return TranscriptFingerprint.extend(seed, over: turns[..<(index - offset)])
    }
}

/// Fetches only what changed in a transcript, using the server's turn-window
/// protocol (`tailTurns`, `fromIndex`, `prefix_hash`), the way the codeg web
/// client does. A server without the protocol answers every request with the
/// whole transcript, which is used as it is.
enum TranscriptSync {
    /// Servers (`TranscriptCache.serverKey`) seen answering with windows, so
    /// background prefetching never pulls a whole transcript from an older one.
    @MainActor private(set) static var windowedServers: Set<String> = []

    @MainActor static func noteWindowed(serverKey: String) {
        windowedServers.insert(serverKey)
    }

    /// Turns asked for when nothing is held yet (the web client's default).
    static let tailTurns = 120
    /// Held turns fetched again when a session is opened from the cache or the
    /// app comes back to it: the last round or two, which the server may have
    /// rewritten in place (a background task's acknowledgement, a
    /// delegation's status). On an image-heavy session 40 turns were 130 KB
    /// compressed, against 1 MB for 120.
    static let reopenOverlap = 40
    /// Held turns fetched again on a refresh during a session: the reply that
    /// was just streaming and the turn or two persisted while it ran.
    static let liveOverlap = 8

    /// The request for a refresh of `held`.
    enum Request: Equatable {
        /// A fresh window of the last `tailTurns` turns.
        case tail(Int)
        /// Everything from `fromIndex` on, which must follow a prefix whose
        /// fingerprint is `expected`.
        case from(index: Int, expected: String)
    }

    /// What to ask for, re-fetching the last `overlap` server turns held.
    static func request(for held: TranscriptWindow?, overlap: Int) -> Request {
        guard let held, !held.serverTurns.isEmpty || held.offset > 0 else { return .tail(tailTurns) }
        let serverEnd = held.offset + held.serverTurns.count
        let start = max(held.offset, serverEnd - max(0, overlap))
        if let expected = held.fingerprint(before: start) {
            return .from(index: start, expected: expected)
        }
        // A held turn without its exact time: refresh the whole window, which
        // only needs the fingerprint the server gave for its start.
        if let hash = held.prefixHash ?? (held.offset == 0 ? TranscriptFingerprint.empty : nil) {
            return .from(index: held.offset, expected: hash)
        }
        return .tail(tailTurns)
    }

    /// The result of a refresh.
    struct Outcome: Sendable {
        /// The whole response, with `turns` replaced by the merged window.
        var detail: ConversationDetail
        var window: TranscriptWindow
        /// `true` when `window` continues the held one (same start, same
        /// history before it); `false` for a fresh window or a whole
        /// transcript, which replace what was held.
        var continuesHeld: Bool
    }

    /// Joins `response` (the answer to `request`) to `held`. `nil` when it
    /// doesn't join: the history before the requested index was rewritten
    /// (a compaction), so the caller starts over from a fresh tail.
    static func merge(held: TranscriptWindow?, request: Request, response: ConversationDetail) -> Outcome? {
        guard response.isWindowed, let offset = response.turnsOffset, let total = response.turnsTotal else {
            // An older server: the whole transcript.
            let window = TranscriptWindow(offset: 0, prefixHash: nil, total: response.turns.count, turns: response.turns)
            return Outcome(detail: response, window: window, continuesHeld: false)
        }
        switch request {
        case .tail:
            let window = TranscriptWindow(offset: offset, prefixHash: response.prefixHash, total: total, turns: response.turns)
            return Outcome(detail: response, window: window, continuesHeld: false)
        case .from(let index, let expected):
            guard let held, offset == index, response.prefixHash == expected, total >= index,
                  index >= held.offset, index <= held.offset + held.serverTurns.count
            else { return nil }
            var merged = held
            merged.turns = Array(held.turns[..<(index - held.offset)]) + response.turns
            merged.total = total
            var detail = response
            detail.turns = merged.turns
            return Outcome(detail: detail, window: merged, continuesHeld: true)
        }
    }

    /// Refresh `held` against the server: the delta when it joins, else a
    /// fresh tail window.
    static func fetch(client: CodegClient, id: Int, held: TranscriptWindow?, overlap: Int) async throws -> Outcome {
        let request = request(for: held, overlap: overlap)
        let response = try await client.conversationDetail(id: id, window: request)
        if let outcome = merge(held: held, request: request, response: response) { return outcome }
        let fresh = try await client.conversationDetail(id: id, window: .tail(tailTurns))
        // A tail request never fails to "join".
        return merge(held: nil, request: .tail(tailTurns), response: fresh)!
    }

    /// The page before `held` joined in front of it, or `nil` when it doesn't
    /// join (the history before the window was rewritten).
    static func prepend(page: ConversationTurnsPage, to held: TranscriptWindow) -> TranscriptWindow? {
        guard let hash = held.prefixHash, page.prefixHashBeforeIndex == hash,
              page.turnsOffset + page.turns.count == held.offset
        else { return nil }
        var window = held
        window.turns = page.turns + held.turns
        window.offset = page.turnsOffset
        window.prefixHash = page.prefixHash
        window.total = page.turnsTotal
        return window
    }
}
