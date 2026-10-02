import Foundation
import os
import whisper

private let whisperLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "whisper")

/// whisper.cpp (the official XCFramework, Metal on the GPU) behind
/// ``SpeechToText``. The context is not thread-safe, so every call runs on one
/// serial queue; a decode blocks that queue, never the main thread or the
/// Swift concurrency pool.
final class WhisperCppEngine: SpeechToText, @unchecked Sendable {
    let modelID: String
    let modelURL: URL

    private let queue = DispatchQueue(label: "codeg.whisper", qos: .userInitiated)
    /// Touched only on `queue`.
    private var context: OpaquePointer?
    private let abort = AbortFlag()

    init(modelID: String, modelURL: URL) {
        self.modelID = modelID
        self.modelURL = modelURL
        WhisperLogging.install()
    }

    deinit {
        if let context { whisper_free(context) }
    }

    func prepare() async throws {
        try await onQueue { try self.loadIfNeeded() }
    }

    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> Transcription {
        abort.set(false)
        return try await onQueue { try self.decode(samples, options: options) }
    }

    func cancel() { abort.set(true) }

    func unload() async {
        try? await onQueue {
            if let context = self.context {
                whisper_free(context)
                self.context = nil
            }
        }
    }

    // MARK: - On the queue

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func loadIfNeeded() throws {
        guard context == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw SpeechToTextError.modelMissing }
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        #else
        params.use_gpu = true
        #endif
        params.flash_attn = true
        let started = Date()
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw SpeechToTextError.loadFailed
        }
        self.context = context
        whisperLog.info("Loaded \(self.modelID, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
    }

    private func decode(_ samples: [Float], options: TranscriptionOptions) throws -> Transcription {
        try loadIfNeeded()
        guard let context else { throw SpeechToTextError.loadFailed }
        if abort.isSet { throw SpeechToTextError.cancelled }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threads)
        params.translate = false
        params.no_context = true
        // Decode with timestamp tokens, as Speakly and whisper-cli do. Turning
        // them off measurably hurt this model: English speech came out
        // transliterated or translated into Hebrew.
        params.no_timestamps = false
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_nst = true
        params.greedy.best_of = 1
        params.detect_language = false
        if let audioContext = options.audioContext { params.audio_ctx = audioContext }

        // C strings that must outlive whisper_full.
        let language = strdup(options.language ?? "auto")
        let prompt = options.prompt.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer {
            free(language)
            free(prompt)
        }
        params.language = UnsafePointer(language)
        params.initial_prompt = prompt.map { UnsafePointer($0) }

        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        let started = Date()
        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        if abort.isSet { throw SpeechToTextError.cancelled }
        guard status == 0 else { throw SpeechToTextError.decodeFailed(status) }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        let langID = whisper_full_lang_id(context)
        let detected = langID >= 0 ? whisper_lang_str(langID).map { String(cString: $0) } : nil
        let seconds = Date().timeIntervalSince(started)
        whisperLog.info("Decoded \(Double(samples.count) / 16_000, format: .fixed(precision: 1)) s of audio in \(seconds, format: .fixed(precision: 2)) s")
        return Transcription(text: text, language: detected ?? options.language, seconds: seconds)
    }
}

/// Silero VAD (the ggml build whisper.cpp ships) on the CPU. One probability
/// per 512-sample (32 ms) frame.
final class SileroVAD: VoiceActivityDetector, @unchecked Sendable {
    private let context: OpaquePointer
    private let lock = NSLock()

    init?(modelURL: URL) {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        WhisperLogging.install()
        var params = whisper_vad_default_context_params()
        params.use_gpu = false
        params.n_threads = 2
        guard let context = whisper_vad_init_from_file_with_params(modelURL.path, params) else { return nil }
        self.context = context
    }

    deinit { whisper_vad_free(context) }

    func speechProbabilities(_ samples: [Float]) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return [] }
        let ok = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech(context, buffer.baseAddress, Int32(buffer.count))
        }
        guard ok else { return nil }
        let count = Int(whisper_vad_n_probs(context))
        guard count > 0, let probs = whisper_vad_probs(context) else { return [] }
        return Array(UnsafeBufferPointer(start: probs, count: count))
    }
}

/// Set from any thread, read by whisper.cpp's abort callback.
private final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Route whisper.cpp and ggml logging to the unified log (warnings and
/// errors only) instead of stderr.
private enum WhisperLogging {
    private static let installed: Void = {
        whisper_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, level != GGML_LOG_LEVEL_CONT,
                  let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { whisperLog.warning("\(message, privacy: .public)") }
        }, nil)
    }()

    static func install() { _ = installed }
}
