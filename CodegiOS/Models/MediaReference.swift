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
        /// A path in a command, or in what a tool printed.
        case command
    }

    /// Absolute, normalized (no `.` or `..`).
    let path: String
    let format: MediaFormat
    let origin: Origin
    /// The turn it came from. Pictures are cached per reply, so a file the
    /// agent writes again under the same name shows its new contents.
    let scope: String

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
/// codeg web links only Markdown link destinations; the phone also takes
/// paths written out in prose or in code spans, since it can't open a file
/// any other way. Tool calls follow the web's "New files" card
/// (`extractReplyFileChanges`): the paths a Write / Edit / apply_patch call
/// wrote. The phone adds what a command or another tool names (an `ffmpeg`
/// output, "Saved to …"), leaving out a printout that lists many files.
enum MediaDetector {
    /// At most this many files under one message.
    static let limit = 12
    /// A command's printout naming more media files than this is a listing
    /// (`ls`, `find`), not something the command made.
    static let listingThreshold = 6

    /// A Markdown link or picture: `[label](dest)`, `![alt](<dest with spaces> "title")`.
    private static let markdownLink = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]\n]*)\]\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+"[^"\n]*")?\s*\)"#)
    /// `<file:///…>`.
    private static let autolink = try! NSRegularExpression(pattern: #"<(file:[^>\s]+)>"#)
    private static let fence = try! NSRegularExpression(
        pattern: #"(?ms)^[ \t]*(```|~~~)[^\n]*\n.*?(?:^[ \t]*\1[^\n]*$|\z)"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let webURL = try! NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z\d+.\-]*://(?!/)\S+"#)
    /// A path ending in a known extension, optionally `file://`, `~/`, `./`,
    /// or `/`, with an optional `:line[:col]`.
    private static let barePath: NSRegularExpression = {
        let exts = MediaFormats.allExtensions.joined(separator: "|")
        let pattern = #"(?<![\w.~/\-@%+=])((?:file://)?(?:~/|\.\.?/|/)?(?:[\w@%+=~.\-]+/)*[\w@%+=~.\-]*[\w@%+=~\-]\.(?:"#
            + exts + #"))(?::\d+(?::\d+)?)?(?![\w/\-]|\.\w)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// The media files `text` refers to, in order.
    static func references(inText text: String, scope: String, context: MediaPathContext) -> [MediaRef] {
        var found: [MediaRef] = []
        // Fenced code is example code and commands more often than a product.
        var prose = blank(fence, in: text)

        for match in markdownLink.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let destRange = Range(match.range(at: 3), in: prose) else { continue }
            let isPicture = Range(match.range(at: 1), in: prose).map { !prose[$0].isEmpty } ?? false
            guard let path = MediaPaths.resolve(String(prose[destRange]), in: context, decode: true),
                  let format = MediaFormats.format(forPath: path) else { continue }
            // codeg web draws a Markdown picture only from inside the
            // session's folder (`markdown-local-image.ts`).
            if isPicture, !MediaPaths.isInside(path, folder: context.folderPath) { continue }
            found.append(MediaRef(path: path, format: format, origin: .link, scope: scope))
        }
        prose = blank(markdownLink, in: prose)

        for match in autolink.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let range = Range(match.range(at: 1), in: prose),
                  let path = MediaPaths.resolve(String(prose[range]), in: context),
                  let format = MediaFormats.format(forPath: path) else { continue }
            found.append(MediaRef(path: path, format: format, origin: .link, scope: scope))
        }
        prose = blank(autolink, in: prose)

        // A code span that is a whole path keeps its spaces.
        var wholeSpans: [NSRange] = []
        for match in codeSpan.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let range = Range(match.range(at: 1), in: prose) else { continue }
            let span = prose[range].trimmingCharacters(in: .whitespaces)
            guard span.contains(" "), !span.contains("://") || span.lowercased().hasPrefix("file:"),
                  let path = MediaPaths.resolve(span, in: context),
                  let format = MediaFormats.format(forPath: path) else { continue }
            found.append(MediaRef(path: path, format: format, origin: .mention, scope: scope))
            wholeSpans.append(match.range)
        }
        prose = blank(wholeSpans, in: prose)
        found += mentions(in: prose, origin: .mention, scope: scope, context: context)
        return dedupe(found)
    }

    /// Paths with a known extension written out in `text`.
    static func mentions(in text: String, origin: MediaRef.Origin, scope: String,
                         context: MediaPathContext) -> [MediaRef] {
        // `https://host/a.png` is a web picture, not a file on the server.
        let text = blank(webURL, in: text, keepingFileURLs: true)
        return barePath.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> MediaRef? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            var token = String(text[range])
            // Hebrew joins a prefix letter to a foreign word with a hyphen
            // ("ו-clip.mp4", "and clip.mp4"); the file is the word.
            if let prefix = token.range(of: #"^[\u05D0-\u05EA]{1,3}[-\u05BE]"#, options: .regularExpression),
               prefix.upperBound < token.endIndex {
                token.removeSubrange(prefix)
            }
            guard let path = MediaPaths.resolve(token, in: context),
                  let format = MediaFormats.format(forPath: path) else { return nil }
            return MediaRef(path: path, format: format, origin: origin, scope: scope)
        }
    }

    /// The media files a tool call wrote or named. `output` is the result's
    /// text; a call that failed names nothing.
    static func references(inToolCall name: String, input: String?, output: String?, isError: Bool,
                           scope: String, context: MediaPathContext) -> [MediaRef] {
        guard !isError else { return [] }
        switch ToolDerive.bucket(name: name, kind: "") {
        case .edit:
            return writtenPaths(input).compactMap { raw -> MediaRef? in
                guard let path = MediaPaths.resolve(raw, in: context),
                      let format = MediaFormats.format(forPath: path) else { return nil }
                return MediaRef(path: path, format: format, origin: .written, scope: scope)
            }
        case .execute:
            var refs = mentions(in: commandText(input), origin: .command, scope: scope, context: context)
            refs += printedPaths(output, scope: scope, context: context)
            return refs
        case .read, .search, .todo, .taskMgmt:
            // A Read of a picture already shows it; a search lists files.
            return []
        case .web, .task, .other:
            return printedPaths(output, scope: scope, context: context)
        }
    }

    /// What a printout names, unless it names so many that it is a listing.
    private static func printedPaths(_ output: String?, scope: String, context: MediaPathContext) -> [MediaRef] {
        guard let output, !output.isEmpty else { return [] }
        let refs = mentions(in: String(output.prefix(64 * 1024)), origin: .command, scope: scope, context: context)
        return Set(refs.map(\.path)).count > listingThreshold ? [] : refs
    }

    /// The media files of one turn: links and paths in its text, then what
    /// its tool calls wrote or named, in the order they come.
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
                found += references(inText: text, scope: turn.id, context: context)
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
