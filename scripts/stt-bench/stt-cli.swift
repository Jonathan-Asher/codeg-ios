// stt-cli: run the app's own voice-typing code (WhisperCppEngine, SileroVAD,
// DictationTrim, DictationText) over 16 kHz mono WAV files on a Mac, to compare
// models, quantizations and prompts (docs/FORK.md, "Voice typing").
//
// Build (needs the macOS slice of the whisper.xcframework that
// Packages/WhisperCpp pins; unzip the release zip and point F at it):
//
//   F=/path/to/build-apple/whisper.xcframework/macos-arm64_x86_64
//   D=CodegiOS/Features/Dictation
//   mkdir -p bench/fw && cp -R "$F/whisper.framework" bench/fw/
//   swiftc -O -target arm64-apple-macos15.0 -F "$F" -framework whisper \
//     -Xlinker -rpath -Xlinker @executable_path/fw -o bench/stt-cli \
//     scripts/stt-bench/stt-cli.swift $D/SpeechToText.swift $D/WhisperCppEngine.swift \
//     $D/VADGate.swift $D/DictationText.swift
//
// Run (writes <id>.txt per clip and run.log with timings into --out):
//
//   bench/stt-cli --model ggml-ivrit-large-v3-turbo-q8_0.bin --vad ggml-silero-v5.1.2.bin \
//     --lang he --prompt "…" --out out/q8_0/fleurs clips/fleurs/*.wav
//
// Options: --lang he|en|auto, --prompt TEXT, --ctx scaled (Speakly's
// scaled audio_ctx), --threads N. Convert clips first with
// `afconvert -f WAVE -d LEI16@16000 -c 1 in.wav out.wav`.

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
let out = URL(fileURLWithPath: opts["out"]!); try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let engine = WhisperCppEngine(modelID: "cli", modelURL: URL(fileURLWithPath: opts["model"]!))
let vad = opts["vad"].flatMap { SileroVAD(modelURL: URL(fileURLWithPath: $0)) }
let lang = opts["lang"].flatMap { $0 == "auto" ? nil : $0 }
let sem = DispatchSemaphore(value: 0)
Task {
    let t0 = Date(); try await engine.prepare(); let load = Date().timeIntervalSince(t0)
    var audio = 0.0, decoded = 0.0, decode = 0.0; var langs: [String: Int] = [:]; var log = ""
    for path in wavs {
        let samples = readWav(path); audio += Double(samples.count) / 16000
        let plan = DictationTrim.plan(totalSamples: samples.count, probabilities: vad?.speechProbabilities(samples))
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard case .speech(let r) = plan else { try! "".write(to: out.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8); log += "\(id)\t\(plan)\n"; continue }
        let clip = Array(samples[r])
        var o = TranscriptionOptions(language: lang, prompt: opts["prompt"])
        if let t = opts["threads"].flatMap(Int.init) { o.threads = t }
        if opts["ctx"] == "scaled" { o.audioContext = TranscriptionOptions.scaledAudioContext(sampleCount: clip.count) }
        let res = try await engine.transcribe(clip, options: o)
        decoded += Double(clip.count) / 16000; decode += res.seconds; langs[res.language ?? "-", default: 0] += 1
        let text = DictationText.clean(res.text)
        try! text.write(to: out.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
        log += String(format: "%@\t%.1fs\t%.1fs\t%.2fs\t%@\t%@\n", id, Double(samples.count)/16000, Double(clip.count)/16000, res.seconds, res.language ?? "-", text)
    }
    let summary = String(format: "files=%d load=%.2fs audio=%.1fs decoded=%.1fs decode=%.1fs rtf=%.3f langs=%@\n", wavs.count, load, audio, decoded, decode, decode / max(decoded, 0.001), langs.description)
    try! (summary + log).write(to: out.appendingPathComponent("run.log"), atomically: true, encoding: .utf8)
    print(summary, terminator: "")
    await engine.unload()
    sem.signal()
}
sem.wait()
