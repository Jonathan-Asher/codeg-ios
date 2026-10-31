import Foundation

// The seams between Talk's pure logic and the engines that run on the device.
// The logic in this folder only sees these protocols; the audio engine, the
// speech models and the session wiring implement them.

/// Streaming voice activity detection: one speech probability for each frame
/// of 512 samples at 16 kHz (32 ms). Keeps its state between frames until
/// ``reset()``.
protocol SpeechActivity {
    func probability(_ frame: [Float]) -> Float
    func reset()
}

/// Live (streaming) transcription of the utterance being heard. `begin`
/// starts an utterance with the audio just before speech was detected;
/// `accept` returns the partial text when it changed; `flushTail` decodes
/// what is buffered at a pause without ending the utterance; `finish` ends
/// it and returns the final text.
protocol LiveTranscriber: AnyObject {
    func begin(preRoll: [Float])
    func accept(_ samples: [Float]) -> String?
    func flushTail() -> String
    func finish() -> String
    func reset()
}

/// The more accurate transcription of a whole utterance (16 kHz mono),
/// started speculatively at a pause.
protocol FinalTranscriber: AnyObject, Sendable {
    func transcribe(_ clip: [Float]) async throws -> String
    func cancel()
}

/// The probability that the speaker finished their turn, from the last 8 s
/// of audio. `nil` when the model isn't available.
protocol TurnEndClassifier {
    func probability(last8s: [Float]) async -> Float?
}

/// Speech for one unit, as 44.1 kHz mono samples in chunks.
protocol Synthesizer {
    func synthesize(_ unit: SpeechUnit) -> AsyncThrowingStream<[Float], Error>
}

/// Monotonic seconds. Tests drive a fake one.
protocol TalkClock: Sendable {
    func now() -> TimeInterval
}

/// The clock Talk runs on: seconds since the device booted.
struct SystemTalkClock: TalkClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// One piece of speech: a sentence of the agent's reply, or a short cue
/// ("It's on the screen") that stands in for something that isn't read.
struct SpeechUnit: Equatable, Hashable, Sendable, Identifiable {
    /// The language the text is in, as a hint for the synthesizer.
    enum Language: String, Equatable, Hashable, Sendable {
        case hebrew = "he"
        case english = "en"
        /// Neither is clear (only digits and symbols, or both).
        case auto
    }

    enum Kind: Equatable, Hashable, Sendable {
        case sentence
        case cue
    }

    /// The reply a unit belongs to (a turn id, or a cue's own name) and its
    /// place in it.
    struct ID: Hashable, Sendable, CustomStringConvertible {
        var reply: String
        var index: Int

        var description: String { "\(reply)#\(index)" }
    }

    var id: ID
    var text: String
    var language: Language
    /// The first unit of a reply: the speaker starts it with a short first
    /// chunk, so the first sound comes sooner.
    var isFirstOfReply: Bool
    var kind: Kind

    init(id: ID, text: String, language: Language? = nil, isFirstOfReply: Bool = false, kind: Kind = .sentence) {
        self.id = id
        self.text = text
        self.language = language ?? Self.language(of: text)
        self.isFirstOfReply = isFirstOfReply
        self.kind = kind
    }

    /// A unit with no reply of its own: a prompt or a cue Talk says itself.
    static func standalone(_ text: String, name: String, kind: Kind = .cue,
                           language: Language? = nil) -> SpeechUnit {
        SpeechUnit(id: ID(reply: name, index: 0), text: text, language: language, isFirstOfReply: true, kind: kind)
    }

    /// Hebrew when the text holds a Hebrew letter, English when it holds
    /// only Latin letters, otherwise auto.
    static func language(of text: String) -> Language {
        if HebrewText.containsHebrew(text) { return .hebrew }
        if HebrewText.containsLatin(text) { return .english }
        return .auto
    }
}
