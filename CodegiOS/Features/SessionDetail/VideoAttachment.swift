import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Where a file comes from

/// A video or an audio file picked for the next message.
enum AttachmentSource {
    /// A video from the photo library: it may still be in iCloud.
    case library(PhotosPickerItem)
    /// A file already on the iPhone (the camera's recording, one from Files),
    /// copied into the app's own folder.
    case file(URL)

    /// An audio file from Files; everything else is a video.
    var isAudio: Bool {
        if case .file(let url) = self { return Self.isAudioFile(url) }
        return false
    }

    static func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) && !type.conforms(to: .movie)
    }
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

/// How a video goes to a server that takes large ones (fork.191 and later).
/// The choice is remembered for the next video.
enum VideoQuality: String, CaseIterable, Sendable {
    /// As the iPhone has it, whatever the codec; compressed only when it is
    /// over the server's limit.
    case original
    /// H.264 MP4 at 720p (smaller ones as they are): a quicker upload that
    /// plays in any browser.
    case compressed

    static let preferenceKey = "attachments.videoQuality"

    static var preferred: VideoQuality {
        get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(VideoQuality.init(rawValue:)) ?? .original }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    var label: String {
        switch self {
        case .original: return "Original"
        case .compressed: return "Compressed (720p)"
        }
    }
}

// MARK: - The job

/// One video or audio file on its way into a message: fetched from iCloud
/// when it has to be, compressed when it must be, and uploaded to codeg's
/// uploads directory, each with its progress. The message links to the
/// uploaded file, as codeg web attaches a file that isn't a picture; it can be
/// sent once the upload is done.
///
/// A server that says its limits (`upload_limits`, fork.191) takes video and
/// audio up to its media limit (1 GiB by default) and a resumable upload:
/// the file goes in pieces (``ResumableTransfer``), a dropped connection
/// carries on where the server stopped, and when iOS is about to suspend the
/// app the upload pauses and goes on once the app is back
/// (``AttachmentUploadLifecycle``). Any other server gets 1.3.14's upload: 20 MiB,
/// HEVC and larger files compressed to fit, one multipart request.
@MainActor
@Observable
final class AttachmentUpload: Identifiable, Hashable {
    enum Kind: Sendable, Equatable {
        case video
        case audio
    }

    enum WaitReason: Sendable, Equatable {
        /// The network dropped; it tries again on its own.
        case network
        /// The app left the screen and iOS was about to suspend it; it goes on
        /// when the app is back.
        case background
    }

    enum Phase: Equatable {
        /// Waiting for the picker's copy, or downloading it from iCloud.
        case fetching(Double?)
        case compressing(Double)
        case uploading(Double)
        /// Paused part way through the upload.
        case waiting(Double, WaitReason)
        case done
        case failed(String)
    }

    nonisolated let id = UUID()
    let kind: Kind
    private(set) var phase: Phase = .fetching(nil)
    private(set) var uploaded: UploadedAttachment?
    private(set) var poster: UIImage?
    private(set) var duration: TimeInterval?
    /// "Compressed to 720p H.264" or "Original", for the chip's description.
    private(set) var note: String?
    private(set) var displayName: String
    /// The bytes the server has, and the file's size, while it uploads.
    private(set) var sentBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    /// What the server takes, once asked.
    private(set) var limits: ServerUploadLimits?
    private(set) var quality: VideoQuality

    @ObservationIgnored private let source: AttachmentSource
    @ObservationIgnored private let uploader: any AttachmentUploading
    @ObservationIgnored private let bucket: String?
    @ObservationIgnored private let preparer: any VideoPreparing
    @ObservationIgnored private let lifecycle: AttachmentUploadLifecycle
    @ObservationIgnored private var task: Task<Void, Never>?
    /// A run that was stopped and may still be winding down.
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var runToken: UUID?
    @ObservationIgnored private var localFile: URL?
    @ObservationIgnored private var prepared: PreparedMedia?
    @ObservationIgnored private var transfer: ResumableTransfer?
    @ObservationIgnored private var suspended = false
    /// The waits between tries after a failure (tests shorten them).
    @ObservationIgnored var retryBackoff: [Duration]?

