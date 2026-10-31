import AVFoundation
import BackgroundTasks
import Foundation
import Observation
import os
import SherpaOnnx
import SmartTurn

/// The Talk Lab (Settings › Voice › Talk › Lab): Talk's engines measured on
/// this iPhone, to tune them.
///
/// - **Transcribers.** A recording on Talk's audio, then the Zipformer (the
///   clip at once, and streamed in 512-sample frames as Talk feeds it, with
///   the finish timed alone: the wait after the end of speech), whisper with
///   voice typing's language plan and no prompt (its load timed apart), and
///   Smart Turn on the clip up to just after the last word, as Talk asks it
///   at a pause. The last 10, newest first.
/// - **Voice.** Time to first audio, the whole synthesis and the audio's
///   length: BlueTTS at Talk's 4 threads, or the iPhone's own voice without
///   it, played on Talk's audio.
/// - **Echo test.** A sentence played once per echo mode on the current
///   route: the voice onsets the microphone heard while it played, and the
///   microphone's level against the second before.
/// - **This iPhone.** What it offers Talk.
///
/// One test runs at a time, none while Talk runs. The engines' leases are
/// held while the screen is open.
@MainActor
@Observable
final class TalkLab {
    static let shared = TalkLab()

    // MARK: - Types

    /// What the Lab is doing.
    enum Activity: Equatable {
        case idle
        case recording
        case transcribing
        case speaking
        case echoTest
    }

    /// The Zipformer's two passes over a recording.
    struct ZipformerRun: Sendable {
        /// The clip at once (`transcribeOnce`).
        var onceText: String
        var onceSeconds: Double
        /// The clip streamed in 512-sample frames, then finished.
        var streamedText: String
        /// Accepting the frames, as fast as they go.
        var feedSeconds: Double
        /// `inputFinished()` alone: the wait after the end of speech.
        var finishSeconds: Double
    }

    enum ZipformerOutcome {
        case running
        case stopped
        case failed(String)
        case done(ZipformerRun)
    }

    enum WhisperOutcome {
        case running
        case stopped
        case notDownloaded
        /// Not run, and why.
        case skipped(String)
        case failed(String)
        /// `loadSeconds`: loading the model first, when this run loaded it.
        case done(text: String, decodeSeconds: Double, loadSeconds: Double?)
    }

    enum SmartTurnOutcome {
        case running
        case stopped
        case notDownloaded
        case failed
        /// `heardSpeech`: voice detection found speech, and the clip ended
        /// just after it; otherwise it was the whole recording.
        case done(probability: Float, heardSpeech: Bool)
    }

    /// One recording through each engine.
    struct TranscriberResult: Identifiable {
        let id = UUID()
        let date: Date
        let audioSeconds: Double
        var zipformer = ZipformerOutcome.running
        var whisper = WhisperOutcome.running
        var smartTurn = SmartTurnOutcome.running
    }

    /// One timing of the voice.
    struct VoiceResult: Identifiable {
        let id = UUID()
        let text: String
        /// BlueTTS; false for the iPhone's own voice.
        let natural: Bool
        /// BlueTTS's voice.
        let voiceName: String?
        /// Loading BlueTTS first, when it had to load.
        var loadSeconds: Double?
        /// From the call to the first audio.
        var firstAudioSeconds: Double?
        /// From the call to the end of the synthesis.
        var totalSeconds: Double = 0
        var audioSeconds: Double = 0
        /// Played on Talk's audio (which needs the microphone allowed).
        var played = false
        var error: String?
    }

    /// The microphone's level over some frames: the loudest frame's RMS, and
    /// the RMS of them all.
    struct Level: Sendable {
        private(set) var peak: Float = 0
        private(set) var frames = 0
        private var power: Float = 0

        init() {}

        var mean: Float { frames > 0 ? (power / Float(frames)).squareRoot() : 0 }

        mutating func add(_ rms: Float) {
            peak = max(peak, rms)
            power += rms * rms
            frames += 1
        }
    }

