import AVFoundation
import Foundation
import MetricKit
import Network
import UIKit
import os

/// Crash reports, kept on this iPhone until a codeg server has them.
///
/// Three sources: MetricKit's diagnostics (crashes, hangs, CPU and disk
/// exceptions, slow launches, delivered on the next launch), the uncaught
/// Objective-C exception handler (name, reason and stack, written to disk
/// just before the abort and sent on the next launch), and the exceptions the
/// audio guard catches (``AVFAudioGuard``). Each report carries the app
/// version, build, device and OS, and the breadcrumbs leading up to it. They
/// go to every saved server (`report_client_diagnostic`); nothing goes to a
/// third party. On by default; Settings › About turns it off, which also
/// drops what is waiting.
final class Diagnostics: NSObject, @unchecked Sendable {
    static let shared = Diagnostics()
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "diagnostics")

    /// The switch in Settings › About.
    static let enabledKey = "diagnostics.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { shared.start() } else { shared.stop() }
        }
    }

    /// Caught exceptions reported per launch; the rest are only logged.
    static let maxCaughtPerLaunch = 5

    private let lock = NSLock()
    private var started = false
    private var caughtThisLaunch = 0
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var lastNetwork: String?
    private var uploadTask: Task<Void, Never>?
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private static var imageAtLaunch: DiagnosticReport.BinaryImage?

    // MARK: - Lifecycle

    /// From `didFinishLaunching`, before anything else can raise.
    func start() {
        guard Self.isEnabled else { return }
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        DiagnosticsStore.ensureDirectory()
        Breadcrumbs.shared.start()
        installExceptionHandler()
        collectPendingException()
        MXMetricManager.shared.add(self)
        observeSystem()
        Breadcrumbs.add("app.launch", "\(DiagnosticEnvironment.app.version) (\(DiagnosticEnvironment.app.build))")
        scheduleUpload(after: 8)
    }

    /// The switch went off: stop collecting and drop what is waiting.
    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()
        MXMetricManager.shared.remove(self)
        NSSetUncaughtExceptionHandler(Self.previousExceptionHandler)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pathMonitor?.cancel()
        pathMonitor = nil
        uploadTask?.cancel()
        Breadcrumbs.shared.stopAndForget()
        DiagnosticsStore.removeAll()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    // MARK: - Uncaught exceptions

    private func installExceptionHandler() {
        DiagnosticsStore.prepareExceptionPath()
        // Worked out now: the handler must not walk dyld while the app dies.
        Self.imageAtLaunch = DiagnosticEnvironment.mainImage
        Self.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.writeUncaught(exception)
            Diagnostics.previousExceptionHandler?(exception)
        }
    }

    /// Runs on the raising thread, just before the abort: write what the next
    /// launch needs, synchronously, and nothing else.
    private static func writeUncaught(_ exception: NSException) {
        let record: [String: Any] = [
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "",
            "symbols": exception.callStackSymbols,
            "addresses": exception.callStackReturnAddresses.map(\.uintValue),
            "time": Date().timeIntervalSince1970,
            "app": [DiagnosticEnvironment.app.version, DiagnosticEnvironment.app.build],
            "image": imageAtLaunch.map { [$0.name, $0.uuid, $0.loadAddress] } ?? [],
            "crumbs": (try? JSONEncoder().encode(Breadcrumbs.shared.current(nonBlocking: true)))
                .map { $0.base64EncodedString() } ?? "",
        ]
        guard let path = DiagnosticsStore.exceptionPath,
              let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        FileManager.default.createFile(atPath: path, contents: data)
    }

    /// The exception the last launch died of, now a report.
    private func collectPendingException() {
        guard let path = DiagnosticsStore.exceptionPath,
              let data = FileManager.default.contents(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let crumbs = (record["crumbs"] as? String).flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode([Breadcrumb].self, from: $0) }
        _ = Breadcrumbs.shared.takePreviousLaunch()
        var app = DiagnosticEnvironment.app
        if let pair = record["app"] as? [String], pair.count == 2 { app.version = pair[0]; app.build = pair[1] }
        let report = DiagnosticReport.exception(
            kind: "uncaught_exception", source: "exception_handler",
            name: record["name"] as? String ?? "NSException", reason: record["reason"] as? String,
            symbols: record["symbols"] as? [String] ?? [], addresses: record["addresses"] as? [UInt] ?? [],
            occurredAt: Date(timeIntervalSince1970: record["time"] as? Double ?? Date().timeIntervalSince1970),
            context: nil, app: app,
            // Where the binary was loaded in the launch that died.
            image: (record["image"] as? [String]).flatMap {
                $0.count == 3 ? DiagnosticReport.BinaryImage(name: $0[0], uuid: $0[1], loadAddress: $0[2]) : nil
            },
            breadcrumbs: crumbs ?? [], breadcrumbsFrom: "previous_launch")
        DiagnosticsStore.enqueue(report)
        Self.log.notice("The last launch ended on an uncaught \(report.summary.exceptionName ?? "?", privacy: .public); queued for the server")
    }

    // MARK: - Caught exceptions

    /// The audio guard caught an exception the app would have died of.
    func caught(operation: String, exception: NSException) {
        guard isRunning else { return }
        lock.lock()
        caughtThisLaunch += 1
        let report = caughtThisLaunch <= Self.maxCaughtPerLaunch
        lock.unlock()
        Breadcrumbs.add("audio.exception", operation)
        guard report else { return }
        let entry = DiagnosticReport.exception(
            kind: "caught_exception", source: "audio_guard", name: exception.name.rawValue,
            reason: exception.reason, symbols: exception.callStackSymbols,
            addresses: exception.callStackReturnAddresses.map(\.uintValue), occurredAt: Date(),
            context: operation, breadcrumbs: Breadcrumbs.shared.current(), breadcrumbsFrom: "this_launch")
        DiagnosticsStore.enqueue(entry)
        scheduleUpload(after: 2)
    }

    // MARK: - Uploading

    /// Send what is waiting to every saved server, a little later.
    func scheduleUpload(after seconds: Double) {
        guard isRunning else { return }
        uploadTask?.cancel()
        uploadTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await DiagnosticsUploader.flush()
        }
    }

    // MARK: - Breadcrumbs from the system

    private func observeSystem() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ body: @escaping (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil, using: body))
        }
        on(AVAudioSession.routeChangeNotification) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map(Self.routeReason) ?? "\(raw)"
            Breadcrumbs.add("audio.route", "\(reason) \(Self.routeDescription())")
        }
        on(AVAudioSession.interruptionNotification) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            Breadcrumbs.add("audio.interruption", AVAudioSession.InterruptionType(rawValue: raw) == .began ? "began" : "ended")
        }
        on(AVAudioSession.mediaServicesWereResetNotification) { _ in Breadcrumbs.add("audio.media_services_reset") }
        on(.AVAudioEngineConfigurationChange) { note in
            let running = (note.object as? AVAudioEngine)?.isRunning ?? false
            Breadcrumbs.add("audio.engine_config_change", running ? "running" : "stopped")
        }
        on(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            Breadcrumbs.add("app.active")
            self?.scheduleUpload(after: 3)
        }
        on(UIApplication.didEnterBackgroundNotification) { _ in Breadcrumbs.add("app.background") }
        on(UIApplication.didReceiveMemoryWarningNotification) { _ in Breadcrumbs.add("app.memory_warning") }
        on(ProcessInfo.thermalStateDidChangeNotification) { _ in
            Breadcrumbs.add("app.thermal", "\(ProcessInfo.processInfo.thermalState.rawValue)")
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: String
            if path.status != .satisfied { kind = "offline" }
            else if path.usesInterfaceType(.wifi) { kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { kind = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { kind = "ethernet" }
            else { kind = "other" }
            let detail = kind + (path.isConstrained ? " constrained" : "") + (path.isExpensive ? " expensive" : "")
            guard let self else { return }
            self.lock.lock()
            let changed = self.lastNetwork != detail
            self.lastNetwork = detail
            self.lock.unlock()
            if changed { Breadcrumbs.add("network", detail) }
        }
        monitor.start(queue: DispatchQueue(label: "codeg.diagnostics.network", qos: .utility))
        pathMonitor = monitor
    }

    /// The current route as port types only ("in=MicrophoneBuiltIn
    /// out=BluetoothA2DPOutput 48000Hz"): never the devices' names.
    static func routeDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let ins = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
        let outs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
        return "in=\(ins.isEmpty ? "none" : ins) out=\(outs.isEmpty ? "none" : outs) \(Int(session.sampleRate))Hz"
    }

    private static func routeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "new_device"
        case .oldDeviceUnavailable: return "device_gone"
        case .categoryChange: return "category"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "no_route"
        case .routeConfigurationChange: return "config"
        case .unknown: return "unknown"
        @unknown default: return "\(reason.rawValue)"
        }
    }
}

