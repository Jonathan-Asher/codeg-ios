import Foundation

// MARK: - Exact server timestamps

/// RFC 3339 timestamps read the way the codeg server counts them. The shared
/// date decoder drops 6- and 9-digit fractions altogether, so the transcript
/// keeps each turn's exact milliseconds alongside its `Date`.
enum TranscriptTime {
    /// Epoch milliseconds of `text`, as chrono's `timestamp_millis()` gives
    /// them: the fraction cut (not rounded) to milliseconds. `nil` for
    /// anything that isn't `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`.
    static func millis(_ text: String) -> Int64? {
        var utf8 = text.utf8.makeIterator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(40)
        while let b = utf8.next() {
            bytes.append(b)
            if bytes.count > 64 { return nil }
        }
        guard bytes.count >= 20 else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for i in start..<(start + count) {
                let b = bytes[i]
                guard b >= 48, b <= 57 else { return nil }
                value = value * 10 + Int(b - 48)
            }
            return value
        }

        guard let year = digits(0, 4), bytes[4] == 45,
              let month = digits(5, 2), bytes[7] == 45,
              let day = digits(8, 2),
              bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32,
              let hour = digits(11, 2), bytes[13] == 58,
              let minute = digits(14, 2), bytes[16] == 58,
              let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }

        var i = 19
        var fraction = 0
        if i < bytes.count, bytes[i] == 46 {
            i += 1
            var count = 0
            while i < bytes.count, bytes[i] >= 48, bytes[i] <= 57 {
                if count < 3 { fraction = fraction * 10 + Int(bytes[i] - 48) }
                count += 1
                i += 1
            }
            guard count > 0 else { return nil }
            if count < 3 {
                for _ in count..<3 { fraction *= 10 }
            }
        }

        guard i < bytes.count else { return nil }
        var offsetSeconds = 0
        switch bytes[i] {
        case 90, 122:
            i += 1
        case 43, 45:
            guard let oh = digits(i + 1, 2), i + 3 < bytes.count, bytes[i + 3] == 58,
                  let om = digits(i + 4, 2) else { return nil }
            offsetSeconds = (oh * 3600 + om * 60) * (bytes[i] == 45 ? -1 : 1)
            i += 6
        default:
            return nil
        }
        guard i == bytes.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return seconds * 1000 + Int64(fraction)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar
    /// (Howard Hinnant's `days_from_civil`).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// `millis` as RFC 3339 in UTC with three fraction digits, which
    /// `millis(_:)` reads back to the same value.
    static func string(millis: Int64) -> String {
        var seconds = millis / 1000
        var ms = millis % 1000
        if ms < 0 { ms += 1000; seconds -= 1 }
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 { rest += 86_400; days -= 1 }
        let (y, m, d) = civil(fromDays: Int(days))
        let h = Int(rest / 3600), mi = Int(rest % 3600 / 60), s = Int(rest % 60)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, m, d, h, mi, s, Int(ms))
    }

    /// `date` to the nearest millisecond (a date read from milliseconds
    /// comes back the same despite floating-point error).
    static func string(date: Date) -> String {
        string(millis: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    /// Inverse of `daysFromCivil`.
    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

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
