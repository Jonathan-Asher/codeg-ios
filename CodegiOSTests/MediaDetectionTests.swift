import XCTest
@testable import Codeg

/// Which files a session's messages and replies show: only those the agent
/// clearly made or pointed at (a Write target, a Markdown link, an absolute or
/// `~/` path, a "Saved to …" line a tool printed, an attachment), never a
/// name in a command's code. The fixtures are made up, after the shapes
/// real sessions have.
@MainActor
final class MediaDetectionTests: XCTestCase {
    private let context = MediaPathContext(folderPath: "/Users/j/proj", homePath: "/Users/j")

    private func turn(_ id: String, _ role: String, _ blocks: String) throws -> MessageTurn {
        let json = #"{"id": "\#(id)", "role": "\#(role)", "timestamp": "2026-10-18T10:00:00Z", "blocks": \#(blocks)}"#
        return try CodegJSON.decoder.decode(MessageTurn.self, from: Data(json.utf8))
    }

    /// A Bash tool call and its result, the input JSON-encoded as the server sends it.
    private func bash(_ id: String, _ command: String, output: String, isError: Bool = false) -> String {
        let input = String(data: try! JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8)!
        let encode = { (text: String) in String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast() }
        return """
        {"type": "tool_use", "tool_use_id": "\(id)", "tool_name": "Bash", "input_preview": \(encode(input))},
        {"type": "tool_result", "tool_use_id": "\(id)", "output_preview": \(encode(output)), "is_error": \(isError)}
        """
    }

    private func paths(_ refs: [MediaRef]) -> [String] { refs.map(\.path) }

    // MARK: - The reported session: files made outside the session's folder by scripts

    /// A reply that works in another folder (`cd ~/site/manual && …`) and
    /// whose commands are full of names that are code: an ffmpeg crop, a
    /// Python heredoc with f-strings and a dict of widths, a shell loop over
    /// `$f.png`, `pdfinfo Manual-$l.pdf`, a sed swap, and an `ls` of renders.
    private func scriptedReply() throws -> MessageTurn {
        let crop = """
        cd ~/site/manual && ffmpeg -y -loglevel error -i ~/shots/raw-listing.png -vf "crop=800:100:300:100" strip.png && python3 - <<'EOF'
        p = "/Users/j/site/manual/build.py"; s = open(p).read()
        WIDTH = {"composer.png": "60%", "strip.png": "100%"}
        for f in ["login-en", "login-he"]:
            Image.open(f"/Users/j/site/manual/{f}.png").save(f"/Users/j/site/manual/{f}-tight.png")
            print(f, "->", f"{f}-tight.png")
        EOF
        for l in EN HE; do echo "$l: $(pdfinfo Manual-$l.pdf | awk '/^Pages/{print $2}') pages"; done
        """
        let loop = #"cd ~/site/manual && for f in login-en login-he; do [ -f $f.png ] && sips -g pixelHeight $f.png; done; sed -i '' 's/"login-en.png"/"login-en-tight.png"/' build.py"#
        let render = "cd ~/site/manual && rm -rf ql && mkdir ql && qlmanage -t -s 1400 -o ql Manual-HE.pdf; ls ql/"
        return try turn("reply-script", "assistant", """
        [
          {"type": "text", "text": "I'll crop the listing and trim the sign-in shots."},
          \(bash("b1", crop, output: "800 100\nlogin-en -> login-en-tight.png\nEN: 3 pages\nHE: 3 pages"))
          ,\(bash("b2", loop, output: "login-en 1548\nlogin-he 1508"))
          ,\(bash("b3", render, output: "Manual-HE.pdf.png\nShell cwd was reset to /Users/j/proj"))
          ,{"type": "text", "text": "Done: the guides are `Manual-EN-v2.pdf` and `Manual-HE-v2.pdf`, and `strip.png` replaces the old shot."}
        ]
        """)
    }

    func testNamesInCommandsAndScriptsAreNotFiles() throws {
        XCTAssertEqual(MediaDetector.references(inTurn: try scriptedReply(), context: context), [],
                       "f-strings, $f.png, dict keys, sed, ls output and bare names show nothing")
    }

