import SwiftUI
import Observation

/// The streaming state of a single in-flight tool call, keyed by its ACP tool
/// id. Mutated in place as `tool_call_update` events arrive so the UI updates
/// granularly without rebuilding the whole turn.
@MainActor
@Observable
final class LiveToolCall: Identifiable {
    nonisolated let id: String
    var title: String
    var kind: String
    var status: String
    /// Echoed argument JSON (preview), shown under the tool name.
    var rawInput: String?
    /// Accumulated output text. `tool_call_update` with `append:true` appends,
    /// otherwise the value replaces.
    var rawOutput: String
    /// ACP "rendered content" — for an edit this is the unified diff. Kept so the
    /// card can render a red/green diff live (previously this field was dropped).
    var content: String?
    /// ACP `meta` — for `delegate_to_agent` carries `codeg.delegation`, whose
    /// terminal status the delegate card prefers over the running ack. Patched in
    /// place when a `tool_call_update` carries a newer meta.
    var meta: AnyJSON?
    /// Pictures the tool returned (a Read of a PNG, a screenshot). Replaced by
    /// an update that carries images, kept by one that carries none.
    var images: [ImageData]

    init(id: String, title: String, kind: String, status: String, rawInput: String?, rawOutput: String,
         content: String? = nil, meta: AnyJSON? = nil, images: [ImageData] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.content = content
        self.meta = meta
        self.images = images
    }

    /// True once the agent reports the call finished (success or failure).
    var isFinished: Bool {
        switch status {
        case "completed", "failed", "error", "cancelled", "canceled": return true
        default: return false
        }
    }

    var isError: Bool {
        status == "failed" || status == "error"
    }

