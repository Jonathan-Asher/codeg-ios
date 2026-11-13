import Foundation

// The cards codeg's Pi parser folds delegated work into (fork.234,
// `parsers/pi/fold.rs`), read off a tool call's `meta`. A live Pi connection
// sends the same cards (`parsers/pi/live.rs` reshapes pi-acp's own): on the
// call while its turn runs, then as `tool_card` events and in the snapshot's
// `tool_cards` (see ``LiveToolCards``), plus a few fields only a run still
// going has (`activity`, `live`).
//
// - `codeg.subagentRun` on the `Agent` call that started a pi-subagents run:
//   its status, its result, and one row per child;
// - `codeg.backgroundJob` on a `bgj_run` command: how the job ended;
// - `codeg.agentWake` on the marker opening a run Pi started by itself;
// - `codeg.systemNote` on a live notice no card claims.
//
// Every parser returns nil for anything else, so a call whose `meta` lacks the
// key, or carries a shape this build doesn't know, renders exactly as before.
// codeg web reads the same keys (`src/lib/agent-run-meta.ts`).

/// The `meta` keys of the Pi cards.
enum PiMetaKey {
    static let subagentRun = "codeg.subagentRun"
    static let backgroundJob = "codeg.backgroundJob"
    static let agentWake = "codeg.agentWake"
    static let systemNote = "codeg.systemNote"
}

/// The two cards a live connection keeps updating after their turn.
enum PiCardKey: String, Hashable, Sendable {
    case subagentRun = "codeg.subagentRun"
    case backgroundJob = "codeg.backgroundJob"

    /// The states the transcript only writes once the run or job ended.
    var settledStates: Set<String> {
        switch self {
        case .subagentRun: return ["completed", "failed", "paused", "stopped"]
        case .backgroundJob: return ["completed", "failed", "killed", "unknown"]
        }
    }

    /// The field the state is in.
    var stateField: String {
        switch self {
        case .subagentRun: return "status"
        case .backgroundJob: return "state"
        }
    }
}

// MARK: - Sub-agent runs

enum SubagentRunStatus: String, Hashable, Sendable, CaseIterable {
    case completed, failed, paused, stopped, running
    /// History: launched in the background, no outcome in the transcript.
    /// Live: queued, not started yet.
    case pending

    /// Still going (as far as a live card can tell).
    var isActive: Bool { self == .running || self == .pending }
}

/// A question a child asked its parent, and the parent's answer.
struct SubagentRunExchange: Hashable, Sendable {
    let question: String
    let answer: String?
}

/// One child of a run: a workflow lane, a parallel task or a chain step.
struct SubagentRunChild: Hashable, Sendable, Identifiable {
    let key: String
    /// What to call the child: its workflow key, else its agent.
    let label: String
    let agent: String?
    let status: SubagentRunStatus?
    let task: String?
    let error: String?
    let result: String?
    /// The child's own Pi session (its header id), openable with
    /// `get_conversation`.
    let sessionId: String?
    let model: String?
    let tokens: Int?
    let turns: Int?
    let exchanges: [SubagentRunExchange]
    /// Questions it asked that have no answer yet.
    let attention: [String]
    /// Live only, while the child works: its current tool.
    let currentTool: String?

    var id: String { key }
}

/// Text the model was given that a card now shows as structure.
struct ModelNote: Hashable, Sendable {
    /// `launch`, `question`, `child`, `result`, `attention`, `jobExit`,
    /// `notice`, or a wake kind.
    let kind: String
    let text: String
}

struct SubagentRun: Hashable, Sendable {
    /// `single`, `parallel`, `chain` or `workflow`.
    let mode: String
    let isAsync: Bool
    let status: SubagentRunStatus
    let agent: String?
    let task: String?
    let durationMs: Int?
    let tokens: Int?
    /// The run's own result (a workflow's return value, a child's report).
    let result: String?
    let error: String?
    let children: [SubagentRunChild]
    let notes: [ModelNote]
    /// The card came from the live channel, not the transcript.
    let isLive: Bool

