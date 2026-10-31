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

/// The audio session's side of Talk's echo policy: the session mode for each
/// echo mode and the route from the session's ports.
final class TalkEchoSessionTests: XCTestCase {
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
}

/// The engine's speech buffers.
final class TalkAudioEngineBufferTests: XCTestCase {
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
