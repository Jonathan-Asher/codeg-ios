import AVFoundation
import Accelerate

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
/// A recording normally starts the microphone cold: the audio session is
/// `.playAndRecord` while recording, so a reply being read aloud is stopped
/// first (the read-aloud player switches the session back to `.playback`
/// when it next starts), and it is deactivated with
/// `.notifyOthersOnDeactivation` when recording ends, so other apps' audio
/// resumes.
///
/// For Camera Control to talk the recorder can also stand by: the microphone
/// runs and the last ``preRollSeconds`` stay in memory, so a recording that
/// starts on a button press begins with the words said while the audio was
/// still starting. Standby listens through the iPhone's microphone and mixes
/// with other audio (`.mixWithOthers`, Bluetooth A2DP rather than HFP), so
/// AirPods keep playing in full quality and music in other apps keeps going.
final class DictationRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Longest recording kept (5 minutes); the controller stops at this length.
    static let maxSeconds: Double = 300
    /// Audio kept from before a recording starts, in standby.
    static let preRollSeconds: Double = 1.5

    /// The cold recording's session: AirPods (HFP) work as the microphone.
    static let recordingOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
    /// Standby's session: the iPhone's microphone, AirPods stay in A2DP, other
    /// apps' audio keeps playing.
    static let standbyOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffer = RecordingBuffer(preRollSamples: Int(preRollSeconds * sampleRate),
                                         maxSamples: Int(maxSeconds * sampleRate))
    private var level: Float = 0
    /// A recording is running (everything is kept).
    private var running = false
    /// The engine runs with the tap installed (recording or standby).
    private var engineOn = false
    /// Standby is wanted: after a recording, keep the microphone running.
    private var standbyWanted = false
    /// The engine was started for a recording, with the recording's session
    /// options, not standby's.
    private var startedCold = false
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

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: nil) { [weak self] _ in
            // Activating the session can post one of these while the engine
            // keeps running; only a change that stopped the engine matters.
            guard let self, !self.engine.isRunning else { return }
            self.interrupted()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.interrupted()
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
        return engineOn && standbyWanted
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
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord || session.categoryOptions != recordingOptions else { return }
        try? session.setCategory(.playAndRecord, mode: .default, options: recordingOptions)
    }

    // MARK: - Standby

    /// Keep the microphone running with the last ``preRollSeconds`` in
    /// memory. Does nothing while a recording runs (it carries on in standby
    /// afterwards) or if standby is already on.
    func startStandby() throws {
        lock.lock()
        standbyWanted = true
        let on = engineOn
        lock.unlock()
        guard !on else { return }
        lock.lock()
        startedCold = false
        lock.unlock()
        do {
            try startEngine(options: Self.standbyOptions)
        } catch {
            lock.lock()
            standbyWanted = false
            lock.unlock()
            throw error
        }
    }

    /// Stop standing by: the microphone stops and the session is
    /// deactivated, unless a recording runs, which then stops it when it ends.
    func stopStandby() {
        lock.lock()
        standbyWanted = false
        let stopNow = engineOn && !running
        lock.unlock()
        if stopNow { stopEngine() }
    }

    // MARK: - Recording

    /// Start recording. In standby the recording begins with the pre-roll
    /// (unless `includePreRoll` is false) and the microphone is already
    /// running; otherwise the microphone starts now. `pressUptime` is when the
    /// button that started it went down, for the log.
    func start(includePreRoll: Bool = true, pressUptime: TimeInterval? = nil) throws {
        lock.lock()
        let warm = engineOn
        if warm {
            buffer.beginRecording(includePreRoll: includePreRoll)
            preRollAtStart = Double(buffer.samples.count) / Self.sampleRate
            running = true
            self.pressUptime = pressUptime
            level = 0
        }
        lock.unlock()
        guard !warm else { return }

        lock.lock()
        buffer.reset()
        buffer.beginRecording(includePreRoll: false)
        preRollAtStart = 0
        startedCold = true
        running = true
        self.pressUptime = pressUptime
        level = 0
        lock.unlock()
        do {
            try startEngine(options: Self.recordingOptions)
        } catch {
            lock.lock()
            running = false
            buffer.reset()
            self.pressUptime = nil
            lock.unlock()
            throw error
        }
    }

    /// Stop and return everything recorded. In standby the microphone keeps
    /// running for the next one.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        let wasRunning = running
        running = false
        pressUptime = nil
        let recorded = buffer.endRecording()
        level = 0
        // Standby restarts with its own session options after a cold recording.
        let keepEngine = standbyWanted && engineOn && !startedCold
        lock.unlock()
        if wasRunning, !keepEngine { stopEngine() }
        return recorded
    }

    // MARK: - Engine

    private func startEngine(options: AVAudioSession.CategoryOptions) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // The press and release haptics (mic button, Camera Control) would
        // otherwise be muted while the microphone records.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        lock.lock()
        engineOn = true
        lock.unlock()
    }

    private func stopEngine() {
        lock.lock()
        let wasOn = engineOn
        engineOn = false
        startedCold = false
        buffer.reset()
        level = 0
        lock.unlock()
        guard wasOn else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func interrupted() {
        lock.lock()
        let wasRunning = running
        let standingBy = engineOn && !running
        lock.unlock()
        if wasRunning {
            onInterrupted?()
        } else if standingBy {
            // Standby lost the microphone (a call, Siri, a route change).
            stopEngine()
            onStandbyLost?()
        }
    }

    /// On the audio thread: meter the buffer, convert it to 16 kHz mono, keep it.
    private func consume(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
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
        let firstAfterPress = running ? pressUptime : nil
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

    enum RecorderError: LocalizedError {
        case noInput

        var errorDescription: String? { "No microphone is available." }
    }
}
