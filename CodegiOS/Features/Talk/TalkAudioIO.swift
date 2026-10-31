import AVFoundation
import Accelerate
import os

extension Notification.Name {
    /// Talk is about to set the audio session up for itself. Posted on the
    /// main thread, before the session changes: the Camera Control's
    /// standing-by microphone and read aloud step aside until
    /// ``talkDidReleaseAudio``, as they do for read aloud and session media.
    static let talkWillClaimAudio = Notification.Name("codeg.talk.willClaimAudio")
    /// Talk stopped and let go of the audio session. Main thread.
    static let talkDidReleaseAudio = Notification.Name("codeg.talk.didReleaseAudio")
}

/// 32 ms of microphone audio as Talk's listening reads it.
struct MicFrame: Sendable {
    /// 512 samples, 16 kHz mono.
    let samples: [Float]
    /// The samples' root mean square (linear, 0…1).
    let rms: Float
    /// When the first sample was captured, in seconds on the clock of
    /// `ProcessInfo.systemUptime`.
    let time: TimeInterval
}

/// The kind of audio route Talk runs on.
enum TalkRoute: Sendable, Equatable { case builtIn, bluetoothHFP, wired, other }

/// How Talk keeps its own speech out of the microphone (see ``TalkEchoPolicy``).
enum TalkEchoMode: Sendable, Equatable { case echoCancelledInput, voiceProcessing, none }

/// What happened to Talk's audio.
enum TalkAudioEvent: Sendable {
    /// A call, Siri or an alarm took the audio: the engine stopped.
    case interruptionBegan
    /// It's over; `shouldResume` when iOS says to carry on. Call
    /// ``TalkAudioIO/start(preferring:)`` to resume.
    case interruptionEnded(shouldResume: Bool)
    /// The engine was rebuilt for the route now in use (AirPods in or out, a
    /// configuration change). Speech scheduled before it was dropped.
    case routeChanged(TalkRoute)
    /// The iPhone's audio services restarted; the engine is being rebuilt.
    case mediaServicesReset
    /// The engine stopped and couldn't be started again; the message says why
    /// in plain words.
    case engineFailed(String)
}

/// Short tones Talk plays between turns.
enum Earcon: Sendable { case listening, gotIt, error }

/// Talk's audio: one engine for the microphone and the agent's speech, so
/// echo cancellation sees both. ``TalkAudioEngine`` in the app.
@MainActor
protocol TalkAudioIO: AnyObject {
    /// The microphone, 16 kHz mono, 512 samples a frame, while running.
    var frames: AsyncStream<MicFrame> { get }
    var events: AsyncStream<TalkAudioEvent> { get }
    var route: TalkRoute { get }
    var echoMode: TalkEchoMode { get }
    /// Speech is queued and not yet played to its end.
    var isSpeaking: Bool { get }
    /// Take the audio session and start, preferring `preferring` (the Lab's
    /// override) over ``TalkEchoPolicy``'s choice. Throws when the audio
    /// can't start (see ``AudioErrorText``).
    func start(preferring: TalkEchoMode?) throws
    /// Stop and give the audio session back.
    func stop()
    /// Queue mono speech samples at `sampleRate`. `onPlayed` runs once they
    /// have been heard to the end; never for audio cut off by ``stopSpeech()``,
    /// ``stop()`` or a rebuild, nor when the engine isn't running (then the
    /// samples are dropped).
    func schedule(_ samples: [Float], sampleRate: Double, onPlayed: @escaping @Sendable () -> Void)
    /// Lower the speech while a voice may be interrupting it, or bring it back.
    func duck(_ on: Bool)
    /// Stop the speech now and drop what is queued.
    func stopSpeech()
    func play(_ earcon: Earcon)
}

// MARK: - Frames

/// Cuts 16 kHz audio into ``MicFrame``s of 512 samples, keeping the rest for
/// the next chunk. Pure.
struct MicFrameAssembler: Sendable {
    static let frameSamples = 512
    static let sampleRate: Double = 16_000

    private var pending: [Float] = []
    /// When the first pending sample was captured.
    private var pendingStart: TimeInterval = 0

    init() {}

