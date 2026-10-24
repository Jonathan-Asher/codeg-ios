import Foundation

// MARK: - Formats

/// What kind of file a session refers to, by its extension.
enum MediaKind: String, Sendable, Hashable {
    case image
    case video
    case audio
    /// PDFs and office files, shown with Quick Look.
    case document
}

/// One file extension the app shows or plays.
struct MediaFormat: Sendable, Hashable {
    let kind: MediaKind
    /// AVFoundation, ImageIO or Quick Look handles it on the iPhone. A
    /// `false` one (WebM, Ogg) is still offered: it may play, and says so
    /// plainly when it doesn't.
    let native: Bool
    /// An SVG: drawn by WebKit, not ImageIO.
    var vector = false
    /// Formats codeg can stream that no iPhone player plays (AVI, WMV, FLV,
    /// MPEG-1/2), as the web client marks them `unsupported`.
    var unsupported = false
}

enum MediaFormats {
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "ico"]
    static let vectors: Set<String> = ["svg"]
    static let videos: Set<String> = ["mp4", "m4v", "mov", "3gp"]
    /// Streamed by codeg, but Matroska and Ogg containers rarely play in AVFoundation.
    static let maybeVideos: Set<String> = ["webm", "mkv", "ogv"]
    static let unsupportedVideos: Set<String> = ["avi", "wmv", "flv", "mpg", "mpeg"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "caf"]
    static let maybeAudio: Set<String> = ["ogg", "oga", "opus"]
    static let documents: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "usdz"]

    static let allExtensions: [String] = Array(
        images.union(vectors).union(videos).union(maybeVideos).union(unsupportedVideos)
            .union(audio).union(maybeAudio).union(documents)
    ).sorted { $0.count > $1.count }

    static func format(forExtension raw: String) -> MediaFormat? {
        let ext = raw.lowercased()
        if images.contains(ext) { return MediaFormat(kind: .image, native: true) }
        if vectors.contains(ext) { return MediaFormat(kind: .image, native: true, vector: true) }
        if videos.contains(ext) { return MediaFormat(kind: .video, native: true) }
        if maybeVideos.contains(ext) { return MediaFormat(kind: .video, native: false) }
        if unsupportedVideos.contains(ext) { return MediaFormat(kind: .video, native: false, unsupported: true) }
        if audio.contains(ext) { return MediaFormat(kind: .audio, native: true) }
        if maybeAudio.contains(ext) { return MediaFormat(kind: .audio, native: false) }
        if documents.contains(ext) { return MediaFormat(kind: .document, native: true) }
        return nil
    }

    static func format(forPath path: String) -> MediaFormat? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return format(forExtension: ext)
    }

    /// A file attached to a message whose type isn't one of the above (a text
    /// file, a spreadsheet, code, an archive): a document, opened with Quick
    /// Look. Only a file in codeg's uploads directory
    /// (`…/uploads/<bucket>/<name>`, where `upload_attachment` puts it), so a
    /// file a message merely mentions stays a link in its text.
    static func attachment(atPath path: String) -> MediaFormat? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[parts.count - 3] == "uploads" else { return nil }
        return MediaFormat(kind: .document, native: true)
    }
}

// MARK: - References

/// A media file a session mentions, resolved to an absolute path on the server.
struct MediaRef: Hashable, Identifiable, Sendable {
    /// Where in the session it was found.
    enum Origin: String, Sendable, Hashable {
        /// A Markdown link or picture in a message.
        case link
        /// A path written out in a message.
        case mention
        /// A file a Write / Edit / apply_patch tool call wrote.
        case written
        /// A file a tool's printout said it saved ("Saved to …").
        case printed
    }

    /// Absolute, normalized (no `.` or `..`).
    let path: String
    let format: MediaFormat
    let origin: Origin
    /// The turn it came from. Pictures are cached per reply, so a file the
    /// agent writes again under the same name shows its new contents.
    let scope: String
    /// The directory a relative name was joined to when that was a command's
    /// own `cd`, not the session's folder or the home. The existence check
    /// names it as one of its roots.
    var base: String? = nil

    var id: String { path }
    var kind: MediaKind { format.kind }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    /// The `rootPath` the workspace endpoints take, as codeg web's
    /// `splitAbsPath` sends it: the file's directory, with the name as the
    /// relative path.
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }
}

