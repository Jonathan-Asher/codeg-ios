import Foundation
import Observation

/// The newest card of each Pi sub-agent run and background job the live
/// connection reported, by the call that started it: `tool_card` events and
/// the attach snapshot's `tool_cards` (fork.234, `acp::pi_meta`). The card is
/// the call's whole `meta` in the shape the history parser writes
/// (`codeg.subagentRun`, `codeg.backgroundJob`).
///
/// A run outlives the turn that launched it, so its card keeps changing after
/// the call was drawn: in an earlier turn, or already as the transcript's
/// copy, which only knows what was written before. The cards read their
/// `meta` through ``meta(for:own:key:)``, so one renderer draws a call
/// streaming in, the same call in an earlier turn and after a reload (codeg
/// web's `LiveToolCardsProvider`). An older server sends no cards, and every
/// call draws its own `meta` as before.
@MainActor
@Observable
final class LiveToolCards {
    /// The card per call id.
    private(set) var cards: [String: AnyJSON] = [:]
    /// The connection the cards came from: another one starts over.
    @ObservationIgnored private var connectionID: String?

    init(cards: [String: AnyJSON] = [:]) {
        self.cards = cards
    }

    /// A `tool_card` event: the call's newest card, whole.
    func apply(toolCallID: String, meta: AnyJSON) {
        guard !toolCallID.isEmpty, meta.object != nil, cards[toolCallID] != meta else { return }
        cards[toolCallID] = meta
    }

    /// An attach snapshot's cards. Each is the server's newest for its call and
    /// replaces this one's; a call it doesn't list keeps its card, and a
    /// snapshot without any (an older server, or nothing launched) changes
    /// nothing. A snapshot from another connection (the agent restarted) drops
    /// the cards of the one before, which will never be updated again.
    func merge(_ snapshot: [ToolCardSnapshot], connectionID: String?) {
        if let connectionID, !connectionID.isEmpty {
            if let known = self.connectionID, known != connectionID, !cards.isEmpty { cards = [:] }
            self.connectionID = connectionID
        }
        for card in snapshot where cards[card.toolCallId] != card.meta {
            cards[card.toolCallId] = card.meta
        }
    }

    /// The connection is gone: its cards say nothing any more, and the
    /// transcript's take over.
    func removeAll() {
        connectionID = nil
        if !cards.isEmpty { cards = [:] }
    }

    /// The `meta` a run's or job's card draws from: the call's own, or this
    /// connection's newest card for it (see ``ToolCardMerge``).
    func meta(for toolCallID: String?, own: AnyJSON?, key: PiCardKey) -> AnyJSON? {
        guard let toolCallID else { return own }
        return ToolCardMerge.effective(own: own, live: cards[toolCallID], key: key)
    }

    /// A run or job the connection reports as still going: the screen keeps
    /// watching the connection for its end, and for the run Pi starts when it
    /// ends.
    var hasActiveWork: Bool {
        cards.values.contains { meta in
            SubagentRun.parse(meta)?.status.isActive == true || BackgroundJob.parse(meta)?.state.isActive == true
        }
    }
}
