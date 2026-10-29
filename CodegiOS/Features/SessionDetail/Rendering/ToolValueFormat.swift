import SwiftUI

// Visual rendering for tool-call *input arguments* and *output*, so an MCP /
// generic tool call reads as structured fields and clean terminal/markdown
// output instead of a dumped raw-JSON string. Mirrors the codeg web client's
// `GenericToolInput` / `ToolOutput` / `commandOutputFromJsonString` /
// `parseCliExecutionEnvelope` helpers (see web `content-parts-renderer.tsx` and
// `ai-elements/tool.tsx`) so the two clients render the same payloads alike.

// MARK: - Pure JSON helpers

/// Pure (view-free) helpers for parsing and shaping tool JSON payloads.
enum ToolJSONFormat {

    /// Parse a JSON string, allowing a top-level fragment (a bare `"string"` or
    /// number) — command results are sometimes a JSON-encoded scalar.
    static func parseAny(_ s: String?) -> Any? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Parse a JSON object (`{...}`) string into a dictionary, or nil.
    static func parseObject(_ s: String?) -> [String: Any]? {
        parseAny(s) as? [String: Any]
    }

    /// True when an `Any` decoded from JSON is a boolean (vs a number). A JSON
    /// bool decodes to an `NSNumber` backed by `CFBoolean`; `as? Bool` is
    /// unreliable for 0/1, so test the CoreFoundation type id directly.
    static func isBoolean(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A short scalar rendering for inline display ("true", "42", "1.5").
    static func scalarString(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if isBoolean(value), let n = value as? NSNumber { return n.boolValue ? "true" : "false" }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// Pretty-print a JSON value (object/array/scalar) for a code block.
    static func prettyPrint(_ value: Any) -> String? {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value) else {
            return scalarString(value)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Re-serialize a JSON string pretty-printed; returns nil if it isn't JSON.
    static func prettyPrintString(_ s: String) -> String? {
        guard let any = parseAny(s) else { return nil }
        // A bare scalar isn't worth a "json" block.
        if any is String || any is NSNumber { return nil }
        return prettyPrint(any)
    }

    /// Top-level object keys *in source order*. `JSONSerialization` yields an
    /// unordered dictionary, so a tiny string scanner recovers the author's key
    /// order (matching the web's `Object.entries` insertion order). Returns an
    /// empty array when the input isn't an object — callers fall back to sorted
    /// keys.
    static func orderedTopLevelKeys(_ s: String) -> [String] {
        var keys: [String] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count, chars[i] != "{" { i += 1 }
        guard i < chars.count else { return keys }
        i += 1 // step past '{'
        var depth = 0
        var expectKey = true
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var str = ""
                i += 1
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\\" {            // escape: take next char verbatim
                        i += 1
                        if i < chars.count { str.append(chars[i]) }
                    } else if ch == "\"" {
                        break
                    } else {
                        str.append(ch)
                    }
                    i += 1
                }
                if depth == 0, expectKey {
                    keys.append(str)
                    expectKey = false
                }
                i += 1
                continue
            }
            if depth == 0 {
                switch c {
                case ",": expectKey = true
                case "{", "[": depth += 1
                case "}": return keys                 // end of top object
                default: break
                }
            } else {
                switch c {
                case "{", "[": depth += 1
                case "}", "]": depth -= 1
                default: break
                }
            }
            i += 1
        }
        return keys
    }

    /// Ordered `(key, value)` entries of a tool input object, with hidden / null
    /// fields dropped. Falls back to sorted keys when source order can't be
    /// recovered.
    static func orderedEntries(json: String, object: [String: Any]) -> [(String, Any)] {
        var order = orderedTopLevelKeys(json)
        if order.isEmpty { order = object.keys.sorted() }
        // Append any keys the scanner missed, deterministically.
        let seen = Set(order)
        order.append(contentsOf: object.keys.filter { !seen.contains($0) }.sorted())

        var out: [(String, Any)] = []
        for key in order {
            guard let value = object[key] else { continue }
            if hiddenFields.contains(key) { continue }
            if value is NSNull { continue }
            out.append((key, value))
        }
        return out
    }

    /// Fields rendered as a code block when they carry a string value.
    static let codeFields: Set<String> = [
        "command", "cmd", "script", "old_string", "new_string",
        "content", "new_source", "prompt", "code", "patch", "diff",
    ]

    /// Fields never shown (noise / internal flags). Mirrors web `HIDDEN_FIELDS`.
    static let hiddenFields: Set<String> = ["dangerouslyDisableSandbox"]
}

// MARK: - Output normalization