    init(source: AttachmentSource, displayName: String = "Video", uploader: any AttachmentUploading,
         bucket: String?, preparer: any VideoPreparing = VideoAttachmentPrep(), quality: VideoQuality = .original,
         lifecycle: AttachmentUploadLifecycle? = nil) {
        self.source = source
        self.kind = source.isAudio ? .audio : .video
        self.displayName = displayName
        self.uploader = uploader
        self.bucket = bucket
        self.preparer = preparer
        self.quality = quality
        self.lifecycle = lifecycle ?? .shared
    }

    nonisolated static func == (lhs: AttachmentUpload, rhs: AttachmentUpload) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var isDone: Bool { uploaded != nil }
    var isRunning: Bool {
        switch phase {
        case .fetching, .compressing, .uploading, .waiting: return true
        case .done, .failed: return false
        }
    }
    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
    /// The Original / Compressed choice applies: a video, not uploaded yet, to
    /// a server that takes large ones.
    var offersQuality: Bool { kind == .video && uploaded == nil && (limits?.isReported ?? false) }
    /// The upload carries on from where the server stopped after a drop.
    var isResumable: Bool { limits?.resumable != nil }

    /// Start, or start over after a failure or a pause (a file already
    /// fetched or compressed isn't done again, and a resumable upload goes on
    /// from what the server holds).
    func start() {
        guard task == nil, uploaded == nil else { return }
        suspended = false
        let previous = stopping
        stopping = nil
        let token = UUID()
        runToken = token
        lifecycle.began(self)
        task = Task { [weak self] in
            // A stopped run gives up its request first.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.run()
            guard let self, self.runToken == token else { return }
            self.task = nil
            self.runToken = nil
            self.lifecycle.ended(self)
        }
    }

    /// Wait for the job to end (tests).
    func finish() async {
        while let task { await task.value }
    }

    /// Stop and throw away what it made, on the iPhone and on the server.
    func cancel() {
        stopRun()
        stopping?.cancel()
        stopping = nil
        suspended = false
        transfer?.discard()
        transfer = nil
        lifecycle.forget(self)
        cleanUp()
    }

    /// iOS is about to suspend the app: stop the request (its bytes so far
    /// stay on the server) and wait for the app to come back.
    func suspendForBackground() {
        guard task != nil, uploaded == nil else { return }
        suspended = true
        stopRun()
        phase = .waiting(fraction, .background)
    }

    /// The app is back: carry on from where the server stopped.
    func resumeAfterBackground() {
        guard suspended else { return }
        start()
    }

    /// Send the video as it is, or compressed. Starts over from the picked
    /// file; the server drops what it had of the other one.
    func setQuality(_ next: VideoQuality) {
        guard offersQuality, next != quality else { return }
        quality = next
        stopRun()
        transfer?.discard()
        transfer = nil
        if let prepared, prepared.url != localFile {
            let folder = prepared.url.deletingLastPathComponent()
            if VideoAttachmentPrep.isExportDirectory(folder) { try? FileManager.default.removeItem(at: folder) }
        }
        prepared = nil
        note = nil
        sentBytes = 0
        totalBytes = 0
        start()
    }

    private func stopRun() {
        guard let task else { return }
        task.cancel()
        stopping = task
        self.task = nil
        runToken = nil
    }

    private var fraction: Double {
        switch phase {
        case .uploading(let value), .waiting(let value, _): return value
        case .done: return 1
        default: return 0
        }
    }