    /// The sub-agent run card in `meta`, or nil.
    static func parse(_ meta: AnyJSON?) -> SubagentRun? {
        guard let run = meta?[PiMetaKey.subagentRun]?.object,
              let status = PiCardValue.runStatus(run["status"]) else { return nil }
        return SubagentRun(
            mode: PiCardValue.text(run["mode"]) ?? "single",
            isAsync: run["async"]?.bool == true,
            status: status,
            agent: PiCardValue.text(run["agent"]),
            task: PiCardValue.text(run["task"]),
            durationMs: PiCardValue.count(run["durationMs"]),
            tokens: PiCardValue.count(run["tokens"]),
            result: PiCardValue.text(run["result"]),
            error: PiCardValue.text(run["error"]),
            children: (run["children"]?.array ?? []).compactMap(Self.child),
            notes: PiCardValue.notes(run["notes"]),
            isLive: run["live"]?.bool == true
        )
    }

    private static func child(_ value: AnyJSON) -> SubagentRunChild? {
        guard let row = value.object, let key = PiCardValue.text(row["key"]) else { return nil }
        let exchanges: [SubagentRunExchange] = (row["exchanges"]?.array ?? []).compactMap { item in
            guard let question = PiCardValue.text(item["question"]) else { return nil }
            return SubagentRunExchange(question: question, answer: PiCardValue.text(item["answer"]))
        }
        let attention = (row["attention"]?.array ?? []).compactMap { PiCardValue.text($0) }
        return SubagentRunChild(
            key: key,
            label: PiCardValue.text(row["label"]) ?? key,
            agent: PiCardValue.text(row["agent"]),
            status: PiCardValue.runStatus(row["status"]),
            task: PiCardValue.text(row["task"]),
            error: PiCardValue.text(row["error"]),
            result: PiCardValue.text(row["result"]),
            sessionId: PiCardValue.text(row["sessionId"]),
            model: PiCardValue.text(row["model"]),
            tokens: PiCardValue.count(row["tokens"]),
            turns: PiCardValue.count(row["turns"]),
            exchanges: exchanges,
            attention: attention,
            currentTool: PiCardValue.text(row["activity"]?["currentTool"])
        )
    }

    /// What the card is called: the agent its children share (or the run's
    /// one agent), else how it ran.
    var title: String { agent ?? mode }

    /// How the run reads at a glance (its marker's tint).
    enum Tone: Hashable, Sendable {
        case working, done, failed
        /// Paused, stopped, or launched with no outcome recorded.
        case quiet
    }

    var tone: Tone {
        switch status {
        case .running: return .working
        // Live, a run not started yet; in history, one whose end the
        // transcript never recorded, which is no reason to look busy.
        case .pending: return isLive ? .working : .quiet
        case .completed: return .done
        case .failed: return .failed
        case .paused, .stopped: return .quiet
        }
    }
}

// MARK: - Background jobs

enum BackgroundJobState: String, Hashable, Sendable, CaseIterable {
    case completed, failed, killed
    /// It ended with no exit code.
    case unknown
    /// History: no exit recorded in the transcript.
    case pending
    /// Live: the job is still going.
    case running

    var isActive: Bool { self == .running }
}

struct BackgroundJob: Hashable, Sendable {
    let id: String?
    let state: BackgroundJobState
    let exitCode: Int?
    /// `bgj_kill` (the model), `timeout`, `user`.
    let killedBy: String?
    /// As pi-bg-jobs spells it: `58s`, `3m 52s`.
    let duration: String?
    /// The last lines of the job's output.
    let tail: String?
    /// The exit notice as the model read it.
    let notice: String?
    let isLive: Bool

    /// How the job a `bgj_run` started ended, or nil.
    static func parse(_ meta: AnyJSON?) -> BackgroundJob? {
        guard let job = meta?[PiMetaKey.backgroundJob]?.object,
              let raw = job["state"]?.string, let state = BackgroundJobState(rawValue: raw) else { return nil }
        return BackgroundJob(
            id: PiCardValue.text(job["id"]),
            state: state,
            exitCode: PiCardValue.signedCount(job["exitCode"]),
            killedBy: PiCardValue.text(job["killedBy"]),
            duration: PiCardValue.text(job["duration"]),
            tail: PiCardValue.text(job["tail"]),
            notice: PiCardValue.text(job["notice"]),
            isLive: job["live"]?.bool == true
        )
    }
}

// MARK: - Runs Pi started by itself

enum AgentWakeKind: String, Hashable, Sendable, CaseIterable {
    case subagentQuestion, subagentSettled, subagentAttention, jobExit, `extension`
}