/// Turns a tool's raw output (often a JSON envelope) into clean displayable
/// text and classifies its kind. Mirrors the web `ToolOutput` pipeline.
enum ToolOutputFormat {

    enum Kind { case json, diff, markdown, log }

    /// Pull human-readable text out of a JSON command-result envelope
    /// (`{stdout, stderr, exit_code, formatted_output, ...}`), or nil when the
    /// output isn't such an envelope. Mirrors web `commandOutputFromJsonString`.
    static func commandOutput(fromJSON output: String) -> String? {
        guard let parsed = ToolJSONFormat.parseAny(output) else { return nil }
        if let s = parsed as? String { return s }
        guard let obj = parsed as? [String: Any] else { return nil }

        let envelopeKeys = ["command", "parsed_cmd", "cwd", "exit_code",
                            "stdout", "stderr", "formatted_output", "aggregated_output"]
        let isEnvelope = envelopeKeys.contains { obj[$0] != nil }

        let stdout = (obj["stdout"] as? String) ?? ""
        let stderr = (obj["stderr"] as? String) ?? ""
        if !stdout.isEmpty || !stderr.isEmpty {
            if !stdout.isEmpty, !stderr.isEmpty { return "\(stdout)\n[stderr]\n\(stderr)" }
            return stdout.isEmpty ? stderr : stdout
        }

        for key in ["formatted_output", "aggregated_output", "output", "text", "result"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        // Metadata-only envelope (command/cwd/exit_code, no body) → empty, so we
        // don't fall back to dumping the raw JSON as terminal output.
        return isEnvelope ? "" : nil
    }

    private static let cliMetaLine = try! NSRegularExpression(
        pattern: #"^(exit code\s*[:=]|wall time\s*[:=]|chunk id\s*[:=]|original token count\s*[:=]|total output lines\s*[:=]|process exited with code\s)"#,
        options: [.caseInsensitive]
    )

    private static func isMetaLine(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return cliMetaLine.firstMatch(in: s, range: r) != nil
    }

    /// Strip CLI execution-envelope metadata ("Chunk ID:", "Wall time:",
    /// "Output:" separator, …) leaving the real command output. Mirrors web
    /// `parseCliExecutionEnvelope`.
    static func parseCliEnvelope(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var outputSep = -1
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^output:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                outputSep = idx
                break
            }
            if !isMetaLine(trimmed), !trimmed.isEmpty { break }
        }
        if outputSep >= 0 {
            var start = outputSep + 1
            while start < lines.count {
                let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
                if isMetaLine(trimmed) || trimmed.isEmpty { start += 1; continue }
                break
            }
            return lines[start...].joined(separator: "\n")
        }
        var index = 0
        var sawMeta = false
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if isMetaLine(trimmed) { sawMeta = true; index += 1; continue }
            if sawMeta, trimmed.isEmpty { index += 1; continue }
            break
        }
        if !sawMeta { return text }
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        return lines[index...].joined(separator: "\n")
    }

    /// Remove a single leading / trailing Markdown code fence (```sh … ```).
    static func stripMarkdownFence(_ text: String) -> String {
        var result = text
        if let r = result.range(of: #"^\s*```[\w-]*\s*\n?"#, options: .regularExpression) {
            result.removeSubrange(r)
        }
        if let r = result.range(of: #"\n?\s*```\s*$"#, options: .regularExpression) {
            result.removeSubrange(r)
        }
        return result
    }

    /// Full command-output pipeline: unwrap a JSON envelope, strip CLI metadata,
    /// drop a wrapping code fence.
    static func cleanCommandOutput(_ source: String) -> String {
        let unwrapped = commandOutput(fromJSON: source) ?? source
        return stripMarkdownFence(parseCliEnvelope(unwrapped))
    }

    /// Classify finalized output so the renderer can pick a JSON block, a diff
    /// view, Markdown, or a plain log block. Mirrors web `detectOutputLanguage`
    /// + `looksLikeMarkdown`.
    static func classify(_ output: String) -> Kind {
        let trimmed = output.trimmingCharacters(in: .whitespaces)
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           ToolJSONFormat.parseAny(trimmed) != nil {
            return .json
        }
        if trimmed.contains("diff --git") || trimmed.range(of: #"(?m)^@@ "#, options: .regularExpression) != nil {
            return .diff
        }
        return looksLikeMarkdown(output) ? .markdown : .log
    }

    static func looksLikeMarkdown(_ s: String) -> Bool {
        var count = 0
        let patterns = [
            #"(?m)^#{1,6}\s"#, #"(?m)^\s*[-*+]\s"#, #"(?m)^\s*\d+\.\s"#,
            #"\*\*[^*]+\*\*"#, #"\[[^\]]+\]\([^)]+\)"#, #"```"#, #"(?m)^>\s"#, #"(?m)^\|.+\|$"#,
        ]
        for p in patterns {
            if s.range(of: p, options: .regularExpression) != nil { count += 1 }
            if count >= 2 { return true }
        }
        return false
    }

    /// Parse a JSON-object error body into labeled `(key, value)` fields, or nil
    /// for a plain-text error. Mirrors web `renderErrorText`.
    static func errorFields(_ errorText: String) -> [(String, String)]? {
        let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = ToolJSONFormat.parseObject(trimmed), !obj.isEmpty else { return nil }
        let entries = ToolJSONFormat.orderedEntries(json: trimmed, object: obj)
        guard !entries.isEmpty else { return nil }
        return entries.map { key, value in
            (key, (value as? String) ?? ToolJSONFormat.prettyPrint(value) ?? "")
        }
    }
}

