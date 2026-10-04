// lid-cli: run the app's own language identification (WhisperLanguageIdentifier,
// SpokenLanguageDecision) after Silero VAD trimming (DictationTrim), as the
// app does, over 16 kHz mono WAV files, for several window lengths. Used to
// pick the language-ID model and threshold (docs/FORK.md, "Hebrew or English").
//
// Build as stt-cli.swift explains (F and D as there). swiftc only runs
// top-level code from a file named main.swift, so copy this file first:
//
//   mkdir -p bench/src && cp scripts/stt-bench/lid-cli.swift bench/src/main.swift
//   swiftc -O -target arm64-apple-macos15.0 -F "$F" -framework whisper \
//     -Xlinker -rpath -Xlinker @executable_path/fw -o bench/lid-cli \
//     bench/src/main.swift $D/SpeechToText.swift $D/WhisperCppEngine.swift \
//     $D/VADGate.swift $D/DictationLanguage.swift
//
// Run:
//
//   bench/lid-cli --model ggml-tiny-q8_0.bin --vad ggml-silero-v5.1.2.bin \
//     --windows 3,5,30 --out tiny-q8_0.tsv clips/*/*.wav
//
// Writes one row per clip and window: clip, speech seconds, window, p(he) and
// p(en) renormalized over the two, milliseconds for the call. The first line
// of the file is the load time. Score with lid-score.py.

import Foundation
import AVFoundation

var opts: [String: String] = [:]; var wavs: [String] = []
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() { if a.hasPrefix("--") { opts[String(a.dropFirst(2))] = it.next() } else { wavs.append(a) } }
func readWav(_ path: String) -> [Float] {
    let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}
let windows = (opts["windows"] ?? "30").split(separator: ",").compactMap { Double($0) }
let lid = WhisperLanguageIdentifier(modelURL: URL(fileURLWithPath: opts["model"]!))
let vad = opts["vad"].flatMap { SileroVAD(modelURL: URL(fileURLWithPath: $0)) }
let sem = DispatchSemaphore(value: 0)
Task {
    let t0 = Date(); try await lid.prepare(); let load = Date().timeIntervalSince(t0)
    var rows = String(format: "#load\t%.3f\n", load)
    // Warm up the GPU pipeline so the first clip's time is not the shader compile.
    _ = try await lid.probabilities([Float](repeating: 0, count: 16_000), among: SpokenLanguageDecision.candidates)
    for path in wavs {
        let samples = readWav(path)
        let plan = DictationTrim.plan(totalSamples: samples.count, probabilities: vad?.speechProbabilities(samples))
        let parts = path.split(separator: "/")
        let id = parts.suffix(2).joined(separator: "/")
        guard case .speech(let r) = plan else { rows += "\(id)\t0\t-\t-\t-\t-\n"; continue }
        let clip = Array(samples[r])
        for w in windows {
            let audio = SpokenLanguageDecision.window(of: clip, seconds: w)
            let t = Date()
            let p = try await lid.probabilities(audio, among: SpokenLanguageDecision.candidates)
            let ms = Date().timeIntervalSince(t) * 1000
            rows += String(format: "%@\t%.2f\t%.0f\t%.4e\t%.4e\t%.1f\n", id, Double(clip.count) / 16000, w,
                           p["he"] ?? -1, p["en"] ?? -1, ms)
        }
    }
    try! rows.write(toFile: opts["out"]!, atomically: true, encoding: .utf8)
    await lid.unload()
    sem.signal()
}
sem.wait()
