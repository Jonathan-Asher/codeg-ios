import AVFoundation
import MediaPlayer
import Observation
import os
import BlueTTSKit
import BlueTTSEspeak

/// Read-aloud preferences (Settings › Voice).
enum VoicePrefs {
    private static let defaults = UserDefaults.standard

    static var voice: String {
        get { defaults.string(forKey: "codeg.voice.name") ?? "noa" }
        set { defaults.set(newValue, forKey: "codeg.voice.name") }
    }

    static var speed: Double {
        get { (defaults.object(forKey: "codeg.voice.speed") as? Double) ?? 1.0 }
        set { defaults.set(newValue, forKey: "codeg.voice.speed") }
    }

    static var readCode: Bool {
        get { defaults.bool(forKey: "codeg.voice.readCode") }
        set { defaults.set(newValue, forKey: "codeg.voice.readCode") }
    }

    static var readToolOutput: Bool {
        get { defaults.bool(forKey: "codeg.voice.readToolOutput") }
        set { defaults.set(newValue, forKey: "codeg.voice.readToolOutput") }
    }

    /// The first Read aloud asked whether to download the voice.
    static var askedDownload: Bool {
        get { defaults.bool(forKey: "codeg.voice.askedDownload") }
        set { defaults.set(newValue, forKey: "codeg.voice.askedDownload") }
    }

    static var speechOptions: SpeechText.Options {
        SpeechText.Options(includeCode: readCode, includeToolOutput: readToolOutput)
    }
}

/// Reads agent replies aloud.
///
/// With the BlueTTS models downloaded (``VoiceModelStore``), text goes
/// through `BlueTTS.synthesizeStream` sentence by sentence and every chunk is
/// queued on an `AVAudioPlayerNode`, so speech starts after the first
/// sentence. Without them it falls back to `AVSpeechSynthesizer`, with the
/// Hebrew (Carmit) or English system voice per span of text.
///
/// The audio session is `.playback` / `.spokenAudio`, and the app declares the
/// `audio` background mode, so reading continues with the screen locked. Now
/// Playing shows the reply, and the lock-screen controls pause, resume and stop.
@MainActor
@Observable
final class ReadAloudPlayer: NSObject {
    static let shared = ReadAloudPlayer()

    enum State: Equatable {
        case idle
        /// Loading the model or synthesizing the first sentence.
        case preparing
        case playing
        case paused
    }

