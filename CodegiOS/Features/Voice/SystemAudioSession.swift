import AVFoundation

/// `AVAudioSession` behind ``AudioSessionDriver``: the category, mode and
/// options for each ``AudioSessionUse``.
final class SystemAudioSession: AudioSessionDriver {
    /// A recording without standby: AirPods (HFP) work as the microphone.
    static let recordingOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
    /// Standby: the iPhone's microphone, AirPods stay in A2DP, other apps'
    /// audio keeps playing.
    static let standbyOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
    /// Talk: the speaker unless something is plugged in, AirPods' microphone
    /// (HFP) allowed.
    static let talkOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
    /// Talk's IO buffer: 10 ms, so the speech ducks within a frame or two of
    /// a voice starting.
    static let talkIOBufferDuration: TimeInterval = 0.01

    private var session: AVAudioSession { .sharedInstance() }
    /// How Talk keeps its speech out of the microphone, for the next
    /// `configure(for: .talk)`.
    private var talkEcho: TalkEchoMode = .voiceProcessing

    func configure(for use: AudioSessionUse) throws {
        switch use {
        case .standby:
            try configureRecording(options: Self.standbyOptions)
        case .recording:
            try configureRecording(options: Self.recordingOptions)
        case .readAloud:
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        case .media:
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        case .talk:
            try configureTalk()
        }
    }

    func prepareTalk(echo: TalkEchoMode) {
        talkEcho = echo
    }

    private func configureTalk() throws {
        let mode = TalkEchoPolicy.sessionMode(for: talkEcho)
        if session.category != .playAndRecord || session.categoryOptions != Self.talkOptions || session.mode != mode {
            try session.setCategory(.playAndRecord, mode: mode, options: Self.talkOptions)
        }
        try? session.setPreferredIOBufferDuration(Self.talkIOBufferDuration)
        // Asked for before the session goes active, and only on the built-in
        // microphone and speaker (where TalkEchoPolicy picks it); off
        // otherwise, so it never stays on under voice processing. Unsupported
        // hardware refuses, which changes nothing.
        try? session.setPrefersEchoCancelledInput(talkEcho == .echoCancelledInput)
        // The earcons and haptics play while the microphone records.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    private func configureRecording(options: AVAudioSession.CategoryOptions) throws {
        if session.category != .playAndRecord || session.categoryOptions != options || session.mode != .default {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        // The press and release haptics (mic button, Camera Control) would
        // otherwise be muted while the microphone records.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    func activate() throws {
        try session.setActive(true)
    }

    func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension AudioSessionOwner {
    /// The app's owner of `AVAudioSession.sharedInstance()`.
    static let shared: AudioSessionOwner = {
        let owner = AudioSessionOwner(driver: SystemAudioSession())
        let center = NotificationCenter.default
        // iOS deactivates the session when an interruption begins and after a
        // media services reset; the next use has to activate it again.
        _ = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                               queue: nil) { [weak owner] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            AudioSessionOwner.log.notice("Interruption began; the session is inactive")
            owner?.sessionWasDeactivated()
        }
        _ = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                               queue: nil) { [weak owner] _ in
            AudioSessionOwner.log.notice("Media services were reset; the session is inactive")
            owner?.sessionWasDeactivated()
        }
        return owner
    }()
}
