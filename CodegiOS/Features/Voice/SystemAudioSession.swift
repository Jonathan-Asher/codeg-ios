import AVFoundation

/// `AVAudioSession` behind ``AudioSessionDriver``: the category, mode and
/// options for each ``AudioSessionUse``.
final class SystemAudioSession: AudioSessionDriver {
    /// A recording without standby: AirPods (HFP) work as the microphone.
    static let recordingOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
    /// Standby: the iPhone's microphone, AirPods stay in A2DP, other apps'
    /// audio keeps playing.
    static let standbyOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]

    private var session: AVAudioSession { .sharedInstance() }

    func configure(for use: AudioSessionUse) throws {
        switch use {
        case .standby:
            try configureRecording(options: Self.standbyOptions)
        case .recording:
            try configureRecording(options: Self.recordingOptions)
        case .readAloud:
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
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
