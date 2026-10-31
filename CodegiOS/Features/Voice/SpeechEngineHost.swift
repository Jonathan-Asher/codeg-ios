import Foundation
import Observation
import UIKit
import os
import whisper

/// Speech in a live microphone stream, one probability per 32 ms frame, with
/// what the model remembers carried from frame to frame (unlike
/// ``VoiceActivityDetector``, whose every call starts afresh).
protocol StreamingVoiceActivityDetector: AnyObject, Sendable {
    /// The speech probability of each 512-sample frame of 16 kHz mono
    /// `samples`, in order (a shorter last frame is padded with silence), or
    /// nil on failure.
    func probabilities(_ samples: [Float]) -> [Float]?
    /// Forget what the frames so far left in the model's memory (between
    /// utterances).
    func reset()
}

extension StreamingVoiceActivityDetector {
    /// The speech probability of one frame (512 samples, 32 ms).
    func probability(of frame: [Float]) -> Float? {
        probabilities(frame)?.last
    }
}

/// Silero VAD for a live microphone (Talk): whisper.cpp v1.9.1's
/// `whisper_vad_detect_speech_no_reset`, which keeps the LSTM state between
/// calls, and `whisper_vad_reset_state` between utterances. A context of its
/// own, apart from the batch detector dictation trims with (``SileroVAD``),
/// whose every call resets the state. CPU, one thread.
final class StreamingSileroVAD: StreamingVoiceActivityDetector, @unchecked Sendable {
    static let frameSamples = 512

    private let context: OpaquePointer
    private let lock = NSLock()

    init?(modelURL: URL, threads: Int32 = 1) {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        var params = whisper_vad_default_context_params()
        params.use_gpu = false
        params.n_threads = threads
        guard let context = whisper_vad_init_from_file_with_params(modelURL.path, params) else { return nil }
        self.context = context
    }

    deinit { whisper_vad_free(context) }

    func probabilities(_ samples: [Float]) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return [] }
        let ok = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(context, buffer.baseAddress, Int32(buffer.count))
        }
        guard ok else { return nil }
        let count = Int(whisper_vad_n_probs(context))
        guard count > 0, let probs = whisper_vad_probs(context) else { return [] }
        return Array(UnsafeBufferPointer(start: probs, count: count))
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        whisper_vad_reset_state(context)
    }
}

/// The files the speech engines load: one speech model's whisper weights,
/// its Silero VAD and the small language-ID model.
struct SpeechEngineConfiguration: Equatable, Sendable {
    var whisperModelID: String
    var whisperURL: URL
    var vadURL: URL?
    /// Only once its download was verified.
    var languageIDURL: URL?

    init(whisperModelID: String, whisperURL: URL, vadURL: URL? = nil, languageIDURL: URL? = nil) {
        self.whisperModelID = whisperModelID
        self.whisperURL = whisperURL
        self.vadURL = vadURL
        self.languageIDURL = languageIDURL
    }

    /// A downloaded model's files. The language-ID model counts only once its
    /// download was verified (it may arrive after the model, see
    /// ``SpeechModelStores/completeIfUpdated(_:)``).
    @MainActor
    init(model: SpeechModelManifest.Model, store: ModelPackStore) {
        self.init(
            whisperModelID: model.id,
            whisperURL: store.url(forPath: model.weights),
            vadURL: model.vad.map { store.url(forPath: $0) },
            languageIDURL: model.languageID.flatMap { store.hasVerified([$0]) ? store.url(forPath: $0) : nil }
        )
    }
}

/// Makes the engines ``SpeechEngineHost`` holds: whisper.cpp in the app,
/// fakes in the tests.
protocol SpeechEngineFactory {
    func makeWhisper(modelID: String, url: URL) -> SpeechToText
    func makeLanguageID(url: URL) -> SpokenLanguageIdentifier
    func makeVAD(url: URL) -> VoiceActivityDetector?
    func makeStreamingVAD(url: URL) -> StreamingVoiceActivityDetector?
}

/// whisper.cpp's engines.
struct WhisperEngineFactory: SpeechEngineFactory {
    func makeWhisper(modelID: String, url: URL) -> SpeechToText { WhisperCppEngine(modelID: modelID, modelURL: url) }
    func makeLanguageID(url: URL) -> SpokenLanguageIdentifier { WhisperLanguageIdentifier(modelURL: url) }
    func makeVAD(url: URL) -> VoiceActivityDetector? { SileroVAD(modelURL: url) }
    func makeStreamingVAD(url: URL) -> StreamingVoiceActivityDetector? { StreamingSileroVAD(modelURL: url) }
}

