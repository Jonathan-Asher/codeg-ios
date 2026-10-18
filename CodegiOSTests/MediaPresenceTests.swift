import XCTest
@testable import Codeg

/// Lists directories from a script, counting the calls.
final class FakeDirectoryLister: MediaDirectoryListing, @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: Result<[DirectoryItem], Error>] = [:]
    private(set) var calls: [String] = []

    func set(_ directory: String, files: [String]) {
        let items = files.map { DirectoryItem(name: $0, path: directory + "/" + $0, isDir: false, hasChildren: false, size: 1200) }
        lock.withLock { listings[directory] = .success(items) }
    }

    func set(_ directory: String, error: Error) {
        lock.withLock { listings[directory] = .failure(error) }
    }

    func listDirectoryWithFiles(path: String) async throws -> [DirectoryItem] {
        let result = lock.withLock { () -> Result<[DirectoryItem], Error>? in
            calls.append(path)
            return listings[path]
        }
        switch result {
        case .success(let items)?: return items
        case .failure(let error)?: throw error
        case nil: throw APIError.server(status: 500, code: "io_error", message: "Path is not a directory")
        }
    }

    func count(_ directory: String) -> Int { lock.withLock { calls.filter { $0 == directory }.count } }
}

/// A card shows only for a file that is on the server: one directory listing
/// answers for every file in it, a file that isn't there never shows (unless
/// the reply wrote it: then it is listed as deleted), and a server that can't
/// say leaves the cards as they were.
@MainActor
final class MediaPresenceTests: XCTestCase {
    private let context = MediaPathContext(folderPath: "/Users/j/proj", homePath: "/Users/j")

    private func ref(_ path: String, origin: MediaRef.Origin = .mention) -> MediaRef {
        MediaRef(path: path, format: MediaFormats.format(forPath: path)!, origin: origin, scope: "t")
    }

    func testOneListingPerDirectoryAnswersEveryFileInIt() async {
        let lister = FakeDirectoryLister()
        lister.set("/Users/j/shots", files: ["a.png", "b.png", "notes.txt"])
        lister.set("/tmp/v", files: ["demo.mp4"])
        let presence = MediaPresence(lister: lister)
        for path in ["/Users/j/shots/a.png", "/Users/j/shots/b.png", "/Users/j/shots/gone.png", "/tmp/v/demo.mp4"] {
            XCTAssertNil(presence.state(of: path), "not checked yet")
            presence.enqueue(path)
        }
        presence.enqueue("/Users/j/shots/a.png")
        await presence.settle()

        XCTAssertEqual(lister.count("/Users/j/shots"), 1)
        XCTAssertEqual(lister.count("/tmp/v"), 1)
        XCTAssertEqual(presence.state(of: "/Users/j/shots/a.png"), .present(size: 1200))
        XCTAssertEqual(presence.state(of: "/Users/j/shots/gone.png"), .missing)
        XCTAssertEqual(presence.state(of: "/tmp/v/demo.mp4"), .present(size: 1200))
        XCTAssertGreaterThan(presence.version, 0)

        // Asked again, it is known: no new listing.
        _ = presence.state(of: "/Users/j/shots/b.png")
        await presence.settle()
        XCTAssertEqual(lister.count("/Users/j/shots"), 1)
    }

    func testAMissingFolderMeansItsFilesAreGoneAndAServerThatCantSayShowsThem() async {
        let lister = FakeDirectoryLister()
        lister.set("/Users/j/Work/legalix", error: APIError.server(status: 500, code: "io_error", message: "Path is not a directory"))
        lister.set("/old/server", error: APIError.server(status: 501, code: "not_implemented",
                                                         message: "API endpoint 'list_directory_with_files' is not available in web mode"))
        lister.set("/offline", error: APIError.transport("The network connection was lost."))
        lister.set("/hidden", files: ["shown.png"])
        let presence = MediaPresence(lister: lister)
        for path in ["/Users/j/Work/legalix/claude-listing.png", "/old/server/a.png", "/offline/b.mp4", "/hidden/.cache.png"] {
            presence.enqueue(path)
        }
        await presence.settle()
        XCTAssertEqual(presence.state(of: "/Users/j/Work/legalix/claude-listing.png"), .missing)
        XCTAssertEqual(presence.state(of: "/old/server/a.png"), .unverified)
        XCTAssertEqual(presence.state(of: "/offline/b.mp4"), .unverified)
        XCTAssertEqual(presence.state(of: "/hidden/.cache.png"), .unverified, "a listing leaves out hidden names")
    }

    func testAFileThatWasMissingIsCheckedAgainLater() async {
        let lister = FakeDirectoryLister()
        lister.set("/tmp/out", files: [])
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let presence = MediaPresence(lister: lister, now: { now })
        presence.enqueue("/tmp/out/clip.mp4")
        await presence.settle()
        XCTAssertEqual(presence.state(of: "/tmp/out/clip.mp4"), .missing)

        // The agent makes it a moment later.
        lister.set("/tmp/out", files: ["clip.mp4"])
        _ = presence.state(of: "/tmp/out/clip.mp4")
        await presence.settle()
        XCTAssertEqual(lister.count("/tmp/out"), 1, "a fresh answer is kept")

        now += MediaPresence.missingLifetime + 1
        XCTAssertEqual(presence.state(of: "/tmp/out/clip.mp4"), .missing, "the stale answer still stands meanwhile")
        await presence.settle()
        XCTAssertEqual(lister.count("/tmp/out"), 2)
        XCTAssertEqual(presence.state(of: "/tmp/out/clip.mp4"), .present(size: 1200))
    }

