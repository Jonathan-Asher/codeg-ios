import Foundation
import os

/// One app event, kept for the next crash report: an event name and a short
/// detail from a fixed vocabulary (a screen, a microphone use, a route's port
/// types). Never message text, file names, paths, URLs or tokens.
struct Breadcrumb: Codable, Equatable, Sendable {
    /// Milliseconds since 1970.
    let t: Int64
    let event: String
    let detail: String?

    init(t: Int64, event: String, detail: String?) {
        self.t = t
        self.event = Breadcrumb.clean(event, max: 48) ?? "event"
        self.detail = detail.flatMap { Breadcrumb.clean($0, max: 120) }
    }

    /// Letters, digits and `._:-/=,+ ` only, cut to `max` characters; a
    /// second line of defense against a caller passing something it shouldn't.
    static func clean(_ text: String, max: Int) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-/=,+ "))
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }))
            .trimmingCharacters(in: .whitespaces)
        guard !kept.isEmpty else { return nil }
        return String(kept.prefix(max))
    }
}

/// The last ``capacity`` events, oldest first.
struct BreadcrumbRing: Codable, Equatable, Sendable {
    static let capacity = 100
    private(set) var items: [Breadcrumb] = []

    mutating func append(_ crumb: Breadcrumb) {
        items.append(crumb)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }
}

/// The app's breadcrumb trail. Every event is written to disk shortly after
/// it is recorded, so the trail survives a crash; the trail of the previous
/// launch is kept apart for the crash report that arrives on this one.
final class Breadcrumbs: @unchecked Sendable {
    static let shared = Breadcrumbs()

    private let lock = NSLock()
    private var ring = BreadcrumbRing()
    private var writeScheduled = false
    private let queue = DispatchQueue(label: "codeg.breadcrumbs", qos: .utility)
    private var enabled = false
    /// The trail of the launch before this one, read once at start.
    private(set) var previousLaunch: [Breadcrumb] = []

    private var currentFile: URL { DiagnosticsStore.directory.appendingPathComponent("breadcrumbs-current.json") }
    private var previousFile: URL { DiagnosticsStore.directory.appendingPathComponent("breadcrumbs-previous.json") }

    /// Rotate the files (this launch's trail starts empty) and start recording.
    func start() {
        let fm = FileManager.default
        try? fm.removeItem(at: previousFile)
        try? fm.moveItem(at: currentFile, to: previousFile)
        let previous = (try? Data(contentsOf: previousFile))
            .flatMap { try? JSONDecoder().decode(BreadcrumbRing.self, from: $0) }?.items ?? []
        lock.lock()
        previousLaunch = previous
        enabled = true
        lock.unlock()
    }

    /// Stop recording and forget both trails (the switch went off).
    func stopAndForget() {
        lock.lock()
        enabled = false
        ring = BreadcrumbRing()
        previousLaunch = []
        lock.unlock()
        try? FileManager.default.removeItem(at: currentFile)
        try? FileManager.default.removeItem(at: previousFile)
    }

    /// An enum case's name without its payload ("interrupted(…)" →
    /// "interrupted"), so a breadcrumb never carries the payload's text.
    static func caseName(_ value: Any) -> String {
        String(String(describing: value).prefix { $0 != "(" })
    }

    /// Record an event. Cheap and callable from any thread.
    static func add(_ event: String, _ detail: String? = nil) {
        shared.record(event, detail)
    }

    private func record(_ event: String, _ detail: String?) {
        let crumb = Breadcrumb(t: Int64(Date().timeIntervalSince1970 * 1000), event: event, detail: detail)
        lock.lock()
        guard enabled else { lock.unlock(); return }
        ring.append(crumb)
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if schedule {
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let snapshot = ring
        writeScheduled = false
        let on = enabled
        lock.unlock()
        guard on, let data = try? JSONEncoder().encode(snapshot) else { return }
        DiagnosticsStore.ensureDirectory()
        try? data.write(to: currentFile, options: .atomic)
    }

    /// This launch's trail. With `nonBlocking` (the exception handler, which
    /// may run while this thread holds the lock) it gives up rather than wait.
    func current(nonBlocking: Bool = false) -> [Breadcrumb] {
        if nonBlocking {
            guard lock.try() else { return [] }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        return ring.items
    }

    /// The previous launch's trail, handed out once (to the first crash
    /// report about that launch).
    func takePreviousLaunch() -> [Breadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        let trail = previousLaunch
        previousLaunch = []
        return trail
    }
}
