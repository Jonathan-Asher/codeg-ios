import CryptoKit
import Foundation

/// What the cache keeps of one conversation: the window of turns the phone
/// last held, with the identity and stats the session screen shows, so an
/// opened session draws at once and only asks the server what changed.
struct CachedTranscript: Codable, Sendable {
    static let currentVersion = 1

    var version = CachedTranscript.currentVersion
    var conversationID: Int
    var savedAt: Date
    var summary: ConversationSummary
    /// Kept apart: the summary's coding leaves it out.
    var selectorState: ConversationSelectorState?
    var sessionStats: SessionStats?
    var folder: FolderDetail?
    /// The whole transcript's `[turnsOffset ..< turnsOffset + turns.count]`.
    var turnsOffset: Int
    /// Fingerprint of the turns before `turnsOffset` (`nil` with offset 0:
    /// the whole transcript, from a server without the window protocol).
    var prefixHash: String?
    var turnsTotal: Int?
    /// Only turns that came from the server (`serverMillis` set).
    var turns: [MessageTurn]

    var window: TranscriptWindow {
        TranscriptWindow(offset: turnsOffset, prefixHash: prefixHash, total: turnsTotal, turns: turns)
    }

    /// The server's change marker for this conversation when it was saved.
    var updatedAt: Date { summary.updatedAt }
}

/// Opened conversations' transcripts on disk, in the Caches directory, one
/// file per conversation under a folder per server endpoint and token. The
/// files are bounded by a size cap with least-recently-used eviction, and a
/// server whose URL or token changes (or that is removed) loses its folder.
///
/// Everything runs on the actor, off the main thread: decoding a cached
/// window of a long, image-heavy session takes tens of milliseconds.
actor TranscriptCache {
    static let shared = TranscriptCache()

    /// Total size the cache may grow to before the least recently used
    /// conversations are removed (down to 80% of it).
    let capBytes: Int
    private let root: URL
    private let fileManager = FileManager.default
    /// Bytes written since the last size check; a full scan runs only once
    /// this passes a slice of the cap.
    private var writtenSinceScan = Int.max

    init(root: URL? = nil, capBytes: Int = 256 * 1024 * 1024) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.root = root ?? caches.appendingPathComponent("TranscriptCache", isDirectory: true)
        self.capBytes = capBytes
    }

    /// The folder name for a server endpoint and token: a hash, so neither is
    /// written to disk, and a new URL or token starts from an empty folder.
    nonisolated static func serverKey(baseURL: URL, token: String) -> String {
        let digest = SHA256.hash(data: Data("\(baseURL.absoluteString)\n\(token)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func serverKey(for client: CodegClient) -> String {
        serverKey(baseURL: client.baseURL, token: client.token)
    }

    // MARK: - Coding

    /// No key conversion either way: the models' `init(from:)` read the
    /// camelCase keys the server decoder produces, and are written that way.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let millis = TranscriptTime.millis(raw) {
                return Date(timeIntervalSince1970: Double(millis) / 1000)
            }
            if let date = ISO8601.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(raw)")
        }
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TranscriptTime.string(date: date))
        }
        return e
    }()

    // MARK: - Files

    private func folder(serverKey: String) -> URL {
        root.appendingPathComponent(serverKey, isDirectory: true)
    }

    private func file(serverKey: String, conversationID: Int) -> URL {
        folder(serverKey: serverKey).appendingPathComponent("\(conversationID).json")
    }

    func contains(serverKey: String, conversationID: Int) -> Bool {
        fileManager.fileExists(atPath: file(serverKey: serverKey, conversationID: conversationID).path)
    }

    /// The cached transcript, or `nil` (none, unreadable, or another format
    /// version, which is then removed). Reading it marks it recently used.
    func load(serverKey: String, conversationID: Int) -> CachedTranscript? {
        let url = file(serverKey: serverKey, conversationID: conversationID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? Self.decoder.decode(CachedTranscript.self, from: data),
              entry.version == CachedTranscript.currentVersion,
              entry.conversationID == conversationID
        else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry
    }

    /// Write `entry`, replacing what was there, then trim the cache to its cap.
    func save(_ entry: CachedTranscript, serverKey: String) {
        var entry = entry
        // Never keep a turn the phone made up: the window's fingerprint only
        // covers the server's turns.
        let serverCount = entry.turns.firstIndex(where: { $0.serverMillis == nil }) ?? entry.turns.count
        if serverCount < entry.turns.count { entry.turns = Array(entry.turns[..<serverCount]) }
        guard let data = try? Self.encoder.encode(entry) else { return }
        let dir = folder(serverKey: serverKey)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file(serverKey: serverKey, conversationID: entry.conversationID), options: .atomic)
        } catch {
            return
        }
        if writtenSinceScan != Int.max { writtenSinceScan += data.count }
        if writtenSinceScan == Int.max || writtenSinceScan > capBytes / 10 {
            writtenSinceScan = 0
            evictIfNeeded()
        }
    }

    func remove(serverKey: String, conversationID: Int) {
        try? fileManager.removeItem(at: file(serverKey: serverKey, conversationID: conversationID))
    }

    /// Remove every server folder except `keep` (the saved servers' current
    /// endpoint and token keys).
    func removeServers(except keep: Set<String>) {
        guard let dirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs where !keep.contains(dir.lastPathComponent) {
            try? fileManager.removeItem(at: dir)
        }
    }

    func removeAll() {
        try? fileManager.removeItem(at: root)
    }

    /// Total bytes on disk (tests, diagnostics).
    func totalBytes() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    private struct FileEntry {
        let url: URL
        let size: Int
        let used: Date
    }

    private func entries() -> [FileEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [FileEntry] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            out.append(FileEntry(url: url, size: values.fileSize ?? 0,
                                 used: values.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Least recently used first, until the cache is at 80% of its cap.
    private func evictIfNeeded() {
        var files = entries()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > capBytes else { return }
        files.sort { $0.used < $1.used }
        let target = capBytes / 10 * 8
        for file in files {
            guard total > target else { break }
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
