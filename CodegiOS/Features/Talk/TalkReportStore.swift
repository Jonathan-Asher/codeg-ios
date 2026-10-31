import Foundation
import os

/// Talk's `talk_lab` reports, kept on this iPhone until the session's server
/// has them. A Talk that ends with the iPhone locked has only the background
/// time ``TalkController`` takes before iOS suspends the app, and one that
/// ends offline or with the server down would lose them otherwise.
///
/// One folder per server (`Application Support/TalkReports/<server id>/`,
/// not backed up): a report holds what was said, so it goes only to the
/// server of its session. What waits is sent again at the next Talk's end
/// and whenever the app comes to the front (``sendAllKeptSoon(after:)``). A
/// report older than ``maxAge`` is dropped unsent, and so is everything while
/// Share Talk telemetry is off.
struct TalkReportStore: Sendable {
    static let shared: TalkReportStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TalkReportStore(directory: base.appendingPathComponent("TalkReports", isDirectory: true))
    }()

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "talk")
    static let maxAge: TimeInterval = 14 * 24 * 3600
    /// Reports kept per server at most; the oldest go first.
    static let maxPerServer = 30

    let directory: URL

    func folder(for server: UUID) -> URL {
        directory.appendingPathComponent(server.uuidString, isDirectory: true)
    }

    // MARK: - Keeping

    /// Write `reports` for `server`, each under its id (a report kept again
    /// replaces its earlier copy), and drop what is past the limits.
    func keep(_ reports: [Data], for server: UUID, now: Date = Date()) {
        guard !reports.isEmpty else { return }
        let fm = FileManager.default
        let folder = folder(for: server)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var root = directory
            try? root.setResourceValues(values)
        }
        let earlier = waiting(for: server)
        // One millisecond apart, so the parts of a Talk stay in order.
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        for (index, report) in reports.enumerated() {
            let id = Self.id(of: report) ?? UUID().uuidString.lowercased()
            for file in earlier where Self.id(ofFile: file) == id { remove(file) }
            let name = String(format: "%013lld", stamp + Int64(index)) + "-" + id + ".json"
            try? report.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        trim(server, now: now)
    }

    /// What waits for `server`, oldest first.
    func waiting(for server: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: server),
                                                                   includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The servers something waits for.
    func servers() -> [UUID] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .filter { !waiting(for: $0).isEmpty }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func remove(server: UUID) {
        try? FileManager.default.removeItem(at: folder(for: server))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Sending

    /// Send what waits for `server`, oldest first, through `send` (one
    /// report's `report_client_diagnostic` body). A report goes once the
    /// server has it, or refused it for what it is (a 4xx other than 404,
    /// 408 and 429); at any other failure (no connection, a server without
    /// the call yet) it and the rest stay for the next try. Returns how many
    /// the server took.
    @discardableResult
    func send(for server: UUID, now: Date = Date(), _ send: (Data) async throws -> Void) async -> Int {
        trim(server, now: now)
        var sent = 0
        for file in waiting(for: server) {
            guard !Task.isCancelled else { break }
            guard let report = try? Data(contentsOf: file), let body = DiagnosticsUploader.wrap(report) else {
                remove(file)
                continue
            }
            do {
                try await send(body)
                remove(file)
                sent += 1
            } catch APIError.server(let status, _, _) where (400..<500).contains(status) && ![404, 408, 429].contains(status) {
                Self.log.notice("The server refused a Talk report (HTTP \(status)); dropped it")
                remove(file)
            } catch {
                Self.log.notice("A Talk report didn't go, kept for later: \(String(describing: error), privacy: .public)")
                break
            }
        }
        if sent > 0 { Self.log.notice("Sent \(sent) Talk report(s) to the server") }
        return sent
    }

    // MARK: - Limits

    private func trim(_ server: UUID, now: Date) {
        var files = waiting(for: server)
        let nowMs = now.timeIntervalSince1970 * 1000
        files.removeAll { file in
            let ms = Double(file.lastPathComponent.prefix { $0 != "-" }) ?? 0
            guard nowMs - ms > Self.maxAge * 1000 else { return false }
            remove(file)
            return true
        }
        while files.count > Self.maxPerServer { remove(files.removeFirst()) }
    }

    private func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// A report's `id` when it is safe in a file name (letters, digits and
    /// `-`, as the server's ids).
    static func id(of report: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: report) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return id
    }

    /// The id in a kept file's name (`<milliseconds>-<id>.json`).
    static func id(ofFile file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return nil }
        return String(name[name.index(after: dash)...])
    }
}

// MARK: - In the app

extension TalkReportStore {
    @MainActor private static var sending: Task<Void, Never>?

    /// Send every server's kept reports to it, a few seconds from now: when
    /// the app comes to the front, and so at launch.
    @MainActor
    static func sendAllKeptSoon(after seconds: Double = 4) {
        sending?.cancel()
        sending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await sendAllKept()
        }
    }

    /// Each server's kept reports to that server, while it is saved. With
    /// Share Talk telemetry off they are dropped instead, and a server that
    /// is no longer saved takes its reports with it.
    @MainActor
    static func sendAllKept(store: TalkReportStore = .shared) async {
        guard TalkPrefs().shareTelemetry else {
            store.removeAll()
            return
        }
        let servers = store.servers()
        guard !servers.isEmpty else { return }
        let profiles = ServerStore.persistedServers()
        for server in servers {
            guard let profile = profiles.first(where: { $0.id == server }) else {
                store.remove(server: server)
                continue
            }
            guard let client = ServerStore.makeClient(for: profile) else { continue }
            await store.send(for: server) { body in try await client.reportClientDiagnostic(body) }
        }
    }
}
