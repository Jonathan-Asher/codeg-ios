import AVFoundation
import Foundation
import Observation
import UIKit
import os

/// Settings for voice typing.
enum DictationPrefs {
    private static let defaults = UserDefaults.standard

    static var language: DictationLanguage {
        get {
            migrateLanguage()
            return defaults.string(forKey: "codeg.dictation.language").flatMap(DictationLanguage.init) ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: "codeg.dictation.language") }
    }

    /// Up to 1.3.0, Hebrew was the default and the only way to get the
    /// ivrit.ai model's Hebrew. "Hebrew or English" does the same for Hebrew
    /// and also catches English, so a stored Hebrew moves to it, once.
    private static func migrateLanguage() {
        let key = "codeg.dictation.languageMigrated"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        if defaults.string(forKey: "codeg.dictation.language") == DictationLanguage.hebrew.rawValue {
            defaults.set(DictationLanguage.hebrewOrEnglish.rawValue, forKey: "codeg.dictation.language")
        }
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
    /// Language for this dictation. Starts from Settings › Voice; the strip's
    /// chip changes it for this one message.
    var languageThisTime: DictationLanguageChoice = .automatic
    /// Where `languageThisTime` started, so the strip can show an override.
    private(set) var languageDefault: DictationLanguageChoice = .automatic

    /// Enough history for the widest meter (thin bars, newest at the trailing edge).
    static let meterBars = 64

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "dictation")
    private let recorder = DictationRecorder()
    private var engine: SpeechToText?
    private var vad: VoiceActivityDetector?
    private var vadModelPath: String?
    /// The small model that tells Hebrew from English, when it's downloaded.
    private var languageID: SpokenLanguageIdentifier?
    private var languageIDPath: String?
    private var completion: ((DictationOutcome) -> Void)?
    private var context = DictationContext()
    private var usePrompt = true
    private var postProcessor: TranscriptPostProcessor?
    private var language: DictationLanguage = .default
    /// The language the transcript was decoded in, for the clean-up request;
    /// `nil` when the stock model detected it.
    private var decodedLanguage: String?
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
    /// Camera Control to talk wants the microphone standing by (pre-roll).
    private var preRollWanted = false
    /// Read aloud has the audio session; standby steps aside meanwhile.
    private var readAloudActive = false
    private var preRollRetry: Task<Void, Never>?

    /// Unload the model after this long without dictation.
    private static let idleUnload: Duration = .seconds(180)

    private init() {
        recorder.onInterrupted = { [weak self] in
            // A call or Siri cut the recording short: transcribe it, but leave
            // it in the composer rather than sending half a message.
            Task { @MainActor in self?.stop(keepUnsent: "The recording was interrupted, so it wasn't sent.") }
        }
        recorder.onStandbyLost = { [weak self] in
            Task { @MainActor in self?.standbyLost() }
        }
        let center = NotificationCenter.default
        // Posted on the main thread, before read aloud changes the session.
        observers.append(center.addObserver(forName: .readAloudWillClaimAudio, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readAloudActive = true
                self?.updatePreRoll()
            }
        })
        observers.append(center.addObserver(forName: .readAloudDidReleaseAudio, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readAloudActive = false
                self?.updatePreRoll()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            Task { @MainActor in self?.updatePreRoll() }
        })
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

    // MARK: - The strip's chips

    /// The strip's "after transcribing" chip. It is the setting itself
    /// (Settings › Voice › Voice Typing › After transcribing): picking
    /// "To English" there keeps every later dictation in English until it is
    /// changed again. It also applies to the dictation under way.
    func chooseRefineMode(_ mode: DictationRefineMode) {
        refineThisTime = mode
        DictationPrefs.afterTranscribing = mode
    }

    /// The strip's language chip: this message only. A sticky English would
    /// turn every later Hebrew dictation into English.
    func chooseLanguage(_ choice: DictationLanguageChoice) {
        languageThisTime = choice
    }

    // MARK: - Pre-roll (Camera Control to talk)

    /// Keep the microphone standing by with the last 1.5 s in memory, so a
    /// Camera Control press starts with the words said as it went down.
    /// ``CameraTalkController`` turns it on while the mode runs for a visible
    /// session and "Catch the first words" is on, and off otherwise (mode
    /// off, screen left, app in the background, camera interrupted).
    func setPreRoll(_ wanted: Bool) {
        guard preRollWanted != wanted else { return }
        preRollWanted = wanted
        preRollRetry?.cancel()
        CameraTalkController.log.info("Pre-roll \(wanted ? "wanted" : "off", privacy: .public)")
        updatePreRoll()
    }

    /// Start or stop standby to match what is wanted now.
    private func updatePreRoll(attempt: Int = 0) {
        let should = preRollWanted && !readAloudActive && DictationRecorder.permission == .granted
            && UIApplication.shared.applicationState != .background
        guard should else {
            recorder.stopStandby()
            return
        }
        guard !recorder.isStandingBy else { return }
        do {
            let started = ContinuousClock.now
            try recorder.startStandby()
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            CameraTalkController.log.info("Microphone standing by (started in \(ms) ms)")
        } catch {
            CameraTalkController.log.error("Standby didn't start: \(AudioErrorText(error).logLine, privacy: .public)")
            retryPreRoll(attempt: attempt + 1)
        }
    }

    /// Standby lost the microphone (a call, Siri, a route change).
    private func standbyLost() {
        CameraTalkController.log.notice("Standby lost the microphone")
        retryPreRoll(attempt: 1)
    }

    private func retryPreRoll(attempt: Int) {
        preRollRetry?.cancel()
        guard preRollWanted, attempt <= 5 else { return }
        preRollRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(attempt == 1 ? 1 : 3))
            guard !Task.isCancelled else { return }
            self?.updatePreRoll(attempt: attempt)
        }
    }

    // MARK: - Availability

    enum Availability: Equatable {
        case ready
        /// The model for the language setting isn't on the phone yet.
        case needsModel(id: String)
        case microphoneDenied
    }

    func availability(language: DictationLanguage = DictationPrefs.language) -> Availability {
        guard let model = SpeechModelCatalog.model(for: language) else { return .needsModel(id: "") }
        guard SpeechModelStores.store(for: model).hasVerified(model.requiredPaths) else {
            return .needsModel(id: model.id)
        }
        if DictationRecorder.permission == .denied { return .microphoneDenied }
        return .ready
    }

    // MARK: - Start / stop

    /// Start recording for `owner`. The outcome arrives through `completion`
    /// once recording stops, the decode finishes and, when clean-up is on,
    /// `postProcessor` has answered. `pressUptime` is when the Camera Control
    /// went down (`ProcessInfo.systemUptime`), for the log.
    func start(owner: UUID, source: DictationSource = .mic, context: DictationContext,
               postProcessor: TranscriptPostProcessor? = nil, pressUptime: TimeInterval? = nil,
               completion: @escaping (DictationOutcome) -> Void) async {
        guard phase == .idle else { return }
        let language = DictationPrefs.language
        guard let model = SpeechModelCatalog.model(for: language) else {
            completion(.failed("No speech model is configured."))
            return
        }
        let store = SpeechModelStores.store(for: model)
        guard store.hasVerified(model.requiredPaths) else {
            completion(.failed("Download the speech model in Settings › Voice first."))
            return
        }
        // A file added to the model since it was downloaded (the language-ID
        // model): fetch just that, and work without it meanwhile.
        SpeechModelStores.completeIfUpdated(model)
        if DictationRecorder.permission != .granted {
            guard await DictationRecorder.requestPermission() else {
                completion(.failed("Allow the microphone for \(AppIdentity.displayName) in the Settings app."))
                return
            }
        }
        guard phase == .idle else { return }

        // Stopping a reply read aloud lets go of `.playback`; standby (when
        // wanted) takes the session back at once, so the recording below
        // starts from the running engine instead of activating again.
        ReadAloudPlayer.shared.stop()
        do {
            // A Camera Control press starts with the pre-roll, when the
            // microphone was standing by: the words said as it went down.
            let started = try recorder.start(includePreRoll: source == .cameraControl, pressUptime: pressUptime)
            switch started {
            case .fromStandby: log.info("Recording from the standing-by microphone")
            case .started(let use): log.info("Microphone started for the recording (\(use.rawValue, privacy: .public))")
            }
        } catch {
            let text = AudioErrorText(error)
            log.error("Recording failed to start: \(text.logLine, privacy: .public)")
            completion(.failed(text.message("Couldn't start the microphone")))
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
        languageDefault = language.defaultChoice
        languageThisTime = languageDefault
        decodedLanguage = nil
        pendingNote = nil
        refineOffered = postProcessor == nil ? false : nil
        self.context = context
        usePrompt = DictationPrefs.usePrompt
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
        updatePreRoll()
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
            updatePreRoll()
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
        // The language-ID model only counts once its download was verified.
        let languageIDPath = model.languageID.flatMap { path in
            store.hasVerified([path]) ? store.url(forPath: path).path : nil
        }
        if languageIDPath != self.languageIDPath {
            let old = languageID
            Task { await old?.unload() }
            self.languageIDPath = languageIDPath
            languageID = languageIDPath.map { WhisperLanguageIdentifier(modelURL: URL(fileURLWithPath: $0)) }
        }
        // Load the weights while the user speaks.
        let engine = self.engine
        let languageID = language.plan(choice: languageThisTime) == .hebrewOrEnglish ? self.languageID : nil
        Task.detached(priority: .userInitiated) {
            do { try await languageID?.prepare() } catch {
                // identifyLanguage() falls back to Hebrew.
            }
            do { try await engine?.prepare() } catch {
                // transcribe() reports it.
            }
        }
    }

    /// Hebrew or English for "Hebrew or English": the language-ID model's
    /// call, leaning to Hebrew. Without the model, or if it fails, Hebrew.
    private func identifyLanguage(_ clip: [Float]) async -> String {
        guard let languageID else {
            log.info("No language-ID model; transcribing as Hebrew")
            return "he"
        }
        let started = ContinuousClock.now
        do {
            let probabilities = try await languageID.probabilities(
                SpokenLanguageDecision.window(of: clip), among: SpokenLanguageDecision.candidates)
            let code = SpokenLanguageDecision.language(for: probabilities)
            let english = probabilities["en"] ?? 0
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.info("Language \(code, privacy: .public): p(en) \(english, format: .fixed(precision: 5)) in \(ms) ms")
            return code
        } catch {
            log.error("Language ID failed (\(error.localizedDescription, privacy: .public)); transcribing as Hebrew")
            return "he"
        }
    }

    /// Trim with the VAD, then one decode over the speech. The heavy work runs
    /// off the main actor (the VAD in a detached task, whisper on its queue).
    private func transcribe(_ samples: [Float]) async -> DictationOutcome {
        guard let engine else { return .failed("The speech engine isn't loaded.") }
        let vad = self.vad
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
            var spoken: String?
            while true {
                await waitUntilActive()
                if Task.isCancelled { return .nothing("Cancelled.") }
                // Read the chip now: it may have changed while recording.
                switch language.plan(choice: languageThisTime) {
                case .forced(let code): spoken = code
                case .detectAny: spoken = nil
                case .hebrewOrEnglish:
                    if spoken == nil { spoken = await identifyLanguage(clip) }
                }
                if Task.isCancelled { return .nothing("Cancelled.") }
                decodedLanguage = spoken
                let options = TranscriptionOptions(
                    language: spoken,
                    prompt: usePrompt
                        ? DictationText.prompt(folder: context.folder, session: context.session, language: spoken)
                        : nil)
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
            let result = await postProcessor.process(words, mode: mode, sourceLanguage: decodedLanguage)
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
        let languageID = self.languageID
        self.languageID = nil
        languageIDPath = nil
        Task { await languageID?.unload() }
        vad = nil
        vadModelPath = nil
        log.info("Unloaded the speech model")
    }
}
