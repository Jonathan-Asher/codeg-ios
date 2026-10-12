import SwiftUI

/// Which way a block of prose reads, the same rule as codeg web's
/// `src/lib/text-direction.ts`.
///
/// The app's UI is left to right, but a message's text does not care: a Hebrew
/// or Arabic reply must lay out right to left — alignment, list markers and
/// indents on the right, and punctuation and mixed Hebrew/English runs
/// resolved against a right-to-left base direction. Every block picks that
/// direction from its own text.
///
/// The first strong character is not enough for what an agent writes: a Hebrew
/// list item that opens with a Latin term (`EO 14324 (אוגוסט 2025) → חוק → …`)
/// or with a file path or a code span. So this counts words instead:
///
/// - Code spans, fenced code, URLs, file paths, e-mail addresses, `@handles`
///   and `$skills` never vote: they are left to right in every language.
///   Neither does quoted material (`'כתב תביעה'` inside an English sentence,
///   `"Save changes"` inside a Hebrew one), unless the text is nothing but a
///   quote.
/// - Digits, punctuation, Markdown syntax and emoji carry no direction.
/// - Text whose first word is right to left is right to left.
/// - Text whose first word is left to right is still right to left when at
///   least 40% of its words are: a Hebrew sentence that starts with a Latin
///   term. Below that it is an English sentence quoting a few Hebrew words.
/// - Text with no letters at all has no direction of its own (`nil`) and
///   inherits its container's.
enum TextDirection {
    /// The share of right-to-left words that makes a text opening with a
    /// left-to-right word read right to left.
    static let rtlWordShare = 0.4

    /// The direction `text` reads in, or `nil` when it has no letters to tell
    /// (numbers, punctuation, emoji, code only) and should inherit. Takes raw
    /// Markdown as well as plain text: Markdown syntax carries no direction,
    /// and code, link targets, URLs and paths are dropped before the words are
    /// counted.
    static func detect(_ text: String) -> LayoutDirection? {
        guard !text.isEmpty else { return nil }
        let prose = stripLTRSpans(text)
        return decide(stripQuoted(prose)) ?? decide(prose)
    }

    /// Whether `text` holds a character of a right-to-left script.
    static func hasRTLLetter<S: StringProtocol>(_ text: S) -> Bool {
        text.unicodeScalars.contains(where: isRTL)
    }

    /// A run of consecutive lines that read in the same direction.
    struct Run: Equatable {
        let text: String
        let direction: LayoutDirection?
    }

    /// Splits plain multi-line text (a user message) into runs of lines that
    /// share a direction, so each run can be its own block: a Hebrew paragraph
    /// under an English one keeps its own alignment. A line with no letters (a
    /// number, an emoji) stays with the run it follows, and one before any
    /// letters takes the first run's direction; blank lines between two runs
    /// open the second one, so the gap still shows. Joining the runs' text
    /// with "\n" gives back the input.
    static func lineRuns(_ text: String) -> [Run] {
        var runs: [(lines: [String], direction: LayoutDirection?)] = []
        // Blank lines at the end of the current run, which move to the next
        // run if the direction changes.
        var trailingBlank = 0
        for line in text.components(separatedBy: "\n") {
            let direction = detect(line)
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard let last = runs.indices.last else {
                runs.append(([line], direction))
                trailingBlank = blank ? 1 : 0
                continue
            }
            if direction == nil {
                runs[last].lines.append(line)
                trailingBlank = blank ? trailingBlank + 1 : 0
            } else if runs[last].direction == nil || runs[last].direction == direction {
                runs[last].lines.append(line)
                runs[last].direction = direction
                trailingBlank = 0
            } else {
                let moved = Array(runs[last].lines.suffix(trailingBlank))
                runs[last].lines.removeLast(trailingBlank)
                runs.append((moved + [line], direction))
                trailingBlank = 0
            }
        }
        return runs.map { Run(text: $0.lines.joined(separator: "\n"), direction: $0.direction) }
    }

    // MARK: - Words

    /// Counts the words and decides; `nil` when there are none.
    private static func decide(_ text: String) -> LayoutDirection? {
        let scalars = Array(text.unicodeScalars)
        var rtl = 0
        var ltr = 0
        var firstIsRTL: Bool?
        var i = 0
        while i < scalars.count {
            guard isLetter(scalars[i]) else { i += 1; continue }
            // A word: a letter followed by letters, combining marks (niqqud,
            // harakat), joiners, and apostrophes between letters (`center's`
            // and `צ'יפס` are one word each). Its first letter decides it.
            let wordIsRTL = isRTL(scalars[i])
            if firstIsRTL == nil { firstIsRTL = wordIsRTL }
            if wordIsRTL { rtl += 1 } else { ltr += 1 }
            i += 1
            while i < scalars.count {
                let s = scalars[i]
                if isLetter(s) || isMark(s) || s.value == 0x200C || s.value == 0x200D {
                    i += 1
                } else if s == "'" || s.value == 0x2019, i + 1 < scalars.count, isLetter(scalars[i + 1]) {
                    i += 1
                } else {
                    break
                }
            }
        }
        if rtl == 0 && ltr == 0 { return nil }
        if rtl == 0 { return .leftToRight }
        if ltr == 0 || firstIsRTL == true { return .rightToLeft }
        return Double(rtl) / Double(rtl + ltr) >= rtlWordShare ? .rightToLeft : .leftToRight
    }

