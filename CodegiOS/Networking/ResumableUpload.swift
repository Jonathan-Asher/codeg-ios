import Foundation

/// What a piece of a resumable upload reports while it is sent.
enum UploadChunkEvent: Sendable, Equatable {
    /// This many bytes of the piece have gone out.
    case sent(Int64)
    /// The request waits for the network to come back.
    case waitingForNetwork
}

/// One file sent with codeg's resumable upload (fork.191): created with
/// `upload_attachment_create`, sent in pieces of about the server's
/// suggested size (`PUT upload_attachment_chunk?uploadId=…&offset=N`), and
/// completed with `upload_attachment_complete`, which answers as
/// `upload_attachment` does.
///
/// The upload id and the offset are kept across failures and pauses, so a
/// dropped connection, a request cut off by the app being suspended or a
/// Try Again carries on from what the server holds
/// (`upload_attachment_status`) instead of from zero. The server keeps the
/// bytes of a piece that was cut off midway, so little is sent twice.
/// - A piece at the wrong offset (409 `offsetMismatch`) starts again at the
///   offset the server gives.
/// - A piece taken over by a newer request (409 `superseded`) asks where the
///   upload stands and goes on from there.
/// - An upload the server no longer has (404 `notFound`: idle for a day, or
///   the server restarted) starts over from zero, a few times at most.
/// - A network or server failure waits a moment (longer each time) and asks
///   where it stands; after ``maxFailures`` in a row it gives up, keeping
///   the upload for a retry.
@MainActor
final class ResumableTransfer {
    let file: URL
    let size: Int64
    let fileName: String
    let mimeType: String
    let bucket: String?
    let chunkBytes: Int64
    private let api: any AttachmentUploading

    /// The server's id for the upload, kept until it completes.
    private(set) var uploadId: String?
    /// The bytes the server holds, as it last said.
    private(set) var offset: Int64 = 0
    /// Times the upload started over because the server had lost it.
    private(set) var restarts = 0

    /// The wait after each failure in a row; the last one repeats.
    var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// Failures in a row, with nothing getting through, before giving up.
    var maxFailures = 8
    static let maxRestarts = 3
    /// Offset disagreements in a row before giving up.
    static let maxConflicts = 6

    /// Drops piece progress that arrives after its piece is over.
    private var piece = 0

    init(file: URL, size: Int64, fileName: String, mimeType: String, bucket: String?, chunkBytes: Int64,
         api: any AttachmentUploading) {
        self.file = file
        self.size = size
        self.fileName = fileName
        self.mimeType = mimeType
        self.bucket = bucket
        self.chunkBytes = max(1, chunkBytes)
        self.api = api
    }

    /// Send what the server doesn't have yet, then complete the upload.
    /// - Parameters:
    ///   - onProgress: the bytes the server has, or has been sent so far.
    ///   - onWaiting: the upload waits for the network, or to try again.
    func run(onProgress: @escaping (Int64) -> Void,
             onWaiting: @escaping () -> Void = {}) async throws -> UploadedAttachment {
        var failures = 0
        var conflicts = 0
        var needsStatus = uploadId != nil
        while true {
            try Task.checkCancellation()
            do {
                if uploadId == nil {
                    let state = try await api.createResumableUpload(fileName: fileName, size: size,
                                                                    mimeType: mimeType, bucket: bucket)
                    try Task.checkCancellation()
                    uploadId = state.uploadId
                    offset = state.offset
                    needsStatus = false
                } else if needsStatus, let id = uploadId {
                    let state = try await api.resumableUploadStatus(uploadId: id)
                    try Task.checkCancellation()
                    offset = state.offset
                    needsStatus = false
                }
                guard let id = uploadId else { continue }
                onProgress(offset)
                while offset < size {
                    try Task.checkCancellation()
                    let start = offset
                    let data = try await Self.read(file, at: start, length: Int(min(chunkBytes, size - start)))
                    piece += 1
                    let current = piece
                    let state = try await api.uploadResumableChunk(uploadId: id, offset: start, data: data) { event in
                        Task { @MainActor [weak self] in
                            guard let self, self.piece == current else { return }
                            switch event {
                            case .sent(let bytes): onProgress(start + bytes)
                            case .waitingForNetwork: onWaiting()
                            }
                        }
                    }
                    piece += 1
                    try Task.checkCancellation()
                    offset = state.offset
                    failures = 0
                    conflicts = 0
                    onProgress(offset)
                }
                let uploaded = try await api.completeResumableUpload(uploadId: id)
                uploadId = nil
                return uploaded
            } catch let error as AttachmentUploadError {
                piece += 1
                switch error {
                case .offsetMismatch(let server?), .incomplete(let server?):
                    conflicts += 1
                    guard conflicts <= Self.maxConflicts else { throw error }
                    offset = server
                case .offsetMismatch(nil), .incomplete(nil), .superseded:
                    conflicts += 1
                    guard conflicts <= Self.maxConflicts else { throw error }
                    needsStatus = true
                case .uploadNotFound:
                    // Idle too long, or the server restarted: what it had is gone.
                    restarts += 1
                    guard restarts <= Self.maxRestarts else { throw error }
                    uploadId = nil
                    offset = 0
                    needsStatus = false
                    onProgress(0)
                case _ where error.isRetryable:
                    failures += 1
                    needsStatus = uploadId != nil
                    guard failures < maxFailures else { throw error }
                    onWaiting()
                    try await Task.sleep(for: backoff[min(failures - 1, backoff.count - 1)])
                default:
                    throw error
                }
            }
        }
    }

    /// Let the server drop the upload and its bytes (the attachment was
    /// removed). Best effort: an idle upload lapses on its own.
    func discard() {
        guard let id = uploadId else { return }
        uploadId = nil
        let api = self.api
        Task { await api.cancelResumableUpload(uploadId: id) }
    }

    /// `length` bytes of `file` from `offset`, read off the main thread.
    nonisolated static func read(_ file: URL, at offset: Int64, length: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: file) } catch {
                throw AttachmentUploadError.fileUnreadable(error.localizedDescription)
            }
            defer { try? handle.close() }
            let data: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                data = try handle.read(upToCount: length) ?? Data()
            } catch {
                throw AttachmentUploadError.fileUnreadable(error.localizedDescription)
            }
            guard data.count == length else {
                throw AttachmentUploadError.fileUnreadable("The file changed while it was being uploaded.")
            }
            return data
        }.value
    }
}