    private func run() async {
        // A run stopped by a change of quality must not finish with the other one.
        let wanted = quality
        do {
            try Task.checkCancellation()
            let limits: ServerUploadLimits
            if prepared == nil {
                let file: URL
                if let localFile {
                    file = localFile
                    limits = try await knownLimits()
                } else {
                    phase = .fetching(nil)
                    // Ask the server while the picker's copy arrives.
                    async let asked = Self.limits(self.limits, from: uploader)
                    let fetched = try await fetch()
                    localFile = fetched
                    file = fetched
                    limits = try await asked
                    self.limits = limits
                }
                try Task.checkCancellation()
                displayName = file.lastPathComponent
                let result: PreparedMedia
                switch kind {
                case .video:
                    phase = .compressing(0)
                    result = try await preparer.prepare(file, policy: VideoPolicy(limits: limits, quality: quality)) {
                        [weak self] fraction in
                        Task { @MainActor in self?.progress(.compressing(fraction)) }
                    }
                case .audio:
                    result = try await AudioAttachmentPrep.prepare(file, maxBytes: limits.maxMediaBytes)
                }
                guard quality == wanted else { throw CancellationError() }
                prepared = result
                poster = result.poster
                duration = result.duration
                note = result.note
                displayName = result.name
            } else {
                limits = try await knownLimits()
            }
            guard let prepared else { return }
            try Task.checkCancellation()
            totalBytes = prepared.size

            let uploaded: UploadedAttachment
            if limits.resumable != nil {
                let transfer = self.transfer ?? ResumableTransfer(
                    file: prepared.url, size: prepared.size, fileName: prepared.name, mimeType: prepared.mimeType,
                    bucket: bucket, chunkBytes: limits.chunkBytes, api: uploader)
                if let retryBackoff { transfer.backoff = retryBackoff }
                self.transfer = transfer
                phase = .uploading(prepared.size > 0 ? Double(transfer.offset) / Double(prepared.size) : 0)
                uploaded = try await transfer.run(
                    onProgress: { [weak self] bytes in self?.sent(bytes) },
                    onWaiting: { [weak self] in self?.waitForNetwork() })
                self.transfer = nil
            } else {
                phase = .uploading(0)
                uploaded = try await uploader.uploadAttachment(
                    fileURL: prepared.url, fileName: prepared.name, mimeType: prepared.mimeType, bucket: bucket,
                    maxBytes: limits.limit(forMimeType: prepared.mimeType)
                ) { [weak self] fraction in
                    Task { @MainActor in self?.progress(.uploading(fraction)) }
                }
            }
            // Kept even when the run was paused meanwhile: the server has it.
            guard quality == wanted else { throw CancellationError() }
            self.uploaded = uploaded
            sentBytes = totalBytes
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

    private func knownLimits() async throws -> ServerUploadLimits {
        if let limits { return limits }
        let asked = try await uploader.attachmentUploadLimits()
        limits = asked
        return asked
    }

    nonisolated private static func limits(_ known: ServerUploadLimits?,
                                           from uploader: any AttachmentUploading) async throws -> ServerUploadLimits {
        if let known { return known }
        return try await uploader.attachmentUploadLimits()
    }

    /// Late progress never moves a finished, failed or paused job back.
    private func progress(_ next: Phase) {
        switch (phase, next) {
        case (.compressing, .compressing), (.uploading, .uploading), (.fetching, .fetching):
            phase = next
        default:
            break
        }
    }

    /// The server has (or has been sent) `bytes` of the file.
    private func sent(_ bytes: Int64) {
        sentBytes = bytes
        let value = totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : 0
        switch phase {
        case .uploading, .waiting(_, .network): phase = .uploading(value)
        default: break
        }
    }

    private func waitForNetwork() {
        if case .uploading(let value) = phase { phase = .waiting(value, .network) }
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
            var folder = file.deletingLastPathComponent()
            if VideoAttachmentPrep.isExportDirectory(folder) { folder = folder.deletingLastPathComponent() }
            guard VideoAttachmentPrep.isWorkDirectory(folder) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
        prepared = nil
        localFile = nil
    }
}

// MARK: - Uploads and the app's lifecycle

/// Keeps attachment uploads going for the time iOS gives an app that leaves
/// the screen (`beginBackgroundTask`), pauses them just before that time runs
/// out, and resumes them when the app comes back to the foreground. A
/// resumable upload then carries on from the bytes the server holds.
@MainActor
final class AttachmentUploadLifecycle {
    static let shared = AttachmentUploadLifecycle()

    private struct Weak {
        weak var job: AttachmentUpload?
    }

    private var active: [ObjectIdentifier: Weak] = [:]
    private var paused: [ObjectIdentifier: Weak] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observer: NSObjectProtocol?

    init(observesApp: Bool = true) {
        guard observesApp else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumePaused() }
        }
    }