/// The marker opening a run Pi started by itself because a notice woke it.
struct AgentWake: Hashable, Sendable {
    struct Trigger: Hashable, Sendable {
        let kind: AgentWakeKind
        /// What the model read.
        let text: String
    }

    let triggers: [Trigger]

    /// The marker in `meta`, or nil.
    static func parse(_ meta: AnyJSON?) -> AgentWake? {
        guard let wake = meta?[PiMetaKey.agentWake]?.object, let list = wake["triggers"]?.array else { return nil }
        let triggers = list.map { item in
            Trigger(kind: item["kind"]?.string.flatMap(AgentWakeKind.init(rawValue:)) ?? .extension,
                    text: item["text"]?.string ?? "")
        }
        return triggers.isEmpty ? nil : AgentWake(triggers: triggers)
    }

    /// The marker a turn carries: history draws it on a System turn of its
    /// own (`[caption, agent_wake call, result]`).
    static func of(_ turn: MessageTurn) -> AgentWake? {
        for block in turn.blocks {
            if case .toolUse(_, _, _, let meta) = block, let wake = parse(meta) { return wake }
        }
        return nil
    }

    /// The notices behind it, as the "what the model saw" toggle lists them.
    var notes: [ModelNote] {
        triggers.compactMap { trigger in
            let text = trigger.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ModelNote(kind: trigger.kind.rawValue, text: trigger.text)
        }
    }
}

/// A displayed notice no card claims, live: the System note history shows
/// for it.
struct PiSystemNote: Hashable, Sendable {
    let customType: String?
    let text: String

    static func parse(_ meta: AnyJSON?) -> PiSystemNote? {
        guard let note = meta?[PiMetaKey.systemNote]?.object, let text = PiCardValue.text(note["text"]) else {
            return nil
        }
        return PiSystemNote(customType: PiCardValue.text(note["customType"]), text: text)
    }
}

// MARK: - The live card wins until the transcript has the end

/// Which card a run's or job's call draws from: its own `meta`, or the live
/// connection's newest card for it (codeg web's `useToolCardMeta`). The live
/// card wins while the run is going, since the transcript can only say it was
/// launched, and over any copy of a live card the call carries (the
/// connection's is always the newest). Once the transcript has the run's end
/// its own card wins: it is what every reload draws, read from the same
/// notices plus what only the transcript keeps, so the card ends exactly as
/// history shows it.
enum ToolCardMerge {
    /// Whether `own` is the transcript's card (no `live` mark) for a run or
    /// job the transcript has seen end.
    static func settledInTranscript(_ own: AnyJSON?, key: PiCardKey) -> Bool {
        guard let card = own?[key.rawValue]?.object, card["live"]?.bool != true,
              let state = card[key.stateField]?.string else { return false }
        return key.settledStates.contains(state)
    }

    /// The `meta` the card draws from.
    static func effective(own: AnyJSON?, live: AnyJSON?, key: PiCardKey) -> AnyJSON? {
        guard let live, live[key.rawValue]?.object != nil, !settledInTranscript(own, key: key) else { return own }
        return live
    }
}

/// One entry of a live snapshot's `tool_cards`: a call and its card's whole
/// `meta`.
struct ToolCardSnapshot: Hashable, Sendable, Decodable {
    let toolCallId: String
    let meta: AnyJSON

    private enum CodingKeys: String, CodingKey { case toolCallId, meta }

    init(toolCallId: String, meta: AnyJSON) {
        self.toolCallId = toolCallId
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try c.decode(String.self, forKey: .toolCallId)
        meta = try c.decode(AnyJSON.self, forKey: .meta)
    }

    /// A snapshot's list, skipping any entry that doesn't decode (or has no
    /// id or card).
    static func lenientList<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [ToolCardSnapshot] {
        guard c.contains(key), (try? c.decodeNil(forKey: key)) == false,
              var list = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [ToolCardSnapshot] = []
        while !list.isAtEnd {
            if let card = try? list.decode(ToolCardSnapshot.self) {
                if !card.toolCallId.isEmpty, card.meta.object != nil { out.append(card) }
            } else if (try? list.decode(SkippedCard.self)) == nil {
                break
            }
        }
        return out
    }

    private struct SkippedCard: Decodable {
        init(from decoder: Decoder) {}
    }
}