/// Another engine kept alongside these (Talk's streaming transcriber, its
/// turn classifier), so one place loads and unloads them all.
@MainActor
protocol SpeechEngineAttachment: AnyObject {
    /// It runs on the CPU only, so it stays loaded in the background.
    var runsInBackground: Bool { get }
    /// Free its memory; the next use loads it again.
    func unload()
}

/// Who uses the speech engines; they stay loaded while any lease is held.
enum SpeechEngineLease: String, CaseIterable, Sendable {
    case dictation
    case talk
    case lab
}

/// The one set of on-device speech engines (no model loads twice): the
/// whisper model, the language-ID model, Silero VAD for trimming a recording
/// (batch) and for a live microphone (streaming), and whatever Talk attaches.
/// Voice typing, Talk and the Lab hold leases on it.
///
/// - Nothing loads until it is used (``preload(languageID:)``,
///   ``prepareWhisper()``, or a decode, which loads on demand).
/// - With no lease held, everything is unloaded after 180 s, or at once on
///   a memory warning or when the app goes to the background.
/// - In the background the GPU isn't available: whisper and the language-ID
///   model are unloaded unless dictation still holds them (its decode waits
///   for the app to come back); the VADs and CPU-only attachments stay for
///   Talk.
@MainActor
@Observable
final class SpeechEngineHost {
    static let shared = SpeechEngineHost()

    typealias Lease = SpeechEngineLease

    /// Who holds the engines now.
    private(set) var leases: Set<Lease> = []
    /// whisper's weights are in memory (a decode starts at once).
    private(set) var isWhisperLoaded = false

    /// The files in use; nil until the first ``use(_:)`` (and after an unload).
    @ObservationIgnored private(set) var configuration: SpeechEngineConfiguration?
    /// The whisper engine for ``configuration``. It loads its weights on first
    /// use; ``unloadWhisper()`` frees them but keeps the engine usable.
    @ObservationIgnored private(set) var whisper: SpeechToText?
    @ObservationIgnored private(set) var languageID: SpokenLanguageIdentifier?
    /// Silero VAD over a whole recording (dictation's trim). Nil when the
    /// model has none, or it failed to load.
    @ObservationIgnored private(set) var vad: VoiceActivityDetector?

