import SwiftUI

/// One node on the transcript timeline. The whole transcript — persisted turns,
/// optimistic pending user turns, and the live streaming turn — flattens into a
/// single `[TimelineNode]`, and `TranscriptView`'s `List` renders one row each.
///
/// `id` is the row's stable identity (for `List` recycling, scroll-to-id, and the
/// jump-to-question affordance) — see `TranscriptTimeline` for the scheme. The
/// struct is deliberately NOT `Equatable`: `Content` carries reference types
/// (`LiveTextRun`) whose value never changes identity across a stream, so any
/// value-equality gating would suppress needed re-renders. Identity comes from
/// `id`; live re-rendering comes from `@Observable` read at the leaf.
struct TimelineNode: Identifiable {
    let id: String
    let content: Content
    /// The session's agent, used to render the agent-branded marker on assistant
    /// nodes (the rail reintroduces agent identity in the gutter without spending
    /// any content width).
    let agent: AgentType
    /// Whether the spine continues above / below this node. Suppressed only at the
    /// very first and very last node so the rail terminates at its endpoints.
    var connectTop: Bool = true
    var connectBottom: Bool = true
    /// A reply boundary begins here (user / system nodes) — used for slightly
    /// larger breathing room before a new turn.
    var startsGroup: Bool = false
    /// A user message's own files (an attached video, a picture it links),
    /// shown inside its card.
    var attachedMedia: MediaGroup?
    /// The persisted turn this node shows (a reply's first turn for its
    /// parts and footer). Nil for optimistic and live nodes. A saved reading
    /// position keeps it, to open the window over that turn again.
    var turnID: String?

    enum Content {
        case user(MessageTurn)
        /// A message the user sent into the running turn, inside the reply
        /// where the agent took it (native steering).
        case insertedUser(MessageTurn)
        case system(MessageTurn)
        case assistantText(String)
        case liveText(LiveTextRun, streaming: Bool)
        case reasoning(String)
        case liveReasoning(LiveTextRun, streaming: Bool)
        case tool(ToolCallVM)
        case toolGroup([ToolCallVM], streaming: Bool)
        case delegationStatusGroup([ToolCallVM])
        case taskGroup([ToolCallVM])
        case image(ImageData, caption: String?)
        /// The pictures, videos, audio and documents a reply refers to
        /// (links, paths, files its tools wrote or said they saved): one
        /// inline, several folded into one row.
        case media(MediaGroup)
        /// A context-compaction boundary — rendered as a chrome-less divider, not
        /// a card. Token counts are Grok-only (codex sends none).
        case compaction(before: Int?, after: Int?, running: Bool)
        /// A user turn that only says "keep going" (Continue, the resume after
        /// a restart, the continuation after a usage-limit reset), drawn as a
        /// slim divider instead of a message card.
        case continuation(ContinuePrompt.Variant)
        /// The footer under a reply. `forkTurnID` is the reply's LAST turn,
        /// where "Fork from here" forks ("up to and including this reply").
        case footer(MessageTurn, questionID: String?, forkTurnID: String?)
        case plan([PlanEntry], streaming: Bool)
        case thinking
        case error(String)
        case unsupported(String)
    }

    /// The gutter marker for this node — drives the icon and the state tint.
    var marker: MarkerKind {
        switch content {
        case .user, .insertedUser: return .user
        case .system: return .system
        case .assistantText, .liveText: return .assistant(agent)
        case .reasoning, .liveReasoning: return .reasoning
        case .tool(let vm): return .tool(icon: vm.icon, state: vm.state)
        case .toolGroup(let items, let streaming):
            return .toolGroup(error: items.contains(where: \.isError), streaming: streaming)
        case .delegationStatusGroup(let polls):
            let running = polls.contains { $0.state == .running || $0.state == .inputStreaming }
            let state: ToolCallState = running ? .running : (polls.contains(where: \.isError) ? .error : .done)
            return .tool(icon: "person.2", state: state)
        case .taskGroup(let ops):
            let running = ops.contains { $0.state == .running || $0.state == .inputStreaming }
            let state: ToolCallState = running ? .running : (ops.contains(where: \.isError) ? .error : .done)
            return .tool(icon: "checklist", state: state)
        case .image, .media: return .image
        case .compaction, .continuation: return .compaction
        case .footer: return .footer
        case .plan: return .plan
        case .thinking: return .thinking
        case .error: return .error
        case .unsupported: return .system
        }
    }
}

