import XCTest
@testable import Codeg

/// codeg fork.191's resumable upload, played on the mock server: it keeps the
/// bytes each piece brings, answers where an upload stands, and can be told
/// to drop a connection part way, to answer a piece with a conflict, or to
/// forget an upload as a restarted server would.
final class FakeResumableServer: @unchecked Sendable {
    enum Piece {
        /// Take the piece and answer.
        case normal
        /// Keep this many bytes of it, then lose the connection.
        case drop(after: Int)
        /// A newer request took over: keep nothing, answer 409 superseded.
        case superseded
        /// The server restarted: it no longer has the upload (404 notFound).
        case forget
        /// A 500 the server answers when its disk hiccups.
        case serverError
    }

    struct Upload {
        let id: String
        let size: Int
        let fileName: String
        let mimeType: String?
        let bucket: String?
        var bytes = Data()
    }

    /// The test holds the server; the server's routes hold this fake.
    unowned let server: MockCodegServer
    private let lock = NSLock()
    private var uploads: [String: Upload] = [:]
    private var made = 0
    private var script: [Piece] = []
    /// Bytes that land just before the first piece, as from a request the
    /// phone gave up on (it puts the phone out of step).
    var stray = Data()
    private(set) var files: [String: Data] = [:]
    private(set) var cancelled: [String] = []

