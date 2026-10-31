import BlueTTSKit
import UIKit
import XCTest
@testable import Codeg

// MARK: - Fakes

/// Counts what is asked of it; `holdLoads` keeps `prepare()` waiting until
/// `finishLoads()`.
private final class FakeWhisper: SpeechToText, @unchecked Sendable {
    let modelID: String
    private let lock = NSLock()
    private var counts = (prepares: 0, unloads: 0, cancels: 0, decodes: 0)
    private var held: [CheckedContinuation<Void, Never>] = []
    var holdLoads = false

    init(modelID: String) { self.modelID = modelID }

    var prepares: Int { lock.withLock { counts.prepares } }
    var unloads: Int { lock.withLock { counts.unloads } }
    var cancels: Int { lock.withLock { counts.cancels } }
    var decodes: Int { lock.withLock { counts.decodes } }

    func prepare() async throws {
        lock.withLock { counts.prepares += 1 }
        if holdLoads {
            await withCheckedContinuation { continuation in
                lock.withLock { held.append(continuation) }
            }
        }
    }

    func finishLoads() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let current = held
            held = []
            return current
        }
        waiting.forEach { $0.resume() }
    }

    var waitingLoads: Int { lock.withLock { held.count } }

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcription {
        lock.withLock { counts.decodes += 1 }
        return Transcription(text: "שלום", language: options.language, seconds: 0)
    }

    func cancel() { lock.withLock { counts.cancels += 1 } }

    func unload() async { lock.withLock { counts.unloads += 1 } }
}

private final class FakeLanguageID: SpokenLanguageIdentifier, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (prepares: 0, unloads: 0)
    var prepares: Int { lock.withLock { counts.prepares } }
    var unloads: Int { lock.withLock { counts.unloads } }
    func prepare() async throws { lock.withLock { counts.prepares += 1 } }
    func probabilities(_ samples: [Float], among candidates: [String]) async throws -> [String: Float] { ["he": 1] }
    func unload() async { lock.withLock { counts.unloads += 1 } }
}

private final class FakeVAD: VoiceActivityDetector, @unchecked Sendable {
    func speechProbabilities(_ samples: [Float]) -> [Float]? { [] }
}

private final class FakeStreamingVAD: StreamingVoiceActivityDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var resetCount = 0
    var resets: Int { lock.withLock { resetCount } }
    func probabilities(_ samples: [Float]) -> [Float]? {
        Array(repeating: 0.9, count: max(1, (samples.count + 511) / 512))
    }
    func reset() { lock.withLock { resetCount += 1 } }
}

private final class FakeEngineFactory: SpeechEngineFactory {
    private(set) var whispers: [FakeWhisper] = []
    private(set) var languageIDs: [FakeLanguageID] = []
    private(set) var vads = 0
    private(set) var streamingVADs: [FakeStreamingVAD] = []
    var holdLoads = false

    func makeWhisper(modelID: String, url: URL) -> SpeechToText {
        let whisper = FakeWhisper(modelID: modelID)
        whisper.holdLoads = holdLoads
        whispers.append(whisper)
        return whisper
    }

    func makeLanguageID(url: URL) -> SpokenLanguageIdentifier {
        let model = FakeLanguageID()
        languageIDs.append(model)
        return model
    }

    func makeVAD(url: URL) -> VoiceActivityDetector? {
        vads += 1
        return FakeVAD()
    }

    func makeStreamingVAD(url: URL) -> StreamingVoiceActivityDetector? {
        let vad = FakeStreamingVAD()
        streamingVADs.append(vad)
        return vad
    }
}

@MainActor
private final class FakeAttachment: SpeechEngineAttachment {
    let runsInBackground: Bool
    private(set) var unloads = 0
    init(runsInBackground: Bool) { self.runsInBackground = runsInBackground }
    func unload() { unloads += 1 }
}

// MARK: - The speech engines

/// Voice typing, Talk and the Lab share one set of speech engines: made once,
/// kept while a lease holds them, unloaded after the idle time, on a memory
/// warning when nothing holds them, and in the background except what Talk
/// can still run there.
@MainActor
final class SpeechEngineHostTests: XCTestCase {
    private var center: NotificationCenter!
    private var factory: FakeEngineFactory!
    private var host: SpeechEngineHost!

    private let model = SpeechEngineConfiguration(
        whisperModelID: "he-turbo",
        whisperURL: URL(fileURLWithPath: "/models/ggml-ivrit.bin"),
        vadURL: URL(fileURLWithPath: "/models/silero.bin"),
        languageIDURL: URL(fileURLWithPath: "/models/ggml-tiny.bin"))

    override func setUp() async throws {
        center = NotificationCenter()
        factory = FakeEngineFactory()
        host = SpeechEngineHost(factory: factory, idleUnload: .milliseconds(80), notificationCenter: center)
    }

    private var whisper: FakeWhisper { factory.whispers[0] }

