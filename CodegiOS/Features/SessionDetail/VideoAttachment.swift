import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Where a video comes from

/// A video picked for the next message.
enum VideoSource {
    /// From the photo library: it may still be in iCloud.
    case library(PhotosPickerItem)
    /// A file already on the iPhone (the camera's recording, one from Files),
    /// copied into the app's own folder.
    case file(URL)
}

/// A movie from the photo library, copied out of the picker's temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try VideoAttachmentPrep.keep(received.file))
        }
    }
}

// MARK: - The job

/// One video on its way into a message: fetched from iCloud when it has to
/// be, compressed to H.264 when it is HEVC or too large, and uploaded to
/// codeg's uploads directory (`upload_attachment`), each with its progress.
/// The message links to the uploaded file, as codeg web attaches a file that
/// isn't a picture; it can be sent once the upload is done.
@MainActor
@Observable
final class AttachmentUpload: Identifiable, Hashable {
    enum Phase: Equatable {
        /// Waiting for the picker's copy, or downloading it from iCloud.
        case fetching(Double?)
        case compressing(Double)
        case uploading(Double)
        case done
        case failed(String)
    }

    nonisolated let id = UUID()
    private(set) var phase: Phase = .fetching(nil)
    private(set) var uploaded: UploadedAttachment?
    private(set) var poster: UIImage?
    private(set) var duration: TimeInterval?
    /// "Compressed to 720p H.264" or "Original", for the chip's description.
    private(set) var note: String?
    private(set) var displayName: String

    @ObservationIgnored private let source: VideoSource
    @ObservationIgnored private let uploader: any AttachmentUploading
    @ObservationIgnored private let bucket: String?
    @ObservationIgnored private let preparer: any VideoPreparing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var localFile: URL?
    @ObservationIgnored private var prepared: PreparedVideo?

    init(source: VideoSource, displayName: String = "Video", uploader: any AttachmentUploading, bucket: String?,
         preparer: any VideoPreparing = VideoAttachmentPrep()) {
        self.source = source
        self.displayName = displayName
        self.uploader = uploader
        self.bucket = bucket
        self.preparer = preparer
    }

