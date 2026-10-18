import MediaPlayer

extension Notification.Name {
    /// A clip from the session is about to set the audio session to
    /// `.playback`. Posted on the main thread, before the session changes.
    static let mediaPlaybackWillClaimAudio = Notification.Name("codeg.media.willClaimAudio")
    /// Clips stopped and let go of the audio session. Main thread.
    static let mediaPlaybackDidReleaseAudio = Notification.Name("codeg.media.didReleaseAudio")
}

/// A clip the center can pause when something else needs the audio.
@MainActor
protocol MediaPlaybackClient: RemoteControllable {
    /// Read aloud, dictation, another clip or a call took the audio: pause,
    /// keeping the position.
    func pauseForOtherAudio()
}

/// One clip plays at a time, through the app's one audio session.
///
/// A clip asks ``begin(_:)`` before it plays: the clip that was playing
/// pauses, read aloud stops, and the session is taken for `.media` through
/// ``AudioSessionOwner``, which read aloud and the microphone use too, so none
/// of them undoes another. Read aloud starting, or dictation taking the
/// session, pauses the clip. A clip left paused gives the session back after
/// ``idleRelease``, so other apps' audio can resume; playing it again takes it
/// back.
@MainActor
final class MediaPlaybackCenter {
    static let shared = MediaPlaybackCenter(owner: .shared, stopReadAloud: { ReadAloudPlayer.shared.stop() })

    private let owner: AudioSessionOwner
    private let stopReadAloud: @MainActor () -> Void
    private let idleRelease: Duration
    private var observers: [NSObjectProtocol] = []
    /// Posted ``Notification/Name/mediaPlaybackWillClaimAudio`` and not yet
    /// the matching release.
    private var claimed = false
    private var idleTask: Task<Void, Never>?

    /// The clip holding the session (playing, or paused a short while).
    private(set) weak var active: MediaPlaybackClient?

    init(owner: AudioSessionOwner, stopReadAloud: @escaping @MainActor () -> Void,
         idleRelease: Duration = .seconds(30)) {
        self.owner = owner
        self.stopReadAloud = stopReadAloud
        self.idleRelease = idleRelease
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .readAloudWillClaimAudio, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.yield() }
        })
        // Dictation (or the Camera Control's microphone) took the session.
        // Posted inside the owner's acquire, maybe off the main thread: the
        // clip pauses afterwards, without touching the session.
        observers.append(center.addObserver(forName: .audioSessionUseWillChange, object: nil, queue: nil) { [weak self] note in
            guard (note.object as AnyObject?) === owner,
                  note.userInfo?["from"] as? String == AudioSessionUse.media.rawValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.lostSession() }
            }
        })
    }

    /// `client` is about to play. Throws when the session can't be started.
    func begin(_ client: MediaPlaybackClient) throws {
        idleTask?.cancel()
        idleTask = nil
        if let current = active, current !== client { current.pauseForOtherAudio() }
        stopReadAloud()
        if !claimed {
            claimed = true
            // The Camera Control's standing-by microphone steps aside first.
            NotificationCenter.default.post(name: .mediaPlaybackWillClaimAudio, object: self)
        }
        do {
            try owner.acquire(.media)
        } catch {
            active = nil
            releaseClaim()
            throw error
        }
        active = client
        RemoteCommandRouter.shared.claim(client)
    }

    /// `client` paused. It keeps the session (and the lock-screen controls)
    /// for ``idleRelease``, then lets go.
    func paused(_ client: MediaPlaybackClient) {
        guard active === client else { return }
        idleTask?.cancel()
        let delay = idleRelease
        idleTask = Task { [weak self, weak client] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let client else { return }
            self.end(client)
        }
    }

    /// `client` stopped (its card went away, the player closed).
    func end(_ client: MediaPlaybackClient) {
        guard active === client else { return }
        idleTask?.cancel()
        idleTask = nil
        active = nil
        RemoteCommandRouter.shared.release(client)
        owner.release(.media)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        releaseClaim()
    }

    /// Read aloud is starting: the clip pauses and gives the session up.
    private func yield() {
        guard let client = active else { return }
        client.pauseForOtherAudio()
        end(client)
    }

    /// The session moved to another use already: pause, but leave the session alone.
    private func lostSession() {
        guard owner.activeUse != .media, let client = active else { return }
        idleTask?.cancel()
        idleTask = nil
        active = nil
        client.pauseForOtherAudio()
        RemoteCommandRouter.shared.release(client)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        releaseClaim()
    }

    private func releaseClaim() {
        guard claimed else { return }
        claimed = false
        NotificationCenter.default.post(name: .mediaPlaybackDidReleaseAudio, object: self)
    }
}