    // MARK: - The transcript

    private func turn(_ id: String, _ role: String, _ blocks: String) throws -> MessageTurn {
        let json = #"{"id": "\#(id)", "role": "\#(role)", "timestamp": "2026-10-18T10:00:00Z", "blocks": \#(blocks)}"#
        return try CodegJSON.decoder.decode(MessageTurn.self, from: Data(json.utf8))
    }

    /// A reply that writes two pictures (one deleted since), names a video
    /// in full that is there and a picture that isn't.
    private func reply() throws -> MessageTurn {
        try turn("r-1", "assistant", #"""
        [
          {"type": "tool_use", "tool_use_id": "w1", "tool_name": "Write", "input_preview": "{\"file_path\":\"/Users/j/proj/out/kept.png\"}"},
          {"type": "tool_result", "tool_use_id": "w1", "output_preview": "ok", "is_error": false},
          {"type": "tool_use", "tool_use_id": "w2", "tool_name": "Write", "input_preview": "{\"file_path\":\"/Users/j/proj/out/removed.png\"}"},
          {"type": "tool_result", "tool_use_id": "w2", "output_preview": "ok", "is_error": false},
          {"type": "text", "text": "The cut is at /tmp/render/cut.mp4; the old poster /tmp/render/poster.png is gone."}
        ]
        """#)
    }

    func testTheTranscriptShowsOnlyFilesThatAreThere() async throws {
        let lister = FakeDirectoryLister()
        lister.set("/Users/j/proj/out", files: ["kept.png"])
        lister.set("/tmp/render", files: ["cut.mp4"])
        let presence = MediaPresence(lister: lister)
        let question = try turn("q-1", "user", #"[{"type": "text", "text": "cut it"}]"#)

        func build() throws -> [TimelineNode] {
            TranscriptTimeline.buildPersisted(turns: [question, try reply()], pending: [], agent: .claudeCode,
                                              suppressInFlight: false, media: context, presence: presence)
        }
        let first = try build()
        XCTAssertFalse(first.contains { $0.id == "r-1#media" }, "nothing shows before the check answers")
        await presence.settle()
        XCTAssertEqual(lister.calls.count, 2, "one listing per directory")

        let nodes = try build()
        guard let node = nodes.first(where: { $0.id == "r-1#media" }), case .media(let group) = node.content else {
            return XCTFail("no media node")
        }
        XCTAssertEqual(group.items.map(\.ref.name), ["kept.png", "removed.png", "cut.mp4"])
        XCTAssertEqual(group.items.map(\.isDeleted), [false, true, false],
                       "a file the reply wrote is listed as deleted; one it only named is left out")
        XCTAssertEqual(group.items[0].size, 1200)
        XCTAssertEqual(MediaGroupSummary.text(group.items), "1 image · 1 video · 1 deleted")
    }

    func testAMessageWhoseFilesAreAllGoneShowsNothing() async throws {
        let lister = FakeDirectoryLister()
        let presence = MediaPresence(lister: lister)
        // The session's folder, where bare names used to be looked for.
        lister.set("/Users/j/proj", files: ["README.md"])
        let message = try turn("r-2", "assistant", #"""
        [{"type": "text", "text": "See /Users/j/proj/claude-listing.png and /Users/j/proj/l.pdf"}]
        """#)
        _ = TranscriptTimeline.buildPersisted(turns: [message], pending: [], agent: .claudeCode,
                                              suppressInFlight: false, media: context, presence: presence)
        await presence.settle()
        let nodes = TranscriptTimeline.buildPersisted(turns: [message], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false, media: context, presence: presence)
        XCTAssertFalse(nodes.contains { $0.id == "r-2#media" }, "no list of files that are no longer there")
    }

    // MARK: - The folded row

    func testTheFoldedRowSaysWhatIsInIt() {
        let items = [
            MediaItem(ref: ref("/a/1.png")), MediaItem(ref: ref("/a/2.jpg")), MediaItem(ref: ref("/a/3.svg")),
            MediaItem(ref: ref("/a/r.pdf")), MediaItem(ref: ref("/a/clip.mov")), MediaItem(ref: ref("/a/v.m4a")),
            MediaItem(ref: ref("/a/d.docx")), MediaItem(ref: ref("/a/w.mp3")),
        ]
        XCTAssertEqual(MediaGroupSummary.text(items), "3 images · 1 video · 2 audio files · 1 PDF · 1 document")
        XCTAssertEqual(MediaGroupSummary.spoken(items), "3 images, 1 video, 2 audio files, 1 PDF, 1 document")
        XCTAssertEqual(MediaGroupSummary.text([MediaItem(ref: ref("/a/x.png", origin: .written), isDeleted: true)]),
                       "1 deleted file")
    }

    func testOnlyASinglePictureOrVideoShowsInline() {
        XCTAssertTrue(MediaGroup(refs: [ref("/a/1.png")]).showsInline)
        XCTAssertTrue(MediaGroup(refs: [ref("/a/1.mp4")]).showsInline)
        XCTAssertFalse(MediaGroup(refs: [ref("/a/1.png"), ref("/a/2.png")]).showsInline)
        XCTAssertFalse(MediaGroup(items: [MediaItem(ref: ref("/a/1.png", origin: .written), isDeleted: true)]).showsInline,
                       "a deleted file is a row in the list")
    }
}
