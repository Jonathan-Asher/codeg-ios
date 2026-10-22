import Foundation
import Observation

/// Lists one server directory (`list_directory_with_files`).
protocol MediaDirectoryListing: Sendable {
    func listDirectoryWithFiles(path: String) async throws -> [DirectoryItem]
}

/// Whether the files a session refers to are on the server, so the
/// transcript shows a card only for a file that is there.
///
/// A message's files are checked once, before their cards show. A server with
/// `stat_paths` (codeg fork.191) answers up to 200 of them in one request,
/// each under the roots the session gives (its folder, the home for a path in
/// it, the `cd` a command opened with). A path outside those roots, and every
/// path on an older server, is checked as before: one
/// `list_directory_with_files` per directory, shared by every file in it,
/// however many messages name them. The answer is kept per path, for
/// ``presentLifetime`` when the file is there and ``missingLifetime`` when it
/// isn't, so a file the agent makes later is seen once it is there. A server
/// that can't answer (an older codeg, the network) leaves the cards to find
/// out for themselves, as before.
@MainActor
@Observable
final class MediaPresence {
    enum State: Equatable, Sendable {
        /// On the server, with its size when the answer gave one.
        case present(size: Int64?)
        /// Not there: the directory has no such file, or there is no such directory.
        case missing
        /// The server couldn't say (an older server, the network): show the card.
        case unverified
    }

    /// Bumped when an answer arrives, so the transcript rebuilds its cards.
    private(set) var version = 0

    @ObservationIgnored private var entries: [String: (state: State, at: Date)] = [:]
    /// The roots each path was asked with, for asking again when it is stale.
    @ObservationIgnored private var rootsByPath: [String: [String]] = [:]
    @ObservationIgnored private var queued: [String: [String]] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var flushing = 0
    @ObservationIgnored private var inFlight: [String: Task<Result<[DirectoryItem], Error>, Never>] = [:]
    @ObservationIgnored private var statting: Set<String> = []
    @ObservationIgnored private let lister: any MediaDirectoryListing
    @ObservationIgnored private let statter: (any MediaPathStatting)?
    /// The server answered that it has no `stat_paths`: list directories.
    @ObservationIgnored private(set) var statUnsupported = false
    @ObservationIgnored private let now: () -> Date

    static let presentLifetime: TimeInterval = 10 * 60
    static let missingLifetime: TimeInterval = 30
    static let unverifiedLifetime: TimeInterval = 60
    /// Paths and roots per `stat_paths` request (the server's caps).
    static let statBatchPaths = 200
    static let statBatchRoots = 32

    init(lister: any MediaDirectoryListing, statter: (any MediaPathStatting)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.lister = lister
        self.statter = statter
        self.now = now
    }

    /// What is known about `path`, nil when it hasn't been checked. A stale
    /// answer is still given (so a card doesn't blink) and checked again.
    func state(of path: String) -> State? {
        guard let entry = entries[path] else { return nil }
        if isStale(entry) { enqueue(path, roots: rootsByPath[path] ?? []) }
        return entry.state
    }

