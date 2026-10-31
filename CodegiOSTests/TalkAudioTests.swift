import AVFoundation
import XCTest
@testable import Codeg

/// Records what the owner asks of the audio session, Talk's echo setting
/// included.
private final class FakeTalkAudioSession: AudioSessionDriver {
    enum Call: Equatable {
        case configure(AudioSessionUse, TalkEchoMode?)
        case activate
        case deactivate
    }

    private(set) var calls: [Call] = []
    private var echo: TalkEchoMode?
    var activationErrors: [Error] = []

    func configure(for use: AudioSessionUse) throws {
        calls.append(.configure(use, use == .talk ? echo : nil))
    }

    func activate() throws {
        calls.append(.activate)
        if !activationErrors.isEmpty { throw activationErrors.removeFirst() }
    }

    func deactivate() throws {
        calls.append(.deactivate)
    }

    func prepareTalk(echo: TalkEchoMode) {
        self.echo = echo
    }
}

/// Talk's session use: configured for its echo setting, reconfigured in place
/// (never deactivated) when the route asks for another one, and released
/// only by Talk.
final class TalkAudioSessionTests: XCTestCase {
    private var session: FakeTalkAudioSession!
    private var owner: AudioSessionOwner!

    override func setUp() {
        session = FakeTalkAudioSession()
        owner = AudioSessionOwner(driver: session, retryDelay: 0) { _ in }
    }

    func testTalkConfiguresTheSessionForItsEchoSettingAndActivatesOnce() throws {
        var started = 0
        XCTAssertEqual(try owner.acquireTalk(echo: .echoCancelledInput) { started += 1 }, .activated)
        XCTAssertEqual(owner.activeUse, .talk)
        XCTAssertEqual(owner.activeTalkEcho, .echoCancelledInput)
        XCTAssertEqual(try owner.acquireTalk(echo: .echoCancelledInput) { started += 1 }, .alreadyActive)
        XCTAssertEqual(session.calls, [.configure(.talk, .echoCancelledInput), .activate])
        XCTAssertEqual(started, 2)
    }

    func testAnotherEchoSettingIsConfiguredInPlaceWithoutDeactivating() throws {
        try owner.acquireTalk(echo: .echoCancelledInput)
        // AirPods come in: no echo control, the session stays active.
        XCTAssertEqual(try owner.acquireTalk(echo: .none), .alreadyActive)
        try owner.acquireTalk(echo: .voiceProcessing)
        XCTAssertEqual(session.calls, [
            .configure(.talk, .echoCancelledInput), .activate,
            .configure(.talk, TalkEchoMode.none),
            .configure(.talk, .voiceProcessing),
        ])
        XCTAssertFalse(session.calls.contains(.deactivate))
        XCTAssertEqual(owner.activeTalkEcho, .voiceProcessing)
    }

    func testOnlyTalkReleasesItsSession() throws {
        try owner.acquireTalk(echo: .voiceProcessing)
        owner.release(.recording)
        owner.release(.readAloud)
        XCTAssertEqual(owner.activeUse, .talk)
        owner.release(.talk)
        XCTAssertNil(owner.activeUse)
        XCTAssertNil(owner.activeTalkEcho)
        XCTAssertEqual(session.calls.last, .deactivate)
    }

    func testAFailedStartIsRetriedOnceAfterACleanDeactivate() throws {
        session.activationErrors = [NSError(domain: NSOSStatusErrorDomain, code: 561_017_449)]
        XCTAssertEqual(try owner.acquireTalk(echo: .voiceProcessing), .activatedOnRetry)
        XCTAssertEqual(session.calls, [
            .configure(.talk, .voiceProcessing), .activate, .deactivate,
            .configure(.talk, .voiceProcessing), .activate,
        ])
    }

