import AVFoundation
import Foundation

/// Turns any audio file iOS can read into a notification sound: a Core Audio
/// file of 16-bit linear PCM, mono, 44.1 kHz, at most 29.5 s (iOS plays the
/// default sound instead of one of 30 s or more), with a short fade where a
/// long one is cut.
enum NotificationSoundImporter {
    static let maxSeconds: Double = 29.5
    static let sampleRate: Double = 44_100
    /// The fade at the end of a sound that was cut.
    static let fadeSeconds: Double = 0.3

    struct Result: Equatable, Sendable {
        let seconds: Double
        let trimmed: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case silent

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This file has no audio iOS can read.")
            case .silent: String(localized: "This file has no sound in it.")
            }
        }
    }

    /// Convert `source` into `directory/fileName`, creating the directory
    /// (with no file protection, so iOS can play the sound while the iPhone
    /// is locked). A failed conversion leaves no file behind.
    static func convert(from source: URL, into directory: URL, fileName: String) throws -> Result {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw Failure.unreadable
        }
        let sourceSeconds = Double(input.length) / input.fileFormat.sampleRate
        guard input.length > 0, sourceSeconds > 0 else { throw Failure.silent }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
            throw Failure.unreadable
        }
        converter.downmix = true

        let maxFrames = AVAudioFrameCount(maxSeconds * sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: maxFrames) else {
            throw Failure.unreadable
        }
        let chunk: AVAudioFrameCount = 8192
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk),
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else {
            throw Failure.unreadable
        }
        var finished = false
        while output.frameLength < maxFrames {
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: readBuffer, frameCount: chunk)
                } catch {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if readBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return readBuffer
            }
            if status == .error { throw Failure.unreadable }
            let take = min(converted.frameLength, maxFrames - output.frameLength)
            if take > 0, let from = converted.floatChannelData?[0], let to = output.floatChannelData?[0] {
                (to + Int(output.frameLength)).update(from: from, count: Int(take))
                output.frameLength += take
            }
            if status == .endOfStream || (converted.frameLength == 0 && finished) { break }
        }
        guard output.frameLength > 0 else { throw Failure.silent }
        let trimmed = sourceSeconds > maxSeconds
        if trimmed { fadeOut(output) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            // The file closes when `file` goes, at the end of this block.
            let file = try AVAudioFile(forWriting: destination, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: output)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unreadable
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: destination.path)
        return Result(seconds: Double(output.frameLength) / sampleRate, trimmed: trimmed)
    }

    /// A raised-cosine fade over the last ``fadeSeconds``.
    static func fadeOut(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let fade = min(count, Int(fadeSeconds * buffer.format.sampleRate))
        guard fade > 0 else { return }
        for i in 0..<fade {
            let gain = Float(0.5 + 0.5 * cos(Double.pi * Double(i + 1) / Double(fade)))
            samples[count - fade + i] *= gain
        }
    }
}