    /// Add `samples`, captured from `time` on; returns the frames completed.
    mutating func append(_ samples: [Float], startingAt time: TimeInterval) -> [MicFrame] {
        if pending.isEmpty { pendingStart = time }
        pending.append(contentsOf: samples)
        var frames: [MicFrame] = []
        while pending.count >= Self.frameSamples {
            let frame = Array(pending[..<Self.frameSamples])
            pending.removeFirst(Self.frameSamples)
            frames.append(MicFrame(samples: frame, rms: Self.rms(frame), time: pendingStart))
            pendingStart += Double(Self.frameSamples) / Self.sampleRate
        }
        return frames
    }

    mutating func reset() {
        pending = []
        pendingStart = 0
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return value
    }
}

// MARK: - Earcons

/// The earcons, made in code: soft sine tones at about −20 dBFS with 5 ms
/// fades. Listening rises (660 then 880 Hz), "got it" is one short 880 Hz
/// tick, an error falls (330 then 220 Hz). Pure.
enum EarconTone {
    /// −20 dBFS.
    static let peak: Float = 0.1
    static let fadeSeconds = 0.005

    static func tones(_ earcon: Earcon) -> [(hz: Double, seconds: Double)] {
        switch earcon {
        case .listening: return [(hz: 660, seconds: 0.07), (hz: 880, seconds: 0.09)]
        case .gotIt: return [(hz: 880, seconds: 0.04)]
        case .error: return [(hz: 330, seconds: 0.09), (hz: 220, seconds: 0.14)]
        }
    }

    static func samples(_ earcon: Earcon, sampleRate: Double) -> [Float] {
        var out: [Float] = []
        let fade = max(1, Int(fadeSeconds * sampleRate))
        for tone in tones(earcon) {
            let count = Int((tone.seconds * sampleRate).rounded())
            out.reserveCapacity(out.count + count)
            for index in 0..<count {
                var gain = 1.0
                if index < fade {
                    gain = 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fade))
                } else if index >= count - fade {
                    gain = 0.5 - 0.5 * cos(Double.pi * Double(count - 1 - index) / Double(fade))
                }
                let phase = 2 * Double.pi * tone.hz * Double(index) / sampleRate
                out.append(Float(sin(phase) * gain) * peak)
            }
        }
        return out
    }
}

// MARK: - The engine

