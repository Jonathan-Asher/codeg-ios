import SwiftUI

/// Inline Markdown, parsed, with the direction its own source text reads in
/// (`TextDirection.detect`): `nil` when it has no letters (a number, a code
/// span), so it inherits its block's.
struct MarkdownInline {
    let text: AttributedString
    let direction: LayoutDirection?
}

/// A parsed block of Markdown. Inline spans (bold, italic, code, links) are
/// pre-parsed into `AttributedString` at parse time so the whole block list can
/// be cached per source string — the recycling `List` then re-displays a turn
/// for free. Fenced code keeps its raw text (rendered by `CodeBlockView`).
///
/// Each block also carries the direction of its own text, decided at parse
/// time from the Markdown source, so a Hebrew paragraph under an English one
/// lays out right to left on its own.
enum MarkdownBlock {
    case paragraph(MarkdownInline)
    case heading(level: Int, MarkdownInline)
    /// `direction` is the whole list's, from all its items' text.
    case bulletList([MarkdownInline], direction: LayoutDirection?)
    case numberedList([(marker: String, content: MarkdownInline)], direction: LayoutDirection?)
    case quote(MarkdownInline)
    case code(language: String?, code: String)
    case rule
    /// `direction` is the whole table's, from all its cells' text.
    case table(header: [MarkdownInline], rows: [[MarkdownInline]], direction: LayoutDirection?)

    /// The direction the block lays out in. A list's or a table's sets the
    /// side its markers sit on and the order of its columns; an item or a cell
    /// with letters of its own then follows its own text. Code is always left
    /// to right; a rule has no direction.
    var direction: LayoutDirection? {
        switch self {
        case .paragraph(let inline), .heading(_, let inline), .quote(let inline):
            return inline.direction
        case .bulletList(_, let direction), .numberedList(_, let direction), .table(_, _, let direction):
            return direction
        case .code:
            return .leftToRight
        case .rule:
            return nil
        }
    }
}

/// Block-level Markdown for finalized assistant text. Unlike `MarkdownText`
/// (Apple's *inline-only* parser, which leaves ``` fences as literal backticks),
/// this splits the source into real blocks — paragraphs, headings, lists,
/// quotes, fenced code, rules, GFM tables — so a coding agent's replies render
/// like a chat client instead of a wall of text. Inline content inside each
/// block still goes through `MarkdownText.attributed(from:)` for bold/italic/
/// inline-code/links.
///
/// Streaming text uses this too, via `LiveTextNode` with `streaming: true`, which
/// parses directly and bypasses the block cache (the partial strings would only
/// churn it); the finalized turn re-renders once through the cached path.
struct MarkdownContent: View {
    let raw: String
    /// While a reply is streaming, parse directly (skip the block LRU): the text
    /// changes ~20×/sec, so caching every partial string would only churn (and
    /// evict useful finalized entries). The finalized turn re-renders once through
    /// the cached path.
    var streaming: Bool = false

    @Environment(\.selectText) private var selectText

    /// Long press: Copy and Select Text, where the screen offers the sheet,
    /// once the text has stopped streaming. Otherwise each text keeps its own
    /// Copy.
    private var offersMenu: Bool { selectText != nil && !streaming }

    private var blocks: [MarkdownBlock] {
        streaming ? MarkdownContent.parseBlocks(raw) : MarkdownContent.blocks(for: raw)
    }

