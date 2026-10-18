import AVFoundation
import SwiftUI
import UIKit

/// A video's card: the frame to show, its length, its size.
struct VideoPreview: Sendable {
    let poster: UIImage?
    let duration: TimeInterval?
    let size: Int64
}

/// Fetches what the media cards of one server show and play, through the
/// connection the app already has to it (its base URL and token, Tailscale or
/// not).
///
/// - **Video** streams from a capability (`workspace_media_capability`), one
///   per file, minted when a card or the player needs it and again once it
///   lapses (``MediaStreamResolver``). The poster and length come from the
///   same stream: AVFoundation reads only the header and one frame.
/// - **Audio** streams the same way where the server allows it. codeg mints
///   capabilities for video files only, so against such a server the file is
///   downloaded (`download_workspace_file`) and played from the iPhone,
///   up to ``maxAudioBytes``.
/// - **Pictures and documents** are downloaded, decoded off the main thread
///   and scaled down, and kept in ``MediaDiskCache`` and in memory.
///
/// Every request names the file as codeg web does: its directory as
/// `rootPath`, its name as the path.
@MainActor
final class MediaLibrary: MediaSourceProviding {
    let client: CodegClient
    let streams: MediaStreamResolver
    private let disk: MediaDiskCache
    private var downloads: [String: Task<URL, Error>] = [:]
    private var previews: [String: VideoPreview] = [:]
    /// The server answered "only video files can be streamed": audio is
    /// downloaded from then on.
    private(set) var audioStreams = true

    static let maxImageBytes: Int64 = 40 * 1024 * 1024
    static let maxAudioBytes: Int64 = 200 * 1024 * 1024
    static let maxDocumentBytes: Int64 = 100 * 1024 * 1024

    init(client: CodegClient, disk: MediaDiskCache = .shared) {
        self.client = client
        self.disk = disk
        streams = MediaStreamResolver(minter: client)
    }

    private static var libraries: [String: MediaLibrary] = [:]

    /// One library per server connection, kept while the app runs.
    static func shared(for client: CodegClient) -> MediaLibrary {
        let key = "\(client.baseURL.absoluteString)|\(client.token.hashValue)"
        if let existing = libraries[key] { return existing }
        let library = MediaLibrary(client: client)
        libraries[key] = library
        return library
    }

    private var serverKey: String { client.baseURL.absoluteString }

    // MARK: Files

    /// The file on the iPhone, downloaded once and kept in the cache. `scope`
    /// keeps a copy per reply (a file written again under the same name is
    /// fetched again for the newer reply).
    func localFile(for ref: MediaRef, maxBytes: Int64) async throws -> URL {
        let key = "\(serverKey)|\(ref.path)|\(ref.scope)"
        if let hit = disk.lookup(key, ext: ref.ext) { return hit }
        if let running = downloads[key] { return try await running.value }
        let client = self.client
        let disk = self.disk
        let task = Task<URL, Error> {
            let temp = try await client.downloadWorkspaceFile(rootPath: ref.directory, path: ref.name, maxBytes: maxBytes)
            return try disk.store(fileAt: temp, key: key, ext: ref.ext)
        }
        downloads[key] = task
        defer { downloads[key] = nil }
        return try await task.value
    }