// MARK: - MetricKit

extension Diagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard isRunning else { return }
        var queued = 0
        for payload in payloads {
            let when = payload.timeStampEnd
            var items: [(String, MXDiagnostic)] = []
            items += (payload.crashDiagnostics ?? []).map { ("crash", $0 as MXDiagnostic) }
            items += (payload.hangDiagnostics ?? []).map { ("hang", $0 as MXDiagnostic) }
            items += (payload.cpuExceptionDiagnostics ?? []).map { ("cpu_exception", $0 as MXDiagnostic) }
            items += (payload.diskWriteExceptionDiagnostics ?? []).map { ("disk_write_exception", $0 as MXDiagnostic) }
            items += (payload.appLaunchDiagnostics ?? []).map { ("app_launch", $0 as MXDiagnostic) }
            for (kind, diagnostic) in items {
                let data = diagnostic.jsonRepresentation()
                guard DiagnosticsStore.firstSighting(of: data),
                      let object = try? JSONSerialization.jsonObject(with: data) else { continue }
                // A crash is the previous launch's end: its trail goes with it.
                let crumbs = kind == "crash" ? Breadcrumbs.shared.takePreviousLaunch() : []
                let report = DiagnosticReport.metricKit(
                    kind: kind, json: DiagnosticJSON(any: object), occurredAt: when, breadcrumbs: crumbs,
                    breadcrumbsFrom: crumbs.isEmpty ? nil : "previous_launch")
                DiagnosticsStore.enqueue(report)
                queued += 1
            }
        }
        if queued > 0 {
            Self.log.notice("MetricKit delivered \(queued) diagnostic(s); queued for the server")
            scheduleUpload(after: 2)
        }
    }
}

