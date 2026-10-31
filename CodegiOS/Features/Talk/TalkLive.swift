import AVFoundation
import CallKit
import MediaPlayer
import Observation
import UIKit
import os
import BlueTTSKit
import SherpaOnnx
import SmartTurn

// Talk's engines, device and server in the app (the controller sees them
// through TalkDependencies.swift).

// MARK: - Listening

/// Silero, streaming, as Talk's VAD.
final class SileroSpeechActivity: SpeechActivity {
    private let detector: StreamingVoiceActivityDetector

    init(_ detector: StreamingVoiceActivityDetector) {
        self.detector = detector
    }

    func probability(_ frame: [Float]) -> Float { detector.probability(of: frame) ?? 0 }

    func reset() { detector.reset() }
}

/// The streaming Zipformer, kept with the speech engines
/// (``SpeechEngineHost/attach(_:as:)``) so Talk and the Lab load it once. CPU
/// only: it stays in the background.
@MainActor
final class ZipformerEngine: SpeechEngineAttachment {
    static let key = "talk.zipformer"

    private(set) var recognizer: StreamingTransducerRecognizer?

    init(recognizer: StreamingTransducerRecognizer) {
        self.recognizer = recognizer
    }

    var runsInBackground: Bool { true }

    func unload() { recognizer = nil }

    /// The loaded one, or a new one from the downloaded model (off the main
    /// thread: it takes a fraction of a second).
    static func shared(host: SpeechEngineHost = .shared) async throws -> StreamingTransducerRecognizer {
        if let engine = host.attachment(key) as? ZipformerEngine, let recognizer = engine.recognizer { return recognizer }
        guard let model = TalkModels.zipformerParts() else { throw TalkStartError.modelsMissing }
        let recognizer = try await Task.detached(priority: .userInitiated) {
            try StreamingTransducerRecognizer(files: TransducerModelFiles(directory: model.directory, parts: model.parts),
                                              threads: 2)
        }.value
        host.attach(ZipformerEngine(recognizer: recognizer), as: key)
        return recognizer
    }
}

/// Smart Turn, kept with the speech engines like the Zipformer.
@MainActor
final class SmartTurnEngine: SpeechEngineAttachment {
    static let key = "talk.smartTurn"

    private(set) var classifier: SmartTurnClassifier?

    init(classifier: SmartTurnClassifier) {
        self.classifier = classifier
    }

    var runsInBackground: Bool { true }

    func unload() { classifier = nil }

    static func shared(host: SpeechEngineHost = .shared) async -> SmartTurnClassifier? {
        if let engine = host.attachment(key) as? SmartTurnEngine, let classifier = engine.classifier { return classifier }
        guard let url = TalkModels.smartTurnURL() else { return nil }
        let classifier = try? await Task.detached(priority: .userInitiated) {
            try SmartTurnClassifier(modelURL: url, threads: 2)
        }.value
        if let classifier { host.attach(SmartTurnEngine(classifier: classifier), as: key) }
        return classifier
    }
}

/// The Zipformer as Talk's live transcriber. It keeps the utterance's audio
/// for the check at a pause (a fresh pass over the last 3 s).
final class ZipformerTranscriber: LiveTranscriber, @unchecked Sendable {
    private let recognizer: StreamingTransducerRecognizer
    private let lock = NSLock()
    private var audio: [Float] = []
    private var lastPartial = ""

    /// The audio a pause's check reads.
    static let tailSeconds = 3.0

    init(recognizer: StreamingTransducerRecognizer) {
        self.recognizer = recognizer
    }

    func begin(preRoll: [Float]) {
        recognizer.reset()
        lock.withLock {
            audio = preRoll
            lastPartial = ""
        }
        if !preRoll.isEmpty { _ = accept(preRoll, keep: false) }
    }

    func accept(_ samples: [Float]) -> String? {
        accept(samples, keep: true)
    }

    private func accept(_ samples: [Float], keep: Bool) -> String? {
        if keep { lock.withLock { audio.append(contentsOf: samples) } }
        let text = recognizer.accept(samples: samples)
        return lock.withLock {
            guard text != lastPartial else { return nil }
            lastPartial = text
            return text
        }
    }

    func flushTail() -> String {
        let tail = lock.withLock {
            let count = Int(Self.tailSeconds * Double(StreamingTransducerRecognizer.sampleRate))
            return audio.count <= count ? audio : Array(audio.suffix(count))
        }
        return recognizer.transcribeOnce(samples: tail)
    }

    func finish() -> String {
        recognizer.inputFinished()
    }