/// Talk's audio on `AVAudioEngine` (see ``TalkAudioIO``).
///
/// - A fresh engine for every start and every route change, built after the
///   session is active, so the input node reads the route as it is now
///   (the standby crash of 1.3.2 to 1.3.19 came from a reused one).
/// - The microphone tap gives 16 kHz mono 512-sample frames through
///   ``MicrophoneConverter``, the converter voice typing uses.
/// - Two player nodes, one for speech and one for the earcons. With voice
///   processing they are connected before
///   `inputNode.setVoiceProcessingEnabled(true)`, other apps' audio is
///   ducked as little as it allows, and voice processing is turned off
///   before the engine stops.
/// - Every AVFAudio call that can raise runs through ``AVFAudioGuard``, and
///   ``MicrophoneFormatCheck`` checks the input before the tap.
/// - It keeps running with the screen locked (the `audio` background mode);
///   a rebuild keeps the session active, so it works there too.
@MainActor
final class TalkAudioEngine: TalkAudioIO {
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "talk-audio")
    /// Speech plays at BlueTTS's own rate; other rates are resampled to it.
    nonisolated static let playerSampleRate: Double = 44_100
    /// The speech's volume while ducked.
    nonisolated static let duckedVolume: Float = 0.12

    let frames: AsyncStream<MicFrame>
    let events: AsyncStream<TalkAudioEvent>
    private(set) var route: TalkRoute = .builtIn
    private(set) var echoMode: TalkEchoMode = .voiceProcessing
    private(set) var isSpeaking = false

    private let owner: AudioSessionOwner
    private let frameSink: AsyncStream<MicFrame>.Continuation
    private let eventSink: AsyncStream<TalkAudioEvent>.Continuation
    private let observers = ObserverTokens()
    private let playerFormat: AVAudioFormat

    // The engine and its nodes, while built.
    private var engine: AVAudioEngine?
    private var input: AVAudioInputNode?
    private var speechPlayer: AVAudioPlayerNode?
    private var earconPlayer: AVAudioPlayerNode?
    private var tap: TalkMicTap?
    private var tapInstalled = false
    private var voiceProcessingOn = false

    /// Started and not stopped: route changes and resets rebuild the engine.
    private var wantsRunning = false
    /// A call or Siri holds the audio.
    private var interrupted = false
    /// The echo mode asked for at start (the Lab's override).
    private var preference: TalkEchoMode?
    /// Posted ``Notification/Name/talkWillClaimAudio`` and not yet the release.
    private var claimed = false
    private var ducked = false
    /// Bumped when queued speech is dropped, so its completions are ignored.
    private var speechGeneration = 0
    private var pendingSpeech = 0
    private var routeCheck: Task<Void, Never>?
    private var earconBuffers: [Earcon: AVAudioPCMBuffer] = [:]
    private var resamplers: [Double: AVAudioConverter] = [:]

    init(owner: AudioSessionOwner = .shared) {
        self.owner = owner
        let frameStream = AsyncStream.makeStream(of: MicFrame.self, bufferingPolicy: .bufferingNewest(256))
        frames = frameStream.stream
        frameSink = frameStream.continuation
        let eventStream = AsyncStream.makeStream(of: TalkAudioEvent.self)
        events = eventStream.stream
        eventSink = eventStream.continuation
        // The standard 44.1 kHz mono format always exists.
        playerFormat = AVAudioFormat(standardFormatWithSampleRate: Self.playerSampleRate, channels: 1)!
        observe()
    }

    deinit {
        frameSink.finish()
        eventSink.finish()
    }

    // MARK: - Start and stop

    func start(preferring preferred: TalkEchoMode?) throws {
        routeCheck?.cancel()
        routeCheck = nil
        stopSpeech()
        teardownEngine()
        interrupted = false
        preference = preferred
        claim()
        do {
            try startSession()
            wantsRunning = true
        } catch {
            Self.log.error("Talk's audio didn't start: \(AudioErrorText(error).logLine, privacy: .public)")
            Breadcrumbs.add("talk.audio.start_failed")
            teardownEngine()
            owner.release(.talk)
            releaseClaim()
            throw error
        }
    }

    func stop() {
        wantsRunning = false
        interrupted = false
        routeCheck?.cancel()
        routeCheck = nil
        stopSpeech()
        let wasRunning = engine != nil
        teardownEngine()
        owner.release(.talk)
        if wasRunning { Breadcrumbs.add("talk.audio.stop") }
        releaseClaim()
    }

    /// Activate the session for Talk, pick the echo mode for the route, and
    /// build the engine for it.
    private func startSession() throws {
        let session = AVAudioSession.sharedInstance()
        let preferred = preference
        // Active first: the route, and whether this iPhone has echo-cancelled
        // input, are known only for an active `.playAndRecord` session in
        // mode `.default`, which is how the session starts.
        try owner.acquireTalk(echo: preferred ?? .echoCancelledInput)
        let route = TalkEchoPolicy.route(session.currentRoute)
        var echo = TalkEchoPolicy.choose(route: route,
                                         echoCancelledInputAvailable: session.isEchoCancelledInputAvailable,
                                         override: preferred)
        try startEngine(echo: echo)
        if echo == .echoCancelledInput, preferred == nil, !session.isEchoCancelledInputEnabled {
            // Asked for, but iOS didn't turn it on for this route.
            Self.log.notice("Echo-cancelled input isn't on for this route; using voice processing")
            teardownEngine()
            echo = .voiceProcessing
            try startEngine(echo: echo)
        }
        self.route = route
        echoMode = echo
        Self.log.info("Talk's audio runs on \(TalkEchoPolicy.name(of: route), privacy: .public) with \(TalkEchoPolicy.name(of: echo), privacy: .public)")
        Breadcrumbs.add("talk.audio.start",
                        "\(TalkEchoPolicy.name(of: route)) \(TalkEchoPolicy.name(of: echo)) \(Diagnostics.routeDescription())")
    }

    /// Build and start the engine for `echo` on the active session; when that
    /// fails, once more after a clean deactivate, as a cold microphone start
    /// does (``AudioSessionOwner`` retries that one too).
    private func startEngine(echo: TalkEchoMode) throws {
        do {
            try owner.acquireTalk(echo: echo) { try buildEngine(echo: echo) }
        } catch {
            Self.log.error("Talk's engine didn't start (\(AudioErrorText(error).logLine, privacy: .public)); trying again")
            teardownEngine()
            owner.release(.talk)
            try owner.acquireTalk(echo: echo) { try buildEngine(echo: echo) }
        }
    }

    /// A fresh engine: the players, voice processing when asked, the format
    /// check, the tap, then start. Registered at once, so a failure anywhere
    /// is undone by ``teardownEngine()``.
    private func buildEngine(echo: TalkEchoMode) throws {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else { throw TalkAudioError.noInput }
        teardownEngine()
        let engine = AVAudioEngine()
        let speech = AVAudioPlayerNode()
        let earcons = AVAudioPlayerNode()
        self.engine = engine
        do {
            // The players go in first: with voice processing they must be
            // connected before it is turned on.
            try AVFAudioGuard.run("set up Talk's players") {
                engine.attach(speech)
                engine.attach(earcons)
                engine.connect(speech, to: engine.mainMixerNode, format: playerFormat)
                engine.connect(earcons, to: engine.mainMixerNode, format: playerFormat)
            }
            speechPlayer = speech
            earconPlayer = earcons
            let input = try AVFAudioGuard.run("get Talk's microphone input") { engine.inputNode }
            self.input = input
            if echo == .voiceProcessing {
                try AVFAudioGuard.run("turn on voice processing") { try input.setVoiceProcessingEnabled(true) }
                voiceProcessingOn = true
                // Other apps' audio is ducked as little as voice processing allows.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let hardware = AudioFormatShape(input.inputFormat(forBus: 0))
            let tapFormat = input.outputFormat(forBus: 0)
            let check = MicrophoneFormatCheck.evaluate(hardware: hardware, output: AudioFormatShape(tapFormat),
                                                       inputAvailable: session.isInputAvailable)
            guard check == .ready else {
                let detail = "hw=\(Int(hardware.sampleRate))/\(hardware.channelCount) tap=\(Int(tapFormat.sampleRate))/\(tapFormat.channelCount) session=\(Int(session.sampleRate))"
                Self.log.error("Talk's microphone format isn't usable (\(String(describing: check), privacy: .public)): \(detail, privacy: .public)")
                Breadcrumbs.add("talk.audio.format", detail)
                if case .unavailable(let problem) = check { throw DictationRecorder.RecorderError.format(problem) }
                throw TalkAudioError.noInput
            }
            guard let converter = MicrophoneConverter(inputFormat: tapFormat) else { throw TalkAudioError.noInput }
            let tap = TalkMicTap(converter: converter, sink: frameSink)
            let block = Self.tapBlock(tap)
            try AVFAudioGuard.run("install Talk's microphone tap") {
                input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat, block: block)
            }
            self.tap = tap
            tapInstalled = true
            try AVFAudioGuard.run("start Talk's audio") {
                engine.prepare()
                try engine.start()
            }
            // A route change can stop it again before this returns.
            guard engine.isRunning else { throw DictationRecorder.RecorderError.format(.formatChanging) }
            try AVFAudioGuard.run("start Talk's players") {
                speech.play()
                earcons.play()
            }
            speech.volume = ducked ? Self.duckedVolume : 1
        } catch {
            teardownEngine()
            throw error
        }
    }

    /// The tap's block, made outside the main actor: it runs on the audio
    /// thread.
    nonisolated private static func tapBlock(_ tap: TalkMicTap) -> AVAudioNodeTapBlock {
        { buffer, when in tap.consume(buffer, at: when) }
    }

    /// Undo whatever of the engine is built. Voice processing goes off before
    /// the engine stops (and again after, if the running engine refused), so
    /// it never outlives Talk. The session stays as it is.
    private func teardownEngine() {
        guard let engine else { return }
        let input = self.input
        let speech = speechPlayer
        let earcons = earconPlayer
        let hadTap = tapInstalled
        let processing = voiceProcessingOn
        self.engine = nil
        self.input = nil
        speechPlayer = nil
        earconPlayer = nil
        tap?.close()
        tap = nil
        tapInstalled = false
        voiceProcessingOn = false
        if hadTap, let input {
            try? AVFAudioGuard.run("remove Talk's microphone tap") { input.removeTap(onBus: 0) }
        }
        if processing, let input {
            try? AVFAudioGuard.run("turn off voice processing") { try input.setVoiceProcessingEnabled(false) }
        }
        try? AVFAudioGuard.run("stop Talk's players") {
            speech?.stop()
            earcons?.stop()
        }
        try? AVFAudioGuard.run("stop Talk's audio") { engine.stop() }
        if processing, let input, input.isVoiceProcessingEnabled {
            try? AVFAudioGuard.run("turn off voice processing") { try input.setVoiceProcessingEnabled(false) }
        }
    }

    // MARK: - Speech and earcons

    func schedule(_ samples: [Float], sampleRate: Double, onPlayed: @escaping @Sendable () -> Void) {
        guard !samples.isEmpty else { return }
        guard let engine, engine.isRunning, let player = speechPlayer else {
            Self.log.notice("Speech dropped: Talk's audio isn't running")
            return
        }
        guard let buffer = speechBuffer(samples, sampleRate: sampleRate) else {
            Self.log.error("Speech dropped: it didn't convert from \(Int(sampleRate)) Hz")
            return
        }
        let generation = speechGeneration
        pendingSpeech += 1
        isSpeaking = true
        do {
            try AVFAudioGuard.run("queue Talk's speech") {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in self?.speechPlayed(generation: generation, onPlayed: onPlayed) }
                }
            }
            if !player.isPlaying {
                try AVFAudioGuard.run("play Talk's speech") { player.play() }
            }
        } catch {
            pendingSpeech = max(0, pendingSpeech - 1)
            isSpeaking = pendingSpeech > 0
            eventSink.yield(.engineFailed(AudioErrorText(error).message("Couldn't play the reply")))
        }
    }

    private func speechPlayed(generation: Int, onPlayed: @Sendable () -> Void) {
        // Cut off by stopSpeech, stop or a rebuild: not heard to the end.
        guard generation == speechGeneration else { return }
        pendingSpeech = max(0, pendingSpeech - 1)
        isSpeaking = pendingSpeech > 0
        onPlayed()
    }

    func duck(_ on: Bool) {
        ducked = on
        speechPlayer?.volume = on ? Self.duckedVolume : 1
    }

    func stopSpeech() {
        speechGeneration &+= 1
        pendingSpeech = 0
        isSpeaking = false
        guard let player = speechPlayer else { return }
        // A stopped player needs `play()` again: `schedule` does it.
        try? AVFAudioGuard.run("stop Talk's speech") { player.stop() }
    }

    func play(_ earcon: Earcon) {
        guard let engine, engine.isRunning, let player = earconPlayer else { return }
        let buffer: AVAudioPCMBuffer
        if let cached = earconBuffers[earcon] {
            buffer = cached
        } else {
            guard let made = Self.pcmBuffer(EarconTone.samples(earcon, sampleRate: Self.playerSampleRate),
                                            format: playerFormat) else { return }
            earconBuffers[earcon] = made
            buffer = made
        }
        try? AVFAudioGuard.run("play a Talk earcon") {
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
    }

    /// `samples` at `sampleRate` as a buffer in the players' format.
    private func speechBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard sampleRate > 0 else { return nil }
        if abs(sampleRate - Self.playerSampleRate) < 1 { return Self.pcmBuffer(samples, format: playerFormat) }
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let source = Self.pcmBuffer(samples, format: sourceFormat) else { return nil }
        let converter: AVAudioConverter
        if let cached = resamplers[sampleRate] {
            converter = cached
        } else {
            guard let made = AVAudioConverter(from: sourceFormat, to: playerFormat) else { return nil }
            resamplers[sampleRate] = made
            converter = made
        }
        // Each piece of speech is a whole of its own.
        converter.reset()
        let capacity = AVAudioFrameCount(Double(samples.count) * Self.playerSampleRate / sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    nonisolated static func pcmBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    // MARK: - The session's events

    private func observe() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                         queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            MainActor.assumeIsolated { self?.interruption(type, shouldResume: options.contains(.shouldResume)) }
        })
        observers.add(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRouteCheck() }
        })
        observers.add(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesWereReset() }
        })
        observers.add(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                         queue: .main) { [weak self] note in
            let changed = note.object as AnyObject?
            MainActor.assumeIsolated {
                // Only this engine's change matters (read aloud and the
                // dictation recorder have engines of their own).
                guard let self, let engine = self.engine, changed === engine else { return }
                self.scheduleRouteCheck()
            }
        })
        let owner = self.owner
        observers.add(center.addObserver(forName: .audioSessionUseWillChange, object: nil,
                                         queue: .main) { [weak self] note in
            guard (note.object as AnyObject?) === owner,
                  note.userInfo?["from"] as? String == AudioSessionUse.talk.rawValue else { return }
            MainActor.assumeIsolated { self?.sessionTaken() }
        })
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard claimed else { return }
        switch type {
        case .began?:
            guard !interrupted else { return }
            interrupted = true
            routeCheck?.cancel()
            stopSpeech()
            teardownEngine()
            Breadcrumbs.add("talk.audio.interrupted")
            eventSink.yield(.interruptionBegan)
        case .ended?:
            let wasInterrupted = interrupted || (wantsRunning && engine == nil)
            interrupted = false
            if wasInterrupted { eventSink.yield(.interruptionEnded(shouldResume: shouldResume)) }
        default:
            break
        }
    }

    /// A route or configuration change: look once things settle.
    private func scheduleRouteCheck() {
        guard wantsRunning, !interrupted else { return }
        routeCheck?.cancel()
        routeCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.checkRoute()
        }
    }

    /// Rebuild when the route is another kind now, or the engine stopped.
    /// Talk's own session changes don't change the route, so they rebuild
    /// nothing.
    private func checkRoute() {
        guard wantsRunning, !interrupted else { return }
        let now = TalkEchoPolicy.route(AVAudioSession.sharedInstance().currentRoute)
        let running = engine?.isRunning == true
        guard now != route || !running else { return }
        rebuild(reason: running ? "route" : "engine_stopped")
    }

    private func rebuild(reason: String) {
        Self.log.notice("Rebuilding Talk's audio (\(reason, privacy: .public))")
        Breadcrumbs.add("talk.audio.rebuild", reason)
        stopSpeech()
        teardownEngine()
        do {
            try startSession()
            eventSink.yield(.routeChanged(route))
        } catch {
            wantsRunning = false
            let message = AudioErrorText(error).message("Talk's audio stopped")
            Self.log.error("\(message, privacy: .public)")
            owner.release(.talk)
            eventSink.yield(.engineFailed(message))
        }
    }

    private func mediaServicesWereReset() {
        guard claimed else { return }
        // Every audio object is gone: drop ours without calling into them.
        engine = nil
        input = nil
        speechPlayer = nil
        earconPlayer = nil
        tap?.close()
        tap = nil
        tapInstalled = false
        voiceProcessingOn = false
        speechGeneration &+= 1
        pendingSpeech = 0
        isSpeaking = false
        Breadcrumbs.add("talk.audio.media_reset")
        eventSink.yield(.mediaServicesReset)
        guard wantsRunning, !interrupted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.wantsRunning, !self.interrupted, self.engine == nil else { return }
            self.rebuild(reason: "media_services_reset")
        }
    }

    /// Another use of the app took the session from Talk.
    private func sessionTaken() {
        guard claimed, wantsRunning || engine != nil else { return }
        wantsRunning = false
        routeCheck?.cancel()
        stopSpeech()
        teardownEngine()
        eventSink.yield(.engineFailed("Another part of the app took the audio."))
    }

    private func claim() {
        guard !claimed else { return }
        claimed = true
        NotificationCenter.default.post(name: .talkWillClaimAudio, object: self)
    }

    private func releaseClaim() {
        guard claimed else { return }
        claimed = false
        NotificationCenter.default.post(name: .talkDidReleaseAudio, object: self)
    }
}

/// The microphone tap's work, on the audio thread: each buffer converted to
/// 16 kHz mono and cut into ``MicFrame``s.
final class TalkMicTap: @unchecked Sendable {
    private let converter: MicrophoneConverter
    private let sink: AsyncStream<MicFrame>.Continuation
    private let lock = NSLock()
    private var assembler = MicFrameAssembler()
    private var closed = false

    init(converter: MicrophoneConverter, sink: AsyncStream<MicFrame>.Continuation) {
        self.converter = converter
        self.sink = sink
    }

    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let converted = converter.convert(buffer) else { return }
        let start = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : ProcessInfo.processInfo.systemUptime - Double(converted.samples.count) / MicrophoneConverter.sampleRate
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let frames = assembler.append(converted.samples, startingAt: start)
        lock.unlock()
        for frame in frames { sink.yield(frame) }
    }

    /// The engine is going: nothing more is yielded.
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// Notification observers removed when their owner goes.
private final class ObserverTokens {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

enum TalkAudioError: PlainAudioError, Equatable {
    case noInput

    var errorDescription: String? { "No microphone is available." }
}