// MARK: - Builder

/// Flattens the transcript into `[TimelineNode]`. Reuses the same primitives the
/// old turn-based layout did — consecutive assistant turns are merged into one
/// reply (`merge`), then expanded into ordered parts by `MessageRender.adaptTurn`
/// — so grouping, tool pairing, and the value-keyed render cache all keep working;
/// only the *shell* changed from per-turn blocks to per-part rail nodes.
///
/// `@MainActor` because it reads the main-actor `MessageRender` / `LiveTurn`. Only
/// ever called from a view body, so this is free.
@MainActor
enum TranscriptTimeline {
    /// Build the **persisted** node tier — the expensive half. Flattens persisted
    /// turns + optimistic pending user turns into nodes. Deliberately does NOT read
    /// the live turn and does NOT apply the rail-endpoint (`connectTop`/`Bottom`)
    /// fixup: the caller concatenates the live tier and terminates the rail on the
    /// *combined* list, so the tail's `connectBottom` lands on the live node while a
    /// reply streams. This half is memoized by the transcript (keyed on a cheap
    /// content-free signal), because `MessageRender.adaptTurn`'s value-keyed cache
    /// hashes each `MessageTurn`'s full content on lookup — work we must not repeat
    /// per streamed token.
    ///
    /// - Parameter suppressInFlight: set when a reattach live turn owns the
    ///   in-flight reply. The snapshot's `live_message` is the COMPLETE reply, but
    ///   the agent CLI asynchronously persists a PARTIAL copy of that same reply
    ///   into `turns` while it streams — so the persisted assistant turns after the
    ///   most recent user prompt are dropped here to avoid double-rendering the reply
    ///   beside the live stream. Mirrors the web client's `getTimelineTurns`
    ///   in-flight suppression. A no-op on the send path (the optimistic prompt is in
    ///   `pending`, not `turns`, so there are no trailing persisted assistant turns).
    ///
    /// - Parameter media: where the session's paths point; with it, each
    ///   message and reply that refers to media files shows them.
    /// - Parameter presence: which of those files are on the server. A file
    ///   not checked yet is asked about and shows once it is found; one that
    ///   isn't there doesn't show, unless the reply wrote it (then it is
    ///   listed as deleted). Without it every file shows.
    static func buildPersisted(turns rawTurns: [MessageTurn], pending: [MessageTurn], agent: AgentType,
                               suppressInFlight: Bool, liveCoverage: LiveCoverage? = nil,
                               media: MediaPathContext? = nil,
                               presence: MediaPresence? = nil) -> [TimelineNode] {
        var nodes: [TimelineNode] = []

        // Hide the persisted partial in-flight reply while the reattach live turn
        // (which carries the full reply) is in hand: drop the assistant turns that
        // follow the most recent user prompt. Earlier replies stay untouched —
        // and so does this one unless the live turn holds everything it would
        // hide (`liveCovers`): a live copy rebuilt from a trimmed snapshot, or an
        // anchor that is not the running prompt, must never show less.
        let turns: [MessageTurn]
        if suppressInFlight,
           let promptIdx = rawTurns.lastIndex(where: { $0.role == .user }),
           liveCovers(rawTurns[(promptIdx + 1)...], liveCoverage) {
            turns = rawTurns.enumerated()
                .filter { $0.offset <= promptIdx || $0.element.role != .assistant }
                .map(\.element)
        } else {
            turns = rawTurns
        }

        // Persisted turns. User/system map 1:1; runs of consecutive assistant
        // turns merge into one reply (codeg persists a single logical reply as
        // several turns), then expand into part nodes + a footer.
        var lastUserID: String?
        var i = 0
        while i < turns.count {
            let turn = turns[i]
            switch turn.role {
            case .user:
                lastUserID = turn.id
                var node = userNode(turn, agent: agent)
                if case .user = node.content, let media {
                    node.attachedMedia = mediaGroup(for: turn, context: media, presence: presence)
                }
                node.turnID = turn.id
                nodes.append(node)
                i += 1
            case .system:
                // Skip system turns with no renderable text so the rail doesn't
                // show a lone marker against an empty row.
                if !SystemText.of(turn).isEmpty {
                    nodes.append(TimelineNode(id: turn.id, content: .system(turn), agent: agent, startsGroup: true,
                                              turnID: turn.id))
                }
                i += 1
            case .assistant:
                var j = i + 1
                while j < turns.count, turns[j].role == .assistant { j += 1 }
                let merged = merge(Array(turns[i..<j]))
                var reply = assistantNodes(merged: merged, questionID: lastUserID,
                                           forkTurnID: turns[j - 1].id, agent: agent,
                                           media: media, presence: presence)
                for k in reply.indices { reply[k].turnID = merged.id }
                nodes.append(contentsOf: reply)
                i = j
            }
        }

        // Optimistic user turns (sent, not yet reconciled into `turns`).
        for turn in pending {
            var node = userNode(turn, agent: agent)
            if case .user = node.content, let media {
                node.attachedMedia = mediaGroup(for: turn, context: media, presence: presence)
            }
            nodes.append(node)
        }

        return nodes
    }

