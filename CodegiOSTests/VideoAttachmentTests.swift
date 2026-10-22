import AVFoundation
import XCTest
@testable import Codeg

/// Prepares a video without AVFoundation, counting the calls and keeping
/// the policies it was given.
final class FakeVideoPreparer: VideoPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var policies: [VideoPolicy] = []
    var delay: Duration = .zero
    /// The prepared file's name; the picked file's when nil.
    var name: String?

    func prepare(_ file: URL, policy: VideoPolicy,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedMedia {
        lock.withLock {
            calls += 1
            policies.append(policy)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        progress(1)
        return PreparedMedia(url: file, name: name ?? file.lastPathComponent, mimeType: "video/mp4",
                             size: VideoAttachmentPrep.size(of: file),
                             duration: 3, poster: nil, note: "Original")
    }
}

/// Attaching a video: it is uploaded to codeg's uploads directory as codeg
/// web uploads a file that isn't a picture (`upload_attachment`, multipart,
/// the conversation's bucket), the message links to it with a
/// `resource_link`, and the message can go only once the upload is done.
@MainActor
final class VideoAttachmentTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []

    override func setUp() async throws {
        server = MockCodegServer()
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        server = nil
    }

    /// A file in a folder of the app's own, as the pickers leave it.
    private func pickedFile(_ name: String = "clip.mp4", bytes: Data = Data("fake-mp4".utf8)) throws -> URL {
        let url = VideoAttachmentPrep.workDirectory().appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func uploadedJSON(_ path: String = "/srv/uploads/conv-1-claude_code-7/clip.mp4") -> String {
        #"{"path":"\#(path)","name":"\#((path as NSString).lastPathComponent)","size":8,"mimeType":"video/mp4"}"#
    }

    // MARK: - The endpoint

    func testTheUploadIsMultipartWithTheBucketAndTheFile() async throws {
        server.on("upload_attachment") { _ in .body(self.uploadedJSON("/srv/uploads/b/take (1).mp4")) }
        let file = try pickedFile("take (1).mp4", bytes: Data("0123456789".utf8))
        let uploaded = try await server.client.uploadAttachment(fileURL: file, fileName: "take (1).mp4",
                                                                mimeType: "video/mp4", bucket: "conv-1-claude_code-7") { _ in }
        XCTAssertEqual(uploaded, UploadedAttachment(path: "/srv/uploads/b/take (1).mp4", name: "take (1).mp4",
                                                    size: 8, mimeType: "video/mp4"))
        let call = try XCTUnwrap(server.calls("upload_attachment").first)
        let body = String(decoding: call.raw, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"session_id\"\r\n\r\nconv-1-claude_code-7\r\n"), body)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"take (1).mp4\"\r\nContent-Type: video/mp4\r\n\r\n0123456789\r\n"))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
    }

    func testRefusalsReadInPlainWords() async throws {
        let file = try pickedFile()
        let cases: [(MockCodegServer.Reply, AttachmentUploadError)] = [
            (.status(500, #"{"code":"io_error","message":"Upload exceeds the maximum allowed size","i18n_key":"errors.upload.tooLarge"}"#),
             .tooLarge(limit: AttachmentUploadLimits.maxBytes)),
            (.status(500, #"{"code":"io_error","message":"Upload quota exceeded for this server","i18n_key":"errors.upload.quotaExceeded"}"#),
             .quotaFull),
            (.status(501, #"{"code":"not_implemented","message":"API endpoint 'upload_attachment' is not available"}"#),
             .unsupportedServer),
            (.status(401, #"{"code":"unauthorized","message":"Unauthorized"}"#), .unauthorized),
            (.status(500, #"{"code":"io_error","message":"Failed to create uploads root"}"#), .server("Failed to create uploads root")),
        ]
        for (reply, expected) in cases {
            server.on("upload_attachment") { _ in reply }
            do {
                _ = try await server.client.uploadAttachment(fileURL: file, fileName: "clip.mp4", mimeType: "video/mp4",
                                                             bucket: nil) { _ in }
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? AttachmentUploadError, expected)
                XCTAssertNotNil((error as? AttachmentUploadError)?.errorDescription)
            }
        }
        server.on("upload_attachment") { _ in .fail(.networkConnectionLost) }
        do {
            _ = try await server.client.uploadAttachment(fileURL: file, fileName: "clip.mp4", mimeType: "video/mp4",
                                                         bucket: nil) { _ in }
            XCTFail("should throw")
        } catch {
            guard case .network? = error as? AttachmentUploadError else { return XCTFail("\(error)") }
            XCTAssertTrue((error as? AttachmentUploadError)?.isRetryable == true)
        }
    }

    func testAFileOverTheServersLimitIsRefusedBeforeItIsSent() async throws {
        let url = VideoAttachmentPrep.workDirectory().appendingPathComponent("huge.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AttachmentUploadLimits.maxBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await server.client.uploadAttachment(fileURL: url, fileName: "huge.mp4", mimeType: "video/mp4",
                                                         bucket: nil) { _ in }
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? AttachmentUploadError, .tooLarge(limit: 20 * 1024 * 1024))
        }
        XCTAssertTrue(server.calls("upload_attachment").isEmpty, "nothing was sent")
    }

    // MARK: - The job

    func testAVideoIsPreparedAndUploadedAndItsCopiesAreRemoved() async throws {
        server.on("upload_attachment") { _ in .body(self.uploadedJSON()) }
        let file = try pickedFile()
        let preparer = FakeVideoPreparer()
        let upload = AttachmentUpload(source: .file(file), displayName: "clip.mp4", uploader: server.client,
                                      bucket: "conv-1-claude_code-7", preparer: preparer)
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(upload.uploaded?.path, "/srv/uploads/conv-1-claude_code-7/clip.mp4")
        XCTAssertEqual(upload.duration, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path),
                       "the copy on the iPhone is gone once the server has it")

        let attachment = Attachment(video: upload)
        XCTAssertTrue(attachment.isReady)
        XCTAssertEqual(attachment.byteCount, 0, "a video doesn't ride in the prompt")
        guard case .resourceLink(let uri, let name, let mimeType) = attachment.promptInputBlock else {
            return XCTFail("not a resource link")
        }
        XCTAssertEqual(uri, "file:///srv/uploads/conv-1-claude_code-7/clip.mp4")
        XCTAssertEqual(name, "clip.mp4")
        XCTAssertEqual(mimeType, "video/mp4")
        XCTAssertEqual(attachment.optimisticBlock, .text("[clip.mp4](file:///srv/uploads/conv-1-claude_code-7/clip.mp4)"))
    }

    func testAFailedUploadSaysWhyAndTriesAgainWithoutCompressingAgain() async throws {
        server.on("upload_attachment") { _ in
            .status(500, #"{"code":"io_error","message":"Upload quota exceeded for this server","i18n_key":"errors.upload.quotaExceeded"}"#)
        }
        let preparer = FakeVideoPreparer()
        let upload = AttachmentUpload(source: .file(try pickedFile()), uploader: server.client, bucket: nil,
                                      preparer: preparer)
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .failed("The codeg server's upload space is full."))
        XCTAssertFalse(Attachment(video: upload).isReady)

        server.on("upload_attachment") { _ in .body(self.uploadedJSON()) }
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(preparer.calls, 1, "the compressed file is kept for the retry")
        XCTAssertEqual(server.calls("upload_attachment").count, 2)
        XCTAssertEqual(preparer.policies, [.legacy], "a server that doesn't say its limits gets 1.3.14's 20 MiB")
    }

    func testRemovingAVideoStopsItAndDeletesItsCopy() async throws {
        let file = try pickedFile()
        let preparer = FakeVideoPreparer()
        preparer.delay = .seconds(30)
        let upload = AttachmentUpload(source: .file(file), uploader: server.client, bucket: nil, preparer: preparer)
        upload.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(upload.isRunning)
        upload.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(server.calls("upload_attachment").isEmpty)
    }

    // MARK: - Sending

    private func openIdleSession() async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("acp_connect") { _ in .body(#""conn-1""#) }
        let factory = StreamFactory([.attach(Fixtures.snapshot(status: "connected"))])
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID) { _ in
            factory.make()
        }
        models.append(model)
        await model.load()
        return model
    }

    func testTheMessageLinksTheUploadedVideoAndWaitsForIt() async throws {
        server.on("upload_attachment") { _ in .body(self.uploadedJSON()) }
        let model = await openIdleSession()
        let preparer = FakeVideoPreparer()
        preparer.delay = .milliseconds(400)
        model.videoPreparer = preparer

        model.addMedia(.file(try pickedFile()))
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertFalse(model.attachmentsReady)
        model.draft = "What happens at 0:02?"
        model.sendFromComposer()
        XCTAssertEqual(model.notice, "Wait for the video to finish uploading.")
        XCTAssertTrue(server.calls("acp_prompt").isEmpty, "nothing goes before the upload is done")
        XCTAssertEqual(model.draft, "What happens at 0:02?", "the message stays in the composer")

        let upload = try XCTUnwrap(model.attachments.first?.upload)
        await upload.finish()
        XCTAssertTrue(model.attachmentsReady)
        let call = try XCTUnwrap(server.calls("upload_attachment").first)
        XCTAssertTrue(String(decoding: call.raw, as: UTF8.self).contains("conv-1-claude_code-7"),
                      "the conversation's bucket, as codeg web names it")

        model.notice = nil
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let blocks = try XCTUnwrap(server.calls("acp_prompt").first?.body["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["type"] as? String, "resource_link")
        XCTAssertEqual(blocks[1]["uri"] as? String, "file:///srv/uploads/conv-1-claude_code-7/clip.mp4")
        XCTAssertEqual(blocks[1]["name"] as? String, "clip.mp4")
        XCTAssertEqual(blocks[1]["mime_type"] as? String, "video/mp4")
        // The message shows the video at once: its link becomes the card.
        let shown = try XCTUnwrap(model.pendingUserTurns.last?.blocks)
        XCTAssertEqual(shown.last, .text("[clip.mp4](file:///srv/uploads/conv-1-claude_code-7/clip.mp4)"))
        XCTAssertTrue(model.attachments.isEmpty)
    }

    func testAVideoThatDidntUploadSaysSo() async throws {
        server.on("upload_attachment") { _ in .status(500, #"{"code":"io_error","message":"disk full"}"#) }
        let model = await openIdleSession()
        model.videoPreparer = FakeVideoPreparer()
        model.addMedia(.file(try pickedFile()))
        await model.attachments.first?.upload?.finish()
        model.draft = "Look"
        model.sendFromComposer()
        XCTAssertEqual(model.notice, "A video didn't upload. Tap it to try again, or remove it.")
        XCTAssertTrue(server.calls("acp_prompt").isEmpty)

        let id = try XCTUnwrap(model.attachments.first?.id)
        model.removeAttachment(id)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertTrue(model.attachmentsReady)
    }

    // MARK: - Preparing real videos

    /// A short movie made here with AVAssetWriter.
    private func makeMovie(_ name: String, codec: AVVideoCodecType, fileType: AVFileType) async throws -> URL {
        let url = VideoAttachmentPrep.workDirectory().appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(40 + frame * 20), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testAnH264VideoUnderTheLimitIsSentAsItIs() async throws {
        let movie = try await makeMovie("short.mp4", codec: .h264, fileType: .mp4)
        defer { try? FileManager.default.removeItem(at: movie.deletingLastPathComponent()) }
        let prepared = try await VideoAttachmentPrep().prepare(movie) { _ in }
        XCTAssertEqual(prepared.url, movie)
        XCTAssertEqual(prepared.note, "Original")
        XCTAssertEqual(prepared.mimeType, "video/mp4")
        XCTAssertEqual(prepared.duration ?? 0, 1, accuracy: 0.2)
        XCTAssertNotNil(prepared.poster)
    }

    /// The simulator encodes only H.264, so the file that must be exported is
    /// an H.264 movie in a container that isn't sent as it is (`.qt`); HEVC
    /// takes the same path.
    func testAVideoThatCantGoAsItIsIsExportedToH264MP4() async throws {
        let movie = try await makeMovie("frames.qt", codec: .h264, fileType: .mov)
        defer { try? FileManager.default.removeItem(at: movie.deletingLastPathComponent()) }
        let prepared = try await VideoAttachmentPrep().prepare(movie) { _ in }
        XCTAssertEqual(prepared.name, "frames.mp4")
        XCTAssertEqual(prepared.mimeType, "video/mp4")
        XCTAssertTrue(prepared.note.hasPrefix("Compressed to 720p"), prepared.note)
        XCTAssertLessThanOrEqual(prepared.size, AttachmentUploadLimits.maxBytes)
        let tracks = try await AVURLAsset(url: prepared.url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let codec = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
    }

    func testAVideoTooLongForTheLimitSaysSo() async throws {
        let movie = try await makeMovie("long.qt", codec: .h264, fileType: .mov)
        defer { try? FileManager.default.removeItem(at: movie.deletingLastPathComponent()) }
        do {
            _ = try await VideoAttachmentPrep(maxBytes: 1024).prepare(movie) { _ in }
            XCTFail("should refuse")
        } catch let VideoAttachmentError.tooLong(_, limit) {
            XCTAssertEqual(limit, 1024)
        }
    }

    // MARK: - A server that takes large videos (fork.191)

    private let largeServer = VideoPolicy(maxBytes: 1024 * 1024 * 1024, keepsAnyCodec: true, quality: .original)

    func testOnAServerWithTheMediaLimitAVideoUnderItGoesAsItIs() async throws {
        // The `.qt` an older server gets exported: any codec and container go
        // as they are now.
        let movie = try await makeMovie("frames.qt", codec: .h264, fileType: .mov)
        defer { try? FileManager.default.removeItem(at: movie.deletingLastPathComponent()) }
        let prepared = try await VideoAttachmentPrep().prepare(movie, policy: largeServer) { _ in }
        XCTAssertEqual(prepared.url, movie)
        XCTAssertEqual(prepared.name, "frames.qt")
        XCTAssertEqual(prepared.mimeType, "video/quicktime")
        XCTAssertEqual(prepared.note, "Original")
        XCTAssertNotNil(prepared.poster)
    }

    func testCompressedExportsTo720pAndASmallH264VideoGoesAsItIs() async throws {
        var compressed = largeServer
        compressed.quality = .compressed
        let small = try await makeMovie("small.mp4", codec: .h264, fileType: .mp4)
        defer { try? FileManager.default.removeItem(at: small.deletingLastPathComponent()) }
        let kept = try await VideoAttachmentPrep().prepare(small, policy: compressed) { _ in }
        XCTAssertEqual(kept.url, small, "an H.264 video of 160 by 120 is already smaller than 720p")
        XCTAssertEqual(kept.note, "Original")

        let other = try await makeMovie("other.qt", codec: .h264, fileType: .mov)
        defer { try? FileManager.default.removeItem(at: other.deletingLastPathComponent()) }
        let exported = try await VideoAttachmentPrep().prepare(other, policy: compressed) { _ in }
        XCTAssertEqual(exported.name, "other.mp4")
        XCTAssertTrue(exported.note.hasPrefix("Compressed to 720p"), exported.note)
        XCTAssertTrue(VideoAttachmentPrep.isExportDirectory(exported.url.deletingLastPathComponent()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "the picked file stays as it is")
    }

    func testTheExportSizesFollowTheServerAndTheChoice() {
        XCTAssertEqual(largeServer.presets.map(\.label), ["1080p", "720p", "540p", "480p", "360p"],
                       "an original over 1 GiB is compressed as little as it can be")
        var compressed = largeServer
        compressed.quality = .compressed
        XCTAssertEqual(compressed.presets.map(\.label), ["720p", "540p", "480p", "360p"])
        XCTAssertEqual(VideoPolicy.legacy.presets.map(\.label), ["720p", "540p", "480p", "360p"], "1.3.14's ladder")

        let limits = ServerUploadLimits(maxFileBytes: 20 << 20, maxMediaBytes: 1 << 30,
                                        resumable: .init(chunkBytesHint: 8 << 20, idleTimeoutSecs: 86400, maxActive: 32))
        XCTAssertEqual(VideoPolicy(limits: limits, quality: .compressed),
                       VideoPolicy(maxBytes: 1 << 30, keepsAnyCodec: true, quality: .compressed))
        XCTAssertEqual(VideoPolicy(limits: .legacy, quality: .compressed), .legacy,
                       "an older server has no choice to make")
    }

    func testAnH264MP4OverTheLimitIsNeverOverwrittenByItsExport() async throws {
        // 1.3.14 wrote the export of `clip.mp4` over `clip.mp4` itself.
        let movie = try await makeMovie("clip.mp4", codec: .h264, fileType: .mp4)
        defer { try? FileManager.default.removeItem(at: movie.deletingLastPathComponent()) }
        let size = VideoAttachmentPrep.size(of: movie)
        let prepared = try? await VideoAttachmentPrep(maxBytes: max(1, size - 1)).prepare(movie) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertEqual(VideoAttachmentPrep.size(of: movie), size)
        if let prepared { XCTAssertNotEqual(prepared.url, movie) }
    }

    func testAnUnreadableVideoGoesAsItIsOnlyToAServerThatTakesLargeFiles() async throws {
        let file = try pickedFile("talk.mkv", bytes: Data(repeating: 7, count: 64))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let kept = try await VideoAttachmentPrep().prepare(file, policy: largeServer) { _ in }
        XCTAssertEqual(kept.url, file)
        XCTAssertEqual(kept.mimeType, "video/x-matroska")
        XCTAssertNil(kept.poster)
        do {
            _ = try await VideoAttachmentPrep().prepare(file, policy: .legacy) { _ in }
            XCTFail("an older server gets only what can be checked")
        } catch {
            XCTAssertEqual(error as? VideoAttachmentError, .noVideo)
        }
        var tiny = largeServer
        tiny.maxBytes = 10
        do {
            _ = try await VideoAttachmentPrep().prepare(file, policy: tiny) { _ in }
            XCTFail("over the limit")
        } catch {
            XCTAssertEqual(error as? VideoAttachmentError, .tooLarge(size: 64, limit: 10))
        }
    }

    // MARK: - Audio

    func testAnAudioFileGoesAsItIsWithinTheLimit() async throws {
        let file = try pickedFile("memo.m4a", bytes: Data(repeating: 1, count: 300))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertTrue(AttachmentSource.file(file).isAudio)
        XCTAssertFalse(AttachmentSource.file(URL(fileURLWithPath: "/tmp/a.mov")).isAudio)
        XCTAssertFalse(AttachmentSource.file(URL(fileURLWithPath: "/tmp/a.mp4")).isAudio)
        let prepared = try await AudioAttachmentPrep.prepare(file, maxBytes: 1000)
        XCTAssertEqual(prepared.url, file)
        XCTAssertEqual(prepared.mimeType, "audio/mp4")
        XCTAssertEqual(prepared.size, 300)
        do {
            _ = try await AudioAttachmentPrep.prepare(file, maxBytes: 100)
            XCTFail("over the limit")
        } catch {
            XCTAssertEqual(error as? VideoAttachmentError, .tooLarge(size: 300, limit: 100))
        }
        XCTAssertEqual(AudioAttachmentPrep.mimeType(forExtension: "mp3"), "audio/mpeg")
        XCTAssertEqual(AudioAttachmentPrep.mimeType(forExtension: "wav"), "audio/wav")
    }

    func testAnAudioFileIsUploadedAndLinkedAsAudio() async throws {
        server.on("upload_attachment") { _ in .body(#"{"path":"/srv/uploads/b/memo.mp3","name":"memo.mp3","size":4,"mimeType":"audio/mpeg"}"#) }
        let file = try pickedFile("memo.mp3", bytes: Data("ID3x".utf8))
        let preparer = FakeVideoPreparer()
        let upload = AttachmentUpload(source: .file(file), displayName: "memo.mp3", uploader: server.client,
                                      bucket: "b", preparer: preparer)
        XCTAssertEqual(upload.kind, .audio)
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(preparer.calls, 0, "audio isn't compressed")
        let attachment = Attachment(upload: upload)
        XCTAssertFalse(attachment.isVideo)
        guard case .resourceLink(_, let name, let mimeType) = attachment.promptInputBlock else {
            return XCTFail("not a resource link")
        }
        XCTAssertEqual(name, "memo.mp3")
        XCTAssertEqual(mimeType, "audio/mpeg")
        let body = String(decoding: try XCTUnwrap(server.calls("upload_attachment").first).raw, as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Type: audio/mpeg"), body)
    }
}