    /// SF Symbol chosen from the ACP `kind` hint, falling back to a generic
    /// wrench. Mirrors the kinds emitted by the codeg agents.
    var symbol: String {
        switch kind.lowercased() {
        case "read", "fetch": return "doc.text"
        case "edit", "write": return "square.and.pencil"
        case "search", "grep", "find": return "magnifyingglass"
        case "execute", "command", "bash", "shell", "terminal": return "terminal"
        case "think": return "brain"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "web", "browser": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// One ordered piece of an in-flight assistant turn. The live turn is a sequence
/// of these so text, reasoning, and tool calls render in arrival order, exactly
/// as a finalized transcript would. The associated reference types expose a
/// `nonisolated let id`, so the enum's `id` needs no actor hop.
enum LiveSegment: Identifiable {
    case text(LiveTextRun)
    case thinking(LiveTextRun)
    case tool(LiveToolCall)
    /// A message the user sent into the turn, where the agent took it: it
    /// ends what the agent said so far, and the reply to it follows.
    case steered(SteeredMessage)

    var id: String {
        switch self {
        case .text(let run): return "t-\(run.id)"
        case .thinking(let run): return "k-\(run.id)"
        case .tool(let call): return "x-\(call.id)"
        case .steered(let message): return "s-\(message.id)"
        }
    }
}

/// A message delivered into the running turn (native steering), as the
/// conversation shows it: a message of the user's inside the reply, as on
/// the desktop. The agent writes its own copy into the transcript, which
/// replaces this one once the turn is reconciled.
struct SteeredMessage: Hashable, Sendable {
    /// Row identity: the phone's own id for a message sent from here, else
    /// `fb-` and the server's note id.
    let id: String
    /// The server's note id, once known (the `feedback_submitted` echo or the
    /// response). Ties the echo, the response and a snapshot's `feedback`
    /// to this message.
    var serverID: String?
    /// The text as sent, for matching.
    let text: String
    /// What renders: the text, then any pictures.
    let blocks: [ContentBlock]
    let timestamp: Date
    /// Where it sits among the agent's output (see ``SteerAnchor``).
    var anchor: SteerAnchor

    /// The message as a user turn of the conversation.
    var turn: MessageTurn {
        MessageTurn(id: "steer-\(id)", role: .user, blocks: blocks, timestamp: timestamp)
    }
}

/// Where a message delivered into the turn sits among the agent's output: after
/// the last tool call before it, and after so many bytes of text and reasoning
/// that followed that call. A snapshot's live message marks no such point and
/// joins the text on both sides into one block, so this is what puts the
/// message back in its place when the turn is rebuilt from a snapshot (a
/// reconnect, the app coming back to the foreground).
struct SteerAnchor: Hashable, Sendable {
    /// The last tool call before the message; nil when none came before it.
    let afterToolID: String?
    /// UTF-8 bytes of text and reasoning between that tool call (or the
    /// start of the reply) and the message.
    let proseBytes: Int
}

/// A growing run of text (either assistant prose or reasoning). A reference type
/// so appending a delta mutates in place and SwiftUI re-renders just this run.
///
/// Deltas land token-by-token, but the *published* `text` is coalesced to a
/// ~50ms cadence so the view re-parses (block Markdown) at most ~20×/sec instead
/// of once per token — the streaming path now renders formatted Markdown live
/// (`MarkdownContent`), and re-parsing the whole accumulated reply per token
/// would be O(n²) main-thread work. The raw `buffer` is always current (so
/// snapshots never lose the tail); `text` trails it by up to one coalesce window.
@MainActor
@Observable
final class LiveTextRun: Identifiable {
    nonisolated let id = UUID().uuidString

    /// What views render. Published at most ~every 50ms while streaming.
    private(set) var text: String

    /// The full accumulated text, updated synchronously on every delta. NOT
    /// observed, so appends don't invalidate views between flushes; read via
    /// `fullText` for snapshotting.
    @ObservationIgnored private var buffer: String
    /// Pending coalesce task; non-nil means a flush is already scheduled.
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// Coalesce window for streamed text, scaled with the accumulated length. Each
    /// flush re-parses the whole buffer (block Markdown), which is ~O(n), so a fixed
    /// 50ms cadence makes the stream O(n²). Short replies — the common case — stay
    /// snappy at 50ms; a long reply relaxes toward ~140ms, dropping the re-parse
    /// rate as the per-parse cost rises. `flushNow()` still publishes the complete
    /// text on finalize, so this only trades a little tail latency, never content.
    private var coalesceWindow: Duration {
        switch buffer.utf8.count {
        case ..<4_000:  return .milliseconds(50)
        case ..<16_000: return .milliseconds(90)
        default:        return .milliseconds(140)
        }
    }

    init(_ text: String) {
        self.text = text
        self.buffer = text
    }

    /// Authoritative full content, regardless of any pending flush. Snapshots and
    /// finalization read this so the last partial chunk is never dropped.
    var fullText: String { buffer }

    /// Append a streamed delta. The buffer updates immediately; the observed
    /// `text` is published on the next coalesce tick.
    func append(_ delta: String) {
        buffer += delta
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }   // leading-guard: one task per window
        let window = coalesceWindow              // sampled at schedule time
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard let self else { return }
            self.flushTask = nil
            if self.text != self.buffer { self.text = self.buffer }   // trailing publish
        }
    }

    /// Publish the buffer immediately and cancel any pending coalesce. Call when
    /// the turn finalizes / fails / is cancelled so the finalized render sees the
    /// complete text with no trailing reflow.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        if text != buffer { text = buffer }
    }
}

/// The mutable, observable model for the assistant reply that is currently
/// streaming. Built optimistically when the user sends, mutated as ACP events
/// arrive, then converted to an immutable `MessageTurn` on completion.
@MainActor
@Observable
final class LiveTurn: Identifiable {
    nonisolated let id: String
    private(set) var segments: [LiveSegment] = []
    /// Tool-call lookup so `tool_call_update` finds its target in O(1).
    private var toolIndex: [String: LiveToolCall] = [:]
    /// The agent's live plan/TODO list (`plan_update`). Replaced wholesale per
    /// event (each carries the full list); rendered as a checklist above the turn.
    var livePlan: [PlanEntry] = []
    /// Fatal error surfaced inline at the end of the turn.
    var errorMessage: String?
    /// Whether the turn is still receiving events (drives the pulse).
    var isStreaming = true
    /// Most recent stop reason once the turn completes.
    var stopReason: String?