    var body: some View {
        let parsed = blocks
        let lastIndex = parsed.count - 1
        VStack(alignment: .leading, spacing: Theme.Typography.blockSpacing) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { idx, block in
                // Streaming "typing" caret rides the trailing paragraph only —
                // a code/list/table tail is self-evidently in progress already.
                view(for: block, caret: streaming && idx == lastIndex && Self.isParagraph(block))
                    .blockDirection(block.direction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectTextMenu(.markdown(raw), enabled: offersMenu)
    }

    private static func isParagraph(_ block: MarkdownBlock) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, caret: Bool = false) -> some View {
        switch block {
        // Every block is laid out in its own direction (applied in `body`), so
        // `.leading` here is the right edge of a right-to-left block.
        case .paragraph(let a):
            if caret {
                CaretParagraph(base: a.text)
            } else {
                Text(a.text)
                    .font(Theme.Typography.messageBody)
                    .lineSpacing(Theme.Typography.messageLineSpacing)
                    .foregroundStyle(Theme.textPrimary)
                    .modifier(SelectableText(enabled: !offersMenu))
                    .tint(Theme.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .heading(let level, let a):
            Text(a.text)
                .font(Theme.Typography.heading(level))
                .lineSpacing(Theme.Typography.headingLineSpacing)
                .fontWeight(Theme.Typography.headingWeight(level))
                .foregroundStyle(Theme.textPrimary)
                .modifier(SelectableText(enabled: !offersMenu))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

        case .bulletList(let items, _):
            VStack(alignment: .leading, spacing: Theme.Typography.listItemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", content: item)
                }
            }

        case .numberedList(let items, _):
            VStack(alignment: .leading, spacing: Theme.Typography.listItemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: item.marker, content: item.content)
                }
            }

        case .quote(let item):
            // The bar sits on the quote's leading side: the right of a
            // right-to-left quote.
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.5)).frame(width: 3)
                Text(item.text)
                    .font(Theme.Typography.quote)
                    .lineSpacing(Theme.Typography.quoteLineSpacing)
                    .foregroundStyle(Theme.textSecondary)
                    .italic()
                    .modifier(SelectableText(enabled: !offersMenu))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .code(let lang, let code):
            CodeBlockView(code: code, language: lang)

        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.vertical, 2)

        case .table(let header, let rows, _):
            MarkdownTable(header: header, rows: rows)
        }
    }

    /// One list item. The row (marker and text) follows the item's own
    /// direction, or the list's when the item has no letters, so the marker
    /// sits on the side the item's text starts from.
    private func listRow(marker: String, content: MarkdownInline) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(Theme.Typography.messageBody)
                .foregroundStyle(Theme.textTertiary)
                // Marker hugs the block's leading edge (no leading indent) so
                // lists line up with paragraphs/headings; the small min-width
                // keeps multi-line item text aligned past the marker.
                .frame(minWidth: 14, alignment: .leading)
            Text(content.text)
                .font(Theme.Typography.messageBody)
                .lineSpacing(Theme.Typography.messageLineSpacing)
                .foregroundStyle(Theme.textPrimary)
                .modifier(SelectableText(enabled: !offersMenu))
                .tint(Theme.accent)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .blockDirection(content.direction)
    }
}

// MARK: - Streaming caret

/// The trailing paragraph of a still-streaming reply, with a blinking "typing"
/// caret glued to the end of the text (so it wraps with the last word, like
/// ChatGPT). The caret glyph is *always* in the layout (constant width — only
/// its color alpha toggles), so the blink never re-measures the line box.
///
/// The blink is a discrete timer toggle with NO animation — deliberately. An
/// *ambient* `withAnimation(.repeatForever)` would make every concurrent layout
/// change animate too, so each streamed token would interpolate the caret's
/// x-position across the line (it visibly flew right). A hard terminal-style
/// blink keeps the caret pinned to the text end at every frame. `textSelection`
/// is omitted: streaming text isn't selected mid-flight.
private struct CaretParagraph: View {
    let base: AttributedString
    @State private var visible = true

    private var caretRun: AttributedString {
        var s = AttributedString(" ▌")
        s.foregroundColor = visible ? Theme.accent : Theme.accent.opacity(0)
        return s
    }

    var body: some View {
        (Text(base) + Text(caretRun))
            .font(Theme.Typography.messageBody)
            .lineSpacing(Theme.Typography.messageLineSpacing)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(530))
                    visible.toggle()
                }
            }
    }
}

// MARK: - Table fallback

