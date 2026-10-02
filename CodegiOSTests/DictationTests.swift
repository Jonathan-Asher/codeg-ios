import SwiftUI
import XCTest
@testable import Codeg

/// Speakly's VAD gate and dictation trimming, ported to Swift.
final class VADGateTests: XCTestCase {
    /// 32 ms frames: close after 9 quiet frames, drop speech under 7 frames.
    private let config = VADGateConfig.dictation(frameMs: 32)

    private func probs(_ parts: (Float, Int)...) -> [Float] {
        parts.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    func testOnsetNeedsTwoFrames() {
        var single = probs((0.1, 20))
        single[5] = 0.9
        XCTAssertEqual(VADGate.run(config, probabilities: single), VADGateOutput(closed: [], openStart: nil))

        let out = VADGate.run(config, probabilities: probs((0.1, 3), (0.9, 12)))
        XCTAssertEqual(out.openStart, 3)
        XCTAssertTrue(out.closed.isEmpty)
    }

    func testShortDipDoesNotClose() {
        // A 5-frame dip (160 ms) is under the 300 ms needed to close.
        let out = VADGate.run(config, probabilities: probs((0.9, 10), (0.1, 5), (0.9, 10)))
        XCTAssertEqual(out, VADGateOutput(closed: [], openStart: 0))
    }

    func testSustainedSilenceClosesAtTheLastSpeechFrame() {
        let out = VADGate.run(config, probabilities: probs((0.9, 10), (0.1, 12)))
        XCTAssertEqual(out, VADGateOutput(closed: [VADSegment(start: 0, end: 10)], openStart: nil))
    }

    func testTooShortSpeechIsDropped() {
        // 4 frames (128 ms) is under the 250 ms minimum.
        let out = VADGate.run(config, probabilities: probs((0.9, 4), (0.1, 12)))
        XCTAssertEqual(out, VADGateOutput(closed: [], openStart: nil))
    }

    func testMidBandProbabilityKeepsSpeechOpen() {
        // 0.5 is under the 0.6 onset but over the 0.35 release.
        let out = VADGate.run(config, probabilities: probs((0.9, 8), (0.5, 20)))
        XCTAssertEqual(out, VADGateOutput(closed: [], openStart: 0))
    }

    func testMaxSegmentForcesASplit() {
        var short = config
        short.maxSegmentMs = 320 // 10 frames
        let out = VADGate.run(short, probabilities: probs((0.9, 25)))
        XCTAssertEqual(out.closed, [VADSegment(start: 0, end: 10), VADSegment(start: 10, end: 20)])
        XCTAssertEqual(out.openStart, 20)
    }

    func testTwoUtterancesMakeTwoSegments() {
        let out = VADGate.run(config, probabilities: probs((0.9, 10), (0.1, 12), (0.9, 10), (0.1, 12)))
        XCTAssertEqual(out.closed.count, 2)
        XCTAssertEqual(out.closed[1], VADSegment(start: 22, end: 32))
    }

    func testDictationPolicyValues() {
        let c = VADGateConfig.dictation(frameMs: 32)
        XCTAssertEqual(c.onThreshold, 0.6)
        XCTAssertEqual(c.onFrames, 2)
        XCTAssertEqual(c.offThreshold, 0.35)
        XCTAssertEqual(c.offMs, 300)
        XCTAssertEqual(c.minSpeechMs, 250)
        XCTAssertEqual(c.maxSegmentMs, 25_000)
    }
}

final class DictationTrimTests: XCTestCase {
    func testSpeechBoundsPadsAndClamps() {
        let closed = VADGateOutput(closed: [VADSegment(start: 16_000, end: 32_000)], openStart: nil)
        XCTAssertEqual(DictationTrim.speechBounds(closed, totalSamples: 40_000), 13_600..<34_400)

        // Speech still open runs to the end of the recording.
        let open = VADGateOutput(closed: [], openStart: 8_000)
        XCTAssertEqual(DictationTrim.speechBounds(open, totalSamples: 20_000), 5_600..<20_000)

        // Padding never reaches before the start.
        let early = VADGateOutput(closed: [VADSegment(start: 1_000, end: 9_000)], openStart: nil)
        XCTAssertEqual(DictationTrim.speechBounds(early, totalSamples: 20_000), 0..<11_400)

        XCTAssertNil(DictationTrim.speechBounds(VADGateOutput(closed: [], openStart: nil), totalSamples: 20_000))
    }

    func testPlanTrimsAroundSpeech() {
        // 62 Silero frames of 512 samples; speech in frames 20..<40.
        let p = Array(repeating: Float(0.05), count: 20) + Array(repeating: Float(0.95), count: 20)
            + Array(repeating: Float(0.05), count: 22)
        let plan = DictationTrim.plan(totalSamples: 62 * 512, probabilities: p)
        XCTAssertEqual(plan, .speech((20 * 512 - 2_400)..<(40 * 512 + 2_400)))
    }

    func testPlanRejectsMisTapsAndSilence() {
        XCTAssertEqual(DictationTrim.plan(totalSamples: 3_000, probabilities: nil), .tooShort)
        XCTAssertEqual(DictationTrim.plan(totalSamples: 62 * 512, probabilities: Array(repeating: 0.05, count: 62)),
                       .noSpeech)
    }

