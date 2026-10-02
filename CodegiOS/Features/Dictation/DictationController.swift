import Foundation
import Observation
import UIKit
import os

/// Settings for voice typing.
enum DictationPrefs {
    private static let defaults = UserDefaults.standard

    static var language: DictationLanguage {
        get { defaults.string(forKey: "codeg.dictation.language").flatMap(DictationLanguage.init) ?? .hebrew }
        set { defaults.set(newValue.rawValue, forKey: "codeg.dictation.language") }
    }

    /// Send the message as soon as the transcript is in the composer.
    static var autoSend: Bool {
        get { defaults.bool(forKey: "codeg.dictation.autoSend") }
        set { defaults.set(newValue, forKey: "codeg.dictation.autoSend") }
    }

    /// Bias whisper with the workspace folder, session title and code words.
    static var usePrompt: Bool {
        get { defaults.object(forKey: "codeg.dictation.usePrompt") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "codeg.dictation.usePrompt") }
    }
}

/// What the composer knows about where the dictation goes; it biases whisper.
struct DictationContext: Equatable, Sendable {
    var folder: String?
    var session: String?
}

/// How a dictation ended, delivered to the composer that started it.
enum DictationOutcome: Equatable {
    /// Insert this text; send right after when `send` is true.
    case text(String, send: Bool)
    /// Nothing to insert, with a short reason for the notice line.
    case nothing(String)
    case failed(String)
}

