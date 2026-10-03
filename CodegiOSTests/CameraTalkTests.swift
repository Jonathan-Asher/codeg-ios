import UIKit
import XCTest
@testable import Codeg

/// Hold-to-talk on the Camera Control and the volume buttons.
final class CameraTalkPressTests: XCTestCase {
    func testHoldThenReleaseSends() {
        var press = CameraTalkPress()
        XCTAssertEqual(press.handle(.began, from: .primary, at: 10), .start)
        XCTAssertTrue(press.isHolding)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 12.5), .finish)
        XCTAssertFalse(press.isHolding)
    }

    func testAClickIsThrownAway() {
        var press = CameraTalkPress()
        XCTAssertEqual(press.handle(.began, from: .primary, at: 0), .start)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 0.2), .discard(.tooShort))
        XCTAssertFalse(press.isHolding)
        // The next press starts again.
        XCTAssertEqual(press.handle(.began, from: .primary, at: 1), .start)
    }

    func testTheMinimumHoldCounts() {
        var press = CameraTalkPress()
        _ = press.handle(.began, from: .primary, at: 0)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: CameraTalkPress.minimumHold), .finish)
    }

    func testCancelledIsThrownAway() {
        var press = CameraTalkPress()
        _ = press.handle(.began, from: .primary, at: 0)
        XCTAssertEqual(press.handle(.cancelled, from: .primary, at: 3), .discard(.cancelled))
        XCTAssertFalse(press.isHolding)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 3.1), .none)
    }

    func testStrayEventsAreIgnored() {
        var press = CameraTalkPress()
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 0), .none)
        XCTAssertEqual(press.handle(.cancelled, from: .secondary, at: 0), .none)
        XCTAssertEqual(press.handle(.began, from: .primary, at: 1), .start)
        // A repeated began while held, and the other button's release.
        XCTAssertEqual(press.handle(.began, from: .primary, at: 1.5), .none)
        XCTAssertEqual(press.handle(.ended, from: .secondary, at: 1.6), .none)
        XCTAssertTrue(press.isHolding)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 2), .finish)
    }

    func testTheVolumeButtonAloneTalksToo() {
        var press = CameraTalkPress()
        XCTAssertEqual(press.handle(.began, from: .secondary, at: 0), .start)
        XCTAssertEqual(press.handle(.ended, from: .secondary, at: 1), .finish)
    }

    func testTheOtherButtonThrowsTheRecordingAway() {
        var press = CameraTalkPress()
        XCTAssertEqual(press.handle(.began, from: .primary, at: 0), .start)
        XCTAssertEqual(press.handle(.began, from: .secondary, at: 1), .discard(.otherButton))
        XCTAssertFalse(press.isHolding)
        // Nothing happens until both are up.
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 2), .none)
        XCTAssertEqual(press.handle(.began, from: .primary, at: 2.5), .none)
        XCTAssertEqual(press.handle(.ended, from: .secondary, at: 3), .none)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 3.5), .none)
        XCTAssertEqual(press.handle(.began, from: .secondary, at: 4), .start)
    }

    func testResetDropsTheHeldPress() {
        var press = CameraTalkPress()
        _ = press.handle(.began, from: .primary, at: 0)
        press.reset()
        XCTAssertFalse(press.isHolding)
        XCTAssertEqual(press.handle(.ended, from: .primary, at: 2), .none)
        XCTAssertEqual(press.handle(.began, from: .primary, at: 3), .start)
    }
}

/// When the capture session may run.
final class CameraTalkGateTests: XCTestCase {
    private let screen = UUID()
    private let other = UUID()
    private let onScreen = CameraTalkGate.Presence(visible: true, sceneActive: true)

    private func readyGate() -> CameraTalkGate {
        var gate = CameraTalkGate()
        gate.enabled = true
        gate.cameraAuthorized = true
        gate.update(screen, onScreen)
        return gate
    }

    func testRunsOnlyWhenOnAndAllowed() {
        var gate = readyGate()
        XCTAssertTrue(gate.shouldRun)
        XCTAssertTrue(gate.isLive(screen))

        gate.enabled = false
        XCTAssertFalse(gate.shouldRun)
        XCTAssertFalse(gate.isLive(screen))

        gate.enabled = true
        gate.cameraAuthorized = false
        XCTAssertFalse(gate.shouldRun)
    }

    func testOffWithoutASessionScreen() {
        var gate = CameraTalkGate()
        gate.enabled = true
        gate.cameraAuthorized = true
        XCTAssertNil(gate.activeOwner)
        XCTAssertFalse(gate.shouldRun)
    }

    func testStopsWhenTheSceneIsNotActive() {
        var gate = readyGate()
        gate.update(screen, CameraTalkGate.Presence(visible: true, sceneActive: false))
        XCTAssertFalse(gate.shouldRun)
        XCTAssertEqual(gate.activeOwner, screen)

        gate.update(screen, onScreen)
        XCTAssertTrue(gate.shouldRun)

        gate.appActive = false
        XCTAssertFalse(gate.shouldRun)
        gate.appActive = true
        XCTAssertTrue(gate.shouldRun)
    }

    func testStopsWhenLeavingTheSession() {
        var gate = readyGate()
        gate.update(screen, CameraTalkGate.Presence(visible: false, sceneActive: true))
        XCTAssertFalse(gate.shouldRun)
        XCTAssertNil(gate.activeOwner)

        gate.update(screen, onScreen)
        XCTAssertTrue(gate.shouldRun)
        gate.remove(screen)
        XCTAssertFalse(gate.shouldRun)
        XCTAssertTrue(gate.presences.isEmpty)
    }

    func testThePhotoCameraSuspendsIt() {
        var gate = readyGate()
        gate.update(screen, CameraTalkGate.Presence(visible: true, sceneActive: true, suspended: true))
        XCTAssertFalse(gate.shouldRun)
    }

    func testTheLatestVisibleScreenOwnsIt() {
        var gate = readyGate()
        gate.update(other, onScreen)
        XCTAssertEqual(gate.activeOwner, other)
        XCTAssertTrue(gate.isLive(other))
        XCTAssertFalse(gate.isLive(screen))

        // Back to the first screen.
        gate.update(other, CameraTalkGate.Presence(visible: false, sceneActive: true))
        XCTAssertEqual(gate.activeOwner, screen)
        XCTAssertTrue(gate.isLive(screen))

        // Becoming visible again moves it to the front.
        gate.update(other, onScreen)
        XCTAssertEqual(gate.activeOwner, other)
        gate.remove(other)
        XCTAssertEqual(gate.activeOwner, screen)
    }

    func testAnUnchangedUpdateKeepsTheOrder() {
        var gate = readyGate()
        gate.update(other, onScreen)
        // A scene-phase report from the first screen doesn't take it back.
        gate.update(screen, CameraTalkGate.Presence(visible: true, sceneActive: true))
        XCTAssertEqual(gate.activeOwner, other)
    }

    func testTheCameraControlSymbolExists() {
        XCTAssertNotNil(UIImage(systemName: "camera.shutter.button.fill"))
        XCTAssertNotNil(UIImage(systemName: "camera.shutter.button"))
    }
}
