import Foundation
import CryptoKit
import Observation
import os

/// One model file, pinned to an exact URL, size and checksum.
struct ModelPackFile: Hashable, Sendable {
    /// Path inside the pack's directory.
    let path: String
    let sha256: String
    let url: URL
    let size: Int64
}

/// A set of model files that download together into one directory, with
/// their own background `URLSession`.
struct ModelPack: Sendable {
    /// Short id, used in logs.
    let id: String
    let files: [ModelPackFile]
    /// Where the files end up.
    let directory: URL
    /// The background `URLSession` identifier (stable across launches).
    let sessionIdentifier: String
    /// UserDefaults key remembering that a download was running.
    let activeKey: String

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func file(forPath path: String) -> ModelPackFile? { files.first { $0.path == path } }

    /// `Application Support/<components…>`.
    static func applicationSupport(_ components: String...) -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return components.reduce(support) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Stream a file through SHA-256 and compare with `expected` (lowercase hex).
    static func sha256Matches(_ url: URL, expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 4 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == expected.lowercased()
    }
}

/// Downloads a ``ModelPack`` into Application Support with a background
/// `URLSession`, so a download keeps going when the app is suspended. Each
/// file resumes where it stopped (resume data is kept on disk), is checked
/// against its pinned sha256, and only then moved into place. A marker written
/// after the last check lets later launches trust the files without hashing
/// them again.
@MainActor
@Observable
final class ModelPackStore {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case paused
        case verifying
        case ready
        case failed(String)
    }

    let pack: ModelPack

    private(set) var state: State = .notDownloaded
    /// Bytes on disk or downloaded so far, across all files.
    private(set) var bytesDone: Int64 = 0

    var progress: Double {
        pack.totalBytes > 0 ? min(1, Double(bytesDone) / Double(pack.totalBytes)) : 0
    }

    var isReady: Bool { state == .ready }

    var modelsDirectory: URL { pack.directory }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "model-download")
    private var session: URLSession?
    private let sessionDelegate = ModelPackDownloadDelegate()
    /// Per-file bytes for files still downloading (keyed by path).
    private var inFlightBytes: [String: Int64] = [:]
    /// Files verified and in place.
    private var completed: Set<String> = []
    /// Files being hashed right now.
    private var verifying: Set<String> = []
    private var backgroundCompletion: (() -> Void)?
    private var pausing = false

    private var stagingDirectory: URL { modelsDirectory.appendingPathComponent(".staging", isDirectory: true) }
    private var resumeDirectory: URL { modelsDirectory.appendingPathComponent(".resume", isDirectory: true) }
    private var markerURL: URL { modelsDirectory.appendingPathComponent(".verified.json") }

    init(pack: ModelPack) {
        self.pack = pack
        sessionDelegate.store = self
        refreshFromDisk()
        // A download started in an earlier run may still be running in the
        // background: reconnect to it.
        if UserDefaults.standard.bool(forKey: pack.activeKey) {
            state = .downloading
            reconnect()
        }
    }

    /// Local path of a file in the pack.
    func url(forPath path: String) -> URL { modelsDirectory.appendingPathComponent(path) }

    // MARK: - Disk state

    /// Recompute what is already in place (cheap: sizes + the marker).
    func refreshFromDisk() {
        let fm = FileManager.default
        completed = []
        var done: Int64 = 0
        for file in pack.files {
            let url = modelsDirectory.appendingPathComponent(file.path)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.int64Value == file.size {
                completed.insert(file.path)
                done += file.size
            }
        }
        bytesDone = done
        if completed.count == pack.files.count, markerMatches() {
            state = .ready
        } else if state == .ready {
            state = .notDownloaded
        }
    }

    private func markerMatches() -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let sums = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return pack.files.allSatisfy { sums[$0.path] == $0.sha256 }
    }

    private func writeMarker() {
        let sums = Dictionary(uniqueKeysWithValues: pack.files.map { ($0.path, $0.sha256) })
        if let data = try? JSONEncoder().encode(sums) { try? data.write(to: markerURL, options: .atomic) }
    }

    // MARK: - Download

    /// Start (or resume) the download of every missing file.
    func start() {
        guard state != .ready, state != .verifying else { return }
        pausing = false
        prepareDirectories()
        let missing = pack.files.filter { !completed.contains($0.path) && !verifying.contains($0.path) }
        guard !missing.isEmpty else {
            finishIfComplete()
            return
        }
        state = .downloading
        UserDefaults.standard.set(true, forKey: pack.activeKey)
        let session = makeSession()
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for file in missing where !running.contains(file.path) {
                    let task: URLSessionDownloadTask
                    if let resume = self.resumeData(for: file) {
                        task = session.downloadTask(withResumeData: resume)
                        self.clearResumeData(for: file)
                    } else {
                        task = session.downloadTask(with: file.url)
                    }
                    task.taskDescription = file.path
                    task.countOfBytesClientExpectsToReceive = file.size
                    task.resume()
                }
            }
        }
    }

    /// Stop for now, keeping what was downloaded so `start()` resumes it.
    func pause() {
        guard state == .downloading, let session else { return }
        pausing = true
        state = .paused
        UserDefaults.standard.set(false, forKey: pack.activeKey)
        session.getAllTasks { tasks in
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask, let path = download.taskDescription else {
                    task.cancel()
                    continue
                }
                download.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    Task { @MainActor in
                        if let file = self.pack.file(forPath: path) { self.saveResumeData(data, for: file) }
                    }
                })
            }
        }
    }

    /// Remove the models (and any partial download).
    func delete() {
        pausing = true
        session?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        UserDefaults.standard.set(false, forKey: pack.activeKey)
        try? FileManager.default.removeItem(at: modelsDirectory)
        inFlightBytes = [:]
        refreshFromDisk()
        state = .notDownloaded
    }

    private func reconnect() {
        let session = makeSession()
        session.getAllTasks { tasks in
            let count = tasks.count
            Task { @MainActor in
                if count == 0 {
                    // Nothing running (finished or lost while the app was gone).
                    self.refreshFromDisk()
                    if self.state != .ready { self.start() }
                }
            }
        }
    }

    private func makeSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.background(withIdentifier: pack.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 3
        let session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        self.session = session
        return session
    }

    private func prepareDirectories() {
        let fm = FileManager.default
        for dir in [modelsDirectory, stagingDirectory, resumeDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Large files that can be downloaded again: keep them out of iCloud backups.
        var root = modelsDirectory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    // MARK: - Resume data

    private func resumeURL(for file: ModelPackFile) -> URL {
        resumeDirectory.appendingPathComponent(file.path.replacingOccurrences(of: "/", with: "__") + ".resume")
    }

    private func resumeData(for file: ModelPackFile) -> Data? {
        try? Data(contentsOf: resumeURL(for: file))
    }

    private func saveResumeData(_ data: Data, for file: ModelPackFile) {
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeURL(for: file), options: .atomic)
    }

    private func clearResumeData(for file: ModelPackFile) {
        try? FileManager.default.removeItem(at: resumeURL(for: file))
    }

    // MARK: - Delegate events (main actor)

    private func recountBytes() {
        let doneBytes = pack.files.filter { completed.contains($0.path) }.reduce(0) { $0 + $1.size }
        bytesDone = doneBytes + inFlightBytes.values.reduce(0, +)
    }

    fileprivate func didWrite(path: String, totalWritten: Int64) {
        inFlightBytes[path] = totalWritten
        recountBytes()
        if state != .downloading, !pausing, state != .verifying { state = .downloading }
    }

    /// `staged` was moved out of the session's temporary location already.
    fileprivate func didFinish(path: String, staged: URL) {
        guard let file = pack.file(forPath: path) else { return }
        // Count the file as downloaded while it is hashed.
        inFlightBytes[path] = file.size
        verifying.insert(path)
        recountBytes()
        let destination = modelsDirectory.appendingPathComponent(file.path)
        Task {
            let ok = await Self.verify(staged, sha256: file.sha256)
            verifying.remove(path)
            inFlightBytes[path] = nil
            if ok {
                let fm = FileManager.default
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                do {
                    try fm.moveItem(at: staged, to: destination)
                    completed.insert(file.path)
                    clearResumeData(for: file)
                } catch {
                    fail("Couldn't save \(file.path): \(error.localizedDescription)")
                    return
                }
            } else {
                try? FileManager.default.removeItem(at: staged)
                clearResumeData(for: file)
                recountBytes()
                fail("\(file.path) failed its checksum. Try the download again.")
                return
            }
            recountBytes()
            finishIfComplete()
        }
    }

    fileprivate func didFail(path: String?, error: Error, resumeData: Data?) {
        if let path { inFlightBytes[path] = nil }
        if let path, let resumeData, let file = pack.file(forPath: path) {
            saveResumeData(resumeData, for: file)
        }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if pausing || cancelled { return }
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        log.error("Model download (\(self.pack.id, privacy: .public)) failed: \(message, privacy: .public)")
        UserDefaults.standard.set(false, forKey: pack.activeKey)
        state = .failed(message)
    }

    private func finishIfComplete() {
        guard completed.count == pack.files.count else { return }
        writeMarker()
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.removeItem(at: resumeDirectory)
        UserDefaults.standard.set(false, forKey: pack.activeKey)
        bytesDone = pack.totalBytes
        state = .ready
        log.info("Models ready: \(self.pack.id, privacy: .public)")
    }

    fileprivate func sessionFinishedEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    /// From the app delegate when iOS relaunches the app for this pack's session.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = makeSession()
    }

    /// Stream the file through SHA-256 off the main actor.
    nonisolated static func verify(_ url: URL, sha256 expected: String) async -> Bool {
        await Task.detached(priority: .utility) {
            ModelPack.sha256Matches(url, expected: expected)
        }.value
    }

    /// Where the delegate parks a finished file before it is verified.
    nonisolated func stagingURL(forPath path: String) -> URL {
        pack.directory.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "__") + "-\(UUID().uuidString)")
    }
}

/// The background session's delegate. Runs on the session's queue; the
/// downloaded file must be moved before `didFinishDownloadingTo` returns.
private final class ModelPackDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: ModelPackStore?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let path = downloadTask.taskDescription, let store else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(path)"])
            Task { @MainActor in store.didFail(path: path, error: error, resumeData: nil) }
            return
        }
        let staged = store.stagingURL(forPath: path)
        do {
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            Task { @MainActor in store.didFail(path: path, error: error, resumeData: nil) }
            return
        }
        Task { @MainActor in store.didFinish(path: path, staged: staged) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let path = downloadTask.taskDescription, let store else { return }
        Task { @MainActor in store.didWrite(path: path, totalWritten: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let store else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let path = task.taskDescription
        Task { @MainActor in store.didFail(path: path, error: error, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let store else { return }
        Task { @MainActor in store.sessionFinishedEvents() }
    }
}
