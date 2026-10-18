import XCTest
@testable import Codeg

// MARK: - A byte server behind URLProtocol

/// codeg's `/api/workspace_media/<token>/<name>` answered in process, with
/// its Range rules (`workspace_media.rs`): 200 for no Range, 206 for one
/// satisfiable span, 416 past the end, 404 JSON for an unknown token.
final class MockMediaServer: @unchecked Sendable {
    let host = "media-\(UUID().uuidString.lowercased()).test"
    let body: Data
    var contentType = "video/mp4"
    /// Ignore Range and always send the whole file.
    var ignoresRange = false
    private let lock = NSLock()
    private var tokens: Set<String> = []
    private(set) var ranges: [String?] = []

    init(body: Data) {
        self.body = body
        MockMediaProtocol.register(self)
    }

    deinit { MockMediaProtocol.unregister(host) }

    func issue(_ token: String) { lock.withLock { _ = tokens.insert(token) } }
    func revoke(_ token: String) { lock.withLock { _ = tokens.remove(token) } }

    func url(_ token: String, name: String = "clip.mp4") -> URL {
        URL(string: "http://\(host)/api/workspace_media/\(token)/\(name)")!
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockMediaProtocol.self]
        return URLSession(configuration: cfg)
    }()

    fileprivate func answer(path: String, range: String?) -> (Int, [String: String], Data) {
        lock.withLock { ranges.append(range) }
        let parts = path.split(separator: "/")
        let token = parts.count >= 3 ? String(parts[2]) : ""
        guard lock.withLock({ tokens.contains(token) }) else {
            return (404, ["Content-Type": "application/json"],
                    Data(#"{"code":"not_found","message":"Media link is invalid or expired"}"#.utf8))
        }
        let len = body.count
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes"]
        guard !ignoresRange, let range, range.hasPrefix("bytes=") else {
            headers["Content-Length"] = String(len)
            return (200, headers, body)
        }
        let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        var start = Int(spec.first ?? "") ?? -1
        var end = spec.count > 1 ? Int(spec[1]) ?? len - 1 : len - 1
        if spec.first?.isEmpty == true, let suffix = Int(spec[1]) { start = max(0, len - suffix); end = len - 1 }
        guard start >= 0, start < len else {
            headers["Content-Range"] = "bytes */\(len)"
            return (416, headers, Data())
        }
        end = min(end, len - 1)
        headers["Content-Range"] = "bytes \(start)-\(end)/\(len)"
        return (206, headers, body.subdata(in: start..<(end + 1)))
    }
}

final class MockMediaProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: MockMediaServer] = [:]

    static func register(_ server: MockMediaServer) { lock.withLock { servers[server.host] = server } }
    static func unregister(_ host: String) { lock.withLock { _ = servers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, headers, data) = server.answer(path: url.path, range: request.value(forHTTPHeaderField: "Range"))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Minting with a counter

/// Mints capabilities without a server, counting the calls.
final class CountingMinter: MediaCapabilityMinting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mints = 0
    var expiresInSecs = 900
    var delay: Duration = .zero
    var error: Error?

    func mediaCapability(rootPath: String, path: String) async throws -> MediaCapability {
        if delay > .zero { try await Task.sleep(for: delay) }
        let n: Int = lock.withLock { mints += 1; return mints }
        if let error { throw error }
        return MediaCapability(token: String(format: "%032x", n), url: "/api/workspace_media/\(String(format: "%032x", n))/\(path)",
                               filename: path, size: 4096, contentType: "video/mp4", expiresInSecs: expiresInSecs)
    }

    func mediaURL(for capability: MediaCapability) -> URL? {
        URL(string: "http://box.test\(capability.url)")
    }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

// MARK: - Tests

/// Capabilities are minted once per file and again when they lapse; the
/// endpoints are called as codeg web calls them; a stream answers Range
/// requests with the right bytes, and its failures read in plain words.
final class MediaStreamingTests: XCTestCase {

    // MARK: Minting and refresh

    func testOneCapabilityPerFileUntilItLapses() async throws {
        let minter = CountingMinter()
        let clock = TestClock()
        let resolver = MediaStreamResolver(minter: minter, now: { clock.now })

        let first = try await resolver.stream(rootPath: "/w/out", path: "clip.mp4")
        let again = try await resolver.stream(rootPath: "/w/out", path: "clip.mp4")
        XCTAssertEqual(minter.mints, 1)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.url.absoluteString, "http://box.test/api/workspace_media/\(String(format: "%032x", 1))/clip.mp4")

        _ = try await resolver.stream(rootPath: "/w/out", path: "other.mp4")
        XCTAssertEqual(minter.mints, 2, "another file gets its own")

        // A minute before the server's 15-minute idle limit, a new one.
        clock.advance(900 - 61)
        _ = try await resolver.stream(rootPath: "/w/out", path: "clip.mp4")
        XCTAssertEqual(minter.mints, 2)
        clock.advance(2)
        let fresh = try await resolver.stream(rootPath: "/w/out", path: "clip.mp4")
        XCTAssertEqual(minter.mints, 3)
        XCTAssertNotEqual(fresh.capability.token, first.capability.token)
    }

    func testRefreshMintsAgainAndConcurrentCallersShareOneMint() async throws {
        let minter = CountingMinter()
        minter.delay = .milliseconds(50)
        let resolver = MediaStreamResolver(minter: minter)
        _ = try await resolver.stream(rootPath: "/w", path: "a.mp4")
        async let one = resolver.refresh(rootPath: "/w", path: "a.mp4")
        async let two = resolver.refresh(rootPath: "/w", path: "a.mp4")
        let (a, b) = try await (one, two)
        XCTAssertEqual(a, b)
        XCTAssertEqual(minter.mints, 2)
    }

    func testAMintThatFailsIsNotKept() async throws {
        let minter = CountingMinter()
        minter.error = MediaError.missing
        let resolver = MediaStreamResolver(minter: minter)
        do {
            _ = try await resolver.stream(rootPath: "/w", path: "gone.mp4")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MediaError, .missing)
        }
        minter.error = nil
        _ = try await resolver.stream(rootPath: "/w", path: "gone.mp4")
        XCTAssertEqual(minter.mints, 2)
    }

    // MARK: The endpoints, as codeg answers them

    func testMintingSendsTheDirectoryAndNameAndReadsTheCapability() async throws {
        let server = MockCodegServer()
        server.on("workspace_media_capability") { _ in .body("""
        {"token":"0123456789abcdef0123456789abcdef","url":"/api/workspace_media/0123456789abcdef0123456789abcdef/clip%20one.mp4",
         "filename":"clip one.mp4","size":58508,"contentType":"video/mp4","expiresInSecs":900}
        """) }
        let ref = MediaRef(path: "/Users/j/proj/out/clip one.mp4", format: MediaFormats.format(forPath: "x.mp4")!,
                           origin: .link, scope: "t")
        let capability = try await server.client.mediaCapability(rootPath: ref.directory, path: ref.name)
        XCTAssertEqual(capability.size, 58508)
        XCTAssertEqual(capability.expiresInSecs, 900)
        let call = try XCTUnwrap(server.calls("workspace_media_capability").first)
        XCTAssertEqual(call.body["rootPath"] as? String, "/Users/j/proj/out")
        XCTAssertEqual(call.body["path"] as? String, "clip one.mp4")
        XCTAssertEqual(server.client.mediaURL(for: capability)?.absoluteString,
                       "http://\(server.host)/api/workspace_media/0123456789abcdef0123456789abcdef/clip%20one.mp4")
    }

    func testTheStreamURLKeepsAReverseProxyPath() {
        let client = CodegClient(baseURL: URL(string: "https://box.example/codeg")!, token: "t")
        let capability = MediaCapability(token: "ab", url: "/api/workspace_media/ab/x.mp4", filename: "x.mp4",
                                         size: 1, contentType: "video/mp4", expiresInSecs: 900)
        XCTAssertEqual(client.mediaURL(for: capability)?.absoluteString, "https://box.example/codeg/api/workspace_media/ab/x.mp4")
        let hostile = MediaCapability(token: "ab", url: "/api/../etc/passwd", filename: "x", size: 1,
                                      contentType: "video/mp4", expiresInSecs: 900)
        XCTAssertNil(client.mediaURL(for: hostile))
    }

    func testRefusalsReadInPlainWords() async {
        let server = MockCodegServer()
        let cases: [(MockCodegServer.Reply, MediaError)] = [
            (.status(400, #"{"code":"invalid_input","message":"Only video files can be streamed for preview"}"#), .notStreamable),
            (.status(404, #"{"code":"not_found","message":"File does not exist"}"#), .missing),
            (.status(404, #"{"code":"not_found","message":"Workspace folder does not exist"}"#), .folderMissing),
            (.status(400, #"{"code":"invalid_input","message":"Path cannot contain '..'"}"#), .outsideFolder),
            (.status(400, #"{"code":"invalid_input","message":"Path is outside workspace root"}"#), .outsideFolder),
            (.status(501, #"{"code":"not_implemented","message":"API endpoint 'workspace_media_capability' is not available in web mode"}"#), .unsupportedServer),
        ]
        for (reply, expected) in cases {
            server.on("workspace_media_capability") { _ in reply }
            do {
                _ = try await server.client.mediaCapability(rootPath: "/w", path: "a.m4a")
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? MediaError, expected)
                XCTAssertNotNil((error as? MediaError)?.errorDescription)
            }
        }
    }

    func testADownloadKeepsTheFileAndRefusesTooMuch() async throws {
        let server = MockCodegServer()
        server.on("download_workspace_file") { _ in .body("RIFF-pretend-audio") }
        let file = try await server.client.downloadWorkspaceFile(rootPath: "/w", path: "tone.wav", maxBytes: 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("RIFF-pretend-audio".utf8))
        XCTAssertEqual(file.pathExtension, "wav")
        let call = try XCTUnwrap(server.calls("download_workspace_file").first)
        XCTAssertEqual(call.body["rootPath"] as? String, "/w")
        XCTAssertEqual(call.body["path"] as? String, "tone.wav")

        do {
            _ = try await server.client.downloadWorkspaceFile(rootPath: "/w", path: "tone.wav", maxBytes: 4)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? MediaError, .tooLarge(18))
        }

        server.on("download_workspace_file") { _ in .status(404, #"{"code":"not_found","message":"File does not exist"}"#) }
        do {
            _ = try await server.client.downloadWorkspaceFile(rootPath: "/w", path: "gone.png", maxBytes: 1024)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MediaError, .missing)
        }
    }

    // MARK: Range

    private func sample(_ count: Int = 4096) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
    }

    func testARangeRequestGetsExactlyThoseBytes() async throws {
        let body = sample()
        let server = MockMediaServer(body: body)
        let token = String(repeating: "a", count: 32)
        server.issue(token)

        let head = try await MediaProbe.head(server.url(token), session: MockMediaServer.session)
        XCTAssertTrue(head.acceptsRanges)
        XCTAssertEqual(head.totalLength, 4096)
        XCTAssertEqual(head.contentType, "video/mp4")
        XCTAssertEqual(head.head, body.prefix(16))

        let middle = try await MediaProbe.read(server.url(token), start: 1000, end: 1999, session: MockMediaServer.session)
        XCTAssertEqual(middle.head, body.subdata(in: 1000..<2000))
        XCTAssertEqual(middle.totalLength, 4096)

        let tail = try await MediaProbe.read(server.url(token), start: 4000, end: 9999, session: MockMediaServer.session)
        XCTAssertEqual(tail.head, body.subdata(in: 4000..<4096), "an end past the file is clamped")

        let past = try await MediaProbe.read(server.url(token), start: 5000, end: 5100, session: MockMediaServer.session)
        XCTAssertEqual(past.totalLength, 4096, "a 416 still says the length")
        XCTAssertTrue(past.head.isEmpty)

        XCTAssertEqual(server.ranges, ["bytes=0-15", "bytes=1000-1999", "bytes=4000-9999", "bytes=5000-5100"])
    }

    func testAServerThatIgnoresRangeIsToldApart() async throws {
        let body = sample(64)
        let server = MockMediaServer(body: body)
        server.ignoresRange = true
        let token = String(repeating: "b", count: 32)
        server.issue(token)
        let probe = try await MediaProbe.head(server.url(token), session: MockMediaServer.session)
        XCTAssertFalse(probe.acceptsRanges)
        XCTAssertEqual(probe.totalLength, 64)
        XCTAssertEqual(probe.head, body.prefix(16))
    }

    func testAnExpiredLinkSaysSo() async {
        let server = MockMediaServer(body: sample())
        let token = String(repeating: "c", count: 32)
        server.issue(token)
        server.revoke(token)
        do {
            _ = try await MediaProbe.head(server.url(token), session: MockMediaServer.session)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MediaError, .expired)
            XCTAssertTrue((error as? MediaError)?.isExpired == true)
        }
    }

    func testAWebMFileIsRecognisedFromItsFirstBytes() async throws {
        var body = Data([0x1A, 0x45, 0xDF, 0xA3])
        body.append(sample(60))
        let server = MockMediaServer(body: body)
        server.contentType = "video/webm"
        let token = String(repeating: "d", count: 32)
        server.issue(token)
        let probe = try await MediaProbe.head(server.url(token, name: "a.webm"), session: MockMediaServer.session)
        XCTAssertTrue(probe.isMatroska)
    }

    func testContentRangeLengths() {
        XCTAssertEqual(MediaProbe.totalLength(contentRange: "bytes 0-15/2048"), 2048)
        XCTAssertEqual(MediaProbe.totalLength(contentRange: "bytes */2048"), 2048)
        XCTAssertNil(MediaProbe.totalLength(contentRange: "bytes 0-15/*"))
        XCTAssertNil(MediaProbe.totalLength(contentRange: nil))
    }
}