    func testPlanWithoutVADDecodesEverything() {
        XCTAssertEqual(DictationTrim.plan(totalSamples: 32_000, probabilities: nil), .speech(0..<32_000))
        XCTAssertEqual(DictationTrim.plan(totalSamples: 32_000, probabilities: []), .speech(0..<32_000))
    }

    func testScaledAudioContext() {
        XCTAssertEqual(TranscriptionOptions.scaledAudioContext(sampleCount: 16_000 * 8), 528)
        XCTAssertEqual(TranscriptionOptions.scaledAudioContext(sampleCount: 16_000 * 60), 1_500)
    }
}

/// The bundled model manifest and the checksum check every download goes through.
final class SpeechModelManifestTests: XCTestCase {
    func testBundledManifestIsValid() throws {
        let manifest = SpeechModelCatalog.manifest
        XCTAssertEqual(manifest.problems(), [])
        XCTAssertEqual(manifest.release, "models-v1")

        let hebrew = try XCTUnwrap(SpeechModelCatalog.model(id: SpeechModelCatalog.hebrewID))
        XCTAssertFalse(hebrew.detectsLanguage)
        XCTAssertEqual(hebrew.license, "Apache-2.0")
        XCTAssertNotNil(hebrew.vad)
        for file in hebrew.files {
            XCTAssertTrue(file.url.absoluteString.hasPrefix(
                "https://github.com/Jonathan-Asher/codeg-ios/releases/download/models-v1/"), file.url.absoluteString)
        }
        let multilingual = try XCTUnwrap(SpeechModelCatalog.model(id: SpeechModelCatalog.multilingualID))
        XCTAssertTrue(multilingual.detectsLanguage)
    }

    func testLanguageChoosesTheModel() {
        XCTAssertEqual(SpeechModelCatalog.model(for: .hebrew)?.id, SpeechModelCatalog.hebrewID)
        XCTAssertEqual(SpeechModelCatalog.model(for: .english)?.id, SpeechModelCatalog.hebrewID)
        XCTAssertEqual(SpeechModelCatalog.model(for: .auto)?.id, SpeechModelCatalog.multilingualID)
        XCTAssertEqual(DictationLanguage.hebrew.whisperCode, "he")
        XCTAssertEqual(DictationLanguage.english.whisperCode, "en")
        XCTAssertNil(DictationLanguage.auto.whisperCode)
    }

    func testPackLayout() throws {
        let hebrew = try XCTUnwrap(SpeechModelCatalog.model(id: SpeechModelCatalog.hebrewID))
        let pack = SpeechModelCatalog.pack(for: hebrew)
        XCTAssertEqual(pack.directory.lastPathComponent, hebrew.id)
        XCTAssertEqual(pack.directory.deletingLastPathComponent().lastPathComponent, "SpeechToText")
        XCTAssertEqual(pack.totalBytes, hebrew.totalBytes)
        XCTAssertNotEqual(pack.sessionIdentifier, VoiceModelCatalog.pack.sessionIdentifier)
    }

    func testProblemsAreReported() throws {
        let json = """
        {"schema": 1, "release": "x", "models": [
          {"id": "a", "title": "A", "summary": "", "languages": ["he"], "detectsLanguage": false,
           "license": "MIT", "source": "", "weights": "missing.bin", "vad": null,
           "files": [{"path": "a.bin", "url": "http://example.com/a.bin", "size": 0, "sha256": "ABC"}]}
        ]}
        """
        let manifest = try SpeechModelManifest.decode(Data(json.utf8))
        let problems = manifest.problems()
        XCTAssertTrue(problems.contains { $0.contains("weights missing.bin") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("sha256") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("https") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("size 0") }, "\(problems)")
    }

    func testChecksumAcceptsTheFileAndRejectsACorruptOne() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)
        let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

        XCTAssertTrue(ModelPack.sha256Matches(url, expected: hello))
        XCTAssertTrue(ModelPack.sha256Matches(url, expected: hello.uppercased()))
        let ok = await ModelPackStore.verify(url, sha256: hello)
        XCTAssertTrue(ok)

        try Data("hellO".utf8).write(to: url)
        XCTAssertFalse(ModelPack.sha256Matches(url, expected: hello))
        let corrupt = await ModelPackStore.verify(url, sha256: hello)
        XCTAssertFalse(corrupt)

        XCTAssertFalse(ModelPack.sha256Matches(url.appendingPathExtension("missing"), expected: hello))
    }
}

