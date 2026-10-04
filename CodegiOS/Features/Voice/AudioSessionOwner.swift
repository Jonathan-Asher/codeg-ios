import Foundation
import os

/// What the app uses its audio session for. There is one session per app, so
/// the microphone (dictation and the Camera Control's standby) and read aloud
/// take turns through ``AudioSessionOwner``.
enum AudioSessionUse: String, Sendable {
    /// The Camera Control's standby microphone, and any recording that starts
    /// from it: `.playAndRecord` through the iPhone's microphone, mixing with
    /// other apps' audio, AirPods kept in A2DP.
    case standby
    /// A recording started without standby: `.playAndRecord`, not mixable,
    /// AirPods' microphone (HFP) allowed.
    case recording
    /// Read aloud: `.playback`, spoken audio.
    case readAloud
}

/// The calls ``AudioSessionOwner`` makes: `AVAudioSession` in the app
/// (``SystemAudioSession``), a fake in the tests.
protocol AudioSessionDriver: AnyObject {
    /// Set the category, mode and options for `use`, without activating.
    func configure(for use: AudioSessionUse) throws
    func activate() throws
    /// Deactivate, letting other apps' audio resume.
    func deactivate() throws
}

/// The one owner of the app's audio session. Every activation and
/// deactivation goes through it, so the microphone and read aloud never undo
/// each other, and a failure is retried once and reported in plain words.
///
/// - ``acquire(_:starting:)`` configures and activates the session for a use,
///   then runs the work that needs it (starting the audio engine). If that
///   fails, the session is deactivated cleanly, and after a short pause the
///   whole attempt runs once more. When the session is already active for
///   that use, nothing is activated again.
/// - ``release(_:)`` deactivates it, but only for the use it is active for.
///
/// A recording that starts while the microphone stands by doesn't come here
/// at all: it records from the engine that is already running
/// (``MicrophoneState``).
final class AudioSessionOwner: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        /// Active for this use already: nothing was called.
        case alreadyActive
        case activated
        /// The first attempt failed; the second worked.
        case activatedOnRetry
    }

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "audio-session")

    private let driver: AudioSessionDriver
    private let retryDelay: TimeInterval
    private let pause: (TimeInterval) -> Void
    private let lock = NSRecursiveLock()
    private var active: AudioSessionUse?

    /// `pause` waits between the failed attempt and the retry (a sleep in
    /// the app, nothing in the tests).
    init(driver: AudioSessionDriver, retryDelay: TimeInterval = 0.25,
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.driver = driver
        self.retryDelay = retryDelay
        self.pause = pause
    }

    /// The use the session is configured and active for, if any.
    var activeUse: AudioSessionUse? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Make the session ready for `use`, then run `work`. Throws an
    /// ``AudioSessionFailure`` when the retry fails too; the session is then
    /// inactive.
    @discardableResult
    func acquire(_ use: AudioSessionUse, starting work: () throws -> Void = {}) throws -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if active == use {
            try work()
            return .alreadyActive
        }
        do {
            try attempt(use, work)
            return .activated
        } catch let first {
            let text = AudioErrorText(first)
            Self.log.error("Audio session for \(use.rawValue, privacy: .public) failed: \(text.logLine, privacy: .public); retrying after a clean deactivate")
            try? driver.deactivate()
            active = nil
            pause(retryDelay)
            do {
                try attempt(use, work)
                Self.log.notice("Audio session for \(use.rawValue, privacy: .public) started on the retry")
                return .activatedOnRetry
            } catch {
                let text = AudioErrorText(error)
                Self.log.error("Audio session for \(use.rawValue, privacy: .public) failed again: \(text.logLine, privacy: .public)")
                try? driver.deactivate()
                active = nil
                throw AudioSessionFailure(use: use, underlying: error)
            }
        }
    }

    private func attempt(_ use: AudioSessionUse, _ work: () throws -> Void) throws {
        try driver.configure(for: use)
        try driver.activate()
        active = use
        try work()
    }

    /// `use` is done with the session: deactivate it, letting other apps'
    /// audio resume. Does nothing when the session is active for another use
    /// (or not at all), so one user can't pull it from under another.
    func release(_ use: AudioSessionUse) {
        lock.lock()
        defer { lock.unlock() }
        guard active == use else { return }
        active = nil
        do {
            try driver.deactivate()
        } catch {
            // Usually '!act': audio was still running. The session goes
            // inactive once it stops.
            Self.log.notice("Deactivating after \(use.rawValue, privacy: .public): \(AudioErrorText(error).logLine, privacy: .public)")
        }
    }

    /// Set the category for `use` ahead of time, without activating, when
    /// nothing holds the session. Cheap; changes nothing audible.
    func prepare(_ use: AudioSessionUse) {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { return }
        try? driver.configure(for: use)
    }

    /// iOS deactivated the session (an interruption began, or the media
    /// services were reset): the next ``acquire(_:starting:)`` activates it
    /// again.
    func sessionWasDeactivated() {
        lock.lock()
        defer { lock.unlock() }
        active = nil
    }
}