// MARK: - Read-tool output

/// Parses a Read tool's output. The codeg server returns a file body as a JSON
/// envelope `{"start_line": N, "content": "..."}` (so a windowed read still
/// numbers from its true first line). Returns nil for anything that isn't this
/// envelope, so the caller falls back to the generic output renderer. Mirrors the
/// web client's read-output parse in `content-parts-renderer`.
enum ReadOutputFormat {
    struct File: Equatable {
        let content: String
        let startLine: Int
    }

    static func parse(_ output: String) -> File? {
        guard let obj = ToolJSONFormat.parseObject(output),
              let start = intValue(obj["start_line"]),
              let content = obj["content"] as? String else { return nil }
        return File(content: content, startLine: start)
    }

    /// A numeric (non-boolean) JSON value as an Int — accepts both `1` and `1.0`,
    /// matching the web's `typeof === "number"` check.
    private static func intValue(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !ToolJSONFormat.isBoolean(n) else { return nil }
        return n.intValue
    }
}

// MARK: - Friendly field labels

/// Human labels for common tool-argument keys (mirrors web `FIELD_LABEL_KEYS`).
/// Unknown keys fall back to the key itself.
enum ToolFieldLabel {
    private static let map: [String: String] = [
        "file_path": "File", "notebook_path": "Notebook", "path": "Path",
        "command": "Command", "cmd": "Command", "script": "Script",
        "old_string": "Replace", "new_string": "With",
        "pattern": "Pattern", "query": "Query", "url": "URL",
        "description": "Description", "content": "Content", "new_source": "Source",
        "prompt": "Prompt", "subject": "Subject", "task": "Task",
        "task_id": "Task", "task_ids": "Tasks", "taskId": "Task",
        "status": "Status", "skill": "Skill", "args": "Args",
        "offset": "Offset", "limit": "Limit", "glob": "Glob",
        "type": "Type", "output_mode": "Output", "replace_all": "Replace all",
        "language": "Language", "timeout": "Timeout", "wait_ms": "Wait",
        "run_in_background": "Background", "background": "Background",
        "subagent_type": "Agent", "agent_type": "Agent",
        "libraryName": "Library", "libraryId": "Library ID",
        "working_dir": "Directory", "cwd": "Directory",
    ]

    static func label(for key: String) -> String {
        if let l = map[key] { return l }
        return humanize(key)
    }

    /// `read_only` → "Read only", `timeoutMs` → "Timeout ms". A light touch for
    /// keys not in the curated map, so unknown MCP args still read as labels
    /// rather than raw identifiers.
    private static func humanize(_ key: String) -> String {
        var spaced = key.replacingOccurrences(of: "_", with: " ")
        // Split camelCase boundaries (lowercase→Uppercase) with a space.
        spaced = spaced.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression
        )
        spaced = spaced.lowercased().trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return key }
        return first.uppercased() + spaced.dropFirst()
    }
}

// MARK: - Field views

/// `label: value` on one line — short scalars. Mirrors web `FieldInline`.
struct ToolFieldInline: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(stringLiteral: label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            Text(value)
                .font(.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A field label above a block child (code / long text / nested JSON). Mirrors
/// web `FieldBlock`.
struct ToolFieldBlock<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(stringLiteral: label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            content
        }
    }
}

/// A header-less monospaced block for a long plain-string value.
struct PlainTextBlock: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm)
    }
}

/// Renders a JSON object's arguments as a structured field list — the universal
/// fallback for MCP and otherwise-unrecognized tools, replacing a dumped
/// raw-JSON code block. Mirrors web `GenericToolInput`.
struct StructuredJSONView: View {
    /// Raw JSON string (object expected). Falls back to a mono block otherwise.
    let json: String
    /// Long string values longer than this expand into their own block.
    var inlineMaxLength: Int = 200