/// Runs voice typing: the microphone, Silero VAD trimming, and one whisper
/// decode over the whole recording (Speakly's dictation policy). One shared
/// instance, because there is one microphone.
@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var phase: Phase = .idle
    /// Smoothed input level, 0…1.
    private(set) var level: Float = 0
    /// Recent levels, oldest first, for the meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.meterBars)
    private(set) var elapsed: TimeInterval = 0
    /// The composer that owns the current dictation.
    private(set) var owner: UUID?

    var autoSend: Bool = DictationPrefs.autoSend {
        didSet { DictationPrefs.autoSend = autoSend }
    }

    static let meterBars = 24

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "dictation")
    private let recorder = DictationRecorder()
    private var engine: SpeechToText?
    private var vad: VoiceActivityDetector?
    private var vadModelPath: String?
    private var completion: ((DictationOutcome) -> Void)?
    private var options = TranscriptionOptions()
    private var meterTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var startedAt = Date()
    /// Bumped per dictation, so a late decode never lands in a newer one.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    /// The app went to the background during a decode, which was cancelled.
    private var decodeInterrupted = false

    /// Unload the model after this long without dictation.
    private static let idleUnload: Duration = .seconds(180)

    private init() {
        recorder.onInterrupted = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.unloadIfIdle() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // iOS doesn't let a background app use the GPU. Finish the
                // recording now; its decode waits for the app to come back. A
                // decode already running is stopped and run again then.
                switch self.phase {
                case .recording: self.stop()
                case .transcribing:
                    self.decodeInterrupted = true
                    self.engine?.cancel()
                case .idle: self.unloadIfIdle()
                }
            }
        })
    }

    var isBusy: Bool { phase != .idle }

    // MARK: - Availability

    enum Availability: Equatable {
        case ready
        /// The model for the language setting isn't on the phone yet.
        case needsModel(id: String)
        case microphoneDenied
    }

    func availability(language: DictationLanguage = DictationPrefs.language) -> Availability {
        guard let model = SpeechModelCatalog.model(for: language) else { return .needsModel(id: "") }
        guard SpeechModelStores.store(for: model).isReady else { return .needsModel(id: model.id) }
        if DictationRecorder.permission == .denied { return .microphoneDenied }
        return .ready
    }

    // MARK: - Start / stop

    /// Start recording for `owner`. The outcome arrives through `completion`
    /// once recording stops and the decode finishes.
    func start(owner: UUID, context: DictationContext, completion: @escaping (DictationOutcome) -> Void) async {
        guard phase == .idle else { return }
        let language = DictationPrefs.language
        guard let model = SpeechModelCatalog.model(for: language) else {
            completion(.failed("No speech model is configured."))
            return
        }
        let store = SpeechModelStores.store(for: model)
        guard store.isReady else {
            completion(.failed("Download the speech model in Settings › Voice first."))
            return
        }
        if DictationRecorder.permission != .granted {
            guard await DictationRecorder.requestPermission() else {
                completion(.failed("Allow the microphone for \(AppIdentity.displayName) in the Settings app."))
                return
            }
        }
        guard phase == .idle else { return }

        ReadAloudPlayer.shared.stop()
        do {
            try recorder.start()
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            completion(.failed("Couldn't start the microphone: \(error.localizedDescription)"))
            return
        }

        generation &+= 1
        self.owner = owner
        self.completion = completion
        options = TranscriptionOptions(
            language: language.whisperCode,
            prompt: DictationPrefs.usePrompt
                ? DictationText.prompt(folder: context.folder, session: context.session, language: language)
                : nil)
        phase = .recording
        startedAt = Date()
        elapsed = 0
        levels = Array(repeating: 0, count: Self.meterBars)
        unloadTask?.cancel()
        loadEngine(model: model, store: store)
        startMeter()
    }

    /// Stop recording and transcribe it.
    func stop() {
        guard phase == .recording else { return }
        meterTask?.cancel()
        let samples = recorder.stop()
        phase = .transcribing
        level = 0
        decodeInterrupted = false
        let generation = self.generation
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.transcribe(samples)
            self.finish(outcome, generation: generation)
        }
    }

    /// Stop and throw the recording away (or abandon a running decode).
    func cancel() {
        switch phase {
        case .idle:
            return
        case .recording:
            meterTask?.cancel()
            recorder.stop()
        case .transcribing:
            engine?.cancel()
            transcribeTask?.cancel()
        }
        completion = nil
        owner = nil
        phase = .idle
        level = 0
        scheduleUnload()
    }

    private func finish(_ outcome: DictationOutcome, generation: Int) {
        guard phase == .transcribing, generation == self.generation else { return }
        let completion = self.completion
        self.completion = nil
        owner = nil
        phase = .idle
        completion?(outcome)
        scheduleUnload()
    }

    // MARK: - Work

    private func loadEngine(model: SpeechModelManifest.Model, store: ModelPackStore) {
        if engine?.modelID != model.id {
            let old = engine
            Task { await old?.unload() }
            engine = WhisperCppEngine(modelID: model.id, modelURL: store.url(forPath: model.weights))
        }
        let vadPath = model.vad.map { store.url(forPath: $0).path }
        if vadPath != vadModelPath {
            vadModelPath = vadPath
            vad = vadPath.flatMap { SileroVAD(modelURL: URL(fileURLWithPath: $0)) }
            if vadPath != nil, vad == nil { log.error("Silero VAD failed to load; decoding untrimmed audio") }
        }
        // Load the weights while the user speaks.
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            do { try await engine?.prepare() } catch {
                // transcribe() reports it.
            }
        }
    }

    /// Trim with the VAD, then one decode over the speech. The heavy work runs
    /// off the main actor (the VAD in a detached task, whisper on its queue).
    private func transcribe(_ samples: [Float]) async -> DictationOutcome {
        guard let engine else { return .failed("The speech engine isn't loaded.") }
        let vad = self.vad
        let options = self.options
        let plan = await Task.detached(priority: .userInitiated) {
            DictationTrim.plan(totalSamples: samples.count, probabilities: vad?.speechProbabilities(samples))
        }.value
        switch plan {
        case .tooShort:
            return .nothing("Too short. Hold the mic while you speak, or tap once to start and again to stop.")
        case .noSpeech:
            return .nothing("No speech detected.")
        case .speech(let range):
            let clip = Array(samples[range])
            var retried = false
            while true {
                await waitUntilActive()
                if Task.isCancelled { return .nothing("Cancelled.") }
                do {
                    let result = try await engine.transcribe(clip, options: options)
                    let text = DictationText.clean(result.text)
                    return text.isEmpty ? .nothing("No speech detected.") : .text(text, send: autoSend)
                } catch SpeechToTextError.cancelled {
                    if decodeInterrupted, !retried, phase == .transcribing {
                        decodeInterrupted = false
                        retried = true
                        continue
                    }
                    return .nothing("Cancelled.")
                } catch {
                    if decodeInterrupted, !retried, phase == .transcribing {
                        // A GPU error from being sent to the background.
                        decodeInterrupted = false
                        retried = true
                        continue
                    }
                    return .failed(error.localizedDescription)
                }
            }
        }
    }

    /// The GPU is only available to the app in the foreground.
    private func waitUntilActive() async {
        while UIApplication.shared.applicationState != .active, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.phase == .recording else { return }
                let level = self.recorder.currentLevel
                self.level = level
                self.levels.removeFirst()
                self.levels.append(level)
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                if self.recorder.duration >= DictationRecorder.maxSeconds { self.stop() }
            }
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled else { return }
            self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard phase == .idle, let engine else { return }
        self.engine = nil
        Task { await engine.unload() }
        vad = nil
        vadModelPath = nil
        log.info("Unloaded the speech model")
    }
}