    /// The files `turn` refers to that are on the server, nil when none are.
    static func mediaGroup(for turn: MessageTurn, context: MediaPathContext,
                           presence: MediaPresence?) -> MediaGroup? {
        let refs = MediaRefCache.references(in: turn, context: context)
        guard !refs.isEmpty else { return nil }
        guard let presence else { return MediaGroup(refs: refs) }
        var items: [MediaItem] = []
        for ref in refs {
            switch presence.state(of: ref.path) {
            case .present(let size)?:
                items.append(MediaItem(ref: ref, size: size))
            case .unverified?:
                items.append(MediaItem(ref: ref))
            case .missing?:
                // Only a file the reply itself wrote is worth saying is gone.
                if ref.origin == .written { items.append(MediaItem(ref: ref, isDeleted: true)) }
            case nil:
                presence.enqueue(ref.path)
            }
        }
        return items.isEmpty ? nil : MediaGroup(items: items)
    }

    /// What a live turn holds, to compare with the persisted turns it would hide.
    struct LiveCoverage: Equatable {
        let toolIDs: Set<String>
        let imageCount: Int
    }

    /// Whether the live turn holds every tool call and image of the persisted
    /// assistant turns it would hide. No coverage given: the caller vouches.
    static func liveCovers(_ hidden: ArraySlice<MessageTurn>, _ coverage: LiveCoverage?) -> Bool {
        guard let coverage else { return true }
        var toolIDs = Set<String>()
        var images = 0
        for turn in hidden where turn.role == .assistant {
            for block in turn.blocks {
                switch block {
                case .toolUse(let id, _, _, _):
                    if let id { toolIDs.insert(id) }
                case .toolResult(_, _, _, let resultImages):
                    images += resultImages.count
                case .image, .imageGeneration:
                    images += 1
                default:
                    break
                }
            }
        }
        return toolIDs.isSubset(of: coverage.toolIDs) && images <= coverage.imageCount
    }

    /// A user turn's node: a message card, or a divider for a bare Continue.
    private static func userNode(_ turn: MessageTurn, agent: AgentType) -> TimelineNode {
        if let variant = ContinuePrompt.variant(of: turn) {
            return TimelineNode(id: turn.id, content: .continuation(variant), agent: agent, startsGroup: true)
        }
        return TimelineNode(id: turn.id, content: .user(turn), agent: agent, startsGroup: true)
    }

