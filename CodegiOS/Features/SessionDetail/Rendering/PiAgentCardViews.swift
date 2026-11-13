import SwiftUI

// Pi's delegated work on the phone, as codeg web draws it (fork.234): a
// sub-agent run as one card with a row per child (`agent-tool-call.tsx`,
// `subagent-run-children.tsx`), a background job's state as a chip on the
// command that started it (`background-job-chip.tsx`) with its polls merged
// into one card (`background-task-card.tsx`), the start of a run Pi began by
// itself as a divider (`agent-wake-divider.tsx`), and the text the model was
// given behind a toggle (`model-notes-toggle.tsx`). The cards read their state
// through ``LiveToolCards``, so a run keeps updating after the turn that
// launched it. Parsing lives in `PiAgentCards.swift`.

// MARK: - Environment

private struct LiveToolCardsKey: EnvironmentKey {
    static let defaultValue: LiveToolCards? = nil
}

/// A row of a run card asking to show a child's own session.
struct OpenSubagentSessionAction {
    let open: (SubagentSessionRef) -> Void
    func callAsFunction(_ ref: SubagentSessionRef) { open(ref) }
}

private struct OpenSubagentSessionKey: EnvironmentKey {
    static let defaultValue: OpenSubagentSessionAction? = nil
}

extension EnvironmentValues {
    /// The live connection's Pi run and job cards. Absent outside an open
    /// session (every call draws its own `meta`).
    var liveToolCards: LiveToolCards? {
        get { self[LiveToolCardsKey.self] }
        set { self[LiveToolCardsKey.self] = newValue }
    }

    /// Opens a sub-agent's own session. Absent: the rows open nothing.
    var openSubagentSession: OpenSubagentSessionAction? {
        get { self[OpenSubagentSessionKey.self] }
        set { self[OpenSubagentSessionKey.self] = newValue }
    }
}

/// A child session a run card's row opens.
struct SubagentSessionRef: Identifiable, Hashable {
    let sessionID: String
    /// The row's label (its workflow key or agent).
    let label: String
    let agent: String?
    /// The child is still working: its transcript keeps growing.
    let isRunning: Bool

    var id: String { sessionID }
}

// MARK: - Sub-agent run card

/// A `.task` call: the sub-agent run card when the call (or the live
/// connection) has one, the plain tool card otherwise.
struct SubagentRunToolCard: View {
    let vm: ToolCallVM
    @Environment(\.liveToolCards) private var liveToolCards

    var body: some View {
        let meta = liveToolCards?.meta(for: vm.id, own: vm.meta, key: .subagentRun) ?? vm.meta
        if let run = SubagentRun.parse(meta) {
            SubagentRunCard(vm: vm, run: run)
        } else {
            ToolCallCard(vm: vm)
        }
    }
}

/// One Pi sub-agent run: what ran and how it is going, one row per child
/// (status, current tool, its result or error, the questions it asked and the
/// answers it got), the run's own error and result, and what the model was
/// told. A row with a session opens it.
struct SubagentRunCard: View {
    let vm: ToolCallVM
    let run: SubagentRun

    @State private var errorOpen = false
    @State private var resultOpen: Bool
    private let notesOpen: Bool

    /// `resultOpen`, `notesOpen`: open from the start (screenshots).
    init(vm: ToolCallVM, run: SubagentRun, resultOpen: Bool = false, notesOpen: Bool = false) {
        self.vm = vm
        self.run = run
        self.notesOpen = notesOpen
        _resultOpen = State(initialValue: resultOpen)
    }

    /// The agent (or how it ran), and how many children a run of several has.
    private var title: Text {
        guard run.children.count > 1 else { return Text(verbatim: run.title) }
        return Text(verbatim: run.title + " · ") + Text("\(run.children.count) sub-agents")
    }

    /// The task, when the run had one (a workflow's script is no task).
    private var task: String? {
        run.task.map(PiCardValue.firstLine).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !run.children.isEmpty {
                SubagentChildRows(children: run.children)
            }
            outcome
            ModelNotesToggle(notes: run.notes, open: notesOpen)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .accessibilityIdentifier("subagent-run-card")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                title
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let duration = run.durationMs.flatMap(PiCardFormat.duration) {
                    Text(verbatim: duration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                SubagentRunBadge(status: run.status, isLive: run.isLive)
                    .fixedSize()
            }
            if let task {
                Text(verbatim: task)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blockDirection(TextDirection.detect(task))
            }
        }
    }