    nonisolated static func == (lhs: AttachmentUpload, rhs: AttachmentUpload) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var isDone: Bool { uploaded != nil }
    var isRunning: Bool {
        switch phase {
        case .fetching, .compressing, .uploading: return true
        case .done, .failed: return false
        }
    }
    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Start, or start over after a failure (a file already fetched or
    /// compressed isn't done again).
    func start() {
        guard task == nil, uploaded == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    /// Wait for the job to end (tests).
    func finish() async {
        while let task { await task.value }
    }

    /// Stop and throw away what it made on the iPhone.
    func cancel() {
        task?.cancel()
        task = nil
        cleanUp()
    }

    private func run() async {
        do {
            if prepared == nil {
                let file: URL
                if let localFile {
                    file = localFile
                } else {
                    phase = .fetching(nil)
                    file = try await fetch()
                    localFile = file
                }
                displayName = file.lastPathComponent
                phase = .compressing(0)
                let result = try await preparer.prepare(file) { [weak self] fraction in
                    Task { @MainActor in self?.progress(.compressing(fraction)) }
                }
                prepared = result
                poster = result.poster
                duration = result.duration
                note = result.note
                displayName = result.name
            }
            guard let prepared else { return }
            try Task.checkCancellation()
            phase = .uploading(0)
            let uploaded = try await uploader.uploadAttachment(
                fileURL: prepared.url, fileName: prepared.name, mimeType: prepared.mimeType, bucket: bucket
            ) { [weak self] fraction in
                Task { @MainActor in self?.progress(.uploading(fraction)) }
            }
            try Task.checkCancellation()
            self.uploaded = uploaded
            displayName = uploaded.name
            phase = .done
            cleanUp()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Late progress never moves a finished or failed job back.
    private func progress(_ next: Phase) {
        switch (phase, next) {
        case (.compressing, .compressing), (.uploading, .uploading), (.fetching, .fetching):
            phase = next
        default:
            break
        }
    }

    private func fetch() async throws -> URL {
        switch source {
        case .file(let url):
            return url
        case .library(let item):
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    let loading = item.loadTransferable(type: PickedMovie.self) { result in
                        switch result {
                        case .success(let movie?): continuation.resume(returning: movie.url)
                        case .success(nil):
                            continuation.resume(throwing: VideoAttachmentError.unreadable)
                        case .failure(let error):
                            continuation.resume(throwing: VideoAttachmentError.fetch(error.localizedDescription))
                        }
                    }
                    // An iCloud video downloads first: follow its progress.
                    Task { @MainActor [weak self] in
                        while !loading.isFinished, !loading.isCancelled {
                            let fraction = loading.totalUnitCount > 0 ? loading.fractionCompleted : nil
                            self?.progress(.fetching(fraction))
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                }
            } onCancel: {
                // The picker's load can't be cancelled from here; its file is
                // thrown away when it arrives.
            }
        }
    }

    /// Delete the copies this job made; only ever inside its own folder.
    private func cleanUp() {
        for file in [prepared?.url, localFile].compactMap({ $0 }) {
            let folder = file.deletingLastPathComponent()
            guard VideoAttachmentPrep.isWorkDirectory(folder) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
        prepared = nil
        localFile = nil
    }
}

// MARK: - Preparing a video

enum VideoAttachmentError: LocalizedError, Equatable {
    case unreadable
    case noVideo
    case fetch(String)
    /// Even at the smallest size it would be over the server's limit.
    case tooLong(estimate: Int64, limit: Int64)
    case export(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The video couldn't be read."
        case .noVideo: return "This file has no video in it."
        case .fetch(let detail): return "The video couldn't be loaded from the library: \(detail)"
        case .tooLong(let estimate, let limit):
            let size = ByteCountFormatter.string(fromByteCount: estimate, countStyle: .memory)
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
            return "Too long to send: even at 360p it is about \(size), and the codeg server takes attachments up to \(cap). Trim it in Photos first."
        case .export(let detail): return "The video couldn't be compressed: \(detail)"
        }
    }
}

/// A video ready to upload.
struct PreparedVideo: Sendable {
    let url: URL
    let name: String
    let mimeType: String
    let size: Int64
    let duration: TimeInterval?
    let poster: UIImage?
    let note: String
}

protocol VideoPreparing: Sendable {
    func prepare(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedVideo
}

/// Turns a picked video into one codeg takes: an H.264 MP4 or MOV under
/// ``maxBytes`` is sent as it is; HEVC, another codec or a larger file is
/// exported to H.264 MP4 at 720p, or at 540p, 480p or AVFoundation's medium
/// quality (about 360p) when the larger size would still be over the limit
/// (AVFoundation's estimate first, the real size after).
struct VideoAttachmentPrep: VideoPreparing {
    var maxBytes: Int64 = AttachmentUploadLimits.maxBytes

    /// Presets from the preferred size down, each H.264.
    static let presets: [(name: String, label: String)] = [
        (AVAssetExportPreset1280x720, "720p"),
        (AVAssetExportPreset960x540, "540p"),
        (AVAssetExportPreset640x480, "480p"),
        (AVAssetExportPresetMediumQuality, "360p"),
    ]

    /// The folder picked videos are copied to and compressed in.
    static func workDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-videos", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A folder ``workDirectory()`` made.
    static func isWorkDirectory(_ folder: URL) -> Bool {
        folder.deletingLastPathComponent().lastPathComponent == "attachment-videos"
            && folder.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    /// Copy `file` (a picker's or the camera's temporary file) into a folder of our own.
    static func keep(_ file: URL) throws -> URL {
        let destination = workDirectory().appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        default: return "video/mp4"
        }
    }

    func prepare(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedVideo {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoAttachmentError.noVideo
        }
        let duration = (try? await asset.load(.duration)).flatMap { $0.isNumeric && $0.seconds > 0 ? $0.seconds : nil }
        let codec = (try? await track.load(.formatDescriptions))?.first.map(CMFormatDescriptionGetMediaSubType)
        let size = Self.size(of: file)
        let ext = file.pathExtension.lowercased()

        if codec == kCMVideoCodecType_H264, ["mp4", "m4v", "mov"].contains(ext), size > 0, size <= maxBytes {
            progress(1)
            return PreparedVideo(url: file, name: file.lastPathComponent, mimeType: Self.mimeType(forExtension: ext),
                                 size: size, duration: duration, poster: await Self.poster(of: asset, duration: duration),
                                 note: "Original")
        }

        let base = file.deletingPathExtension().lastPathComponent
        let output = file.deletingLastPathComponent().appendingPathComponent("\(base).mp4")
        var smallest: Int64 = 0
        for preset in Self.presets {
            try Task.checkCancellation()
            guard let session = AVAssetExportSession(asset: asset, presetName: preset.name) else { continue }
            session.shouldOptimizeForNetworkUse = true
            let estimate = (try? await session.estimatedOutputFileLengthInBytes) ?? 0
            smallest = estimate
            // Leave room: the estimate is only an estimate.
            if estimate > 0, Double(estimate) > Double(maxBytes) * 0.92 { continue }
            try? FileManager.default.removeItem(at: output)
            try await Self.export(session, to: output, progress: progress)
            let written = Self.size(of: output)
            guard written > 0 else { throw VideoAttachmentError.export("nothing was written") }
            if written > maxBytes {
                smallest = written
                continue
            }
            return PreparedVideo(url: output, name: output.lastPathComponent, mimeType: "video/mp4", size: written,
                                 duration: duration,
                                 poster: await Self.poster(of: AVURLAsset(url: output), duration: duration),
                                 note: "Compressed to \(preset.label) H.264")
        }
        throw VideoAttachmentError.tooLong(estimate: smallest, limit: maxBytes)
    }

    private static func export(_ session: AVAssetExportSession, to output: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: output, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VideoAttachmentError.export(error.localizedDescription)
        }
        progress(1)
    }

    static func size(of file: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A frame near the start, for the chip and the optimistic message.
    static func poster(of asset: AVAsset, duration: TimeInterval?) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let seconds = duration.map { min(0.5, $0 / 2) } ?? 0
        guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else {
            return nil
        }
        return UIImage(cgImage: frame)
    }
}
