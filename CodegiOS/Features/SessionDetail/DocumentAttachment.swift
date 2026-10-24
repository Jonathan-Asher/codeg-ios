import Foundation
import UniformTypeIdentifiers

// MARK: - Where a file from Files goes

/// Where a file picked in Files goes. A picture rides in the prompt itself; a
/// video, an audio file and any other file (a PDF, a Word or text file, a
/// spreadsheet, code, an archive…) is uploaded to codeg and linked from the
/// prompt, as codeg web attaches a file that isn't a picture. A folder or a
/// package can't be sent as one file.
enum PickedFileRoute: Equatable, Sendable {
    case picture
    case upload(AttachmentKind)
    case folder
    case package

    /// What the Files picker offers: every regular file. A folder or a package
    /// isn't `public.data`, so it stays greyed out.
    static let importableTypes: [UTType] = [.image, .movie, .audio, .pdf, .data]

    /// By the file's type, read from its name.
    static func route(forFileNamed name: String) -> PickedFileRoute {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return .picture
        }
        return .upload(AttachmentKind(forFileNamed: name))
    }

    /// A picked file: a folder or a package first (asked of the file system,
    /// inside the picker's security scope), then by its type.
    static func route(for url: URL) -> PickedFileRoute {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isPackage == true { return .package }
        if values?.isDirectory == true { return .folder }
        return route(forFileNamed: url.lastPathComponent)
    }

    /// Why a folder or a package wasn't attached; nil for a file.
    func notice(forFileNamed name: String) -> String? {
        switch self {
        case .folder: return String(localized: "\(name) is a folder. Attach the files in it instead.")
        case .package: return String(localized: "\(name) is a package, not a single file, so it can't be attached.")
        case .picture, .upload: return nil
        }
    }
}

/// What an uploaded attachment is: a video, an audio file, or any other file.
enum AttachmentKind: Sendable, Equatable {
    case video
    case audio
    /// A PDF, a Word or text file, a spreadsheet, code, an archive: uploaded
    /// as it is, never compressed.
    case document

    /// Extensions whose type the iPhone reads as media that are code far more
    /// often in a coding session: `.ts` is TypeScript before it is an MPEG
    /// transport stream.
    static let codeExtensions: Set<String> = ["ts", "mts", "cts"]

    /// By the file's name: the app's own media formats (the ones the
    /// transcript plays), then the system's type, then a document.
    init(forFileNamed name: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !Self.codeExtensions.contains(ext) else {
            self = .document
            return
        }
        switch MediaFormats.format(forExtension: ext)?.kind {
        case .video?:
            self = .video
            return
        case .audio?:
            self = .audio
            return
        default:
            break
        }
        guard let type = UTType(filenameExtension: ext) else {
            self = .document
            return
        }
        if type.conforms(to: .audio), !type.conforms(to: .movie) {
            self = .audio
        } else if type.conforms(to: .movie) {
            self = .video
        } else {
            self = .document
        }
    }
}

// MARK: - Preparing a document

/// Why a document can't go as it is. Said as a notice, and its chip goes:
/// trying again wouldn't help.
enum DocumentAttachmentError: LocalizedError, Equatable {
    /// Over the server's limit for a file that isn't video or audio
    /// (`max_file_bytes`, 20 MiB; 20 MiB on a server that doesn't say).
    case tooLarge(name: String, size: Int64, limit: Int64)
    case empty(name: String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let size, let limit):
            // codeg counts its limits in binary megabytes, so the size is
            // counted the same way.
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
            let shown = ByteCountFormatter.string(fromByteCount: size, countStyle: .memory)
            if shown == cap {
                return String(localized: "\(name) is over \(cap); codeg takes documents up to \(cap).")
            }
            return String(localized: "\(name) is \(shown); codeg takes documents up to \(cap).")
        case .empty(let name):
            return String(localized: "\(name) is empty, so it wasn't attached.")
        }
    }
}

/// A document from Files goes as it is, within the server's limit for files
/// that aren't video or audio. Its type is the one codeg web gives the same
/// name (`MIME_BY_EXT` in `attachment-files.ts`), or the system's.
enum DocumentAttachmentPrep {
    /// codeg web's table, and the office formats.
    private static let knownTypes: [String: String] = [
        "txt": "text/plain",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "json": "application/json",
        "yaml": "application/yaml",
        "yml": "application/yaml",
        "csv": "text/csv",
        "html": "text/html",
        "css": "text/css",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "cjs": "text/javascript",
        "ts": "text/typescript",
        "tsx": "text/tsx",
        "jsx": "text/jsx",
        "py": "text/x-python",
        "rs": "text/rust",
        "go": "text/x-go",
        "java": "text/x-java-source",
        "xml": "application/xml",
        "toml": "application/toml",
        "pdf": "application/pdf",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "pages": "application/vnd.apple.pages",
        "numbers": "application/vnd.apple.numbers",
        "key": "application/vnd.apple.keynote",
        "rtf": "text/rtf",
        "zip": "application/zip",
    ]

    static func mimeType(forFileNamed name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "application/octet-stream" }
        if let known = knownTypes[ext] { return known }
        if let type = UTType(filenameExtension: ext) {
            if let mime = type.preferredMIMEType { return mime }
            if type.conforms(to: .text) { return "text/plain" }
        }
        return "application/octet-stream"
    }

    /// The symbol of a document, as its card in the message shows it.
    static func symbol(forFileNamed name: String) -> String {
        (name as NSString).pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
    }

    /// "PDF document", "Plain text", in the system's words.
    static func typeDescription(forFileNamed name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let text = UTType(filenameExtension: ext)?.localizedDescription, !text.isEmpty {
            return text
        }
        return String(localized: "Document")
    }

    static func prepare(_ file: URL, maxBytes: Int64) throws -> PreparedMedia {
        let name = file.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw VideoAttachmentError.unreadable }
        let size = VideoAttachmentPrep.size(of: file)
        guard size > 0 else { throw DocumentAttachmentError.empty(name: name) }
        guard size <= maxBytes else { throw DocumentAttachmentError.tooLarge(name: name, size: size, limit: maxBytes) }
        return PreparedMedia(url: file, name: name, mimeType: mimeType(forFileNamed: name), size: size,
                             duration: nil, poster: nil, note: typeDescription(forFileNamed: name))
    }
}