    func reset() {
        recognizer.reset()
        lock.withLock {
            audio = []
            lastPartial = ""
        }
    }

    func transcribeOnce(_ clip: [Float]) -> String {
        recognizer.transcribeOnce(samples: clip)
    }
}

/// whisper for the final transcript, with voice typing's language plan and
/// its prompt (the folder, the session's title and code words).
final class WhisperFinalTranscriber: FinalTranscriber, @unchecked Sendable {
    private let engine: SpeechToText
    private let languageID: SpokenLanguageIdentifier?
    private let plan: DictationLanguagePlan
    private let prompt: @Sendable (String?) -> String?

    init(engine: SpeechToText, languageID: SpokenLanguageIdentifier?, plan: DictationLanguagePlan,
         prompt: @escaping @Sendable (String?) -> String?) {
        self.engine = engine
        self.languageID = languageID
        self.plan = plan
        self.prompt = prompt
    }

    func transcribe(_ clip: [Float]) async throws -> String {
        let language: String?
        switch plan {
        case .forced(let code): language = code
        case .detectAny: language = nil
        case .hebrewOrEnglish: language = await identify(clip)
        }
        let options = TranscriptionOptions(language: language, prompt: prompt(language))
        let result = try await engine.transcribe(clip, options: options)
        return DictationText.clean(result.text)
    }

    func cancel() { engine.cancel() }

    private func identify(_ clip: [Float]) async -> String {
        guard let languageID else { return "he" }
        let probabilities = try? await languageID.probabilities(SpokenLanguageDecision.window(of: clip),
                                                                among: SpokenLanguageDecision.candidates)
        return SpokenLanguageDecision.language(for: probabilities)
    }
}

/// Smart Turn as Talk's turn-end classifier.
final class SmartTurnTurnEnd: TurnEndClassifier {
    private let classifier: SmartTurnClassifier

    init(_ classifier: SmartTurnClassifier) {
        self.classifier = classifier
    }

    func probability(last8s: [Float]) async -> Float? {
        await classifier.probability(last8s: last8s)
    }
}

// MARK: - Speaking

/// BlueTTS on the shared voice (``VoiceEngineHost``), with read aloud's voice
/// and speed. A reply's first unit gets a short first chunk.
@MainActor
final class BlueVoiceSynthesizer: Synthesizer {
    func synthesize(_ unit: SpeechUnit) -> AsyncThrowingStream<SpeechChunk, Error> {
        var options = SynthesisOptions()
        options.voice = VoicePrefs.voice
        options.speed = VoicePrefs.speed
        switch unit.language {
        case .hebrew: options.language = .hebrew
        case .english: options.language = .english
        case .auto: options.language = .auto
        }
        let stream: AsyncThrowingStream<AudioChunk, Error>
        do {
            stream = try VoiceEngineHost.shared.synthesizeStream(unit.text, options: options,
                                                                 firstChunkMaxChars: unit.isFirstOfReply ? 90 : 400)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in stream {
                        continuation.yield(SpeechChunk(samples: chunk.samples, sampleRate: Double(chunk.sampleRate)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The iPhone's own Hebrew and English voices, when BlueTTS isn't
/// downloaded: rendered to samples (`AVSpeechSynthesizer.write`) and played
/// on Talk's engine, so echo cancellation still hears them.
@MainActor
final class SystemVoiceSynthesizer: Synthesizer {
    private var synthesizers: [AVSpeechSynthesizer] = []

    func synthesize(_ unit: SpeechUnit) -> AsyncThrowingStream<SpeechChunk, Error> {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.4, max(0.7, VoicePrefs.speed)))
        let runs = SpeechText.scriptRuns(unit.text).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let synthesizer = AVSpeechSynthesizer()
        synthesizers.append(synthesizer)
        return AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                for run in runs {
                    let utterance = AVSpeechUtterance(string: run.text)
                    utterance.voice = AVSpeechSynthesisVoice(language: run.isHebrew ? "he-IL" : "en-US")
                    utterance.rate = rate
                    for chunk in await Self.render(utterance, with: synthesizer) {
                        continuation.yield(chunk)
                    }
                }
                continuation.finish()
                self?.synthesizers.removeAll { $0 === synthesizer }
            }
        }
    }

    /// What a render collected, filled on the synthesizer's thread.
    private final class Render: @unchecked Sendable {
        let lock = NSLock()
        var chunks: [SpeechChunk] = []
        var done = false
    }

    /// One utterance as mono float chunks (none when there is no voice for
    /// its language).
    private static func render(_ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer) async -> [SpeechChunk] {
        guard utterance.voice != nil else { return [] }
        let render = Render()
        return await withCheckedContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                render.lock.lock()
                guard !render.done else {
                    render.lock.unlock()
                    return
                }
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    if let chunk = Self.chunk(pcm) { render.chunks.append(chunk) }
                    render.lock.unlock()
                } else {
                    // An empty buffer ends the utterance.
                    render.done = true
                    let chunks = render.chunks
                    render.lock.unlock()
                    continuation.resume(returning: chunks)
                }
            }
        }
    }

    nonisolated private static func chunk(_ buffer: AVAudioPCMBuffer) -> SpeechChunk? {
        let count = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        if let data = buffer.floatChannelData?[0] {
            return SpeechChunk(samples: Array(UnsafeBufferPointer(start: data, count: count)), sampleRate: rate)
        }
        if let data = buffer.int16ChannelData?[0] {
            let samples = UnsafeBufferPointer(start: data, count: count).map { Float($0) / 32_768 }
            return SpeechChunk(samples: samples, sampleRate: rate)
        }
        return nil
    }
}

