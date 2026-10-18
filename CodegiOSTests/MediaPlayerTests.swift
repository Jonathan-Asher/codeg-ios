import XCTest
@testable import Codeg

/// Records what the player model asks of AVPlayer; the tests play its events.
@MainActor
final class FakePlaybackEngine: MediaPlaybackEngine {
    var onReady: ((TimeInterval?) -> Void)?
    var onTime: ((TimeInterval) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((Error?) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?

    enum Call: Equatable {
        case load(URL, at: TimeInterval)
        case play
        case pause
        case seek(TimeInterval)
        case unload
    }

    private(set) var calls: [Call] = []
    var currentTime: TimeInterval = 0

    var loads: [Call] { calls.filter { if case .load = $0 { return true } else { return false } } }

    func load(_ url: URL, at time: TimeInterval) { calls.append(.load(url, at: time)); currentTime = time }
    func play() { calls.append(.play) }
    func pause() { calls.append(.pause) }
    func seek(to time: TimeInterval) { calls.append(.seek(time)); currentTime = time }
    func unload() { calls.append(.unload) }
}

/// Hands out streams (or a downloaded file) and counts the asks.
@MainActor
final class FakeMediaProvider: MediaSourceProviding {
    var sources = 0
    var refreshes = 0
    var mintedAt: () -> Date = { Date() }
    var idleLimit: TimeInterval = 900
    var local = false
    var sourceError: Error?
    var diagnosis: MediaError?

    func source(for ref: MediaRef) async throws -> MediaSource {
        sources += 1
        if let sourceError { throw sourceError }
        if local { return .file(URL(fileURLWithPath: "/tmp/\(ref.name)")) }
        return .stream(URL(string: "http://box.test/api/workspace_media/s\(sources)/\(ref.name)")!,
                       mintedAt: mintedAt(), idleLimit: idleLimit)
    }

    func refreshedSource(for ref: MediaRef) async throws -> MediaSource {
        refreshes += 1
        return .stream(URL(string: "http://box.test/api/workspace_media/r\(refreshes)/\(ref.name)")!,
                       mintedAt: mintedAt(), idleLimit: idleLimit)
    }

    func diagnose(_ source: MediaSource, ref: MediaRef) async -> MediaError? { diagnosis }
}

/// The inline audio player and the video player's model: one clip at a time
/// through the shared audio session, streams refreshed when they lapse, and
/// failures in words.
@MainActor
final class MediaPlayerTests: XCTestCase {
    private var session: FakeAudioSession!
    private var owner: AudioSessionOwner!
    private var center: MediaPlaybackCenter!
    private var readAloudStops = 0
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        session = FakeAudioSession()
        owner = AudioSessionOwner(driver: session, retryDelay: 0) { _ in }
        readAloudStops = 0
        center = MediaPlaybackCenter(owner: owner, stopReadAloud: { [unowned self] in self.readAloudStops += 1 },
                                     idleRelease: .milliseconds(80))
    }

    private func ref(_ name: String) -> MediaRef {
        MediaRef(path: "/w/out/\(name)", format: MediaFormats.format(forPath: name)!, origin: .link, scope: "t")
    }

    private func model(_ name: String = "tone.m4a", provider: FakeMediaProvider, engine: FakePlaybackEngine) -> MediaPlayerModel {
        MediaPlayerModel(ref: ref(name), provider: provider, engine: engine, center: center, now: { [unowned self] in self.now })
    }

    /// Play, and let the engine say the item is ready.
    private func start(_ model: MediaPlayerModel, _ engine: FakePlaybackEngine, duration: TimeInterval? = 30) async {
        await model.playAndWait()
        engine.onReady?(duration)
    }

    func testPlayStreamsFromTheStartAndTakesTheAudio() async {
        let provider = FakeMediaProvider()
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await player.playAndWait()
        XCTAssertEqual(player.phase, .loading)
        XCTAssertEqual(engine.calls, [.load(URL(string: "http://box.test/api/workspace_media/s1/tone.m4a")!, at: 0)])

        engine.onReady?(42)
        XCTAssertEqual(player.phase, .playing)
        XCTAssertEqual(player.duration, 42)
        XCTAssertEqual(engine.calls.last, .play)
        XCTAssertEqual(session.calls, [.configure(.media), .activate])
        XCTAssertEqual(owner.activeUse, .media)
        XCTAssertEqual(readAloudStops, 1, "read aloud stops")
        XCTAssertTrue(center.active === player)
        XCTAssertTrue(RemoteCommandRouter.shared.current === player, "the lock screen controls it")
        player.stop()
    }

    func testAnotherClipPausesThisOne() async {
        let provider = FakeMediaProvider()
        let firstEngine = FakePlaybackEngine(), secondEngine = FakePlaybackEngine()
        let first = model("a.m4a", provider: provider, engine: firstEngine)
        let second = model("b.mp3", provider: provider, engine: secondEngine)
        await start(first, firstEngine)
        await start(second, secondEngine)
        XCTAssertEqual(first.phase, .paused)
        XCTAssertEqual(firstEngine.calls.last, .pause)
        XCTAssertEqual(second.phase, .playing)
        XCTAssertTrue(center.active === second)
        XCTAssertEqual(session.calls.filter { $0 == .activate }.count, 1, "the session stays up between them")
        second.stop()
        XCTAssertNil(owner.activeUse)
    }

    func testAPausedClipGivesTheSessionBackAfterAWhile() async throws {
        let provider = FakeMediaProvider()
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await start(player, engine)
        player.pause()
        XCTAssertEqual(player.phase, .paused)
        XCTAssertEqual(owner.activeUse, .media, "kept for a quick resume")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(owner.activeUse)
        XCTAssertNil(center.active)
        XCTAssertEqual(session.calls.last, .deactivate)

        await player.playAndWait()
        XCTAssertEqual(player.phase, .playing, "a fresh stream needs no reload")
        XCTAssertEqual(owner.activeUse, .media)
        XCTAssertEqual(engine.loads.count, 1)
        player.stop()
    }

    func testAnExpiredStreamIsMintedAgainAndResumesWhereItWas() async throws {
        let provider = FakeMediaProvider()
        provider.diagnosis = .expired
        let engine = FakePlaybackEngine()
        let player = model("demo.mp4", provider: provider, engine: engine)
        await start(player, engine, duration: 120)
        engine.onTime?(37.5)
        XCTAssertEqual(player.position, 37.5)

        engine.onFailure?(URLError(.fileDoesNotExist))
        engine.onFailure?(URLError(.fileDoesNotExist))  // AVFoundation reports it twice
        for _ in 0..<20 where engine.loads.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(provider.refreshes, 1)
        XCTAssertEqual(engine.loads.last, .load(URL(string: "http://box.test/api/workspace_media/r1/demo.mp4")!, at: 37.5))
        XCTAssertEqual(player.phase, .loading)
        engine.onReady?(120)
        XCTAssertEqual(player.phase, .playing, "it plays on")
        player.stop()
    }

    func testAStreamUnusedPastTheServersLimitIsRefreshedBeforeResuming() async {
        let provider = FakeMediaProvider()
        provider.mintedAt = { [unowned self] in self.now }
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await start(player, engine)
        engine.onTime?(12)
        player.pause()
        now += 14 * 60 + 30  // past 15 minutes less the one-minute margin
        await player.playAndWait()
        XCTAssertEqual(provider.refreshes, 1)
        XCTAssertEqual(engine.loads.last, .load(URL(string: "http://box.test/api/workspace_media/r1/tone.m4a")!, at: 12))
        engine.onReady?(30)
        XCTAssertEqual(player.phase, .playing)
        player.stop()
    }

    func testAFileThatWontPlaySaysWhyWithoutRetrying() async throws {
        let provider = FakeMediaProvider()
        provider.diagnosis = .unplayable("WEBM (Matroska) files don't play on the iPhone.")
        let engine = FakePlaybackEngine()
        let player = model("a.webm", provider: provider, engine: engine)
        await start(player, engine)
        engine.onFailure?(nil)
        for _ in 0..<20 where player.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(player.failure, "WEBM (Matroska) files don't play on the iPhone.")
        XCTAssertEqual(provider.refreshes, 0)
        XCTAssertNil(owner.activeUse, "the session is given back")
    }

    func testAMissingFileFailsInWords() async {
        let provider = FakeMediaProvider()
        provider.sourceError = MediaError.missing
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await player.playAndWait()
        XCTAssertEqual(player.failure, MediaError.missing.errorDescription)
        XCTAssertTrue(engine.loads.isEmpty)
        XCTAssertNil(owner.activeUse)
    }

    func testADownloadedFileThatFailsIsNotRefreshed() async throws {
        let provider = FakeMediaProvider()
        provider.local = true
        let engine = FakePlaybackEngine()
        let player = model("a.ogg", provider: provider, engine: engine)
        await start(player, engine)
        engine.onFailure?(nil)
        for _ in 0..<20 where player.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(player.failure, "OGG files don't play on the iPhone.")
        XCTAssertEqual(provider.refreshes, 0)
    }

    func testReadAloudOrDictationPausesTheClip() async throws {
        let provider = FakeMediaProvider()
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await start(player, engine)

        NotificationCenter.default.post(name: .readAloudWillClaimAudio, object: nil)
        XCTAssertEqual(player.phase, .paused)
        XCTAssertNil(center.active)
        XCTAssertNil(owner.activeUse)

        await player.playAndWait()
        XCTAssertEqual(player.phase, .playing)
        // Dictation takes the session for the microphone.
        try owner.acquire(.recording)
        for _ in 0..<20 where player.phase == .playing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(player.phase, .paused)
        XCTAssertNil(center.active)
        XCTAssertEqual(owner.activeUse, .recording, "the microphone keeps the session")
        owner.release(.recording)
        // Leave the app's microphone standby as it was.
        NotificationCenter.default.post(name: .readAloudDidReleaseAudio, object: nil)
    }

    func testTheStandingByMicrophoneHearsMediaClaimTheAudio() async {
        final class Heard: @unchecked Sendable { var names: [Notification.Name] = [] }
        let heard = Heard()
        let names: [Notification.Name] = [.mediaPlaybackWillClaimAudio, .mediaPlaybackDidReleaseAudio]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: center, queue: nil) { note in
                heard.names.append(note.name)
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        let provider = FakeMediaProvider()
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await start(player, engine)
        player.stop()
        XCTAssertEqual(heard.names, names)
    }

    func testScrubbingAndTheEnd() async {
        let provider = FakeMediaProvider()
        let engine = FakePlaybackEngine()
        let player = model(provider: provider, engine: engine)
        await start(player, engine, duration: 60)
        player.isScrubbing = true
        engine.onTime?(5)
        XCTAssertEqual(player.position, 0, "the playhead doesn't fight the finger")
        player.isScrubbing = false
        player.seek(to: 45)
        XCTAssertEqual(engine.calls.last, .seek(45))
        XCTAssertEqual(player.position, 45)
        player.seek(to: 600)
        XCTAssertEqual(player.position, 60, "clamped to the length")

        engine.onEnd?()
        XCTAssertEqual(player.phase, .ended)
        await player.playAndWait()
        XCTAssertEqual(player.phase, .playing)
        XCTAssertTrue(engine.calls.contains(.seek(0)), "playing again starts over")
        player.stop()
    }

    func testTheSystemPlayersOwnPauseIsFollowed() async {
        let provider = FakeMediaProvider()
        let engine = FakePlaybackEngine()
        let player = model("demo.mp4", provider: provider, engine: engine)
        await start(player, engine)
        engine.onPlayingChange?(false)
        XCTAssertEqual(player.phase, .paused)
        engine.onPlayingChange?(true)
        XCTAssertEqual(player.phase, .playing)
        player.stop()
    }

    func testTheOwnerSaysWhenTheSessionMovesToAnotherUse() throws {
        final class Heard: @unchecked Sendable { var changes: [[String]] = [] }
        let heard = Heard()
        let token = NotificationCenter.default.addObserver(forName: .audioSessionUseWillChange, object: owner,
                                                           queue: nil) { note in
            heard.changes.append([note.userInfo?["from"] as? String ?? "", note.userInfo?["to"] as? String ?? ""])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try owner.acquire(.media)
        try owner.acquire(.media)
        try owner.acquire(.readAloud)
        owner.release(.readAloud)
        try owner.acquire(.recording)
        owner.release(.recording)
        XCTAssertEqual(heard.changes, [["media", "readAloud"]], "only a held session moving on is announced")
        XCTAssertEqual(session.calls.prefix(2), [.configure(.media), .activate])
    }

    func testDurationText() {
        XCTAssertEqual(DurationText.clock(0), "0:00")
        XCTAssertEqual(DurationText.clock(75.9), "1:15")
        XCTAssertEqual(DurationText.clock(3725), "1:02:05")
        XCTAssertEqual(DurationText.clock(.nan), "--:--")
    }
}
