import XCTest
@testable import Codeg

/// Which files a session's messages and replies show as media cards: links
/// and paths in the text, files the tools wrote, what a command made, and an
/// attachment in the user's message, resolved the way codeg web opens them.
@MainActor
final class MediaDetectionTests: XCTestCase {
    private let context = MediaPathContext(folderPath: "/Users/j/proj", homePath: "/Users/j")

    private func turn(_ id: String, _ role: String, _ blocks: String) throws -> MessageTurn {
        let json = #"{"id": "\#(id)", "role": "\#(role)", "timestamp": "2026-10-18T10:00:00Z", "blocks": \#(blocks)}"#
        return try CodegJSON.decoder.decode(MessageTurn.self, from: Data(json.utf8))
    }

    private func paths(_ refs: [MediaRef]) -> [String] { refs.map(\.path) }

    // MARK: A reply as the server sends it

    /// A Claude Code reply that renders a video with ffmpeg, writes an SVG,
    /// lists a folder of pictures, and links what it made.
    private func fixtureReply() throws -> MessageTurn {
        try turn("reply-1", "assistant", #"""
        [
          {"type": "text", "text": "Rendering the demo now."},
          {"type": "tool_use", "tool_use_id": "t1", "tool_name": "Bash",
           "input_preview": "{\"command\":\"ffmpeg -y -i assets/raw.mov -vf scale=720:-2 out/demo.mp4\",\"description\":\"Render\"}"},
          {"type": "tool_result", "tool_use_id": "t1", "output_preview": "frame=  240 fps=120", "is_error": false},
          {"type": "tool_use", "tool_use_id": "t2", "tool_name": "Write",
           "input_preview": "{\"file_path\":\"/Users/j/proj/art/logo.svg\",\"content\":\"<svg/>\"}"},
          {"type": "tool_result", "tool_use_id": "t2", "output_preview": "File created", "is_error": false},
          {"type": "tool_use", "tool_use_id": "t3", "tool_name": "Bash",
           "input_preview": "{\"command\":\"ls shots\"}"},
          {"type": "tool_result", "tool_use_id": "t3",
           "output_preview": "a.png\nb.png\nc.png\nd.png\ne.png\nf.png\ng.png", "is_error": false},
          {"type": "tool_use", "tool_use_id": "t4", "tool_name": "Write",
           "input_preview": "{\"file_path\":\"/Users/j/proj/broken.png\"}"},
          {"type": "tool_result", "tool_use_id": "t4", "output_preview": "EACCES", "is_error": true},
          {"type": "text", "text": "Done. The video is [here](out/demo.mp4), the voice-over is `out/voice over.m4a`, and the report is at ~/Desktop/report.pdf. Logs: https://ci.example.com/run/1/screenshot.png"}
        ]
        """#)
    }

    func testAReplyShowsWhatItMadeOnceEachAndNotWhatItListed() throws {
        let refs = MediaDetector.references(inTurn: try fixtureReply(), context: context)
        XCTAssertEqual(paths(refs), [
            "/Users/j/proj/assets/raw.mov",
            "/Users/j/proj/out/demo.mp4",
            "/Users/j/proj/art/logo.svg",
            "/Users/j/proj/out/voice over.m4a",
            "/Users/j/Desktop/report.pdf",
        ])
        XCTAssertEqual(refs.map(\.kind), [.video, .video, .image, .audio, .document])
        XCTAssertEqual(refs[1].origin, .command, "the first mention wins")
        XCTAssertEqual(refs[2].origin, .written)
        XCTAssertTrue(refs[2].format.vector)
        XCTAssertEqual(Set(refs.map(\.scope)), ["reply-1"])
        // codeg web's split: the directory is the root, the name the path.
        XCTAssertEqual(refs[1].directory, "/Users/j/proj/out")
        XCTAssertEqual(refs[1].name, "demo.mp4")
    }

    func testTheReplyGetsACardsNodeAboveItsFooter() throws {
        let question = try turn("q-1", "user", #"[{"type": "text", "text": "make the demo"}]"#)
        let nodes = TranscriptTimeline.buildPersisted(turns: [question, try fixtureReply()], pending: [],
                                                      agent: .claudeCode, suppressInFlight: false, media: context)
        guard let mediaIndex = nodes.firstIndex(where: { $0.id == "reply-1#media" }) else {
            return XCTFail("no media node")
        }
        XCTAssertEqual(nodes[mediaIndex + 1].id, "reply-1#footer")
        guard case .media(let refs) = nodes[mediaIndex].content else { return XCTFail("not media") }
        XCTAssertEqual(refs.count, 5)

        let without = TranscriptTimeline.buildPersisted(turns: [question, try fixtureReply()], pending: [],
                                                        agent: .claudeCode, suppressInFlight: false)
        XCTAssertFalse(without.contains { if case .media = $0.content { return true } else { return false } },
                       "no cards without the session's folder")
    }

    func testAnAttachmentInTheUsersMessageGetsCards() throws {
        // codeg turns a non-image attachment into `[name](uri)`.
        let message = try turn("u-1", "user", #"""
        [{"type": "text", "text": "Trim this: [take2.mov](file:///Users/j/Movies/take2.mov) and [notes.txt](file:///Users/j/notes.txt)"}]
        """#)
        let nodes = TranscriptTimeline.buildPersisted(turns: [message], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false, media: context)
        XCTAssertEqual(nodes.map(\.id), ["u-1", "u-1#media"])
        guard case .media(let refs) = nodes[1].content else { return XCTFail("not media") }
        XCTAssertEqual(paths(refs), ["/Users/j/Movies/take2.mov"])
        XCTAssertEqual(refs[0].origin, .link)
    }

    // MARK: Text

    func testLinksAndPathsResolveAgainstTheFolderAndHome() {
        let refs = MediaDetector.references(inText: """
        See [the clip](out/clip%20one.mov), ![chart](./charts/b.png), <file:///tmp/a.wav>,
        /tmp/render/final.mp4:12, ~/Music/song.flac, ../shared/loop.gif and file:///Users/j/proj/x%20y.mp3.
        """, scope: "s", context: context)
        XCTAssertEqual(paths(refs), [
            "/Users/j/proj/out/clip one.mov",
            "/Users/j/proj/charts/b.png",
            "/tmp/a.wav",
            "/tmp/render/final.mp4",
            "/Users/j/Music/song.flac",
            "/Users/j/shared/loop.gif",
            "/Users/j/proj/x y.mp3",
        ])
    }

    func testAMarkdownPictureOutsideTheFolderIsNotShownLikeOnTheWeb() {
        let refs = MediaDetector.references(inText: "![x](/etc/secret.png) but [y](/tmp/y.png)",
                                            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/tmp/y.png"])
    }

    func testWebLinksCodeFencesAndLookalikesAreNotFiles() {
        let refs = MediaDetector.references(inText: """
        https://example.com/pic.png and [site](https://example.com/v.mp4), codeg://session/12,
        backup.png.bak, the .png format, v1.2, PNG.
        ```
        ffmpeg -i in.mov out.mp4
        ```
        """, scope: "s", context: context)
        XCTAssertEqual(refs, [])
    }

    func testHebrewPrefixLettersAreNotPartOfTheName() {
        let refs = MediaDetector.references(inText: "שמרתי את clip.mp4 ו-recording.mp3 בתיקייה.",
                                            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/Users/j/proj/clip.mp4", "/Users/j/proj/recording.mp3"])
    }

    func testWithoutAFolderOrHomeRelativePathsAreDropped() {
        let bare = MediaPathContext(folderPath: nil, homePath: nil)
        let refs = MediaDetector.references(inText: "out/a.mp4 ~/b.mp4 /abs/c.mp4", scope: "s", context: bare)
        XCTAssertEqual(paths(refs), ["/abs/c.mp4"])
    }

    func testAtMostTwelveFilesUnderOneMessage() {
        let text = (1...20).map { "shot\($0).png" }.joined(separator: " ")
        XCTAssertEqual(MediaDetector.references(inText: text, scope: "s", context: context).count, 12)
    }

    // MARK: Tools

    func testPatchesAndNestedInputsNameTheirFiles() {
        let patch = MediaDetector.references(inToolCall: "apply_patch",
            input: #"{"input":"*** Begin Patch\n*** Add File: art/x.svg\n+<svg/>\n*** Update File: src/a.ts\n*** End Patch"}"#,
            output: nil, isError: false, scope: "s", context: context)
        XCTAssertEqual(paths(patch), ["/Users/j/proj/art/x.svg"])

        let nested = MediaDetector.references(inToolCall: "mcp__acp__Write",
            input: #"{"arguments":{"path":"docs/manual.pdf"}}"#, output: nil, isError: false,
            scope: "s", context: context)
        XCTAssertEqual(paths(nested), ["/Users/j/proj/docs/manual.pdf"])
    }

    func testAReadOrASearchShowsNoCards() {
        XCTAssertEqual(MediaDetector.references(inToolCall: "Read", input: #"{"file_path":"/a/b.png"}"#,
                                                output: nil, isError: false, scope: "s", context: context), [])
        XCTAssertEqual(MediaDetector.references(inToolCall: "Glob", input: #"{"pattern":"**/*.png"}"#,
                                                output: "/a/b.png", isError: false, scope: "s", context: context), [])
    }

    func testAnotherToolsSavedFileIsShown() {
        let refs = MediaDetector.references(inToolCall: "mcp__imagegen__generate", input: #"{"prompt":"a cat"}"#,
                                            output: "Saved image to /Users/j/proj/gen/cat.webp", isError: false,
                                            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/Users/j/proj/gen/cat.webp"])
    }

    // MARK: Paths and formats

    func testPathRules() {
        XCTAssertEqual(MediaPaths.resolve("a/./b/../c.mp4", in: context), "/Users/j/proj/a/c.mp4")
        XCTAssertNil(MediaPaths.resolve("../../../../x.mp4", in: context), "above /")
        XCTAssertNil(MediaPaths.resolve("file://otherhost/share/x.mp4", in: context))
        XCTAssertEqual(MediaPaths.resolve("file://localhost/tmp/x.mp4", in: context), "/tmp/x.mp4")
        XCTAssertNil(MediaPaths.resolve("C:\\clips\\x.mp4", in: context))
        XCTAssertNil(MediaPaths.resolve("mailto:a@b.c", in: context))
        XCTAssertEqual(MediaPaths.resolve("out/x.mp4#t=10", in: context, decode: true), "/Users/j/proj/out/x.mp4")
        XCTAssertTrue(MediaPaths.isInside("/Users/j/proj/a.png", folder: "/Users/j/proj/"))
        XCTAssertFalse(MediaPaths.isInside("/Users/j/project2/a.png", folder: "/Users/j/proj"))
    }

    func testFormats() {
        XCTAssertEqual(MediaFormats.format(forPath: "a.MOV")?.kind, .video)
        XCTAssertEqual(MediaFormats.format(forPath: "a.webm")?.native, false)
        XCTAssertEqual(MediaFormats.format(forPath: "a.avi")?.unsupported, true)
        XCTAssertEqual(MediaFormats.format(forPath: "a.m4a")?.kind, .audio)
        XCTAssertEqual(MediaFormats.format(forPath: "a.ogg")?.native, false)
        XCTAssertEqual(MediaFormats.format(forPath: "a.heic")?.kind, .image)
        XCTAssertEqual(MediaFormats.format(forPath: "a.pdf")?.kind, .document)
        XCTAssertNil(MediaFormats.format(forPath: "a.swift"))
        XCTAssertNil(MediaFormats.format(forPath: "Makefile"))
    }

    func testLinksTappedInAMessageOpenMediaOnly() {
        XCTAssertEqual(MediaLinks.ref(for: URL(string: "out/clip%20one.mp4")!, context: context)?.path,
                       "/Users/j/proj/out/clip one.mp4")
        XCTAssertEqual(MediaLinks.ref(for: URL(string: "file:///tmp/a.png")!, context: context)?.kind, .image)
        XCTAssertNil(MediaLinks.ref(for: URL(string: "https://example.com/a.mp4")!, context: context))
        XCTAssertNil(MediaLinks.ref(for: URL(string: "src/main.swift")!, context: context))
    }
}
