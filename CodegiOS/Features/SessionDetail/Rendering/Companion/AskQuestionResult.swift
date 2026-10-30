import Foundation

// Pure parsing for the historical (read-only) `ask_user_question` record in the
// transcript, ported from the web client's `ask-question.ts`. The tool input is
// the agent's raw `{ questions: [...] }`; the output is the companion's
// structured `{ answers, declined }` envelope (with a human-text fallback for
// hosts that persist `content` instead of `structuredContent`).

/// One question's answer as persisted: the user's raw picks (each entry is one
/// offered option label or a free-text "Other" answer). Partition with
/// `matchSelections`.
struct AskAnswer {
    let header: String
    let question: String
    let selected: [String]
}

struct AskOutcome {
    let declined: Bool
    let answers: [AskAnswer]
}

/// Where an ask's in-stream record stands, from what the transcript holds.
/// Mirrors codeg web's `AskQuestionRecordState` (`ask-question.ts`).
enum AskRecordState: Equatable {
    /// No result yet and the turn is still running: the pinned card is (or is
    /// about to be) waiting for an answer.
    case inFlight
    /// A result came back (an answer, or the user dismissed it).
    case answered
    /// The call ended without one: the turn was cancelled, the agent's process
    /// went away (a codeg restart, a crash), or the agent gave up on the call.
    /// codeg keeps a question open until it is answered, so it can no longer be.
    case expired
    /// The call was rejected before anyone saw it (malformed arguments), so it
    /// never was a question that could expire.
    case error
}

enum AskQuestionParse {

