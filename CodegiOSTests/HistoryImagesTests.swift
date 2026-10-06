import XCTest
@testable import Codeg

/// What a session shows must never shrink under the reader: the images a tool
/// returned (a Read of a PNG) render from the transcript and from the live
/// stream, a live turn rebuilt on reattach hides the persisted copy of the
/// running reply only where it holds all of it, and a frame the server had to
/// shrink is told apart from a whole one.
@MainActor
final class HistoryImagesTests: XCTestCase {

    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func blocks(_ json: String) throws -> [ContentBlock] {
        try CodegJSON.decoder.decode([ContentBlock].self, from: Data(json.utf8))
    }

    // MARK: Transcript

    func testAReadOfAPictureShowsThePictureAfterItsCard() throws {
        let decoded = try blocks("""
        [{"type": "tool_use", "tool_use_id": "toolu_read", "tool_name": "Read",
          "input_preview": "{\\"file_path\\":\\"/w/placement.png\\"}"},
         {"type": "tool_result", "tool_use_id": "toolu_read", "output_preview": "",
          "is_error": false, "images": [{"data": "\(Self.png)", "mime_type": "image/png"}]}]
        """)
        guard case .toolResult(_, _, _, let images) = decoded[1] else { return XCTFail("not a result") }
        XCTAssertEqual(images.count, 1)

        let turn = MessageTurn(id: "t1", role: .assistant, blocks: decoded, timestamp: Date())
        let parts = MessageRender.adaptTurn(turn)
        XCTAssertEqual(parts.count, 2)
        guard case .tool(let vm) = parts[0] else { return XCTFail("the card comes first") }
        XCTAssertEqual(vm.id, "toolu_read")
        guard case .image(let image, _) = parts[1] else { return XCTFail("then the picture") }
        XCTAssertEqual(image.data, Self.png)
    }

