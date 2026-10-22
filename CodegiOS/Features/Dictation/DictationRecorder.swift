import AVFoundation
import Accelerate
import os

/// The last few seconds of microphone audio, oldest first, overwritten in
/// place once full. Memory only.
struct AudioRingBuffer: Equatable, Sendable {
    let capacity: Int
    private var storage: [Float]
    /// Where the next sample goes.
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: 0, count: self.capacity)
    }

    mutating func append<C: Collection>(contentsOf samples: C) where C.Element == Float {
        // Only the newest `capacity` samples can survive.
        let kept = samples.count > capacity ? samples.dropFirst(samples.count - capacity) : samples[...]
        for sample in kept {
            storage[head] = sample
            head = (head + 1) % capacity
        }
        count = min(capacity, count + kept.count)
    }

    /// The samples held, oldest first.
    var contents: [Float] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        if start + count <= capacity { return Array(storage[start..<(start + count)]) }
        return Array(storage[start...]) + Array(storage[..<(start + count - capacity)])
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }
}

/// What the recorder keeps of the audio it receives: in standby, only the
/// last ``AudioRingBuffer/capacity`` samples (the pre-roll); while recording,
/// everything, starting with the pre-roll it held when the recording began.
struct RecordingBuffer: Equatable, Sendable {
    private(set) var preRoll: AudioRingBuffer
    private(set) var samples: [Float] = []
    private(set) var isRecording = false
    /// Longest recording kept, in samples.
    let maxSamples: Int

    init(preRollSamples: Int, maxSamples: Int) {
        preRoll = AudioRingBuffer(capacity: preRollSamples)
        self.maxSamples = maxSamples
    }

    /// Audio from the microphone, in order.
    mutating func receive<C: Collection>(_ chunk: C) where C.Element == Float {
        if isRecording {
            let room = maxSamples - samples.count
            if room > 0 { samples.append(contentsOf: chunk.prefix(room)) }
        } else {
            preRoll.append(contentsOf: chunk)
        }
    }

    /// Start keeping everything. With `includePreRoll`, the recording starts
    /// with the audio held from just before; otherwise that is dropped.
    mutating func beginRecording(includePreRoll: Bool) {
        samples = includePreRoll ? preRoll.contents : []
        samples.reserveCapacity(16_000 * 30)
        preRoll.removeAll()
        isRecording = true
    }

    /// Stop keeping everything and hand the recording over; standby starts
    /// filling the pre-roll again from empty.
    mutating func endRecording() -> [Float] {
        let recorded = samples
        samples = []
        isRecording = false
        preRoll.removeAll()
        return recorded
    }

    /// Drop everything (standby ended, or a recording was thrown away).
    mutating func reset() {
        samples = []
        isRecording = false
        preRoll.removeAll()
    }
}