    /// Build the **live** node tier — the in-flight reply. Cheap (O(segments); text
    /// nodes wrap the `LiveTextRun` reference, copying no prose), so the caller
    /// rebuilds it fresh on every pass while the persisted tier stays memoized. That
    /// freshness is required for correctness, not just latency: live tool cards,
    /// gutter markers, and plan statuses mutate their `LiveToolCall`/`LiveTurn` in
    /// place and render from a value snapshot with no observing leaf, so a stale
    /// live tier would freeze them at their first-rendered state.
    static func buildLive(_ live: LiveTurn, agent: AgentType) -> [TimelineNode] {
        liveNodes(live, agent: agent)
    }

    // MARK: Assistant reply → nodes

    private static func assistantNodes(merged: MessageTurn, questionID: String?, forkTurnID: String?,
                                       agent: AgentType, media: MediaPathContext? = nil,
                                       presence: MediaPresence? = nil) -> [TimelineNode] {
        var out = MessageRender.adaptTurn(merged).enumerated().map { idx, part in
            node(for: part, ownerID: merged.id, index: idx, agent: agent)
        }
        // The reply's media, above its footer.
        if let media, let group = mediaGroup(for: merged, context: media, presence: presence) {
            out.append(TimelineNode(id: "\(merged.id)#media", content: .media(group), agent: agent))
        }
        // The footer (reply time / model / tokens / copy / jump) is always emitted
        // — even when the reply has no renderable parts — so an empty or tool-only
        // turn still shows its metadata instead of vanishing.
        out.append(TimelineNode(id: "\(merged.id)#footer",
                                content: .footer(merged, questionID: questionID, forkTurnID: forkTurnID),
                                agent: agent))
        return out
    }

    /// The live reply's nodes. A message the user sent into the turn sits
    /// between the agent's output before it and the reply to it, as a message
    /// of the user's, never above the message bar only. The output between two
    /// such messages is grouped on its own, so a tool run never spans one.
    private static func liveNodes(_ live: LiveTurn, agent: AgentType) -> [TimelineNode] {
        var out: [TimelineNode] = []
        if !live.livePlan.isEmpty {
            out.append(TimelineNode(id: "\(live.id)#plan", content: .plan(live.livePlan, streaming: live.isStreaming), agent: agent))
        }
        if live.isEmpty && live.isStreaming {
            out.append(TimelineNode(id: "\(live.id)#thinking", content: .thinking, agent: agent))
        }
        let streamingID = live.isStreaming ? live.segments.last?.id : nil
        var chunk: [LiveSegment] = []
        var part = 0
        func flush() {
            guard !chunk.isEmpty else { return }
            // The first part keeps the turn's own id, so the ids of what was on
            // screen don't change when a message is sent into the turn.
            let owner = part == 0 ? live.id : "\(live.id)~\(part)"
            out.append(contentsOf: MessageRender.adaptLive(segments: chunk, streamingID: streamingID).enumerated().map {
                node(for: $1, ownerID: owner, index: $0, agent: agent)
            })
            chunk = []
        }
        for segment in live.segments {
            if case .steered(let message) = segment {
                flush()
                part += 1
                out.append(steeredNode(message, agent: agent))
            } else {
                chunk.append(segment)
            }
        }
        flush()
        // The agent has the message and hasn't answered yet.
        if live.isStreaming, live.endsWithSteered {
            out.append(TimelineNode(id: "\(live.id)#thinking~\(part)", content: .thinking, agent: agent))
        }
        if let error = live.errorMessage {
            out.append(TimelineNode(id: "\(live.id)#error", content: .error(error), agent: agent))
        }
        return out
    }

