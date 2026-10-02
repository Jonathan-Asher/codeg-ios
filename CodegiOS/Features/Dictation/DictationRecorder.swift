import AVFoundation
import Accelerate

/// Captures the microphone as 16 kHz mono Float32, the input whisper wants,
/// and keeps the current input level for the meter.
///
/// The audio session is `.playAndRecord` while recording, so a reply being
/// read aloud is stopped first (the read-aloud player switches the session
/// back to `.playback` when it next starts), and it is deactivated with
/// `.notifyOthersOnDeactivation` when recording ends, so other apps' audio
/// resumes.
final class DictationRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Longest recording kept (5 minutes); the controller stops at this length.
    static let maxSeconds: Double = 300

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var level: Float = 0
    private var running = false

    /// Called on an arbitrary queue when the audio route or the engine's
    /// configuration changes under a running recording (AirPods removed, a
    /// call comes in). The controller then finishes the recording.
    var onInterrupted: (() -> Void)?

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
        return Double(samples.count) / Self.sampleRate
    }

    /// The latest input level, 0…1 (−55 dBFS … 0 dBFS).
    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
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

    // MARK: - Recording

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
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

        lock.lock()
        samples = []
        samples.reserveCapacity(Int(Self.sampleRate) * 30)
        level = 0
        running = true
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            running = false
            lock.unlock()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    /// Stop and return everything recorded.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        lock.lock()
        defer { lock.unlock() }
        let recorded = samples
        samples = []
        level = 0
        return recorded
    }

    private func interrupted() {
        lock.lock()
        let wasRunning = running
        lock.unlock()
        if wasRunning { onInterrupted?() }
    }

    /// On the audio thread: meter the buffer, convert it to 16 kHz mono, keep it.
    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        var rms: Float = 0
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        }
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = min(1, max(0, (db + 55) / 55))

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
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
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))

        lock.lock()
        if running, Double(samples.count) < Self.maxSeconds * Self.sampleRate {
            samples.append(contentsOf: chunk)
        }
        // Fast attack, slower release, so the meter reads as speech, not flicker.
        level = normalized > level ? normalized : level * 0.7 + normalized * 0.3
        lock.unlock()
    }

    enum RecorderError: LocalizedError {
        case noInput

        var errorDescription: String? { "No microphone is available." }
    }
}
