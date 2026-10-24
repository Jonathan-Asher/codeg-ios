import UniformTypeIdentifiers
import XCTest
@testable import Codeg

/// Attaching a document from Files: a PDF, a Word or text file, anything that
/// isn't a picture, a video or audio. It is uploaded as it is (in pieces on a
/// server that takes the resumable upload, in one multipart request
/// otherwise) within the server's limit for files, the prompt links it with
/// a `resource_link`, and the message shows it as a document's card.
@MainActor
final class DocumentAttachmentTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []
    private var files: [URL] = []

    private let bucket = "conv-1-claude_code-7"

    override func setUp() async throws {
        server = MockCodegServer()
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        files = []
        server = nil
    }

    /// A file in a folder of the app's own, as the composer copies a pick from Files.
    private func pickedFile(_ name: String = "Report.pdf", bytes: Data = Data("%PDF-1.7 twenty-two by".utf8)) throws -> URL {
        let url = VideoAttachmentPrep.workDirectory().appendingPathComponent(name)
        try bytes.write(to: url)
        files.append(url)
        return url
    }

    /// A file of `size` bytes that takes no room (sparse).
    private func sparseFile(_ name: String, size: Int64) throws -> URL {
        let url = VideoAttachmentPrep.workDirectory().appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        files.append(url)
        return url
    }

    private func job(_ file: URL) -> AttachmentUpload {
        let upload = AttachmentUpload(source: .file(file), displayName: file.lastPathComponent, uploader: server.client,
                                      bucket: bucket, preparer: FakeVideoPreparer(),
                                      lifecycle: AttachmentUploadLifecycle(observesApp: false))
        upload.retryBackoff = [.zero]
        return upload
    }

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

    /// The block as it goes in `acp_prompt`.
    private func wire(_ block: PromptInputBlock) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: CodegJSON.encoder.encode(block))
        return try XCTUnwrap(object as? [String: String])
    }

    // MARK: - Where a file from Files goes

    func testFilesRoutesEachFileByItsType() {
        let documents = ["Report.pdf", "REPORT.PDF", "Letter.docx", "Budget.xlsx", "Deck.pptx", "Talk.key",
                         "notes.md", "notes.txt", "data.csv", "config.json", "main.swift", "app.ts", "archive.zip",
                         "Makefile", "blob.unknownext"]
        for name in documents {
            XCTAssertEqual(PickedFileRoute.route(forFileNamed: name), .upload(.document), name)
        }
        for name in ["photo.png", "IMG_0001.HEIC", "shot.jpg", "anim.gif"] {
            XCTAssertEqual(PickedFileRoute.route(forFileNamed: name), .picture, name)
        }
        // Tried as a picture first; one the iPhone can't decode goes as a document.
        XCTAssertEqual(PickedFileRoute.route(forFileNamed: "drawing.svg"), .picture)
        XCTAssertEqual(AttachmentSource.file(URL(fileURLWithPath: "/tmp/drawing.svg")).kind, .document)
        for name in ["clip.mov", "IMG_0002.MOV", "clip.mp4", "talk.webm"] {
            XCTAssertEqual(PickedFileRoute.route(forFileNamed: name), .upload(.video), name)
        }
        for name in ["memo.m4a", "song.mp3", "take.wav"] {
            XCTAssertEqual(PickedFileRoute.route(forFileNamed: name), .upload(.audio), name)
        }
        XCTAssertEqual(AttachmentSource.file(URL(fileURLWithPath: "/tmp/Report.pdf")).kind, .document)
        XCTAssertEqual(AttachmentSource.file(URL(fileURLWithPath: "/tmp/IMG_0002.MOV")).kind, .video,
                       "the camera's recording is still a video")
        XCTAssertTrue(AttachmentSource.file(URL(fileURLWithPath: "/tmp/memo.m4a")).isAudio)
        XCTAssertFalse(AttachmentSource.file(URL(fileURLWithPath: "/tmp/Report.pdf")).isAudio)
        XCTAssertTrue(PickedFileRoute.importableTypes.contains(.data), "any regular file can be picked")
        XCTAssertTrue(PickedFileRoute.importableTypes.contains(.pdf))
    }

    func testAFolderOrAPackageIsNotAttached() throws {
        let folder = VideoAttachmentPrep.workDirectory().appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        files.append(folder)
        XCTAssertEqual(PickedFileRoute.route(for: folder), .folder)
        XCTAssertEqual(PickedFileRoute.route(for: try pickedFile()), .upload(.document))

        XCTAssertEqual(PickedFileRoute.folder.notice(forFileNamed: "Projects"),
                       "Projects is a folder. Attach the files in it instead.")
        XCTAssertEqual(PickedFileRoute.package.notice(forFileNamed: "Deck.key"),
                       "Deck.key is a package, not a single file, so it can't be attached.")
        XCTAssertNil(PickedFileRoute.upload(.document).notice(forFileNamed: "Report.pdf"))
        XCTAssertNil(PickedFileRoute.picture.notice(forFileNamed: "photo.png"))
    }

    // MARK: - Its type

    func testTheTypeIsTheOneCodegWebGivesOrTheSystems() {
        let expected = [
            "Report.pdf": "application/pdf",
            "REPORT.PDF": "application/pdf",
            "notes.md": "text/markdown",
            "notes.txt": "text/plain",
            "data.csv": "text/csv",
            "config.json": "application/json",
            "app.ts": "text/typescript",
            "Letter.docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "Budget.xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "archive.zip": "application/zip",
            "Makefile": "application/octet-stream",
            "blob.unknownext": "application/octet-stream",
        ]
        for (name, mime) in expected {
            XCTAssertEqual(DocumentAttachmentPrep.mimeType(forFileNamed: name), mime, name)
        }
        XCTAssertTrue(DocumentAttachmentPrep.mimeType(forFileNamed: "main.swift").hasPrefix("text/"),
                      "source code without a registered type is text")
        XCTAssertEqual(AttachmentUpload.mimeType(for: .document, fileName: "Report.pdf"), "application/pdf")
        XCTAssertEqual(AttachmentUpload.mimeType(for: .video, fileName: "clip.mov"), "video/quicktime")
        XCTAssertEqual(AttachmentUpload.mimeType(for: .audio, fileName: "memo.mp3"), "audio/mpeg")
        XCTAssertEqual(DocumentAttachmentPrep.symbol(forFileNamed: "Report.pdf"), "doc.richtext")
        XCTAssertEqual(DocumentAttachmentPrep.symbol(forFileNamed: "notes.md"), "doc")
    }

    // MARK: - Its size

    func testTheSizeNoticeNamesTheFileAndTheLimit() {
        XCTAssertEqual(DocumentAttachmentError.tooLarge(name: "Report.pdf", size: 23 * 1024 * 1024,
                                                        limit: 20 * 1024 * 1024).errorDescription,
                       "Report.pdf is 23 MB; codeg takes documents up to 20 MB.")
        XCTAssertEqual(DocumentAttachmentError.tooLarge(name: "Report.pdf", size: 20 * 1024 * 1024 + 1,
                                                        limit: 20 * 1024 * 1024).errorDescription,
                       "Report.pdf is over 20 MB; codeg takes documents up to 20 MB.",
                       "never \"20 MB; … up to 20 MB\"")
        XCTAssertEqual(DocumentAttachmentError.empty(name: "notes.txt").errorDescription,
                       "notes.txt is empty, so it wasn't attached.")
    }

    func testWithoutReportedLimitsADocumentOverTwentyMegabytesIsRefusedBeforeItIsSent() async throws {
        server.on("upload_limits") { _ in .status(404, "{}") }
        let upload = job(try sparseFile("Report.pdf", size: 23 * 1024 * 1024))
        var told: [String] = []
        upload.onRefused = { told.append($0) }
        upload.start()
        await upload.finish()
        XCTAssertEqual(told, ["Report.pdf is 23 MB; codeg takes documents up to 20 MB."])
        XCTAssertEqual(upload.refusal, told.first)
        XCTAssertFalse(upload.isDone)
        XCTAssertTrue(server.calls("upload_attachment").isEmpty, "nothing was sent")
        XCTAssertTrue(server.calls("upload_attachment_create").isEmpty)
    }

    func testTheServersTooLargeAnswerIsTheSameNotice() async throws {
        _ = FakeResumableServer(server)
        server.on("upload_attachment_create") { _ in
            .status(500, #"{"code":"io_error","message":"Upload exceeds the maximum allowed size","i18n_key":"errors.upload.tooLarge","i18n_params":{"size":"22","limit":"16"}}"#)
        }
        let upload = job(try pickedFile())
        var told: [String] = []
        upload.onRefused = { told.append($0) }
        upload.start()
        await upload.finish()
        XCTAssertEqual(told, [try XCTUnwrap(DocumentAttachmentError.tooLarge(name: "Report.pdf", size: 22,
                                                                             limit: 16).errorDescription)])
        XCTAssertTrue(server.calls("upload_attachment_chunk").isEmpty)

        // One request on an older server: its 413 reads the same way.
        let old = MockCodegServer()
        old.on("upload_limits") { _ in .status(501, "{}") }
        old.on("upload_attachment") { _ in .status(413, "Payload Too Large") }
        let legacy = AttachmentUpload(source: .file(try pickedFile("notes.md")), displayName: "notes.md",
                                      uploader: old.client, bucket: bucket,
                                      lifecycle: AttachmentUploadLifecycle(observesApp: false))
        var legacyTold: [String] = []
        legacy.onRefused = { legacyTold.append($0) }
        legacy.start()
        await legacy.finish()
        XCTAssertEqual(legacyTold, [try XCTUnwrap(DocumentAttachmentError.tooLarge(name: "notes.md", size: 22,
                                                                                   limit: 20 * 1024 * 1024).errorDescription)])
    }

    func testAnEmptyDocumentIsRefused() async throws {
        _ = FakeResumableServer(server)
        let upload = job(try pickedFile("notes.txt", bytes: Data()))
        var told: [String] = []
        upload.onRefused = { told.append($0) }
        upload.start()
        await upload.finish()
        XCTAssertEqual(told, ["notes.txt is empty, so it wasn't attached."])
        XCTAssertTrue(server.calls("upload_attachment_create").isEmpty)
    }

    // MARK: - The upload

    func testADocumentGoesUpAsItIsInPiecesAndIsLinked() async throws {
        let fake = FakeResumableServer(server)
        let content = Data("%PDF-1.7 twenty-two by".utf8)
        let file = try pickedFile("Report.pdf", bytes: content)
        let preparer = FakeVideoPreparer()
        let upload = AttachmentUpload(source: .file(file), displayName: "Report.pdf", uploader: server.client,
                                      bucket: bucket, preparer: preparer,
                                      lifecycle: AttachmentUploadLifecycle(observesApp: false))
        upload.retryBackoff = [.zero]
        XCTAssertEqual(upload.kind, .document)
        XCTAssertEqual(upload.totalBytes, Int64(content.count), "its size shows on the chip at once")
        XCTAssertFalse(upload.offersQuality)
        upload.start()
        await upload.finish()

        XCTAssertEqual(upload.phase, .done)
        XCTAssertEqual(preparer.calls, 0, "a document is never compressed")
        let create = try XCTUnwrap(server.calls("upload_attachment_create").first)
        XCTAssertEqual(create.body["fileName"] as? String, "Report.pdf")
        XCTAssertEqual(create.body["size"] as? Int, content.count)
        XCTAssertEqual(create.body["mimeType"] as? String, "application/pdf")
        XCTAssertEqual(create.body["sessionId"] as? String, bucket)
        XCTAssertEqual(fake.pieceOffsets, [0, 8, 16])
        XCTAssertTrue(server.calls("upload_attachment").isEmpty)
        XCTAssertEqual(fake.files["/srv/uploads/\(bucket)/Report.pdf"], content, "byte for byte, as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path),
                       "the copy on the iPhone is gone once the server has it")

        let attachment = Attachment(upload: upload)
        XCTAssertTrue(attachment.isReady)
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.byteCount, 0, "a document doesn't ride in the prompt")
        XCTAssertEqual(try wire(attachment.promptInputBlock), [
            "type": "resource_link",
            "uri": "file:///srv/uploads/\(bucket)/Report.pdf",
            "name": "Report.pdf",
            "mime_type": "application/pdf",
        ])
        XCTAssertEqual(attachment.optimisticBlock, .text("[Report.pdf](file:///srv/uploads/\(bucket)/Report.pdf)"))
    }

    func testOnAnOlderServerADocumentGoesInOneMultipartRequest() async throws {
        server.on("upload_limits") { _ in .status(501, #"{"code":"not_implemented","message":"not available"}"#) }
        server.on("upload_attachment") { _ in
            .body(#"{"path":"/srv/uploads/b/Notes (1).md","name":"Notes (1).md","size":12,"mimeType":"text/markdown"}"#)
        }
        let upload = job(try pickedFile("Notes.md", bytes: Data("# Notes\n- a\n".utf8)))
        upload.start()
        await upload.finish()
        XCTAssertEqual(upload.phase, .done)
        XCTAssertTrue(server.calls("upload_attachment_create").isEmpty)
        let body = String(decoding: try XCTUnwrap(server.calls("upload_attachment").first).raw, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"session_id\"\r\n\r\n\(bucket)\r\n"), body)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"Notes.md\"\r\nContent-Type: text/markdown\r\n\r\n# Notes\n- a\n\r\n"),
                      body)
        XCTAssertEqual(upload.displayName, "Notes (1).md", "the name the server gave it")
        XCTAssertEqual(try wire(Attachment(upload: upload).promptInputBlock), [
            "type": "resource_link",
            "uri": "file:///srv/uploads/b/Notes%20(1).md",
            "name": "Notes (1).md",
            "mime_type": "text/markdown",
        ])
    }

    func testAServerThatDoesntRecordTheTypeGetsTheOneFromTheName() async throws {
        server.on("upload_limits") { _ in .status(501, "{}") }
        server.on("upload_attachment") { _ in
            .body(#"{"path":"/srv/uploads/b/data.csv","name":"data.csv","size":8,"mimeType":null}"#)
        }
        let upload = job(try pickedFile("data.csv", bytes: Data("a,b\n1,2\n".utf8)))
        upload.start()
        await upload.finish()
        XCTAssertEqual(try wire(Attachment(upload: upload).promptInputBlock)["mime_type"], "text/csv")
    }

    // MARK: - Sending

    func testTheMessageWaitsForTheDocumentAndLinksIt() async throws {
        _ = FakeResumableServer(server)
        let model = await openIdleSession()
        model.addMedia(.file(try pickedFile()))
        XCTAssertEqual(model.attachments.first?.upload?.kind, .document)
        XCTAssertEqual(model.attachments.first?.mimeType, "application/pdf")
        model.draft = "Summarize the report."
        // The upload hasn't run yet: the main actor hasn't been given up.
        model.sendFromComposer()
        XCTAssertEqual(model.notice, "Wait for the document to finish uploading.")
        XCTAssertTrue(server.calls("acp_prompt").isEmpty, "nothing goes before the upload is done")
        XCTAssertEqual(model.draft, "Summarize the report.")

        await model.attachments.first?.upload?.finish()
        XCTAssertTrue(model.attachmentsReady)
        model.notice = nil
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let blocks = try XCTUnwrap(server.calls("acp_prompt").first?.body["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(Set(blocks[1].keys), ["type", "uri", "name", "mime_type"], "codeg web's resource_link")
        XCTAssertEqual(blocks[1]["type"] as? String, "resource_link")
        XCTAssertEqual(blocks[1]["uri"] as? String, "file:///srv/uploads/\(bucket)/Report.pdf")
        XCTAssertEqual(blocks[1]["name"] as? String, "Report.pdf")
        XCTAssertEqual(blocks[1]["mime_type"] as? String, "application/pdf")
        let shown = try XCTUnwrap(model.pendingUserTurns.last?.blocks)
        XCTAssertEqual(shown.last, .text("[Report.pdf](file:///srv/uploads/\(bucket)/Report.pdf)"))
        XCTAssertTrue(model.attachments.isEmpty)
    }

    func testADocumentOverTheLimitIsANoticeAndItsChipGoes() async throws {
        _ = FakeResumableServer(server, limits: #"""
        {"maxFileBytes":10,"maxMediaBytes":1073741824,"mediaTypes":["video/*","audio/*"],
         "resumable":{"chunkBytesHint":8,"idleTimeoutSecs":86400,"maxActive":32}}
        """#)
        let model = await openIdleSession()
        let file = try pickedFile()
        model.addMedia(.file(file))
        XCTAssertEqual(model.attachments.count, 1)
        let gone = await eventually { model.attachments.isEmpty }
        XCTAssertTrue(gone, "the chip goes")
        XCTAssertEqual(model.notice, "Report.pdf is 22 bytes; codeg takes documents up to 10 bytes.")
        XCTAssertTrue(server.calls("upload_attachment_create").isEmpty, "nothing was sent")
        XCTAssertTrue(server.calls("upload_attachment").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "and its copy on the iPhone")
    }

    func testADocumentThatDidntUploadSaysSoAndTriesAgain() async throws {
        server.on("upload_limits") { _ in .status(501, "{}") }
        server.on("upload_attachment") { _ in .status(500, #"{"code":"io_error","message":"disk full"}"#) }
        let model = await openIdleSession()
        model.addMedia(.file(try pickedFile()))
        await model.attachments.first?.upload?.finish()
        XCTAssertEqual(model.attachments.first?.upload?.failure, "disk full")
        XCTAssertEqual(model.attachments.count, 1, "a failure that may pass keeps its chip")
        model.draft = "Look"
        model.sendFromComposer()
        XCTAssertEqual(model.notice, "A document didn't upload. Tap it to try again, or remove it.")
        XCTAssertTrue(server.calls("acp_prompt").isEmpty)

        server.on("upload_attachment") { _ in
            .body(#"{"path":"/srv/uploads/b/Report.pdf","name":"Report.pdf","size":22,"mimeType":"application/pdf"}"#)
        }
        let id = try XCTUnwrap(model.attachments.first?.id)
        model.retryAttachment(id)
        await model.attachments.first?.upload?.finish()
        XCTAssertTrue(model.attachmentsReady)
    }

    // MARK: - In the message

    private let context = MediaPathContext(folderPath: "/Users/j/proj", homePath: "/Users/j")

    private func turn(_ id: String, _ role: String, _ texts: [String]) throws -> MessageTurn {
        let blocks = texts.map { text -> [String: String] in ["type": "text", "text": text] }
        let object: [String: Any] = ["id": id, "role": role, "timestamp": "2026-10-24T10:00:00Z", "blocks": blocks]
        let json = try JSONSerialization.data(withJSONObject: object)
        return try CodegJSON.decoder.decode(MessageTurn.self, from: json)
    }

    func testAnAttachedDocumentShowsAsACardInTheMessage() throws {
        let uploads = "/Users/j/.codeg/uploads/\(bucket)"
        let message = try turn("u-doc-1", "user", [
            "Compare these:",
            "[@notes.md](file://\(uploads)/notes.md)",
            "[Report.pdf](file://\(uploads)/Report.pdf)",
            "and look at [main.swift](file:///Users/j/proj/main.swift)",
        ])
        let refs = MediaDetector.references(inTurn: message, context: context)
        XCTAssertEqual(refs.map(\.path), ["\(uploads)/notes.md", "\(uploads)/Report.pdf"],
                       "a file the message only mentions stays a link")
        XCTAssertEqual(refs.map(\.kind), [.document, .document])

        let nodes = TranscriptTimeline.buildPersisted(turns: [message], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false, media: context)
        let group = try XCTUnwrap(nodes.first?.attachedMedia)
        XCTAssertEqual(group.refs.map(\.name), ["notes.md", "Report.pdf"])
        XCTAssertEqual(MediaGroupSummary.text(group.items), "1 PDF · 1 document")
        XCTAssertEqual(MediaSymbols.symbol(for: group.refs[1]), "doc.richtext")

        // The link the optimistic message carries reads back as its card.
        let marker = MediaAttachmentText.marker(name: "Budget (final).csv", path: "/srv/uploads/b/Budget (final).csv")
        XCTAssertEqual(MediaDetector.references(inText: marker, scope: "s", context: context, attachments: true)
            .map(\.path), ["/srv/uploads/b/Budget (final).csv"])

        // An agent's reply isn't an attachment: its link stays a link.
        let reply = try turn("a-doc-1", "assistant", ["[notes.md](file://\(uploads)/notes.md)"])
        XCTAssertEqual(MediaDetector.references(inTurn: reply, context: context), [])

        XCTAssertEqual(MediaFormats.attachment(atPath: "/srv/uploads/b/Makefile")?.kind, .document)
        XCTAssertNil(MediaFormats.attachment(atPath: "/Users/j/proj/Makefile"))
        XCTAssertNil(MediaFormats.attachment(atPath: "/uploads/Makefile"))
    }
}