    func testAnotherUseTakingTheSessionIsAnnouncedFromTalk() throws {
        final class Heard: @unchecked Sendable { var changes: [[String]] = [] }
        let heard = Heard()
        let token = NotificationCenter.default.addObserver(forName: .audioSessionUseWillChange, object: owner,
                                                           queue: nil) { note in
            heard.changes.append([note.userInfo?["from"] as? String ?? "", note.userInfo?["to"] as? String ?? ""])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try owner.acquireTalk(echo: .echoCancelledInput)
        try owner.acquire(.recording)
        XCTAssertEqual(heard.changes, [["talk", "recording"]])
        XCTAssertNil(owner.activeTalkEcho, "Talk no longer holds the session")
    }
}

final class TalkEchoPolicyTests: XCTestCase {
    func testEachRouteGetsItsEchoMode() {
        XCTAssertEqual(TalkEchoPolicy.choose(route: .builtIn, echoCancelledInputAvailable: true), .echoCancelledInput)
        XCTAssertEqual(TalkEchoPolicy.choose(route: .builtIn, echoCancelledInputAvailable: false), .voiceProcessing)
        XCTAssertEqual(TalkEchoPolicy.choose(route: .bluetoothHFP, echoCancelledInputAvailable: true), TalkEchoMode.none)
        XCTAssertEqual(TalkEchoPolicy.choose(route: .wired, echoCancelledInputAvailable: true), .voiceProcessing)
        XCTAssertEqual(TalkEchoPolicy.choose(route: .other, echoCancelledInputAvailable: false), .voiceProcessing)
    }

    func testTheLabOverrideWins() {
        XCTAssertEqual(TalkEchoPolicy.choose(route: .builtIn, echoCancelledInputAvailable: true, override: .voiceProcessing),
                       .voiceProcessing)
        XCTAssertEqual(TalkEchoPolicy.choose(route: .bluetoothHFP, echoCancelledInputAvailable: false,
                                             override: .echoCancelledInput), .echoCancelledInput)
    }

    func testTheSessionModeFollowsTheEchoMode() {
        XCTAssertEqual(TalkEchoPolicy.sessionMode(for: .echoCancelledInput), .default)
        XCTAssertEqual(TalkEchoPolicy.sessionMode(for: .voiceProcessing), .voiceChat)
        XCTAssertEqual(TalkEchoPolicy.sessionMode(for: TalkEchoMode.none), .default)
    }

    func testRoutesFromPortTypes() {
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.builtInMic], outputs: [.builtInSpeaker]), .builtIn)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.builtInMic], outputs: [.builtInReceiver]), .builtIn)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.bluetoothHFP], outputs: [.bluetoothHFP]), .bluetoothHFP)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.builtInMic], outputs: [.bluetoothHFP]), .bluetoothHFP)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.headsetMic], outputs: [.headphones]), .wired)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.builtInMic], outputs: [.headphones]), .wired)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [.usbAudio], outputs: [.carAudio]), .other)
        XCTAssertEqual(TalkEchoPolicy.route(inputs: [], outputs: []), .other)
    }

    func testNamesRoundTrip() {
        for mode in [TalkEchoMode.echoCancelledInput, .voiceProcessing, TalkEchoMode.none] {
            XCTAssertEqual(TalkEchoPolicy.echoMode(named: TalkEchoPolicy.name(of: mode)), mode)
        }
        XCTAssertNil(TalkEchoPolicy.echoMode(named: "automatic"))
        XCTAssertEqual(TalkEchoPolicy.name(of: .bluetoothHFP), "bluetoothHFP")
    }
}