// MARK: - The queue on disk

/// Reports waiting for a server, one JSON file each, in Application Support
/// (not backed up). At most ``maxReports`` / ``maxBytes``; the oldest go
/// first, and anything older than ``maxAge`` is dropped unsent.
enum DiagnosticsStore {
    static let maxReports = 50
    static let maxBytes = 8 * 1024 * 1024
    static let maxAge: TimeInterval = 21 * 24 * 3600

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    static var pendingDirectory: URL { directory.appendingPathComponent("pending", isDirectory: true) }
    private static let lock = NSLock()

    static func ensureDirectory() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: pendingDirectory.path) else { return }
        try? fm.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    /// Fixed before any exception, so the handler only writes a file.
    private(set) static var exceptionPath: String?
    static func prepareExceptionPath() {
        exceptionPath = directory.appendingPathComponent("uncaught-exception.json").path
    }

    /// The server takes up to 1 MiB; a bigger report goes without its raw
    /// MetricKit payload (the summary and frames stay).
    static let maxReportBytes = 900 * 1024

    static func enqueue(_ report: DiagnosticReport) {
        guard var data = try? JSONEncoder().encode(report) else { return }
        if data.count > maxReportBytes {
            var trimmed = report
            trimmed.metricKit = nil
            guard let smaller = try? JSONEncoder().encode(trimmed) else { return }
            data = smaller
        }
        lock.lock()
        defer { lock.unlock() }
        ensureDirectory()
        let name = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(report.id).json"
        try? data.write(to: pendingDirectory.appendingPathComponent(name), options: .atomic)
        trim()
    }

    /// Waiting reports, oldest first.
    static func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var pendingCount: Int { pending().count }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func trim() {
        let fm = FileManager.default
        var files = pending()
        let now = Date().timeIntervalSince1970
        files.removeAll { file in
            let ms = Double(file.lastPathComponent.split(separator: "-").first ?? "") ?? 0
            guard now - ms / 1000 > maxAge else { return false }
            try? fm.removeItem(at: file)
            return true
        }
        var sizes = files.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        while files.count > maxReports || sizes.reduce(0, +) > maxBytes, !files.isEmpty {
            try? fm.removeItem(at: files.removeFirst())
            sizes.removeFirst()
        }
    }

    /// MetricKit can hand the same diagnostic over again; remember a digest
    /// of the last ones seen.
    static func firstSighting(of data: Data) -> Bool {
        // FNV-1a: stable across launches, unlike `Hasher`.
        let digest = data.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }
        let key = String(digest, radix: 16)
        let file = directory.appendingPathComponent("metrickit-seen.json")
        lock.lock()
        defer { lock.unlock() }
        var seen = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        guard !seen.contains(key) else { return false }
        seen.append(key)
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }
        ensureDirectory()
        try? JSONEncoder().encode(seen).write(to: file, options: .atomic)
        return true
    }
}

