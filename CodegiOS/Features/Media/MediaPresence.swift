import Foundation
import Observation

/// Lists one server directory (`list_directory_with_files`).
protocol MediaDirectoryListing: Sendable {
    func listDirectoryWithFiles(path: String) async throws -> [DirectoryItem]
}

/// Whether the files a session refers to are on the server, so the
/// transcript shows a card only for a file that is there.
///
/// A message's files are checked once, before their cards show: one
/// `list_directory_with_files` per directory, shared by every file in it,
/// however many messages name them. The answer is kept per path, for
/// ``presentLifetime`` when the file is there and ``missingLifetime`` when it
/// isn't, so a file the agent makes later is seen once it is there. A server
/// that can't list the directory (an older codeg, the network) leaves the
/// cards to find out for themselves, as before.
@MainActor
@Observable
final class MediaPresence {
    enum State: Equatable, Sendable {
        /// On the server, with its size when the listing gave one.
        case present(size: Int64?)
        /// Not there: the directory has no such file, or there is no such directory.
        case missing
        /// The server couldn't say (an older server, the network): show the card.
        case unverified
    }

    /// Bumped when an answer arrives, so the transcript rebuilds its cards.
    private(set) var version = 0

    @ObservationIgnored private var entries: [String: (state: State, at: Date)] = [:]
    @ObservationIgnored private var queued: [String: String] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var flushing = 0
    @ObservationIgnored private var inFlight: [String: Task<Result<[DirectoryItem], Error>, Never>] = [:]
    @ObservationIgnored private let lister: any MediaDirectoryListing
    @ObservationIgnored private let now: () -> Date

    static let presentLifetime: TimeInterval = 10 * 60
    static let missingLifetime: TimeInterval = 30
    static let unverifiedLifetime: TimeInterval = 60

    init(lister: any MediaDirectoryListing, now: @escaping () -> Date = Date.init) {
        self.lister = lister
        self.now = now
    }

    /// What is known about `path`, nil when it hasn't been checked. A stale
    /// answer is still given (so a card doesn't blink) and checked again.
    func state(of path: String) -> State? {
        guard let entry = entries[path] else { return nil }
        if isStale(entry) { enqueue(path) }
        return entry.state
    }

    /// Check `path` soon. Called while the transcript builds, so the check
    /// starts after the current update rather than inside it.
    func enqueue(_ path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        queued[path] = directory.isEmpty ? "/" : directory
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            await self?.flush()
        }
    }

    /// Check every queued path now: one listing per directory.
    func flush() async {
        flushScheduled = false
        let batch = queued
        queued = [:]
        guard !batch.isEmpty else { return }
        flushing += 1
        defer { flushing -= 1 }
        var byDirectory: [String: [String]] = [:]
        for (path, directory) in batch { byDirectory[directory, default: []].append(path) }

        await withTaskGroup(of: (String, Result<[DirectoryItem], Error>).self) { group in
            for directory in byDirectory.keys {
                let task = listing(of: directory)
                group.addTask { (directory, await task.value) }
            }
            for await (directory, result) in group {
                record(result, directory: directory, paths: byDirectory[directory] ?? [])
            }
        }
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

    private func record(_ result: Result<[DirectoryItem], Error>, directory: String, paths: [String]) {
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