    /// The picture, decoded off the main thread at most `maxPixelSize` on its
    /// long side, and kept in memory.
    func image(for ref: MediaRef, maxPixelSize: Int = TranscriptImages.maxPixelSize) async throws -> UIImage {
        let key = "media|\(serverKey)|\(ref.path)|\(ref.scope)|\(maxPixelSize)"
        if let hit = TranscriptImages.cached(key) { return hit }
        let file = try await localFile(for: ref, maxBytes: Self.maxImageBytes)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            return TranscriptImages.downsample(data, maxPixelSize: maxPixelSize)
        }.value
        guard let image else { throw MediaError.unplayable("This picture couldn't be decoded.") }
        TranscriptImages.store(image, key: key)
        return image
    }

    // MARK: Players

    private var players: [String: MediaPlayerModel] = [:]
    private var playerOrder: [String] = []

    /// The inline player of an audio file, kept while the app runs so it
    /// plays on when its row scrolls away and shows where it was when it
    /// comes back.
    func player(for ref: MediaRef) -> MediaPlayerModel {
        let key = "\(ref.path)|\(ref.scope)"
        if let existing = players[key] { return existing }
        let model = MediaPlayerModel(ref: ref, provider: self, engine: AVPlayerEngine(), center: .shared)
        players[key] = model
        playerOrder.append(key)
        // Forget the oldest players that aren't in use.
        while players.count > 24, let index = playerOrder.firstIndex(where: { candidate in
            guard candidate != key else { return false }
            guard let old = players[candidate] else { return true }
            return old.phase != .playing && old.phase != .loading && MediaPlaybackCenter.shared.active !== old
        }) {
            let old = playerOrder.remove(at: index)
            players[old]?.stop()
            players[old] = nil
        }
        return model
    }

    /// A player for one viewing of a video, in the system player.
    func videoPlayer(for ref: MediaRef) -> MediaPlayerModel {
        MediaPlayerModel(ref: ref, provider: self, engine: AVPlayerEngine(), center: .shared)
    }

    // MARK: Streams

    func stream(for ref: MediaRef) async throws -> MediaStream {
        try await streams.stream(rootPath: ref.directory, path: ref.name)
    }

    /// The poster frame and length of a video, from its stream. A link that
    /// has lapsed is minted again once.
    func videoPreview(for ref: MediaRef) async throws -> VideoPreview {
        if let hit = previews[ref.path] { return hit }
        var stream = try await self.stream(for: ref)
        do {
            _ = try await MediaProbe.head(stream.url, session: MediaProbe.session)
        } catch MediaError.expired {
            stream = try await streams.refresh(rootPath: ref.directory, path: ref.name)
            _ = try await MediaProbe.head(stream.url, session: MediaProbe.session)
        }
        let posterKey = "poster|\(serverKey)|\(ref.path)|\(stream.capability.size)"
        let asset = AVURLAsset(url: stream.url)
        let duration = try? await asset.load(.duration)
        var poster: UIImage?
        if let cached = disk.lookup(posterKey, ext: "jpg"), let data = try? Data(contentsOf: cached) {
            poster = UIImage(data: data)
        } else if ref.format.native {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            let seconds = duration.map { min(1, max(0, $0.seconds * 0.1)) } ?? 0
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                let image = UIImage(cgImage: frame)
                poster = image
                if let jpeg = image.jpegData(compressionQuality: 0.8) {
                    try? disk.store(jpeg, key: posterKey, ext: "jpg")
                }
            }
        }
        let seconds = duration.flatMap { $0.isNumeric && $0.seconds > 0 ? $0.seconds : nil }
        let preview = VideoPreview(poster: poster, duration: seconds, size: stream.capability.size)
        previews[ref.path] = preview
        return preview
    }

    // MARK: MediaSourceProviding

    func source(for ref: MediaRef) async throws -> MediaSource {
        if ref.kind == .audio, !audioStreams {
            return .file(try await localFile(for: ref, maxBytes: Self.maxAudioBytes))
        }
        do {
            let stream = try await self.stream(for: ref)
            return .stream(stream.url, mintedAt: stream.mintedAt,
                           idleLimit: TimeInterval(stream.capability.expiresInSecs))
        } catch MediaError.notStreamable where ref.kind == .audio {
            audioStreams = false
            return .file(try await localFile(for: ref, maxBytes: Self.maxAudioBytes))
        } catch MediaError.unsupportedServer where ref.kind == .audio {
            return .file(try await localFile(for: ref, maxBytes: Self.maxAudioBytes))
        }
    }

    func refreshedSource(for ref: MediaRef) async throws -> MediaSource {
        if ref.kind == .audio, !audioStreams { return try await source(for: ref) }
        let stream = try await streams.refresh(rootPath: ref.directory, path: ref.name)
        return .stream(stream.url, mintedAt: stream.mintedAt, idleLimit: TimeInterval(stream.capability.expiresInSecs))
    }

    func diagnose(_ source: MediaSource, ref: MediaRef) async -> MediaError? {
        guard case .stream(let url, _, _) = source else { return nil }
        do {
            let probe = try await MediaProbe.head(url, session: MediaProbe.session)
            if probe.isMatroska {
                return .unplayable("\(ref.ext.uppercased()) (Matroska) files don't play on the iPhone.")
            }
            return nil
        } catch {
            return MediaError.from(error)
        }
    }
}

// MARK: - Environment

/// The session screen's media: the library of its server and where its paths
/// point. Absent elsewhere, where no media cards show.
struct MediaEnvironment {
    let library: MediaLibrary
    let context: MediaPathContext
}

private struct MediaEnvironmentKey: EnvironmentKey {
    static let defaultValue: MediaEnvironment? = nil
}

extension EnvironmentValues {
    var codegMedia: MediaEnvironment? {
        get { self[MediaEnvironmentKey.self] }
        set { self[MediaEnvironmentKey.self] = newValue }
    }
}