    /// Jobs uploading now, and paused ones (tests).
    var activeCount: Int { active.values.filter { $0.job != nil }.count }
    var pausedCount: Int { paused.values.filter { $0.job != nil }.count }

    func began(_ job: AttachmentUpload) {
        let key = ObjectIdentifier(job)
        paused[key] = nil
        active[key] = Weak(job: job)
        holdBackgroundTime()
    }

    func ended(_ job: AttachmentUpload) {
        active[ObjectIdentifier(job)] = nil
        releaseIfIdle()
    }

    func forget(_ job: AttachmentUpload) {
        active[ObjectIdentifier(job)] = nil
        paused[ObjectIdentifier(job)] = nil
        releaseIfIdle()
    }

    /// The background time is about to run out: pause every upload.
    func expire() {
        let jobs = active.values.compactMap(\.job)
        active = [:]
        for job in jobs {
            job.suspendForBackground()
            paused[ObjectIdentifier(job)] = Weak(job: job)
        }
        endBackgroundTime()
    }

    /// The app is back: every paused upload goes on.
    func resumePaused() {
        let jobs = paused.values.compactMap(\.job)
        paused = [:]
        for job in jobs { job.resumeAfterBackground() }
    }

    private func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Attachment upload") { [weak self] in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    private func releaseIfIdle() {
        active = active.filter { $0.value.job != nil }
        if active.isEmpty { endBackgroundTime() }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Preparing a video

enum VideoAttachmentError: LocalizedError, Equatable {
    case unreadable
    case noVideo
    case fetch(String)
    /// Even at the smallest size it would be over the server's limit.
    case tooLong(estimate: Int64, limit: Int64)
    /// Over the server's limit, and not a file the iPhone can compress.
    case tooLarge(size: Int64, limit: Int64)
    case export(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file couldn't be read."
        case .noVideo: return "This file has no video in it."
        case .fetch(let detail): return "The video couldn't be loaded from the library: \(detail)"
        case .tooLong(let estimate, let limit):
            let size = ByteCountFormatter.string(fromByteCount: estimate, countStyle: .memory)
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
            return "Too long to send: even at 360p it is about \(size), and the codeg server takes attachments up to \(cap). Trim it in Photos first."
        case .tooLarge(let size, let limit):
            let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .memory)
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
            return "Too large to send: it is \(bytes), and the codeg server takes attachments up to \(cap)."
        case .export(let detail): return "The video couldn't be compressed: \(detail)"
        }
    }
}

/// A video or audio file ready to upload.
struct PreparedMedia: Sendable {
    let url: URL
    let name: String
    let mimeType: String
    let size: Int64
    let duration: TimeInterval?
    let poster: UIImage?
    let note: String
}

/// How a video is made ready for one server.
struct VideoPolicy: Equatable, Sendable {
    /// The server's limit for a video.
    var maxBytes: Int64
    /// The server says its limits (fork.191 and later): a video in any codec
    /// and container goes as it is when it fits. Before that only H.264 in
    /// MP4, MOV or M4V did (1.3.14).
    var keepsAnyCodec: Bool
    var quality: VideoQuality

