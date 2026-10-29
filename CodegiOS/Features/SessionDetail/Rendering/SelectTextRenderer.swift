import SwiftUI
import UIKit

/// What Select Text shows (`SelectTextSheet`): a message, a code block or a
/// tool's output, rendered the way the transcript renders it.
enum SelectTextSource: Equatable {
    /// An agent's reply, its reasoning, a plan or a tool's Markdown output:
    /// block Markdown, as `MarkdownContent` draws it.
    case markdown(String)
    /// Your own message: inline Markdown in runs of lines that read the same
    /// way, as `MarkdownText` draws it.
    case message(String)
    /// A code block, a diff or a tool's output: monospaced, left to right.
    case code(String)

    /// The text as it came, which Copy puts on the pasteboard.
    var raw: String {
        switch self {
        case .markdown(let text), .message(let text), .code(let text): return text
        }
    }
}

/// Turns a `SelectTextSource` into the attributed string the Select Text
/// sheet's text view shows: the transcript's fonts, colours and spacing,
/// links as links, code in monospace, and every paragraph aligned to its own
/// direction (`TextDirection`), so a Hebrew paragraph sits on the right under
/// an English one and a selection can run across both.
///
/// A block's lines are paragraphs of their own (a selection handle can stop
/// at any of them); only the last line of a block carries the gap to the
/// next block.
enum SelectTextRenderer {
    static func attributed(_ source: SelectTextSource,
                           contentSize: UIContentSizeCategory = .large) -> NSAttributedString {
        let fonts = Fonts(contentSize: contentSize)
        switch source {
        case .markdown(let raw):
            let fallback = TextDirection.detect(raw)
            return join(MarkdownContent.parseBlocks(raw).flatMap { units(for: $0, fallback: fallback, fonts: fonts) })
        case .message(let raw):
            let fallback = TextDirection.detect(raw)
            return join(MarkdownText.runs(from: raw).map { run in
                Unit(text: inline(run.text, font: fonts.body, color: Palette.primary,
                                  paragraph: paragraph(run.direction ?? fallback,
                                                       lineSpacing: Theme.Typography.messageLineSpacing)),
                     gapAfter: Theme.Typography.messageLineSpacing)
            })
        case .code(let raw):
            return join([code(raw, fonts: fonts)])
        }
    }

    // MARK: - Blocks

    /// A block's text and the gap below it.
    private struct Unit {
        var text: NSMutableAttributedString
        var gapAfter: CGFloat
    }

    private static func units(for block: MarkdownBlock, fallback: LayoutDirection?, fonts: Fonts) -> [Unit] {
        let blockGap = Theme.Typography.blockSpacing
        switch block {
        case .paragraph(let content):
            return [Unit(text: inline(content.text, font: fonts.body, color: Palette.primary,
                                      paragraph: paragraph(content.direction ?? fallback,
                                                           lineSpacing: Theme.Typography.messageLineSpacing)),
                         gapAfter: blockGap)]

        case .heading(let level, let content):
            return [Unit(text: inline(content.text, font: fonts.heading(level), color: Palette.primary,
                                      paragraph: paragraph(content.direction ?? fallback,
                                                           lineSpacing: Theme.Typography.headingLineSpacing)),
                         gapAfter: blockGap)]

        case .bulletList(let items, let direction):
            return list(items.map { (marker: "•", content: $0) }, direction: direction ?? fallback, fonts: fonts)

        case .numberedList(let items, let direction):
            return list(items, direction: direction ?? fallback, fonts: fonts)

        case .quote(let content):
            // Inset on its leading side, where the transcript draws the bar.
            let style = paragraph(content.direction ?? fallback, lineSpacing: Theme.Typography.quoteLineSpacing)
            style.firstLineHeadIndent = 11
            style.headIndent = 11
            var font = fonts.body
            font.italic = true
            return [Unit(text: inline(content.text, font: font, color: Palette.secondary, paragraph: style),
                         gapAfter: blockGap)]

        case .code(_, let text):
            return [code(text, fonts: fonts)]

        case .rule:
            // The gap between the blocks around it stands in for the line.
            return []

        case .table(let header, let rows, let direction):
            // A row per line, its cells apart at tab stops, as a spreadsheet
            // pastes them.
            let tableDirection = direction ?? fallback
            var out: [Unit] = []
            for (index, cells) in ([header] + rows).enumerated() {
                let style = paragraph(tableDirection, lineSpacing: 2)
                style.tabStops = []
                style.defaultTabInterval = 120
                var font = fonts.table
                if index == 0 { font.weight = .semibold }
                let line = NSMutableAttributedString()
                for (column, cell) in cells.enumerated() {
                    if column > 0 { line.append(NSAttributedString(string: "\t", attributes: font.attributes(paragraph: style))) }
                    line.append(inline(cell.text, font: font, color: index == 0 ? Palette.primary : Palette.secondary,
                                       paragraph: style))
                }
                out.append(Unit(text: line, gapAfter: 4))
            }
            if !out.isEmpty { out[out.count - 1].gapAfter = blockGap }
            return out
        }
    }

