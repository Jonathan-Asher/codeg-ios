import SwiftUI

// MARK: - Fold state

/// Which request a pinned prompt card is folded for. Folding is the reader's
/// alone: the card goes down to a one-line bar so the transcript behind it
/// can be read, and nothing the agent waits on changes (the answer, Talk and
/// the "Waiting for you" list read the model, never the card). Keyed by the
/// request, so a new request always arrives unfolded, even into a card whose
/// view state carried over.
struct PromptFold: Equatable {
    private(set) var foldedID: String?

    init(folded id: String? = nil) {
        foldedID = id
    }

    func isFolded(_ id: String) -> Bool { foldedID == id }
    mutating func fold(_ id: String) { foldedID = id }
    mutating func unfold() { foldedID = nil }

    /// The transcript's own snappy curve.
    static let animation = Animation.snappy(duration: 0.28)

    /// A swipe that runs mostly up or down, far enough or flicked: down folds
    /// the card, up opens it again.
    static func isSwipe(_ translation: CGSize, predicted: CGSize, down: Bool) -> Bool {
        guard abs(translation.height) > abs(translation.width) else { return false }
        let sign: CGFloat = down ? 1 : -1
        return translation.height * sign >= 24 || predicted.height * sign >= 60
    }
}

// MARK: - What the bar says

/// What a folded card's bar says: the card's icon and title, one line of what
/// it asks, and, for a set of questions, how many are answered.
struct PromptFoldSummary {
    var icon: String
    var title: LocalizedStringKey
    var preview: String
    var answered = 0
    /// The questions in the set; the bar counts them from two up.
    var total = 0
    /// What VoiceOver calls the two controls ("Hide question", "Show question").
    var hideLabel: LocalizedStringKey
    var showLabel: LocalizedStringKey

    /// The longest preview kept; the bar truncates it to its one line.
    static let previewLimit = 160

    /// Text as one line for the bar: its lines joined, runs of white space as
    /// one, and inline Markdown (bold, code, links) as its plain words.
    static func oneLine(_ text: String) -> String {
        let plain = text
            .replacingOccurrences(of: #"\[([^\]\n]+)\]\([^)\n]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        let line = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(line.prefix(previewLimit))
    }

    /// A plan's first line worth reading, as one line: past blank lines, rules
    /// and code blocks, without the heading, quote or list marker that starts it.
    static func firstLine(ofMarkdown markdown: String) -> String? {
        let marker = #"^(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,3}[.)]\s+)"#
        var inCode = false
        for raw in markdown.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode || line.allSatisfy({ "-*_= ".contains($0) }) { continue }
            while let range = line.range(of: marker, options: .regularExpression) {
                line.removeSubrange(range)
            }
            let text = oneLine(line)
            if !text.isEmpty { return text }
        }
        return nil
    }
}

// MARK: - The fold

/// A pinned prompt card (permission, question, plan) that folds. The chevron
/// at the right of its header, or a swipe down on the header, folds it to a
/// slim bar in the same place, so the transcript behind it can be read; a tap
/// on the bar, or a swipe up, opens it again. The card stays in the hierarchy
/// while folded, hidden and out of reach, so the options chosen, the text
/// typed and a submit under way are all still there when it opens. A card
/// replayed in the transcript (read-only) passes `foldable: false` and renders
/// as it always did.
struct PromptCardFold<Header: View, Content: View>: View {
    /// The request the card answers: a new one arrives unfolded.
    let id: String
    let summary: PromptFoldSummary
    let foldable: Bool
    /// Drives the fold from outside (tests and screenshots); the card keeps
    /// its own otherwise.
    let fold: Binding<PromptFold>?
    /// The card lets go of a focused text field as it folds.
    let willFold: () -> Void
    let header: Header
    let content: Content

    @State private var ownFold = PromptFold()
    @AccessibilityFocusState private var voiceOverFocus: Control?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Control: Hashable { case hide, show }

    init(id: String, summary: PromptFoldSummary, foldable: Bool = true,
         fold: Binding<PromptFold>? = nil, willFold: @escaping () -> Void = {},
         @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.id = id
        self.summary = summary
        self.foldable = foldable
        self.fold = fold
        self.willFold = willFold
        self.header = header()
        self.content = content()
    }

    private var state: Binding<PromptFold> { fold ?? $ownFold }
    private var folded: Bool { foldable && state.wrappedValue.isFolded(id) }

    var body: some View {
        if foldable {
            foldingCard
        } else {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
            }
            .padding(14)
        }
    }

    private var foldingCard: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 4) {
                    header
                    hideButton
                }
                // The whole header takes the swipe; the scrolling body below
                // it keeps its own.
                .contentShape(Rectangle())
                .simultaneousGesture(swipe(down: true))
                content
            }
            .padding(14)
            // Folded, all of it stays (what was chosen and typed, a submit
            // under way) at no height, hidden and out of reach.
            .frame(height: folded ? 0 : nil, alignment: .top)
            .opacity(folded ? 0 : 1)
            .disabled(folded)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)

            if folded {
                bar
                    .transition(.opacity)
            }
        }
        // While the card shrinks or grows, what it holds stays inside it.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: folded)
        .onChange(of: folded) { _, now in
            // However it folded: a focused text field of the card lets go of
            // the keyboard (a hidden one must not keep it up), and VoiceOver
            // moves to the control that brings the card back.
            if now { willFold() }
            voiceOverFocus = now ? .show : .hide
        }
    }

    private var hideButton: some View {
        Button { setFolded(true) } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A 44 pt target that reaches into the card's padding instead of
        // making the header taller; the chevron lines up with the bar's.
        .padding(EdgeInsets(top: -12, leading: -8, bottom: -12, trailing: -14))
        .accessibilityLabel(Text(summary.hideLabel))
        .accessibilityFocused($voiceOverFocus, equals: .hide)
    }

    /// The folded card: one line, all of it a button.
    private var bar: some View {
        Button { setFolded(false) } label: {
            HStack(spacing: 8) {
                Image(systemName: summary.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(summary.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Text(verbatim: summary.preview)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if summary.total > 1 {
                    Text(verbatim: "\(summary.answered)/\(summary.total)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(swipe(down: false))
        .accessibilityLabel(Text(summary.title))
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: Text(summary.showLabel)) { setFolded(false) }
        .accessibilityFocused($voiceOverFocus, equals: .show)
    }

    private var accessibilityValue: Text {
        guard summary.total > 1 else { return Text(verbatim: summary.preview) }
        return Text("\(summary.preview), \(summary.answered) of \(summary.total) answered")
    }

    private func swipe(down: Bool) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard PromptFold.isSwipe(value.translation, predicted: value.predictedEndTranslation,
                                         down: down) else { return }
                setFolded(down)
            }
    }

    private func setFolded(_ value: Bool) {
        guard value != folded else { return }
        // The keyboard goes before the card does.
        if value { willFold() }
        withAnimation(reduceMotion ? nil : PromptFold.animation) {
            if value {
                state.wrappedValue.fold(id)
            } else {
                state.wrappedValue.unfold()
            }
        }
    }
}