    /// A server before fork.191: 20 MiB, H.264 only (1.3.14).
    static let legacy = VideoPolicy(maxBytes: AttachmentUploadLimits.maxBytes, keepsAnyCodec: false, quality: .original)

    init(maxBytes: Int64, keepsAnyCodec: Bool, quality: VideoQuality) {
        self.maxBytes = maxBytes
        self.keepsAnyCodec = keepsAnyCodec
        self.quality = quality
    }

    init(limits: ServerUploadLimits, quality: VideoQuality) {
        maxBytes = limits.maxMediaBytes
        keepsAnyCodec = limits.isReported
        self.quality = limits.isReported ? quality : .original
    }

    /// The export sizes tried, the preferred first: 1080p first for an
    /// original over a large limit, 720p otherwise (1.3.14's ladder).
    var presets: [(name: String, label: String)] {
        if keepsAnyCodec, quality == .original {
            return [(AVAssetExportPreset1920x1080, "1080p")] + VideoAttachmentPrep.presets
        }
        return VideoAttachmentPrep.presets
    }
}

protocol VideoPreparing: Sendable {
    func prepare(_ file: URL, policy: VideoPolicy,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedMedia
}

/// Turns a picked video into one codeg takes.
///
/// - **A server that says its limits** (fork.191, 1 GiB for video by default):
///   *Original* sends the file as the iPhone has it, HEVC included, whenever
///   it is within the limit; only a larger one is exported to H.264 MP4 at
///   1080p, or 720p, 540p, 480p or about 360p when that is still over.
///   *Compressed* exports to H.264 MP4 at 720p (down the same ladder to fit);
///   an H.264 video already 720p or smaller goes as it is.
/// - **Any other server** (20 MiB): an H.264 MP4, MOV or M4V within the limit
///   goes as it is; HEVC, another codec or a larger file is exported to H.264
///   MP4 at 720p, or 540p, 480p or 360p to fit (1.3.14).
///
/// AVFoundation's estimate decides whether a size is tried, the written size
/// whether it is kept. Exports go to a folder of their own next to the
/// picked file, which stays as it is.
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

    /// A folder an export was written to, inside a work directory.
    static func isExportDirectory(_ folder: URL) -> Bool {
        folder.lastPathComponent.hasPrefix("export-") && isWorkDirectory(folder.deletingLastPathComponent())
    }

