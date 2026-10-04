import XCTest
@testable import Codeg

/// "Hebrew or English": the language-ID decision, the strip's chip, the
/// setting, and the fallbacks when the language-ID model isn't there.
final class SpokenLanguageDecisionTests: XCTestCase {
    func testProbabilitiesAreRenormalizedOverTheCandidates() {
        let p = SpokenLanguageDecision.normalized(["he": 0.2, "en": 0.6])
        XCTAssertEqual(p["he"] ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertEqual(p["en"] ?? 0, 0.75, accuracy: 1e-6)
        XCTAssertEqual(SpokenLanguageDecision.normalized([:]), [:])
        XCTAssertEqual(SpokenLanguageDecision.normalized(["he": 0, "en": 0]), [:])
        XCTAssertEqual(SpokenLanguageDecision.normalized(["he": .nan, "en": 0.5]), ["en": 1])
        XCTAssertEqual(SpokenLanguageDecision.normalized(["he": -1, "en": 0.5]), ["en": 1])
    }

    /// English only once p(en) clears the threshold; anything less is Hebrew.
    func testTheThresholdLeansToHebrew() {
        let t = SpokenLanguageDecision.englishThreshold
        XCTAssertGreaterThan(t, 0.5, "the decision must lean to Hebrew")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": 0.5, "he": 0.5]), "he")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": 0.8, "he": 0.2]), "he")
        let below = t - 0.0005
        let above = min(1, t + 0.0002)
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": below, "he": 1 - below]), "he")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": above, "he": 1 - above]), "en")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": 1, "he": 0]), "en")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": 0.1, "he": 0.9]), "he")
        // Raw probabilities (whisper's softmax over all its languages) are
        // renormalized first: only the ratio of English to Hebrew counts.
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": above * 0.01, "he": (1 - above) * 0.01]), "en")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": below * 0.01, "he": (1 - below) * 0.01]), "he")
        // A custom threshold.
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["en": 0.7, "he": 0.3], threshold: 0.6), "en")
    }

    /// No language-ID model, or it failed: transcribe as Hebrew, as 1.3.0 did.
    func testWithoutAnAnswerItIsHebrew() {
        XCTAssertEqual(SpokenLanguageDecision.language(for: nil), "he")
        XCTAssertEqual(SpokenLanguageDecision.language(for: [:]), "he")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["he": 0, "en": 0]), "he")
        XCTAssertEqual(SpokenLanguageDecision.language(for: ["he": 1]), "he")
    }

    func testTheWindowIsTheStartOfTheClip() {
        let clip = (0..<(16_000 * 40)).map { Float($0) }
        let window = SpokenLanguageDecision.window(of: clip)
        XCTAssertEqual(window.count, Int(SpokenLanguageDecision.windowSeconds * 16_000))
        XCTAssertEqual(window.first, 0)
        XCTAssertEqual(SpokenLanguageDecision.window(of: clip, seconds: 5).count, 80_000)
        let short = Array(clip.prefix(16_000))
        XCTAssertEqual(SpokenLanguageDecision.window(of: short), short)
    }
}

final class DictationLanguageTests: XCTestCase {
    func testThePlanForEachSettingAndChip() {
        // The new default: Auto asks the language-ID model.
        XCTAssertEqual(DictationLanguage.hebrewOrEnglish.plan(choice: .automatic), .hebrewOrEnglish)
        XCTAssertEqual(DictationLanguage.hebrewOrEnglish.plan(choice: .hebrew), .forced("he"))
        XCTAssertEqual(DictationLanguage.hebrewOrEnglish.plan(choice: .english), .forced("en"))
        // The chip overrides a fixed setting for one message, both ways.
        XCTAssertEqual(DictationLanguage.hebrew.plan(choice: .hebrew), .forced("he"))
        XCTAssertEqual(DictationLanguage.hebrew.plan(choice: .english), .forced("en"))
        XCTAssertEqual(DictationLanguage.hebrew.plan(choice: .automatic), .hebrewOrEnglish)
        XCTAssertEqual(DictationLanguage.english.plan(choice: .english), .forced("en"))
        XCTAssertEqual(DictationLanguage.english.plan(choice: .hebrew), .forced("he"))
        // With the stock model, Auto is its own detection; the chip never
        // switches models.
        XCTAssertEqual(DictationLanguage.auto.plan(choice: .automatic), .detectAny)
        XCTAssertEqual(DictationLanguage.auto.plan(choice: .hebrew), .forced("he"))
        XCTAssertEqual(DictationLanguage.auto.plan(choice: .english), .forced("en"))
    }

    func testTheChipStartsFromTheSetting() {
        XCTAssertEqual(DictationLanguage.hebrewOrEnglish.defaultChoice, .automatic)
        XCTAssertEqual(DictationLanguage.auto.defaultChoice, .automatic)
        XCTAssertEqual(DictationLanguage.hebrew.defaultChoice, .hebrew)
        XCTAssertEqual(DictationLanguage.english.defaultChoice, .english)
        for language in DictationLanguage.allCases {
            XCTAssertEqual(language.plan(choice: language.defaultChoice),
                           language == .hebrew ? .forced("he")
                           : language == .english ? .forced("en")
                           : language == .auto ? .detectAny : .hebrewOrEnglish)
        }
    }

