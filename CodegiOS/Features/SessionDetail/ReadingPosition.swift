import Foundation

// MARK: - Reading position

/// Where the reader was in a session's transcript when they left it: the row
/// at the top of the screen and how far into it, or the latest message.
///
/// Saved per server and conversation (``ReadingPositionStore``) when the
/// session screen goes (Back, another tab, the app to the background) and
/// whenever scrolling settles, so it survives leaving the session, the model
/// being let go and the app being relaunched.
struct ReadingPosition: Codable, Equatable, Sendable {
    /// The transcript row at the top of the screen (a `TimelineNode` id).
    var anchorID: String
    /// The persisted turn that row belongs to. Lets the window open wide
    /// enough again, and finds the reply when its rows were renumbered. Nil
    /// for a row of the live reply.
    var anchorTurnID: String?
    /// That turn's exact server time. Turn ids are positions in the
    /// transcript (`turn-41`), so after the history was rewritten (a
    /// compaction, a fork in place) the same id can be another message: the
    /// time tells them apart.
    var anchorTurnMillis: Int64?
    /// The top of the screen, in points below the row's top: 0 when the row
    /// starts right at the top, positive when it was scrolled partly out of
    /// view, negative when it starts lower.
    var offset: Double
    /// The reader was at the latest message.
    var atBottom: Bool
    /// The first turn the transcript showed (global index), so the window
    /// opens over the same history again.
    var windowStart: Int?
    /// How far the persisted transcript went (global end) when the reader
    /// last saw its end. Turns after it arrived while they were away.
    var seenTurnEnd: Int
    var savedAt: Date

    /// At the latest message.
    static func bottom(seenTurnEnd: Int, windowStart: Int? = nil, at date: Date = Date()) -> ReadingPosition {
        ReadingPosition(anchorID: "", anchorTurnID: nil, anchorTurnMillis: nil, offset: 0, atBottom: true,
                        windowStart: windowStart, seenTurnEnd: seenTurnEnd, savedAt: date)
    }
}

// MARK: - The restore rule

/// How a session opens: at its latest message, or where the reader left it.
///
/// The rule:
/// - **At the latest message** when the reader was there when they left (it
///   keeps following new replies, as before), when nothing was saved, and
///   when the session is opened from a notification or a link: those are
///   about something new, so they show it.
/// - **Where they left it** otherwise: from a list, Back, another tab, the
///   app coming back. A reply that arrived meanwhile doesn't move the view;
///   "New messages" says it is there.
/// - A saved row that is no longer in the transcript (the history was
///   rewritten, the session forked in place) falls back to the first row of
///   the same turn, then to the latest message.
enum ReadingRestore: Equatable, Sendable {
    case bottom
    case anchored(ReadingPosition)

    static func decide(saved: ReadingPosition?, openAtLatest: Bool) -> ReadingRestore {
        guard !openAtLatest, let saved, !saved.atBottom, !saved.anchorID.isEmpty else { return .bottom }
        return .anchored(saved)
    }

    /// The saved row's turn is still the same message: held with the same
    /// server time, or not held at all (it may come with the window), or
    /// saved without a time.
    static func isStillThere(_ position: ReadingPosition, in turns: [MessageTurn]) -> Bool {
        guard let id = position.anchorTurnID, let millis = position.anchorTurnMillis,
              let turn = turns.first(where: { $0.id == id }) else { return true }
        return turn.serverMillis == millis
    }

    /// The row and offset to scroll to among the rows on screen: the saved
    /// row, or the first row of its turn (from its top), or nil (open at the
    /// latest message).
    static func resolve(_ position: ReadingPosition, rows: [(id: String, turnID: String?)])
        -> (id: String, offset: Double)? {
        if rows.contains(where: { $0.id == position.anchorID }) {
            return (position.anchorID, position.offset)
        }
        if let turn = position.anchorTurnID, let row = rows.first(where: { $0.turnID == turn }) {
            return (row.id, 0)
        }
        return nil
    }

    /// The window start (global turn index) that shows `turnID`: the saved
    /// start, moved up to the turn when the turn is earlier. Nil when the
    /// turn isn't held, so the view can't show it.
    static func windowStart(for position: ReadingPosition, turnIDs: [String], turnsOffset: Int) -> Int? {
        guard let turn = position.anchorTurnID, let local = turnIDs.firstIndex(of: turn) else { return nil }
        let global = turnsOffset + local
        return min(position.windowStart ?? global, global)
    }
}

// MARK: - Store

/// The saved reading positions, keyed by server (its endpoint and token, as
/// the transcript cache keys it) and conversation, in UserDefaults. Holds at
/// most `capacity` sessions, dropping the least recently saved.
@MainActor
final class ReadingPositionStore {
    static let shared = ReadingPositionStore()
    static let storageKey = "codeg.readingPositions.v1"
    static let capacity = 400

    private let defaults: UserDefaults
    private var entries: [String: ReadingPosition]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: ReadingPosition].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    static func key(serverKey: String, conversationID: Int) -> String {
        "\(serverKey)#\(conversationID)"
    }

    func position(serverKey: String, conversationID: Int) -> ReadingPosition? {
        entries[Self.key(serverKey: serverKey, conversationID: conversationID)]
    }

    func save(_ position: ReadingPosition, serverKey: String, conversationID: Int) {
        let key = Self.key(serverKey: serverKey, conversationID: conversationID)
        guard entries[key] != position else { return }
        entries[key] = position
        if entries.count > Self.capacity {
            let oldest = entries.sorted { $0.value.savedAt < $1.value.savedAt }
                .prefix(entries.count - Self.capacity)
            for (key, _) in oldest { entries.removeValue(forKey: key) }
        }
        persist()
    }

    func remove(serverKey: String, conversationID: Int) {
        guard entries.removeValue(forKey: Self.key(serverKey: serverKey, conversationID: conversationID)) != nil
        else { return }
        persist()
    }

    /// Forget the servers that are gone or whose address or token changed.
    func removeServers(except keep: Set<String>) {
        let before = entries.count
        entries = entries.filter { key, _ in
            guard let hash = key.firstIndex(of: "#") else { return false }
            return keep.contains(String(key[..<hash]))
        }
        if entries.count != before { persist() }
    }

    var count: Int { entries.count }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