    /// Copy `file` (a picker's or the camera's temporary file) into a folder of our own.
    static func keep(_ file: URL) throws -> URL {
        let destination = workDirectory().appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "mov", "qt": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "3gp": return "video/3gpp"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default:
            if let mime = UTType(filenameExtension: ext)?.preferredMIMEType, mime.hasPrefix("video/") { return mime }
            return "video/mp4"
        }
    }

    /// With this preparer's own limit, as a server before fork.191 would take it.
    func prepare(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedMedia {
        try await prepare(file, policy: VideoPolicy(maxBytes: maxBytes, keepsAnyCodec: false, quality: .original),
                          progress: progress)
    }

    func prepare(_ file: URL, policy: VideoPolicy,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: file)
        let size = Self.size(of: file)
        let ext = file.pathExtension.lowercased()
        let fits = size > 0 && size <= policy.maxBytes

        func original(duration: TimeInterval?, poster: UIImage?) -> PreparedMedia {
            progress(1)
            return PreparedMedia(url: file, name: file.lastPathComponent, mimeType: Self.mimeType(forExtension: ext),
                                 size: size, duration: duration, poster: poster, note: "Original")
        }

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            // Not a video AVFoundation reads (WebM, Matroska, …): a server
            // that takes large files gets it as it is.
            if policy.keepsAnyCodec, fits { return original(duration: nil, poster: nil) }
            if policy.keepsAnyCodec, size > 0 { throw VideoAttachmentError.tooLarge(size: size, limit: policy.maxBytes) }
            throw VideoAttachmentError.noVideo
        }
        let duration = (try? await asset.load(.duration)).flatMap { $0.isNumeric && $0.seconds > 0 ? $0.seconds : nil }
        let codec = (try? await track.load(.formatDescriptions))?.first.map(CMFormatDescriptionGetMediaSubType)
        let isH264InCommonContainer = codec == kCMVideoCodecType_H264 && ["mp4", "m4v", "mov"].contains(ext)

        switch policy.quality {
        case .original where policy.keepsAnyCodec:
            if fits { return original(duration: duration, poster: await Self.poster(of: asset, duration: duration)) }
        case .original:
            if isH264InCommonContainer, fits {
                return original(duration: duration, poster: await Self.poster(of: asset, duration: duration))
            }
        case .compressed:
            if isH264InCommonContainer, fits, let side = await Self.shortSide(of: track), side <= 720 {
                return original(duration: duration, poster: await Self.poster(of: asset, duration: duration))
            }
        }

        let base = file.deletingPathExtension().lastPathComponent
        // A folder of its own, so a picked `clip.mp4` is never overwritten.
        let folder = file.deletingLastPathComponent()
            .appendingPathComponent("export-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("\(base).mp4")
        var smallest: Int64 = 0
        for preset in policy.presets {
            try Task.checkCancellation()
            guard let session = AVAssetExportSession(asset: asset, presetName: preset.name) else { continue }
            session.shouldOptimizeForNetworkUse = true
            let estimate = (try? await session.estimatedOutputFileLengthInBytes) ?? 0
            smallest = estimate
            // Leave room: the estimate is only an estimate.
            if estimate > 0, Double(estimate) > Double(policy.maxBytes) * 0.92 { continue }
            try? FileManager.default.removeItem(at: output)
            try await Self.export(session, to: output, progress: progress)
            let written = Self.size(of: output)
            guard written > 0 else { throw VideoAttachmentError.export("nothing was written") }
            if written > policy.maxBytes {
                smallest = written
                continue
            }
            return PreparedMedia(url: output, name: output.lastPathComponent, mimeType: "video/mp4", size: written,
                                 duration: duration,
                                 poster: await Self.poster(of: AVURLAsset(url: output), duration: duration),
                                 note: "Compressed to \(preset.label) H.264")
        }
        try? FileManager.default.removeItem(at: folder)
        throw VideoAttachmentError.tooLong(estimate: smallest, limit: policy.maxBytes)
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

    /// The shorter side of the picture as it shows (rotation applied).
    static func shortSide(of track: AVAssetTrack) async -> CGFloat? {
        guard let natural = try? await track.load(.naturalSize) else { return nil }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let shown = natural.applying(transform)
        let side = min(abs(shown.width), abs(shown.height))
        return side > 0 ? side : nil
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

// MARK: - Preparing an audio file

/// An audio file from Files goes as it is, within the server's media limit
/// (20 MiB on a server before fork.191).
enum AudioAttachmentPrep {
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        default:
            if let mime = UTType(filenameExtension: ext)?.preferredMIMEType, mime.hasPrefix("audio/") { return mime }
            return "audio/mpeg"
        }
    }

    static func prepare(_ file: URL, maxBytes: Int64) async throws -> PreparedMedia {
        let size = VideoAttachmentPrep.size(of: file)
        guard size > 0 else { throw VideoAttachmentError.unreadable }
        guard size <= maxBytes else { throw VideoAttachmentError.tooLarge(size: size, limit: maxBytes) }
        let duration = (try? await AVURLAsset(url: file).load(.duration))
            .flatMap { $0.isNumeric && $0.seconds > 0 ? $0.seconds : nil }
        return PreparedMedia(url: file, name: file.lastPathComponent,
                             mimeType: mimeType(forExtension: file.pathExtension),
                             size: size, duration: duration, poster: nil, note: "Original")
    }
}
