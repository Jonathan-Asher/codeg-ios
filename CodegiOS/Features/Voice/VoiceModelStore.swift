import Foundation
import CryptoKit
import Observation
import os

/// One model file BlueTTS needs, pinned to an exact revision and checksum.
/// The list mirrors `Packages/BlueTTSKit/scripts/models.sha256`.
struct VoiceModelFile: Hashable, Sendable {
    /// Path inside the model directory (the layout `BlueTTS(modelDirectory:)` reads).
    let path: String
    let sha256: String
    let url: URL
    let size: Int64
}

enum VoiceModelCatalog {
    private static let blueRev = "468da64b4a51795a7594a3637727dbaf876b6df2"
    private static let renikudRev = "679c56ca449d41873fb8ff7711ddf7563d28198f"
    private static let voicesRev = "0e38dbf08ed53f85863d1eab092bd9572c53a503"

    private static func hf(_ repo: String, _ rev: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(rev)/\(file)")!
    }

    private static func gh(_ repo: String, _ rev: String, _ file: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(rev)/\(file)")!
    }

    static let files: [VoiceModelFile] = [
        VoiceModelFile(path: "bluetts/duration_predictor_style.onnx",
                       sha256: "3d0347cfc09234b78a20d5fa50b5c402d338fb99825f40ada8c70301edbb60ea",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "duration_predictor_style.onnx"), size: 1_508_749),
        VoiceModelFile(path: "bluetts/text_encoder.onnx",
                       sha256: "f971aa25315b93efff1850b39fe293aa93ae85df69fabf5e5022318cc632973c",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "text_encoder.onnx"), size: 27_419_694),
        VoiceModelFile(path: "bluetts/vector_estimator.onnx",
                       sha256: "50557b34acfafa4b34f21dae263faa74d3f3169f114ff927599a1eff110d0b6e",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "vector_estimator.onnx"), size: 132_475_789),
        VoiceModelFile(path: "bluetts/vocoder.onnx",
                       sha256: "b0709df316ff44cc263c04fbf9d17371b16897071a48b79d3634d5f379fb3067",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "vocoder.onnx"), size: 101_411_919),
        VoiceModelFile(path: "bluetts/tts.json",
                       sha256: "862d44194197de4873eccc8bfdab1835d15f98e469a90489df6da8f92a48c7ea",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "tts.json"), size: 9_260),
        VoiceModelFile(path: "bluetts/vocab.json",
                       sha256: "13fba5e735222fcf30d9c062d898982a1ba86d481f11560fbbdf6e0af79417b3",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "vocab.json"), size: 3_157),
        VoiceModelFile(path: "bluetts/stats.npz",
                       sha256: "20d44fae010d46b859ee6238609780eb7bd5bf82320bad17b826a5dcfa4ed658",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "stats.npz"), size: 1_920),
        VoiceModelFile(path: "bluetts/uncond.npz",
                       sha256: "1c71c2b2836fd97f4c56eb21e258227650bbe0dcd906f64e2bba58e6ac09e76b",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "uncond.npz"), size: 52_732),
        VoiceModelFile(path: "renikud/model_int8.onnx",
                       sha256: "0337468fad56eadf5ecc7becfdf21648a4d668de41de5bc27e860141b5afcadd",
                       url: hf("notmax123/RenikudPlus", renikudRev, "model_int8.onnx"), size: 311_605_741),
        VoiceModelFile(path: "voices/noa.json",
                       sha256: "c233f066a7d505306892509649bc80abeb7d0a565687f143e277ec93874a47c8",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/noa.json"), size: 288_898),
        VoiceModelFile(path: "voices/adam.json",
                       sha256: "c2c7b7daf9d77aad0f76e91ad9ae634a17158a291d6920eb4eb705e522dcc0b2",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/adam.json"), size: 288_774),
        VoiceModelFile(path: "voices/daniel.json",
                       sha256: "9f5364c856383de27f5f276557b6160343125dcf80a6019e882cc90d7cbf2d84",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/daniel.json"), size: 289_020),
        VoiceModelFile(path: "voices/lily.json",
                       sha256: "b96c1b0255334e83f1a23a9fe9e599b8af44058308c64775e216fbcb8415f916",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/lily.json"), size: 289_090),
    ]

    static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }

    /// The voices shipped with the model files.
    static let voices = ["noa", "adam", "daniel", "lily"]

    static func file(forPath path: String) -> VoiceModelFile? { files.first { $0.path == path } }
}

/// Downloads the BlueTTS model files (~575 MB) into Application Support with a
/// background `URLSession`, so a download keeps going when the app is
/// suspended. Each file resumes where it stopped (resume data is kept on
/// disk), is checked against its pinned sha256, and only then moved into
/// place. A marker written after the last check lets later launches trust the
/// files without hashing 575 MB again.
@MainActor
@Observable
final class VoiceModelStore {
    static let shared = VoiceModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading
        case paused
        case verifying
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded
    /// Bytes on disk or downloaded so far, across all files.
    private(set) var bytesDone: Int64 = 0

    var progress: Double {
        VoiceModelCatalog.totalBytes > 0 ? min(1, Double(bytesDone) / Double(VoiceModelCatalog.totalBytes)) : 0
    }

    var isReady: Bool { state == .ready }

    /// Where `BlueTTS(modelDirectory:)` reads the models from.
    let modelsDirectory: URL

    static let sessionIdentifier = "io.ashurov.codeg.voice-models"

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "voice-models")
    private var session: URLSession?
    private let sessionDelegate = DownloadDelegate()
    /// Per-file bytes for files still downloading (keyed by path).
    private var inFlightBytes: [String: Int64] = [:]
    /// Files verified and in place.
    private var completed: Set<String> = []
    private var backgroundCompletion: (() -> Void)?
    private var pausing = false

    private var stagingDirectory: URL { modelsDirectory.appendingPathComponent(".staging", isDirectory: true) }
    private var resumeDirectory: URL { modelsDirectory.appendingPathComponent(".resume", isDirectory: true) }
    private var markerURL: URL { modelsDirectory.appendingPathComponent(".verified.json") }

    private init() {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        modelsDirectory = support.appendingPathComponent("BlueTTS", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        sessionDelegate.store = self
        refreshFromDisk()
        // A download started in an earlier run may still be running in the
        // background: reconnect to it.
        if UserDefaults.standard.bool(forKey: Self.activeKey) {
            state = .downloading
            reconnect()
        }
    }

    private static let activeKey = "codeg.voice.downloadActive"

    // MARK: - Disk state

    /// Recompute what is already in place (cheap: sizes + the marker).
    func refreshFromDisk() {
        let fm = FileManager.default
        completed = []
        var done: Int64 = 0
        for file in VoiceModelCatalog.files {
            let url = modelsDirectory.appendingPathComponent(file.path)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.int64Value == file.size {
                completed.insert(file.path)
                done += file.size
            }
        }
        bytesDone = done
        if completed.count == VoiceModelCatalog.files.count, markerMatches() {
            state = .ready
        } else if state == .ready {
            state = .notDownloaded
        }
    }

    private func markerMatches() -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let sums = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return VoiceModelCatalog.files.allSatisfy { sums[$0.path] == $0.sha256 }
    }

    private func writeMarker() {
        let sums = Dictionary(uniqueKeysWithValues: VoiceModelCatalog.files.map { ($0.path, $0.sha256) })
        if let data = try? JSONEncoder().encode(sums) { try? data.write(to: markerURL, options: .atomic) }
    }

    // MARK: - Download

    /// Start (or resume) the download of every missing file.
    func start() {
        guard state != .ready, state != .verifying else { return }
        pausing = false
        prepareDirectories()
        let missing = VoiceModelCatalog.files.filter { !completed.contains($0.path) }
        guard !missing.isEmpty else {
            finishIfComplete()
            return
        }
        state = .downloading
        UserDefaults.standard.set(true, forKey: Self.activeKey)
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
        UserDefaults.standard.set(false, forKey: Self.activeKey)
        session.getAllTasks { tasks in
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask, let path = download.taskDescription else {
                    task.cancel()
                    continue
                }
                download.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    Task { @MainActor in
                        if let file = VoiceModelCatalog.file(forPath: path) { self.saveResumeData(data, for: file) }
                    }
                })
            }
        }
    }

    /// Remove the models (and any partial download).
    func delete() {
        pausing = true
        session?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        UserDefaults.standard.set(false, forKey: Self.activeKey)
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
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
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
        // 575 MB that can be downloaded again: keep it out of iCloud backups.
        var root = modelsDirectory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    // MARK: - Resume data

    private func resumeURL(for file: VoiceModelFile) -> URL {
        resumeDirectory.appendingPathComponent(file.path.replacingOccurrences(of: "/", with: "__") + ".resume")
    }

    private func resumeData(for file: VoiceModelFile) -> Data? {
        try? Data(contentsOf: resumeURL(for: file))
    }

    private func saveResumeData(_ data: Data, for file: VoiceModelFile) {
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeURL(for: file), options: .atomic)
    }

    private func clearResumeData(for file: VoiceModelFile) {
        try? FileManager.default.removeItem(at: resumeURL(for: file))
    }

    // MARK: - Delegate events (main actor)

    fileprivate func didWrite(path: String, totalWritten: Int64) {
        inFlightBytes[path] = totalWritten
        let doneBytes = VoiceModelCatalog.files.filter { completed.contains($0.path) }.reduce(0) { $0 + $1.size }
        bytesDone = doneBytes + inFlightBytes.values.reduce(0, +)
        if state != .downloading, !pausing, state != .verifying { state = .downloading }
    }

    /// `staged` was moved out of the session's temporary location already.
    fileprivate func didFinish(path: String, staged: URL) {
        inFlightBytes[path] = nil
        guard let file = VoiceModelCatalog.file(forPath: path) else { return }
        let destination = modelsDirectory.appendingPathComponent(file.path)
        Task {
            let ok = await Self.verify(staged, sha256: file.sha256)
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
                fail("\(file.path) failed its checksum. Try the download again.")
                return
            }
            let doneBytes = VoiceModelCatalog.files.filter { completed.contains($0.path) }.reduce(0) { $0 + $1.size }
            bytesDone = doneBytes + inFlightBytes.values.reduce(0, +)
            finishIfComplete()
        }
    }

    fileprivate func didFail(path: String?, error: Error, resumeData: Data?) {
        if let path { inFlightBytes[path] = nil }
        if let path, let resumeData, let file = VoiceModelCatalog.file(forPath: path) {
            saveResumeData(resumeData, for: file)
        }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if pausing || cancelled { return }
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        log.error("Voice model download failed: \(message, privacy: .public)")
        UserDefaults.standard.set(false, forKey: Self.activeKey)
        state = .failed(message)
    }

    private func finishIfComplete() {
        guard completed.count == VoiceModelCatalog.files.count else { return }
        writeMarker()
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.removeItem(at: resumeDirectory)
        UserDefaults.standard.set(false, forKey: Self.activeKey)
        bytesDone = VoiceModelCatalog.totalBytes
        state = .ready
        log.info("Voice models ready")
    }

    fileprivate func sessionFinishedEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    /// From the app delegate when iOS relaunches the app for this session.
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completion()
            return
        }
        backgroundCompletion = completion
        _ = makeSession()
    }

    /// Stream the file through SHA-256 off the main actor.
    nonisolated static func verify(_ url: URL, sha256 expected: String) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = (try? handle.read(upToCount: 4 << 20)) ?? nil
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return hex == expected
        }.value
    }

    /// Where the delegate parks a finished file before it is verified.
    nonisolated func stagingURL(forPath path: String) -> URL {
        modelsDirectory.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "__") + "-\(UUID().uuidString)")
    }
}

/// The background session's delegate. Runs on the session's queue; the
/// downloaded file must be moved before `didFinishDownloadingTo` returns.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: VoiceModelStore?

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