/// One file under a message, as the transcript shows it.
struct MediaItem: Hashable, Identifiable, Sendable {
    let ref: MediaRef
    /// Its size on the server, when the existence check listed it.
    var size: Int64?
    /// A file the agent wrote that is no longer on the server.
    var isDeleted = false

    var id: String { ref.id }
}

/// The files one message or reply shows: the ones on the server, and the
/// files it wrote that are gone since.
struct MediaGroup: Hashable, Sendable {
    var items: [MediaItem]

    init(items: [MediaItem]) { self.items = items }
    init(refs: [MediaRef]) { items = refs.map { MediaItem(ref: $0) } }

    var refs: [MediaRef] { items.map(\.ref) }

    /// One picture or video shows inline; anything more folds into one row.
    var showsInline: Bool { items.count == 1 && !items[0].isDeleted }
}

/// Where relative paths in a session point: its folder, and the server
/// user's home for `~/`.
struct MediaPathContext: Equatable, Sendable {
    var folderPath: String?
    var homePath: String?
}

// MARK: - Path rules

/// Resolves the paths a session writes the way codeg web opens them
/// (`resolveOpenAbsolutePath`, `parseLocalFileTarget`): `file://` URLs by
/// their path, `~/` against the server user's home, a relative path against
/// the session's folder, an absolute path as it is. Web URLs and other
/// schemes are not files.
enum MediaPaths {
    /// Any URL scheme, `https:`, `mailto:`, `codeg:`.
    private static let scheme = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z\d+\-.]*:"#)
    private static let windowsDrive = try! NSRegularExpression(pattern: #"^[A-Za-z]:[\\/]"#)
    private static let lineSuffix = try! NSRegularExpression(pattern: #":\d+(?::\d+)?$"#)

    /// `raw` as an absolute, normalized path, or nil when it isn't a file the
    /// server can have (a web link, a relative path with no folder, `..`
    /// above `/`). `decode`: the text is a link destination, percent-encoded,
    /// with an optional `?query` or `#fragment`.
    static func resolve(_ raw: String, in context: MediaPathContext, decode: Bool = false) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("file:") {
            guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
                  url.scheme?.lowercased() == "file" else { return nil }
            // A share on another host (`file://host/…`) isn't on the server.
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
            text = url.path
            guard !text.isEmpty else { return nil }
        } else {
            if matches(windowsDrive, text) { return nil }
            if matches(scheme, text) { return nil }
            if text.hasPrefix("//") || text.hasPrefix("\\\\") { return nil }
            if decode {
                if let cut = text.firstIndex(where: { $0 == "#" || $0 == "?" }) { text = String(text[..<cut]) }
                text = text.removingPercentEncoding ?? text
            }
        }
        // `clip.mp4:12` (a file position) names the file.
        if let match = lineSuffix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        guard !text.isEmpty else { return nil }

        let absolute: String
        if text == "~" || text.hasPrefix("~/") {
            guard let home = context.homePath, home.hasPrefix("/") else { return nil }
            absolute = home + "/" + text.dropFirst(text == "~" ? 1 : 2)
        } else if text.hasPrefix("/") {
            absolute = text
        } else {
            guard let folder = context.folderPath, folder.hasPrefix("/") else { return nil }
            absolute = folder + "/" + text
        }
        return normalize(absolute)
    }

    /// Collapse `.`, `..` and repeated slashes. Nil when `..` climbs above `/`.
    static func normalize(_ absolute: String) -> String? {
        var parts: [Substring] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` is the folder or inside it.
    static func isInside(_ path: String, folder: String?) -> Bool {
        guard let folder, let root = normalize(folder) else { return false }
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - Detection

/// Finds the media files a message or a reply refers to.
///
/// Precision over recall: a card is shown only for a file the agent clearly
/// made or pointed at, never for a name that merely appears in code.
///
/// - **Prose** (the agent's text, the user's message): Markdown links and
///   pictures (resolved as codeg web resolves them), `file://` autolinks, and
///   paths written out in full, absolute or in the home (`/tmp/a.png`,
///   `~/Movies/b.mov`), in the text or in a code span. A bare or relative
///   name in prose has no base it is known to be relative to, so it is left
///   out. Fenced code is left out.
/// - **Attachments**: in the user's message, a `file://` link to any file in
///   codeg's uploads directory is an attached file, a document when its type
///   isn't media (``MediaFormats/attachment(atPath:)``).
/// - **Tool calls**: what a Write / Edit / apply_patch call wrote (its
///   `file_path` and the other path keys, as codeg web's "New files" card
///   reads them), and a "Saved to …" / "Wrote …" line in what a tool
///   printed. A command's own text (a Bash body, a heredoc, a script) is
///   never read: names in code are templates (`f"{f}-short.png"`, `$f.png`),
///   dictionary keys and sed expressions, not files. A relative name a
///   command printed is resolved only against the `cd <dir> &&` the same
///   command starts with; without one it is left out.
/// - Anything with `{`, `}`, `$` or `*` in or around the name is a template.
enum MediaDetector {
    /// At most this many files under one message.
    static let limit = 24
    /// A tool call's printout names at most this many saved files.
    static let printedLimit = 12

    /// A Markdown link or picture: `[label](dest)`, `![alt](<dest with spaces> "title")`,
    /// with escapes in the label and balanced parentheses in the destination
    /// (`[@clip (1).mov](file:///a/clip%20(1).mov)`).
    private static let markdownLink = try! NSRegularExpression(
        pattern: #"(!?)\[((?:[^\]\\\n]|\\.)*)\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()\s]*\))+)(?:\s+"[^"\n]*")?\s*\)"#)
    /// `<file:///…>`.
    private static let autolink = try! NSRegularExpression(pattern: #"<(file:[^>\s]+)>"#)
    private static let fence = try! NSRegularExpression(
        pattern: #"(?ms)^[ \t]*(```|~~~)[^\n]*\n.*?(?:^[ \t]*\1[^\n]*$|\z)"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let webURL = try! NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z\d+.\-]*://(?!/)\S+"#)
    /// A Hebrew prefix letter joined to a path with a hyphen (`ב-/tmp/a.png`, "in /tmp/a.png").
    private static let hebrewPrefix = try! NSRegularExpression(pattern: #"([א-ת])[-־](?=[/~])"#)

    private static let extensions = MediaFormats.allExtensions.joined(separator: "|")

    /// A path that says where it is: absolute, `~/`, or `file://`, ending in a
    /// known extension, with an optional `:line[:col]`.
    private static let anchoredPath = try! NSRegularExpression(
        pattern: #"(?<![\w.~/\-@%+=$*{}\\])((?:file://)?(?:~/|/)(?:[\w@%+=~.\-]+/)*[\w@%+=~.\-]*[\w@%+=~\-]\.(?:"#
            + extensions + #"))(?::\d+(?::\d+)?)?(?![\w/\-{}$*]|\.\w)"#,
        options: [.caseInsensitive])

    /// Any path or name ending in a known extension, relative ones included
    /// (only in a printed "Saved to …" line).
    private static let anyPath = try! NSRegularExpression(
        pattern: #"(?<![\w.~/\-@%+=$*{}\\])((?:file://)?(?:~/|\.\.?/|/)?(?:[\w@%+=~.\-]+/)*[\w@%+=~.\-]*[\w@%+=~\-]\.(?:"#
            + extensions + #"))(?::\d+(?::\d+)?)?(?![\w/\-{}$*]|\.\w)"#,
        options: [.caseInsensitive])

    /// What a tool prints when it made a file: "Saved to", "Wrote", "Written
    /// to", "Created", "Exported", "Rendered", "Generated", "Screenshot saved",
    /// ffmpeg's "Output #0, mp4, to '…'".
    private static let savedVerb = try! NSRegularExpression(
        pattern: #"\b(?:saved|saving|wrote|written|writing|created|exported|rendered|generated|recorded|output)\b"#,
        options: [.caseInsensitive])
    /// How far after the verb the file may come ("Saved image to …",
    /// "Wrote 48213 bytes to …").
    private static let savedReach = 60
    /// What may stand between the verb and the file: nothing ("Wrote
    /// out.png", "Saved: …"), or a few words ending in a preposition ("Saved
    /// image to", "Wrote 48213 bytes to", ffmpeg's "Output #0, mp4, to '…'").
    /// "Screenshot saved to: shot 1.png" names "shot 1.png", not "1.png".
    private static let savedGlue = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\S+\s+){0,4}?(?:to|as|at|into|in|under|->|→|=>)\s*:?\s*|:\s*)?['"“‘(\[<]?$"#,
        options: [.caseInsensitive])
    /// A line that reports a failure ("Error opening output file …") names
    /// a file that wasn't made.
    private static let failureWords = try! NSRegularExpression(
        pattern: #"\b(?:error|errors|failed|failure|fail|cannot|can't|couldn't|could not|unable|no such|not found|denied|refused|invalid|skipped|skipping)\b"#,
        options: [.caseInsensitive])

    /// `cd <dir> &&` or `cd <dir>;` opening a command.
    private static let leadingCD = try! NSRegularExpression(
        pattern: #"^\s*cd\s+(?:"([^"\n]+)"|'([^'\n]+)'|([^\s;&|'"]+))\s*(?:&&|;)"#)
    /// A later directory change in the same command makes its base unknown.
    private static let laterCD = try! NSRegularExpression(pattern: #"(?:^|[;&|(\s])(?:cd|pushd|popd)(?:\s|$)"#)

    /// Characters that make a name a template rather than a file.
    private static let templateCharacters = CharacterSet(charactersIn: "{}$*")

    // MARK: Prose

    /// The media files `text` (a message or the agent's prose) refers to, in
    /// order. `attachments`: the text is the user's message, whose `file://`
    /// links into codeg's uploads directory are files attached to it.
    static func references(inText text: String, scope: String, context: MediaPathContext,
                           attachments: Bool = false) -> [MediaRef] {
        var found: [MediaRef] = []
        // Fenced code is example code and commands, not a product.
        var prose = blank(fence, in: text)

        /// The format of a linked file: a media one, or an attached document.
        func linkedFormat(_ path: String, destination: String) -> MediaFormat? {
            if let format = MediaFormats.format(forPath: path) { return format }
            guard attachments, isFileURL(destination) else { return nil }
            return MediaFormats.attachment(atPath: path)
        }

        for match in markdownLink.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let destRange = Range(match.range(at: 3), in: prose) else { continue }
            let dest = String(prose[destRange])
            guard !isTemplate(dest) else { continue }
            let isPicture = Range(match.range(at: 1), in: prose).map { !prose[$0].isEmpty } ?? false
            guard let path = MediaPaths.resolve(dest, in: context, decode: true),
                  let format = isPicture ? MediaFormats.format(forPath: path) : linkedFormat(path, destination: dest)
            else { continue }
            // codeg web draws a Markdown picture only from inside the
            // session's folder (`markdown-local-image.ts`).
            if isPicture, !MediaPaths.isInside(path, folder: context.folderPath) { continue }
            found.append(MediaRef(path: path, format: format, origin: .link, scope: scope))
        }
        prose = blank(markdownLink, in: prose)

        for match in autolink.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let range = Range(match.range(at: 1), in: prose), !isTemplate(prose[range]),
                  let path = MediaPaths.resolve(String(prose[range]), in: context),
                  let format = linkedFormat(path, destination: String(prose[range])) else { continue }
            found.append(MediaRef(path: path, format: format, origin: .link, scope: scope))
        }
        prose = blank(autolink, in: prose)

        // A code span that is a whole path keeps its spaces.
        var wholeSpans: [NSRange] = []
        for match in codeSpan.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let range = Range(match.range(at: 1), in: prose) else { continue }
            let span = prose[range].trimmingCharacters(in: .whitespaces)
            guard span.contains(" "), isAnchored(span), !isTemplate(span),
                  let path = MediaPaths.resolve(span, in: context),
                  let format = MediaFormats.format(forPath: path) else { continue }
            found.append(MediaRef(path: path, format: format, origin: .mention, scope: scope))
            wholeSpans.append(match.range)
        }
        prose = blank(wholeSpans, in: prose)
        // Backticks are only delimiters now; what's inside reads like prose.
        prose = prose.replacingOccurrences(of: "`", with: " ")
        found += mentions(in: prose, origin: .mention, scope: scope, context: context)
        return dedupe(found)
    }

    /// Absolute and `~/` paths with a known extension written out in `text`.
    static func mentions(in text: String, origin: MediaRef.Origin, scope: String,
                         context: MediaPathContext) -> [MediaRef] {
        // `https://host/a.png` is a web picture, not a file on the server.
        var text = blank(webURL, in: text, keepingFileURLs: true)
        text = hebrewPrefix.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                     withTemplate: "$1 ")
        return anchoredPath.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> MediaRef? in
            guard let range = Range(match.range(at: 1), in: text),
                  !inTemplate(match.range, of: text) else { return nil }
            guard let path = MediaPaths.resolve(String(text[range]), in: context),
                  let format = MediaFormats.format(forPath: path) else { return nil }
            return MediaRef(path: path, format: format, origin: origin, scope: scope)
        }
    }

    // MARK: Tool calls

    /// The media files a tool call wrote, or said it saved. `output` is the
    /// result's text; a call that failed names nothing.
    static func references(inToolCall name: String, input: String?, output: String?, isError: Bool,
                           scope: String, context: MediaPathContext) -> [MediaRef] {
        guard !isError else { return [] }
        switch ToolDerive.bucket(name: name, kind: "") {
        case .edit:
            // The edit tools resolve a relative path against the agent's
            // working directory, the session's folder, as codeg web does.
            return writtenPaths(input).compactMap { raw -> MediaRef? in
                guard !isTemplate(raw), let path = MediaPaths.resolve(raw, in: context),
                      let format = MediaFormats.format(forPath: path) else { return nil }
                return MediaRef(path: path, format: format, origin: .written, scope: scope)
            }
        case .execute:
            let base = commandBase(commandText(input), context: context)
            return savedPaths(output, base: base, scope: scope, context: context)
        case .read, .search, .todo, .taskMgmt:
            // A Read of a picture already shows it; a search lists files.
            return []
        case .web, .task, .other:
            return savedPaths(output, base: nil, scope: scope, context: context)
        }
    }

    /// The files a printout says were saved: "Saved to out.png", "Wrote
    /// /tmp/a.mp4", "Screenshot saved to: ~/s.png". A relative name is
    /// resolved against `base` (the command's own `cd`), and dropped without one.
    static func savedPaths(_ output: String?, base: String?, scope: String,
                           context: MediaPathContext) -> [MediaRef] {
        guard let output, !output.isEmpty else { return [] }
        let text = String(output.prefix(64 * 1024))
        var found: [MediaRef] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            let ns = line as NSString
            guard failureWords.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) == nil else {
                continue
            }
            for verb in savedVerb.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let start = verb.range.location + verb.range.length
                let reach = NSRange(location: start, length: min(savedReach, ns.length - start))
                guard reach.length > 0,
                      let match = anyPath.firstMatch(in: line, range: reach),
                      let range = Range(match.range(at: 1), in: line),
                      !inTemplate(match.range, of: line) else { continue }
                let gap = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                guard savedGlue.firstMatch(in: gap, range: NSRange(location: 0, length: (gap as NSString).length)) != nil
                else { continue }
                let token = String(line[range])
                let raw: String
                if isAnchored(token) {
                    raw = token
                } else if let base {
                    raw = base + "/" + token
                } else {
                    continue
                }
                guard let path = MediaPaths.resolve(raw, in: context),
                      let format = MediaFormats.format(forPath: path) else { continue }
                found.append(MediaRef(path: path, format: format, origin: .printed, scope: scope,
                                      base: isAnchored(token) ? nil : base))
                break
            }
            if found.count >= printedLimit { break }
        }
        return found
    }

    /// The directory a command runs in when it says so itself: the `cd <dir>`
    /// it opens with, absolute or in the home, and no other directory change
    /// after it. Nil when that isn't certain.
    static func commandBase(_ command: String, context: MediaPathContext) -> String? {
        let ns = command as NSString
        guard let match = leadingCD.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var dir = ""
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            dir = ns.substring(with: match.range(at: group))
        }
        guard isAnchored(dir) || dir == "~", !isTemplate(dir), !dir.contains("`") else { return nil }
        let rest = ns.substring(from: match.range.location + match.range.length)
        guard laterCD.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) == nil else {
            return nil
        }
        let absolute: String
        if dir == "~" || dir.hasPrefix("~/") {
            guard let home = context.homePath, home.hasPrefix("/") else { return nil }
            absolute = dir == "~" ? home : home + "/" + dir.dropFirst(2)
        } else {
            absolute = dir
        }
        return MediaPaths.normalize(absolute)
    }

    /// The media files of one turn: links and paths in its text, then what
    /// its tool calls wrote or said they saved, in the order they come.
    static func references(inTurn turn: MessageTurn, context: MediaPathContext) -> [MediaRef] {
        var found: [MediaRef] = []
        let blocks = turn.blocks
        var results: [String: (output: String?, isError: Bool)] = [:]
        for block in blocks {
            if case .toolResult(let id, let output, let isError, _) = block, let id {
                results[id] = (output, isError)
            }
        }
        for block in blocks {
            switch block {
            case .text(let text):
                found += references(inText: text, scope: turn.id, context: context, attachments: turn.role == .user)
            case .toolUse(let id, let name, let input, _):
                let result = id.flatMap { results[$0] }
                found += references(inToolCall: name, input: input, output: result?.output,
                                    isError: result?.isError ?? false, scope: turn.id, context: context)
            default:
                break
            }
            if found.count > limit * 4 { break }
        }
        return dedupe(found)
    }

    // MARK: Tool inputs

    /// The keys codeg web reads a written file's path from (`PATH_KEYS`).
    static let pathKeys = ["file_path", "filePath", "path", "target_file", "targetFile", "filename", "notebook_path"]
    private static let patchFile = try! NSRegularExpression(
        pattern: #"(?m)^(?:\*\*\* (?:Add|Update) File:\s+(.+?)\s*$|\+\+\+ (?:b/)?(.+?)\s*$)"#)
    private static let quotedPathKey = try! NSRegularExpression(
        pattern: #""(?:file_path|filePath|path|target_file|targetFile|notebook_path)"\s*:\s*"((?:[^"\\]|\\.)+)""#)

    /// The paths a write or edit call names: its path keys (searched four
    /// levels deep, through `input` / `arguments` / `params` / `payload`), the
    /// keys of a `changes` object, and a patch's file headers.
    static func writtenPaths(_ input: String?) -> [String] {
        guard let input, !input.isEmpty else { return [] }
        var paths: [String] = []
        if let data = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            collect(object, depth: 0, into: &paths)
        } else {
            for match in quotedPathKey.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                if let range = Range(match.range(at: 1), in: input) {
                    paths.append(String(input[range]).replacingOccurrences(of: "\\/", with: "/"))
                }
            }
        }
        paths += patchPaths(input)
        return paths
    }

    private static func collect(_ value: Any, depth: Int, into paths: inout [String]) {
        guard depth <= 4 else { return }
        if let object = value as? [String: Any] {
            for key in pathKeys {
                if let path = object[key] as? String, !path.isEmpty { paths.append(path) }
            }
            if let changes = object["changes"] as? [String: Any] { paths += changes.keys.sorted() }
            for (key, inner) in object where !pathKeys.contains(key) {
                if let text = inner as? String {
                    if key == "patch" || key == "input" || key == "diff" || text.contains("*** ") {
                        paths += patchPaths(text)
                    }
                } else {
                    collect(inner, depth: depth + 1, into: &paths)
                }
            }
        } else if let list = value as? [Any] {
            for inner in list { collect(inner, depth: depth + 1, into: &paths) }
        }
    }

    private static func patchPaths(_ text: String) -> [String] {
        patchFile.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            for group in 1...2 {
                if let range = Range(match.range(at: group), in: text) {
                    let path = String(text[range])
                    return path == "/dev/null" ? nil : path
                }
            }
            return nil
        }
    }

    /// A command call's command line, as the tool card reads it.
    static func commandText(_ input: String?) -> String {
        ToolDerive.extractCommand(input: input, parsed: ToolDerive.parseJSON(input)) ?? ""
    }

    // MARK: Helpers

    /// First mention of each file, at most ``limit``.
    static func dedupe(_ refs: [MediaRef]) -> [MediaRef] {
        var seen = Set<String>()
        var out: [MediaRef] = []
        for ref in refs where seen.insert(ref.path).inserted {
            out.append(ref)
            if out.count == limit { break }
        }
        return out
    }

    /// A `file:` URL, bare or in angle brackets.
    private static func isFileURL(_ destination: String) -> Bool {
        var text = destination.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<") { text.removeFirst() }
        return text.lowercased().hasPrefix("file:")
    }

    /// Says where it is: absolute, in the home, or a `file:` URL.
    private static func isAnchored<S: StringProtocol>(_ text: S) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~/") || text.lowercased().hasPrefix("file:")
    }

    private static func isTemplate<S: StringProtocol>(_ text: S) -> Bool {
        text.unicodeScalars.contains { templateCharacters.contains($0) }
    }

    /// The match sits in a word with `{`, `}`, `$` or `*` in it
    /// (`out/${name}.png`, `f"{f}-short.png"`, `*.png`): a template.
    private static func inTemplate(_ range: NSRange, of text: String) -> Bool {
        let ns = text as NSString
        var start = range.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
            start -= 1
        }
        var end = range.location + range.length
        while end < ns.length {
            let c = ns.character(at: end)
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
            end += 1
        }
        return isTemplate(ns.substring(with: NSRange(location: start, length: end - start)))
    }

    /// `text` with the given ranges replaced by spaces.
    private static func blank(_ ranges: [NSRange], in text: String) -> String {
        guard !ranges.isEmpty else { return text }
        let ns = NSMutableString(string: text)
        for range in ranges.reversed() {
            ns.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        return ns as String
    }

    /// `text` with every match of `regex` replaced by spaces of the same
    /// length, so later patterns don't see it again.
    private static func blank(_ regex: NSRegularExpression, in text: String, keepingFileURLs: Bool = false) -> String {
        let ns = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if keepingFileURLs, ns.substring(with: match.range).lowercased().hasPrefix("file:") { continue }
            ns.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return ns as String
    }
}

