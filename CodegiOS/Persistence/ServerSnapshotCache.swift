import CryptoKit
import Foundation

// MARK: - Protected files

/// How saved session content reaches the disk. These are attorney-client
/// conversations: in the app (``ProtectedFiles``) every file and folder gets
/// complete file protection, and iOS keeps it unreadable from about 10
/// seconds after the phone locks until it is unlocked. Nothing reads them
/// while the phone is locked: the app has no background tasks, and
/// read-aloud speaks from memory. The tests record what was asked for, since
/// a simulator doesn't apply protection.
protocol SavedFileStore: Sendable {
    /// Write `data` to `url` atomically and protected, making its folder
    /// (protected too, like any folder made up to it) first.
    func write(_ data: Data, to url: URL) throws
    /// Give a file or folder that exists complete protection.
    func protect(_ url: URL)
    /// The protection a file or folder has, when the platform reports one.
    func protection(of url: URL) -> FileProtectionType?
}

extension SavedFileStore {
    /// Give every folder and file under `root` complete protection: what an
    /// earlier version saved had the default. Best effort.
    func protectTree(at root: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        var items = [root]
        if let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { items.append(url) }
        }
        for url in items where protection(of: url) != ProtectedFiles.protection {
            protect(url)
        }
    }
}

/// The app's file store: complete protection on every file and folder.
struct ProtectedFiles: SavedFileStore {
    static let protection = FileProtectionType.complete
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    static var folderAttributes: [FileAttributeKey: Any] { [.protectionKey: protection] }

    func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: Self.folderAttributes)
        }
        try data.write(to: url, options: Self.writeOptions)
    }

    func protect(_ url: URL) {
        try? FileManager.default.setAttributes(Self.folderAttributes, ofItemAtPath: url.path)
    }

    func protection(of url: URL) -> FileProtectionType? {
        let value = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey]
        if let type = value as? FileProtectionType { return type }
        if let raw = value as? String { return FileProtectionType(rawValue: raw) }
        return nil
    }
}

// MARK: - The session lists

/// The session lists as a server last gave them (`ServerSnapshotLoad`), so
/// the Chats, Folders and Activity tabs show them when the phone opens
/// offline, marked with their age.
struct SavedServerSnapshot: Codable, Sendable {
    static let currentVersion = 1

    var version = SavedServerSnapshot.currentVersion
    var folders: [FolderDetail]
    /// Nil until the open-folder list has loaded once.
    var openFolders: [FolderDetail]?
    var conversations: [ConversationSummary]
    var groups: [FolderGroupDetail]
    /// What each session waits on (`list_conversation_attention`).
    var attention: [Int: String]?
    /// When the server last gave these lists: the file's modification date,
    /// not stored in it.
    var savedAt = Date.distantPast

    private enum CodingKeys: String, CodingKey {
        case version, folders, openFolders, conversations, groups, attention
    }
}

/// One file per server, `lists.json` in the server's folder of
/// ``TranscriptCache`` (so removing a server, or changing its URL or token,
/// removes its lists with its transcripts). Written after every load that
/// brought the conversation list; when nothing changed only the file's date
/// moves, so the 25-second pulse doesn't rewrite it. Capped at 2 MB: a
/// larger list is saved without its least recently updated sessions.
actor ServerSnapshotCache {
    static let shared = ServerSnapshotCache()
    static let fileName = "lists.json"

    let capBytes: Int
    private let root: URL
    private let files: any SavedFileStore
    private let fileManager = FileManager.default
    /// What was last written per server.
    private var lastDigests: [String: SHA256Digest] = [:]

    init(root: URL? = nil, capBytes: Int = 2 * 1024 * 1024, files: any SavedFileStore = ProtectedFiles()) {
        self.root = root ?? TranscriptCache.defaultRoot
        self.capBytes = capBytes
        self.files = files
    }

    /// The transcript cache's coding, with sorted keys: the same lists
    /// always encode to the same bytes (a keyed container's order otherwise
    /// varies between encodes), so unchanged lists are recognised.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TranscriptTime.string(date: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    func file(serverKey: String) -> URL {
        root.appendingPathComponent(serverKey, isDirectory: true).appendingPathComponent(Self.fileName)
    }

    /// The saved lists, or nil (none, unreadable, or another format version,
    /// which is then removed).
    func load(serverKey: String) -> SavedServerSnapshot? {
        let url = file(serverKey: serverKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var snapshot = try? TranscriptCache.decoder.decode(SavedServerSnapshot.self, from: data),
              snapshot.version == SavedServerSnapshot.currentVersion
        else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        snapshot.savedAt = values?.contentModificationDate ?? .distantPast
        return snapshot
    }

    /// Save `snapshot` as the server's lists as of `date`. Returns whether
    /// they are on disk.
    @discardableResult
    func save(_ snapshot: SavedServerSnapshot, serverKey: String, at date: Date = Date()) -> Bool {
        guard var data = try? Self.encoder.encode(snapshot) else { return false }
        if data.count > capBytes {
            guard let smaller = trimmed(snapshot) else { return false }
            data = smaller
        }
        let url = file(serverKey: serverKey)
        let digest = SHA256.hash(data: data)
        if lastDigests[serverKey] != digest || !fileManager.fileExists(atPath: url.path) {
            do {
                try files.write(data, to: url)
            } catch {
                return false
            }
            lastDigests[serverKey] = digest
        }
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return true
    }

    func remove(serverKey: String) {
        lastDigests[serverKey] = nil
        try? fileManager.removeItem(at: file(serverKey: serverKey))
    }

    /// The snapshot without its least recently updated sessions (pinned ones
    /// go last), encoded within the cap; nil if it can't be.
    private func trimmed(_ snapshot: SavedServerSnapshot) -> Data? {
        var kept = snapshot.conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
        while kept.count > 1 {
            kept = Array(kept.prefix(kept.count * 3 / 4))
            var smaller = snapshot
            smaller.conversations = kept
            if let data = try? Self.encoder.encode(smaller), data.count <= capBytes { return data }
        }
        return nil
    }
}