    /// Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic and the Arabic
    /// supplements (U+0590–U+08FF), the Hebrew and Arabic presentation forms,
    /// and the supplementary-plane right-to-left blocks.
    private static func isRTL(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF,
             0x10800...0x10FFF, 0x1E800...0x1EFFF:
            return true
        default:
            return false
        }
    }

    /// `\p{L}`. ASCII and the Hebrew letters skip the (slow) property lookup.
    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII { return (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value) }
        if (0x05D0...0x05EA).contains(s.value) { return true }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// `\p{M}`.
    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII { return false }
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    // MARK: - Spans that never vote

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a typo fails every test at once.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fencedCode = regex(#"```[\s\S]*?(?:```|\z)|~~~[\s\S]*?(?:~~~|\z)"#)
    private static let inlineCode = regex(#"(`+)[^`]*?\1"#)
    /// A file or codeg reference — `[a.ts](file:///…)`, `[@Codex](codeg://…)` —
    /// is a badge whose label is a name; another link keeps its label as prose.
    private static let referenceLink = regex(#"\[[^\]\n]*\]\((?:file|codeg):[^)\s]*\)"#, .caseInsensitive)
    private static let linkTarget = regex(#"\]\([^)\s]*\)"#)
    /// `(?<![A-Za-z0-9_])` is the web pattern's `\b`, which only knows ASCII
    /// word characters (ICU's would not match after a Hebrew letter).
    private static let url = regex(#"(?<![A-Za-z0-9_])(?:[a-z][a-z0-9+.\-]*://|www\.|mailto:)\S+"#, .caseInsensitive)
    /// The lookbehinds below only skip start positions where no match can
    /// begin (inside a token), so the matches are the web pattern's; without
    /// them every position of a long reply backtracks through its token.
    private static let email = regex(#"(?<![^\s@])[^\s@]+@[^\s@]+\.[^\s@]+"#)
    /// `@file`, `@agent` mentions and `$skill` invocations at a word start.
    private static let handle = regex(#"(^|\s)[@\$]\S+"#)
    /// A token with a slash or backslash in it: a path, a ratio, `and/or`.
    private static let slashedToken = regex(#"(?<!\S)\S*[/\\]\S*"#)

    /// Removes everything that is left to right in every language. Each pattern
    /// runs only when the text holds a character it needs, which keeps the
    /// per-token work of a streaming reply off plain prose.
    private static func stripLTRSpans(_ text: String) -> String {
        var s = text
        if has(s, "```") || has(s, "~~~") { s = replace(fencedCode, in: s, with: " ") }
        if has(s, "`") { s = replace(inlineCode, in: s, with: " ") }
        if has(s, "](") {
            s = replace(referenceLink, in: s, with: " ")
            s = replace(linkTarget, in: s, with: "] ")
        }
        if has(s, "://") || has(s, "www.", caseInsensitive: true) || has(s, "mailto:", caseInsensitive: true) {
            s = replace(url, in: s, with: " ")
        }
        if has(s, "@") { s = replace(email, in: s, with: " ") }
        if has(s, "@") || has(s, "$") { s = replace(handle, in: s, with: "$1 ") }
        if has(s, "/") || has(s, "\\") {
            // `ו/או` is Hebrew prose, not a path.
            s = replace(slashedToken, in: s) { hasRTLLetter($0) ? $0 : " " }
        }
        return s
    }

    /// A quoted span: the opener follows the start, a space, an opening bracket
    /// or a dash, and the closer is followed by the end, one of those or
    /// punctuation. That keeps Hebrew gershayim and geresh (`ארה"ב`, `צ'יפס`)
    /// and English apostrophes (`center's`), which sit between letters, out.
    private static let quotePairs: [(open: String, close: String)] = [
        ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{201E}", "\u{201C}"),
        ("\u{2018}", "\u{2019}"), ("\u{00AB}", "\u{00BB}"),
    ]
    private static let quoted: [NSRegularExpression] = quotePairs.map { pair in
        regex(#"(^|[\s(\[{\x{2014}\x{2013}\-])\#(pair.open)[^\n\#(pair.open)\#(pair.close)]+?\#(pair.close)(?=\z|[\s.,;:!?)\]}\x{2026}\x{2014}\x{2013}\-])"#)
    }

    private static func stripQuoted(_ text: String) -> String {
        zip(quotePairs, quoted).reduce(text) { s, quote in
            has(s, quote.0.open) ? replace(quote.1, in: s, with: "$1 ") : s
        }
    }

    /// Whether `text` holds `needle`, compared as UTF-8 bytes (`caseInsensitive`
    /// folds ASCII only, for a lowercase needle). Much cheaper than a bridged
    /// `range(of:)` on a long reply.
    private static func has(_ text: String, _ needle: String, caseInsensitive: Bool = false) -> Bool {
        var text = text
        let pattern = Array(needle.utf8)
        return text.withUTF8 { bytes in
            guard !pattern.isEmpty, bytes.count >= pattern.count else { return false }
            for start in 0...(bytes.count - pattern.count) {
                var k = 0
                while k < pattern.count {
                    var byte = bytes[start + k]
                    if caseInsensitive, byte >= 0x41, byte <= 0x5A { byte |= 0x20 }
                    guard byte == pattern[k] else { break }
                    k += 1
                }
                if k == pattern.count { return true }
            }
            return false
        }
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with transform: (String) -> String
    ) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}

extension View {
    /// Lays this block out in `direction`: its alignment (`.leading` is the
    /// right edge when it is right to left), the side its list marker or quote
    /// bar sits on, and the base direction its text's bidi runs resolve
    /// against. `nil` keeps the direction it inherits.
    func blockDirection(_ direction: LayoutDirection?) -> some View {
        transformEnvironment(\.layoutDirection) { value in
            if let direction { value = direction }
        }
    }
}
