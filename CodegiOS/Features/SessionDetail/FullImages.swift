import Foundation

/// The full pictures behind history previews.
///
/// A server with previews (`imagePreviews` in its health) sends each large
/// picture of a session's history as a small JPEG with a ``FullImageInfo``:
/// the transcript, and the copy of it saved on the phone, carry only that.
/// The full picture is fetched when it is opened (the full-screen viewer, an
/// edited message's attachments) and kept on disk, least recently used out
/// first past a size cap, with complete file protection like the
/// transcripts.
enum FullImages {
    /// Disk room for full pictures.
    static let diskLimit: Int64 = 192 * 1024 * 1024

    static let cache = MediaDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HistoryImages", isDirectory: true),
        limit: diskLimit,
        writeOptions: [.atomic, .completeFileProtection]
    )

    /// A picture whole in a held copy is "large" past this much base64: the
    /// size above which a server with previews sends a preview instead.
    static let largeBase64 = 32 * 1024

    /// The disk cache key of a full picture: its server and its reference.
    static func cacheKey(_ info: FullImageInfo, baseURL: URL) -> String {
        "\(baseURL.absoluteString)|\(info.ref)"
    }

    /// The full picture's file: from the disk cache, else fetched and kept.
    static func file(for info: FullImageInfo, client: CodegClient,
                     cache: MediaDiskCache = FullImages.cache) async throws -> URL {
        let key = cacheKey(info, baseURL: client.baseURL)
        let ext = MediaImageItem.fileExtension(forMIME: info.mimeType)
        if let hit = cache.lookup(key, ext: ext) { return hit }
        let data = try await client.fullImageData(ref: info.ref)
        return try cache.store(data, key: key, ext: ext)
    }

    /// The cached full picture's file, if it was opened before.
    static func cachedFile(for info: FullImageInfo, baseURL: URL,
                           cache: MediaDiskCache = FullImages.cache) -> URL? {
        cache.lookup(cacheKey(info, baseURL: baseURL), ext: MediaImageItem.fileExtension(forMIME: info.mimeType))
    }

    /// `image` whole: itself when it is not a preview, else its full picture
    /// as base64 (an edited message sends its pictures again as they were).
    static func whole(_ image: ImageData, client: CodegClient,
                      cache: MediaDiskCache = FullImages.cache) async throws -> ImageData {
        guard let info = image.fullImage else { return image }
        let url = try await file(for: info, client: client, cache: cache)
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        return ImageData(data: data.base64EncodedString(), mimeType: info.mimeType, uri: image.uri)
    }

    // MARK: Transcripts

    /// The pictures a block carries.
    static func images(in block: ContentBlock) -> [ImageData] {
        switch block {
        case .image(let image): return [image]
        case .imageGeneration(_, let image): return image.map { [$0] } ?? []
        case .toolResult(_, _, _, let images): return images
        default: return []
        }
    }

    /// Pictures in `turns` that came as previews.
    static func previewCount(in turns: [MessageTurn]) -> Int {
        turns.reduce(0) { count, turn in
            count + turn.blocks.reduce(0) { $0 + images(in: $1).filter { $0.fullImage != nil }.count }
        }
    }

    /// Whether `image` is a large picture held whole (not a preview, not a
    /// reference).
    static func isWholeLarge(_ image: ImageData) -> Bool {
        image.fullImage == nil && image.dataRef == nil && image.data.utf8.count > largeBase64
    }

    /// The global index of the first server turn of `window` that holds a
    /// large picture whole, if any.
    static func firstWholeLargeImage(in window: TranscriptWindow) -> Int? {
        window.serverTurns.firstIndex { turn in
            turn.blocks.contains { images(in: $0).contains(where: isWholeLarge) }
        }.map { window.offset + ($0 - window.serverTurns.startIndex) }
    }
}

extension MediaImageItem {
    /// The full picture behind a history preview, from the disk cache or
    /// the server.
    static func fullImage(_ info: FullImageInfo, client: CodegClient) -> MediaImageItem {
        MediaImageItem(name: "Image") {
            try await FullImages.file(for: info, client: client)
        }
    }
}
