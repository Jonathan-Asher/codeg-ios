import XCTest
@testable import Codeg

/// Records what the owner asks of the audio session, and fails the next
/// activations on request.
final class FakeAudioSession: AudioSessionDriver {
    enum Call: Equatable {
        case configure(AudioSessionUse)
        case activate
        case deactivate
    }

    private(set) var calls: [Call] = []
    /// Errors for the next activations, in order.
    var activationErrors: [Error] = []

    func configure(for use: AudioSessionUse) throws {
        calls.append(.configure(use))
    }

    func activate() throws {
        calls.append(.activate)
        if !activationErrors.isEmpty { throw activationErrors.removeFirst() }
    }

    func deactivate() throws {
        calls.append(.deactivate)
    }
}

private func osStatus(_ code: Int) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "Session activation failed"])
}

private let insufficientPriority = 561_017_449 // '!pri'

final class AudioSessionOwnerTests: XCTestCase {
    private var session: FakeAudioSession!
    private var pauses: [TimeInterval] = []
    private var owner: AudioSessionOwner!

    override func setUp() {
        session = FakeAudioSession()
        pauses = []
        owner = AudioSessionOwner(driver: session, retryDelay: 0.25) { [unowned self] in self.pauses.append($0) }
    }

    func testActivatesOnceForAUse() throws {
        XCTAssertEqual(try owner.acquire(.standby), .activated)
        XCTAssertEqual(owner.activeUse, .standby)
        XCTAssertEqual(try owner.acquire(.standby), .alreadyActive)
        XCTAssertEqual(session.calls, [.configure(.standby), .activate])
    }

    func testAFailedActivationIsRetriedOnceAfterACleanDeactivate() throws {
        session.activationErrors = [osStatus(insufficientPriority)]
        XCTAssertEqual(try owner.acquire(.recording), .activatedOnRetry)
        XCTAssertEqual(session.calls, [
            .configure(.recording), .activate,
            .deactivate,
            .configure(.recording), .activate,
        ])
        XCTAssertEqual(pauses, [0.25])
        XCTAssertEqual(owner.activeUse, .recording)
    }

    func testTwoFailuresThrowAPlainWordsError() {
        session.activationErrors = [osStatus(insufficientPriority), osStatus(insufficientPriority)]
        XCTAssertThrowsError(try owner.acquire(.recording)) { error in
            XCTAssertTrue(error is AudioSessionFailure)
            XCTAssertEqual(AudioErrorText(error).tag, "!pri")
            XCTAssertEqual(AudioErrorText(error).message("Couldn't start the microphone"),
                           "Couldn't start the microphone: a call or another app is using the audio (!pri).")
        }
        XCTAssertNil(owner.activeUse)
        XCTAssertEqual(session.calls.last, .deactivate)
        XCTAssertEqual(session.calls.filter { $0 == .activate }.count, 2)
    }

    func testTheWorkFailingCountsAsAFailedAttempt() throws {
        var starts = 0
        let outcome = try owner.acquire(.standby) {
            starts += 1
            if starts == 1 { throw osStatus(-10_868) }
        }
        XCTAssertEqual(outcome, .activatedOnRetry)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(session.calls, [
            .configure(.standby), .activate, .deactivate, .configure(.standby), .activate,
        ])
    }

    func testReleaseOnlyLetsGoOfTheUseItIsActiveFor() throws {
        try owner.acquire(.readAloud)
        owner.release(.standby)
        XCTAssertEqual(owner.activeUse, .readAloud)
        XCTAssertFalse(session.calls.contains(.deactivate))
        owner.release(.readAloud)
        XCTAssertNil(owner.activeUse)
        XCTAssertEqual(session.calls.last, .deactivate)
    }

    func testAfterAnInterruptionTheNextUseActivatesAgain() throws {
        try owner.acquire(.standby)
        owner.sessionWasDeactivated()
        XCTAssertEqual(try owner.acquire(.standby), .activated)
        XCTAssertEqual(session.calls.filter { $0 == .activate }.count, 2)
    }

    func testPrepareSetsTheCategoryOnlyWhenNothingHoldsTheSession() throws {
        owner.prepare(.recording)
        XCTAssertEqual(session.calls, [.configure(.recording)])
        try owner.acquire(.readAloud)
        owner.prepare(.recording)
        XCTAssertEqual(session.calls, [.configure(.recording), .configure(.readAloud), .activate])
    }
}

/// The microphone hands off between standby and a recording without a
/// second activation, and never stays marked as running when it isn't.
final class MicrophoneStateTests: XCTestCase {
    func testARecordingFromStandbyUsesTheRunningEngine() {
        var mic = MicrophoneState()
        XCTAssertEqual(mic.wantStandby(), .startEngine(.standby))
        mic.engineStarted(.standby)
        XCTAssertTrue(mic.isStandingBy)
        // The press: no engine start, no session call.
        XCTAssertEqual(mic.beginRecording(), .none)
        // Let go: it carries on standing by.
        XCTAssertEqual(mic.endRecording(), .none)
        XCTAssertTrue(mic.isStandingBy)
        XCTAssertEqual(mic.engine, .standby)
    }

    func testAColdRecordingStartsAndStopsTheEngineForItself() {
        var mic = MicrophoneState()
        XCTAssertEqual(mic.beginRecording(), .startEngine(.recording))
        mic.engineStarted(.recording)
        XCTAssertEqual(mic.endRecording(), .stopEngine(.recording))
        XCTAssertNil(mic.engine)
    }

