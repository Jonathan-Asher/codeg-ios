import Foundation

/// What the microphone's engine is doing, and what each request needs from
/// it. Pure, so the hand-off rules are unit-tested; ``DictationRecorder``
/// carries out the steps through ``AudioSessionOwner``.
///
/// - A recording that starts while the microphone stands by records from the
///   running engine: no session call, no second activation.
/// - A recording that starts while standby is wanted but not running (it is
///   being retried after an interruption) starts the engine as standby, so it
///   carries on standing by afterwards.
/// - Otherwise a recording starts the engine for itself (AirPods' microphone
///   allowed), and stops it at the end.
/// - When the engine stops by itself (a call, a route change), nothing is
///   left marked as running, so the next request starts it again.
struct MicrophoneState: Equatable, Sendable {
    /// The session use the running engine was started for; nil when stopped.
    private(set) var engine: AudioSessionUse?
    /// The Camera Control wants the microphone standing by.
    private(set) var standbyWanted = false
    /// A recording keeps everything it hears.
    private(set) var recording = false

    enum Step: Equatable, Sendable {
        case none
        /// Acquire the session for this use and start the engine.
        case startEngine(AudioSessionUse)
        /// Stop the engine and release the session it was started for.
        case stopEngine(AudioSessionUse)
        /// Stop the engine, release `from`, then start it again for `to`.
        case restartEngine(from: AudioSessionUse, to: AudioSessionUse)
    }

    /// Standing by: the engine runs and standby is wanted.
    var isStandingBy: Bool { standbyWanted && engine != nil }

    mutating func wantStandby() -> Step {
        standbyWanted = true
        // A running engine, or a recording under way (its end restarts the
        // engine as standby when needed), needs nothing now.
        guard engine == nil, !recording else { return .none }
        return .startEngine(.standby)
    }

    mutating func dropStandby() -> Step {
        standbyWanted = false
        guard let use = engine, !recording else { return .none }
        engine = nil
        return .stopEngine(use)
    }

    mutating func beginRecording() -> Step {
        recording = true
        guard engine == nil else { return .none }
        return .startEngine(standbyWanted ? .standby : .recording)
    }

    mutating func endRecording() -> Step {
        guard recording else { return .none }
        recording = false
        guard let use = engine else { return .none }
        if standbyWanted {
            if use == .standby { return .none }
            engine = nil
            return .restartEngine(from: use, to: .standby)
        }
        engine = nil
        return .stopEngine(use)
    }

    /// The engine runs for `use`.
    mutating func engineStarted(_ use: AudioSessionUse) {
        engine = use
    }

    /// Starting the engine failed: nothing runs, and a recording that asked
    /// for it didn't start. Standby stays wanted, so its retry, or the next
    /// recording, starts it.
    mutating func engineFailed(duringRecording: Bool) {
        engine = nil
        if duringRecording { recording = false }
    }

    /// The engine stopped by itself (an interruption, a route change).
    /// Returns the use whose session to release. A recording stays marked
    /// until it is ended, so its audio so far can be kept.
    mutating func engineStopped() -> AudioSessionUse? {
        let use = engine
        engine = nil
        return use
    }
}
