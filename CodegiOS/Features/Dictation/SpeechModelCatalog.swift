import Foundation

/// The speech-to-text models the app can download, as listed in
/// `stt-models.json`. The same file is published next to the models in the
/// `models-v1` release of Jonathan-Asher/codeg-ios; the copy bundled in the app
/// is the one trusted, so a download is only accepted when it matches the
/// size and sha256 pinned here.
struct SpeechModelManifest: Codable, Sendable {
    struct File: Codable, Hashable, Sendable {
        /// File name inside the model's directory.
        let path: String
        let url: URL
        let size: Int64
        /// Lowercase hex SHA-256 of the whole file.
        let sha256: String
    }

    struct Model: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        /// One line for Settings.
        let summary: String
        /// Whisper language codes the model is meant for.
        let languages: [String]
        /// Whether whisper's language detection works with this model.
        let detectsLanguage: Bool
        let license: String
        /// Where the weights come from and how they were made.
        let source: String
        /// The whisper ggml weights (one of `files`).
        let weights: String
        /// The Silero VAD ggml model (one of `files`), if any.
        let vad: String?
        let files: [File]

        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    let schema: Int
    /// The GitHub release the files are published in.
    let release: String
    let models: [Model]

    static let supportedSchema = 1

    static func decode(_ data: Data) throws -> SpeechModelManifest {
        try JSONDecoder().decode(SpeechModelManifest.self, from: data)
    }

    /// Everything wrong with the manifest; empty when it is usable.
    func problems() -> [String] {
        var problems: [String] = []
        if schema != Self.supportedSchema { problems.append("schema \(schema) is not \(Self.supportedSchema)") }
        if models.isEmpty { problems.append("no models") }
        if Set(models.map(\.id)).count != models.count { problems.append("duplicate model ids") }
        let hex = Set("0123456789abcdef")
        for model in models {
            if model.files.isEmpty { problems.append("\(model.id): no files") }
            if Set(model.files.map(\.path)).count != model.files.count { problems.append("\(model.id): duplicate paths") }
            if !model.files.contains(where: { $0.path == model.weights }) {
                problems.append("\(model.id): weights \(model.weights) is not one of its files")
            }
            if let vad = model.vad, !model.files.contains(where: { $0.path == vad }) {
                problems.append("\(model.id): vad \(vad) is not one of its files")
            }
            for file in model.files {
                if file.sha256.count != 64 || !file.sha256.allSatisfy(hex.contains) {
                    problems.append("\(model.id)/\(file.path): sha256 is not 64 lowercase hex digits")
                }
                if file.size <= 0 { problems.append("\(model.id)/\(file.path): size \(file.size)") }
                if file.url.scheme != "https" { problems.append("\(model.id)/\(file.path): URL is not https") }
                if file.path.isEmpty || file.path.contains("/") || file.path.hasPrefix(".") {
                    problems.append("\(model.id)/\(file.path): bad file name")
                }
            }
        }
        return problems
    }
}

enum SpeechModelCatalog {
    /// The manifest bundled with the app.
    static let manifest: SpeechModelManifest = {
        guard let url = Bundle.main.url(forResource: "stt-models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? SpeechModelManifest.decode(data) else {
            assertionFailure("stt-models.json is missing or invalid")
            return SpeechModelManifest(schema: SpeechModelManifest.supportedSchema, release: "", models: [])
        }
        return manifest
    }()

    /// The Hebrew model (ivrit.ai): Hebrew and English with the language forced.
    static let hebrewID = "he-turbo"
    /// The stock multilingual model, used when the language is detected.
    static let multilingualID = "multi-turbo"

    static func model(id: String) -> SpeechModelManifest.Model? {
        manifest.models.first { $0.id == id }
    }

    /// The model a language setting uses.
    static func model(for language: DictationLanguage) -> SpeechModelManifest.Model? {
        model(id: language == .auto ? multilingualID : hebrewID)
    }

    /// The download for a model: `Application Support/SpeechToText/<id>`.
    static func pack(for model: SpeechModelManifest.Model) -> ModelPack {
        ModelPack(
            id: "stt-\(model.id)",
            files: model.files.map { ModelPackFile(path: $0.path, sha256: $0.sha256, url: $0.url, size: $0.size) },
            directory: ModelPack.applicationSupport("SpeechToText", model.id),
            sessionIdentifier: "io.ashurov.codeg.stt-\(model.id)",
            activeKey: "codeg.stt.\(model.id).downloadActive")
    }
}

/// One ``ModelPackStore`` per speech model, created on first use.
@MainActor
enum SpeechModelStores {
    private static var stores: [String: ModelPackStore] = [:]

    static func store(for model: SpeechModelManifest.Model) -> ModelPackStore {
        if let store = stores[model.id] { return store }
        let store = ModelPackStore(pack: SpeechModelCatalog.pack(for: model))
        stores[model.id] = store
        return store
    }

    /// The store whose background `URLSession` this is, for the app delegate.
    static func store(forSessionIdentifier identifier: String) -> ModelPackStore? {
        guard let model = SpeechModelCatalog.manifest.models.first(where: {
            SpeechModelCatalog.pack(for: $0).sessionIdentifier == identifier
        }) else { return nil }
        return store(for: model)
    }

    /// Reconnect downloads that were running when the app last quit.
    static func resumeActiveDownloads() {
        for model in SpeechModelCatalog.manifest.models
        where UserDefaults.standard.bool(forKey: SpeechModelCatalog.pack(for: model).activeKey) {
            _ = store(for: model)
        }
    }
}