    /// One echo mode in the echo test.
    struct EchoResult: Identifiable {
        let id = UUID()
        let asked: TalkEchoMode
        /// What the audio engine ran with; nil when it didn't start.
        var used: TalkEchoMode?
        /// iOS turned echo-cancelled input on for the session.
        var echoCancelledInputOn = false
        var route: TalkRoute?
        /// Voice onsets heard while the sentence played.
        var onsets = 0
        /// The microphone while the sentence played, and half a second after.
        var during = Level()
        /// The microphone in the second before the sentence.
        var before = Level()
        var heardToEnd = false
        var routeChanged = false
        var error: String?
    }

    /// What this iPhone offers Talk, read on demand.
    struct DeviceSnapshot {
        var model = ""
        var system = ""
        /// iOS's answer now; reliable only while Talk's audio runs.
        var echoCancelledInputNow = false
        var route = TalkRoute.other
        var ports = ""
        var backgroundGPU = false
        var availableMemory: UInt64 = 0
        var thermal = ProcessInfo.ThermalState.nominal
    }

    // MARK: - Configuration

    /// A recording stops by itself at this length.
    static let maxRecordingSeconds = 30.0
    /// A shorter recording isn't transcribed.
    static let minRecordingSeconds = 0.3
    static let keptTranscriptions = 10
    static let keptVoiceResults = 5
    /// BlueTTS's threads in Talk.
    static let voiceThreads = 4
    /// The echo modes the echo test compares, in this order.
    static let echoModes: [TalkEchoMode] = [.echoCancelledInput, .voiceProcessing, TalkEchoMode.none]
    /// What the echo test plays: Hebrew with English terms, as Talk speaks.
    static let echoText = "זו בדיקת הד. המשפט הזה מושמע דרך הרמקול, ונא לשמור על שקט עד הסוף. The build passed, and all the tests are green."

    private static let sampleRate = MicFrameAssembler.sampleRate

    // MARK: - State

    private(set) var activity = Activity.idle
    /// What the running test does now.
    private(set) var step: String?

    private(set) var recordingElapsed: TimeInterval = 0
    /// The microphone's level while recording, 0…1.
    private(set) var recordingLevel: Float = 0
    /// Newest first.
    private(set) var transcriptions: [TranscriberResult] = []
    private(set) var transcriberError: String?

    /// The sentence the voice is timed on.
    var speakText = "בדקתי את ה-build, והבדיקות של ה-API עוברות עכשיו."
    /// Newest first.
    private(set) var voiceResults: [VoiceResult] = []
    private(set) var voiceError: String?

    private(set) var echoResults: [EchoResult] = []
    private(set) var echoError: String?

    private(set) var device = DeviceSnapshot()
    /// Whether echo-cancelled input was available the last time the Lab's
    /// audio ran on the built-in microphone and speaker in mode `.default`
    /// (iOS tells reliably only then).
    private(set) var echoCancelledInputSeen: Bool?

    @ObservationIgnored private var openCount = 0
    /// Bumped by every start and stop, so a stopped test's late steps change
    /// nothing.
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// The Lab's audio engine while a test uses it.
    @ObservationIgnored private var audio: TalkAudioEngine?
    @ObservationIgnored private var whisperRun: WhisperFinalTranscriber?
    @ObservationIgnored private var clip: [Float] = []
    /// Where the recording's last voiced frame ends, in samples.
    @ObservationIgnored private var speechEnd = 0
    @ObservationIgnored private var stopRequested = false
    /// The echo test's sentence, synthesized once.
    @ObservationIgnored private var echoSample: (natural: Bool, chunks: [SpeechChunk])?

    private init() {}

    /// Talk runs: the microphone and the engines are its own.
    var talkRunning: Bool { TalkCenter.shared.controller?.isActive == true }

    /// A test can start now.
    var canStart: Bool { activity == .idle && !talkRunning }

    /// The live transcriber is downloaded.
    var canTranscribe: Bool { TalkModels.isReady(.liveTranscriber) }

    /// Talk's voice detection has its model.
    var canTestEcho: Bool { TalkModels.engineConfiguration() != nil }

    // MARK: - The screen

