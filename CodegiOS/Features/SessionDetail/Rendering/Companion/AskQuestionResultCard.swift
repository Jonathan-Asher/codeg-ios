import SwiftUI

// Read-only, in-stream rendering of an `ask_user_question` tool call (historical
// transcript + the in-flight marker). Mirrors web `ask-question-result-card.tsx`:
// the answered / declined record collapses into a capsule summarizing the picks,
// expanding to the live `AskQuestionCard` in its read-only mode so the Q&A layout
// matches exactly. Error / in-flight / expired states fall back to a compact
// header card.

/// Pre-filled selection for a read-only `AskQuestionCard` question: the chosen
/// option labels plus any free-text "Other" answer.
struct AskQuestionSelection: Equatable {
    var chosen: [String]
    var otherText: String
}

struct AskQuestionResultCard: View {
    let vm: ToolCallVM
    @State private var expanded = false

    var body: some View {
        let questions = AskQuestionParse.parseInput(vm.input)
        let record = AskQuestionParse.recordState(of: vm)
        let reason = (vm.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch record {
        case .error:
            shell(subtitle: nil, record: record) {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .inFlight:
            shell(subtitle: "Waiting for your answer…", record: record) {
                if !questions.isEmpty {
                    chips(questions.map { $0.header.isEmpty ? $0.question : $0.header })
                }
            }
        case .expired:
            // The call ended without an answer (a cancelled turn, the agent's
            // process gone, the agent gave up): say so, rather than a card that
            // still looks like it waits or reads as answered with no selection.
            shell(subtitle: "This question expired", record: record) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The agent stopped waiting before it was answered.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !questions.isEmpty {
                        chips(questions.map { $0.header.isEmpty ? $0.question : $0.header })
                    }
                    // Why the call ended, when its error result says.
                    if vm.isError || vm.state == .error, !reason.isEmpty {
                        Text(verbatim: reason)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                }
            }
        case .answered:
            let outcome = AskQuestionParse.parseOutcome(vm.output)
            if questions.isEmpty {
                answersOnly(outcome)
            } else {
                answered(questions: questions, outcome: outcome)
            }
        }
    }

    // MARK: Answered / declined

    private func answered(questions: [QuestionSpec], outcome: AskOutcome?) -> some View {
        let declined = outcome?.declined ?? false
        // A secret question's typed answer never shows.
        let picks = AskQuestionParse.shownPicks(outcome, questions: questions)
        let summary = declined
            ? String(localized: "Declined")
            : (picks.isEmpty ? String(localized: "No selection") : picks.joined(separator: ", "))

        return VStack(alignment: .leading, spacing: 8) {
            capsule(summary: summary)
            if expanded {
                AskQuestionCard(
                    pending: PendingQuestion(questionId: "result", questions: questions),
                    onAnswer: { _ in false },
                    readOnly: true,
                    initialSelections: selections(questions: questions, outcome: outcome),
                    titleOverride: "Question",
                    subtitleOverride: declined ? "Declined" : nil
                )
                // The card seeds its selection @State in `init` only; force a fresh
                // identity (and re-seed) if the answered content changes under a
                // reused node (e.g. the live→persisted handoff at the same tool id).
                .id("ask-\(vm.id)-\(declined ? "declined" : picks.joined(separator: "\u{1f}"))")
            }
        }
    }

    private func capsule(summary: String) -> some View {
        Button {
            withAnimation(Theme.Motion.expand) { expanded.toggle() }
        } label: {
            // No leading question-bubble icon — the timeline gutter marker already
            // shows it for this node.
            HStack(spacing: 8) {
                (Text("Answered:").foregroundColor(Theme.textTertiary)
                    + Text(verbatim: " " + summary).foregroundColor(Theme.textSecondary))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Each question's persisted answer as the read-only card's selection.
    private func selections(questions: [QuestionSpec], outcome: AskOutcome?) -> [String: AskQuestionSelection] {
        AskQuestionParse.answeredSelections(questions: questions, outcome: outcome)
    }

    // MARK: Fallbacks (input didn't parse, error, in-flight)

    /// Input didn't parse (e.g. a truncated transcript) but the result did — show
    /// the answers as chips so the record isn't lost.
    @ViewBuilder private func answersOnly(_ outcome: AskOutcome?) -> some View {
        let answers = outcome?.answers ?? []
        if answers.isEmpty {
            EmptyView()
        } else {
            shell(subtitle: (outcome?.declined ?? false) ? "Declined" : nil, record: .answered) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(answers.enumerated()), id: \.offset) { _, a in
                        VStack(alignment: .leading, spacing: 4) {
                            if !a.question.isEmpty {
                                Text(verbatim: a.question)
                                    .font(.caption).foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            let labels = a.selected.filter { !$0.isEmpty }
                            if labels.isEmpty {
                                Text("No selection").font(.caption).foregroundStyle(Theme.textTertiary)
                            } else {
                                chips(labels)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shell<Content: View>(subtitle: LocalizedStringKey?, record: AskRecordState,
                                      @ViewBuilder content: () -> Content) -> some View {
        let border: Color = switch record {
        case .error: Theme.danger.opacity(0.4)
        case .expired: Theme.surfaceStroke
        case .inFlight, .answered: Theme.accent.opacity(0.3)
        }
        return VStack(alignment: .leading, spacing: 8) {
            // The gutter marker carries the question-bubble icon for this node, so
            // the card header leads with just the title.
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Question")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 4)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: border)
    }

    private func chips(_ labels: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(verbatim: label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }
}
