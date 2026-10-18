import Foundation
import MediaPlayer

/// Where a clip's bytes come from.
enum MediaSource: Equatable, Sendable {
    /// The capability URL, read with HTTP Range requests as the player needs
    /// them. `idleLimit`: how long the server keeps it without a request.
    case stream(URL, mintedAt: Date, idleLimit: TimeInterval)
    /// A downloaded copy (audio from a server that streams only video).
    case file(URL)

    var url: URL {
        switch self {
        case .stream(let url, _, _), .file(let url): return url
        }
    }

    var isStream: Bool {
        if case .stream = self { return true }
        return false
    }
}

/// What a player model needs from the server. ``MediaLibrary`` in the app.
@MainActor
protocol MediaSourceProviding: AnyObject {
    /// A source for the file: a fresh or still-valid stream, or a download.
    func source(for ref: MediaRef) async throws -> MediaSource
    /// A new stream, the old one having expired.
    func refreshedSource(for ref: MediaRef) async throws -> MediaSource
    /// Why `source` stopped playing, in words, when the server can say.
    func diagnose(_ source: MediaSource, ref: MediaRef) async -> MediaError?
}

/// One audio or video file's player: play, pause, scrub, and the position and
/// length to show. The inline audio player and the full-screen video player
/// both drive one.
///
/// - **Streaming.** A stream is the capability URL; AVFoundation reads it with
///   Range requests, so a seek fetches from the new offset.
/// - **Expired links.** Before playing a stream that sat unused for longer
///   than the server keeps it, a fresh one is minted and loaded at the same
///   position. A stream that still fails is minted again (twice at most)
///   and resumes where it was, as codeg web's video preview does.
/// - **One at a time.** Playing goes through ``MediaPlaybackCenter``: the
///   other clip pauses, read aloud stops, and the audio session is the
///   shared owner's.
@MainActor
@Observable
final class MediaPlayerModel: MediaPlaybackClient {
    enum Phase: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
        case failed(String)
    }

    let ref: MediaRef
    private(set) var phase: Phase = .idle
    private(set) var duration: TimeInterval?
    private(set) var position: TimeInterval = 0
    /// While the user drags the scrubber, the playhead doesn't move it.
    var isScrubbing = false

    @ObservationIgnored let engine: MediaPlaybackEngine
    @ObservationIgnored private let provider: MediaSourceProviding
    @ObservationIgnored private let center: MediaPlaybackCenter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private(set) var source: MediaSource?
    /// Last play, pause or seek: how long the stream has sat unused.
    @ObservationIgnored private var lastActivity: Date?
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var recoveries = 0
    /// A failure is being looked into; a second report of it is the same one.
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Asked again this long before the server's idle limit.
    static let refreshMargin: TimeInterval = 60
    static let maxRecoveries = 2

    init(ref: MediaRef, provider: MediaSourceProviding, engine: MediaPlaybackEngine,
         center: MediaPlaybackCenter, now: @escaping () -> Date = { Date() }) {
        self.ref = ref
        self.provider = provider
        self.engine = engine
        self.center = center
        self.now = now
        engine.onReady = { [weak self] duration in self?.ready(duration) }
        engine.onTime = { [weak self] time in self?.tick(time) }
        engine.onEnd = { [weak self] in self?.finished() }
        engine.onFailure = { [weak self] error in self?.recover(error) }
        engine.onPlayingChange = { [weak self] playing in self?.engineChanged(playing: playing) }
    }

    var isPlaying: Bool { phase == .playing }
    var isBusy: Bool { phase == .loading }
    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    // MARK: Controls

    func toggle() {
        switch phase {
        case .playing: pause()
        case .loading: break
        default: play()
        }
    }

    func play() {
        loadTask?.cancel()
        loadTask = Task { await start() }
    }

    /// Wait for the start to have happened (the tests).
    func playAndWait() async {
        play()
        await loadTask?.value
    }

    private func start() async {
        recovering = false
        if phase == .ended { position = 0 }
        if case .failed = phase { source = nil; recoveries = 0 }
        if let source, !needsFreshStream(source) {
            if phase == .ended { engine.seek(to: 0) }
            begin()
            return
        }
        let stale = source != nil
        phase = .loading
        playWhenReady = true
        do {
            let next = stale ? try await provider.refreshedSource(for: ref) : try await provider.source(for: ref)
            guard !Task.isCancelled else { return }
            source = next
            engine.load(next.url, at: position)
        } catch {
            guard !Task.isCancelled else { return }
            fail(MediaError.from(error))
        }
    }

    func pause() {
        playWhenReady = false
        engine.pause()
        if phase == .playing || phase == .loading { phase = .paused }
        lastActivity = now()
        center.paused(self)
        publishNowPlaying()
    }

    /// Move the playhead (scrubber, lock screen, the player's controls).
    func seek(to time: TimeInterval) {
        let upper = duration ?? max(time, 0)
        position = min(max(0, time), upper)
        engine.seek(to: position)
        lastActivity = now()
        if phase == .ended { phase = .paused }
        publishNowPlaying()
    }

    /// Stop and let go of the player and the audio session (the card left the
    /// screen, the full-screen player closed).
    func stop() {
        loadTask?.cancel()
        recovering = false
        playWhenReady = false
        position = phase == .ended ? 0 : engine.currentTime > 0 ? engine.currentTime : position
        engine.unload()
        source = nil
        if phase != .idle, failure == nil { phase = .idle }
        center.end(self)
    }

    // MARK: Engine events

    private func ready(_ duration: TimeInterval?) {
        recovering = false
        if let duration { self.duration = duration }
        if playWhenReady {
            playWhenReady = false
            begin()
        } else if phase == .loading {
            phase = .paused
        }
    }

    private func begin() {
        do {
            try center.begin(self)
        } catch {
            fail(.unplayable(AudioErrorText(error).message("Couldn't start audio")))
            return
        }
        engine.play()
        phase = .playing
        lastActivity = now()
        publishNowPlaying()
    }

    private func tick(_ time: TimeInterval) {
        guard !isScrubbing, phase != .loading else { return }
        if time > position + 0.5 { recoveries = 0 }
        position = time
        if phase == .playing { lastActivity = now() }
    }

    private func finished() {
        phase = .ended
        if let duration { position = duration }
        lastActivity = now()
        center.paused(self)
        publishNowPlaying()
    }

    /// The system player's own controls (or iOS) paused or resumed playback.
    private func engineChanged(playing: Bool) {
        if !playing, phase == .playing {
            phase = .paused
            lastActivity = now()
            center.paused(self)
            publishNowPlaying()
        } else if playing, phase == .paused {
            begin()
        }
    }

    /// The item failed. A stream is minted again and resumes where it was;
    /// otherwise, or after ``maxRecoveries``, the reason is shown.
    private func recover(_ error: Error?) {
        guard let failed = source, !recovering else { return }
        recovering = true
        let resumeAt = max(position, engine.currentTime)
        let wasPlaying = phase == .playing || playWhenReady
        loadTask?.cancel()
        loadTask = Task {
            let diagnosis = await provider.diagnose(failed, ref: ref)
            guard !Task.isCancelled else { return }
            if failed.isStream, recoveries < Self.maxRecoveries, diagnosis == nil || diagnosis == .expired {
                recoveries += 1
                phase = .loading
                playWhenReady = wasPlaying
                do {
                    let next = try await provider.refreshedSource(for: ref)
                    guard !Task.isCancelled else { return }
                    source = next
                    position = resumeAt
                    engine.load(next.url, at: resumeAt)
                } catch {
                    guard !Task.isCancelled else { return }
                    fail(MediaError.from(error))
                }
                return
            }
            fail(diagnosis ?? Self.playbackError(error, ref: ref))
        }
    }

    private func fail(_ error: MediaError) {
        recovering = false
        playWhenReady = false
        engine.unload()
        source = nil
        phase = .failed(error.errorDescription ?? "Couldn't play this file.")
        center.end(self)
    }

    /// An AVFoundation failure with nothing more from the server: the
    /// format, most likely.
    static func playbackError(_ error: Error?, ref: MediaRef) -> MediaError {
        if !ref.format.native {
            return .unplayable("\(ref.ext.uppercased()) files don't play on the iPhone.")
        }
        if let url = error as? URLError { return .network(url.localizedDescription) }
        let detail = (error as NSError?)?.localizedFailureReason ?? error?.localizedDescription
        return .unplayable("The iPhone couldn't play this file" + (detail.map { ": \($0)" } ?? "."))
    }

    /// Whether a stream sat unused past the server's idle limit.
    func needsFreshStream(_ source: MediaSource) -> Bool {
        guard case .stream(_, let mintedAt, let idleLimit) = source else { return false }
        let since = now().timeIntervalSince(lastActivity ?? mintedAt)
        return since > idleLimit - Self.refreshMargin
    }

    // MARK: MediaPlaybackClient

    func pauseForOtherAudio() {
        playWhenReady = false
        engine.pause()
        if phase == .playing || phase == .loading { phase = .paused }
        lastActivity = now()
    }

    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteTogglePlayPause() { toggle() }
    func remoteStop() { stop() }
    func remoteSeek(to seconds: TimeInterval) -> Bool {
        seek(to: seconds)
        return true
    }
    var supportsRemoteSeeking: Bool { true }

    // MARK: Now Playing

    private func publishNowPlaying() {
        guard center.active === self else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ref.name,
            MPMediaItemPropertyArtist: AppIdentity.displayName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: ref.kind == .video
                ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
