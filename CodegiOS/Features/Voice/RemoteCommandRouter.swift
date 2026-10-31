import MediaPlayer

/// Something the lock screen, Control Center and the AirPods can play and
/// pause: read aloud, or a clip from the session.
@MainActor
protocol RemoteControllable: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteTogglePlayPause()
    func remoteStop()
    /// Seek to `seconds`; false when it can't seek (read aloud).
    func remoteSeek(to seconds: TimeInterval) -> Bool
    var supportsRemoteSeeking: Bool { get }
    /// Next and previous track (an AirPods double and triple press). Talk
    /// stops the speech and says the last reply again; the others don't
    /// take them.
    func remoteNextTrack()
    func remotePreviousTrack()
    var supportsTrackCommands: Bool { get }
}

extension RemoteControllable {
    func remoteNextTrack() {}
    func remotePreviousTrack() {}
    var supportsTrackCommands: Bool { false }
}

/// The one set of `MPRemoteCommandCenter` targets, routed to whoever plays
/// now. Read aloud and media each claim it when they start, so a press on the
/// lock screen reaches exactly one of them (two targets that both toggled would
/// cancel each other out).
@MainActor
final class RemoteCommandRouter {
    static let shared = RemoteCommandRouter()

    private(set) weak var current: RemoteControllable?
    private var installed = false

    private init() {}

    /// `controllable` gets the remote commands from now on.
    func claim(_ controllable: RemoteControllable) {
        install()
        current = controllable
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = controllable.supportsRemoteSeeking
        center.nextTrackCommand.isEnabled = controllable.supportsTrackCommands
        center.previousTrackCommand.isEnabled = controllable.supportsTrackCommands
    }

    /// `controllable` is done; the commands go nowhere until the next claim.
    func release(_ controllable: RemoteControllable) {
        guard current === controllable else { return }
        current = nil
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Self.route { $0.remotePlay() }
        }
        center.pauseCommand.addTarget { _ in
            Self.route { $0.remotePause() }
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Self.route { $0.remoteTogglePlayPause() }
        }
        center.stopCommand.addTarget { _ in
            Self.route { $0.remoteStop() }
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return Self.route { _ = $0.remoteSeek(to: position) }
        }
        center.changePlaybackPositionCommand.isEnabled = false
        center.nextTrackCommand.addTarget { _ in
            Self.route { $0.remoteNextTrack() }
        }
        center.previousTrackCommand.addTarget { _ in
            Self.route { $0.remotePreviousTrack() }
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// Remote command handlers come on the main thread; should one ever not,
    /// it is handed to the main thread and counted as handled.
    nonisolated private static func route(
        _ action: @escaping @MainActor (RemoteControllable) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let current = RemoteCommandRouter.shared.current { action(current) }
                }
            }
            return .success
        }
        return MainActor.assumeIsolated {
            guard let current = RemoteCommandRouter.shared.current else { return .noActionableNowPlayingItem }
            action(current)
            return .success
        }
    }
}