    static let limits = #"""
    {"maxFileBytes":20971520,"maxMediaBytes":1073741824,"mediaTypes":["video/*","audio/*"],
     "maxTotalBytes":null,"remainingTotalBytes":null,
     "resumable":{"chunkBytesHint":8,"idleTimeoutSecs":86400,"maxActive":32}}
    """#

    init(_ server: MockCodegServer, limits: String = FakeResumableServer.limits) {
        self.server = server
        server.on("upload_limits") { _ in .body(limits) }
        server.on("upload_attachment_create") { call in self.create(call) }
        server.on("upload_attachment_chunk") { call in self.chunk(call) }
        server.on("upload_attachment_status") { call in self.status(call) }
        server.on("upload_attachment_complete") { call in self.complete(call) }
        server.on("upload_attachment_cancel") { call in
            let id = call.body["uploadId"] as? String ?? ""
            let removed = self.lock.withLock { () -> Bool in
                self.cancelled.append(id)
                return self.uploads.removeValue(forKey: id) != nil
            }
            return .body(removed ? "true" : "false")
        }
    }

    /// What the next pieces do, in order; after them every piece is taken.
    func script(_ pieces: Piece...) { lock.withLock { script = pieces } }

    /// The offsets the phone sent its pieces at, in order.
    var pieceOffsets: [Int] { server.calls("upload_attachment_chunk").compactMap { Int($0.query["offset"] ?? "") } }

    func held(_ id: String) -> Int? { lock.withLock { uploads[id]?.bytes.count } }

    // MARK: Routes

    private func state(_ upload: Upload) -> String {
        let name = upload.fileName.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"uploadId":"\#(upload.id)","offset":\#(upload.bytes.count),"size":\#(upload.size),"complete":\#(upload.bytes.count == upload.size),"fileName":"\#(name)","mimeType":"\#(upload.mimeType ?? "")","limit":1073741824,"expiresInSecs":86400}"#
    }

    private static let notFound = MockCodegServer.Reply.status(404,
        #"{"code":"not_found","message":"Upload not found or expired","i18n_key":"errors.upload.notFound"}"#)

    private func create(_ call: MockCodegServer.Call) -> MockCodegServer.Reply {
        lock.withLock {
            made += 1
            let upload = Upload(id: "up\(made)", size: call.body["size"] as? Int ?? 0,
                                fileName: call.body["fileName"] as? String ?? "",
                                mimeType: call.body["mimeType"] as? String, bucket: call.body["sessionId"] as? String)
            uploads[upload.id] = upload
            return .body(state(upload))
        }
    }

    private func chunk(_ call: MockCodegServer.Call) -> MockCodegServer.Reply {
        lock.withLock {
            let id = call.query["uploadId"] ?? ""
            let offset = Int(call.query["offset"] ?? "") ?? -1
            let next = script.isEmpty ? Piece.normal : script.removeFirst()
            guard var upload = uploads[id] else { return Self.notFound }
            if !stray.isEmpty {
                upload.bytes.append(stray)
                uploads[id] = upload
                stray = Data()
            }
            switch next {
            case .forget:
                uploads[id] = nil
                return Self.notFound
            case .superseded:
                return .status(409, #"{"code":"already_exists","message":"A newer request for this upload took over","i18n_key":"errors.upload.superseded"}"#)
            case .serverError:
                return .status(500, #"{"code":"io_error","message":"Failed to write upload chunk"}"#)
            case .normal, .drop:
                break
            }
            guard offset == upload.bytes.count else {
                let held = upload.bytes.count
                return .status(409, #"{"code":"already_exists","message":"Chunk offset does not match the bytes received","detail":"offset=\#(held) sent=\#(offset)","i18n_key":"errors.upload.offsetMismatch","i18n_params":{"offset":"\#(held)","sent":"\#(offset)"}}"#)
            }
            if case .drop(let kept) = next {
                upload.bytes.append(call.raw.prefix(kept))
                uploads[id] = upload
                return .fail(.networkConnectionLost)
            }
            upload.bytes.append(call.raw)
            uploads[id] = upload
            return .body(state(upload))
        }
    }

    private func status(_ call: MockCodegServer.Call) -> MockCodegServer.Reply {
        lock.withLock {
            guard let upload = uploads[call.body["uploadId"] as? String ?? ""] else { return Self.notFound }
            return .body(state(upload))
        }
    }

    private func complete(_ call: MockCodegServer.Call) -> MockCodegServer.Reply {
        lock.withLock {
            let id = call.body["uploadId"] as? String ?? ""
            guard let upload = uploads[id] else { return Self.notFound }
            guard upload.bytes.count == upload.size else {
                return .status(409, #"{"code":"already_exists","message":"Upload is not complete yet","i18n_key":"errors.upload.incomplete","i18n_params":{"offset":"\#(upload.bytes.count)","size":"\#(upload.size)"}}"#)
            }
            uploads[id] = nil
            let path = "/srv/uploads/\(upload.bucket ?? "default")/\(upload.fileName)"
            files[path] = upload.bytes
            return .body(#"{"path":"\#(path)","name":"\#(upload.fileName)","size":\#(upload.size),"mimeType":"\#(upload.mimeType ?? "")"}"#)
        }
    }
}

/// Large videos and audio files go to a server that says its limits
/// (`upload_limits`) in pieces that survive a dropped connection, a pause in
/// the background and a server that lost the upload; any other server keeps
/// 1.3.14's single 20 MiB upload.
@MainActor
final class ResumableUploadTests: XCTestCase {
    private var server: MockCodegServer!
    private var files: [URL] = []

    override func setUp() async throws {
        server = MockCodegServer()
    }

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        files = []
        server = nil
    }

    /// 20 bytes in the app's own folder: three pieces of 8.
    private let content = Data("0123456789abcdefghij".utf8)

    private func pickedFile(_ name: String = "take.mov") throws -> URL {
        let url = VideoAttachmentPrep.workDirectory().appendingPathComponent(name)
        try content.write(to: url)
        files.append(url)
        return url
    }

    private func job(_ file: URL, lifecycle: AttachmentUploadLifecycle? = nil) -> AttachmentUpload {
        let upload = AttachmentUpload(source: .file(file), displayName: file.lastPathComponent, uploader: server.client,
                                      bucket: "conv-1-claude_code-7", preparer: FakeVideoPreparer(),
                                      lifecycle: lifecycle ?? AttachmentUploadLifecycle(observesApp: false))
        upload.retryBackoff = [.zero]
        return upload
    }

    // MARK: - Limits

    func testTheLimitsAreReadOnceAndKept() async throws {
        _ = FakeResumableServer(server)
        let limits = try await server.client.attachmentUploadLimits()
        XCTAssertEqual(limits.maxFileBytes, 20 * 1024 * 1024)
        XCTAssertEqual(limits.maxMediaBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(limits.mediaTypes, ["video/*", "audio/*"])
        XCTAssertNil(limits.maxTotalBytes)
        XCTAssertEqual(limits.resumable?.idleTimeoutSecs, 86400)
        XCTAssertEqual(limits.resumable?.maxActive, 32)
        XCTAssertTrue(limits.isReported)
        XCTAssertEqual(limits.limit(forMimeType: "video/quicktime"), 1024 * 1024 * 1024)
        XCTAssertEqual(limits.limit(forMimeType: "audio/mpeg"), 1024 * 1024 * 1024)
        XCTAssertEqual(limits.limit(forMimeType: "image/png"), 20 * 1024 * 1024)
        XCTAssertEqual(limits.chunkBytes, 8, "the server's hint")

        _ = try await server.client.attachmentUploadLimits()
        XCTAssertEqual(server.calls("upload_limits").count, 1, "asked once per server")
    }

    func testTheServersChunkHintIsUsed() throws {
        let limits = try CodegJSON.decoder.decode(ServerUploadLimits.self, from: Data(#"""
        {"maxFileBytes":20971520,"maxMediaBytes":524288000,"mediaTypes":["video/*","audio/*"],
         "maxTotalBytes":10737418240,"remainingTotalBytes":5368709120,
         "resumable":{"chunkBytesHint":8388608,"idleTimeoutSecs":86400,"maxActive":32}}
        """#.utf8))
        XCTAssertEqual(limits.chunkBytes, 8 * 1024 * 1024)
        XCTAssertEqual(limits.maxMediaBytes, 500 * 1024 * 1024)
        XCTAssertEqual(limits.maxTotalBytes, 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(limits.remainingTotalBytes, 5 * 1024 * 1024 * 1024)
    }

    func testAnOlderServerGetsTheTwentyMegabyteUpload() async throws {
        let replies: [MockCodegServer.Reply] = [
            .status(501, #"{"code":"not_implemented","message":"API endpoint 'upload_limits' is not available in web mode"}"#),
            .status(404, "{}"),
            .body("null"),
        ]
        for reply in replies {
            let old = MockCodegServer()
            old.on("upload_limits") { _ in reply }
            let limits = try await old.client.attachmentUploadLimits()
            XCTAssertEqual(limits, .legacy)
            XCTAssertFalse(limits.isReported)
            XCTAssertNil(limits.resumable)
            XCTAssertEqual(limits.maxMediaBytes, AttachmentUploadLimits.maxBytes)
        }
    }

    func testAJobOnAnOlderServerUploadsInOneRequest() async throws {
        server.on("upload_limits") { _ in .status(501, #"{"code":"not_implemented","message":"not available"}"#) }
        server.on("upload_attachment") { _ in
            .body(#"{"path":"/srv/uploads/b/take.mov","name":"take.mov","size":20,"mimeType":"video/quicktime"}"#)
        }
        let upload = job(try pickedFile())
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment").count, 1)
        XCTAssertTrue(server.calls("upload_attachment_create").isEmpty)
        XCTAssertFalse(upload.offersQuality, "nothing to choose on a 20 MiB server")
        XCTAssertFalse(upload.isResumable)
    }

    func testAJobWhoseLimitsCantBeReadSaysWhyAndTriesAgain() async throws {
        server.on("upload_limits") { _ in .fail(.notConnectedToInternet) }
        let upload = job(try pickedFile())
        upload.start()
        await upload.finish()
        XCTAssertNotNil(upload.failure)
        let fake = FakeResumableServer(server)
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(fake.files.values.first, content)
    }

    // MARK: - The resumable upload

    func testAVideoGoesUpInPiecesAndCompletes() async throws {
        let fake = FakeResumableServer(server)
        let file = try pickedFile()
        let upload = job(file)
        upload.start()
        await upload.finish()

        XCTAssertEqual(upload.phase, .done)
        XCTAssertTrue(upload.isResumable)
        let create = try XCTUnwrap(server.calls("upload_attachment_create").first)
        XCTAssertEqual(create.body["fileName"] as? String, "take.mov")
        XCTAssertEqual(create.body["size"] as? Int, 20)
        XCTAssertEqual(create.body["mimeType"] as? String, "video/mp4")
        XCTAssertEqual(create.body["sessionId"] as? String, "conv-1-claude_code-7", "the conversation's bucket")
        let pieces = server.calls("upload_attachment_chunk")
        XCTAssertEqual(pieces.map(\.method), ["PUT", "PUT", "PUT"])
        XCTAssertEqual(pieces.map { $0.query["uploadId"] }, ["up1", "up1", "up1"])
        XCTAssertEqual(fake.pieceOffsets, [0, 8, 16])
        XCTAssertEqual(pieces.map(\.raw.count), [8, 8, 4])
        XCTAssertEqual(server.calls("upload_attachment_complete").first?.body["uploadId"] as? String, "up1")
        XCTAssertTrue(server.calls("upload_attachment").isEmpty, "no single-request upload")

        XCTAssertEqual(fake.files["/srv/uploads/conv-1-claude_code-7/take.mov"], content, "byte for byte")
        XCTAssertEqual(upload.uploaded?.path, "/srv/uploads/conv-1-claude_code-7/take.mov")
        XCTAssertEqual(upload.sentBytes, 20)
        XCTAssertEqual(upload.totalBytes, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path),
                       "the copy on the iPhone is gone once the server has it")
        guard case .resourceLink(let uri, _, _) = Attachment(upload: upload).promptInputBlock else {
            return XCTFail("not a resource link")
        }
        XCTAssertEqual(uri, "file:///srv/uploads/conv-1-claude_code-7/take.mov")
    }

    func testADroppedPieceGoesOnFromWhatTheServerKept() async throws {
        let fake = FakeResumableServer(server)
        fake.script(.normal, .drop(after: 3))
        let upload = job(try pickedFile())
        upload.start()
        await upload.finish()

        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment_status").count, 1, "it asked where the upload stood")
        XCTAssertEqual(fake.pieceOffsets, [0, 8, 11, 19], "the three bytes that landed aren't sent again")
        XCTAssertEqual(server.calls("upload_attachment_create").count, 1)
        XCTAssertEqual(fake.files.values.first, content)
    }

    func testAPieceAtTheWrongOffsetStartsWhereTheServerSays() async throws {
        let fake = FakeResumableServer(server)
        fake.stray = content.prefix(4)
        let upload = job(try pickedFile())
        upload.start()
        await upload.finish()

        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(fake.pieceOffsets, [0, 4, 12], "409 offsetMismatch carried the offset")
        XCTAssertTrue(server.calls("upload_attachment_status").isEmpty, "the refusal said where to go on")
        XCTAssertEqual(fake.files.values.first, content)
    }

    func testASupersededPieceAsksWhereTheUploadStands() async throws {
        let fake = FakeResumableServer(server)
        fake.script(.normal, .superseded)
        let upload = job(try pickedFile())
        upload.start()
        await upload.finish()

        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment_status").count, 1)
        XCTAssertEqual(fake.pieceOffsets, [0, 8, 8, 16])
        XCTAssertEqual(fake.files.values.first, content)
    }

    func testAnUploadTheServerLostStartsOver() async throws {
        let fake = FakeResumableServer(server)
        fake.script(.normal, .forget)
        let upload = job(try pickedFile())
        upload.start()
        await upload.finish()

        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment_create").count, 2, "a restarted server keeps no uploads")
        XCTAssertEqual(fake.pieceOffsets, [0, 8, 0, 8, 16])
        XCTAssertEqual(server.calls("upload_attachment_chunk").last?.query["uploadId"], "up2")
        XCTAssertEqual(fake.files.values.first, content)
    }

    func testRepeatedFailuresGiveUpAndTryAgainGoesOn() async throws {
        let fake = FakeResumableServer(server)
        let file = try pickedFile()
        let upload = job(file)
        fake.script(.normal, .serverError, .serverError, .serverError, .serverError,
                    .serverError, .serverError, .serverError, .serverError)
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.failure, "Failed to write upload chunk")
        XCTAssertEqual(fake.held("up1"), 8, "the server keeps the upload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "and the iPhone its copy")

        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment_create").count, 1, "Try Again goes on with the same upload")
        XCTAssertEqual(fake.files.values.first, content)
    }

    func testRemovingTheAttachmentCancelsTheUploadOnTheServer() async throws {
        let fake = FakeResumableServer(server)
        fake.script(.normal, .serverError)
        let file = try pickedFile()
        let upload = job(file)
        upload.retryBackoff = [.seconds(30)]
        upload.start()
        let waiting = await eventually {
            if case .waiting(_, .network) = upload.phase { return true }
            return false
        }
        XCTAssertTrue(waiting, "\(upload.phase)")
        XCTAssertEqual(fake.held("up1"), 8)

        upload.cancel()
        let cancelled = await eventually { fake.cancelled == ["up1"] }
        XCTAssertTrue(cancelled)
        XCTAssertNil(fake.held("up1"), "the server dropped it and its bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(server.calls("upload_attachment_complete").isEmpty)
    }

    func testAnUploadPausesInTheBackgroundAndGoesOnWhenTheAppIsBack() async throws {
        let fake = FakeResumableServer(server)
        fake.script(.normal, .serverError)
        let lifecycle = AttachmentUploadLifecycle(observesApp: false)
        let upload = job(try pickedFile(), lifecycle: lifecycle)
        upload.retryBackoff = [.seconds(30)]
        upload.start()
        XCTAssertEqual(lifecycle.activeCount, 1)
        let waiting = await eventually {
            if case .waiting(_, .network) = upload.phase { return true }
            return false
        }
        XCTAssertTrue(waiting)

        // iOS is about to suspend the app.
        lifecycle.expire()
        guard case .waiting(let fraction, .background) = upload.phase else {
            return XCTFail("\(upload.phase)")
        }
        XCTAssertEqual(fraction, 0.4, accuracy: 0.01)
        XCTAssertEqual(lifecycle.pausedCount, 1)
        XCTAssertEqual(lifecycle.activeCount, 0)

        // Back in the foreground.
        upload.retryBackoff = [.zero]
        lifecycle.resumePaused()
        XCTAssertEqual(lifecycle.pausedCount, 0)
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment_status").count, 1, "it asked where the upload stood")
        XCTAssertEqual(server.calls("upload_attachment_create").count, 1)
        XCTAssertEqual(fake.files.values.first, content)
        XCTAssertEqual(lifecycle.activeCount, 0)
    }

    func testChoosingCompressedStartsOverAndDropsTheOriginal() async throws {
        let fake = FakeResumableServer(server)
        fake.script(.normal, .serverError)
        let preparer = FakeVideoPreparer()
        let upload = AttachmentUpload(source: .file(try pickedFile()), uploader: server.client, bucket: "b",
                                      preparer: preparer, lifecycle: AttachmentUploadLifecycle(observesApp: false))
        upload.retryBackoff = [.seconds(30)]
        upload.start()
        let waiting = await eventually {
            if case .waiting = upload.phase { return true }
            return false
        }
        XCTAssertTrue(waiting)
        XCTAssertTrue(upload.offersQuality)
        XCTAssertEqual(upload.quality, .original)

        upload.retryBackoff = [.zero]
        upload.setQuality(.compressed)
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(upload.quality, .compressed)
        XCTAssertEqual(preparer.policies.map(\.quality), [.original, .compressed])
        XCTAssertEqual(preparer.policies.first?.maxBytes, 1024 * 1024 * 1024, "the server's media limit")
        let dropped = await eventually { fake.cancelled == ["up1"] }
        XCTAssertTrue(dropped, "the server dropped the original's upload")
        XCTAssertEqual(server.calls("upload_attachment_create").count, 2)
        XCTAssertFalse(upload.offersQuality, "uploaded")
    }

    func testAnAudioFileGoesUpTheSameWay() async throws {
        let fake = FakeResumableServer(server)
        let upload = job(try pickedFile("memo.m4a"))
        XCTAssertEqual(upload.kind, .audio)
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(server.calls("upload_attachment_create").first?.body["mimeType"] as? String, "audio/mp4")
        XCTAssertFalse(upload.offersQuality)
        XCTAssertEqual(fake.files.values.first, content)
    }

    // MARK: - The client calls

    func testAProxyThatRefusesPUTGetsAPOST() async throws {
        _ = FakeResumableServer(server)
        let state = try await server.client.createResumableUpload(fileName: "a.mp4", size: 3, mimeType: "video/mp4",
                                                                  bucket: nil)
        XCTAssertNil(server.calls("upload_attachment_create").first?.body["sessionId"] as? String)
        server.on("upload_attachment_chunk") { call in
            if call.method == "PUT" { return .status(405, "") }
            return .body(#"{"uploadId":"up1","offset":3,"size":3,"complete":true}"#)
        }
        let answer = try await server.client.uploadResumableChunk(uploadId: state.uploadId, offset: 0,
                                                                  data: Data("abc".utf8)) { _ in }
        XCTAssertEqual(server.calls("upload_attachment_chunk").map(\.method), ["PUT", "POST"])
        XCTAssertEqual(server.calls("upload_attachment_chunk").last?.query["offset"], "0")
        XCTAssertTrue(answer.complete)
    }

    func testRefusalsOfTheResumableUploadReadInPlainWords() {
        func parse(_ status: Int, _ body: String) -> AttachmentUploadError {
            AttachmentUploadError.from(status: status, data: Data(body.utf8))
        }
        XCTAssertEqual(parse(409, #"{"message":"x","i18n_key":"errors.upload.offsetMismatch","i18n_params":{"offset":"8388608","sent":"0"}}"#),
                       .offsetMismatch(offset: 8_388_608))
        XCTAssertEqual(parse(409, #"{"message":"x","i18n_key":"errors.upload.superseded"}"#), .superseded)
        XCTAssertEqual(parse(404, #"{"message":"Upload not found or expired","i18n_key":"errors.upload.notFound"}"#),
                       .uploadNotFound)
        XCTAssertEqual(parse(404, "{}"), .unsupportedServer, "a 404 without the key is an older server")
        XCTAssertEqual(parse(409, #"{"message":"x","i18n_key":"errors.upload.incomplete","i18n_params":{"offset":"5","size":"9"}}"#),
                       .incomplete(offset: 5))
        XCTAssertEqual(parse(400, #"{"message":"Too many uploads are in progress","i18n_key":"errors.upload.tooManyInProgress"}"#),
                       .tooManyInProgress)
        XCTAssertEqual(parse(500, #"{"message":"Upload exceeds the maximum allowed size","i18n_key":"errors.upload.tooLarge","i18n_params":{"size":"2000000000","limit":"1073741824"}}"#),
                       .tooLarge(limit: 1_073_741_824), "the limit the server gives")
        XCTAssertEqual(AttachmentUploadError.tooLarge(limit: 1_073_741_824).errorDescription,
                       "The codeg server takes attachments up to 1 GB.")
    }

    func testAPieceIsReadFromItsPlaceInTheFile() async throws {
        let file = try pickedFile()
        let piece = try await ResumableTransfer.read(file, at: 8, length: 8)
        XCTAssertEqual(piece, content.subdata(in: 8..<16))
        do {
            _ = try await ResumableTransfer.read(file, at: 16, length: 8)
            XCTFail("past the end")
        } catch {
            guard case .fileUnreadable? = error as? AttachmentUploadError else { return XCTFail("\(error)") }
        }
    }
}