/// An error the app throws itself, already in plain words.
protocol PlainAudioError: LocalizedError {}

/// The session couldn't be started for a use, after the retry.
struct AudioSessionFailure: LocalizedError {
    let use: AudioSessionUse
    let underlying: Error

    var errorDescription: String? { AudioErrorText(underlying).sentence }
}

/// An audio error in plain words. `AVAudioSession` and `AVAudioEngine`
/// report OSStatus codes (`'!pri'`, `-50`) with descriptions such as
/// "Session activation failed", which say nothing about what to do.
struct AudioErrorText: Equatable, Sendable {
    let domain: String
    let code: Int
    /// What went wrong, as a clause: "a call or another app is using the audio".
    let reason: String
    /// The code as it appears in Apple's headers: "!pri", or "-50".
    let tag: String?
    /// The system's own description.
    let systemDescription: String

    init(_ error: Error) {
        let error = (error as? AudioSessionFailure)?.underlying ?? error
        let ns = error as NSError
        domain = ns.domain
        code = ns.code
        systemDescription = ns.localizedDescription
        if let plain = error as? PlainAudioError {
            reason = Self.clause(plain.errorDescription ?? ns.localizedDescription)
            tag = nil
        } else {
            tag = Self.fourCharacterCode(ns.code) ?? String(ns.code)
            reason = Self.reasons[ns.code] ?? "iOS reported an audio error"
        }
    }

    /// "Couldn't start the microphone: a call or another app is using the
    /// audio (!pri)."
    func message(_ prefix: String) -> String {
        "\(prefix): \(reason)\(tag.map { " (\($0))" } ?? "")."
    }

    /// The reason as a sentence, for `errorDescription`.
    var sentence: String {
        let first = reason.prefix(1).uppercased() + reason.dropFirst()
        return "\(first)\(tag.map { " (\($0))" } ?? "")."
    }

    /// Domain, code, four-character code and the system's description.
    var logLine: String {
        "\(domain) \(code)\(tag.map { " (\($0))" } ?? "") \(systemDescription)"
    }

    /// "No microphone is available." → "no microphone is available".
    private static func clause(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first, text.dropFirst().first?.isLowercase ?? true else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// `'!pri'` for 561017449; nil when the four bytes aren't printable.
    static func fourCharacterCode(_ code: Int) -> String? {
        guard code > 0, code <= Int(UInt32.max) else { return nil }
        let value = UInt32(code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `AVAudioSession.ErrorCode`, and the Core Audio codes an engine start
    /// can return.
    static let reasons: [Int: String] = [
        561_017_449: "a call or another app is using the audio",                 // '!pri' insufficientPriority
        560_557_684: "another app's audio can't be interrupted right now",       // '!int' cannotInterruptOthers
        561_145_187: "a call or another app is using the microphone",            // '!rec' cannotStartRecording
        561_015_905: "audio can't play right now",                               // '!pla' cannotStartPlaying
        560_030_580: "the audio system is busy, try again",                      // '!act' isBusy
        560_161_140: "this audio setting isn't allowed right now",               // '!cat' incompatibleCategory
        1_936_290_409: "Siri is using the microphone",                           // 'siri' siriIsRecording
        561_145_203: "the audio hardware isn't available right now",             // '!res' resourceNotAvailable
        1_836_282_486: "the iPhone's audio services restarted, try again",       // 'msrv' mediaServicesFailed
        2_003_329_396: "iOS refused without saying why, try again",              // 'what' unspecified
        561_210_739: "the audio session had expired, try again",                 // '!ses' expiredSession
        1_768_841_571: "the audio session wasn't active",                        // 'inac' sessionNotActive
        1_701_737_535: "the app isn't allowed this kind of audio",               // 'ent?' missingEntitlement
        -50: "iOS rejected the audio settings",                                  // badParam
        -10_868: "the microphone's audio format isn't supported",                // kAudioUnitErr_FormatNotSupported
        -10_875: "the audio engine couldn't start",                              // kAudioUnitErr_FailedInitialization
        -10_851: "the audio engine rejected a setting",                          // kAudioUnitErr_InvalidPropertyValue
    ]
}