    /// A list: an item per paragraph, its marker on the side the item starts
    /// from and its wrapped lines in line with the item's text.
    private static func list(_ items: [(marker: String, content: MarkdownInline)], direction: LayoutDirection?,
                             fonts: Fonts) -> [Unit] {
        var out: [Unit] = items.map { item in
            let style = paragraph(item.content.direction ?? direction, lineSpacing: Theme.Typography.messageLineSpacing)
            let marker = item.marker + " "
            style.headIndent = ceil((marker as NSString).size(withAttributes: [.font: fonts.body.font]).width)
            let text = NSMutableAttributedString(string: marker, attributes: [
                .font: fonts.body.font, .foregroundColor: Palette.tertiary, .paragraphStyle: style,
            ])
            text.append(inline(item.content.text, font: fonts.body, color: Palette.primary, paragraph: style))
            return Unit(text: text, gapAfter: Theme.Typography.listItemSpacing)
        }
        if !out.isEmpty { out[out.count - 1].gapAfter = Theme.Typography.blockSpacing }
        return out
    }

    /// Code: monospaced and left to right in every language, like
    /// `CodeBlockView`, without its trailing line breaks.
    private static func code(_ raw: String, fonts: Fonts) -> Unit {
        var text = raw
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        let style = paragraph(.leftToRight, lineSpacing: Theme.Typography.codeLineSpacing)
        return Unit(text: NSMutableAttributedString(string: text, attributes: fonts.code.attributes(
            paragraph: style, color: Palette.secondary)), gapAfter: Theme.Typography.blockSpacing)
    }

    /// Lays the units one under the other: each ends with a line break whose
    /// paragraph carries the gap to the next.
    private static func join(_ units: [Unit]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let units = units.filter { unit in
            while unit.text.string.hasSuffix("\n") {
                unit.text.deleteCharacters(in: NSRange(location: unit.text.length - 1, length: 1))
            }
            return unit.text.length > 0
        }
        for (index, unit) in units.enumerated() {
            let text = unit.text
            if index < units.count - 1 {
                let last = (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
                let current = text.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle
                let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.paragraphSpacing = unit.gapAfter
                text.addAttribute(.paragraphStyle, value: style, range: last)
                var attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
                attributes[.link] = nil
                attributes[.strikethroughStyle] = nil
                text.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            out.append(text)
        }
        return out
    }

    // MARK: - Inline

    /// Inline Markdown already parsed (`MarkdownText.attributed`): bold,
    /// italic, code spans, strikethrough and links on top of `font`.
    private static func inline(_ text: AttributedString, font: FontSpec, color: UIColor,
                               paragraph: NSParagraphStyle) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.stronglyEmphasized), runFont.weight.rawValue < UIFont.Weight.bold.rawValue {
                runFont.weight = .bold
            }
            if intent.contains(.emphasized) { runFont.italic = true }
            if intent.contains(.code) { runFont.monospaced = true }
            var attributes = runFont.attributes(paragraph: paragraph, color: color)
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return out
    }

    /// A paragraph laid out in `direction` (left to right when it has none),
    /// aligned to the side it starts from.
    private static func paragraph(_ direction: LayoutDirection?, lineSpacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let rightToLeft = direction == .rightToLeft
        style.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
        style.alignment = rightToLeft ? .right : .left
        style.lineSpacing = lineSpacing
        return style
    }

    // MARK: - Fonts and colours

    /// The transcript's colours, as UIKit colours that still follow light and
    /// dark.
    enum Palette {
        static var primary: UIColor { UIColor(Theme.textPrimary) }
        static var secondary: UIColor { UIColor(Theme.textSecondary) }
        static var tertiary: UIColor { UIColor(Theme.textTertiary) }
    }

    /// A font described by size, weight, slant and face, so inline styles
    /// stack (bold code, a bold span in a heading).
    struct FontSpec {
        var size: CGFloat
        var weight: UIFont.Weight = .regular
        var italic = false
        var monospaced = false

        var font: UIFont {
            let base = monospaced
                ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
                : UIFont.systemFont(ofSize: size, weight: weight)
            guard italic,
                  let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic))
            else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }

        func attributes(paragraph: NSParagraphStyle, color: UIColor = Palette.primary) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        }
    }

    /// `Theme.Typography` at a text size: the body and heading text styles
    /// scale with it, code stays at 13 pt as in the transcript.
    struct Fonts {
        let traits: UITraitCollection

        init(contentSize: UIContentSizeCategory) {
            traits = UITraitCollection(preferredContentSizeCategory: contentSize)
        }

        private func size(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        }

        var body: FontSpec { FontSpec(size: size(.body)) }
        var table: FontSpec { FontSpec(size: size(.subheadline)) }
        var code: FontSpec { FontSpec(size: 13, monospaced: true) }

        func heading(_ level: Int) -> FontSpec {
            let style: UIFont.TextStyle
            switch level {
            case 1: style = .title2
            case 2: style = .title3
            case 3: style = .headline
            default: style = .subheadline
            }
            return FontSpec(size: size(style), weight: level <= 2 ? .bold : .semibold)
        }
    }
}

extension DiffFile {
    /// The file's diff as text, the way Select Text shows it: a line per row
    /// with its sign (`+`, `-` or a space), and each hunk after the first under
    /// its `@@` header. A new file is its lines alone.
    var selectableText: String {
        var lines: [String] = []
        for (index, hunk) in hunks.enumerated() {
            if index > 0, let header = hunk.header, !header.isEmpty { lines.append(header) }
            for row in hunk.rows {
                if isNewFile {
                    lines.append(row.text)
                } else {
                    let sign: String
                    switch row.kind {
                    case .added: sign = "+"
                    case .deleted: sign = "-"
                    case .context: sign = " "
                    }
                    lines.append(sign + row.text)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
