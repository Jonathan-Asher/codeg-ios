import Foundation

/// Turns an agent reply into text worth reading aloud: the prose, with the
/// Markdown stripped. Fenced code blocks and tool output are skipped unless
/// the options ask for them.
enum SpeechText {
    struct Options: Equatable, Sendable {
        var includeCode = false
        var includeToolOutput = false
    }

    /// The longest tool output read aloud when tool output is included.
    static let toolOutputLimit = 600

    /// The speakable text of an assistant reply's blocks.
    static func from(blocks: [ContentBlock], options: Options = Options()) -> String {
        var paragraphs: [String] = []
        for block in blocks {
            switch block {
            case .text(let markdown):
                let text = fromMarkdown(markdown, includeCode: options.includeCode)
                if !text.isEmpty { paragraphs.append(text) }
            case .toolUse(_, let name, _, _):
                if options.includeToolOutput { paragraphs.append(sentence("Tool: \(name)")) }
            case .toolResult(_, let output, _):
                guard options.includeToolOutput, let output else { continue }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let clipped = trimmed.count > toolOutputLimit ? String(trimmed.prefix(toolOutputLimit)) : trimmed
                paragraphs.append(fromMarkdown(clipped, includeCode: true))
            case .thinking, .image, .imageGeneration, .unknown:
                continue
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Strip Markdown to readable prose, one paragraph per line group; every
    /// paragraph ends with punctuation so the synthesizer pauses there.
    static func fromMarkdown(_ markdown: String, includeCode: Bool = false) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        var inFence = false
        var fenceMarker = ""
        var codeLines: [String] = []

        func flush() {
            let joined = current.joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { paragraphs.append(sentence(joined)) }
            current = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Fenced code: ``` or ~~~ (with an optional language).
            if inFence {
                if line.hasPrefix(fenceMarker) {
                    inFence = false
                    if includeCode {
                        let code = codeLines.map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .joined(separator: ". ")
                        if !code.isEmpty { paragraphs.append(sentence(code)) }
                    }
                    codeLines = []
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                inFence = true
                fenceMarker = String(line.prefix(3))
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            // Horizontal rules.
            if line.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush()
                continue
            }
            // Table separator rows (|---|:--:|).
            if line.range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil {
                continue
            }
            // Headings stand alone.
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                current.append(inline(String(line[heading.upperBound...])))
                flush()
                continue
            }
            var text = line
            // Table rows: read the cells.
            if text.hasPrefix("|") {
                let cells = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                flush()
                current.append(cells.map(inline).joined(separator: ", "))
                flush()
                continue
            }
            // Block quotes, list markers, task boxes.
            text = text.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression)
            let isListItem = text.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) != nil
            text = text.replacingOccurrences(of: #"^([-*+]|\d{1,3}[.)])\s+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^\[[ xX]\]\s+"#, with: "", options: .regularExpression)
            if isListItem {
                // Each item reads as its own sentence.
                flush()
                current.append(inline(text))
                flush()
            } else {
                current.append(inline(text))
            }
        }
        // An unclosed fence is code to the end.
        if inFence, includeCode {
            let code = codeLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .joined(separator: ". ")
            if !code.isEmpty { paragraphs.append(sentence(code)) }
        }
        flush()
        return paragraphs.joined(separator: "\n")
    }

    /// Inline Markdown: images and links keep their text, URLs drop, inline
    /// code keeps its content, emphasis markers and HTML tags go.
    static func inline(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),           // images → alt text
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),             // links → text
            (#"<(https?://[^>]+)>"#, ""),                   // autolinks
            (#"https?://\S+"#, "a link"),                   // bare URLs
            (#"`+([^`]+)`+"#, "$1"),                        // inline code → content
            (#"(\*\*|__)(.+?)\1"#, "$2"),                   // bold
            (#"(?<![\w*])\*(?!\s)([^*]+?)\*(?![\w*])"#, "$1"), // *italic*
            (#"(?<![\w_])_(?!\s)([^_]+?)_(?![\w_])"#, "$1"), // _italic_
            (#"~~(.+?)~~"#, "$1"),                          // strikethrough
            (#"</?[A-Za-z][^>]*>"#, " "),                   // HTML tags
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// End with sentence punctuation so the synthesizer pauses.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?:;…".contains(last) ? trimmed : trimmed + "."
    }

    // MARK: - Script runs (system-voice fallback)

    /// A run of text in one script, for picking a system voice per span.
    struct Run: Equatable, Sendable {
        var text: String
        var isHebrew: Bool
    }

    /// Split into Hebrew and non-Hebrew runs. Digits, spaces and punctuation
    /// stay with the run they sit in; a Latin span only splits off when it
    /// holds a letter.
    static func scriptRuns(_ text: String) -> [Run] {
        var runs: [Run] = []
        var current = ""
        var currentHebrew: Bool?

        for ch in text {
            let script = Self.script(of: ch)
            guard let isHebrew = script else {
                current.append(ch)
                continue
            }
            if currentHebrew == nil {
                currentHebrew = isHebrew
            } else if currentHebrew != isHebrew {
                // Leave trailing neutral characters with the run that ends.
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { runs.append(Run(text: piece, isHebrew: currentHebrew ?? false)) }
                current = ""
                currentHebrew = isHebrew
            }
            current.append(ch)
        }
        let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty { runs.append(Run(text: piece, isHebrew: currentHebrew ?? false)) }
        return runs
    }

    /// true = Hebrew letter, false = Latin letter, nil = neutral.
    private static func script(of ch: Character) -> Bool? {
        for scalar in ch.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: return true
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return false
            default: continue
            }
        }
        return nil
    }

    /// Whether the text contains any Hebrew letter.
    static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) || (0xFB1D...0xFB4F).contains($0.value) }
    }
}