// MARK: - Sending

enum DiagnosticsUploader {
    private static let gate = NSLock()
    private static var running = false

    /// Send each waiting report to every saved server; one acceptance is
    /// enough to drop it here. Reports stay queued while no server answers.
    static func flush() async {
        gate.lock()
        guard !running else { gate.unlock(); return }
        running = true
        gate.unlock()
        defer { gate.lock(); running = false; gate.unlock() }

        let files = DiagnosticsStore.pending()
        guard !files.isEmpty else { return }
        let clients = await MainActor.run {
            ServerStore.persistedServers().compactMap { ServerStore.makeClient(for: $0) }
        }
        guard !clients.isEmpty else { return }
        var sent = 0
        for file in files.prefix(20) {
            guard !Task.isCancelled, let report = try? Data(contentsOf: file),
                  let body = wrap(report) else {
                DiagnosticsStore.remove(file)
                continue
            }
            var accepted = false
            var refused = false
            for client in clients {
                do {
                    try await client.reportClientDiagnostic(body)
                    accepted = true
                } catch APIError.server(let status, _, _) where status == 404 {
                    // A server without the endpoint yet: try the others.
                } catch APIError.server(let status, _, _) where (400..<500).contains(status) && status != 408 && status != 429 {
                    // Refused for what it is (too large, malformed): sending it
                    // again won't help.
                    refused = true
                } catch {
                    Diagnostics.log.notice("Sending a crash report failed: \(String(describing: error), privacy: .public)")
                }
            }
            if accepted {
                DiagnosticsStore.remove(file)
                sent += 1
            } else if refused {
                Diagnostics.log.notice("A server refused a crash report; dropped it")
                DiagnosticsStore.remove(file)
            }
        }
        if sent > 0 { Diagnostics.log.notice("Sent \(sent) crash report(s) to the server") }
    }

    /// `{"report": <report>}`, the endpoint's body.
    static func wrap(_ report: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: report) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["report": object])
    }
}