    func testEachFalsePositiveOnItsOwn() {
        // Every one of these used to become a card.
        let commands = [
            #"python3 -c 'for f in ["a"]: im.save(f"{f}-short.png")'"#,        // -short.png
            #"for f in a b; do convert $f.png out.png; done"#,                    // f.png, out.png
            #"pdfinfo Guide-Claude-$l.pdf"#,                                      // l.pdf
            #"python3 -c 'UNDER = {"chatgpt-composer.png": "62%"}'"#,             // a dict key
            #"sed -i '' 's/"signin-en.png"/"signin-en-short.png"/' build.py"#,   // a sed swap
            "ffmpeg -i ~/in/listing.png -vf crop=1:1:0:0 listing-crop.png",       // input and output of a command
            "cat > /tmp/render.py <<'EOF'\nimg.save('/tmp/out/hero.png')\nEOF",   // a heredoc
        ]
        for command in commands {
            let refs = MediaDetector.references(inToolCall: "Bash",
                                                input: String(data: try! JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8),
                                                output: "", isError: false, scope: "s", context: context)
            XCTAssertEqual(refs, [], command)
        }
        // A listing printed by `ls` or `find` names files; it doesn't say a command made them.
        XCTAssertEqual(MediaDetector.references(inToolCall: "Bash", input: #"{"command":"cd /tmp/shots && ls"}"#,
                                                output: "a.png\nb.png\nc.mp4", isError: false, scope: "s",
                                                context: context), [])
    }

    func testAPrintedSaveIsResolvedAgainstTheCommandsOwnFolder() throws {
        let reply = try turn("reply-build", "assistant", """
        [\(bash("b1", "cd ~/site/manual && python3 build.py && node render.mjs",
                output: "wrote /Users/j/site/manual/guide-en.html\nwrote Manual-EN.pdf\nwrote Manual-HE.pdf\n730385 Manual-EN.pdf"))]
        """)
        let refs = MediaDetector.references(inTurn: reply, context: context)
        XCTAssertEqual(paths(refs), ["/Users/j/site/manual/Manual-EN.pdf", "/Users/j/site/manual/Manual-HE.pdf"])
        XCTAssertEqual(refs.map(\.origin), [.printed, .printed])
    }