    /// The screen opened: hold the engines while it is open.
    func appear() {
        openCount += 1
        guard openCount == 1 else { return }
        SpeechEngineHost.shared.acquire(.lab)
        VoiceEngineHost.shared.acquire(.lab)
        refreshDevice()
    }

    /// The screen closed: stop what runs and let the engines go.
    func disappear() {
        guard openCount > 0 else { return }
        openCount -= 1
        guard openCount == 0 else { return }
        cancel()
        SpeechEngineHost.shared.release(.lab)
        VoiceEngineHost.shared.release(.lab)
        // Talk keeps its own cap while it runs.
        if !talkRunning { VoiceEngineHost.shared.setThreadCap(nil) }
    }

    /// Stop whatever runs: the microphone, the speech, the work.
    func cancel() {
        runID += 1
        work?.cancel()
        frameTask?.cancel()
        eventTask?.cancel()
        whisperRun?.cancel()
        work = nil
        frameTask = nil
        eventTask = nil
        whisperRun = nil
        stopAudio()
        clip = []
        stopRequested = false
        if activity != .idle { activity = .idle }
        if step != nil { step = nil }
        if recordingLevel != 0 { recordingLevel = 0 }
        settleRunning()
    }

    // MARK: - Transcribers

    /// Record; while recording, stop and transcribe.
    func toggleRecording() {
        if activity == .recording {
            stopRecording()
            return
        }
        guard canStart, canTranscribe else { return }
        transcriberError = nil
        stopRequested = false
        recordingElapsed = 0
        recordingLevel = 0
        let run = begin(.recording)
        work = Task { @MainActor [weak self] in await self?.record(run) }
    }

    func clearTranscriptions() {
        transcriptions.removeAll()
        transcriberError = nil
    }

    private func stopRecording() {
        guard activity == .recording else { return }
        stopRequested = true
        frameTask?.cancel()
    }