/// Captures the microphone as 16 kHz mono Float32, the input whisper wants,
/// and keeps the current input level for the meter.
///
/// The audio session belongs to ``AudioSessionOwner``; ``MicrophoneState``
/// decides when the engine starts and stops. A recording normally starts the
/// microphone cold (`.playAndRecord`, AirPods' microphone allowed) and stops
/// it at the end, deactivating with `.notifyOthersOnDeactivation` so other
/// apps' audio resumes. A reply being read aloud is stopped first.
///
/// For Camera Control to talk the recorder can also stand by: the microphone
/// runs and the last ``preRollSeconds`` stay in memory, so a recording that
/// starts on a button press begins with the words said while the audio was
/// still starting. Any recording that starts then (the mic button too)
/// records from the running engine without activating the session again.
/// Standby listens through the iPhone's microphone and mixes with other
/// audio (`.mixWithOthers`, Bluetooth A2DP rather than HFP), so AirPods keep
/// playing in full quality and music in other apps keeps going.
final class DictationRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Longest recording kept (5 minutes); the controller stops at this length.
    static let maxSeconds: Double = 300
    /// Audio kept from before a recording starts, in standby.
    static let preRollSeconds: Double = 1.5

    /// The engine while the microphone runs; a cold start builds a new one
    /// (see ``runEngine()``).
    private var engine: AVAudioEngine?
    private let audio: AudioSessionOwner
    private let lock = NSLock()
    private var buffer = RecordingBuffer(preRollSamples: Int(preRollSeconds * sampleRate),
                                         maxSamples: Int(maxSeconds * sampleRate))
    private var level: Float = 0
    private var state = MicrophoneState()
    /// The tap is installed on the input node.
    private var tapInstalled = false
    /// Uptime of the button press the current recording started from, until
    /// its first live buffer arrives (logged, then cleared).
    private var pressUptime: TimeInterval?
    private var preRollAtStart: Double = 0

    /// Called on an arbitrary queue when the audio route or the engine's
    /// configuration changes under a running recording (AirPods removed, a
    /// call comes in). The controller then finishes the recording.
    var onInterrupted: (() -> Void)?
    /// Called on an arbitrary queue when standby stopped by itself (a call, a
    /// route change), so the controller can start it again later.
    var onStandbyLost: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(audio: AudioSessionOwner = .shared) {
        self.audio = audio
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                            queue: nil) { [weak self] note in
            // Activating the session can post one of these while the engine
            // keeps running; only a change that stopped this recorder's
            // current engine matters (read aloud has an engine of its own).
            guard let self, let changed = note.object as? AVAudioEngine,
                  changed === self.withLock({ self.engine }), !changed.isRunning else { return }
            self.engineStoppedByItself("the audio route or configuration changed")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: nil) { [weak self] _ in
            self?.engineStoppedByItself("the iPhone's audio services restarted")
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.engineStoppedByItself("an interruption began (a call, Siri, an alarm)")
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Recorded audio so far, in seconds.
    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(buffer.samples.count) / Self.sampleRate
    }

    /// The latest input level, 0…1 (−55 dBFS … 0 dBFS).
    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// The microphone is standing by (or recording from standby).
    var isStandingBy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isStandingBy
    }

    // MARK: - Permission

    enum Permission { case granted, denied, undetermined }

    static var permission: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Set the recording category without activating the session, so a later
    /// cold start skips the category switch. Cheap; changes nothing audible.
    static func prepareCategory() {
        AudioSessionOwner.shared.prepare(.recording)
    }

    // MARK: - Standby

    /// Keep the microphone running with the last ``preRollSeconds`` in
    /// memory. Does nothing while a recording runs (it carries on in standby
    /// afterwards) or if standby is already on.
    func startStandby() throws {
        let step = withLock { state.wantStandby() }
        try perform(step, recordingStarts: false)
    }

    /// Stop standing by: the microphone stops and the session is
    /// deactivated, unless a recording runs, which then stops it when it ends.
    func stopStandby() {
        let step = withLock { state.dropStandby() }
        try? perform(step, recordingStarts: false)
    }

    // MARK: - Recording

    /// How a recording started, for the log.
    enum Start: Equatable {
        /// From the standing-by engine: no activation.
        case fromStandby
        /// The engine started for it.
        case started(AudioSessionUse)
    }

    /// Start recording. In standby the recording begins with the pre-roll
    /// (unless `includePreRoll` is false) and the microphone is already
    /// running; otherwise the microphone starts now. `pressUptime` is when the
    /// button that started it went down, for the log.
    @discardableResult
    func start(includePreRoll: Bool = true, pressUptime: TimeInterval? = nil) throws -> Start {
        lock.lock()
        let running = state.engine
        let step = state.beginRecording()
        if running != nil {
            buffer.beginRecording(includePreRoll: includePreRoll && running == .standby)
        } else {
            buffer.reset()
            buffer.beginRecording(includePreRoll: false)
        }
        preRollAtStart = Double(buffer.samples.count) / Self.sampleRate
        self.pressUptime = pressUptime
        level = 0
        lock.unlock()
        do {
            try perform(step, recordingStarts: true)
        } catch {
            lock.lock()
            buffer.reset()
            self.pressUptime = nil
            lock.unlock()
            throw error
        }
        if case .startEngine(let use) = step { return .started(use) }
        return .fromStandby
    }

    /// Stop and return everything recorded. In standby the microphone keeps
    /// running for the next one.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        let step = state.endRecording()
        let recorded = buffer.endRecording()
        pressUptime = nil
        level = 0
        lock.unlock()
        do {
            try perform(step, recordingStarts: false)
        } catch {
            // Standby couldn't take over after a cold recording; its retry does.
            onStandbyLost?()
        }
        return recorded
    }

    // MARK: - Engine

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func perform(_ step: MicrophoneState.Step, recordingStarts: Bool) throws {
        switch step {
        case .none:
            return
        case .startEngine(let use):
            try startEngine(for: use, recordingStarts: recordingStarts)
        case .stopEngine(let use):
            stopEngine(releasing: use)
        case .restartEngine(let from, let to):
            stopEngine(releasing: from)
            try startEngine(for: to, recordingStarts: false)
        }
    }

    private func startEngine(for use: AudioSessionUse, recordingStarts: Bool) throws {
        do {
            let outcome = try audio.acquire(use) { try runEngine() }
            withLock { state.engineStarted(use) }
            Breadcrumbs.add("mic.start", "\(use.rawValue) \(Diagnostics.routeDescription())")
            if outcome == .activatedOnRetry {
                DictationRecorder.log.notice("Microphone started for \(use.rawValue, privacy: .public) on the second try")
            }
        } catch {
            Breadcrumbs.add("mic.start_failed", use.rawValue)
            withLock {
                state.engineFailed(duringRecording: recordingStarts)
                if !recordingStarts { buffer.reset() }
            }
            throw error
        }
    }

    /// Build a fresh engine, check the microphone's formats, install the tap
    /// and start; undo all of it if a step fails.
    ///
    /// A fresh engine every time: an engine that ran before keeps the formats
    /// of the route it ran on, and after read aloud, a video or AirPods
    /// switching profile changed the route, `installTap` with those formats
    /// raises an Objective-C exception that ended the app (the crash in
    /// 1.3.2 to 1.3.19, always from the Camera Control's standby). Every call
    /// that can raise goes through ``AVFAudioGuard``, so whatever is left
    /// becomes an error, and ``AudioSessionOwner`` retries once.
    private func runEngine() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else { throw RecorderError.noInput }
        // One left running by a stop this recorder missed goes first.
        if let leftover = withLock({ () -> AVAudioEngine? in
            defer { self.engine = nil; tapInstalled = false }
            return self.engine
        }) {
            try? AVFAudioGuard.run("remove the microphone tap") { leftover.inputNode.removeTap(onBus: 0) }
            try? AVFAudioGuard.run("stop the microphone") { leftover.stop() }
        }
        let engine = AVAudioEngine()
        let input = try AVFAudioGuard.run("get the microphone input") { engine.inputNode }
        let hardware = AudioFormatShape(input.inputFormat(forBus: 0))
        let tapFormat = input.outputFormat(forBus: 0)
        let check = MicrophoneFormatCheck.evaluate(hardware: hardware, output: AudioFormatShape(tapFormat),
                                                   inputAvailable: session.isInputAvailable)
        if MicrophoneFormatCheck.isStale(node: hardware, sessionSampleRate: session.sampleRate) {
            // Still tapped (a fresh node is right more often than the
            // session), but worth knowing when a report comes in.
            Breadcrumbs.add("mic.rate_differs", "node=\(Int(hardware.sampleRate)) session=\(Int(session.sampleRate))")
        }
        guard check == .ready else {
            let detail = "hw=\(Int(hardware.sampleRate))/\(hardware.channelCount) tap=\(Int(tapFormat.sampleRate))/\(tapFormat.channelCount) session=\(Int(session.sampleRate))"
            DictationRecorder.log.error("Microphone format not usable (\(String(describing: check), privacy: .public)): \(detail, privacy: .public)")
            Breadcrumbs.add("mic.format", detail)
            if case .unavailable(let problem) = check { throw RecorderError.format(problem) }
            throw RecorderError.noInput
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: tapFormat, to: target) else {
            throw RecorderError.noInput
        }
        try AVFAudioGuard.run("install the microphone tap") {
            input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
                self?.consume(buffer, converter: converter, target: target)
            }
        }
        // Known before it starts, so a configuration change posted while it
        // starts is matched to it.
        withLock {
            self.engine = engine
            tapInstalled = true
        }
        do {
            try AVFAudioGuard.run("start the microphone") {
                engine.prepare()
                try engine.start()
            }
            // A route change can stop it again before this returns.
            guard engine.isRunning else { throw RecorderError.format(.formatChanging) }
        } catch {
            withLock {
                self.engine = nil
                tapInstalled = false
            }
            try? AVFAudioGuard.run("remove the microphone tap") { input.removeTap(onBus: 0) }
            try? AVFAudioGuard.run("stop the microphone") { engine.stop() }
            throw error
        }
    }

    private func stopEngine(releasing use: AudioSessionUse) {
        let (engine, hadTap) = withLock { () -> (AVAudioEngine?, Bool) in
            let running = (self.engine, tapInstalled)
            self.engine = nil
            tapInstalled = false
            return running
        }
        if let engine {
            if hadTap { try? AVFAudioGuard.run("remove the microphone tap") { engine.inputNode.removeTap(onBus: 0) } }
            try? AVFAudioGuard.run("stop the microphone") { engine.stop() }
        }
        withLock {
            if !state.recording { buffer.reset() }
            level = 0
        }
        Breadcrumbs.add("mic.stop", use.rawValue)
        audio.release(use)
    }

    /// The engine stopped under us (an interruption, a route change).
    private func engineStoppedByItself(_ why: String) {
        lock.lock()
        let use = state.engineStopped()
        let wasRecording = state.recording
        let standbyWanted = state.standbyWanted
        lock.unlock()
        guard let use else { return }
        DictationRecorder.log.notice("Microphone stopped by itself: \(why, privacy: .public)")
        Breadcrumbs.add("mic.lost", use.rawValue)
        stopEngine(releasing: use)
        if wasRecording {
            onInterrupted?()
        } else if standbyWanted {
            onStandbyLost?()
        }
    }

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "dictation")

    /// On the audio thread: meter the buffer, convert it to 16 kHz mono, keep it.
    private func consume(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        // A buffer in another format than the converter was built for (the
        // route changed under the tap) is dropped, not converted.
        guard input.format.sampleRate == converter.inputFormat.sampleRate,
              input.format.channelCount == converter.inputFormat.channelCount else { return }
        var rms: Float = 0
        if let channel = input.floatChannelData?[0], input.frameLength > 0 {
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(input.frameLength))
        }
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = min(1, max(0, (db + 55) / 55))

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))

        lock.lock()
        buffer.receive(chunk)
        let firstAfterPress = state.recording ? pressUptime : nil
        if firstAfterPress != nil { pressUptime = nil }
        let preRoll = preRollAtStart
        // Fast attack, slower release, so the meter reads as speech, not flicker.
        level = normalized > level ? normalized : level * 0.7 + normalized * 0.3
        lock.unlock()
        if let pressed = firstAfterPress {
            let ms = Int((ProcessInfo.processInfo.systemUptime - pressed) * 1000)
            CameraTalkController.log.info("First live audio \(ms) ms after the press; \(Int(preRoll * 1000)) ms of pre-roll kept")
        }
    }

    enum RecorderError: PlainAudioError, Equatable {
        case noInput
        case format(MicrophoneFormatCheck.Problem)

        var errorDescription: String? {
            switch self {
            case .noInput, .format(.noInput): "No microphone is available."
            case .format(.emptyFormat): "The microphone isn't ready yet, try again."
            case .format(.formatChanging): "The audio route changed as the microphone started, try again."
            }
        }
    }
}
