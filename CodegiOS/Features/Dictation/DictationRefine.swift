import Foundation
import os

// Clean-up and translation of a dictation through the codeg server the phone
// is connected to. Transcription stays on the iPhone; only the transcript text
// goes to the server, which passes it to the provider set up in codeg
// Settings on the computer. Whatever goes wrong, the words as spoken are kept.

/// Every name the phone uses for the server's dictation commands, in one
/// place (codeg `docs/dictation-refine.md`, from fork.155).
enum DictationRefineWire {
    /// `{ configured, keyError, providers: [{ id, label, hasKey, defaultModel }],
    /// provider, model, endpoint, targetLanguage, refine, translate, instructions }`
    static let settingsCommand = "get_dictation_refine_settings"
    /// Args below; answers `{ text, provider, model, elapsedMs }`.
    static let refineCommand = "refine_dictation"

    /// Request argument names. Requests go out with these keys verbatim.
    enum Arg {
        static let text = "text"
        static let refine = "refine"
        static let translate = "translate"
        static let targetLanguage = "targetLanguage"
        static let sourceLanguage = "sourceLanguage"
    }

    /// The target of "Clean up and translate to English". The server takes a
    /// language name or code, and names it in the model's prompt.
    static let english = "English"

    /// The dictation language as the server's prompt names it.
    static func languageName(_ code: String?) -> String? {
        switch code {
        case "he": "Hebrew"
        case "en": "English"
        default: code
        }
    }

    /// Providers that only translate: asking them to clean up is an error.
    static let translateOnlyProviders: Set<String> = ["google"]

    /// Response keys. Responses are decoded with the shared snake_case
    /// conversion, so `target_language` and `targetLanguage` both match.
    enum SettingsKey: String, CodingKey {
        case configured, keyError, providers, provider, model, endpoint, targetLanguage, refine, translate, instructions
    }

    enum ProviderKey: String, CodingKey {
        case id, label, hasKey, defaultModel
    }

    enum ResultKey: String, CodingKey {
        case text, provider, model, elapsedMs
    }

    /// The server has no such command: an older codeg. Unknown commands answer
    /// 501 `not_implemented`; a 404 is read the same way.
    static func isNotAvailable(_ error: Error) -> Bool {
        guard case .server(let status, let code, _)? = error as? APIError else { return false }
        return status == 404 || status == 501 || code == "not_implemented" || code == "unknown_command"
    }

    /// The server has the command but the selected provider has no key (or,
    /// for a custom one, no endpoint or model). Other server errors carry a
    /// message written for the user, which is shown as is.
    static func isNotConfigured(_ error: Error) -> Bool {
        guard case .server(_, let code, _)? = error as? APIError else { return false }
        return code == "configuration_missing"
    }
}

/// What happens to a transcript before it is inserted (Settings › Voice ›
/// Voice Typing › After transcribing, and the chip on the recording strip).
enum DictationRefineMode: String, CaseIterable, Identifiable, Sendable {
    case asSpoken
    case cleanUp
    case translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asSpoken: "Insert as spoken"
        case .cleanUp: "Clean up"
        case .translate: "Clean up and translate to English"
        }
    }

    /// The recording strip's chip.
    var shortTitle: String {
        switch self {
        case .asSpoken: "As spoken"
        case .cleanUp: "Clean up"
        case .translate: "To English"
        }
    }

    var systemImage: String {
        switch self {
        case .asSpoken: "text.quote"
        case .cleanUp: "wand.and.stars"
        case .translate: "globe"
        }
    }

    /// The settings row's menu.
    var menuLabel: String {
        switch self {
        case .asSpoken: "As spoken"
        case .cleanUp: "Clean up"
        case .translate: "To English"
        }
    }

    /// Shown on the strip while the server works.
    var progressLabel: String {
        self == .translate ? "Translating…" : "Cleaning up…"
    }

    /// The chip cycles through the modes.
    var next: DictationRefineMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - Wire types

struct DictationRefineProvider: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var hasKey: Bool
    var defaultModel: String?

    init(id: String, label: String, hasKey: Bool, defaultModel: String? = nil) {
        self.id = id
        self.label = label
        self.hasKey = hasKey
        self.defaultModel = defaultModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DictationRefineWire.ProviderKey.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? id
        hasKey = (try? c.decodeIfPresent(Bool.self, forKey: .hasKey)) ?? false
        defaultModel = try? c.decodeIfPresent(String.self, forKey: .defaultModel)
    }
}

