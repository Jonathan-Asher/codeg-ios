import XCTest
@testable import Codeg

/// History pictures as previews: the app asks for them, keeps the preview and
/// its reference (not the picture) in the saved copy, opens the full picture
/// from the server once and from the disk after that, sends an edited
/// message's pictures whole, reads a copy saved before previews again once,
/// and says what the last history read cost.
@MainActor
final class ImagePreviewTests: XCTestCase {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    private static let imageID = "9f2c4b1d0e3a5f6789abcdef01234567"
    private static let ref = "/api/conversation_image/7/\(imageID)"

    private var server: MockCodegServer!
    private var root: URL!

    override func setUp() async throws {
        server = MockCodegServer()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("previews-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        server = nil
    }

    private func blocks(_ json: String) throws -> [ContentBlock] {
        try CodegJSON.decoder.decode([ContentBlock].self, from: Data(json.utf8))
    }

    private static let fullImageJSON = """
    {"ref": "\(ref)", "id": "\(imageID)", "mime_type": "image/png", "bytes": 612345, "width": 1920, "height": 1080}
    """

    private var info: FullImageInfo {
        FullImageInfo(ref: Self.ref, id: Self.imageID, mimeType: "image/png", bytes: 612_345, width: 1920, height: 1080)
    }

    // MARK: Wire

    func testAPreviewArrivesWithItsFullPicture() throws {
        let decoded = try blocks("""
        [{"type": "tool_result", "tool_use_id": "toolu_shot", "is_error": false,
          "images": [{"data": "\(Self.png)", "mime_type": "image/jpeg", "full_image": \(Self.fullImageJSON)}]},
         {"type": "image", "data": "\(Self.png)", "mime_type": "image/jpeg", "full_image": \(Self.fullImageJSON)},
         {"type": "image", "data": "\(Self.png)", "mime_type": "image/png", "full_image": 7}]
        """)
        guard case .toolResult(_, _, _, let images) = decoded[0] else { return XCTFail("not a result") }
        XCTAssertEqual(images.first?.fullImage, info)
        XCTAssertEqual(images.first?.mimeType, "image/jpeg", "what is inline: the preview")
        guard case .image(let attached) = decoded[1] else { return XCTFail("not an image") }
        XCTAssertEqual(attached.fullImage, info)
        // A malformed reference costs the link, not the picture.
        guard case .image(let odd) = decoded[2] else { return XCTFail("not an image") }
        XCTAssertNil(odd.fullImage)
        XCTAssertEqual(odd.data, Self.png)
        XCTAssertEqual(FullImages.previewCount(in: [MessageTurn(id: "t", role: .assistant, blocks: decoded,
                                                                timestamp: Date())]), 2)
    }

    func testAPlaceholderSaysSo() throws {
        let decoded = try blocks("""
        [{"type": "image", "data": "\(Self.png)", "mime_type": "image/png",
          "full_image": {"ref": "\(Self.ref)", "id": "\(Self.imageID)", "mime_type": "image/heic",
                         "bytes": 2048000, "placeholder": true}}]
        """)
        guard case .image(let image) = decoded[0] else { return XCTFail("not an image") }
        XCTAssertEqual(image.fullImage?.placeholder, true)
        XCTAssertEqual(image.fullImage?.mimeType, "image/heic")
        XCTAssertNil(image.fullImage?.width)
    }

    func testHistoryReadsAskForPreviews() async throws {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail()) }
        server.on("get_folder_conversation_turns") { _ in
            .body(#"{"turns": [], "turns_offset": 0, "turns_total": 0, "assistant_turns_before_offset": 0, "user_turns_before_offset": 0, "prefix_hash": "cbf29ce484222325", "prefix_hash_before_index": "cbf29ce484222325"}"#)
        }
        let client = server.client
        let (_, timing) = try await client.conversationDetailTimed(id: 7, window: .tail(40))
        _ = try await client.conversationDetail(id: 7, window: .from(index: 3, expected: "x"))
        _ = try await client.conversationTurnsPage(id: 7, beforeIndex: 10, limit: 5)
        let reads = server.calls("get_folder_conversation")
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.map { $0.body["imagePreviews"] as? Bool }, [true, true])
        XCTAssertEqual(reads.first?.body["tailTurns"] as? Int, 40)
        XCTAssertEqual(server.calls("get_folder_conversation_turns").first?.body["imagePreviews"] as? Bool, true)
        XCTAssertEqual(timing.bodyBytes, Fixtures.detail().utf8.count)
        XCTAssertGreaterThan(timing.wireBytes, 0)
        XCTAssertEqual(timing.previews, 0)
        XCTAssertNil(timing.server, "the mock sends no Server-Timing")
    }

    // MARK: The saved copy

    func testTheSavedCopyKeepsThePreviewAndItsReference() async throws {
        let preview = ImageData(data: Self.png, mimeType: "image/jpeg", uri: nil, fullImage: info)
        let turn = MessageTurn(id: "turn-0", role: .assistant,
                               blocks: [.toolResult(id: "t", outputPreview: nil, isError: false, images: [preview]),
                                        .image(preview)],
                               timestamp: Date(timeIntervalSince1970: 1_791_129_600), serverMillis: 1_791_129_600_000)
        let data = try TranscriptCache.encoder.encode(turn)
        let back = try TranscriptCache.decoder.decode(MessageTurn.self, from: data)
        XCTAssertEqual(back, turn)
        XCTAssertLessThan(data.count, 2_000, "the preview and its reference, not the picture")
    }

    // MARK: Full pictures

    private func diskCache() -> MediaDiskCache {
        MediaDiskCache(directory: root, limit: 1024 * 1024)
    }

    func testTheFullPictureIsFetchedOnceThenReadFromTheDisk() async throws {
        server.on(Self.imageID) { _ in .body("full picture bytes") }
        let cache = diskCache()
        let first = try await FullImages.file(for: info, client: server.client, cache: cache)
        XCTAssertEqual(try Data(contentsOf: first), Data("full picture bytes".utf8))
        let again = try await FullImages.file(for: info, client: server.client, cache: cache)
        XCTAssertEqual(again, first)
        let gets = server.calls(Self.imageID)
        XCTAssertEqual(gets.count, 1, "the second open reads the disk")
        XCTAssertEqual(gets.first?.method, "GET")
        XCTAssertNotNil(FullImages.cachedFile(for: info, baseURL: server.client.baseURL, cache: cache))
    }

    func testAnEditedMessageSendsItsPicturesWhole() async throws {
        server.on(Self.imageID) { _ in .body("full picture bytes") }
        let preview = ImageData(data: Self.png, mimeType: "image/jpeg", uri: nil, fullImage: info)
        let whole = try await FullImages.whole(preview, client: server.client, cache: diskCache())
        XCTAssertEqual(whole.data, Data("full picture bytes".utf8).base64EncodedString())
        XCTAssertEqual(whole.mimeType, "image/png")
        XCTAssertNil(whole.fullImage)
        XCTAssertNotNil(Attachment(image: whole, index: 0))
        // Never the preview as if it were the picture.
        XCTAssertNil(Attachment(image: preview, index: 0))
        // A picture sent whole goes as it is, with no request.
        let plain = ImageData(data: Self.png, mimeType: "image/png", uri: nil)
        let same = try await FullImages.whole(plain, client: server.client, cache: diskCache())
        XCTAssertEqual(same, plain)
        XCTAssertEqual(server.calls(Self.imageID).count, 1)
    }

    func testAPictureTheServerNoLongerHasFails() async throws {
        server.on(Self.imageID) { _ in .status(404, #""image not found in this conversation""#) }
        do {
            _ = try await FullImages.file(for: info, client: server.client, cache: diskCache())
            XCTFail("a 404 is no picture")
        } catch {}
    }

    // MARK: Copies saved before previews

    private func window(images: [Int: ImageData], count: Int = 10, offset: Int = 100) -> TranscriptWindow {
        let turns = (0..<count).map { index in
            MessageTurn(id: "turn-\(offset + index)", role: index % 2 == 0 ? .user : .assistant,
                        blocks: images[index].map { [.toolResult(id: "t", outputPreview: nil, isError: false, images: [$0])] }
                            ?? [.text("turn \(index)")],
                        timestamp: Date(), serverMillis: 1_791_129_600_000 + Int64(index) * 1000)
        }
        return TranscriptWindow(offset: offset, prefixHash: "0123456789abcdef", total: offset + count, turns: turns)
    }

    func testACopySavedBeforePreviewsIsReadAgainOnce() {
        let whole = ImageData(data: String(repeating: "A", count: FullImages.largeBase64 + 4), mimeType: "image/png",
                              uri: nil)
        let held = window(images: [2: whole])
        XCTAssertEqual(FullImages.firstWholeLargeImage(in: held), 102)
        let key = "server-\(UUID().uuidString)"
        // A server not known to send previews: the usual overlap.
        XCTAssertEqual(TranscriptSync.overlap(8, upgradingImagesIn: held, serverKey: key, conversationID: 7), 8)
        TranscriptSync.notePreviews(serverKey: key)
        let other = "\(key)-b"
        TranscriptSync.notePreviews(serverKey: other)
        // Back to the turn with the whole picture, once.
        XCTAssertEqual(TranscriptSync.overlap(4, upgradingImagesIn: held, serverKey: other, conversationID: 7), 8)
        XCTAssertEqual(TranscriptSync.overlap(4, upgradingImagesIn: held, serverKey: other, conversationID: 7), 4)
        XCTAssertEqual(TranscriptSync.request(for: held, overlap: 8),
                       .from(index: 102, expected: held.fingerprint(before: 102)!))
        // Previews and small pictures need nothing read again.
        let previews = window(images: [2: ImageData(data: Self.png, mimeType: "image/jpeg", uri: nil, fullImage: info),
                                       5: ImageData(data: Self.png, mimeType: "image/png", uri: nil)])
        XCTAssertNil(FullImages.firstWholeLargeImage(in: previews))
        XCTAssertEqual(TranscriptSync.overlap(4, upgradingImagesIn: previews, serverKey: key, conversationID: 8), 4)
    }

    // MARK: What a read cost

    func testTheServersShareIsReadFromServerTiming() {
        XCTAssertEqual(HistoryLoadTiming.serverSeconds(fromServerTiming: "app;dur=12.5, img;dur=3.0"), 0.0125)
        XCTAssertEqual(HistoryLoadTiming.serverSeconds(fromServerTiming: "img;dur=3, app;desc=\"x\";dur=40"), 0.04)
        XCTAssertNil(HistoryLoadTiming.serverSeconds(fromServerTiming: "db;dur=3"))
        XCTAssertNil(HistoryLoadTiming.serverSeconds(fromServerTiming: nil))
        XCTAssertNil(HistoryLoadTiming.serverSeconds(fromServerTiming: "app;dur=fast"))

        let timing = HistoryLoadTiming(wireBytes: 40_960, bodyBytes: 120_000, total: 0.31, server: 0.02, previews: 3)
        XCTAssertEqual(timing.network ?? 0, 0.29, accuracy: 0.0001)
        XCTAssertTrue(timing.summary.contains("0.31"), timing.summary)
        XCTAssertTrue(timing.summary.contains("0.020"), timing.summary)
        let unsplit = HistoryLoadTiming(wireBytes: 1_300_000, bodyBytes: 1_800_000, total: 2.4, server: nil)
        XCTAssertNil(unsplit.network)
        XCTAssertTrue(unsplit.summary.contains("2.40"), unsplit.summary)
    }
}