// MARK: - Where a run Pi started by itself begins

/// The turn a running turn is anchored on. A prompt's turn is its user turn
/// (`in_flight_user_turn_id`); a run Pi started by itself has no prompt, so
/// fork.234 names the System turn history draws as its "woken by" divider once
/// Pi has written the run's first reply, and before that a marker no turn
/// carries (`pi-agent-turn-<ms>`): nothing of the run is in the transcript yet.
enum InFlightAnchor {
    static let piAgentTurnPrefix = "pi-agent-turn-"

    /// The id the server gives a run Pi started by itself before any of it is
    /// in the transcript.
    static func isPiAgentTurnMarker(_ id: String?) -> Bool {
        id?.hasPrefix(piAgentTurnPrefix) == true
    }

    /// Whether `turn` can be the one an in-flight id names: a prompt, or the
    /// "woken by" divider of a run Pi started by itself.
    static func canAnchor(_ turn: MessageTurn) -> Bool {
        turn.role == .user || (turn.role == .system && AgentWake.of(turn) != nil)
    }

    /// Where the running turn starts in `turns`: the turn the server names,
    /// the end of the transcript for a run none of which is in it yet, else
    /// the last user turn. nil when there is none.
    static func index(in turns: [MessageTurn], promptID: String?) -> Int? {
        if let promptID {
            if let index = turns.lastIndex(where: { $0.id == promptID && canAnchor($0) }) { return index }
            if isPiAgentTurnMarker(promptID) { return turns.count }
        }
        return turns.lastIndex { $0.role == .user }
    }
}

// MARK: - Background job polls

/// What a `bgj_status` / `bgj_wait` / `bgj_kill` call reported about its job,
/// as codeg web reads pi-bg-jobs' result lines (`parsePiJobEnvelope`):
///
///     [jb-x] completed (exit 0) · 3m 52s · <command preview>
///
///     --- output tail ---
///     …
///
/// A kill answers `Sent SIGTERM to <id> (<command>)…`.
struct JobPollReport: Hashable, Sendable {
    enum Outcome: String, Hashable, Sendable {
        case running, completed, failed, stopped
    }

    let jobID: String
    let outcome: Outcome
    let exitCode: Int?
    let command: String?
    let output: String?