    func testStandbyWantedButNotRunningTheRecordingStartsItAsStandby() {
        var mic = MicrophoneState()
        XCTAssertEqual(mic.wantStandby(), .startEngine(.standby))
        // Standby failed to start (a call); its retry is pending.
        mic.engineFailed(duringRecording: false)
        XCTAssertFalse(mic.isStandingBy)
        XCTAssertTrue(mic.standbyWanted)
        // The mic button now starts the engine as standby, and it stays.
        XCTAssertEqual(mic.beginRecording(), .startEngine(.standby))
        mic.engineStarted(.standby)
        XCTAssertEqual(mic.wantStandby(), .none)
        XCTAssertEqual(mic.endRecording(), .none)
        XCTAssertTrue(mic.isStandingBy)
    }

    func testStandbyTurnedOnDuringAColdRecordingTakesOverAtTheEnd() {
        var mic = MicrophoneState()
        XCTAssertEqual(mic.beginRecording(), .startEngine(.recording))
        mic.engineStarted(.recording)
        XCTAssertEqual(mic.wantStandby(), .none)
        XCTAssertEqual(mic.endRecording(), .restartEngine(from: .recording, to: .standby))
    }

    func testStandbyTurnedOffDuringARecordingStopsAtTheEnd() {
        var mic = MicrophoneState()
        _ = mic.wantStandby()
        mic.engineStarted(.standby)
        _ = mic.beginRecording()
        XCTAssertEqual(mic.dropStandby(), .none)
        XCTAssertEqual(mic.endRecording(), .stopEngine(.standby))
        XCTAssertEqual(mic.dropStandby(), .none)
    }

    func testAnInterruptionDuringARecordingLeavesNothingMarkedAsRunning() {
        var mic = MicrophoneState()
        _ = mic.wantStandby()
        mic.engineStarted(.standby)
        _ = mic.beginRecording()
        // A call stops the engine under the recording.
        XCTAssertEqual(mic.engineStopped(), .standby)
        XCTAssertTrue(mic.recording)
        // The recording ends (transcribed, unsent); nothing to stop.
        XCTAssertEqual(mic.endRecording(), .none)
        XCTAssertFalse(mic.isStandingBy)
        // Standby's retry starts the engine again rather than trusting a dead one.
        XCTAssertEqual(mic.wantStandby(), .startEngine(.standby))
    }

    func testAFailedColdStartLeavesNoRecording() {
        var mic = MicrophoneState()
        XCTAssertEqual(mic.beginRecording(), .startEngine(.recording))
        mic.engineFailed(duringRecording: true)
        XCTAssertFalse(mic.recording)
        XCTAssertNil(mic.engine)
        XCTAssertEqual(mic.endRecording(), .none)
    }
}

final class AudioErrorTextTests: XCTestCase {
    func testFourCharacterCodes() {
        XCTAssertEqual(AudioErrorText.fourCharacterCode(561_017_449), "!pri")
        XCTAssertEqual(AudioErrorText.fourCharacterCode(560_557_684), "!int")
        XCTAssertEqual(AudioErrorText.fourCharacterCode(1_936_290_409), "siri")
        XCTAssertNil(AudioErrorText.fourCharacterCode(-50))
        XCTAssertNil(AudioErrorText.fourCharacterCode(12))
    }

    func testSessionCodesReadAsPlainWords() {
        let priority = AudioErrorText(osStatus(561_017_449))
        XCTAssertEqual(priority.reason, "a call or another app is using the audio")
        XCTAssertEqual(priority.tag, "!pri")
        XCTAssertFalse(priority.message("Couldn't start the microphone").contains("Session activation failed"))

        let interrupt = AudioErrorText(osStatus(560_557_684))
        XCTAssertEqual(interrupt.reason, "another app's audio can't be interrupted right now")
        XCTAssertEqual(interrupt.tag, "!int")

        let badParam = AudioErrorText(osStatus(-50))
        XCTAssertEqual(badParam.reason, "iOS rejected the audio settings")
        XCTAssertEqual(badParam.tag, "-50")
        XCTAssertEqual(badParam.message("Couldn't start audio"), "Couldn't start audio: iOS rejected the audio settings (-50).")

        let siri = AudioErrorText(osStatus(1_936_290_409))
        XCTAssertEqual(siri.message("Couldn't start the microphone"),
                       "Couldn't start the microphone: Siri is using the microphone (siri).")
    }

    func testTheLogLineKeepsDomainCodeAndTheSystemsWords() {
        let text = AudioErrorText(osStatus(561_017_449))
        XCTAssertEqual(text.logLine, "\(NSOSStatusErrorDomain) 561017449 (!pri) Session activation failed")
    }

    func testAnUnknownCodeStillSaysSomethingAndKeepsTheCode() {
        let text = AudioErrorText(NSError(domain: "com.apple.coreaudio.avfaudio", code: 4242))
        XCTAssertEqual(text.reason, "iOS reported an audio error")
        XCTAssertEqual(text.tag, "4242")
    }

    func testTheAppsOwnErrorsKeepTheirWords() {
        let text = AudioErrorText(DictationRecorder.RecorderError.noInput)
        XCTAssertEqual(text.reason, "no microphone is available")
        XCTAssertNil(text.tag)
        XCTAssertEqual(text.message("Couldn't start the microphone"),
                       "Couldn't start the microphone: no microphone is available.")
    }

    func testAFailureAfterTheRetryReportsTheUnderlyingError() {
        let failure = AudioSessionFailure(use: .standby, underlying: osStatus(560_557_684))
        XCTAssertEqual(AudioErrorText(failure).tag, "!int")
        XCTAssertEqual(failure.localizedDescription, "Another app's audio can't be interrupted right now (!int).")
    }
}
