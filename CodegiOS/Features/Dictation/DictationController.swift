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

    /// Insert as spoken, or clean up (and translate) through the codeg server.
    static var afterTranscribing: DictationRefineMode {
        get {
            defaults.string(forKey: "codeg.dictation.afterTranscribing").flatMap(DictationRefineMode.init) ?? .asSpoken
        }
        set { defaults.set(newValue.rawValue, forKey: "codeg.dictation.afterTranscribing") }
    }
}

/// What started a dictation.
enum DictationSource: Equatable, Sendable {
    /// The mic button in the message bar.
    case mic
    /// Holding the Camera Control (or a volume button) in walkie-talkie mode.
    case cameraControl
}

/// What the composer knows about where the dictation goes; it biases whisper.
struct DictationContext: Equatable, Sendable {
    var folder: String?
    var session: String?
}

/// How a dictation ended, delivered to the composer that started it.
enum DictationOutcome: Equatable {
    /// Insert this text; send right after when `send` is true. `notice` says
    /// what went wrong on the way (the words were kept as spoken), if anything.
    case text(String, send: Bool, notice: String? = nil)
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
        /// The codeg server is cleaning up or translating the transcript.
        case refining
    }

    private(set) var phase: Phase = .idle
    /// Smoothed input level, 0…1.
    private(set) var level: Float = 0
    /// Recent levels, oldest first, for the meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.meterBars)
    private(set) var elapsed: TimeInterval = 0
    /// The composer that owns the current dictation.
    private(set) var owner: UUID?
    /// What started the current dictation.
    private(set) var source: DictationSource = .mic

    var autoSend: Bool = DictationPrefs.autoSend {
        didSet { DictationPrefs.autoSend = autoSend }
    }

    /// Send this dictation once it is in the composer. Starts from the "Send"
    /// setting for the mic, and on for the Camera Control; the strip's switch
    /// changes it.
    var sendThisTime = false
    /// Clean-up for this dictation. Starts from Settings › Voice; the strip's
    /// chip changes it for this one message.
    var refineThisTime: DictationRefineMode = .asSpoken
    /// Whether the composer's server can clean up dictation: `false` for an
    /// older server, `nil` while unknown. Hides the strip's chip when false.
    private(set) var refineOffered: Bool?

    static let meterBars = 24

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "dictation")
    private let recorder = DictationRecorder()
    private var engine: SpeechToText?
    private var vad: VoiceActivityDetector?
    private var vadModelPath: String?
    private var completion: ((DictationOutcome) -> Void)?
    private var options = TranscriptionOptions()
    private var postProcessor: TranscriptPostProcessor?
    private var language: DictationLanguage = .hebrew
    /// Said with the inserted text when the dictation ended early (an
    /// interruption), which also holds back the send.
    private var pendingNote: String?
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
            // A call or Siri cut the recording short: transcribe it, but leave
            // it in the composer rather than sending half a message.
            Task { @MainActor in self?.stop(keepUnsent: "The recording was interrupted, so it wasn't sent.") }
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
                case .recording:
                    self.stop(keepUnsent: self.source == .cameraControl
                        ? "The app left the screen while you held the Camera Control, so it wasn't sent." : nil)
                case .transcribing:
                    self.decodeInterrupted = true
                    self.engine?.cancel()
                case .refining:
                    // The server call finishes or times out when the app is back.
                    break
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
    /// once recording stops, the decode finishes and, when clean-up is on,
    /// `postProcessor` has answered.
    func start(owner: UUID, source: DictationSource = .mic, context: DictationContext,
               postProcessor: TranscriptPostProcessor? = nil,
               completion: @escaping (DictationOutcome) -> Void) async {
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
        self.source = source
        self.completion = completion
        self.postProcessor = postProcessor
        self.language = language
        sendThisTime = source == .cameraControl ? true : autoSend
        refineThisTime = DictationPrefs.afterTranscribing
        pendingNote = nil
        refineOffered = postProcessor == nil ? false : nil
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
        checkRefine(generation: generation)
    }

    /// Stop recording and transcribe it. With `keepUnsent`, a dictation that
    /// would have been sent goes into the composer unsent, and the note says why.
    func stop(keepUnsent note: String? = nil) {
        guard phase == .recording else { return }
        if let note, sendThisTime {
            sendThisTime = false
            pendingNote = note
        }
        meterTask?.cancel()
        let samples = recorder.stop()
        phase = .transcribing
        level = 0
        decodeInterrupted = false
        let generation = self.generation
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            let transcript = await self.transcribe(samples)
            guard generation == self.generation, self.phase == .transcribing else { return }
            let outcome = await self.postProcess(transcript)
            self.finish(outcome, generation: generation)
        }
    }

    /// While the server cleans up: stop waiting and insert the words as spoken.
    func skipRefine() {
        guard phase == .refining else { return }
        log.info("Clean-up skipped from the strip")
        transcribeTask?.cancel()
    }

    /// Stop and throw the recording away (or abandon a running decode). While
    /// the server cleans up, the words are kept as spoken instead.
    func cancel() {
        switch phase {
        case .idle:
            return
        case .refining:
            skipRefine()
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
        guard phase == .transcribing || phase == .refining, generation == self.generation else { return }
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
            return .nothing(source == .cameraControl
                ? "Too short. Hold the Camera Control while you speak."
                : "Too short. Hold the mic while you speak, or tap once to start and again to stop.")
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
                    return text.isEmpty ? .nothing("No speech detected.") : .text(text, send: false)
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

    /// Clean-up through the codeg server, then the send decision and any
    /// note. Never drops the words: the processor falls back to them.
    private func postProcess(_ transcript: DictationOutcome) async -> DictationOutcome {
        guard case .text(let words, _, _) = transcript else { return transcript }
        var text = words
        var notes: [String] = []
        let mode = refineThisTime
        if mode != .asSpoken, let postProcessor {
            phase = .refining
            let result = await postProcessor.process(words, mode: mode, sourceLanguage: language.whisperCode)
            text = result.text
            if let notice = result.notice { notes.append(notice) }
            if case .kept(.notAvailable) = result.status { refineOffered = false }
        }
        if let pendingNote { notes.append(pendingNote) }
        return .text(text, send: sendThisTime, notice: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Ask the composer's server, while the user speaks, whether it can clean
    /// up dictation, so the strip knows whether to offer it and the answer
    /// is cached by the time the transcript is ready.
    private func checkRefine(generation: Int) {
        guard let postProcessor else { return }
        Task { [weak self] in
            let availability = await postProcessor.availability()
            guard let self, generation == self.generation else { return }
            switch availability {
            case .notAvailable: self.refineOffered = false
            case .ready, .notConfigured: self.refineOffered = true
            case .unknown: break
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