    private(set) var state: State = .idle
    /// The reply being read (its turn id).
    private(set) var currentID: String?
    /// Reading with the system voice (the model isn't downloaded).
    private(set) var usingSystemVoice = false
    private(set) var lastError: String?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "read-aloud")

    // BlueTTS path
    private var tts: BlueTTS?
    private var ttsVoiceDirectory: URL?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var synthesisTask: Task<Void, Never>?
    private var pendingBuffers = 0
    private var synthesisDone = false
    private var generation = 0
    private var unloadTask: Task<Void, Never>?

    // System-voice path
    private let speech = AVSpeechSynthesizer()

    private var title = ""
    private var remoteCommandsInstalled = false

    private override init() {
        super.init()
        speech.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: - Public

    func isReading(_ id: String) -> Bool { currentID == id && state != .idle }

    /// Start reading `text` as reply `id`, or stop when it is already reading.
    func toggle(id: String, title: String, text: String) {
        if currentID == id, state != .idle {
            stop()
            return
        }
        speak(id: id, title: title, text: text)
    }

    func speak(id: String, title: String, text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Nothing to read in this reply."
            return
        }
        lastError = nil
        currentID = id
        self.title = title
        generation &+= 1
        unloadTask?.cancel()
        do {
            try activateSession()
        } catch {
            fail("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        installRemoteCommands()
        if VoiceModelStore.shared.isReady {
            usingSystemVoice = false
            speakWithBlueTTS(trimmed, generation: generation)
        } else {
            usingSystemVoice = true
            speakWithSystemVoice(trimmed)
        }
        updateNowPlaying()
    }

    func pause() {
        guard state == .playing || state == .preparing else { return }
        if usingSystemVoice {
            speech.pauseSpeaking(at: .word)
        } else {
            player?.pause()
        }
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        try? activateSession()
        if usingSystemVoice {
            speech.continueSpeaking()
        } else {
            if engine?.isRunning == false { try? engine?.start() }
            player?.play()
        }
        state = .playing
        updateNowPlaying()
    }

    func stop() {
        generation &+= 1
        synthesisTask?.cancel()
        synthesisTask = nil
        if speech.isSpeaking || speech.isPaused { speech.stopSpeaking(at: .immediate) }
        player?.stop()
        engine?.stop()
        pendingBuffers = 0
        synthesisDone = false
        let wasActive = state != .idle
        state = .idle
        currentID = nil
        if wasActive { deactivateSession() }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        scheduleUnload()
    }

    /// Drop the loaded model (~900 MB in memory) after a quiet spell.
    private func scheduleUnload() {
        unloadTask?.cancel()
        guard tts != nil else { return }
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self, self.state == .idle else { return }
            self.tts = nil
            self.engine = nil
            self.player = nil
        }
    }

    // MARK: - BlueTTS

    private func speakWithBlueTTS(_ text: String, generation gen: Int) {
        state = .preparing
        pendingBuffers = 0
        synthesisDone = false
        let tts: BlueTTS
        do {
            tts = try loadTTS()
            try prepareEngine()
        } catch {
            log.error("BlueTTS unavailable: \(error.localizedDescription, privacy: .public)")
            // Fall back to the system voice rather than saying nothing.
            usingSystemVoice = true
            speakWithSystemVoice(text)
            return
        }
        var options = SynthesisOptions()
        options.voice = VoicePrefs.voice
        options.speed = VoicePrefs.speed
        synthesisTask = Task { [weak self] in
            do {
                for try await chunk in tts.synthesizeStream(text, options: options) {
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    self.enqueue(chunk.samples, sampleRate: chunk.sampleRate, generation: gen)
                }
                guard let self, self.generation == gen else { return }
                self.synthesisDone = true
                self.finishIfDrained(generation: gen)
            } catch {
                guard let self, self.generation == gen else { return }
                if self.pendingBuffers > 0 {
                    // Keep what was synthesized; stop after it plays.
                    self.synthesisDone = true
                    self.lastError = error.localizedDescription
                } else {
                    self.fail("Read aloud failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadTTS() throws -> BlueTTS {
        if let tts { return tts }
        var configuration = BlueTTSConfiguration()
        configuration.defaultVoice = VoicePrefs.voice
        let phonemizer = try EspeakPhonemizer()
        let tts = BlueTTS(modelDirectory: VoiceModelStore.shared.modelsDirectory,
                          englishPhonemizer: phonemizer,
                          configuration: configuration)
        self.tts = tts
        return tts
    }

    private func prepareEngine() throws {
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
                throw NSError(domain: "ReadAloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio format"])
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.player = player
            self.format = format
        }
        if engine?.isRunning == false {
            engine?.prepare()
            try engine?.start()
        }
    }

    private func enqueue(_ samples: [Float], sampleRate: Int, generation gen: Int) {
        guard let player, let format = bufferFormat(sampleRate: sampleRate), !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(generation: gen) }
        }
        if state == .preparing {
            player.play()
            state = .playing
            updateNowPlaying()
        }
    }

    private func bufferFormat(sampleRate: Int) -> AVAudioFormat? {
        if let format, Int(format.sampleRate) == sampleRate { return format }
        // A different rate than the engine was wired for: reconnect.
        guard let engine, let player,
              let newFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else { return nil }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        format = newFormat
        return newFormat
    }

    private func bufferPlayed(generation gen: Int) {
        guard gen == generation else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        finishIfDrained(generation: gen)
    }

    private func finishIfDrained(generation gen: Int) {
        guard gen == generation, synthesisDone, pendingBuffers == 0 else { return }
        stop()
    }

    // MARK: - System voice

    private func speakWithSystemVoice(_ text: String) {
        state = .playing
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.4, max(0.7, VoicePrefs.speed)))
        let hebrewVoice = AVSpeechSynthesisVoice(language: "he-IL")
        let englishVoice = AVSpeechSynthesisVoice(language: "en-US")
        for paragraph in text.components(separatedBy: "\n") where !paragraph.isEmpty {
            for run in SpeechText.scriptRuns(paragraph) {
                let utterance = AVSpeechUtterance(string: run.text)
                utterance.voice = run.isHebrew ? hebrewVoice : englishVoice
                utterance.rate = rate
                speech.speak(utterance)
            }
        }
    }

    fileprivate func systemSpeechFinished() {
        guard usingSystemVoice, state != .idle, !speech.isSpeaking else { return }
        stop()
    }

    // MARK: - Audio session, Now Playing, remote commands

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        lastError = message
        stop()
    }

    private func updateNowPlaying() {
        guard state != .idle else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Agent reply" : title,
            MPMediaItemPropertyArtist: AppIdentity.displayName,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
    }

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .paused { self.resume() } else { self.pause() }
            }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
    }

    @objc nonisolated private func audioSessionInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
            .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
        Task { @MainActor in
            switch type {
            case .began: self.pause()
            case .ended: if shouldResume { self.resume() }
            @unknown default: break
            }
        }
    }
}

extension ReadAloudPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // The queue is empty once the last utterance finishes.
            try? await Task.sleep(for: .milliseconds(150))
            self.systemSpeechFinished()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