    @ObservationIgnored private let factory: SpeechEngineFactory
    @ObservationIgnored private let idleUnload: Duration
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg",
                                                 category: "speech-engines")
    @ObservationIgnored private var streaming: StreamingVoiceActivityDetector?
    @ObservationIgnored private var attachments: [String: SpeechEngineAttachment] = [:]
    @ObservationIgnored private let loadState = EngineLoadState()
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `idleUnload`: how long the engines stay loaded with no lease.
    /// `notificationCenter`: where the memory warning and the move to the
    /// background are heard.
    init(factory: SpeechEngineFactory = WhisperEngineFactory(), idleUnload: Duration = .seconds(180),
         notificationCenter: NotificationCenter = .default) {
        self.factory = factory
        self.idleUnload = idleUnload
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        })
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
    }

    var isHeld: Bool { !leases.isEmpty }

    // MARK: - Leases

    /// `lease` uses the engines: nothing is unloaded while it holds them.
    func acquire(_ lease: Lease) {
        leases.insert(lease)
        unloadTask?.cancel()
        unloadTask = nil
    }

    /// `lease` is done; with no lease left, the engines go after the idle time.
    func release(_ lease: Lease) {
        guard leases.remove(lease) != nil, leases.isEmpty else { return }
        scheduleIdleUnload()
    }

    // MARK: - Engines

    /// Make the engines match `configuration`, creating the ones whose files
    /// changed (an old whisper or language-ID model is unloaded). Loads no
    /// weights.
    func use(_ configuration: SpeechEngineConfiguration) {
        let old = self.configuration
        if whisper == nil || old?.whisperModelID != configuration.whisperModelID
            || old?.whisperURL != configuration.whisperURL {
            let previous = whisper
            loadState.invalidate()
            isWhisperLoaded = false
            if let previous { Task { await previous.unload() } }
            whisper = TrackedSpeechToText(
                base: factory.makeWhisper(modelID: configuration.whisperModelID, url: configuration.whisperURL),
                state: loadState,
                loaded: { [weak self] epoch in Task { @MainActor in self?.whisperLoaded(epoch: epoch) } })
        }
        if old == nil || old?.vadURL != configuration.vadURL {
            vad = configuration.vadURL.flatMap { factory.makeVAD(url: $0) }
            streaming = nil
            if configuration.vadURL != nil, vad == nil {
                log.error("Silero VAD failed to load; decoding untrimmed audio")
            }
        }
        if old == nil || old?.languageIDURL != configuration.languageIDURL {
            let previous = languageID
            if let previous { Task { await previous.unload() } }
            languageID = configuration.languageIDURL.map { factory.makeLanguageID(url: $0) }
        }
        self.configuration = configuration
    }

    /// Load the weights in the background while the user speaks: the
    /// language-ID model first when `languageID`, then whisper. Failures
    /// surface when the engine is used.
    func preload(languageID wantsLanguageID: Bool) {
        let whisper = self.whisper
        let languageID = wantsLanguageID ? self.languageID : nil
        Task.detached(priority: .userInitiated) {
            do { try await languageID?.prepare() } catch {
                // Identifying the language falls back to Hebrew.
            }
            do { try await whisper?.prepare() } catch {
                // The decode reports it.
            }
        }
    }

    /// Load whisper's weights now and wait for them (Talk, once it has
    /// checked there is memory for them).
    func prepareWhisper() async throws {
        guard let whisper else { throw SpeechToTextError.modelMissing }
        try await whisper.prepare()
    }

    /// Free whisper's and the language-ID model's weights now (a memory
    /// warning in Talk, the background), keeping the engines usable: the next
    /// decode loads them again. The VADs and attachments stay.
    func unloadWhisper() {
        loadState.invalidate()
        isWhisperLoaded = false
        let whisper = self.whisper
        let languageID = self.languageID
        Task {
            await whisper?.unload()
            await languageID?.unload()
        }
    }

    /// The live microphone's Silero VAD (one context, for one stream at a
    /// time: Talk or the Lab), made on first use; nil without a VAD model.
    func streamingVAD() -> StreamingVoiceActivityDetector? {
        if let streaming { return streaming }
        guard let url = configuration?.vadURL else { return nil }
        streaming = factory.makeStreamingVAD(url: url)
        if streaming == nil { log.error("The streaming Silero VAD failed to load") }
        return streaming
    }

    /// Keep `engine` with these, under `key`, until it is detached or
    /// everything is unloaded.
    func attach(_ engine: SpeechEngineAttachment, as key: String) {
        attachments[key] = engine
    }

    func attachment(_ key: String) -> SpeechEngineAttachment? {
        attachments[key]
    }

    func detach(_ key: String) {
        attachments.removeValue(forKey: key)?.unload()
    }

    // MARK: - Unloading

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        let delay = idleUnload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.leases.isEmpty else { return }
            self.unloadTask = nil
            self.unloadAll(reason: "idle")
        }
    }

    private func memoryWarning() {
        guard leases.isEmpty else { return }
        unloadAll(reason: "memory warning")
    }

    private func enteredBackground() {
        if leases.isEmpty {
            unloadAll(reason: "background")
            return
        }
        // Dictation's decode waits for the app to come back, and needs them.
        guard !leases.contains(.dictation) else { return }
        if whisper != nil { unloadWhisper() }
        for engine in attachments.values where !engine.runsInBackground { engine.unload() }
    }

    /// Unload everything (no lease holds it).
    private func unloadAll(reason: String) {
        unloadTask?.cancel()
        unloadTask = nil
        guard whisper != nil || languageID != nil || vad != nil || streaming != nil || !attachments.isEmpty
        else { return }
        let whisper = self.whisper
        let languageID = self.languageID
        loadState.invalidate()
        isWhisperLoaded = false
        self.whisper = nil
        self.languageID = nil
        vad = nil
        streaming = nil
        configuration = nil
        let attached = attachments.values
        attachments = [:]
        for engine in attached { engine.unload() }
        Task {
            await whisper?.unload()
            await languageID?.unload()
        }
        log.info("Unloaded the speech engines (\(reason, privacy: .public))")
    }

    private func whisperLoaded(epoch: Int) {
        guard loadState.isCurrent(epoch) else { return }
        isWhisperLoaded = true
    }
}

/// Which loads still count: every unload starts a new epoch, so a load that
/// finishes after it doesn't mark the weights as loaded.
private final class EngineLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    func invalidate() {
        lock.lock()
        epoch += 1
        lock.unlock()
    }

    func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == epoch
    }
}

/// whisper behind ``SpeechToText``, telling the host when its weights are in
/// memory (a load or a decode that worked).
private final class TrackedSpeechToText: SpeechToText, @unchecked Sendable {
    private let base: SpeechToText
    private let state: EngineLoadState
    private let loaded: @Sendable (Int) -> Void

    init(base: SpeechToText, state: EngineLoadState, loaded: @escaping @Sendable (Int) -> Void) {
        self.base = base
        self.state = state
        self.loaded = loaded
    }

    var modelID: String { base.modelID }

    func prepare() async throws {
        let epoch = state.current
        try await base.prepare()
        loaded(epoch)
    }

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcription {
        let epoch = state.current
        let result = try await base.transcribe(samples, options: options)
        loaded(epoch)
        return result
    }

    func cancel() { base.cancel() }

    func unload() async { await base.unload() }
}