    func testEachEngineIsMadeOnceAndLoadsWhileTheUserSpeaks() async {
        host.acquire(.dictation)
        host.use(model)
        host.use(model)
        XCTAssertEqual(factory.whispers.count, 1, "the same files: nothing loads twice")
        XCTAssertEqual(factory.vads, 1)
        XCTAssertEqual(factory.languageIDs.count, 1)
        XCTAssertFalse(host.isWhisperLoaded)

        host.preload(languageID: true)
        let loaded = await eventually { self.host.isWhisperLoaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(whisper.prepares, 1)
        XCTAssertEqual(factory.languageIDs[0].prepares, 1)
        XCTAssertEqual(host.whisper?.modelID, "he-turbo")
    }

    func testTheEnginesStayWhileAnyLeaseHoldsThemThenGoAfterTheIdleTime() async throws {
        host.acquire(.dictation)
        host.acquire(.talk)
        host.use(model)
        host.release(.dictation)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(host.whisper, "Talk still holds them")
        XCTAssertEqual(host.leases, [.talk])

        host.release(.talk)
        let gone = await eventually { self.host.whisper == nil }
        XCTAssertTrue(gone)
        XCTAssertNil(host.vad)
        XCTAssertNil(host.languageID)
        XCTAssertNil(host.configuration)
        let unloaded = await eventually { self.whisper.unloads == 1 && self.factory.languageIDs[0].unloads == 1 }
        XCTAssertTrue(unloaded)
    }

    func testTakingALeaseAgainKeepsThemLoaded() async throws {
        host.acquire(.dictation)
        host.use(model)
        host.release(.dictation)
        host.acquire(.lab)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(host.whisper)
        XCTAssertEqual(whisper.unloads, 0)
    }

    func testAMemoryWarningUnloadsOnlyWhenNothingHoldsThem() async throws {
        host.acquire(.talk)
        host.use(model)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(host.whisper, "Talk holds them: it decides what a warning drops")

        let slow = SpeechEngineHost(factory: factory, idleUnload: .seconds(60), notificationCenter: center)
        slow.use(model)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let dropped = await eventually { slow.whisper == nil }
        XCTAssertTrue(dropped, "nothing holds this one")
        XCTAssertNotNil(host.whisper)
    }

    func testInTheBackgroundTalkKeepsTheDetectorsWhileWhisperIsFreed() async {
        host.acquire(.talk)
        host.use(model)
        host.preload(languageID: false)
        _ = await eventually { self.host.isWhisperLoaded }
        let streaming = host.streamingVAD()
        XCTAssertNotNil(streaming)
        let gpu = FakeAttachment(runsInBackground: false)
        let cpu = FakeAttachment(runsInBackground: true)
        host.attach(gpu, as: "gpu")
        host.attach(cpu, as: "cpu")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let freed = await eventually { !self.host.isWhisperLoaded && self.whisper.unloads == 1 }
        XCTAssertTrue(freed)
        XCTAssertNotNil(host.whisper, "still usable: the next decode loads it again")
        XCTAssertNotNil(host.vad)
        XCTAssertTrue(host.streamingVAD() === streaming)
        XCTAssertEqual(factory.streamingVADs.count, 1)
        XCTAssertEqual(gpu.unloads, 1)
        XCTAssertEqual(cpu.unloads, 0)
        XCTAssertTrue(host.attachment("cpu") === cpu)
    }

    func testInTheBackgroundADictationKeepsEverything() async throws {
        host.acquire(.dictation)
        host.acquire(.talk)
        host.use(model)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(whisper.unloads, 0, "its decode waits for the app to come back")
        XCTAssertNotNil(host.whisper)
    }

    func testInTheBackgroundWithNothingHeldEverythingGoes() async {
        host.use(model)
        let attached = FakeAttachment(runsInBackground: true)
        host.attach(attached, as: "zipformer")
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let gone = await eventually { self.host.whisper == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(attached.unloads, 1)
        XCTAssertNil(host.attachment("zipformer"))
    }

    func testAnotherModelReplacesWhisperAndUnloadsTheOldOne() async {
        host.acquire(.dictation)
        host.use(model)
        var multilingual = model
        multilingual.whisperModelID = "multi-turbo"
        multilingual.whisperURL = URL(fileURLWithPath: "/models/ggml-turbo.bin")
        multilingual.languageIDURL = nil
        host.use(multilingual)
        XCTAssertEqual(factory.whispers.count, 2)
        XCTAssertEqual(factory.vads, 1, "the same VAD stays")
        XCTAssertNil(host.languageID)
        XCTAssertEqual(host.whisper?.modelID, "multi-turbo")
        let unloaded = await eventually { self.factory.whispers[0].unloads == 1 }
        XCTAssertTrue(unloaded)
    }

    func testUnloadWhisperFreesTheWeightsButKeepsTheEngine() async throws {
        host.acquire(.talk)
        host.use(model)
        try await host.prepareWhisper()
        _ = await eventually { self.host.isWhisperLoaded }
        XCTAssertTrue(host.isWhisperLoaded)
        host.unloadWhisper()
        XCTAssertFalse(host.isWhisperLoaded)
        let unloaded = await eventually { self.whisper.unloads == 1 }
        XCTAssertTrue(unloaded)
        // A decode loads it again, and then it counts as loaded.
        _ = try await host.whisper?.transcribe([0], options: TranscriptionOptions(language: "he"))
        let reloaded = await eventually { self.host.isWhisperLoaded }
        XCTAssertTrue(reloaded)
        XCTAssertNotNil(host.vad)
    }

    func testALoadThatFinishesAfterAnUnloadDoesntCountAsLoaded() async {
        factory.holdLoads = true
        host.acquire(.talk)
        host.use(model)
        host.preload(languageID: false)
        _ = await eventually { self.whisper.waitingLoads == 1 }
        host.unloadWhisper()
        whisper.finishLoads()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(host.isWhisperLoaded)
    }

    func testTheStreamingDetectorIsMadeOnFirstUseOnly() {
        XCTAssertNil(host.streamingVAD(), "no model yet")
        host.use(model)
        let first = host.streamingVAD()
        XCTAssertTrue(first === host.streamingVAD())
        XCTAssertEqual(factory.streamingVADs.count, 1)
        XCTAssertEqual(first?.probability(of: Array(repeating: 0, count: 512)), 0.9)
    }
}

// MARK: - The voice

private final class FakeVoice: HostedVoice, @unchecked Sendable {
    let threads: Int
    private let lock = NSLock()
    private var counts = (loads: 0, streams: 0)
    var loads: Int { lock.withLock { counts.loads } }
    var streams: Int { lock.withLock { counts.streams } }

    init(threads: Int) { self.threads = threads }

    func load() async throws { lock.withLock { counts.loads += 1 } }

    func synthesizeStream(_ text: String, options: SynthesisOptions,
                          firstChunkMaxChars: Int) -> AsyncThrowingStream<AudioChunk, Error> {
        lock.withLock { counts.streams += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

/// Read aloud and Talk share one BlueTTS: made on first use, kept while held,
/// dropped after the idle time or on a memory warning when nothing holds it,
/// and Talk's thread cap.
@MainActor
final class VoiceEngineHostTests: XCTestCase {
    private var center: NotificationCenter!
    private var made: [FakeVoice] = []

    override func setUp() async throws {
        center = NotificationCenter()
        made = []
    }

    private func makeHost() -> VoiceEngineHost {
        VoiceEngineHost(makeVoice: { [unowned self] threads in
            let voice = FakeVoice(threads: threads)
            self.made.append(voice)
            return voice
        }, defaultThreads: 6, idleUnload: .milliseconds(80), notificationCenter: center)
    }

    func testOneVoiceIsSharedAndDroppedAfterTheIdleTime() async throws {
        let host = makeHost()
        host.acquire(.readAloud)
        _ = try host.synthesizeStream("שלום", options: SynthesisOptions())
        host.acquire(.talk)
        _ = try host.synthesizeStream("hello", options: SynthesisOptions(), firstChunkMaxChars: 40)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].streams, 2)
        XCTAssertEqual(made[0].threads, 6)
        XCTAssertTrue(host.isLoaded)

        host.release(.readAloud)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(host.isLoaded, "Talk still holds it")
        host.release(.talk)
        let dropped = await eventually { !host.isLoaded }
        XCTAssertTrue(dropped)
        _ = try host.synthesizeStream("again", options: SynthesisOptions())
        XCTAssertEqual(made.count, 2, "made again on the next use")
    }

    func testTalksThreadCapDropsAVoiceWithMoreThreads() async throws {
        let host = makeHost()
        host.acquire(.talk)
        try await host.preload()
        XCTAssertEqual(made[0].loads, 1)
        host.setThreadCap(4)
        XCTAssertFalse(host.isLoaded, "the 6-thread voice goes")
        XCTAssertEqual(host.threads, 4)
        _ = try host.synthesizeStream("שלום", options: SynthesisOptions())
        XCTAssertEqual(made.last?.threads, 4)

        // Lifting the cap keeps the smaller voice rather than loading again.
        host.setThreadCap(nil)
        XCTAssertTrue(host.isLoaded)
        XCTAssertEqual(host.threads, 6)
        host.setThreadCap(8)
        XCTAssertEqual(host.threads, 6, "never more than the default")
        XCTAssertEqual(made.count, 2)
    }

    func testAMemoryWarningDropsItOnlyWhenNothingHoldsIt() async throws {
        let host = makeHost()
        host.acquire(.readAloud)
        _ = try host.loadedVoice()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(host.isLoaded)

        let idle = VoiceEngineHost(makeVoice: { threads in FakeVoice(threads: threads) }, defaultThreads: 6,
                                   idleUnload: .seconds(60), notificationCenter: center)
        _ = try idle.loadedVoice()
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let dropped = await eventually { !idle.isLoaded }
        XCTAssertTrue(dropped)
        XCTAssertTrue(host.isLoaded)
    }
}
