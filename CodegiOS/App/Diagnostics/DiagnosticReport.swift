import Foundation
import MachO
import UIKit

/// A JSON value of any shape, for the MetricKit payload a report carries.
indirect enum DiagnosticJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DiagnosticJSON])
    case object([String: DiagnosticJSON])

    init(any value: Any) {
        switch value {
        case let v as NSNumber:
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map(DiagnosticJSON.init(any:)))
        case let v as [String: Any]: self = .object(v.mapValues(DiagnosticJSON.init(any:)))
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([DiagnosticJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: DiagnosticJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> DiagnosticJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    var arrayValue: [DiagnosticJSON] {
        if case .array(let a) = self { return a }
        return []
    }

    /// Every string scrubbed with ``DiagnosticScrubber``.
    func scrubbed() -> DiagnosticJSON {
        switch self {
        case .string(let s): return .string(DiagnosticScrubber.scrub(s, max: 4000))
        case .array(let a): return .array(a.map { $0.scrubbed() })
        case .object(let o): return .object(o.mapValues { $0.scrubbed() })
        default: return self
        }
    }
}

/// What a report keeps of free text from the system (an exception's reason,
/// MetricKit's termination reason): file paths, URLs' queries and anything
/// shaped like a credential are cut out; the rest is cut to size.
enum DiagnosticScrubber {
    private static let rules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "(?i)\\b(bearer)(\\s+)[^\\s,;&'\"]+"), "$1$2<redacted>"),
        (try! NSRegularExpression(pattern: "(?i)\\b(token|api[_-]?key|secret|password|passwd|authorization)(\\s*[=:]\\s*)[^\\s,;&'\"]+"), "$1$2<redacted>"),
        (try! NSRegularExpression(pattern: "(?i)\\b([a-z][a-z0-9+.-]*://[^\\s'\"<>?#]*)[?#][^\\s'\"<>]*"), "$1?<redacted>"),
        (try! NSRegularExpression(pattern: "(?:/private)?/(?:var|Users|Volumes|tmp|private|System/Volumes)/[^\\s'\"<>,;)]*"), "<path>"),
        (try! NSRegularExpression(pattern: "\\b[A-Za-z0-9_-]{40,}\\b"), "<redacted>"),
    ]

    static func scrub(_ text: String, max: Int) -> String {
        var out = text
        for (rule, template) in rules {
            out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return cut(out, max: max)
    }

    /// Control characters (but newlines) become spaces; then cut to `max`.
    static func cut(_ text: String, max: Int) -> String {
        let out = String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" ? Character(" ") : Character($0)
        })
        return out.count > max ? String(out.prefix(max)) + "…" : out
    }
}

/// One report for the codeg server (`report_client_diagnostic`): what broke,
/// on which build, and the app events leading up to it. No message text,
/// file names, tokens or URLs.
struct DiagnosticReport: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        var version: String
        var build: String
        var bundleId: String
    }

    struct Device: Codable, Equatable, Sendable {
        var model: String
        var os: String
    }

    struct Summary: Codable, Equatable, Sendable {
        var exceptionType: String?
        var signal: String?
        var exceptionName: String?
        var reason: String?
        var terminationReason: String?
        /// The thread that crashed, innermost first: "Codeg +2437700".
        var topFrames: [String] = []
        /// What the app was doing (the guarded audio call, a hang's length).
        var context: String?
    }

    struct BinaryImage: Codable, Equatable, Sendable {
        var name: String
        var uuid: String
        var loadAddress: String
    }

    var schema = 1
    var id: String
    /// `crash`, `hang`, `cpu_exception`, `disk_write_exception`,
    /// `app_launch`, `uncaught_exception` or `caught_exception`.
    var kind: String
    /// `metrickit`, `exception_handler` or `audio_guard`.
    var source: String
    /// When it happened, if known (ISO 8601).
    var occurredAt: String?
    var createdAt: String
    var app: App
    var device: Device
    var summary: Summary
    var binaryImages: [BinaryImage] = []
    /// Return addresses of the raising thread (exceptions), for atos.
    var stackAddresses: [String] = []
    var breadcrumbs: [Breadcrumb] = []
    /// `this_launch` or `previous_launch`.
    var breadcrumbsFrom: String?
    var metricKit: DiagnosticJSON?

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - This app and device

enum DiagnosticEnvironment {
    static var app: DiagnosticReport.App {
        let info = Bundle.main.infoDictionary ?? [:]
        return .init(version: info["CFBundleShortVersionString"] as? String ?? "?",
                     build: info["CFBundleVersion"] as? String ?? "?",
                     bundleId: Bundle.main.bundleIdentifier ?? "?")
    }