    /// A message sent into the turn: a message card marked as sent during the
    /// turn, or the Continue divider for a bare Continue.
    private static func steeredNode(_ message: SteeredMessage, agent: AgentType) -> TimelineNode {
        let turn = message.turn
        if let variant = ContinuePrompt.variant(of: turn) {
            return TimelineNode(id: turn.id, content: .continuation(variant), agent: agent, startsGroup: true)
        }
        return TimelineNode(id: turn.id, content: .insertedUser(turn), agent: agent, startsGroup: true)
    }

    // MARK: Part → node

    /// Map one `RenderPart` to a node. IDs are chosen so a tool that is `running`
    /// during streaming keeps the SAME `List` identity once the reply finalizes
    /// (both paths key tools by their ACP tool id) — its card's expand state and
    /// marker survive the live→persisted handoff instead of flashing. Text /
    /// reasoning live runs key by the segment id (`t-`/`k-`), matching
    /// `LiveSegment.id`; finalized prose keys by its part index.
    private static func node(for part: RenderPart, ownerID: String, index: Int, agent: AgentType) -> TimelineNode {
        let base = "\(ownerID)#\(index)"
        switch part {
        case .text(let s):
            return TimelineNode(id: base, content: .assistantText(s), agent: agent)
        case .reasoning(let t):
            return TimelineNode(id: base, content: .reasoning(t), agent: agent)
        case .liveText(let run, let streaming):
            return TimelineNode(id: "t-\(run.id)", content: .liveText(run, streaming: streaming), agent: agent)
        case .liveReasoning(let run, let streaming):
            return TimelineNode(id: "k-\(run.id)", content: .liveReasoning(run, streaming: streaming), agent: agent)
        case .tool(let vm):
            return TimelineNode(id: "tool-\(vm.id)", content: .tool(vm), agent: agent)
        case .toolGroup(let items, let streaming):
            let gid = items.first.map { "toolgroup-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .toolGroup(items, streaming: streaming), agent: agent)
        case .delegationStatusGroup(let polls):
            let gid = polls.first.map { "delegstatus-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .delegationStatusGroup(polls), agent: agent)
        case .taskGroup(let ops):
            let gid = ops.first.map { "taskgroup-\($0.id)" } ?? base
            return TimelineNode(id: gid, content: .taskGroup(ops), agent: agent)
        case .image(let img, let cap):
            return TimelineNode(id: base, content: .image(img, caption: cap), agent: agent)
        case .compaction(let before, let after, let running):
            return TimelineNode(id: base,
                                content: .compaction(before: before, after: after, running: running),
                                agent: agent)
        case .unknown(let type):
            return TimelineNode(id: base, content: .unsupported(type), agent: agent)
        }
    }

    // MARK: Merge (ported from the old TranscriptGrouping)

    /// Concatenate a run of assistant turns into one synthetic reply. Metadata is
    /// consolidated so the single footer reads correctly: tokens / duration summed,
    /// model + completion time from the last turn. Deterministic (no `Date()`), so
    /// the merged value is stable across rebuilds and `MessageRender.adaptTurn`'s
    /// value-keyed cache keeps hitting.
    static func merge(_ group: [MessageTurn]) -> MessageTurn {
        guard group.count > 1 else { return group[0] }
        let usages = group.compactMap(\.usage)
        let mergedUsage: TurnUsage? = usages.isEmpty ? nil : TurnUsage(
            inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
            outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
            cacheCreationInputTokens: usages.reduce(0) { $0 + $1.cacheCreationInputTokens },
            cacheReadInputTokens: usages.reduce(0) { $0 + $1.cacheReadInputTokens }
        )
        let durations = group.compactMap(\.durationMs)
        return MessageTurn(
            id: group[0].id,
            role: .assistant,
            blocks: group.flatMap(\.blocks),
            timestamp: group[0].timestamp,
            usage: mergedUsage,
            durationMs: durations.isEmpty ? nil : durations.reduce(0, +),
            model: group.last(where: { $0.model?.isEmpty == false })?.model ?? group[0].model,
            completedAt: group.last?.completedAt ?? group.last?.timestamp
        )
    }
}