    /// Check `path` soon, under `roots` (the folders `stat_paths` may look
    /// in). Called while the transcript builds, so the check starts after the
    /// current update rather than inside it.
    func enqueue(_ path: String, roots: [String] = []) {
        var known = queued[path] ?? rootsByPath[path] ?? []
        for root in roots where !known.contains(root) { known.append(root) }
        queued[path] = known
        rootsByPath[path] = known
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            await self?.flush()
        }
    }

    /// The roots the session gives `ref`: its folder, the home when the file
    /// is in it, and the `cd` it was found under.
    static func roots(for ref: MediaRef, context: MediaPathContext) -> [String] {
        var roots: [String] = []
        func add(_ root: String?) {
            guard let root, root.hasPrefix("/"), let normal = MediaPaths.normalize(root) else { return }
            if !roots.contains(normal) { roots.append(normal) }
        }
        add(context.folderPath)
        if let home = context.homePath.flatMap(MediaPaths.normalize), home.hasPrefix("/"),
           ref.path.hasPrefix(home == "/" ? "/" : home + "/") {
            add(home)
        }
        add(ref.base)
        return roots
    }

    /// Check every queued path now: `stat_paths` in batches where the server
    /// has it, one listing per directory for the rest.
    func flush() async {
        flushScheduled = false
        let batch = queued.filter { !statting.contains($0.key) }
        queued = [:]
        guard !batch.isEmpty else { return }
        flushing += 1
        defer { flushing -= 1 }

        var toList = Array(batch.keys)
        if let statter, !statUnsupported {
            toList = await stat(batch, with: statter)
        }
        await list(toList)
        version &+= 1
    }

    /// Wait until every queued check has an answer (tests, the live check).
    func settle() async {
        while flushScheduled || !queued.isEmpty || flushing > 0 {
            if !queued.isEmpty { await flush() } else { await Task.yield() }
        }
    }

    /// Forget every answer (a different server, the user pulled to refresh).
    func reset() {
        entries = [:]
        version &+= 1
    }

    // MARK: Private

    private func isStale(_ entry: (state: State, at: Date)) -> Bool {
        let age = now().timeIntervalSince(entry.at)
        switch entry.state {
        case .present: return age > Self.presentLifetime
        case .missing: return age > Self.missingLifetime
        case .unverified: return age > Self.unverifiedLifetime
        }
    }

    // MARK: stat_paths

    /// Paths in requests of at most ``statBatchPaths`` paths and
    /// ``statBatchRoots`` roots.
    static func statBatches(_ paths: [String: [String]]) -> [(paths: [String], roots: [String])] {
        var batches: [(paths: [String], roots: [String])] = []
        var current: (paths: [String], roots: [String]) = ([], [])
        for path in paths.keys.sorted() {
            let wanted = (paths[path] ?? []).filter { !current.roots.contains($0) }
            if !current.paths.isEmpty,
               current.paths.count >= statBatchPaths || current.roots.count + wanted.count > statBatchRoots {
                batches.append(current)
                current = ([], [])
            }
            current.paths.append(path)
            for root in paths[path] ?? [] where !current.roots.contains(root) && current.roots.count < statBatchRoots {
                current.roots.append(root)
            }
        }
        if !current.paths.isEmpty { batches.append(current) }
        return batches
    }

    /// Stat `batch`; the paths it couldn't answer are returned for listing.
    private func stat(_ batch: [String: [String]], with statter: any MediaPathStatting) async -> [String] {
        let requests = Self.statBatches(batch)
        statting.formUnion(batch.keys)
        defer { statting.subtract(batch.keys) }
        var leftover: [String] = []
        await withTaskGroup(of: (paths: [String], result: Result<[PathStat], Error>).self) { group in
            for request in requests {
                group.addTask {
                    do { return (request.paths, .success(try await statter.statPaths(request.paths, roots: request.roots))) }
                    catch { return (request.paths, .failure(error)) }
                }
            }
            for await (paths, result) in group {
                leftover += record(result, paths: paths)
            }
        }
        return leftover
    }

    /// Record a `stat_paths` answer; returns the paths it didn't settle.
    private func record(_ result: Result<[PathStat], Error>, paths: [String]) -> [String] {
        switch result {
        case .failure(let error):
            if Self.isUnsupported(error) { statUnsupported = true }
            return paths
        case .success(let answers):
            let stamp = now()
            var leftover: [String] = []
            for (index, path) in paths.enumerated() {
                guard index < answers.count, answers[index].path == path else {
                    leftover.append(path)
                    continue
                }
                let answer = answers[index]
                if !answer.allowed {
                    // Outside the roots the session gives (an absolute path
                    // elsewhere, a link leading out of them): list its
                    // directory, as every path was checked before.
                    if answer.reason == "invalidPath" {
                        entries[path] = (.unverified, stamp)
                    } else {
                        leftover.append(path)
                    }
                } else if answer.exists == true {
                    entries[path] = (answer.isFile == true ? .present(size: answer.size) : .missing, stamp)
                } else if answer.exists == false {
                    entries[path] = (.missing, stamp)
                } else {
                    entries[path] = (.unverified, stamp)
                }
            }
            return leftover
        }
    }

    /// An older codeg answers 501 for an endpoint it doesn't have; a proxy may say 404.
    static func isUnsupported(_ error: Error) -> Bool {
        if case .server(let status, _, _)? = error as? APIError { return status == 404 || status == 501 || status == 405 }
        if case .unsupportedServer? = error as? MediaError { return true }
        return false
    }

    // MARK: Directory listings

    private func list(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        var byDirectory: [String: [String]] = [:]
        for path in paths {
            let directory = (path as NSString).deletingLastPathComponent
            byDirectory[directory.isEmpty ? "/" : directory, default: []].append(path)
        }
        await withTaskGroup(of: (String, Result<[DirectoryItem], Error>).self) { group in
            for directory in byDirectory.keys {
                let task = listing(of: directory)
                group.addTask { (directory, await task.value) }
            }
            for await (directory, result) in group {
                record(result, paths: byDirectory[directory] ?? [])
            }
        }
    }

    /// One request per directory at a time, shared by whoever asks.
    private func listing(of directory: String) -> Task<Result<[DirectoryItem], Error>, Never> {
        if let running = inFlight[directory] { return running }
        let lister = self.lister
        let task = Task<Result<[DirectoryItem], Error>, Never> {
            do { return .success(try await lister.listDirectoryWithFiles(path: directory)) }
            catch { return .failure(error) }
        }
        inFlight[directory] = task
        Task { @MainActor [weak self] in
            _ = await task.value
            self?.inFlight[directory] = nil
        }
        return task
    }

    private func record(_ result: Result<[DirectoryItem], Error>, paths: [String]) {
        let stamp = now()
        switch result {
        case .success(let items):
            // Hidden names (`.review/…` lists, a dotfile) aren't in a listing:
            // leave those to their card.
            var files: [String: Int64?] = [:]
            for item in items where !item.isDir { files[item.name] = item.size.map(Int64.init) }
            for path in paths {
                let name = (path as NSString).lastPathComponent
                if let size = files[name] {
                    entries[path] = (.present(size: size), stamp)
                } else if name.hasPrefix(".") {
                    entries[path] = (.unverified, stamp)
                } else {
                    entries[path] = (.missing, stamp)
                }
            }
        case .failure(let error):
            let state: State = Self.directoryIsMissing(error) ? .missing : .unverified
            for path in paths { entries[path] = (state, stamp) }
        }
    }

    /// codeg answers 500 "Path is not a directory" for a directory that
    /// isn't there (`list_directory_with_files`).
    static func directoryIsMissing(_ error: Error) -> Bool {
        if case .server(_, _, let message)? = error as? APIError {
            return message.lowercased().contains("not a directory")
        }
        if case .missing? = error as? MediaError { return true }
        if case .folderMissing? = error as? MediaError { return true }
        return false
    }
}