    static var device: DiagnosticReport.Device {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        // "Version 27.2 (Build 24B5089g)" → "iOS 27.2 (24B5089g)"
        let described = ProcessInfo.processInfo.operatingSystemVersionString
        let build = described.range(of: #"Build ([^)]+)"#, options: .regularExpression)
            .map { String(described[$0].dropFirst(6)) }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "iOS \(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "") + (build.map { " (\($0))" } ?? "")
        return .init(model: model, os: os)
    }

    /// The app binary's UUID and load address, so a stack of return addresses
    /// can be matched to the right dSYM and symbolicated with atos.
    static let mainImage: DiagnosticReport.BinaryImage? = {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == UInt32(MH_EXECUTE) else { continue }
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.load(as: load_command.self)
                if load.cmd == UInt32(LC_UUID) {
                    let uuid = command.load(as: uuid_command.self).uuid
                    let text = UUID(uuid: uuid).uuidString
                    let name = _dyld_get_image_name(index)
                        .map { (String(cString: $0) as NSString).lastPathComponent } ?? "Codeg"
                    return .init(name: name, uuid: text,
                                 loadAddress: "0x" + String(UInt(bitPattern: header), radix: 16))
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
        }
        return nil
    }()
}

// MARK: - Building reports

extension DiagnosticReport {
    /// A report about an Objective-C exception: an uncaught one written by
    /// the handler before the abort, or one the audio guard caught.
    static func exception(kind: String, source: String, name: String, reason: String?,
                          symbols: [String], addresses: [UInt], occurredAt: Date, context: String?,
                          app: App = DiagnosticEnvironment.app, device: Device = DiagnosticEnvironment.device,
                          image: BinaryImage? = DiagnosticEnvironment.mainImage,
                          breadcrumbs: [Breadcrumb], breadcrumbsFrom: String) -> DiagnosticReport {
        var summary = Summary()
        summary.exceptionType = "EXC_CRASH"
        summary.signal = kind == "uncaught_exception" ? "SIGABRT" : nil
        summary.exceptionName = DiagnosticScrubber.scrub(name, max: 200)
        summary.reason = reason.map { DiagnosticScrubber.scrub($0, max: 1000) }
        summary.topFrames = topFrames(fromSymbols: symbols)
        summary.context = context
        return DiagnosticReport(
            id: UUID().uuidString, kind: kind, source: source, occurredAt: iso(occurredAt), createdAt: iso(Date()),
            app: app, device: device, summary: summary, binaryImages: image.map { [$0] } ?? [],
            stackAddresses: addresses.prefix(64).map { "0x" + String($0, radix: 16) },
            breadcrumbs: breadcrumbs, breadcrumbsFrom: breadcrumbsFrom, metricKit: nil)
    }

    /// `NSException.callStackSymbols` lines ("5   Codeg   0x0000000104d98448
    /// Codeg + 2437700") as "Codeg +2437700" or "Codeg runEngine() + 408",
    /// dropping the frames of the exception machinery itself.
    static func topFrames(fromSymbols symbols: [String], appBinary: String = appBinaryName,
                          limit: Int = 12) -> [String] {
        var frames: [(binary: String, text: String)] = []
        for line in symbols.prefix(128) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let binary = String(parts[1])
            let rest = parts.dropFirst(3).joined(separator: " ")
            let symbol = rest.hasPrefix("\(binary) + ") ? "+" + rest.dropFirst(binary.count + 3) : rest
            frames.append((binary, DiagnosticScrubber.cut("\(binary) \(symbol)", max: 200)))
        }
        return focus(frames, appBinary: appBinary, limit: limit)
    }

    static var appBinaryName: String { DiagnosticEnvironment.mainImage?.name ?? "Codeg" }

    /// The frames worth reading first: from two frames above the app's own
    /// innermost frame (the framework call that raised), or, with no app
    /// frame, past the abort and exception machinery.
    static func focus(_ frames: [(binary: String, text: String)], appBinary: String, limit: Int) -> [String] {
        let machinery: Set<String> = ["CoreFoundation", "libobjc.A.dylib", "libc++abi.dylib", "libsystem_kernel.dylib",
                                      "libsystem_c.dylib", "libsystem_pthread.dylib", "libdyld.dylib"]
        let start: Int
        if let app = frames.firstIndex(where: { $0.binary == appBinary }) {
            start = max(0, app - 2)
        } else {
            start = frames.firstIndex { !machinery.contains($0.binary) } ?? 0
        }
        return frames.dropFirst(start).prefix(limit).map(\.text)
    }

