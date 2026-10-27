import CoreGraphics
import Foundation

// MARK: - Opening a session at a message

/// Open a session at one of its messages: a message search hit's turn, and
/// the words searched for.
struct TranscriptJumpRequest: Equatable, Sendable {
    /// The turn's position in the whole transcript (the server's `turn_idx`,
    /// the turn-window protocol's global index).
    let turnIndex: Int
    /// The query's words: the row of the turn that holds them is the one
    /// put at the top and lit.
    let terms: [String]
}

/// A jump the transcript can make: the requested turn is held.
///
/// The session's model makes one once the turn is in its window (fetching
/// older turns first when it is further back), anchors the screen's restore
/// decision to the turn, and the transcript opens there the way it opens at a
/// saved reading position: the window widened to the turn, the list hidden
/// until the bridge has the row in place. Then the row is lit for a moment
/// and the model forgets the jump.
struct TranscriptJump: Equatable, Sendable {
    /// Tells two jumps to the same turn apart.
    let token: Int
    let turnIndex: Int
    /// The `TimelineNode.turnID` of the rows that show the turn: its own id,
    /// or, for a turn of a reply, the reply's first turn (consecutive
    /// assistant turns merge into one reply).
    let turnID: String
    let terms: [String]

    /// Room left above the row, so it doesn't start right under the bar.
    static let topGap: CGFloat = 12

    /// The reading position the screen opens at: the turn's first row, with
    /// the window opened over it.
    func position(seenTurnEnd: Int, at date: Date = Date()) -> ReadingPosition {
        ReadingPosition(anchorID: turnID, anchorTurnID: turnID, anchorTurnMillis: nil, offset: -Double(Self.topGap),
                        atBottom: false, windowStart: nil, seenTurnEnd: seenTurnEnd, savedAt: date)
    }

    /// The `turnID` the rows of the turn at global `index` carry, nil when
    /// `turns` (the window starting at global `offset`) doesn't hold it.
    static func rowTurnID(forTurnAt index: Int, in turns: [MessageTurn], offset: Int) -> String? {
        var local = index - offset
        guard turns.indices.contains(local) else { return nil }
        if turns[local].role == .assistant {
            while local > 0, turns[local - 1].role == .assistant { local -= 1 }
        }
        return turns[local].id
    }

    /// The row to open at: the turn's row that holds the most of the
    /// searched words (a long reply's text, not its first tool call), else
    /// the turn's first row. Nil when no row shows the turn.
    static func row(for jump: TranscriptJump, in nodes: [TimelineNode]) -> String? {
        let rows = nodes.filter { $0.turnID == jump.turnID }
        guard let first = rows.first else { return nil }
        let terms = jump.terms.filter { !$0.isEmpty }
        var best: (id: String, score: Int)?
        for row in rows {
            guard let text = row.searchableText, !text.isEmpty else { continue }
            let score = terms.filter {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }.count
            if score > (best?.score ?? 0) { best = (row.id, score) }
        }
        return best?.id ?? first.id
    }

    /// Turns to ask for in one older page to reach global `target` from a
    /// window starting at `offset`: all the way in one page when the server
    /// allows it (it sends at most 500).
    static func pageLimit(target: Int, offset: Int, pageTurns: Int) -> Int {
        min(500, max(pageTurns, offset - target + 1))
    }

    /// At most this many older pages are fetched for one jump.
    static let maxPages = 20
}

extension TimelineNode {
    /// The text a message search looks in: a message's own text. Nil for
    /// tool calls, reasoning, pictures and the other rows it doesn't index.
    var searchableText: String? {
        switch content {
        case .user(let turn), .insertedUser(let turn), .system(let turn):
            return SystemText.of(turn)
        case .assistantText(let text):
            return text
        default:
            return nil
        }
    }
}
