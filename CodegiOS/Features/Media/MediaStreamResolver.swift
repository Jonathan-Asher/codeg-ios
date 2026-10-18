import Foundation

/// What streaming a file needs from the server: mint a capability
/// (`workspace_media_capability`). A protocol so the tests can count mints.
protocol MediaCapabilityMinting: Sendable {
    func mediaCapability(rootPath: String, path: String) async throws -> MediaCapability
    func mediaURL(for capability: MediaCapability) -> URL?
}

extension CodegClient: MediaCapabilityMinting {}

/// A capability turned into a URL a player can load, and when it was minted.
struct MediaStream: Equatable, Sendable {
    let url: URL
    let capability: MediaCapability
    let mintedAt: Date
}

/// Mints and keeps streaming capabilities, one per file, and mints a new one
/// when the old one has lapsed.
///
/// codeg keeps a capability alive for `expiresInSecs` (15 minutes) after its
/// last request and eight hours at most. The resolver can't see the requests a
/// player makes, so it counts from the mint and asks again a minute early: a
/// card shown now and played an hour later gets a fresh link. A link that
/// still lapses (the player sat paused past the idle limit) comes back as a
/// 404, and ``refresh(rootPath:path:)`` replaces it.
actor MediaStreamResolver {
    private let minter: MediaCapabilityMinting
    private let now: @Sendable () -> Date
    /// Asked again this long before the server's idle limit.
    static let margin: TimeInterval = 60
    /// codeg's hard lifetime (`MEDIA_CAPABILITY_MAX_LIFETIME_SECS`).
    static let maxLifetime: TimeInterval = 8 * 60 * 60

    private var streams: [String: MediaStream] = [:]
    private var inFlight: [String: Task<MediaStream, Error>] = [:]

    init(minter: MediaCapabilityMinting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.minter = minter
        self.now = now
    }

    private static func key(_ rootPath: String, _ path: String) -> String { "\(rootPath)\u{0}\(path)" }

    /// A stream for the file, minted now or still fresh.
    func stream(rootPath: String, path: String) async throws -> MediaStream {
        let key = Self.key(rootPath, path)
        if let cached = streams[key], isFresh(cached) { return cached }
        return try await mint(key: key, rootPath: rootPath, path: path)
    }

    /// Drop the file's capability and mint another (the player was told the
    /// link expired). Concurrent callers share one mint.
    func refresh(rootPath: String, path: String) async throws -> MediaStream {
        let key = Self.key(rootPath, path)
        streams[key] = nil
        return try await mint(key: key, rootPath: rootPath, path: path)
    }

    /// The cached stream, fresh or not (a card's size and type).
    func cached(rootPath: String, path: String) -> MediaStream? {
        streams[Self.key(rootPath, path)]
    }

    func isFresh(_ stream: MediaStream) -> Bool {
        let age = now().timeIntervalSince(stream.mintedAt)
        let idle = TimeInterval(stream.capability.expiresInSecs)
        return age < min(idle, Self.maxLifetime) - Self.margin
    }

    private func mint(key: String, rootPath: String, path: String) async throws -> MediaStream {
        if let running = inFlight[key] { return try await running.value }
        let minter = self.minter
        let now = self.now
        let task = Task<MediaStream, Error> {
            let capability = try await minter.mediaCapability(rootPath: rootPath, path: path)
            guard let url = minter.mediaURL(for: capability) else {
                throw MediaError.server("The server sent a link the app can't use.")
            }
            return MediaStream(url: url, capability: capability, mintedAt: now())
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let stream = try await task.value
        streams[key] = stream
        return stream
    }
}
