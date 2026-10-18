import AVFoundation

/// What a clip's player model drives: `AVPlayer` in the app
/// (``AVPlayerEngine``), a scripted fake in the tests.
@MainActor
protocol MediaPlaybackEngine: AnyObject {
    /// The item is ready; its duration when known.
    var onReady: ((TimeInterval?) -> Void)? { get set }
    /// The playhead moved (about four times a second while playing).
    var onTime: ((TimeInterval) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    /// The item failed to load or to keep playing.
    var onFailure: ((Error?) -> Void)? { get set }
    /// Playing or paused, including a pause from iOS (an interruption,
    /// headphones unplugged) or from the system player controls.
    var onPlayingChange: ((Bool) -> Void)? { get set }

    /// Load `url`, positioned at `time`. Replaces whatever was loaded.
    func load(_ url: URL, at time: TimeInterval)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    var currentTime: TimeInterval { get }
    /// Drop the item and stop observing.
    func unload()
}

/// ``MediaPlaybackEngine`` over one `AVPlayer`. Streams over HTTP Range from
/// the capability URL: AVFoundation asks for the bytes it needs, so seeking
/// fetches from the new offset instead of the whole file.
@MainActor
final class AVPlayerEngine: MediaPlaybackEngine {
    let player = AVPlayer()

    var onReady: ((TimeInterval?) -> Void)?
    var onTime: ((TimeInterval) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((Error?) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    // Read by the non-isolated deinit.
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []
    private var pendingSeek: TimeInterval?
    private var reportedReady = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // Lock-screen controls and Now Playing are the app's (see
        // ``MediaPlaybackCenter``), so AVKit's player view doesn't publish them too.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.onPlayingChange?(playing) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.onTime?(time.seconds)
            }
        }
    }

    func load(_ url: URL, at time: TimeInterval) {
        clearItem()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // A modest forward buffer: AVPlayer keeps what it reads in memory only.
        item.preferredForwardBufferDuration = 30
        reportedReady = false
        pendingSeek = time > 0 ? time : nil
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            let duration = item.duration
            Task { @MainActor in self?.itemStatusChanged(status, error: error, duration: duration) }
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                     object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?() }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                     object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.onFailure?(error) }
        })
        player.replaceCurrentItem(with: item)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: Error?, duration: CMTime) {
        switch status {
        case .readyToPlay:
            guard !reportedReady else { return }
            reportedReady = true
            if let seek = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            onReady?(duration.isNumeric && duration.seconds > 0 ? duration.seconds : nil)
        case .failed:
            onFailure?(error)
        default:
            break
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        guard player.currentItem?.status == .readyToPlay else {
            pendingSeek = time
            return
        }
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var currentTime: TimeInterval {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : 0
    }

    func unload() {
        player.pause()
        clearItem()
        player.replaceCurrentItem(with: nil)
    }

    private func clearItem() {
        statusObservation = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }
}