    /// A report from one MetricKit diagnostic's JSON (`jsonRepresentation()`).
    static func metricKit(kind: String, json: DiagnosticJSON, occurredAt: Date?, breadcrumbs: [Breadcrumb],
                          breadcrumbsFrom: String?, fallbackApp: App = DiagnosticEnvironment.app,
                          fallbackDevice: Device = DiagnosticEnvironment.device) -> DiagnosticReport {
        let meta = json["diagnosticMetaData"] ?? json["metaData"] ?? .object([:])
        let app = App(version: meta["appVersion"]?.string ?? fallbackApp.version,
                      build: meta["appBuildVersion"]?.string ?? fallbackApp.build,
                      bundleId: meta["bundleIdentifier"]?.string ?? fallbackApp.bundleId)
        let device = Device(model: meta["deviceType"]?.string ?? fallbackDevice.model,
                            os: meta["osVersion"]?.string.map { $0.replacingOccurrences(of: "iPhone OS", with: "iOS") }
                                ?? fallbackDevice.os)
        var summary = Summary()
        summary.exceptionType = meta["exceptionType"]?.string.map(Self.machExceptionName)
        summary.signal = meta["signal"]?.string.map(Self.signalName)
        summary.terminationReason = meta["terminationReason"]?.string.map { DiagnosticScrubber.scrub($0, max: 300) }
        if case .object(let fields) = meta,
           let reason = fields.first(where: { $0.key.lowercased().contains("exceptionreason") })?.value {
            summary.exceptionName = (reason["exceptionName"] ?? reason["className"])?.string
            summary.reason = (reason["composedMessage"] ?? reason["formatString"])?.string
                .map { DiagnosticScrubber.scrub($0, max: 1000) }
        }
        if let duration = meta["hangDuration"]?.string { summary.context = "hang \(duration)" }
        else if let writes = meta["writesCaused"]?.string { summary.context = "writes \(writes)" }
        else if let cpu = meta["totalCPUTime"]?.string { summary.context = "cpu \(cpu)" }
        else if let launch = meta["launchDuration"]?.string { summary.context = "launch \(launch)" }
        summary.topFrames = topFrames(fromCallStackTree: json["callStackTree"])
        return DiagnosticReport(
            id: UUID().uuidString, kind: kind, source: "metrickit", occurredAt: occurredAt.map(iso),
            createdAt: iso(Date()), app: app, device: device, summary: summary,
            breadcrumbs: breadcrumbs, breadcrumbsFrom: breadcrumbsFrom, metricKit: json.scrubbed())
    }

    /// The attributed thread's stack, innermost first: MetricKit nests each
    /// caller as the first sub-frame of its callee.
    static func topFrames(fromCallStackTree tree: DiagnosticJSON?, appBinary: String = appBinaryName,
                          limit: Int = 12) -> [String] {
        guard let stacks = tree?["callStacks"]?.arrayValue, !stacks.isEmpty else { return [] }
        let stack = stacks.first { $0["threadAttributed"] == .bool(true) } ?? stacks[0]
        var frame = stack["callStackRootFrames"]?.arrayValue.first
        var frames: [(binary: String, text: String)] = []
        while let current = frame, frames.count < 128 {
            let name = current["binaryName"]?.string ?? "?"
            let offset = current["offsetIntoBinaryTextSegment"]?.string ?? "?"
            frames.append((name, "\(name) +\(offset)"))
            frame = current["subFrames"]?.arrayValue.first
        }
        return focus(frames, appBinary: appBinary, limit: limit)
    }

    static func machExceptionName(_ code: String) -> String {
        let names = ["1": "EXC_BAD_ACCESS", "2": "EXC_BAD_INSTRUCTION", "3": "EXC_ARITHMETIC", "4": "EXC_EMULATION",
                     "5": "EXC_SOFTWARE", "6": "EXC_BREAKPOINT", "10": "EXC_CRASH", "11": "EXC_RESOURCE",
                     "12": "EXC_GUARD", "13": "EXC_CORPSE_NOTIFY"]
        return names[code] ?? code
    }

    static func signalName(_ code: String) -> String {
        let names = ["4": "SIGILL", "5": "SIGTRAP", "6": "SIGABRT", "7": "SIGEMT", "8": "SIGFPE", "9": "SIGKILL",
                     "10": "SIGBUS", "11": "SIGSEGV", "12": "SIGSYS", "13": "SIGPIPE", "15": "SIGTERM"]
        return names[code] ?? code
    }
}