// MARK: - Attachments in a message

/// How codeg writes a file attached to a message, and how the message reads
/// once the file shows as a card instead.
enum MediaAttachmentText {
    /// What `encodeURIComponent` leaves as it is.
    private static let uriSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    private static let link = try! NSRegularExpression(
        pattern: #"!?\[(?:[^\]\\\n]|\\.)*\]\(\s*(<[^>\n]+>|(?:[^()\s]|\([^()\s]*\))+)\s*\)"#)

    /// A `file://` URI for an absolute path, each segment percent-encoded,
    /// as codeg web's `buildFileUri` makes it.
    static func fileURI(forPath path: String) -> String {
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: uriSegmentAllowed) ?? String($0) }
            .joined(separator: "/")
        return path.hasPrefix("/") ? "file://\(encoded)" : "file:///\(encoded)"
    }

    /// An attachment as codeg shows it in the sender's message
    /// (`attachment_marker`): `[name](file://…)`, the name's Markdown
    /// escaped, a destination with parentheses in angle brackets.
    static func marker(name: String, path: String) -> String {
        var label = ""
        for character in name where character != "\n" && character != "\r" {
            if "\\`*_~[]()<>".contains(character) { label.append("\\") }
            label.append(character)
        }
        let uri = fileURI(forPath: path)
        let destination = uri.contains(where: { $0 == "(" || $0 == ")" }) ? "<\(uri)>" : uri
        return "[\(label)](\(destination))"
    }

    /// `text` without its `file://` links to any of `paths` (an attachment
    /// shown as a card under it), and without the lines they leave empty.
    static func removingLinks(to paths: Set<String>, from text: String, context: MediaPathContext) -> String {
        guard !paths.isEmpty, text.contains("file:") else { return text }
        let ns = NSMutableString(string: text)
        var removed = false
        for match in link.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let dest = ns.substring(with: match.range(at: 1))
            let bare = dest.hasPrefix("<") ? String(dest.dropFirst().dropLast()) : dest
            guard bare.lowercased().hasPrefix("file:"),
                  let path = MediaPaths.resolve(bare, in: context, decode: true),
                  paths.contains(path) else { continue }
            ns.replaceCharacters(in: match.range, with: "")
            removed = true
        }
        guard removed else { return text }
        let lines = (ns as String).components(separatedBy: "\n")
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty || lines.count == 1 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Cache

/// Detection results per turn, so rebuilding the transcript's nodes (every
/// persisted change) doesn't scan unchanged turns again. Keyed by the turn's
/// id, its block count and its text length, which change when it grows.
@MainActor
enum MediaRefCache {
    private static var cache: [String: [MediaRef]] = [:]
    private static var order: [String] = []
    private static let limit = 400

    static func references(in turn: MessageTurn, context: MediaPathContext) -> [MediaRef] {
        var textLength = 0
        for block in turn.blocks {
            switch block {
            case .text(let text): textLength += text.utf8.count
            case .toolUse(_, _, let input, _): textLength += input?.utf8.count ?? 0
            case .toolResult(_, let output, _, _): textLength += output?.utf8.count ?? 0
            default: break
            }
        }
        let key = "\(turn.id)|\(turn.blocks.count)|\(textLength)|\(context.folderPath ?? "")|\(context.homePath ?? "")"
        if let hit = cache[key] { return hit }
        let refs = MediaDetector.references(inTurn: turn, context: context)
        cache[key] = refs
        order.append(key)
        if order.count > limit { cache[order.removeFirst()] = nil }
        return refs
    }
}