    func testARelativeSaveWithoutACertainFolderIsLeftOut() {
        let call = { (command: String, output: String) in
            MediaDetector.references(inToolCall: "Bash",
                                     input: String(data: try! JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8),
                                     output: output, isError: false, scope: "s", context: self.context)
        }
        // No `cd`: the shell may be anywhere the last command left it.
        XCTAssertEqual(call("python3 make.py", "Saved chart.png"), [])
        // Two `cd`s: which folder is ambiguous.
        XCTAssertEqual(call("cd /tmp/a && make && cd /tmp/b && ./shoot", "Saved shot.png"), [])
        // A templated folder is not a folder.
        XCTAssertEqual(call("cd $OUT && ./shoot", "Saved shot.png"), [])
        // But an absolute path in the same line needs no folder.
        XCTAssertEqual(paths(call("python3 make.py", "Saved chart to /tmp/charts/q3.png")), ["/tmp/charts/q3.png"])
        // And a single leading `cd` is a certain base.
        XCTAssertEqual(paths(call(#"cd "/tmp/my renders" && ./shoot"#, "Screenshot saved to: shot 1.png")), [])
        XCTAssertEqual(paths(call(#"cd "/tmp/my renders" && ./shoot"#, "Screenshot saved to: shot.png")),
                       ["/tmp/my renders/shot.png"])
        XCTAssertEqual(paths(call("cd ~/out; ffmpeg -i in.mov out.mp4", "Output #0, mp4, to 'clips/out.mp4':")),
                       ["/Users/j/out/clips/out.mp4"])
    }

    func testAFailureLineNamesNothing() {
        let refs = MediaDetector.references(inToolCall: "Bash", input: #"{"command":"cd /tmp/v && ./frames.sh"}"#,
                                            output: "Error opening output file frames/f01.png.\nFailed to write /tmp/v/x.png",
                                            isError: false, scope: "s", context: context)
        XCTAssertEqual(refs, [])
    }

    // MARK: - What still shows

    /// A reply that writes a video and a picture, links one, names one in
    /// full and has a tool save one.
    private func fixtureReply() throws -> MessageTurn {
        try turn("reply-1", "assistant", #"""
        [
          {"type": "text", "text": "Rendering the demo now."},
          {"type": "tool_use", "tool_use_id": "t1", "tool_name": "Write",
           "input_preview": "{\"file_path\":\"/Users/j/proj/art/logo.svg\",\"content\":\"<svg/>\"}"},
          {"type": "tool_result", "tool_use_id": "t1", "output_preview": "File created", "is_error": false},
          {"type": "tool_use", "tool_use_id": "t2", "tool_name": "mcp__browser__screenshot", "input_preview": "{\"name\":\"home\"}"},
          {"type": "tool_result", "tool_use_id": "t2", "output_preview": "Screenshot saved to /tmp/shots/home.png", "is_error": false},
          {"type": "tool_use", "tool_use_id": "t3", "tool_name": "Write",
           "input_preview": "{\"file_path\":\"/Users/j/proj/broken.png\"}"},
          {"type": "tool_result", "tool_use_id": "t3", "output_preview": "EACCES", "is_error": true},
          {"type": "text", "text": "Done. The video is [here](out/demo.mp4), the voice-over is `/Users/j/proj/out/voice over.m4a`, and the report is at ~/Desktop/report.pdf. Logs: https://ci.example.com/run/1/screenshot.png"}
        ]
        """#)
    }

    func testAReplyShowsWhatItClearlyMadeOrPointedAt() throws {
        let refs = MediaDetector.references(inTurn: try fixtureReply(), context: context)
        XCTAssertEqual(paths(refs), [
            "/Users/j/proj/art/logo.svg",
            "/tmp/shots/home.png",
            "/Users/j/proj/out/demo.mp4",
            "/Users/j/proj/out/voice over.m4a",
            "/Users/j/Desktop/report.pdf",
        ])
        XCTAssertEqual(refs.map(\.kind), [.image, .image, .video, .audio, .document])
        XCTAssertEqual(refs.map(\.origin), [.written, .printed, .link, .mention, .mention])
        XCTAssertTrue(refs[0].format.vector)
        XCTAssertEqual(Set(refs.map(\.scope)), ["reply-1"])
        // codeg web's split: the directory is the root, the name the path.
        XCTAssertEqual(refs[2].directory, "/Users/j/proj/out")
        XCTAssertEqual(refs[2].name, "demo.mp4")
    }

    func testTheReplyGetsAMediaNodeAboveItsFooter() throws {
        let question = try turn("q-1", "user", #"[{"type": "text", "text": "make the demo"}]"#)
        let nodes = TranscriptTimeline.buildPersisted(turns: [question, try fixtureReply()], pending: [],
                                                      agent: .claudeCode, suppressInFlight: false, media: context)
        guard let mediaIndex = nodes.firstIndex(where: { $0.id == "reply-1#media" }) else {
            return XCTFail("no media node")
        }
        XCTAssertEqual(nodes[mediaIndex + 1].id, "reply-1#footer")
        guard case .media(let group) = nodes[mediaIndex].content else { return XCTFail("not media") }
        XCTAssertEqual(group.items.count, 5)
        XCTAssertFalse(group.showsInline, "several files fold into one row")

        let without = TranscriptTimeline.buildPersisted(turns: [question, try fixtureReply()], pending: [],
                                                        agent: .claudeCode, suppressInFlight: false)
        XCTAssertFalse(without.contains { if case .media = $0.content { return true } else { return false } },
                       "no cards without the session's folder")
    }

    func testAnAttachmentShowsInsideTheUsersMessage() throws {
        // codeg writes a non-image attachment as `[name](uri)`; Claude Code's
        // transcript as `[@name](uri)`, the uri percent-encoded.
        let message = try turn("u-1", "user", #"""
        [{"type": "text", "text": "Trim this:"},
         {"type": "text", "text": "[@take (2).mov](file:///Users/j/Library/uploads/conv-1/take%20(2).mov)"},
         {"type": "text", "text": "[notes.txt](file:///Users/j/notes.txt)"}]
        """#)
        let nodes = TranscriptTimeline.buildPersisted(turns: [message], pending: [], agent: .claudeCode,
                                                      suppressInFlight: false, media: context)
        XCTAssertEqual(nodes.map(\.id), ["u-1"], "no separate node: the card is in the message")
        let group = try XCTUnwrap(nodes[0].attachedMedia)
        XCTAssertEqual(paths(group.refs), ["/Users/j/Library/uploads/conv-1/take (2).mov"])
        XCTAssertEqual(group.refs[0].origin, .link)
        XCTAssertTrue(group.showsInline)
        // The link itself leaves the message's text; other links stay.
        let paths = Set(group.refs.map(\.path))
        XCTAssertEqual(MediaAttachmentText.removingLinks(
            to: paths, from: "[@take (2).mov](file:///Users/j/Library/uploads/conv-1/take%20(2).mov)", context: context), "")
        XCTAssertEqual(MediaAttachmentText.removingLinks(
            to: paths, from: "[notes.txt](file:///Users/j/notes.txt)", context: context),
                       "[notes.txt](file:///Users/j/notes.txt)")
        XCTAssertEqual(MediaAttachmentText.removingLinks(
            to: paths, from: "<file> [take (2).mov](<file:///Users/j/Library/uploads/conv-1/take%20(2).mov>) What's in it?",
            context: context), "<file>  What's in it?")
    }

    // MARK: - Text

    func testLinksAndFullPathsResolve() {
        let refs = MediaDetector.references(inText: """
        See [the clip](out/clip%20one.mov), ![chart](./charts/b.png), <file:///tmp/a.wav>,
        /tmp/render/final.mp4:12, ~/Music/song.flac, `~/Movies/my take.mov` and file:///Users/j/proj/x%20y.mp3.
        """, scope: "s", context: context)
        XCTAssertEqual(paths(refs), [
            "/Users/j/proj/out/clip one.mov",
            "/Users/j/proj/charts/b.png",
            "/tmp/a.wav",
            "/Users/j/Movies/my take.mov",
            "/tmp/render/final.mp4",
            "/Users/j/Music/song.flac",
            "/Users/j/proj/x y.mp3",
        ])
    }

    func testBareAndRelativeNamesInProseAreLeftOut() {
        let refs = MediaDetector.references(inText: """
        I saved clip.mp4, out/demo.mov and `chart.png`; ../shared/loop.gif is older.
        The guides are `Manual-EN-v2.pdf` and `Manual-HE-v2.pdf`.
        """, scope: "s", context: context)
        XCTAssertEqual(refs, [])
    }

    func testTemplatesInProseAreNotFiles() {
        let refs = MediaDetector.references(inText: """
        Each shot goes to `~/out/${name}.png`, `/tmp/{a,b}.png`, /tmp/*.png or f"{f}-short.png";
        [x](/tmp/${n}.mp4)
        """, scope: "s", context: context)
        XCTAssertEqual(refs, [])
    }

    func testAMarkdownPictureOutsideTheFolderIsNotShownLikeOnTheWeb() {
        let refs = MediaDetector.references(inText: "![x](/etc/secret.png) but [y](/tmp/y.png)",
                                            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/tmp/y.png"])
    }

    func testWebLinksCodeFencesAndLookalikesAreNotFiles() {
        let refs = MediaDetector.references(inText: """
        https://example.com/pic.png and [site](https://example.com/v.mp4), codeg://session/12,
        /tmp/backup.png.bak, the .png format, v1.2, PNG.
        ```
        ffmpeg -i /tmp/in.mov /tmp/out.mp4
        ```
        """, scope: "s", context: context)
        XCTAssertEqual(refs, [])
    }

    func testAHebrewPrefixLetterBeforeAPath() {
        let refs = MediaDetector.references(inText: "שמרתי את הסרטון ב-/tmp/clip.mp4 ואת ההקלטה ב־~/rec.mp3.",
                                            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/tmp/clip.mp4", "/Users/j/rec.mp3"])
    }

    func testWithoutAHomeHomePathsAreDropped() {
        let bare = MediaPathContext(folderPath: nil, homePath: nil)
        let refs = MediaDetector.references(inText: "out/a.mp4 ~/b.mp4 /abs/c.mp4", scope: "s", context: bare)
        XCTAssertEqual(paths(refs), ["/abs/c.mp4"])
    }

    func testAtMostTwentyFourFilesUnderOneMessage() {
        let text = (1...30).map { "/tmp/shots/shot\($0).png" }.joined(separator: " ")
        XCTAssertEqual(MediaDetector.references(inText: text, scope: "s", context: context).count, 24)
    }

    // MARK: - Tools

    func testPatchesAndNestedInputsNameTheirFiles() {
        let patch = MediaDetector.references(inToolCall: "apply_patch",
            input: #"{"input":"*** Begin Patch\n*** Add File: art/x.svg\n+<svg/>\n*** Update File: src/a.ts\n*** End Patch"}"#,
            output: nil, isError: false, scope: "s", context: context)
        XCTAssertEqual(paths(patch), ["/Users/j/proj/art/x.svg"])

        let nested = MediaDetector.references(inToolCall: "mcp__acp__Write",
            input: #"{"arguments":{"path":"/Users/j/proj/docs/manual.pdf"}}"#, output: nil, isError: false,
            scope: "s", context: context)
        XCTAssertEqual(paths(nested), ["/Users/j/proj/docs/manual.pdf"])

        let templated = MediaDetector.references(inToolCall: "Write", input: #"{"file_path":"/tmp/${x}.png"}"#,
                                                 output: nil, isError: false, scope: "s", context: context)
        XCTAssertEqual(templated, [])
    }

    func testAReadOrASearchShowsNoCards() {
        XCTAssertEqual(MediaDetector.references(inToolCall: "Read", input: #"{"file_path":"/a/b.png"}"#,
                                                output: nil, isError: false, scope: "s", context: context), [])
        XCTAssertEqual(MediaDetector.references(inToolCall: "Glob", input: #"{"pattern":"**/*.png"}"#,
                                                output: "Saved /a/b.png", isError: false, scope: "s", context: context), [])
    }

    func testAnotherToolsSavedFileIsShown() {
        let refs = MediaDetector.references(inToolCall: "mcp__imagegen__generate", input: #"{"prompt":"a cat"}"#,
                                            output: "Saved image to /Users/j/proj/gen/cat.webp", isError: false,
                                            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/Users/j/proj/gen/cat.webp"])
        // Without a folder of its own, another tool's relative name is left out.
        XCTAssertEqual(MediaDetector.references(inToolCall: "mcp__imagegen__generate", input: nil,
                                                output: "Saved image to gen/cat.webp", isError: false,
                                                scope: "s", context: context), [])
    }

    func testTheCommandsFolder() {
        XCTAssertEqual(MediaDetector.commandBase("cd ~/a/b && make", context: context), "/Users/j/a/b")
        XCTAssertEqual(MediaDetector.commandBase("cd /tmp/x; ./run", context: context), "/tmp/x")
        XCTAssertEqual(MediaDetector.commandBase("cd '/tmp/a b' && ./run", context: context), "/tmp/a b")
        XCTAssertNil(MediaDetector.commandBase("cd sub && ./run", context: context), "relative to an unknown folder")
        XCTAssertNil(MediaDetector.commandBase("make && cd /tmp/x", context: context), "not at the start")
        XCTAssertNil(MediaDetector.commandBase("cd /tmp/x && (cd y && ./run)", context: context))
        XCTAssertNil(MediaDetector.commandBase("cd `mktemp -d` && ./run", context: context))
    }

    // MARK: - Paths and formats

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

    // MARK: - The attachment marker

    func testTheAttachmentMarkerMatchesCodegs() {
        XCTAssertEqual(MediaAttachmentText.fileURI(forPath: "/Users/j/up/my clip #1.mp4"),
                       "file:///Users/j/up/my%20clip%20%231.mp4")
        XCTAssertEqual(MediaAttachmentText.marker(name: "clip.mp4", path: "/u/clip.mp4"), "[clip.mp4](file:///u/clip.mp4)")
        // Parentheses: escaped in the label, the destination in angle brackets (`attachment_marker`).
        XCTAssertEqual(MediaAttachmentText.marker(name: "take (1).mov", path: "/u/take (1).mov"),
                       #"[take \(1\).mov](<file:///u/take%20(1).mov>)"#)
        // And the detector reads its own marker back.
        let refs = MediaDetector.references(
            inText: MediaAttachmentText.marker(name: "take [b] (1).mov", path: "/u/take [b] (1).mov"),
            scope: "s", context: context)
        XCTAssertEqual(paths(refs), ["/u/take [b] (1).mov"])
    }
}