/// A minimal GFM table: fixed-width columns in a horizontally scrollable grid.
/// Not a full layout engine — just enough that a table reads as a table.
///
/// Its columns run in the table's direction; each cell's text aligns by its
/// own.
private struct MarkdownTable: View {
    let header: [MarkdownInline]
    let rows: [[MarkdownInline]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, isHeader: true)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, cells in
                    row(cells, isHeader: false)
                    if idx < rows.count - 1 {
                        Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 0.5)
                    }
                }
            }
            .background(Color(light: .black.opacity(0.05), dark: .black.opacity(0.18)), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
        }
    }

    private func row(_ cells: [MarkdownInline], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.text)
                    .font(.caption)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .foregroundStyle(isHeader ? Theme.textPrimary : Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(width: 130, alignment: .leading)
                    .blockDirection(cell.direction)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Parsing + cache

extension MarkdownContent {
    /// Parse into blocks, memoized per source string (block parsing is heavier
    /// than inline; the cache keeps recycled `List` rows free). Main-thread-only,
    /// like `MarkdownText`'s cache.
    static func blocks(for raw: String) -> [MarkdownBlock] {
        if let hit = cache[raw] { return hit }
        let parsed = parseBlocks(raw)
        cache[raw] = parsed
        order.append(raw)
        if order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return parsed
    }

    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []
    private static let limit = 300

    static func parseBlocks(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        func inline(_ s: String) -> MarkdownInline {
            MarkdownInline(text: MarkdownText.attributed(from: s), direction: TextDirection.detect(s))
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if let fence = fenceMarker(trimmed) {
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var bodyLines: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence), t.allSatisfy({ $0 == fence.first }) { i += 1; break }
                    bodyLines.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: bodyLines.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { i += 1; continue }

            if let (level, rest) = heading(trimmed) {
                blocks.append(.heading(level: level, inline(rest))); i += 1; continue
            }

            if isRule(trimmed) {
                blocks.append(.rule); i += 1; continue
            }

            // Blockquote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(inline(quoted.joined(separator: "\n"))))
                continue
            }

            // GFM table (header row + a `|---|` separator).
            if i + 1 < lines.count, line.contains("|"), isTableSeparator(lines[i + 1]) {
                let header = tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[i])); i += 1
                }
                blocks.append(.table(
                    header: header.map(inline), rows: rows.map { $0.map(inline) },
                    direction: TextDirection.detect((header + rows.joined()).joined(separator: "\n"))))
                continue
            }

            // Bulleted list.
            if bulletContent(trimmed) != nil {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let c = bulletContent(t) else { break }
                    items.append(c); i += 1
                }
                blocks.append(.bulletList(
                    items.map(inline), direction: TextDirection.detect(items.joined(separator: "\n"))))
                continue
            }

            // Numbered list.
            if orderedContent(trimmed) != nil {
                var items: [(marker: String, content: MarkdownInline)] = []
                var sources: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let (m, c) = orderedContent(t) else { break }
                    items.append((marker: m, content: inline(c))); sources.append(c); i += 1
                }
                blocks.append(.numberedList(
                    items, direction: TextDirection.detect(sources.joined(separator: "\n"))))
                continue
            }

            // Paragraph: gather until a blank line or the start of another block.
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if fenceMarker(t) != nil { break }
                if heading(t) != nil { break }
                if isRule(t) { break }
                if t.hasPrefix(">") { break }
                if bulletContent(t) != nil { break }
                if orderedContent(t) != nil { break }
                if i + 1 < lines.count, l.contains("|"), isTableSeparator(lines[i + 1]) { break }
                para.append(l); i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(inline(para.joined(separator: "\n")))) }
        }
        return blocks
    }

    // MARK: line classifiers

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        var n = 0
        for ch in trimmed { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n) else { return nil }
        let rest = String(trimmed.dropFirst(n))
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (n, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let s = trimmed.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3 else { return false }
        return s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" }
    }

    private static func bulletContent(_ trimmed: String) -> String? {
        for p in ["- ", "* ", "+ "] where trimmed.hasPrefix(p) {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func orderedContent(_ trimmed: String) -> (String, String)? {
        var digits = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            digits.append(trimmed[idx]); idx = trimmed.index(after: idx)
        }
        guard !digits.isEmpty, idx < trimmed.endIndex else { return nil }
        let sep = trimmed[idx]
        guard sep == "." || sep == ")" else { return nil }
        let after = trimmed.index(after: idx)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        return (digits + ".", String(trimmed[trimmed.index(after: after)...]))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