/// Putting a transcript into the composer.
final class DictationTextTests: XCTestCase {
    func testCleanDropsNonSpeechMarkers() {
        XCTAssertEqual(DictationText.clean(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(DictationText.clean("(מוזיקה)"), "")
        XCTAssertEqual(DictationText.clean(" שלום  עולם \n"), "שלום עולם")
        XCTAssertEqual(DictationText.clean("תעדכן את ה-README"), "תעדכן את ה-README")
    }

    func testInsertIntoAnEmptyField() {
        let r = DictationText.insert("שלום", into: "", selection: nil)
        XCTAssertEqual(r.text, "שלום")
        XCTAssertEqual(r.cursor, 4)
    }

    func testAppendAddsASpace() {
        let r = DictationText.insert("world", into: "hello", selection: nil)
        XCTAssertEqual(r.text, "hello world")
        XCTAssertEqual(r.cursor, 11)
    }

    func testInsertAtTheCursor() {
        let r = DictationText.insert("big", into: "a cat", selection: 2..<2)
        XCTAssertEqual(r.text, "a big cat")
        XCTAssertEqual(r.cursor, 5)
    }

    func testReplaceTheSelection() {
        let r = DictationText.insert("dog", into: "a cat!", selection: 2..<5)
        XCTAssertEqual(r.text, "a dog!")
        XCTAssertEqual(r.cursor, 5)
    }

    func testInsideAWordGetsSpacesOnBothSides() {
        let r = DictationText.insert("x", into: "ab", selection: 1..<1)
        XCTAssertEqual(r.text, "a x b")
        XCTAssertEqual(r.cursor, 3)
    }

    func testHebrewInMixedText() {
        let r = DictationText.insert("ותדחוף ל-main", into: "תעדכן את ה-README.", selection: 17..<17)
        XCTAssertEqual(r.text, "תעדכן את ה-README ותדחוף ל-main.")
    }

    func testOffsetsInsideAnEmojiRoundDown() {
        let r = DictationText.insert("hi", into: "👍🏽", selection: 1..<1)
        XCTAssertEqual(r.text, "hi 👍🏽")
    }

    func testOutOfRangeSelectionAppends() {
        let r = DictationText.insert("hi", into: "abc", selection: 10..<12)
        XCTAssertEqual(r.text, "abc hi")
    }

    func testEmptyTranscriptChangesNothing() {
        let r = DictationText.insert("  ", into: "abc", selection: 1..<2)
        XCTAssertEqual(r.text, "abc")
    }

    func testSelectionFromTheTextField() {
        let text = "hello world"
        let start = text.index(text.startIndex, offsetBy: 6)
        let range = DictationText.utf16Range(of: TextSelection(range: start..<text.endIndex), in: text)
        XCTAssertEqual(range, 6..<11)
        XCTAssertEqual(DictationText.utf16Range(of: TextSelection(insertionPoint: start), in: text), 6..<6)
        XCTAssertNil(DictationText.utf16Range(of: nil, in: text))
    }

    func testPromptCarriesTheSessionContext() {
        let prompt = DictationText.prompt(folder: "codeg-ios", session: "Voice typing", language: .hebrew)
        XCTAssertTrue(prompt.hasPrefix("codeg-ios · Voice typing. "), prompt)
        XCTAssertTrue(prompt.contains("README"))
        XCTAssertLessThanOrEqual(prompt.count, DictationText.maxPromptLength)

        let english = DictationText.prompt(folder: nil, session: "  ", language: .english)
        XCTAssertEqual(english, DictationText.englishStyle)

        let same = DictationText.prompt(folder: "x", session: "x", language: .hebrew)
        XCTAssertTrue(same.hasPrefix("x. "), same)

        let long = DictationText.prompt(folder: String(repeating: "f", count: 300),
                                        session: String(repeating: "s", count: 300), language: .hebrew)
        XCTAssertLessThanOrEqual(long.count, DictationText.maxPromptLength)
    }
}

/// Tap to toggle, or hold to talk.
final class DictationPressTests: XCTestCase {
    func testTapLatchesAndASecondTapStops() {
        var press = DictationPress()
        XCTAssertEqual(press.down(at: 0), .start)
        XCTAssertEqual(press.up(at: 0.1), .none)
        XCTAssertTrue(press.isRecording)
        XCTAssertEqual(press.down(at: 3), .stop)
        XCTAssertFalse(press.isRecording)
        XCTAssertEqual(press.up(at: 3.1), .none)
    }

    func testHoldStopsOnRelease() {
        var press = DictationPress()
        XCTAssertEqual(press.down(at: 10), .start)
        XCTAssertEqual(press.up(at: 12), .stop)
        XCTAssertFalse(press.isRecording)
        XCTAssertEqual(press.down(at: 13), .start)
    }

    func testSyncsWithTheRecorder() {
        // A tap whose start failed (no model): the next tap starts again.
        var failed = DictationPress()
        _ = failed.down(at: 0)
        _ = failed.up(at: 0.1)
        failed.sync(isRecording: false)
        XCTAssertEqual(failed.down(at: 5), .start)

        // A hold released during the permission prompt, recording began after:
        // the next tap stops it.
        var late = DictationPress()
        _ = late.down(at: 0)
        XCTAssertEqual(late.up(at: 2), .stop)
        late.sync(isRecording: true)
        XCTAssertEqual(late.down(at: 5), .stop)
    }

    func testResetAfterACancel() {
        var press = DictationPress()
        _ = press.down(at: 0)
        _ = press.up(at: 0.1)
        press.reset()
        XCTAssertFalse(press.isRecording)
        XCTAssertEqual(press.down(at: 1), .start)
    }
}