/// The 16 kHz conversion voice typing and Talk share, Talk's 512-sample
/// frames, and the earcons.
final class TalkAudioFramesTests: XCTestCase {
    private func sine(_ hz: Double, amplitude: Float, frames: Int, rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(i) / rate)) }
        return buffer
    }

    func testTheConverterGivesSixteenKilohertzMonoAndTheInputLevel() throws {
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try XCTUnwrap(MicrophoneConverter(inputFormat: tapFormat))
        XCTAssertEqual(converter.outputFormat.sampleRate, 16_000)
        XCTAssertEqual(converter.outputFormat.channelCount, 1)
        var counts: [Int] = []
        var last: MicrophoneConverter.Converted?
        for _ in 0..<5 {
            let converted = try XCTUnwrap(converter.convert(sine(440, amplitude: 0.5, frames: 4_800, rate: 48_000)))
            counts.append(converted.samples.count)
            last = converted
        }
        // 100 ms in, 100 ms out at 16 kHz once the resampler's delay is
        // filled; that delay stays inside it from buffer to buffer.
        XCTAssertEqual(Double(counts.last ?? 0), 1_600, accuracy: 2)
        let total = counts.reduce(0, +)
        XCTAssertLessThanOrEqual(total, 8_000)
        XCTAssertGreaterThan(total, 7_400)
        XCTAssertEqual(try XCTUnwrap(last).inputRMS, Float(0.5) / Float(2).squareRoot(), accuracy: 0.01)
        let tail = try XCTUnwrap(last).samples
        let peak = tail.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.5, accuracy: 0.05, "the tone survives the conversion")
    }

    func testABufferInAnotherFormatIsDropped() throws {
        let converter = try XCTUnwrap(MicrophoneConverter(inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                                                                      channels: 1)!))
        XCTAssertNil(converter.convert(sine(440, amplitude: 0.5, frames: 4_410, rate: 44_100)))
    }

    func testTheMeterScale() {
        XCTAssertEqual(MicrophoneConverter.meterLevel(rms: 1), 1)
        XCTAssertEqual(MicrophoneConverter.meterLevel(rms: 0), 0)
        XCTAssertEqual(MicrophoneConverter.meterLevel(rms: pow(10, -27.5 / 20)), 0.5, accuracy: 0.001)
    }

    func testFramesAre512SamplesWithTheirTimeAndLevel() {
        var assembler = MicFrameAssembler()
        XCTAssertTrue(assembler.append(Array(repeating: 0.5, count: 300), startingAt: 10).isEmpty)
        let frames = assembler.append(Array(repeating: -0.5, count: 900), startingAt: 10.01875)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.samples.count == 512 })
        XCTAssertEqual(frames[0].time, 10, accuracy: 1e-9, "from the first sample still waiting")
        XCTAssertEqual(frames[1].time, 10.032, accuracy: 1e-9)
        XCTAssertEqual(frames[0].rms, 0.5, accuracy: 1e-6)
        XCTAssertEqual(Array(frames[0].samples.prefix(300)), Array(repeating: 0.5, count: 300))
        // 1200 samples in, 1024 out: 176 wait for the next chunk.
        let next = assembler.append(Array(repeating: 0, count: 336), startingAt: 10.075)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].time, 10.064, accuracy: 1e-9)
        XCTAssertEqual(next[0].rms, (Float(176) * 0.25 / 512).squareRoot(), accuracy: 1e-5)
    }

    func testEarconsAreSoftShortTones() {
        let rate = 44_100.0
        let gotIt = EarconTone.samples(.gotIt, sampleRate: rate)
        XCTAssertEqual(gotIt.count, Int(0.04 * rate))
        for earcon in [Earcon.listening, .gotIt, .error] {
            let samples = EarconTone.samples(earcon, sampleRate: rate)
            let peak = samples.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(peak, EarconTone.peak + 1e-6, "about -20 dBFS")
            XCTAssertGreaterThan(peak, EarconTone.peak * 0.9)
            XCTAssertEqual(samples.first ?? 1, 0, accuracy: 1e-6, "fades in")
            XCTAssertEqual(samples.last ?? 1, 0, accuracy: 1e-6, "fades out")
        }
        XCTAssertEqual(EarconTone.tones(.listening).map(\.hz), [660, 880])
        XCTAssertEqual(EarconTone.tones(.error).map(\.hz), [330, 220])
    }

    func testSpeechBuffersCarryTheSamples() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: TalkAudioEngine.playerSampleRate, channels: 1)!
        let buffer = try XCTUnwrap(TalkAudioEngine.pcmBuffer([0.1, -0.2, 0.3], format: format))
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(buffer.floatChannelData?[0][1], -0.2)
        XCTAssertNil(TalkAudioEngine.pcmBuffer([], format: format))
    }
}

/// While Talk holds the audio, read aloud and voice typing step aside, as
/// they do for each other and for session media.
@MainActor
final class TalkAudioClaimTests: XCTestCase {
    func testReadAloudAndDictationWaitWhileTalkHoldsTheAudio() async {
        // Both exist before Talk claims the audio, as in the app.
        _ = ReadAloudPlayer.shared
        _ = DictationController.shared
        NotificationCenter.default.post(name: .talkWillClaimAudio, object: nil)
        ReadAloudPlayer.shared.speak(id: "reply-1", title: "", text: "שלום")
        XCTAssertEqual(ReadAloudPlayer.shared.state, .idle)
        XCTAssertEqual(ReadAloudPlayer.shared.lastError, "Talk is using the audio.")

        var outcome: DictationOutcome?
        await DictationController.shared.start(owner: UUID(), context: DictationContext()) { outcome = $0 }
        XCTAssertEqual(outcome, .failed("Talk is using the microphone."))
        XCTAssertEqual(DictationController.shared.phase, .idle)

        NotificationCenter.default.post(name: .talkDidReleaseAudio, object: nil)
        // Back to normal: read aloud no longer refuses for Talk.
        ReadAloudPlayer.shared.speak(id: "reply-1", title: "", text: "   ")
        XCTAssertEqual(ReadAloudPlayer.shared.lastError, "Nothing to read in this reply.")
    }
}