    var body: some View {
        if let object = ToolJSONFormat.parseObject(json) {
            let entries = ToolJSONFormat.orderedEntries(json: json, object: object)
            if entries.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        field(key: entry.0, value: entry.1)
                    }
                }
            }
        } else if !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Not a JSON object (a bare string / number / array, or invalid).
            if let array = ToolJSONFormat.parseAny(json), JSONSerialization.isValidJSONObject(array),
               let pretty = ToolJSONFormat.prettyPrint(array) {
                CodeBlockView(code: pretty, language: "json")
            } else {
                PlainTextBlock(text: json)
            }
        }
    }

    @ViewBuilder
    private func field(key: String, value: Any) -> some View {
        let label = ToolFieldLabel.label(for: key)
        if let s = value as? String {
            if ToolJSONFormat.codeFields.contains(key) {
                ToolFieldBlock(label: label) {
                    CodeBlockView(code: s, language: codeLanguage(for: key))
                }
            } else if s.count > inlineMaxLength || s.contains("\n") {
                ToolFieldBlock(label: label) { PlainTextBlock(text: s) }
            } else {
                ToolFieldInline(label: label, value: s)
            }
        } else if let scalar = ToolJSONFormat.scalarString(value) {
            ToolFieldInline(label: label, value: scalar)
        } else if let pretty = ToolJSONFormat.prettyPrint(value) {
            ToolFieldBlock(label: label) {
                CodeBlockView(code: pretty, language: "json")
            }
        }
    }

    private func codeLanguage(for key: String) -> String? {
        switch key {
        case "command", "cmd", "script": return "bash"
        case "patch", "diff": return "diff"
        default: return nil
        }
    }
}

/// Renders a file body with a right-aligned line-number gutter — a Read tool's
/// output. Numbers start at the envelope's `start_line`, so a windowed read shows
/// the file's real line numbers. Horizontally scrollable for long lines; long
/// files collapse behind a "show more" toggle. Mirrors the web client's
/// read-output view (a line gutter + monospaced content).
struct FileBodyView: View {
    let file: ReadOutputFormat.File
    /// Collapse to this many lines when the file is longer, with a toggle.
    var collapsedLineLimit: Int = 60

    @State private var expanded = false
    /// Where the screen offers Select Text, a long press on the file has Copy
    /// and Select Text for all of it.
    @Environment(\.selectText) private var selectText

    /// Drop a trailing newline so the file doesn't render a dangling empty
    /// numbered line (matches `CodeBlockView`'s trim).
    private var content: String {
        var s = file.content
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }
    private var lines: [Substring] { content.split(separator: "\n", omittingEmptySubsequences: false) }
    private var isLong: Bool { lines.count > collapsedLineLimit }
    private var shown: ArraySlice<Substring> { (isLong && !expanded) ? lines.prefix(collapsedLineLimit) : lines[...] }

    /// Size the gutter to the file's widest line number so 4–5 digit numbers never
    /// clip and every row's gutter aligns (mirrors `DiffView`'s gutter sizing).
    private var gutterWidth: CGFloat {
        let maxNo = file.startLine + max(0, lines.count - 1)
        let digits = max(2, String(maxNo).count)
        return CGFloat(digits) * 6.5 + 6
    }

    var body: some View {
        if content.isEmpty {
            Text("Empty file")
                .font(Theme.Typography.metaLabel)
                .foregroundStyle(Theme.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { idx, line in
                            row(number: file.startLine + idx, text: String(line))
                        }
                    }
                    // Size to the widest row so each row's background extends across
                    // the longest line when scrolled.
                    .fixedSize(horizontal: true, vertical: false)
                }
                if isLong { expandToggle }
            }
            .background(Theme.codeSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .hairlineBorder(Theme.Radius.sm)
            .selectTextMenu(.code(content), enabled: selectText != nil)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("FILE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            CopyButton(text: content)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func row(number: Int, text: String) -> some View {
        HStack(spacing: 0) {
            Text(String(number))
                .font(Theme.Typography.diffGutter.monospacedDigit())
                .foregroundStyle(Theme.textTertiary.opacity(0.7))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)
            Text(text.isEmpty ? " " : text)
                .font(Theme.Typography.diffCode)
                .lineSpacing(Theme.Typography.diffLineSpacing)
                .foregroundStyle(Theme.textSecondary)
                .modifier(SelectableText(enabled: selectText == nil))
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1)
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            (expanded ? Text("Show less") : Text("Show \(lines.count - collapsedLineLimit) more lines"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
