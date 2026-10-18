import CryptoKit
import Foundation

/// Files fetched from the server for showing (pictures, audio from a server
/// that streams only video, documents, video posters), in the Caches folder,
/// least recently used first out above ``limit``. Videos are never kept: they
/// stream, and AVPlayer holds only what it buffers.
final class MediaDiskCache: @unchecked Sendable {
    static let shared = MediaDiskCache(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Media", isDirectory: true))

    let directory: URL
    let limit: Int64
    private let lock = NSLock()

    init(directory: URL, limit: Int64 = 256 * 1024 * 1024) {
        self.directory = directory
        self.limit = limit
    }

    /// A short, file-name-safe name for `key`, keeping `ext` so Quick Look and
    /// AVFoundation can tell the type.
    static func fileName(for key: String, ext: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return ext.isEmpty ? digest : "\(digest).\(ext)"
    }

    /// The cached file for `key`, marked as just used.
    func lookup(_ key: String, ext: String) -> URL? {
        let url = directory.appendingPathComponent(Self.fileName(for: key, ext: ext))
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Move the file at `source` into the cache under `key`.
    @discardableResult
    func store(fileAt source: URL, key: String, ext: String) throws -> URL {
        let url = directory.appendingPathComponent(Self.fileName(for: key, ext: ext))
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: source, to: url)
        trimLocked()
        return url
    }

    /// Write `data` into the cache under `key`.
    @discardableResult
    func store(_ data: Data, key: String, ext: String) throws -> URL {
        let url = directory.appendingPathComponent(Self.fileName(for: key, ext: ext))
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        trimLocked()
        return url
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The cache's total size.
    var size: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries().reduce(0) { $0 + $1.size }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let used: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url, size: Int64(values.fileSize ?? 0), used: values.contentModificationDate ?? .distantPast)
        }
    }

    private func trimLocked() {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        all.sort { $0.used < $1.used }
        for entry in all where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