    /// The run's own error (first line, the rest on demand) and result.
    @ViewBuilder
    private var outcome: some View {
        if let error = run.error {
            let head = PiCardValue.firstLine(error)
            let more = error.trimmingCharacters(in: .whitespacesAndNewlines) != head
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: errorOpen ? error : head)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if more {
                    Button {
                        withAnimation(Theme.Motion.expand) { errorOpen.toggle() }
                    } label: {
                        (errorOpen ? Text("Less") : Text("More"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.danger.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        if let result = run.result {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(Theme.Motion.expand) { resultOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Result")
                            .font(.caption.weight(.semibold))
                        if !resultOpen {
                            Text(verbatim: PiCardValue.firstLine(result))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(resultOpen ? 90 : 0))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if resultOpen {
                    MarkdownContent(raw: result)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// A run's or a child's status as a small tinted capsule.
struct SubagentRunBadge: View {
    let status: SubagentRunStatus
    var isLive = true

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
        default:
            Image(systemName: SubagentStatusIcon.symbol(status, isLive: isLive))
                .font(.system(size: 9, weight: .bold))
        }
    }

    private var tint: Color { SubagentStatusIcon.tint(status, isLive: isLive) }

    private var label: LocalizedStringKey {
        switch status {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .running: return "Running"
        // Live: queued, not started. History: no outcome in the transcript.
        case .pending: return isLive ? "Starting" : "Result pending"
        }
    }
}

/// A run's or child's status glyph and tint.
enum SubagentStatusIcon {
    static func symbol(_ status: SubagentRunStatus?, isLive: Bool = true) -> String {
        switch status {
        case .completed?: return "checkmark.circle.fill"
        case .failed?: return "xmark.octagon.fill"
        case .paused?: return "pause.circle.fill"
        case .stopped?: return "nosign"
        case .running?: return "circle.dotted"
        case .pending?: return isLive ? "circle.dashed" : "clock"
        case nil: return "circle.dashed"
        }
    }

    static func tint(_ status: SubagentRunStatus?, isLive: Bool = true) -> Color {
        switch status {
        case .completed?: return DiffPalette.addText
        case .failed?: return Theme.danger
        case .paused?: return Theme.warning
        case .running?: return Theme.accent
        case .pending?: return isLive ? Theme.accent : Theme.textTertiary
        case .stopped?, nil: return Theme.textTertiary
        }
    }
}

// MARK: - Child rows

/// A run's children, one row each, in a bordered list.
struct SubagentChildRows: View {
    let children: [SubagentRunChild]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.key) { index, child in
                if index > 0 {
                    Divider().background(Theme.hairline)
                }
                SubagentChildRow(child: child)
            }
        }
        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
        .accessibilityIdentifier("subagent-run-children")
    }
}

/// One child: its status, label and facts (agent, current tool, turns,
/// tokens), the first line of its error or result, and its questions with
/// Pi's answers. A child with a session opens it on a tap.
struct SubagentChildRow: View {
    let child: SubagentRunChild
    @Environment(\.openSubagentSession) private var openSession

    /// Its agent (when the label isn't it), what it is doing while it works,
    /// its turns and its tokens.
    private var facts: Text? {
        var parts: [Text] = []
        if let agent = child.agent, agent != child.label { parts.append(Text(verbatim: agent)) }
        // Live: what a child still working is doing right now.
        if child.status == .running, let tool = child.currentTool { parts.append(Text(verbatim: tool)) }
        if let turns = child.turns { parts.append(Text("\(turns) turns")) }
        if let tokens = child.tokens { parts.append(Text("\(PiCardValue.compactCount(tokens)) tokens")) }
        guard var joined = parts.first else { return nil }
        for part in parts.dropFirst() { joined = joined + Text(verbatim: " · ") + part }
        return joined
    }

    private var headline: (text: String, isError: Bool)? {
        if let error = child.error { return (PiCardValue.firstLine(error), true) }
        if let result = child.result { return (PiCardValue.firstLine(result), false) }
        return nil
    }

    private var sessionRef: SubagentSessionRef? {
        guard let id = child.sessionId, openSession != nil else { return nil }
        return SubagentSessionRef(sessionID: id, label: child.label, agent: child.agent,
                                  isRunning: child.status?.isActive == true)
    }

    var body: some View {
        if let ref = sessionRef, let openSession {
            Button { openSession(ref) } label: { content(opens: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens this sub-agent’s session"))
        } else {
            content(opens: false)
        }
    }

    private func content(opens: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 14, height: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: child.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let facts {
                        facts
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if let headline {
                    Text(verbatim: headline.text)
                        .font(.caption)
                        .foregroundStyle(headline.isError ? Theme.danger : Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .blockDirection(TextDirection.detect(headline.text))
                }
                SubagentExchangesView(exchanges: child.exchanges, attention: child.attention)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusIcon: some View {
        if child.status == .running {
            ProgressView().controlSize(.mini).tint(Theme.accent)
        } else {
            Image(systemName: SubagentStatusIcon.symbol(child.status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SubagentStatusIcon.tint(child.status))
        }
    }
}

/// The questions a child asked and Pi's answers, as quoted lines, and the
/// questions still waiting.
struct SubagentExchangesView: View {
    let exchanges: [SubagentRunExchange]
    let attention: [String]

    var body: some View {
        if !exchanges.isEmpty || !attention.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(exchanges.enumerated()), id: \.offset) { _, exchange in
                    quoted(Text("Asked:"), PiCardValue.firstLine(exchange.question), muted: false)
                    if let answer = exchange.answer {
                        quoted(Text("Answer:"), PiCardValue.firstLine(answer), muted: false)
                    } else {
                        quoted(Text("Answer:"), nil, muted: true)
                    }
                }
                ForEach(Array(attention.enumerated()), id: \.offset) { _, question in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(verbatim: PiCardValue.firstLine(question))
                            .lineLimit(2)
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    /// `text` nil: no answer was recorded.
    private func quoted(_ label: Text, _ text: String?, muted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            label
                .fontWeight(.medium)
                .foregroundStyle(Theme.textTertiary)
            (text.map { Text(verbatim: $0) } ?? Text("no answer recorded"))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textSecondary)
                .italic(muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
    }
}

// MARK: - What the model saw

/// "What the model saw": the raw text a card stands in for — notices written
/// for the model (run ids, file paths, tool syntax) that the card shows as
/// structure. Verbatim, collapsed by default.
struct ModelNotesToggle: View {
    let notes: [ModelNote]
    var centered = false
    @State private var open: Bool

    /// `open`: open from the start (screenshots).
    init(notes: [ModelNote], centered: Bool = false, open: Bool = false) {
        self.notes = notes
        self.centered = centered
        _open = State(initialValue: open)
    }

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: centered ? HorizontalAlignment.center : HorizontalAlignment.leading, spacing: 8) {
                Button {
                    withAnimation(Theme.Motion.expand) { open.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("What the model saw")
                            .font(.caption)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("model-notes-toggle")
                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ModelNoteLabel.of(note.kind))
                                    .font(Theme.Typography.microLabel)
                                    .tracking(0.5)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Theme.textTertiary)
                                Text(verbatim: note.text)
                                    .font(.mono(11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                            .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: centered ? Alignment.center : Alignment.leading)
        }
    }
}

/// The label over one raw notice.
enum ModelNoteLabel {
    static func of(_ kind: String) -> LocalizedStringKey {
        switch kind {
        case "launch": return "Launch"
        case "question", "subagentQuestion": return "Question"
        case "child": return "Child settled"
        case "result", "subagentSettled": return "Run finished"
        case "attention", "subagentAttention": return "Alert"
        case "jobExit": return "Job exit"
        default: return "Notice"
        }
    }
}

// MARK: - Runs Pi started by itself

/// Where Pi started a run by itself: a slim divider between the reply before
/// it and the one it starts, so the second doesn't read as an answer to the
/// user, with the notices that woke it behind a toggle.
struct AgentWakeDivider: View {
    let wake: AgentWake

    private var label: Text {
        Text("Continued on its own") + Text(verbatim: " · ")
            + Self.reason(wake.triggers.first?.kind ?? .extension, more: wake.triggers.count - 1)
    }

    /// What woke Pi, and how many more notices came with it.
    static func reason(_ kind: AgentWakeKind, more: Int) -> Text {
        guard more > 0 else {
            switch kind {
            case .subagentQuestion: return Text("woken by a sub-agent’s question")
            case .subagentSettled: return Text("woken by a sub-agent finishing")
            case .subagentAttention: return Text("woken by a sub-agent alert")
            case .jobExit: return Text("woken by a background job ending")
            case .extension: return Text("woken by an extension’s message")
            }
        }
        switch kind {
        case .subagentQuestion: return Text("woken by a sub-agent’s question and \(more) more notices")
        case .subagentSettled: return Text("woken by a sub-agent finishing and \(more) more notices")
        case .subagentAttention: return Text("woken by a sub-agent alert and \(more) more notices")
        case .jobExit: return Text("woken by a background job ending and \(more) more notices")
        case .extension: return Text("woken by an extension’s message and \(more) more notices")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                hairline
                HStack(spacing: 5) {
                    Image(systemName: "bell")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    label
                        .font(Theme.Typography.metaLabel)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.textTertiary)
                .layoutPriority(1)
                hairline
            }
            ModelNotesToggle(notes: wake.notes, centered: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityIdentifier("agent-wake-divider")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .frame(minWidth: 16, maxWidth: .infinity)
    }
}

/// A notice Pi was given that no card claims (or another System note of a
/// Pi session): a small line, the whole text behind a toggle.
struct PiNoteView: View {
    let text: String
    @State private var open = false

    private var head: String { PiCardValue.firstLine(text) }
    private var hasMore: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != head }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasMore else { return }
                withAnimation(Theme.Motion.expand) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text(verbatim: head)
                        .lineLimit(open ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasMore {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .blockDirection(TextDirection.detect(head))
            if open {
                Text(verbatim: text)
                    .font(.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .hairlineBorder(Theme.Radius.sm, color: Theme.hairline)
                    .transition(.opacity)
            }
        }
        .accessibilityIdentifier("pi-note")
    }
}

// MARK: - Background jobs

/// How a background job is going, on the command that started it: Running,
/// then how it ended and how long it ran. A job whose end the transcript
/// never recorded says that instead of claiming it still runs.
struct BackgroundJobChip: View {
    let job: BackgroundJob

    /// How it is going, and how long it ran once it ended.
    private var label: Text {
        let base: Text
        switch job.state {
        case .running: base = Text("Running")
        case .completed: base = Text("Exit \(job.exitCode ?? 0)")
        case .failed: base = job.exitCode.map { Text("Failed · exit \($0)") } ?? Text("Failed")
        case .killed: base = job.killedBy.map { Text("Killed (\($0))") } ?? Text("Killed")
        case .unknown: base = Text("Ended")
        case .pending: base = Text("No exit recorded")
        }
        guard let duration = job.duration, job.state != .pending, job.state != .running else { return base }
        return base + Text(verbatim: " · \(duration)")
    }

    private var symbol: String {
        switch job.state {
        case .running: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .killed: return "nosign"
        case .unknown: return "circle.dashed"
        case .pending: return "terminal"
        }
    }

    private var tint: Color {
        switch job.state {
        case .running: return Theme.accent
        case .completed: return DiffPalette.addText
        case .failed: return Theme.danger
        case .killed, .unknown, .pending: return Theme.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if job.state == .running {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            } else {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            label
                .font(.caption2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityIdentifier("background-job-chip")
    }
}

/// A run of consecutive Pi job polls (`bgj_status` / `bgj_wait` /
/// `bgj_kill`): one row per job with its latest state and how many times it
/// was checked, opening to its last output.
struct JobPollGroupCard: View {
    let polls: [ToolCallVM]

    var body: some View {
        let rows = JobPolls.rows(polls.map(\.jobPollCall))
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().background(Theme.hairline)
                }
                JobPollRowView(row: row)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .accessibilityIdentifier("job-poll-group")
    }
}

private struct JobPollRowView: View {
    let row: JobPollRow
    @State private var expanded = false

    /// The job's command, else its id.
    private var title: Text {
        if let command = row.command {
            let line = PiCardValue.firstLine(command)
            return Text(verbatim: line.count > 80 ? String(line.prefix(80)) + "…" : line)
        }
        if let id = row.jobID { return Text("Job \(id)") }
        return Text("Background job")
    }

    private var job: BackgroundJob {
        let state: BackgroundJobState
        switch row.outcome {
        case .running: state = .running
        case .completed: state = .completed
        case .failed: state = .failed
        case .stopped: state = .killed
        }
        return BackgroundJob(id: row.jobID, state: state, exitCode: row.exitCode, killedBy: nil, duration: nil,
                             tail: nil, notice: nil, isLive: true)
    }

    private var hasOutput: Bool { row.output != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(row.outcome == .failed ? Theme.danger : Theme.textSecondary)
                    .frame(width: 16)
                title
                    .font(.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.pollCount > 1 {
                    Text(verbatim: "×\(row.pollCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                BackgroundJobChip(job: job)
                    .fixedSize()
                if hasOutput {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasOutput else { return }
                withAnimation(Theme.Motion.expand) { expanded.toggle() }
            }
            if expanded, let output = row.output {
                Divider().background(Theme.hairline)
                CodeBlockView(code: output, language: "console")
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Formatting

enum PiCardFormat {
    /// `durationMs` as a short label: `850ms`, `2.8s`, `29s`, `3m 52s`, `1h 12m`.
    static func duration(_ ms: Int) -> String? {
        guard ms > 0 else { return nil }
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return whole % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(whole % 60)s" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