    func testTheChipCycles() {
        XCTAssertEqual(DictationLanguageChoice.automatic.next, .hebrew)
        XCTAssertEqual(DictationLanguageChoice.hebrew.next, .english)
        XCTAssertEqual(DictationLanguageChoice.english.next, .automatic)
        XCTAssertEqual(DictationLanguageChoice.allCases.map(\.shortTitle), ["Auto", "עב", "EN"])
    }

    func testTheSettingsOrderAndDefault() {
        XCTAssertEqual(DictationLanguage.default, .hebrewOrEnglish)
        XCTAssertEqual(DictationLanguage.allCases.first, .hebrewOrEnglish)
        XCTAssertEqual(DictationLanguage.hebrewOrEnglish.title, "Hebrew or English (automatic)")
        XCTAssertEqual(Set(DictationLanguage.allCases), [.hebrewOrEnglish, .hebrew, .english, .auto])
    }

    /// A stored Hebrew (1.3.0's default) moves to Hebrew or English once;
    /// choosing Hebrew again afterwards sticks.
    func testStoredHebrewMovesToHebrewOrEnglishOnce() {
        let defaults = UserDefaults.standard
        let keys = ["codeg.dictation.language", "codeg.dictation.languageMigrated"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        keys.forEach(defaults.removeObject(forKey:))
        XCTAssertEqual(DictationPrefs.language, .hebrewOrEnglish)

        keys.forEach(defaults.removeObject(forKey:))
        defaults.set("hebrew", forKey: keys[0])
        XCTAssertEqual(DictationPrefs.language, .hebrewOrEnglish)
        DictationPrefs.language = .hebrew
        XCTAssertEqual(DictationPrefs.language, .hebrew)

        keys.forEach(defaults.removeObject(forKey:))
        defaults.set("english", forKey: keys[0])
        XCTAssertEqual(DictationPrefs.language, .english)
        keys.forEach(defaults.removeObject(forKey:))
        defaults.set("auto", forKey: keys[0])
        XCTAssertEqual(DictationPrefs.language, .auto)
    }
}

/// A model downloaded before the language-ID file was added keeps working,
/// and only the new file is missing.
@MainActor
final class ModelPackUpdateTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ path: String, size: Int64) -> ModelPackFile {
        ModelPackFile(path: path, sha256: String(repeating: Character(String(path.count % 10)), count: 64),
                      url: URL(string: "https://example.com/\(path)")!, size: size)
    }

    private func pack(_ files: [ModelPackFile]) -> ModelPack {
        ModelPack(id: "test", files: files, directory: directory,
                  sessionIdentifier: "test.\(UUID().uuidString)", activeKey: "test.\(UUID().uuidString)")
    }

    private func put(_ file: ModelPackFile) throws {
        try Data(count: Int(file.size)).write(to: directory.appendingPathComponent(file.path))
    }

    private func writeMarker(_ files: [ModelPackFile]) throws {
        let sums = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.sha256) })
        try JSONEncoder().encode(sums).write(to: directory.appendingPathComponent(".verified.json"))
    }

    func testAnAddedFileLeavesTheRestUsable() throws {
        let weights = file("w.bin", size: 10)
        let vad = file("vad.bin", size: 3)
        let lid = file("lid.bin", size: 5)
        try put(weights)
        try put(vad)
        // The marker from the 1.3.0 download lists only the old files.
        try writeMarker([weights, vad])

        let store = ModelPackStore(pack: pack([weights, vad, lid]))
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertTrue(store.hasVerified([weights.path, vad.path]))
        XCTAssertFalse(store.hasVerified([lid.path]))
        XCTAssertEqual(store.bytesMissing, 5)

        // Once the new file is in place and the marker lists it, it's ready.
        try put(lid)
        try writeMarker([weights, vad, lid])
        store.refreshFromDisk()
        XCTAssertTrue(store.isReady)
        XCTAssertTrue(store.hasVerified([lid.path]))
        XCTAssertEqual(store.bytesMissing, 0)
    }

    func testFilesWithoutAMarkerAreNotTrusted() throws {
        let weights = file("w.bin", size: 10)
        let vad = file("vad.bin", size: 3)
        try put(weights)
        try put(vad)
        let store = ModelPackStore(pack: pack([weights, vad]))
        XCTAssertFalse(store.isReady)
        XCTAssertFalse(store.hasVerified([weights.path]))
    }

    func testAWrongSizeIsNotVerified() throws {
        let weights = file("w.bin", size: 10)
        let vad = file("vad.bin", size: 3)
        try put(weights)
        try Data(count: 2).write(to: directory.appendingPathComponent(vad.path))
        try writeMarker([weights, vad])
        let store = ModelPackStore(pack: pack([weights, vad]))
        XCTAssertTrue(store.hasVerified([weights.path]))
        XCTAssertFalse(store.hasVerified([weights.path, vad.path]))
    }
}