// MARK: - The device

/// Talk's device side in the app: the shared engines and their leases, the
/// idle timer, the Lock Screen, memory and the app's moves.
@MainActor
final class LiveTalkSystem: TalkSystem {
    var onEvent: ((TalkSystemEvent) -> Void)?

    private let speech: SpeechEngineHost
    private let voice: VoiceEngineHost
    /// For whisper's prompt.
    private let folder: String?
    private let session: String?
    private var whisperReady = false
    private var leased = false
    private var observers: [NSObjectProtocol] = []
    private let callObserver = CXCallObserver()
    private let remote = TalkRemoteControl()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "talk")

    init(folder: String?, session: String?, speech: SpeechEngineHost = .shared, voice: VoiceEngineHost = .shared) {
        self.folder = folder
        self.session = session
        self.speech = speech
        self.voice = voice
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.memoryWarning) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.enteredBackground) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.willEnterForeground) }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func loadEngines() async throws -> TalkEngineSet {
        guard TalkModels.missingRequired.isEmpty, let setup = TalkModels.engineConfiguration() else {
            throw TalkStartError.modelsMissing
        }
        speech.acquire(.talk)
        voice.acquire(.talk)
        voice.setThreadCap(4)
        leased = true
        speech.use(setup.configuration)
        whisperReady = setup.whisperReady
        let recognizer: StreamingTransducerRecognizer
        do {
            recognizer = try await ZipformerEngine.shared(host: speech)
        } catch {
            log.error("The Zipformer didn't load: \(String(describing: error), privacy: .public)")
            throw TalkStartError("Talk's live transcription didn't load. Delete its model in Settings › Voice › Talk and download it again.")
        }
        let smartTurn = await SmartTurnEngine.shared(host: speech)
        guard let vad = speech.streamingVAD() else {
            throw TalkStartError("Talk's voice detection didn't load. Delete its model in Settings › Voice › Talk and download it again.")
        }
        let natural = VoiceModelStore.shared.isReady
        let synthesizer: Synthesizer
        if natural {
            synthesizer = BlueVoiceSynthesizer()
            do {
                try await voice.preload()
            } catch {
                log.error("BlueTTS didn't preload: \(String(describing: error), privacy: .public)")
            }
        } else {
            synthesizer = SystemVoiceSynthesizer()
        }
        return TalkEngineSet(vad: SileroSpeechActivity(vad), live: ZipformerTranscriber(recognizer: recognizer),
                             turn: smartTurn.map(SmartTurnTurnEnd.init), synthesizer: synthesizer, naturalVoice: natural)
    }

    func releaseEngines() {
        guard leased else { return }
        leased = false
        speech.detach(ZipformerEngine.key)
        speech.detach(SmartTurnEngine.key)
        speech.release(.talk)
        voice.release(.talk)
        voice.setThreadCap(nil)
    }

    var finalTranscriber: FinalTranscriber? {
        guard whisperReady, let engine = speech.whisper else { return nil }
        let language = DictationPrefs.language
        let usePrompt = DictationPrefs.usePrompt
        let folder = folder
        let session = session
        return WhisperFinalTranscriber(engine: engine, languageID: speech.languageID,
                                       plan: language.plan(choice: language.defaultChoice),
                                       prompt: { spoken in
                                           usePrompt ? DictationText.prompt(folder: folder, session: session,
                                                                            language: spoken) : nil
                                       })
    }

    var isWhisperLoaded: Bool { speech.isWhisperLoaded }

    func loadWhisper() async -> Bool {
        guard whisperReady else { return false }
        do {
            try await speech.prepareWhisper()
            return true
        } catch {
            log.error("whisper didn't load for Talk: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func unloadWhisper() { speech.unloadWhisper() }

    var availableMemory: UInt64 { UInt64(os_proc_available_memory()) }

    var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    var isInBackground: Bool { UIApplication.shared.applicationState == .background }

    var callActive: Bool { callObserver.calls.contains { !$0.hasEnded } }

    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    func setNowPlaying(title: String?) {
        guard let title else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: AppIdentity.displayName,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    func setRemoteTarget(_ target: TalkRemoteTarget?) {
        remote.target = target
        if target != nil {
            RemoteCommandRouter.shared.claim(remote)
        } else {
            RemoteCommandRouter.shared.release(remote)
        }
    }
}

/// The Lock Screen's and the AirPods' commands for Talk: play/pause (a stem
/// press) mutes or unmutes, next track stops the speech, previous says the
/// last reply again.
@MainActor
final class TalkRemoteControl: RemoteControllable {
    weak var target: TalkRemoteTarget?

    func remotePlay() { target?.remoteSetMuted(false) }
    func remotePause() { target?.remoteSetMuted(true) }
    func remoteTogglePlayPause() { target?.remoteToggleMute() }
    func remoteStop() { target?.remoteStopSpeech() }
    func remoteSeek(to seconds: TimeInterval) -> Bool { false }
    var supportsRemoteSeeking: Bool { false }
    func remoteNextTrack() { target?.remoteStopSpeech() }
    func remotePreviousTrack() { target?.remoteRepeat() }
    var supportsTrackCommands: Bool { true }
}

// MARK: - The server

/// Talk's server side in the app: the session's lease in the model store,
/// Talk mode, the settings, sub-agents' waiting items and the reports.
@MainActor
final class LiveTalkBackend: TalkBackend {
    var onItemsChanged: (() -> Void)?

    private let client: CodegClient
    private let conversationID: Int
    private let serverProfileID: UUID?
    private let lease: SessionLease?
    private let holder = UUID()
    private weak var pending: PendingItemsStore?
    private var holding = false

    init(client: CodegClient, conversationID: Int, serverProfileID: UUID?, lease: SessionLease?,
         pending: PendingItemsStore?) {
        self.client = client
        self.conversationID = conversationID
        self.serverProfileID = serverProfileID
        self.lease = lease
        self.pending = pending
        observeItems()
    }

    func holdSession(_ hold: Bool) {
        guard hold != holding else { return }
        holding = hold
        if hold { lease?.acquire(holder) } else { lease?.release(holder) }
    }

    func setTalkMode(conversationID: Int, enabled: Bool) async throws {
        try await client.setConversationTalkMode(conversationId: conversationID, enabled: enabled)
    }

    var cachedSettings: TalkSettings? { TalkSettingsSection.cachedServerSettings() }

    func fetchSettings() async -> TalkSettings? {
        guard let settings = try? await client.getTalkSettings() else { return nil }
        TalkSettingsSection.cacheServerSettings(settings)
        return settings
    }

    var subAgentItems: [PendingItem] {
        guard let pending, pending.serverProfileID == serverProfileID else { return [] }
        return pending.items.filter { $0.rootConversationId == conversationID && $0.conversationId != conversationID }
    }

    /// Follow the pending list while Talk runs.
    private func observeItems() {
        guard let pending else { return }
        withObservationTracking {
            _ = pending.items
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.onItemsChanged?()
                self?.observeItems()
            }
        }
    }

    func respond(item: PendingItem, optionId: String) async throws {
        try await client.respondPermission(connectionId: item.connectionId, requestId: item.requestId, optionId: optionId)
        await pending?.refresh()
    }

    func answer(item: PendingItem, answer: QuestionAnswer) async throws {
        try await client.answerQuestion(connectionId: item.connectionId, questionId: item.requestId, answer: answer)
        await pending?.refresh()
    }

    func answerPlan(item: PendingItem, decision: PlanApprovalDecision, feedback: String?) async throws {
        try await client.answerPlanApproval(connectionId: item.connectionId, approvalId: item.requestId,
                                           decision: decision, feedback: feedback)
        await pending?.refresh()
    }

    func upload(report: Data) async throws {
        guard let body = DiagnosticsUploader.wrap(report) else { return }
        try await client.reportClientDiagnostic(body)
    }
}