/// `get_dictation_refine_settings`. Every field is optional on the wire.
struct DictationRefineSettings: Decodable, Equatable, Sendable {
    var configured: Bool
    /// Set when codeg's key store wouldn't open; the keys may then look absent.
    var keyError: String?
    var providers: [DictationRefineProvider]
    var provider: String?
    var model: String?
    var endpoint: String?
    var targetLanguage: String?
    var refine: Bool?
    var translate: Bool?
    var instructions: String?

    init(configured: Bool, keyError: String? = nil, providers: [DictationRefineProvider] = [],
         provider: String? = nil, model: String? = nil, targetLanguage: String? = nil, refine: Bool? = nil,
         translate: Bool? = nil, instructions: String? = nil) {
        self.configured = configured
        self.keyError = keyError
        self.providers = providers
        self.provider = provider
        self.model = model
        self.targetLanguage = targetLanguage
        self.refine = refine
        self.translate = translate
        self.instructions = instructions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DictationRefineWire.SettingsKey.self)
        configured = (try? c.decodeIfPresent(Bool.self, forKey: .configured)) ?? false
        keyError = (try? c.decodeIfPresent(String.self, forKey: .keyError)).flatMap { $0.isEmpty ? nil : $0 }
        providers = (try? c.decodeIfPresent([DictationRefineProvider].self, forKey: .providers)) ?? []
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        endpoint = try? c.decodeIfPresent(String.self, forKey: .endpoint)
        targetLanguage = try? c.decodeIfPresent(String.self, forKey: .targetLanguage)
        refine = try? c.decodeIfPresent(Bool.self, forKey: .refine)
        translate = try? c.decodeIfPresent(Bool.self, forKey: .translate)
        instructions = try? c.decodeIfPresent(String.self, forKey: .instructions)
    }

    /// Clean-up can be asked for: a provider that can be called, and a key
    /// store that opened.
    var isSetUp: Bool { configured && keyError == nil }

    /// "Groq · llama-3.3-70b" for the settings screen.
    var summary: String? {
        let label = providers.first { $0.id == provider }?.label ?? provider
        let model = (self.model?.isEmpty == false ? self.model : nil)
            ?? providers.first { $0.id == provider }?.defaultModel
        let parts = [label, model].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `refine_dictation`'s arguments.
struct DictationRefineRequest: Equatable, Sendable {
    var text: String
    var refine: Bool?
    var translate: Bool?
    var targetLanguage: String?
    var sourceLanguage: String?

    /// `sourceLanguage` is a whisper code (`he`, `en`) or nil; it goes out as
    /// a name. `provider` is the server's selected one, when known: a
    /// translate-only provider isn't asked to clean up.
    init(text: String, mode: DictationRefineMode, sourceLanguage: String?, provider: String? = nil) {
        self.text = text
        self.sourceLanguage = DictationRefineWire.languageName(sourceLanguage)
        switch mode {
        case .asSpoken:
            refine = false
            translate = false
        case .cleanUp:
            refine = true
            translate = false
        case .translate:
            refine = !DictationRefineWire.translateOnlyProviders.contains(provider ?? "")
            translate = true
            targetLanguage = DictationRefineWire.english
        }
    }

    /// The JSON body, keyed by ``DictationRefineWire/Arg``. Absent values go
    /// out as `null`, which the contract allows for each of them.
    func jsonBody() throws -> Data {
        typealias Arg = DictationRefineWire.Arg
        let object: [String: Any] = [
            Arg.text: text,
            Arg.refine: refine.map { $0 as Any } ?? NSNull(),
            Arg.translate: translate.map { $0 as Any } ?? NSNull(),
            Arg.targetLanguage: targetLanguage.map { $0 as Any } ?? NSNull(),
            Arg.sourceLanguage: sourceLanguage.map { $0 as Any } ?? NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// `refine_dictation`'s answer.
struct DictationRefineResult: Decodable, Equatable, Sendable {
    var text: String
    var provider: String?
    var model: String?
    var elapsedMs: Int?

    init(text: String, provider: String? = nil, model: String? = nil, elapsedMs: Int? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
        self.elapsedMs = elapsedMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DictationRefineWire.ResultKey.self)
        text = try c.decode(String.self, forKey: .text)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        if let ms = try? c.decodeIfPresent(Int.self, forKey: .elapsedMs) {
            elapsedMs = ms
        } else if let ms = try? c.decodeIfPresent(Double.self, forKey: .elapsedMs) {
            elapsedMs = Int(ms)
        } else {
            elapsedMs = nil
        }
    }
}

// MARK: - Transport

/// The two server commands. `CodegClient` is the real one; tests use a mock.
protocol DictationRefineTransport: Sendable {
    /// Identifies the server, for the availability cache.
    var refineServerKey: String { get }
    func dictationRefineSettings() async throws -> DictationRefineSettings
    func refineDictation(_ request: DictationRefineRequest) async throws -> DictationRefineResult
}

extension CodegClient: DictationRefineTransport {
    var refineServerKey: String { baseURL.absoluteString }

    func dictationRefineSettings() async throws -> DictationRefineSettings {
        try await postJSON(DictationRefineWire.settingsCommand, EmptyBody(), session: Self.readSession)
    }

    func refineDictation(_ request: DictationRefineRequest) async throws -> DictationRefineResult {
        let body: Data
        do { body = try request.jsonBody() } catch { throw APIError.decoding(String(describing: error)) }
        let data = try await send(DictationRefineWire.refineCommand, rawBody: body)
        do { return try CodegJSON.decoder.decode(DictationRefineResult.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }
}

// MARK: - Availability

/// Whether a server can clean up dictation.
enum DictationRefineAvailability: Equatable, Sendable {
    case ready(DictationRefineSettings)
    /// The server has the commands but no provider is set up, or its key
    /// store wouldn't open (`keyError`).
    case notConfigured(keyError: String?)
    /// An older server without the commands.
    case notAvailable
    /// Couldn't ask (offline, an error). Clean-up is still tried.
    case unknown(String)
}

/// The last answer to `get_dictation_refine_settings` per server, so a
/// dictation doesn't wait for it: each recording refreshes it while you speak.
actor DictationRefineStatusCache {
    static let shared = DictationRefineStatusCache()

    private struct Entry {
        let task: Task<DictationRefineAvailability, Never>
        let started: Date
    }

    private var entries: [String: Entry] = [:]

    /// The availability, asking the server when the answer is older than
    /// `maxAge` seconds. Concurrent callers share one request.
    func availability(of transport: any DictationRefineTransport, maxAge: TimeInterval) async -> DictationRefineAvailability {
        let key = transport.refineServerKey
        if let entry = entries[key], Date().timeIntervalSince(entry.started) < maxAge {
            return await entry.task.value
        }
        let task = Task { await Self.ask(transport) }
        let started = Date()
        entries[key] = Entry(task: task, started: started)
        let value = await task.value
        // Don't keep a failure to ask: the next dictation asks again.
        if case .unknown = value, entries[key]?.started == started { entries[key] = nil }
        return value
    }

    /// What `refine_dictation` itself revealed (an older server, or no
    /// provider) replaces the cached answer.
    func record(_ availability: DictationRefineAvailability, for key: String) {
        entries[key] = Entry(task: Task { availability }, started: Date())
    }

    func forget(_ key: String) { entries[key] = nil }

    private static func ask(_ transport: any DictationRefineTransport) async -> DictationRefineAvailability {
        do {
            let settings = try await transport.dictationRefineSettings()
            return settings.isSetUp ? .ready(settings) : .notConfigured(keyError: settings.keyError)
        } catch {
            if DictationRefineWire.isNotAvailable(error) { return .notAvailable }
            if DictationRefineWire.isNotConfigured(error) { return .notConfigured(keyError: nil) }
            return .unknown((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - Post-processing

/// Why the words were kept as spoken.
enum DictationRefineFallback: Equatable, Sendable {
    case notAvailable
    case notConfigured
    case timedOut
    /// Skipped from the strip, or the dictation was abandoned.
    case skipped
    case failed(String)
}

/// The text to insert, and what happened to it.
struct DictationRefineOutcome: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case asSpoken
        case refined(provider: String?, model: String?, elapsedMs: Int?)
        case kept(DictationRefineFallback)
    }

    var text: String
    var status: Status
    var mode: DictationRefineMode

    /// A short line for the composer's notice, when the words were kept.
    var notice: String? {
        guard case .kept(let reason) = status else { return nil }
        let what = mode == .translate ? "Translation" : "Clean-up"
        switch reason {
        case .skipped:
            return nil
        case .notConfigured:
            return "Set up translation in codeg Settings on your computer."
        case .notAvailable:
            return "This codeg server can't clean up dictation yet. Kept as spoken."
        case .timedOut:
            return "\(what) took too long. Kept as spoken."
        case .failed(let message):
            return "\(what) failed: \(message). Kept as spoken."
        }
    }
}

/// Runs between transcription and insert: sends the transcript to the codeg
/// server for clean-up or translation. Never throws and never loses the
/// words: on any failure, or after ``timeout``, it returns the original text.
struct TranscriptPostProcessor: Sendable {
    let transport: any DictationRefineTransport
    var timeout: Duration = .seconds(12)
    var cache: DictationRefineStatusCache = .shared
    /// How old a cached availability may be when a transcript is ready.
    var settingsMaxAge: TimeInterval = 300

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "dictation-refine")

    /// Ask the server whether clean-up is set up (cached; at most every 10 s).
    func availability(maxAge: TimeInterval = 10) async -> DictationRefineAvailability {
        await cache.availability(of: transport, maxAge: maxAge)
    }

    func process(_ text: String, mode: DictationRefineMode, sourceLanguage: String?) async -> DictationRefineOutcome {
        let original = text
        guard mode != .asSpoken, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DictationRefineOutcome(text: original, status: .asSpoken, mode: mode)
        }
        let started = ContinuousClock.now
        let outcome = await Self.race(
            timeout: timeout,
            timedOut: DictationRefineOutcome(text: original, status: .kept(.timedOut), mode: mode),
            cancelled: DictationRefineOutcome(text: original, status: .kept(.skipped), mode: mode)
        ) {
            await self.run(original, mode: mode, sourceLanguage: sourceLanguage)
        }
        let elapsed = (ContinuousClock.now - started).milliseconds
        switch outcome.status {
        case .refined(let provider, let model, let ms):
            Self.log.info("Refined (\(mode.rawValue, privacy: .public)) by \(provider ?? "?", privacy: .public) \(model ?? "", privacy: .public): \(ms ?? -1) ms on the server, \(elapsed) ms in all")
        case .kept(let reason):
            Self.log.notice("Kept as spoken (\(mode.rawValue, privacy: .public)): \(String(describing: reason), privacy: .public) after \(elapsed) ms")
        case .asSpoken:
            break
        }
        return outcome
    }

    private func run(_ text: String, mode: DictationRefineMode, sourceLanguage: String?) async -> DictationRefineOutcome {
        func kept(_ reason: DictationRefineFallback) -> DictationRefineOutcome {
            DictationRefineOutcome(text: text, status: .kept(reason), mode: mode)
        }
        var provider: String?
        switch await cache.availability(of: transport, maxAge: settingsMaxAge) {
        case .notAvailable: return kept(.notAvailable)
        case .notConfigured: return kept(.notConfigured)
        case .ready(let settings): provider = settings.provider
        case .unknown: break
        }
        if Task.isCancelled { return kept(.skipped) }
        do {
            let result = try await transport.refineDictation(
                DictationRefineRequest(text: text, mode: mode, sourceLanguage: sourceLanguage, provider: provider))
            let refined = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refined.isEmpty else { return kept(.failed("the server returned no text")) }
            return DictationRefineOutcome(
                text: refined,
                status: .refined(provider: result.provider, model: result.model, elapsedMs: result.elapsedMs),
                mode: mode)
        } catch is CancellationError {
            return kept(.skipped)
        } catch {
            if DictationRefineWire.isNotAvailable(error) {
                await cache.record(.notAvailable, for: transport.refineServerKey)
                return kept(.notAvailable)
            }
            if DictationRefineWire.isNotConfigured(error) {
                await cache.record(.notConfigured(keyError: nil), for: transport.refineServerKey)
                return kept(.notConfigured)
            }
            if Task.isCancelled { return kept(.skipped) }
            return kept(.failed(Self.shortMessage(error)))
        }
    }

    /// The server's own message when it sent one (codeg writes it for the
    /// user), otherwise the transport's.
    private static func shortMessage(_ error: Error) -> String {
        let text: String
        if case .server(_, _, let message)? = error as? APIError, !message.isEmpty {
            text = message
        } else {
            text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        return trimmed.count > 180 ? String(trimmed.prefix(177)) + "…" : trimmed
    }

    /// The operation's result, or `timedOut` after `timeout`, or `cancelled`
    /// when the calling task is cancelled, whichever comes first. Unlike a task
    /// group, it doesn't wait for a slow operation to wind down.
    static func race<T: Sendable>(
        timeout: Duration,
        timedOut: T,
        cancelled: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let gate = FirstResult<T>()
        let work = Task { gate.offer(await operation()) }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                gate.offer(timedOut)
            } catch {}
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { gate.wait($0) }
        } onCancel: {
            gate.offer(cancelled)
        }
        work.cancel()
        timer.cancel()
        return result
    }
}

private extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

/// Hands the first offered value to the one waiter; later offers are dropped.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var continuation: CheckedContinuation<T, Never>?
    private var done = false

    func offer(_ offered: T) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: offered)
        } else {
            value = offered
            lock.unlock()
        }
    }

    func wait(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value {
            self.value = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }
}