    /// Classify a call's record. `errorText` is an error result's text, `answered`
    /// says a result envelope parsed out of `output`, and `running` that the call
    /// is still live in a running turn. Mirrors web `askQuestionRecordState`.
    static func recordState(output: String?, errorText: String?, answered: Bool, running: Bool) -> AskRecordState {
        let error = (errorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty {
            return error.range(of: validationError, options: [.regularExpression, .caseInsensitive]) != nil
                ? .error : .expired
        }
        if answered { return .answered }
        if running { return .inFlight }
        // A result that didn't parse is still a result: keep showing what it holds.
        let hasOutput = !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasOutput ? .answered : .expired
    }

    /// The record state of an `ask_user_question` call. An error result's text
    /// rides in `output` with `isError` set. A call with no result is in flight
    /// only while the live turn holding it runs: a persisted call's turn has ended.
    static func recordState(of vm: ToolCallVM) -> AskRecordState {
        let failed = vm.isError || vm.state == .error
        let output = failed ? nil : vm.output
        let running = (vm.state == .running || vm.state == .inputStreaming) && vm.inRunningTurn
        return recordState(output: output, errorText: failed ? vm.output : nil,
                           answered: parseOutcome(output) != nil, running: running)
    }

    /// codeg-mcp's argument validation (`parse_questions`, a -32602 reply).
    private static let validationError = #"ask_user_question (requires|supports)|questions\[\d+\]|-32602"#

    /// The question set, shaped as `QuestionSpec` (synthetic ids: the persisted
    /// input carries none). Tolerant of partial input — returns `[]` rather than
    /// throwing so callers fall back gracefully.
    static func parseInput(_ input: String?) -> [QuestionSpec] {
        guard let obj = CompanionJSON.object(from: input), let questions = obj["questions"] as? [Any] else {
            return []
        }
        var out: [QuestionSpec] = []
        for (i, item) in questions.enumerated() {
            guard let q = item as? [String: Any] else { continue }
            let options = parseOptions(q["options"])
            let question = (q["question"] as? String) ?? ""
            if question.isEmpty && options.isEmpty { continue }      // empty noise
            let multi = (CompanionJSON.bool(q["multiSelect"]) == true) || (CompanionJSON.bool(q["multi_select"]) == true)
            let secret = (CompanionJSON.bool(q["isSecret"]) == true) || (CompanionJSON.bool(q["is_secret"]) == true)
            out.append(QuestionSpec(id: "q\(i)", question: question,
                                    header: (q["header"] as? String) ?? "",
                                    multiSelect: multi, options: options, isSecret: secret))
        }
        return out
    }

    /// Reconstruct the answered / declined outcome from the persisted result.
    /// Structured `{ answers, declined }` envelope first (top-level or under
    /// `structuredContent`), then the companion's human-readable text. Returns
    /// nil when there's no output yet (call still in flight).
    static func parseOutcome(_ output: String?) -> AskOutcome? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if let fromJSON = parseOutcomeJSON(output) { return fromJSON }

        if output.range(of: #"\bdismissed the question"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return AskOutcome(declined: true, answers: [])
        }

        // Fallback text shape:
        //   "The user answered your question(s):\n1. [Header] Question\n   → a, b\n…"
        // A header line pushes an answer (selected empty); the following "→" line
        // fills its selection (split on ", ", lossy for a label with a comma — the
        // structured envelope keeps such labels intact).
        var answers: [AskAnswer] = []
        var hasCurrent = false
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            if let m = Rx.capture(line, #"^\s*\d+\.\s*\[([^\]]*)\]\s*(.*)$"#, groups: 2) {
                answers.append(AskAnswer(header: m[0].trimmingCharacters(in: .whitespaces),
                                         question: m[1].trimmingCharacters(in: .whitespaces),
                                         selected: []))
                hasCurrent = true
                continue
            }
            if hasCurrent, let m = Rx.capture(line, #"^\s*→\s*(.*)$"#, groups: 1) {
                let joined = m[0].trimmingCharacters(in: .whitespaces)
                let selected = (!joined.isEmpty && joined != noSelection) ? joined.components(separatedBy: ", ") : []
                let last = answers.count - 1
                answers[last] = AskAnswer(header: answers[last].header, question: answers[last].question, selected: selected)
                hasCurrent = false
            }
        }
        return AskOutcome(declined: false, answers: answers)
    }

    /// What an answered view shows in place of a secret question's typed
    /// answer.
    static let hiddenAnswer = "••••••"

    /// The picks the answered capsule lists, in order. A secret question's
    /// typed answer is hidden (its offered options picked show as they
    /// are); so is that of an answer that can't be told apart from a secret
    /// question's.
    static func shownPicks(_ outcome: AskOutcome?, questions: [QuestionSpec]) -> [String] {
        let answers = outcome?.answers ?? []
        guard questions.contains(where: \.isSecret) else {
            return answers.flatMap(\.selected).filter { !$0.isEmpty }
        }
        return answers.flatMap { answer -> [String] in
            let values = answer.selected.filter { !$0.isEmpty }
            let question = questions.first { $0.header == answer.header && $0.question == answer.question }
                ?? questions.first { !answer.question.isEmpty && $0.question == answer.question }
            if let question, !question.isSecret { return values }
            let labels = (question.map { [$0] } ?? questions).flatMap(\.options).map(\.label)
            return hidingTyped(values, optionLabels: labels)
        }
    }

    /// Match each question's persisted answer (by header+question signature)
    /// to a pre-filled selection for the read-only card. A secret's typed
    /// answer is never put in the card, only that there was one.
    static func answeredSelections(questions: [QuestionSpec], outcome: AskOutcome?) -> [String: AskQuestionSelection] {
        guard let outcome, !outcome.declined else { return [:] }
        let sep = "\u{1f}"   // unit separator — never in agent text
        var bySig: [String: [String]] = [:]
        for a in outcome.answers { bySig[a.header + sep + a.question] = a.selected }
        var out: [String: AskQuestionSelection] = [:]
        for q in questions {
            let values = bySig[q.header + sep + q.question] ?? []
            let matched = matchSelections(values: values, optionLabels: q.options.map { $0.label })
            let other = q.isSecret && !matched.other.isEmpty ? hiddenAnswer : matched.other.joined(separator: ", ")
            out[q.id] = AskQuestionSelection(chosen: matched.selected, otherText: other)
        }
        return out
    }

    /// A secret question's picks: the offered options as they are, anything
    /// typed hidden.
    static func hidingTyped(_ values: [String], optionLabels: [String]) -> [String] {
        let matched = matchSelections(values: values, optionLabels: optionLabels)
        return matched.selected + (matched.other.isEmpty ? [] : [hiddenAnswer])
    }

    /// Partition raw picks into chosen offered-option labels (`selected`) and
    /// free-text "Other" answers (`other`), order-preserving.
    static func matchSelections(values: [String], optionLabels: [String]) -> (selected: [String], other: [String]) {
        let labels = Set(optionLabels.filter { !$0.isEmpty })
        var selected: [String] = []
        var other: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == noSelection { continue }
            if labels.contains(value) { selected.append(value) } else { other.append(value) }
        }
        return (selected, other)
    }

    /// Strip a trailing " (Recommended)" so it can render as a badge while the
    /// value keeps the agent's original label.
    static func splitRecommended(_ label: String) -> (text: String, recommended: Bool) {
        if let m = Rx.capture(label, #"^(.*?)\s*\(recommended\)\s*$"#, groups: 1, caseInsensitive: true) {
            let text = m[0].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return (text, true) }
        }
        return (label, false)
    }

    // MARK: helpers

    /// The companion's marker for an answered-but-empty selection (English, not localized).
    private static let noSelection = "(no selection)"

    private static func parseOptions(_ raw: Any?) -> [QuestionOption] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let o = item as? [String: Any], let label = o["label"] as? String, !label.isEmpty else { return nil }
            return QuestionOption(label: label, description: (o["description"] as? String) ?? "")
        }
    }

    private static func parseOutcomeJSON(_ output: String) -> AskOutcome? {
        guard let top = ToolJSONFormat.parseObject(output) else { return nil }
        // Resolve an answer envelope from a record: the record itself when it
        // carries `answers`/`declined`, otherwise its `structuredContent`.
        func envelope(_ r: [String: Any]?) -> [String: Any]? {
            guard let r else { return nil }
            if (r["answers"] as? [Any]) != nil || CompanionJSON.bool(r["declined"]) != nil { return r }
            return r["structuredContent"] as? [String: Any]
        }
        // Prefer the bare top-level shape (Claude / the history parser) first, so a
        // valid top-level envelope is never shadowed by an unrelated `result` key.
        // codex's live ACP path wraps the MCP result as `{result, error}`, where
        // `result` is the CallToolResult — sometimes tagged again under an `Ok`
        // serde variant — so fall through those layers when the top level yields
        // nothing. Mirrors the web `ask-question.ts::parseOutcomeJson`.
        let result = top["result"] as? [String: Any]
        let resultOk = result.flatMap { ($0["Ok"] as? [String: Any]) ?? ($0["ok"] as? [String: Any]) }
        guard let env = envelope(top) ?? envelope(result) ?? envelope(resultOk) else { return nil }
        let hasAnswers = (env["answers"] as? [Any]) != nil
        let declined = CompanionJSON.bool(env["declined"])
        if !hasAnswers && declined == nil { return nil }
        if declined == true { return AskOutcome(declined: true, answers: []) }
        return AskOutcome(declined: false, answers: parseAnswers(env["answers"]))
    }

    private static func parseAnswers(_ raw: Any?) -> [AskAnswer] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { item in
            guard let o = item as? [String: Any] else { return nil }
            let selected = (o["selected"] as? [Any])?.compactMap { $0 as? String } ?? []
            return AskAnswer(header: (o["header"] as? String) ?? "",
                             question: (o["question"] as? String) ?? "",
                             selected: selected)
        }
    }
}