    func testOneMalformedImageDoesNotCostTheTranscript() throws {
        let decoded = try blocks("""
        [{"type": "tool_result", "tool_use_id": "t", "is_error": false,
          "images": [{"data": "QUJD"}, {"data": "\(Self.png)", "mime_type": "image/png"}, 7]}]
        """)
        guard case .toolResult(_, _, _, let images) = decoded[0] else { return XCTFail("not a result") }
        XCTAssertEqual(images.map(\.mimeType), ["image/png"])

        let none = try blocks(#"[{"type": "tool_result", "tool_use_id": "t", "images": null}]"#)
        guard case .toolResult(_, _, _, let empty) = none[0] else { return XCTFail("not a result") }
        XCTAssertTrue(empty.isEmpty)
    }

    func testAnImageCarriedByReferenceKeepsItsPath() throws {
        let decoded = try blocks("""
        [{"type": "image", "data": "\(Self.png)", "mime_type": "image/jpeg",
          "data_ref": "/api/live_image/0123456789abcdef0123456789abcdef01234567"}]
        """)
        guard case .image(let image) = decoded[0] else { return XCTFail("not an image") }
        XCTAssertEqual(image.dataRef, "/api/live_image/0123456789abcdef0123456789abcdef01234567")

        let source = ImageSource(baseURL: URL(string: "https://box.example/codeg")!, token: "t0k")
        let request = source.request(for: image.dataRef!)
        XCTAssertEqual(request?.url?.absoluteString,
                       "https://box.example/codeg/api/live_image/0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertNil(source.url(for: "/api/../etc/passwd"))
    }

    // MARK: Live stream

    func testAToolEventCarriesItsImages() throws {
        let json = """
        {"seq": 9, "connection_id": "c", "type": "tool_call_update", "tool_call_id": "toolu_read",
         "status": "completed", "images": [{"data": "\(Self.png)", "mime_type": "image/png"}]}
        """
        let event = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(json.utf8)).event
        guard case .toolCallUpdate(let id, _, _, _, _, _, _, _, let images) = event else {
            return XCTFail("not an update")
        }
        XCTAssertEqual(id, "toolu_read")
        XCTAssertEqual(images?.count, 1)

        let plain = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(
            #"{"seq": 10, "connection_id": "c", "type": "tool_call_update", "tool_call_id": "x"}"#.utf8)).event
        guard case .toolCallUpdate(_, _, _, _, _, _, _, _, let none) = plain else { return XCTFail("not an update") }
        XCTAssertNil(none, "no images means keep what was shown")
    }

    func testASnapshotCarriesItsToolImages() throws {
        let json = """
        {"type": "snapshot", "snapshot": {"connection_id": "c1", "status": "prompting",
          "active_tool_calls": [{"id": "toolu_read", "kind": "read", "label": "Read placement.png",
            "status": "completed", "images": [{"data": "\(Self.png)", "mime_type": "image/png"}]}]}}
        """
        let message = try CodegJSON.decoder.decode(WSServerMessage.self, from: Data(json.utf8))
        guard case .snapshot(let snap) = message else { return XCTFail("not a snapshot") }
        XCTAssertEqual(snap.activeToolCalls?.first?.images.count, 1)
    }

    func testTheLiveTurnShowsImagesAndKeepsThemThroughLaterUpdates() {
        let live = LiveTurn()
        let image = ImageData(data: Self.png, mimeType: "image/png", uri: nil)
        live.upsertToolCall(id: "toolu_read", title: "Read placement.png", kind: "read", status: "in_progress",
                            rawInput: nil, rawOutput: nil, content: nil)
        live.updateToolCall(id: "toolu_read", title: nil, status: "completed", rawInput: nil, rawOutput: "",
                            content: nil, append: false, images: [image])
        live.updateToolCall(id: "toolu_read", title: nil, status: "completed", rawInput: nil, rawOutput: nil,
                            content: nil, append: false)

        XCTAssertEqual(live.imageCount, 1)
        XCTAssertEqual(live.toolCallIDs, ["toolu_read"])
        let parts = MessageRender.adaptLive(live)
        XCTAssertTrue(parts.contains { if case .image = $0 { return true } else { return false } })

        // Promoted into the transcript, the image goes with it.
        guard case .toolResult(_, _, _, let images) = live.snapshotAsMessageTurn().blocks[1] else {
            return XCTFail("not a result")
        }
        XCTAssertEqual(images.count, 1)
    }

    // MARK: Reattach

    private func readTurn(_ toolID: String, id: String) -> MessageTurn {
        MessageTurn(id: id, role: .assistant, blocks: [
            .toolUse(id: toolID, name: "Read", inputPreview: nil, meta: nil),
            .toolResult(id: toolID, outputPreview: "", isError: false,
                        images: [ImageData(data: Self.png, mimeType: "image/png", uri: nil)]),
        ], timestamp: Date())
    }

    private func user(_ id: String) -> MessageTurn {
        MessageTurn(id: id, role: .user, blocks: [.text("draw it")], timestamp: Date())
    }

    private func shows(_ nodes: [TimelineNode], tool id: String) -> Bool {
        nodes.contains { $0.id == "tool-\(id)" }
    }

    func testTheRunningReplyIsHiddenOnlyWhileTheLiveTurnHoldsAllOfIt() {
        let turns = [user("u1"), readTurn("toolu_a", id: "a1")]
        let covered = TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: true,
            liveCoverage: .init(toolIDs: ["toolu_a"], imageCount: 1))
        XCTAssertFalse(shows(covered, tool: "toolu_a"), "the live turn shows it instead")

        let missingImage = TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: true,
            liveCoverage: .init(toolIDs: ["toolu_a"], imageCount: 0))
        XCTAssertTrue(shows(missingImage, tool: "toolu_a"), "a live copy without the picture must not hide it")

        let trimmed = TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: true,
            liveCoverage: .init(toolIDs: [], imageCount: 0))
        XCTAssertTrue(shows(trimmed, tool: "toolu_a"), "a trimmed snapshot must not hide the persisted call")
    }

    func testAPromptNotYetPersistedNeverHidesThePreviousReply() {
        // The new prompt is not in the transcript yet, so the last user turn is
        // the PREVIOUS one, and the turn after it is that reply — the drawings
        // the reader was looking at. The live turn holds only the new reply.
        let turns = [user("u1"), readTurn("toolu_previous", id: "a1")]
        let nodes = TranscriptTimeline.buildPersisted(
            turns: turns, pending: [], agent: .claudeCode, suppressInFlight: true,
            liveCoverage: .init(toolIDs: ["toolu_new"], imageCount: 0))
        XCTAssertTrue(shows(nodes, tool: "toolu_previous"))
        XCTAssertTrue(nodes.contains { if case .image = $0.content { return true } else { return false } })
    }

    // MARK: Socket

    func testTheEventSocketTellsTheServerItsFrameLimit() {
        let protocols = EventStream.protocols(token: "t")
        XCTAssertTrue(protocols.contains("codeg-client.ios"))
        XCTAssertTrue(protocols.contains("codeg-max-frame.\(64 * 1024 * 1024)"))
        XCTAssertEqual(protocols.first, "codeg-events")
    }

    func testAShrunkFrameIsFollowedByAFrameCut() {
        let shrunk = #"{"type": "event", "subscription_id": "s", "frame_cut": true,"#
            + #" "envelope": {"seq": 3, "connection_id": "c", "type": "thinking", "text": "x"}}"#
        let frames = EventStream.frames(from: Data(shrunk.utf8))
        XCTAssertEqual(frames.count, 2)
        guard case .event = frames[0], case .frameCut = frames[1] else { return XCTFail("event, then frameCut") }

        let whole = #"{"type": "event", "subscription_id": "s","#
            + #" "envelope": {"seq": 4, "connection_id": "c", "type": "thinking", "text": "y"}}"#
        XCTAssertEqual(EventStream.frames(from: Data(whole.utf8)).count, 1)
    }
}
