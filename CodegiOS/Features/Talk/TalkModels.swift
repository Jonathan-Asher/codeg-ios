import Foundation

/// The downloads Talk runs on, and whether each is on this iPhone.
///
/// - **Required:** the streaming Zipformer pack (live transcript, with the
///   Silero VAD file in it) and Smart Turn (end of turn, logged in shadow).
/// - **The natural voice:** BlueTTS. Without it Talk speaks with the
///   iPhone's own Hebrew and English voices.
/// - **Optional:** the whisper model voice typing uses (the more accurate
///   final transcript, "better English terms").
@MainActor
enum TalkModels {
    /// One download Talk uses.
    enum Requirement: String, CaseIterable, Identifiable, Sendable {
        case liveTranscriber
        case turnClassifier
        case voice
        case whisper

        var id: String { rawValue }

        /// Talk doesn't start without it.
        var isRequired: Bool { self == .liveTranscriber || self == .turnClassifier }

        var title: String {
            switch self {
            case .liveTranscriber: "Live Hebrew transcription"
            case .turnClassifier: "End of turn"
            case .voice: "Natural voice (BlueTTS)"
            case .whisper: "Better English terms (whisper)"
            }
        }

        /// One line on what it does for Talk.
        var purpose: String {
            switch self {
            case .liveTranscriber: "Hears you as you speak (ivrit.ai streaming Zipformer). Required."
            case .turnClassifier: "Helps tell when you finished (Smart Turn). Required."
            case .voice: "Speaks the replies in a natural Hebrew and English voice. Without it, the iPhone's own voices speak."
            case .whisper: "Writes what you said again at each pause, better at English terms. Optional; also voice typing's model."
            }
        }
    }

    // MARK: - The models

    static var zipformer: SpeechModelManifest.Model? { SpeechModelCatalog.model(id: SpeechModelCatalog.hebrewStreamingID) }
    static var smartTurn: SpeechModelManifest.Model? { SpeechModelCatalog.model(id: SpeechModelCatalog.smartTurnID) }
    /// The whisper model voice typing uses (its language setting picks it).
    static var whisper: SpeechModelManifest.Model? { SpeechModelCatalog.model(for: DictationPrefs.language) }

    /// The store that downloads a requirement (BlueTTS has its own).
    static func store(for requirement: Requirement) -> ModelPackStore? {
        switch requirement {
        case .liveTranscriber: zipformer.map(SpeechModelStores.store(for:))
        case .turnClassifier: smartTurn.map(SpeechModelStores.store(for:))
        case .voice: VoiceModelStore.shared
        case .whisper: whisper.map(SpeechModelStores.store(for:))
        }
    }

    static func model(for requirement: Requirement) -> SpeechModelManifest.Model? {
        switch requirement {
        case .liveTranscriber: zipformer
        case .turnClassifier: smartTurn
        case .voice: nil
        case .whisper: whisper
        }
    }

    /// The download's size in bytes.
    static func bytes(for requirement: Requirement) -> Int64 {
        switch requirement {
        case .voice: VoiceModelCatalog.totalBytes
        default: model(for: requirement)?.totalBytes ?? 0
        }
    }

    /// Whether it is on this iPhone and verified.
    static func isReady(_ requirement: Requirement) -> Bool {
        guard let store = store(for: requirement) else { return false }
        if requirement == .voice { return store.isReady }
        guard let model = model(for: requirement) else { return false }
        return store.hasVerified(model.requiredPaths)
    }

    /// The required downloads that are missing; Talk can start when empty.
    static var missingRequired: [Requirement] {
        Requirement.allCases.filter { $0.isRequired && !isReady($0) }
    }

    /// Everything not on this iPhone yet, required first.
    static var missing: [Requirement] {
        Requirement.allCases.filter { !isReady($0) }
    }

    // MARK: - Files

    /// The Zipformer's encoder, decoder, joiner and tokens.
    static func zipformerParts() -> (directory: URL, parts: [String: String])? {
        guard let model = zipformer, let parts = model.parts, isReady(.liveTranscriber) else { return nil }
        return (SpeechModelStores.store(for: model).modelsDirectory, parts)
    }

    /// The Silero VAD file of the Zipformer pack (the streaming VAD's model
    /// when whisper isn't downloaded).
    static func zipformerVAD() -> URL? {
        guard let model = zipformer, let vad = model.vad, isReady(.liveTranscriber) else { return nil }
        return SpeechModelStores.store(for: model).url(forPath: vad)
    }

    /// Smart Turn's ONNX model.
    static func smartTurnURL() -> URL? {
        guard let model = smartTurn, isReady(.turnClassifier) else { return nil }
        return SpeechModelStores.store(for: model).url(forPath: model.weights)
    }

    /// The speech engines' files for Talk: whisper's when it is downloaded,
    /// otherwise whisper's paths (never loaded) with the Zipformer pack's VAD,
    /// so the streaming VAD still has its model.
    static func engineConfiguration() -> (configuration: SpeechEngineConfiguration, whisperReady: Bool)? {
        guard let whisper else { return nil }
        let store = SpeechModelStores.store(for: whisper)
        if isReady(.whisper) {
            return (SpeechEngineConfiguration(model: whisper, store: store), true)
        }
        guard let vad = zipformerVAD() else { return nil }
        return (SpeechEngineConfiguration(whisperModelID: whisper.id, whisperURL: store.url(forPath: whisper.weights),
                                          vadURL: vad, languageIDURL: nil), false)
    }

    /// "73 MB".
    nonisolated static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }
}
