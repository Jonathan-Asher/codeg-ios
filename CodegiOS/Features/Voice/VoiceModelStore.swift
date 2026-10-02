import Foundation

/// One model file BlueTTS needs, pinned to an exact revision and checksum.
/// The list mirrors `Packages/BlueTTSKit/scripts/models.sha256`; `path` is the
/// layout `BlueTTS(modelDirectory:)` reads.
typealias VoiceModelFile = ModelPackFile

enum VoiceModelCatalog {
    private static let blueRev = "468da64b4a51795a7594a3637727dbaf876b6df2"
    private static let renikudRev = "679c56ca449d41873fb8ff7711ddf7563d28198f"
    private static let voicesRev = "0e38dbf08ed53f85863d1eab092bd9572c53a503"

    private static func hf(_ repo: String, _ rev: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(rev)/\(file)")!
    }

    private static func gh(_ repo: String, _ rev: String, _ file: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(rev)/\(file)")!
    }

    static let files: [VoiceModelFile] = [
        VoiceModelFile(path: "bluetts/duration_predictor_style.onnx",
                       sha256: "3d0347cfc09234b78a20d5fa50b5c402d338fb99825f40ada8c70301edbb60ea",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "duration_predictor_style.onnx"), size: 1_508_749),
        VoiceModelFile(path: "bluetts/text_encoder.onnx",
                       sha256: "f971aa25315b93efff1850b39fe293aa93ae85df69fabf5e5022318cc632973c",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "text_encoder.onnx"), size: 27_419_694),
        VoiceModelFile(path: "bluetts/vector_estimator.onnx",
                       sha256: "50557b34acfafa4b34f21dae263faa74d3f3169f114ff927599a1eff110d0b6e",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "vector_estimator.onnx"), size: 132_475_789),
        VoiceModelFile(path: "bluetts/vocoder.onnx",
                       sha256: "b0709df316ff44cc263c04fbf9d17371b16897071a48b79d3634d5f379fb3067",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "vocoder.onnx"), size: 101_411_919),
        VoiceModelFile(path: "bluetts/tts.json",
                       sha256: "862d44194197de4873eccc8bfdab1835d15f98e469a90489df6da8f92a48c7ea",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "tts.json"), size: 9_260),
        VoiceModelFile(path: "bluetts/vocab.json",
                       sha256: "13fba5e735222fcf30d9c062d898982a1ba86d481f11560fbbdf6e0af79417b3",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "vocab.json"), size: 3_157),
        VoiceModelFile(path: "bluetts/stats.npz",
                       sha256: "20d44fae010d46b859ee6238609780eb7bd5bf82320bad17b826a5dcfa4ed658",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "stats.npz"), size: 1_920),
        VoiceModelFile(path: "bluetts/uncond.npz",
                       sha256: "1c71c2b2836fd97f4c56eb21e258227650bbe0dcd906f64e2bba58e6ac09e76b",
                       url: hf("notmax123/BlueTTS2.5-onnx", blueRev, "uncond.npz"), size: 52_732),
        VoiceModelFile(path: "renikud/model_int8.onnx",
                       sha256: "0337468fad56eadf5ecc7becfdf21648a4d668de41de5bc27e860141b5afcadd",
                       url: hf("notmax123/RenikudPlus", renikudRev, "model_int8.onnx"), size: 311_605_741),
        VoiceModelFile(path: "voices/noa.json",
                       sha256: "c233f066a7d505306892509649bc80abeb7d0a565687f143e277ec93874a47c8",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/noa.json"), size: 288_898),
        VoiceModelFile(path: "voices/adam.json",
                       sha256: "c2c7b7daf9d77aad0f76e91ad9ae634a17158a291d6920eb4eb705e522dcc0b2",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/adam.json"), size: 288_774),
        VoiceModelFile(path: "voices/daniel.json",
                       sha256: "9f5364c856383de27f5f276557b6160343125dcf80a6019e882cc90d7cbf2d84",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/daniel.json"), size: 289_020),
        VoiceModelFile(path: "voices/lily.json",
                       sha256: "b96c1b0255334e83f1a23a9fe9e599b8af44058308c64775e216fbcb8415f916",
                       url: gh("maxmelichov/Light-BlueTTS", voicesRev, "voices/lily.json"), size: 289_090),
    ]

    static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }

    /// The voices shipped with the model files.
    static let voices = ["noa", "adam", "daniel", "lily"]

    static func file(forPath path: String) -> VoiceModelFile? { files.first { $0.path == path } }

    /// The BlueTTS download: ~575 MB into `Application Support/BlueTTS/models`.
    static let pack = ModelPack(
        id: "bluetts",
        files: files,
        directory: ModelPack.applicationSupport("BlueTTS", "models"),
        sessionIdentifier: "io.ashurov.codeg.voice-models",
        activeKey: "codeg.voice.downloadActive")
}

/// The BlueTTS model files (~575 MB), downloaded by a ``ModelPackStore`` in
/// the background, resumable, each file checked against its pinned sha256.
enum VoiceModelStore {
    @MainActor static let shared = ModelPackStore(pack: VoiceModelCatalog.pack)
}