    /// Talk's audio with the route's own echo mode, collecting the
    /// microphone until Stop or the length limit, then the engines.
    private func record(_ run: Int) async {
        defer { end(run) }
        guard await microphoneAllowed() else {
            if run == runID { transcriberError = Self.microphoneOff }
            return
        }
        guard isCurrent(run), !stopRequested else { return }
        let vad = liveVAD()
        vad?.reset()
        let engine = TalkAudioEngine(owner: .shared)
        do {
            try engine.start(preferring: nil)
        } catch {
            transcriberError = AudioErrorText(error).message("The microphone didn't start")
            return
        }
        audio = engine
        noteEchoAvailability(engine)
        clip = []
        speechEnd = 0
        let frames = engine.frames
        let events = engine.events
        let listener = Task { @MainActor [weak self] in
            for await frame in frames {
                guard let self, !Task.isCancelled else { return }
                if !self.addRecorded(frame, vad: vad) { return }
            }
        }
        let watcher = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if let problem = TalkLab.problem(event) {
                    self.transcriberError = problem
                    self.stopRecording()
                }
            }
        }
        frameTask = listener
        eventTask = watcher
        await listener.value
        watcher.cancel()
        stopAudio(engine)
        guard isCurrent(run) else { return }
        frameTask = nil
        eventTask = nil
        recordingLevel = 0
        let recorded = clip
        let lastWord = speechEnd
        clip = []
        guard Double(recorded.count) >= Self.minRecordingSeconds * Self.sampleRate else {
            if transcriberError == nil { transcriberError = "Too short. Tap Record, say a sentence, then tap Stop." }
            return
        }
        await transcribe(recorded, speechEnd: lastWord, run: run)
    }

    /// One microphone frame of the recording; false once it is long enough.
    private func addRecorded(_ frame: MicFrame, vad: StreamingVoiceActivityDetector?) -> Bool {
        clip.append(contentsOf: frame.samples)
        recordingLevel = recordingLevel * 0.6 + min(1, frame.rms * 12) * 0.4
        recordingElapsed = Double(clip.count) / Self.sampleRate
        if let p = vad?.probability(of: frame.samples), p >= EndOfTurnConfig.standard.openThreshold {
            speechEnd = clip.count
        }
        return Double(clip.count) < Self.maxRecordingSeconds * Self.sampleRate
    }

    /// The Zipformer, Smart Turn, then whisper on one recording; its row is
    /// filled in as each finishes.
    private func transcribe(_ clip: [Float], speechEnd: Int, run: Int) async {
        activity = .transcribing
        let result = TranscriberResult(date: Date(), audioSeconds: Double(clip.count) / Self.sampleRate)
        let id = result.id
        transcriptions.insert(result, at: 0)
        if transcriptions.count > Self.keptTranscriptions {
            transcriptions.removeLast(transcriptions.count - Self.keptTranscriptions)
        }
        let whisperReady = configureEngines() ?? false

        step = "Zipformer…"
        do {
            let recognizer = try await ZipformerEngine.shared()
            guard isCurrent(run) else { return }
            let pass = await Self.runZipformer(recognizer, clip: clip)
            update(id, run: run) { $0.zipformer = .done(pass) }
        } catch {
            update(id, run: run) { $0.zipformer = .failed(Self.describe(error)) }
        }
        guard isCurrent(run) else { return }

        step = "Smart Turn…"
        if TalkModels.isReady(.turnClassifier) {
            if let classifier = await SmartTurnEngine.shared() {
                guard isCurrent(run) else { return }
                // Up to just after the last word, as Talk asks at a pause.
                let heardSpeech = speechEnd > 0
                let cut = heardSpeech ? min(clip.count, speechEnd + Self.pauseSamples) : clip.count
                let window = Array(clip[..<cut].suffix(SmartTurnClassifier.maxSeconds * SmartTurnClassifier.sampleRate))
                if let probability = await classifier.probability(last8s: window) {
                    update(id, run: run) { $0.smartTurn = .done(probability: probability, heardSpeech: heardSpeech) }
                } else {
                    update(id, run: run) { $0.smartTurn = .failed }
                }
            } else {
                update(id, run: run) { $0.smartTurn = .failed }
            }
        } else {
            update(id, run: run) { $0.smartTurn = .notDownloaded }
        }
        guard isCurrent(run) else { return }

        await transcribeWithWhisper(clip, ready: whisperReady, id: id, run: run)
    }

    /// whisper as Talk's final transcriber runs it: voice typing's language
    /// plan, no prompt. The load is timed apart, and skipped without the
    /// memory Talk wants for it.
    private func transcribeWithWhisper(_ clip: [Float], ready: Bool, id: UUID, run: Int) async {
        let host = SpeechEngineHost.shared
        guard ready, let engine = host.whisper else {
            update(id, run: run) { $0.whisper = .notDownloaded }
            return
        }
        var loadSeconds: Double?
        if !host.isWhisperLoaded {
            let available = UInt64(os_proc_available_memory())
            guard available >= TalkController.whisperMemoryFloor else {
                let free = available / 1_048_576
                let floor = TalkController.whisperMemoryFloor / 1_048_576
                update(id, run: run) {
                    $0.whisper = .skipped("Not loaded: \(free) MB free, and Talk loads whisper only with \(floor) MB to spare.")
                }
                return
            }
            step = "Loading whisper…"
            let loadStart = Self.uptime
            do {
                try await host.prepareWhisper()
            } catch {
                update(id, run: run) { $0.whisper = .failed(Self.describe(error)) }
                return
            }
            loadSeconds = Self.uptime - loadStart
            guard isCurrent(run) else { return }
        }
        step = "whisper…"
        let language = DictationPrefs.language
        let transcriber = WhisperFinalTranscriber(engine: engine, languageID: host.languageID,
                                                  plan: language.plan(choice: language.defaultChoice),
                                                  prompt: { _ in nil })
        whisperRun = transcriber
        let decodeStart = Self.uptime
        do {
            let text = try await transcriber.transcribe(clip)
            let decodeSeconds = Self.uptime - decodeStart
            update(id, run: run) {
                $0.whisper = .done(text: text, decodeSeconds: decodeSeconds, loadSeconds: loadSeconds)
            }
        } catch {
            update(id, run: run) { $0.whisper = .failed(Self.describe(error)) }
        }
        if run == runID { whisperRun = nil }
    }

    /// The clip at once, then streamed in 512-sample frames and finished,
    /// off the main thread (synchronous CPU work).
    nonisolated private static func runZipformer(_ recognizer: StreamingTransducerRecognizer,
                                                 clip: [Float]) async -> ZipformerRun {
        await Task.detached(priority: .userInitiated) { () -> ZipformerRun in
            let start = ProcessInfo.processInfo.systemUptime
            let once = recognizer.transcribeOnce(samples: clip)
            let onceEnd = ProcessInfo.processInfo.systemUptime
            recognizer.reset()
            var offset = 0
            while offset < clip.count {
                let next = min(clip.count, offset + MicFrameAssembler.frameSamples)
                recognizer.accept(samples: Array(clip[offset..<next]))
                offset = next
            }
            let fed = ProcessInfo.processInfo.systemUptime
            let streamed = recognizer.inputFinished()
            let finished = ProcessInfo.processInfo.systemUptime
            recognizer.reset()
            return ZipformerRun(onceText: once, onceSeconds: onceEnd - start, streamedText: streamed,
                                feedSeconds: fed - onceEnd, finishSeconds: finished - fed)
        }.value
    }

    /// Change a recording's row while its run is the current one (a stopped
    /// run's row stays "Stopped").
    private func update(_ id: UUID, run: Int, _ change: (inout TranscriberResult) -> Void) {
        guard run == runID, let index = transcriptions.firstIndex(where: { $0.id == id }) else { return }
        change(&transcriptions[index])
    }

    /// Results a stopped test left half done.
    private func settleRunning() {
        for index in transcriptions.indices {
            if case .running = transcriptions[index].zipformer { transcriptions[index].zipformer = .stopped }
            if case .running = transcriptions[index].smartTurn { transcriptions[index].smartTurn = .stopped }
            if case .running = transcriptions[index].whisper { transcriptions[index].whisper = .stopped }
        }
    }

    // MARK: - Voice

    /// Time the voice on ``speakText``, playing it on Talk's audio.
    func speak() {
        let text = speakText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canStart, !text.isEmpty else { return }
        voiceError = nil
        let run = begin(.speaking)
        work = Task { @MainActor [weak self] in await self?.timeVoice(text, run: run) }
    }

    /// As Talk says a reply's first sentence: the voice loaded first (timed
    /// apart), then from the call to the first chunk, and to the end.
    private func timeVoice(_ text: String, run: Int) async {
        defer { end(run) }
        let natural = VoiceModelStore.shared.isReady
        var result = VoiceResult(text: text, natural: natural, voiceName: natural ? VoicePrefs.voice : nil)
        if natural {
            step = "Loading the voice…"
            do {
                result.loadSeconds = try await loadVoice()
            } catch {
                if run == runID { voiceError = "The voice didn't load: \(Self.describe(error))" }
                return
            }
            guard isCurrent(run) else { return }
        }
        let player = await playbackEngine(run)
        guard isCurrent(run) else { return }
        result.played = player != nil
        step = "Synthesizing…"
        let playback = TalkLabPlayback()
        let synthesizer = Self.synthesizer(natural: natural)
        let unit = SpeechUnit.standalone(text, name: "lab.voice", kind: .sentence)
        let start = Self.uptime
        do {
            for try await chunk in synthesizer.synthesize(unit) {
                guard isCurrent(run) else { return }
                guard !chunk.samples.isEmpty else { continue }
                if result.firstAudioSeconds == nil { result.firstAudioSeconds = Self.uptime - start }
                result.audioSeconds += chunk.duration
                if let player { schedule(chunk, on: player, playback: playback) }
            }
        } catch {
            result.error = Self.describe(error)
        }
        result.totalSeconds = Self.uptime - start
        guard isCurrent(run) else { return }
        voiceResults.insert(result, at: 0)
        if voiceResults.count > Self.keptVoiceResults {
            voiceResults.removeLast(voiceResults.count - Self.keptVoiceResults)
        }
        guard let player else { return }
        step = "Playing…"
        let deadline = Self.uptime + result.audioSeconds + 2
        while !playback.finished, isCurrent(run), Self.uptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        stopAudio(player)
    }

    /// BlueTTS at Talk's thread cap with its graphs loaded; how long that took
    /// when it had to load (nil when it was ready).
    private func loadVoice() async throws -> Double? {
        let voice = VoiceEngineHost.shared
        voice.setThreadCap(Self.voiceThreads)
        let cold = !voice.isLoaded
        let start = Self.uptime
        try await voice.preload()
        let seconds = Self.uptime - start
        return (cold || seconds >= 0.1) ? seconds : nil
    }

    /// Talk's audio engine to play on, as Talk plays; nil when the microphone
    /// isn't allowed (the engine records too) or it didn't start.
    private func playbackEngine(_ run: Int) async -> TalkAudioEngine? {
        guard await microphoneAllowed() else {
            if run == runID {
                voiceError = "Not played: the microphone is off for \(AppIdentity.displayName). The times are measured all the same."
            }
            return nil
        }
        guard isCurrent(run) else { return nil }
        let engine = TalkAudioEngine(owner: .shared)
        do {
            try engine.start(preferring: nil)
        } catch {
            voiceError = AudioErrorText(error).message("Not played")
            return nil
        }
        audio = engine
        noteEchoAvailability(engine)
        return engine
    }

    private static func synthesizer(natural: Bool) -> Synthesizer {
        if natural { return BlueVoiceSynthesizer() }
        return SystemVoiceSynthesizer()
    }

    /// Queue a chunk on the Lab's audio, counted until it is heard.
    private func schedule(_ chunk: SpeechChunk, on engine: TalkAudioEngine, playback: TalkLabPlayback) {
        playback.scheduled += 1
        engine.schedule(chunk.samples, sampleRate: chunk.sampleRate) {
            MainActor.assumeIsolated { playback.played += 1 }
        }
    }

    // MARK: - Echo test

    /// Play the test sentence once per echo mode and count what the
    /// microphone heard.
    func runEchoTest() {
        guard canStart, canTestEcho else { return }
        echoError = nil
        echoResults = []
        let run = begin(.echoTest)
        work = Task { @MainActor [weak self] in await self?.echoTest(run) }
    }

    private func echoTest(_ run: Int) async {
        defer { end(run) }
        guard await microphoneAllowed() else {
            if run == runID { echoError = Self.microphoneOff }
            return
        }
        guard isCurrent(run) else { return }
        guard let vad = liveVAD() else {
            echoError = "Talk's voice detection didn't load. Delete Talk's live transcription in Settings › Voice › Talk and download it again."
            return
        }
        step = "Preparing the sentence…"
        let chunks: [SpeechChunk]
        do {
            chunks = try await echoSamples()
        } catch {
            if run == runID { echoError = "The test sentence didn't synthesize: \(Self.describe(error))" }
            return
        }
        guard isCurrent(run) else { return }
        guard !chunks.isEmpty else {
            echoError = "The test sentence came out silent."
            return
        }
        for (index, mode) in Self.echoModes.enumerated() {
            guard isCurrent(run) else { return }
            step = "\(Self.title(of: mode)), \(index + 1) of \(Self.echoModes.count)…"
            let result = await measureEcho(mode, chunks: chunks, vad: vad, run: run)
            guard isCurrent(run) else { return }
            echoResults.append(result)
        }
    }

    /// The test sentence, synthesized once (again when the voice changes
    /// between BlueTTS and the iPhone's own).
    private func echoSamples() async throws -> [SpeechChunk] {
        let natural = VoiceModelStore.shared.isReady
        if let sample = echoSample, sample.natural == natural { return sample.chunks }
        if natural { _ = try await loadVoice() }
        let unit = SpeechUnit.standalone(Self.echoText, name: "lab.echo", kind: .sentence)
        var chunks: [SpeechChunk] = []
        for try await chunk in Self.synthesizer(natural: natural).synthesize(unit) where !chunk.samples.isEmpty {
            chunks.append(chunk)
        }
        guard !Task.isCancelled else { return [] }
        echoSample = (natural, chunks)
        return chunks
    }

    /// One echo mode: a fresh audio engine started with it, a second of the
    /// room, then the sentence, counting voice onsets until half a second
    /// after it was heard.
    private func measureEcho(_ mode: TalkEchoMode, chunks: [SpeechChunk],
                             vad: StreamingVoiceActivityDetector, run: Int) async -> EchoResult {
        var result = EchoResult(asked: mode)
        guard isCurrent(run) else { return result }
        let engine = TalkAudioEngine(owner: .shared)
        do {
            try engine.start(preferring: mode)
        } catch {
            result.error = "Didn't start: \(AudioErrorText(error).sentence)"
            return result
        }
        audio = engine
        noteEchoAvailability(engine)
        result.used = engine.echoMode
        result.route = engine.route
        result.echoCancelledInputOn = AVAudioSession.sharedInstance().isEchoCancelledInputEnabled
        vad.reset()
        let meter = TalkLabEchoMeter()
        let frames = engine.frames
        let events = engine.events
        let listener = Task { @MainActor in
            for await frame in frames {
                guard !Task.isCancelled else { return }
                // Every frame, so the detector's memory runs on unbroken.
                meter.add(frame, probability: vad.probability(of: frame.samples) ?? 0)
            }
        }
        let watcher = Task { @MainActor in
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .routeChanged = event { meter.routeChanged = true }
                if let problem = TalkLab.problem(event) { meter.failure = problem }
            }
        }
        frameTask = listener
        eventTask = watcher
        // The microphone settles, then a second of the room.
        try? await Task.sleep(for: .milliseconds(300))
        meter.phase = .baseline
        try? await Task.sleep(for: .seconds(1))
        let playback = TalkLabPlayback()
        if isCurrent(run), meter.failure == nil {
            meter.phase = .playing
            var length: TimeInterval = 0
            for chunk in chunks {
                schedule(chunk, on: engine, playback: playback)
                length += chunk.duration
            }
            let deadline = Self.uptime + length + 3
            while !playback.finished, meter.failure == nil, isCurrent(run), Self.uptime < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The echo's tail counts too.
            if isCurrent(run) { try? await Task.sleep(for: .milliseconds(500)) }
        }
        meter.phase = .done
        listener.cancel()
        watcher.cancel()
        stopAudio(engine)
        if run == runID {
            frameTask = nil
            eventTask = nil
        }
        result.onsets = meter.onsets
        result.during = meter.during
        result.before = meter.before
        result.heardToEnd = playback.scheduled > 0 && playback.finished
        result.routeChanged = meter.routeChanged
        result.error = meter.failure
        return result
    }

    // MARK: - This iPhone

    func refreshDevice() {
        let session = AVAudioSession.sharedInstance()
        let environment = TalkReportEnvironment.device
        var snapshot = DeviceSnapshot()
        snapshot.model = environment["model"] ?? "?"
        snapshot.system = environment["os"] ?? "?"
        snapshot.echoCancelledInputNow = session.isEchoCancelledInputAvailable
        snapshot.route = TalkEchoPolicy.route(session.currentRoute)
        snapshot.ports = Self.ports(session.currentRoute)
        snapshot.backgroundGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        snapshot.availableMemory = UInt64(os_proc_available_memory())
        snapshot.thermal = ProcessInfo.processInfo.thermalState
        device = snapshot
    }

    /// Read the downloads' state from disk again.
    func refreshModels() {
        for requirement in TalkModels.Requirement.allCases {
            TalkModels.store(for: requirement)?.refreshFromDisk()
        }
    }

    /// iOS says reliably whether echo-cancelled input is available only for
    /// an active session in mode `.default`, and it is offered on the
    /// built-in microphone and speaker: noted when the Lab's audio runs so.
    private func noteEchoAvailability(_ engine: TalkAudioEngine) {
        guard engine.route == .builtIn, TalkEchoPolicy.sessionMode(for: engine.echoMode) == .default else { return }
        echoCancelledInputSeen = AVAudioSession.sharedInstance().isEchoCancelledInputAvailable
    }

    // MARK: - Helpers

    /// An echo mode's name on screen.
    nonisolated static func title(of mode: TalkEchoMode) -> String {
        switch mode {
        case .echoCancelledInput: "Echo-cancelled input"
        case .voiceProcessing: "Voice processing"
        case .none: "None"
        }
    }

    private func begin(_ next: Activity) -> Int {
        runID += 1
        activity = next
        step = nil
        return runID
    }

    /// The test `run` is still the one running.
    private func isCurrent(_ run: Int) -> Bool {
        run == runID && !Task.isCancelled
    }

    /// The test `run` is over (nothing changes when it was stopped).
    private func end(_ run: Int) {
        guard run == runID else { return }
        stopAudio()
        work = nil
        frameTask = nil
        eventTask = nil
        whisperRun = nil
        activity = .idle
        step = nil
        recordingLevel = 0
        refreshDevice()
    }

    /// Stop the Lab's audio engine (`engine`, when given, only while it is
    /// the current one). Once only: `stop()` gives the session back, which
    /// would pull it from under a newer engine.
    private func stopAudio(_ engine: TalkAudioEngine? = nil) {
        guard let current = audio else { return }
        if let engine, engine !== current { return }
        audio = nil
        current.stopSpeech()
        current.stop()
    }

    /// Point the shared speech engines at Talk's files, as Talk does; whether
    /// whisper is downloaded, or nil without Talk's models.
    private func configureEngines() -> Bool? {
        guard let setup = TalkModels.engineConfiguration() else { return nil }
        SpeechEngineHost.shared.use(setup.configuration)
        return setup.whisperReady
    }

    /// Talk's streaming VAD (one user at a time: Talk doesn't run now).
    private func liveVAD() -> StreamingVoiceActivityDetector? {
        guard configureEngines() != nil else { return nil }
        return SpeechEngineHost.shared.streamingVAD()
    }

    private func microphoneAllowed() async -> Bool {
        if DictationRecorder.permission == .granted { return true }
        return await DictationRecorder.requestPermission()
    }

    /// What an audio event means for a test; nil when it can go on.
    private static func problem(_ event: TalkAudioEvent) -> String? {
        switch event {
        case .interruptionBegan:
            return "A call, Siri or an alarm took the audio."
        case .mediaServicesReset:
            return "The iPhone's audio restarted."
        case .engineFailed(let message):
            return message
        case .interruptionEnded, .routeChanged:
            return nil
        }
    }

    private static func ports(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map(\.portName).joined(separator: ", ")
        let outputs = route.outputs.map(\.portName).joined(separator: ", ")
        return "\(inputs.isEmpty ? "No input" : inputs) → \(outputs.isEmpty ? "no output" : outputs)"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static var microphoneOff: String {
        "Allow the microphone for \(AppIdentity.displayName) in the Settings app to use the Lab."
    }

    /// The quiet after the last word at which Talk asks Smart Turn.
    private static var pauseSamples: Int {
        Int(EndOfTurnConfig.standard.pauseAfter * sampleRate)
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Speech chunks queued on the Lab's audio, and how many were heard.
@MainActor
private final class TalkLabPlayback {
    var scheduled = 0
    var played = 0

    var finished: Bool { played >= scheduled }
}

/// One echo mode's count and levels, fed the microphone's frames: the second
/// before the sentence, then the sentence and its tail. A voice onset is
/// what opens an utterance in Talk: two frames in a row at p ≥ 0.5.
@MainActor
private final class TalkLabEchoMeter {
    enum Phase { case settling, baseline, playing, done }

    var phase = Phase.settling
    private(set) var before = TalkLab.Level()
    private(set) var during = TalkLab.Level()
    private(set) var onsets = 0
    var routeChanged = false
    var failure: String?
    private var voiceRun = 0

    func add(_ frame: MicFrame, probability p: Float) {
        switch phase {
        case .settling, .done:
            return
        case .baseline:
            before.add(frame.rms)
        case .playing:
            during.add(frame.rms)
            if p >= EndOfTurnConfig.standard.openThreshold {
                voiceRun += 1
                if voiceRun == EndOfTurnConfig.standard.openFrames { onsets += 1 }
            } else {
                voiceRun = 0
            }
        }
    }
}
