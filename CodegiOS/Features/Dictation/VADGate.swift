import Foundation

/// Hysteresis gate over per-frame speech probabilities, ported from Speakly's
/// `crates/engine/src/vad/gate.rs`. Pure and side-effect free, so the policy is
/// unit-tested with synthetic sequences; Silero VAD (``SileroVAD``) produces
/// the probabilities on the device.
struct VADGateConfig: Equatable, Sendable {
    /// Probability at or above which a frame counts toward speech onset.
    var onThreshold: Float
    /// Consecutive onset frames required to open a segment.
    var onFrames: Int
    /// Probability below which a frame counts as silence while in speech.
    var offThreshold: Float
    /// Sustained silence needed to close a segment.
    var offMs: Int
    /// Closed segments shorter than this are dropped (breath, taps on the glass).
    var minSpeechMs: Int
    /// Force a split when an open segment grows past this.
    var maxSegmentMs: Int
    /// Duration of one probability frame (Silero at 16 kHz: 512 samples = 32 ms).
    var frameMs: Int

    /// Speakly's dictation policy: open at 0.6 for 2 frames, close below 0.35
    /// after 300 ms, drop speech under 250 ms, split at 25 s.
    static func dictation(frameMs: Int) -> VADGateConfig {
        VADGateConfig(onThreshold: 0.6, onFrames: 2, offThreshold: 0.35, offMs: 300,
                      minSpeechMs: 250, maxSegmentMs: 25_000, frameMs: max(1, frameMs))
    }
}

/// A speech segment in frame (or sample) indices: `[start, end)`.
struct VADSegment: Equatable, Sendable {
    var start: Int
    var end: Int
}

struct VADGateOutput: Equatable, Sendable {
    /// Segments that ended in sustained silence.
    var closed: [VADSegment]
    /// Start of speech still open at the end of the sequence.
    var openStart: Int?
}

enum VADGate {
    private enum State {
        case silence
        case candidate(start: Int, run: Int)
        case speech(start: Int, quietRun: Int)
    }

    /// Run the gate over `probs`. Stateless across calls.
    static func run(_ config: VADGateConfig, probabilities probs: [Float]) -> VADGateOutput {
        let frameMs = max(1, config.frameMs)
        let offFrames = max(1, config.offMs / frameMs)
        let minSpeechFrames = max(1, config.minSpeechMs / frameMs)
        let maxSegmentFrames = max(1, config.maxSegmentMs / frameMs)

        var closed: [VADSegment] = []
        var state = State.silence

        for (i, p) in probs.enumerated() {
            switch state {
            case .silence:
                if p >= config.onThreshold {
                    state = config.onFrames <= 1 ? .speech(start: i, quietRun: 0) : .candidate(start: i, run: 1)
                }
            case .candidate(let start, let run):
                if p >= config.onThreshold {
                    state = run + 1 >= config.onFrames
                        ? .speech(start: start, quietRun: 0)
                        : .candidate(start: start, run: run + 1)
                } else {
                    state = .silence
                }
            case .speech(let start, let quietRun):
                if p < config.offThreshold {
                    let quiet = quietRun + 1
                    if quiet >= offFrames {
                        // Close at the last speech frame.
                        let end = i + 1 - quiet
                        if end - start >= minSpeechFrames {
                            closed.append(VADSegment(start: start, end: end))
                        }
                        state = .silence
                    } else {
                        state = .speech(start: start, quietRun: quiet)
                    }
                } else if i + 1 - start >= maxSegmentFrames {
                    // Forced split: close here, stay in speech from the next frame.
                    closed.append(VADSegment(start: start, end: i + 1))
                    state = .speech(start: i + 1, quietRun: 0)
                } else {
                    state = .speech(start: start, quietRun: 0)
                }
            }
        }

        switch state {
        case .speech(let start, _), .candidate(let start, _):
            return VADGateOutput(closed: closed, openStart: start)
        case .silence:
            return VADGateOutput(closed: closed, openStart: nil)
        }
    }
}

/// What to decode out of a finished recording (Speakly's dictation finalise:
/// trim around the speech with some padding, then one decode over it).
enum DictationTrim {
    static let sampleRate = 16_000
    /// Padding kept after the detected speech.
    static let padMs = 150
    /// Padding kept before the first detected speech. Longer than Speakly's
    /// 150 ms: the gate opens only once speech is clear, and a soft first
    /// syllable before that was being cut.
    static let leadPadMs = 300
    /// Recordings shorter than this are a mis-tap, not dictation.
    static let minRecordingMs = 400
    /// After trimming, less speech than this is not worth a decode.
    static let minSpeechMs = 250

    enum Outcome: Equatable, Sendable {
        /// The recording was shorter than ``minRecordingMs``.
        case tooShort
        /// The VAD found no speech (or too little to decode).
        case noSpeech
        /// Decode `samples[range]`.
        case speech(Range<Int>)
    }

    /// Trim bounds around all detected speech, padded by `leadPadMs` before
    /// and `padMs` after, in samples. `nil` means no speech at all. Port of
    /// Speakly's `speech_bounds`.
    static func speechBounds(_ output: VADGateOutput, totalSamples: Int, leadPadMs: Int = leadPadMs,
                             padMs: Int = padMs) -> Range<Int>? {
        let lead = leadPadMs * sampleRate / 1000
        let pad = padMs * sampleRate / 1000
        let starts = [output.closed.first?.start, output.openStart].compactMap { $0 }
        guard let first = starts.min() else { return nil }
        let ends = [output.closed.last?.end, output.openStart.map { _ in totalSamples }].compactMap { $0 }
        let last = ends.max() ?? totalSamples
        let lower = max(0, first - lead)
        let upper = min(totalSamples, last + pad)
        return lower < upper ? lower..<upper : nil
    }

    /// Map frame-indexed gate output onto samples. The frame size is derived
    /// from the counts rather than assumed, as Speakly does.
    static func sampleSegments(_ output: VADGateOutput, totalSamples: Int, probabilityCount: Int) -> VADGateOutput {
        let frame = max(1, totalSamples / max(1, probabilityCount))
        return VADGateOutput(
            closed: output.closed.map { VADSegment(start: $0.start * frame, end: min(totalSamples, $0.end * frame)) },
            openStart: output.openStart.map { $0 * frame })
    }

    /// Decide what to decode. `probabilities` is `nil` when no VAD is
    /// available; the whole recording is then decoded untrimmed.
    static func plan(totalSamples: Int, probabilities: [Float]?) -> Outcome {
        guard totalSamples >= minRecordingMs * sampleRate / 1000 else { return .tooShort }
        guard let probs = probabilities, !probs.isEmpty else { return .speech(0..<totalSamples) }
        let frame = max(1, totalSamples / probs.count)
        let frameMs = max(1, frame * 1000 / sampleRate)
        let gate = VADGate.run(.dictation(frameMs: frameMs), probabilities: probs)
        let samples = sampleSegments(gate, totalSamples: totalSamples, probabilityCount: probs.count)
        guard let range = speechBounds(samples, totalSamples: totalSamples) else { return .noSpeech }
        guard range.count >= minSpeechMs * sampleRate / 1000 else { return .noSpeech }
        return .speech(range)
    }
}
