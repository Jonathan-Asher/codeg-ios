import SwiftUI

/// Renders a string as inline Markdown, gracefully degrading to plain text when
/// the string is not valid Markdown. Used for user bubbles and assistant text
/// blocks. Whitespace is preserved between paragraphs (`.inlineOnlyPreservingWhitespace`
/// keeps newlines that the default parser would otherwise collapse).
///
/// The text is laid out in its own direction: split into runs of lines that
/// read the same way (`TextDirection.lineRuns`), so a Hebrew message aligns
/// right with its punctuation where it belongs, and a Hebrew paragraph under
/// an English one keeps its own side. An English message is a single run and
/// renders as before.
struct MarkdownText: View {
    let raw: String
    var color: Color = Theme.textPrimary
    var font: Font = Theme.Typography.messageBody
    /// When true, render the raw string verbatim and skip Markdown parsing. Used
    /// for live-streaming text so each token delta doesn't re-parse the entire
    /// accumulated reply (O(n²) main-actor work on long replies); the turn
    /// re-renders once with full Markdown when it finalizes.
    var plain: Bool = false
    /// The text offers its own Copy on a long press. Off inside a card whose
    /// long press has a menu of its own (your message: Copy, Edit Message).
    var selectable: Bool = true

    var body: some View {
        // Live-streaming text (`plain`) renders verbatim in one direction and is
        // skipped by the cache — each token delta is a distinct string, so
        // caching would only churn. Finalized turns go through the cache so a
        // `List` row recycled back into view re-uses its parse instead of
        // re-running it.
        if plain {
            line(AttributedString(raw))
                .blockDirection(TextDirection.detect(raw))
        } else {
            let runs = Self.cachedRuns(raw)
            if runs.count == 1 {
                line(runs[0].text)
                    .blockDirection(runs[0].direction)
            } else {
                // The gap between two runs is the one between two lines of a
                // single text.
                VStack(alignment: .leading, spacing: Theme.Typography.messageLineSpacing) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        line(run.text)
                            .blockDirection(run.direction)
                    }
                }
            }
        }
    }

    /// One run of text. `.leading` is the right edge of a right-to-left run.
    private func line(_ text: AttributedString) -> some View {
        Text(text)
            .font(font)
            .lineSpacing(Theme.Typography.messageLineSpacing)
            .foregroundStyle(color)
            .modifier(SelectableText(enabled: selectable))
            .tint(Theme.accent)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parse Markdown into an `AttributedString`, falling back to a verbatim
    /// string when parsing fails. Newlines are preserved so streamed multi-line
    /// replies keep their shape.
    static func attributed(from raw: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }

    /// The text's runs of lines that share a direction, each parsed on its own.
    static func runs(from raw: String) -> [MarkdownInline] {
        TextDirection.lineRuns(raw).map {
            MarkdownInline(text: attributed(from: $0.text), direction: $0.direction)
        }
    }

    // MARK: - Parse cache

    /// Markdown parsing is the per-turn rendering cost that dominates a long
    /// transcript. With a recycling `List`, a row that scrolls off and back on
    /// would otherwise re-parse every time. This bounded, main-thread-only cache
    /// keeps each distinct string's parse around so re-display is free.
    ///
    /// Accessed exclusively from `body` (SwiftUI rendering is on the main
    /// thread), so a plain static store is safe without extra synchronization.
    private static var cache: [String: [MarkdownInline]] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 500

    private static func cachedRuns(_ raw: String) -> [MarkdownInline] {
        if let hit = cache[raw] { return hit }
        let parsed = runs(from: raw)
        cache[raw] = parsed
        cacheOrder.append(raw)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return parsed
    }
}

/// `.textSelection(.enabled)` when `enabled` (the two settings are different
/// types, so they can't be picked with a ternary).
private struct SelectableText: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