    init(id: String = "live-\(UUID().uuidString)") {
        self.id = id
    }

    /// True before any content has streamed — used to show a "waiting" shimmer.
    /// A message the user sent into the turn counts as content: it must never
    /// be dropped with an empty placeholder.
    var isEmpty: Bool { segments.isEmpty && errorMessage == nil && livePlan.isEmpty }

    /// The messages the user sent into this turn, in order.
    var steeredMessages: [SteeredMessage] {
        segments.compactMap { if case .steered(let message) = $0 { return message } else { return nil } }
    }

    /// The reply so far ends on a message the user sent into it: the agent
    /// hasn't answered it yet.
    var endsWithSteered: Bool {
        if case .steered? = segments.last { return true }
        return false
    }

    /// Replace the live plan from a `plan_update` event (or snapshot `plan` block).
    func updatePlan(_ entries: [PlanEntry]) {
        livePlan = entries
    }

    // MARK: - Mutation (event handlers call these on the main actor)

    func appendText(_ delta: String) {
        guard !delta.isEmpty else { return }
        if case .text(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.text(LiveTextRun(delta)))
        }
    }

    func appendThinking(_ delta: String) {
        guard !delta.isEmpty else { return }
        if case .thinking(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.thinking(LiveTextRun(delta)))
        }
    }

    /// Flush every text/reasoning run's pending coalesce immediately. Called when
    /// the turn ends so the finalized render sees complete text (no trailing
    /// reflow) and a snapshot taken right after is whole.
    func flushAllText() {
        for segment in segments {
            switch segment {
            case .text(let run), .thinking(let run): run.flushNow()
            case .tool, .steered: break
            }
        }
    }

    // MARK: - Messages sent into the turn

    /// Whether this turn shows the message with this row id or server note id.
    func containsSteered(id: String? = nil, serverID: String? = nil) -> Bool {
        segments.contains { segment in
            guard case .steered(let message) = segment else { return false }
            if let id, message.id == id { return true }
            if let serverID, message.serverID == serverID { return true }
            return false
        }
    }

    /// Show a message the agent took into this turn at the current end of the
    /// reply: what the agent says next is the reply to it. Idempotent by row
    /// id and by server note id (the echo and the response both report it).
    @discardableResult
    func insertSteered(id: String, serverID: String?, text: String, blocks: [ContentBlock],
                       timestamp: Date = Date()) -> Bool {
        if containsSteered(id: id, serverID: serverID) {
            if let serverID { bindSteered(id: id, serverID: serverID) }
            return false
        }
        // Publish the text before the message, so the run it ends shows whole.
        flushAllText()
        let message = SteeredMessage(id: id, serverID: serverID, text: text,
                                     blocks: blocks.isEmpty ? [.text(text)] : blocks,
                                     timestamp: timestamp, anchor: currentAnchor())
        segments.append(.steered(message))
        return true
    }

    /// Record the server's note id of a message shown by row id.
    func bindSteered(id: String, serverID: String) {
        for index in segments.indices {
            guard case .steered(var message) = segments[index], message.id == id,
                  message.serverID == nil else { continue }
            message.serverID = serverID
            segments[index] = .steered(message)
        }
    }

    /// Put the messages of `old` (the same turn, as this screen showed it before
    /// this copy was rebuilt from a snapshot) back where they were, so a
    /// reconnect never takes them out of the conversation. `keep` says which
    /// still belong to the turn the snapshot runs.
    func adoptSteered(from old: LiveTurn, keep: (SteeredMessage) -> Bool = { _ in true }) {
        for message in old.steeredMessages where keep(message) && !containsSteered(id: message.id, serverID: message.serverID) {
            place(message)
        }
    }

    /// Where a message sent now sits among the agent's output.
    private func currentAnchor() -> SteerAnchor {
        var bytes = 0
        for segment in segments.reversed() {
            switch segment {
            case .tool(let call): return SteerAnchor(afterToolID: call.id, proseBytes: bytes)
            case .text(let run), .thinking(let run): bytes += run.fullText.utf8.count
            case .steered: break
            }
        }
        return SteerAnchor(afterToolID: nil, proseBytes: bytes)
    }

    /// Insert `message` at its anchor. When this copy doesn't hold the tool
    /// call it came after (a trimmed snapshot), or holds less text than it
    /// came after, it goes at the end: never dropped.
    private func place(_ message: SteeredMessage) {
        var index = 0
        if let tool = message.anchor.afterToolID {
            guard let found = segments.firstIndex(where: {
                if case .tool(let call) = $0 { return call.id == tool } else { return false }
            }) else {
                segments.append(.steered(message))
                return
            }
            index = found + 1
        }
        var remaining = message.anchor.proseBytes
        while index < segments.count {
            switch segments[index] {
            case .steered:
                // An earlier message at the same point stays first.
                index += 1
                continue
            case .tool:
                segments.insert(.steered(message), at: index)
                return
            case .text(let run), .thinking(let run):
                if remaining == 0 {
                    segments.insert(.steered(message), at: index)
                    return
                }
                let full = run.fullText
                let length = full.utf8.count
                if remaining < length {
                    let split = Self.splitIndex(in: full, utf8Offset: remaining)
                    let head = LiveTextRun(String(full[..<split]))
                    let tail = LiveTextRun(String(full[split...]))
                    let isThinking: Bool
                    if case .thinking = segments[index] { isThinking = true } else { isThinking = false }
                    segments.replaceSubrange(index...index, with: [
                        isThinking ? .thinking(head) : .text(head),
                        .steered(message),
                        isThinking ? .thinking(tail) : .text(tail),
                    ])
                    return
                }
                remaining -= length
                index += 1
            }
        }
        segments.append(.steered(message))
    }

    /// The character boundary at or before `offset` UTF-8 bytes into `text`.
    private static func splitIndex(in text: String, utf8Offset offset: Int) -> String.Index {
        let utf8 = text.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
        while index > text.startIndex, String.Index(index, within: text) == nil {
            index = utf8.index(before: index)
        }
        return index
    }

    func upsertToolCall(id: String, title: String, kind: String, status: String, rawInput: String?, rawOutput: String?,
                        content: String?, meta: AnyJSON? = nil, images: [ImageData]? = nil) {
        if let existing = toolIndex[id] {
            existing.title = title.isEmpty ? existing.title : title
            if !kind.isEmpty { existing.kind = kind }
            if !status.isEmpty { existing.status = status }
            if let rawInput { existing.rawInput = rawInput }
            if let rawOutput { existing.rawOutput = rawOutput }
            if let content { existing.content = content }
            if let meta { existing.meta = meta }
            if let images, !images.isEmpty { existing.images = images }
        } else {
            let call = LiveToolCall(
                id: id,
                title: title.isEmpty ? "Tool" : title,
                kind: kind,
                status: status.isEmpty ? "in_progress" : status,
                rawInput: rawInput,
                rawOutput: rawOutput ?? "",
                content: content,
                meta: meta,
                images: images ?? []
            )
            toolIndex[id] = call
            segments.append(.tool(call))
        }
    }

    func updateToolCall(id: String, title: String?, status: String?, rawInput: String?, rawOutput: String?, content: String?,
                        append: Bool, meta: AnyJSON? = nil, images: [ImageData]? = nil) {
        guard let call = toolIndex[id] else {
            // An update for a tool we never saw a `tool_call` for — materialize it
            // so its input/output is not lost.
            upsertToolCall(
                id: id,
                title: title ?? "",
                kind: "",
                status: status ?? "",
                rawInput: rawInput,
                rawOutput: rawOutput,
                content: content,
                meta: meta,
                images: images
            )
            return
        }
        if let title, !title.isEmpty { call.title = title }
        if let status, !status.isEmpty { call.status = status }
        // Capture arguments arriving on an update (or replacing a partial input)
        // so companion classification can key off the input shape.
        if let rawInput, !rawInput.isEmpty { call.rawInput = rawInput }
        if let content { call.content = content }
        // A newer meta (e.g. the delegate lifecycle's terminal `codeg.delegation`)
        // replaces the prior one so the live delegate card stops reading "running".
        if let meta { call.meta = meta }
        if let rawOutput {
            if append { call.rawOutput += rawOutput } else { call.rawOutput = rawOutput }
        }
        // Replace-on-update, like the server: an update carrying images replaces
        // them, one carrying none keeps what was shown.
        if let images, !images.isEmpty { call.images = images }
    }

    /// Ids of the tool calls this turn holds, and how many images they show —
    /// what the transcript compares with the persisted copy of the same reply
    /// before letting this one stand in for it.
    var toolCallIDs: Set<String> { Set(toolIndex.keys) }
    var imageCount: Int {
        segments.reduce(0) { count, segment in
            if case .tool(let call) = segment { return count + call.images.count }
            return count
        }
    }

    /// Short human-readable label for the currently active tool, for the compose
    /// status line ("Running Edit…").
    var activeToolTitle: String? {
        for segment in segments.reversed() {
            if case .tool(let call) = segment, !call.isFinished {
                return call.title
            }
        }
        return nil
    }

    /// Snapshot this (finalized) turn's agent output as one immutable assistant
    /// `MessageTurn`, leaving out the messages the user sent into it.
    func snapshotAsMessageTurn() -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: segments.flatMap(Self.blocks(of:)), timestamp: Date())
    }

    /// Snapshot this (finalized) turn as immutable turns, so a reply that
    /// finished streaming but isn't yet in the server transcript can be folded
    /// into the persisted list — surviving a subsequent send — until a reconcile
    /// replaces it with the authoritative copy. A message the user sent into the
    /// turn becomes a user turn where it was, between the assistant turns of
    /// the reply around it, as the server's transcript has it. Assistant turns
    /// with nothing in them are left out.
    func snapshotAsMessageTurns() -> [MessageTurn] {
        var out: [MessageTurn] = []
        var blocks: [ContentBlock] = []
        var part = 0
        func flush() {
            if !blocks.isEmpty {
                out.append(MessageTurn(id: part == 0 ? id : "\(id)~\(part)", role: .assistant,
                                       blocks: blocks, timestamp: Date()))
            }
            blocks = []
        }
        for segment in segments {
            if case .steered(let message) = segment {
                flush()
                part += 1
                out.append(message.turn)
            } else {
                blocks.append(contentsOf: Self.blocks(of: segment))
            }
        }
        flush()
        return out
    }

    /// Segment→block mapping, mirroring `MessageRender.adaptLive` so a folded
    /// copy renders the same; a tool's diff `content` rides in the result
    /// preview (its only persisted slot) when there's no separate output text.
    private static func blocks(of segment: LiveSegment) -> [ContentBlock] {
        switch segment {
        case .text(let run):
            return run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.text(run.fullText)]
        case .thinking(let run):
            return run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.thinking(run.fullText)]
        case .tool(let call):
            let output = call.rawOutput.isEmpty ? call.content : call.rawOutput
            return [
                .toolUse(id: call.id, name: call.title, inputPreview: call.rawInput, meta: call.meta),
                .toolResult(id: call.id, outputPreview: output, isError: call.isError, images: call.images),
            ]
        case .steered:
            return []
        }
    }
}