    private static let lineRegex = try? NSRegularExpression(
        pattern: #"^(?:Already finished: )?\[(jb-[A-Za-z0-9_.-]+)\] ([^·\n]+?) · ([^·\n]+?) · ([^\n]*)"#)
    private static let killRegex = try? NSRegularExpression(
        pattern: #"^Sent SIGTERM to (jb-[A-Za-z0-9_.-]+) \(([\s\S]*)\)(?:; SIGKILL follows[\s\S]*)?$"#)
    private static let exitRegex = try? NSRegularExpression(pattern: #"exit (-?\d+)"#)

    /// The report in a poll's result, or nil when it is none of pi-bg-jobs'
    /// shapes.
    static func parse(_ text: String?) -> JobPollReport? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = killRegex?.firstMatch(in: text, range: range),
           let id = group(match, 1, in: text) {
            return JobPollReport(jobID: id, outcome: .stopped, exitCode: nil,
                                 command: group(match, 2, in: text), output: nil)
        }
        guard let match = lineRegex?.firstMatch(in: text, range: range),
              let id = group(match, 1, in: text),
              let state = group(match, 2, in: text)?.trimmingCharacters(in: .whitespaces) else { return nil }
        let exitCode = exitRegex?.firstMatch(in: state, range: NSRange(state.startIndex..., in: state))
            .flatMap { group($0, 1, in: state) }.flatMap { Int($0) }
        let tail = text.components(separatedBy: "\n--- output tail ---\n").dropFirst().first
        let output = tail.map { $0.trimmingCharacters(in: .newlines) }
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0 == "(no output)" ? nil : $0 }
        let command = group(match, 4, in: text)?.trimmingCharacters(in: .whitespaces)
        let outcome: Outcome
        if state.hasPrefix("killed") {
            outcome = .stopped
        } else if state.hasPrefix("completed") || state.hasPrefix("ended") {
            outcome = (exitCode ?? 0) != 0 ? .failed : .completed
        } else if state.hasPrefix("failed") {
            outcome = .failed
        } else {
            outcome = .running
        }
        return JobPollReport(jobID: id, outcome: outcome, exitCode: exitCode,
                             command: command?.isEmpty == false ? command : nil, output: output)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

/// One poll call, as the poll card reads it.
struct JobPollCall: Hashable, Sendable {
    let callID: String
    let input: String?
    let output: String?
    let isError: Bool
    /// The call has its result.
    let finished: Bool
}

/// One job of a run of consecutive polls: its latest outcome, with the
/// freshest command and output any poll of it reported.
struct JobPollRow: Hashable, Sendable, Identifiable {
    let id: String
    let jobID: String?
    let outcome: JobPollReport.Outcome
    let exitCode: Int?
    let command: String?
    let output: String?
    let pollCount: Int
    /// The latest poll is still waiting for its result.
    let inFlight: Bool
}

enum JobPolls {
    static let toolNames: Set<String> = ["bgj_status", "bgj_wait", "bgj_kill"]

    /// Whether a tool name is a pi-bg-jobs poll.
    static func isPoll(_ name: String) -> Bool {
        toolNames.contains(name.lowercased())
    }

    /// The job a poll's arguments name (`{"id": "jb-…"}`).
    static func inputJobID(_ input: String?) -> String? {
        guard let input, let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, id.hasPrefix("jb-") else { return nil }
        return id
    }

    /// One row per job, in the order the jobs first appear.
    static func rows(_ calls: [JobPollCall]) -> [JobPollRow] {
        var order: [String] = []
        var grouped: [String: [JobPollCall]] = [:]
        for (index, call) in calls.enumerated() {
            let report = call.finished ? JobPollReport.parse(call.output) : nil
            let key = report?.jobID ?? inputJobID(call.input) ?? "poll-\(index)-\(call.callID)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(call)
        }
        return order.map { key in
            let polls = grouped[key] ?? []
            let reports = polls.map { $0.finished ? JobPollReport.parse($0.output) : nil }
            let latest = polls.last
            let latestReport = reports.last ?? nil
            let outcome: JobPollReport.Outcome
            if let latestReport {
                outcome = latestReport.outcome
            } else if let latest, latest.finished, latest.isError {
                outcome = .failed
            } else {
                outcome = .running
            }
            return JobPollRow(
                id: key,
                jobID: key.hasPrefix("jb-") ? key : nil,
                outcome: outcome,
                exitCode: latestReport?.exitCode,
                command: reports.compactMap { $0?.command }.last,
                output: reports.compactMap { $0?.output }.last,
                pollCount: polls.count,
                inFlight: latest.map { !$0.finished } ?? false
            )
        }
    }
}

// MARK: - Reading the cards' values

/// The lenient readers every Pi card shares.
enum PiCardValue {
    /// A string with something in it.
    static func text(_ value: AnyJSON?) -> String? {
        guard let s = value?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// A finite, non-negative whole number.
    static func count(_ value: AnyJSON?) -> Int? {
        guard let n = value?.double, n.isFinite, n >= 0, n < 9e15 else { return nil }
        return Int(n)
    }

    /// A finite whole number (an exit code can be negative).
    static func signedCount(_ value: AnyJSON?) -> Int? {
        guard let n = value?.double, n.isFinite, abs(n) < 9e15 else { return nil }
        return Int(n)
    }

    static func runStatus(_ value: AnyJSON?) -> SubagentRunStatus? {
        value?.string.flatMap(SubagentRunStatus.init(rawValue:))
    }

    static func notes(_ value: AnyJSON?) -> [ModelNote] {
        (value?.array ?? []).compactMap { item in
            guard let body = text(item["text"]) else { return nil }
            return ModelNote(kind: text(item["kind"]) ?? "notice", text: body)
        }
    }

    /// `7921` → `7.9K`: token counts in a row's compact meta line.
    static func compactCount(_ value: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            if v >= 100 { return "\(Int(v.rounded()))\(unit)" }
            let tenths = (v * 10).rounded() / 10
            return tenths == tenths.rounded()
                ? "\(Int(tenths))\(unit)" : String(format: "%.1f", tenths) + unit
        }
        if value < 1000 { return String(value) }
        if value < 1_000_000 { return short(Double(value) / 1000, "K") }
        return short(Double(value) / 1_000_000, "M")
    }

    /// The first non-blank line of a block of text.
    static func firstLine(_ value: String) -> String {
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
