import XCTest
@testable import Codeg

/// "Edit Message", as codeg web takes it (`edit-message.ts`,
/// `computeUserEditTargets`, `handleEditUserMessage`): which messages can be
/// edited and when, the hint and labels for each outcome, the server check,
/// the `acp_fork` and `acp_prompt` bodies, the forked history taking the
/// place of the old one, the refusals in the web's words, a retry after the
/// history didn't load, and a first message opening a new conversation.
@MainActor
final class MessageEditTests: XCTestCase {
    private var server: MockCodegServer!

    override func setUp() async throws {
        server = MockCodegServer()
        ForkCapabilities.shared.reset()
    }

    override func tearDown() async throws {
        ForkCapabilities.shared.reset()
        server = nil
    }

    // MARK: - Fixtures

    private func turn(_ id: String, _ role: TurnRole, _ text: String = "text", fromServer: Bool = true,
                      blocks: [ContentBlock]? = nil) -> MessageTurn {
        MessageTurn(id: id, role: role, blocks: blocks ?? [.text(text)], timestamp: Date(),
                    serverMillis: fromServer ? 1_760_000_000_000 : nil)
    }

    /// prompt, reply in two turns, prompt, reply.
    private var transcript: [MessageTurn] {
        [turn("u0", .user, "first question"), turn("a1", .assistant), turn("a2", .assistant),
         turn("u3", .user, "second question"), turn("a4", .assistant)]
    }

    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func summaryJSON(external: String = "ext-7", agent: String = "claude_code") -> String {
        """
        {"id": 7, "folder_id": 1, "title": "Topic", "agent_type": "\(agent)", "status": "pending_review",
         "external_id": "\(external)", "message_count": 5, "created_at": "2026-10-14T08:00:00Z",
         "updated_at": "\(TranscriptTime.string(date: Date()))", "turn_state": null}
        """
    }

    private func turnJSON(_ id: String, _ role: String, _ text: String, image: Bool = false, ms: Int) -> String {
        let picture = image ? #", {"type": "image", "data": "\#(Self.pngBase64)", "mime_type": "image/png"}"# : ""
        return #"{"id": "\#(id)", "role": "\#(role)", "blocks": [{"type": "text", "text": "\#(text)"}\#(picture)], "timestamp": "\#(TranscriptTime.string(millis: Int64(1_760_000_000_000 + ms)))"}"#
    }

    /// The conversation before the edit, and the forked one after it (it ends
    /// at the reply before the edited message).
    private var originalTurns: [String] {
        [turnJSON("u0", "user", "first question", ms: 0), turnJSON("a1", "assistant", "first answer", ms: 1),
         turnJSON("a2", "assistant", "more of it", ms: 2), turnJSON("u3", "user", "second question", image: true, ms: 3),
         turnJSON("a4", "assistant", "second answer", ms: 4)]
    }

    private func detailJSON(external: String, turns: [String], agent: String = "claude_code") -> String {
        """
        {"summary": \(summaryJSON(external: external, agent: agent)), "turns": [\(turns.joined(separator: ", "))],
         "session_stats": null, "in_flight_user_turn_id": null}
        """
    }

    /// A server that edits: the probe says it knows the modes, `conn-1` is
    /// live and idle, and `acp_fork` moves the row to session `s2`, whose
    /// history ends at the first reply.
    private func serveEditableSession(agent: String = "claude_code", forkReply: MockCodegServer.Reply? = nil) {
        let forked = ForkFlag()
        let original = detailJSON(external: "ext-7", turns: originalTurns, agent: agent)
        let afterFork = detailJSON(external: "s2", turns: Array(originalTurns.prefix(3)), agent: agent)
        server.on("get_folder_conversation") { _ in .body(forked.isSet ? afterFork : original) }
        server.on("acp_find_connection_for_conversation") { _ in .body(#"{"connection_id": "conn-1", "event_seq": 0}"#) }
        server.on("acp_get_session_snapshot") { _ in
            .body(#"{"connection_id": "conn-1", "conversation_id": 7, "status": "connected", "event_seq": 3, "fork_supported": true}"#)
        }
        server.on("acp_fork") { call in
            if (call.body["connectionId"] as? String) == "" {
                // The capability check: a server with edit modes refuses the
                // unknown one while reading the body.
                return .status(422, "Failed to deserialize the JSON body into the target type: mode: unknown variant")
            }
            if let forkReply { return forkReply }
            forked.set()
            return .body(#"{"forkedSessionId": "s2", "originalSessionId": "ext-7", "siblingConversationId": 8}"#)
        }
    }

    private func loadedModel() async throws -> SessionDetailViewModel {
        let model = SessionDetailViewModel(client: server.client, conversationID: 7,
                                           makeEventStream: { _ in StreamFactory([]).make() }, transcriptCache: nil)
        model.loadIfNeeded()
        let loaded = await eventually { model.phase == .loaded && model.turns.count == 5 }
        XCTAssertTrue(loaded, "the session loaded")
        await ForkCapabilities.shared.probeEditModesIfNeeded(client: server.client)
        return model
    }

    // MARK: - Which messages

    func testTheEditTargetIsTheReplyBeforeTheMessage() {
        let turns = transcript
        XCTAssertEqual(MessageEditRules.target(for: "u3", in: turns, hasOlderTurns: false),
                       .fork(forkPointID: "a2", ready: true), "the reply's LAST turn, never the message itself")
        XCTAssertEqual(MessageEditRules.target(for: "u0", in: turns, hasOlderTurns: false), .first,
                       "the first message opens a new conversation")
        XCTAssertNil(MessageEditRules.target(for: "u0", in: turns, hasOlderTurns: true),
                     "the first held message while older turns are on the server: the reply before it isn't in hand")
        XCTAssertNil(MessageEditRules.target(for: "a2", in: turns, hasOlderTurns: false), "replies aren't edited")
        XCTAssertNil(MessageEditRules.target(for: "missing", in: turns, hasOlderTurns: false))
    }

    func testOnlyAMessageAfterAReplyCanBeEdited() {
        // Two messages in a row (the first got no answer): forking at the
        // reply further up would drop the first from the history.
        let unanswered = [turn("u0", .user), turn("a1", .assistant), turn("u2", .user), turn("u3", .user)]
        XCTAssertNil(MessageEditRules.target(for: "u3", in: unanswered, hasOlderTurns: false))
        XCTAssertNotNil(MessageEditRules.target(for: "u2", in: unanswered, hasOlderTurns: false))

        let afterNote = [turn("u0", .user), turn("a1", .assistant), turn("s2", .system, "Model changed"), turn("u3", .user)]
        XCTAssertNil(MessageEditRules.target(for: "u3", in: afterNote, hasOlderTurns: false), "after a system note")

        let compaction = turn("a2", .assistant, blocks: [
            .toolUse(id: "c1", name: "compact", inputPreview: nil, meta: AnyJSON.object(["contextCompaction": .bool(true)])),
            .toolResult(id: "c1", outputPreview: nil, isError: false),
        ])
        let afterCompaction = [turn("u0", .user), turn("a1", .assistant), turn("u1", .user), compaction,
                               turn("u3", .user)]
        XCTAssertNil(MessageEditRules.target(for: "u3", in: afterCompaction, hasOlderTurns: false),
                     "after a compaction divider")
        // A compaction inside a reply with words of its own is still a reply.
        let replyWithCompaction = [turn("u0", .user), turn("a1", .assistant), compaction, turn("u3", .user)]
        XCTAssertEqual(MessageEditRules.target(for: "u3", in: replyWithCompaction, hasOlderTurns: false),
                       .fork(forkPointID: "a2", ready: true))

        // Empty turns render nothing and are stepped over.
        let withEmpty = [turn("u0", .user), turn("a1", .assistant), turn("a2", .assistant, blocks: []), turn("u3", .user)]
        XCTAssertEqual(MessageEditRules.target(for: "u3", in: withEmpty, hasOlderTurns: false),
                       .fork(forkPointID: "a1", ready: true))

        let continued = [turn("u0", .user), turn("a1", .assistant), turn("u2", .user, ContinuePrompt.text)]
        XCTAssertNil(MessageEditRules.target(for: "u2", in: continued, hasOlderTurns: false),
                     "a Continue divider has no text worth editing")

        let phoneMade = [turn("u0", .user), turn("a1", .assistant), turn("u2", .user, fromServer: false)]
        XCTAssertNil(MessageEditRules.target(for: "u2", in: phoneMade, hasOlderTurns: false),
                     "a message still on its way isn't edited")
    }

    func testWhyAnEditCantRunNow() {
        let fork = MessageEditTarget.fork(forkPointID: "a2", ready: true)
        XCTAssertNil(MessageEditRules.block(fork, turnRunning: false, awaitingPersist: false, queued: false, saving: false))
        XCTAssertEqual(MessageEditRules.block(fork, turnRunning: true, awaitingPersist: false, queued: true, saving: false),
                       .busy, "a running turn comes first")
        XCTAssertEqual(MessageEditRules.block(fork, turnRunning: false, awaitingPersist: true, queued: false, saving: false),
                       .busy, "a message just sent that isn't a turn yet")
        XCTAssertEqual(MessageEditRules.block(fork, turnRunning: false, awaitingPersist: false, queued: false, saving: true),
                       .busy, "another edit being saved")
        XCTAssertEqual(MessageEditRules.block(fork, turnRunning: false, awaitingPersist: false, queued: true, saving: false),
                       .queued)
        XCTAssertEqual(MessageEditRules.block(.fork(forkPointID: "a2", ready: false), turnRunning: false,
                                              awaitingPersist: false, queued: false, saving: false), .notReady)

        XCTAssertEqual(MessageEditBlock.busy.reason, "Can’t edit while a turn is running")
        XCTAssertEqual(MessageEditBlock.queued.reason, "Can’t edit while messages are waiting in the queue")
        XCTAssertEqual(MessageEditBlock.notReady.reason, "Can’t edit this message just yet — try again in a moment")
    }

    func testEachOutcomeSaysWhatSavingDoes() {
        let fork = MessageEditTarget.fork(forkPointID: "a2", ready: true)
        XCTAssertEqual(MessageEditKind(target: fork, keepOriginal: false), .inPlace)
        XCTAssertEqual(MessageEditKind(target: fork, keepOriginal: true), .newBranch)
        XCTAssertEqual(MessageEditKind(target: .first, keepOriginal: true), .newConversation)
        XCTAssertEqual(MessageEditKind.inPlace.hint,
                       "Saving continues this conversation from here with the edited message, in place of the original. File changes are not undone.")
        XCTAssertEqual(MessageEditKind.newBranch.hint,
                       "Saving starts a new branch from here. The original conversation stays in the sidebar, and file changes are not undone.")
        XCTAssertEqual(MessageEditKind.newConversation.hint,
                       "This is the first message, so saving starts a new conversation with it. This one stays as it is, and file changes are not undone.")
        XCTAssertEqual(MessageEditKind.inPlace.savingLabel, "Continuing from here…")
        XCTAssertEqual(MessageEditKind.newBranch.savingLabel, "Starting a new branch…")
        XCTAssertEqual(MessageEditKind.newConversation.savingLabel, "Opening a new conversation…")
        XCTAssertEqual(MessageEditRules.forkMode(keepOriginal: false), .editInPlace)
        XCTAssertEqual(MessageEditRules.forkMode(keepOriginal: true), .edit)
        XCTAssertTrue(MessageEditRules.supports(.claudeCode))
        XCTAssertTrue(MessageEditRules.supports(.codex))
        XCTAssertTrue(MessageEditRules.supports(.unknown("deepseek")))
        XCTAssertFalse(MessageEditRules.supports(.pi), "Pi forks at the tail when it misses")
        XCTAssertFalse(MessageEditRules.supports(.gemini))
    }

    func testTheEditStartsFromTheTextAndKeepsThePictures() {
        let picture = ImageData(data: Self.pngBase64, mimeType: "image/png", uri: nil)
        let byReference = ImageData(data: Self.pngBase64, mimeType: "image/png", uri: nil, dataRef: "/api/live_image/k")
        let message = turn("u3", .user, blocks: [.text("  שלום, מה שלומך?\n"), .image(picture), .text("second line"), .image(byReference)])
        XCTAssertEqual(MessageEditRules.editableText(message), "שלום, מה שלומך?\n\nsecond line")
        XCTAssertEqual(MessageEditRules.images(message), [picture])
    }

    func testAReplyWithNoServerNameIsFoundInAFreshRead() {
        let fresh = [turn("u0", .user, "first question"), turn("srv-1", .assistant), turn("srv-2", .assistant),
                     turn("u3", .user, "second   question"), turn("srv-4", .assistant)]
        XCTAssertEqual(MessageEditRules.resolveForkPoint(in: fresh, userOrdinal: 1, messageText: "second question"),
                       "srv-2", "matched by place among the user turns and by text, spaces aside")
        XCTAssertNil(MessageEditRules.resolveForkPoint(in: fresh, userOrdinal: 1, messageText: "something else"),
                     "the text has to match: nothing forks somewhere else")
        XCTAssertNil(MessageEditRules.resolveForkPoint(in: fresh, userOrdinal: 0, messageText: "first question"),
                     "the first message has no reply before it")
        XCTAssertNil(MessageEditRules.resolveForkPoint(in: fresh, userOrdinal: 5, messageText: "x"))
    }

    // MARK: - The wire

    func testTheForkBodyCarriesTheEditMode() throws {
        func encoded(_ mode: ForkMode?) throws -> [String: Any] {
            let data = try CodegJSON.encoder.encode(AcpForkBody(connectionId: "conn-1", conversationId: 7, folderId: 1,
                                                                forkFromTurnId: "a2", mode: mode))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try encoded(.editInPlace)["mode"] as? String, "edit_in_place")
        XCTAssertEqual(try encoded(.edit)["mode"] as? String, "edit")
        XCTAssertNil(try encoded(nil)["mode"], "Fork from here sends no mode, as before")
        XCTAssertEqual(try encoded(.edit)["forkFromTurnId"] as? String, "a2")
    }

    func testTheServerCheckForEditing() async throws {
        server.on("acp_fork") { _ in .status(422, "Failed to deserialize the JSON body into the target type: mode: unknown variant") }
        let editing = try await server.client.forkEditModesSupported()
        XCTAssertTrue(editing, "a server that knows the modes refuses an unknown one")
        let probe = try XCTUnwrap(server.calls("acp_fork").first)
        XCTAssertEqual(probe.body["connectionId"] as? String, "", "a connection that can't exist: nothing is forked")

        let older = MockCodegServer()
        older.on("acp_fork") { _ in .status(500, #"{"code": "task_execution_failed", "message": "connection not found: "}"#) }
        let olderEditing = try await older.client.forkEditModesSupported()
        XCTAssertFalse(olderEditing, "an older server ignores the mode")

        let none = MockCodegServer()
        none.on("acp_fork") { _ in .status(501, #"{"code": "not_implemented", "message": "API endpoint is not available in web mode"}"#) }
        let noneEditing = try await none.client.forkEditModesSupported()
        XCTAssertFalse(noneEditing, "a server without forking")

        let offline = MockCodegServer()
        offline.on("acp_fork") { _ in .fail(.notConnectedToInternet) }
        let unknown = await ForkCapabilities.shared.probeEditModesIfNeeded(client: offline.client)
        XCTAssertNil(unknown, "a network failure isn't taken for an older server")
    }

    // MARK: - Saving

    func testEditingInPlaceForksAtTheReplyAndSendsTheEditedMessage() async throws {
        serveEditableSession()
        let model = try await loadedModel()
        XCTAssertEqual(model.editAvailability(turnID: "u3"), .available(.fork(forkPointID: "a2", ready: true)))
        XCTAssertEqual(model.editAvailability(turnID: "u0"), .available(.first))
        XCTAssertEqual(model.editAvailability(turnID: "a4"), .hidden)
        let draft = try XCTUnwrap(model.editDraft(turnID: "u3"))
        XCTAssertEqual(draft.text, "second question")
        XCTAssertEqual(draft.images.count, 1)

        let outcome = try await model.saveEdit(turnID: "u3", text: "second question, rephrased", keepOriginal: false)
        XCTAssertEqual(outcome, .sent)

        let fork = try XCTUnwrap(server.calls("acp_fork").last)
        XCTAssertEqual(fork.body["connectionId"] as? String, "conn-1")
        XCTAssertEqual(fork.body["conversationId"] as? Int, 7)
        XCTAssertEqual(fork.body["folderId"] as? Int, 1)
        XCTAssertEqual(fork.body["forkFromTurnId"] as? String, "a2", "the reply right before the message")
        XCTAssertEqual(fork.body["mode"] as? String, "edit_in_place")

        // The forked history took the old one's place, and the edited
        // message went out on it, with the message's picture.
        XCTAssertEqual(model.turns.map(\.id), ["u0", "a1", "a2"])
        XCTAssertEqual(model.summary?.externalId, "s2")
        XCTAssertEqual(model.pendingUserTurns.count, 1)
        let sent = await eventually { !self.server.calls("acp_prompt").isEmpty }
        XCTAssertTrue(sent, "the edited message was sent")
        let prompt = try XCTUnwrap(server.calls("acp_prompt").last)
        let blocks = try XCTUnwrap(prompt.body["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        XCTAssertEqual(blocks.first?["text"] as? String, "second question, rephrased")
        XCTAssertEqual(blocks.dropFirst().first?["type"] as? String, "image")
        XCTAssertEqual(blocks.dropFirst().first?["data"] as? String, Self.pngBase64)
        XCTAssertEqual(prompt.body["connectionId"] as? String, "conn-1", "on the connection the fork moved")
        XCTAssertEqual(prompt.body["conversationId"] as? Int, 7, "the same conversation, continued in place")
        model.teardown()
    }

    func testKeepingTheOriginalForksAsANewBranch() async throws {
        serveEditableSession()
        let model = try await loadedModel()
        _ = try await model.saveEdit(turnID: "u3", text: "again", keepOriginal: true)
        XCTAssertEqual(server.calls("acp_fork").last?.body["mode"] as? String, "edit")
        model.teardown()
    }

    func testEditingIsHiddenOnAnOlderServerAndForAnAgentThatCantForkExactly() async throws {
        serveEditableSession()
        server.on("acp_fork") { _ in .status(500, #"{"code": "task_execution_failed", "message": "connection not found: "}"#) }
        let model = try await loadedModel()
        XCTAssertEqual(ForkCapabilities.shared.editModes(for: server.client), false)
        XCTAssertFalse(model.canEditMessages)
        XCTAssertEqual(model.editAvailability(turnID: "u3"), .hidden, "an older server: no Edit at all")
        model.teardown()

        ForkCapabilities.shared.reset()
        server = MockCodegServer()
        serveEditableSession(agent: "pi")
        let pi = try await loadedModel()
        XCTAssertEqual(pi.editAvailability(turnID: "u3"), .hidden)
        pi.teardown()
    }

    func testARunningTurnGreysTheEditOut() async throws {
        serveEditableSession()
        let model = try await loadedModel()
        // A message of the user's own on its way: a turn runs.
        model.draft = "one more thing"
        model.sendFromComposer()
        XCTAssertEqual(model.editAvailability(turnID: "u3"),
                       .blocked(.fork(forkPointID: "a2", ready: true), .busy))
        XCTAssertEqual(model.editAvailability(turnID: "u3").reason, "Can’t edit while a turn is running")
        do {
            _ = try await model.saveEdit(turnID: "u3", text: "edited", keepOriginal: false)
            XCTFail("an edit under a running turn must not run")
        } catch {
            XCTAssertEqual(error as? MessageEditError, .busy)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Can’t edit the message while a turn is running")
        }
        XCTAssertTrue(server.calls("acp_fork").filter { ($0.body["connectionId"] as? String) == "conn-1" }.isEmpty)
        model.teardown()
    }

    func testRefusalsReadAsOnTheWeb() async throws {
        serveEditableSession(forkReply: .status(409, #"{"code": "turn_in_progress", "message": "a turn is in progress"}"#))
        let model = try await loadedModel()
        do {
            _ = try await model.saveEdit(turnID: "u3", text: "edited", keepOriginal: false)
            XCTFail("a turn started under the edit")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Can’t edit the message while a turn is running")
        }
        XCTAssertEqual(model.turns.count, 5, "nothing changed")
        XCTAssertTrue(model.pendingUserTurns.isEmpty)
        model.teardown()

        server = MockCodegServer()
        serveEditableSession(forkReply: .status(400, #"{"code": "invalid_input", "message": "the agent cannot fork at the reply before this message"}"#))
        let strict = try await loadedModel()
        do {
            _ = try await strict.saveEdit(turnID: "u3", text: "edited", keepOriginal: false)
            XCTFail("the agent couldn't name the reply")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "Couldn’t edit the message: the agent cannot fork at the reply before this message")
        }
        strict.teardown()
    }

    func testAHistoryThatDidntLoadIsTriedAgainWithoutForkingTwice() async throws {
        serveEditableSession()
        let model = try await loadedModel()
        // The fork goes through, but the row keeps reading as the original.
        let original = detailJSON(external: "ext-7", turns: originalTurns)
        server.on("get_folder_conversation") { _ in .body(original) }
        do {
            _ = try await model.saveEdit(turnID: "u3", text: "edited", keepOriginal: false)
            XCTFail("the forked history never loaded")
        } catch {
            XCTAssertEqual(error as? MessageEditError, .historyFailed(keptOriginal: false))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "The conversation was rewound to this point, but its history didn’t load, so the edited message wasn’t sent. Try Save & send again.")
        }
        XCTAssertTrue(server.calls("acp_prompt").isEmpty, "nothing was sent")

        // Save again once it loads: the same fork, then the message.
        let afterFork = detailJSON(external: "s2", turns: Array(originalTurns.prefix(3)))
        server.on("get_folder_conversation") { _ in .body(afterFork) }
        let forks = server.calls("acp_fork").filter { ($0.body["connectionId"] as? String) == "conn-1" }.count
        let outcome = try await model.saveEdit(turnID: "u3", text: "edited", keepOriginal: false)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(server.calls("acp_fork").filter { ($0.body["connectionId"] as? String) == "conn-1" }.count, forks,
                       "the fork was not taken twice")
        model.teardown()
    }

    func testEditingTheFirstMessageOpensANewConversationThatSendsIt() async throws {
        serveEditableSession()
        let model = try await loadedModel()
        let outcome = try await model.saveEdit(turnID: "u0", text: "a better first question", keepOriginal: false)
        guard case .newConversation(let request) = outcome else { return XCTFail("expected a new conversation") }
        XCTAssertEqual(request.preselectedFolderID, 1)
        XCTAssertEqual(request.agent, .claudeCode)
        XCTAssertEqual(request.initialPrompt?.text, "a better first question")
        XCTAssertTrue(server.calls("acp_fork").filter { ($0.body["connectionId"] as? String) == "conn-1" }.isEmpty,
                      "this conversation stays as it is")
        model.teardown()

        // The new conversation sends it as soon as it is set up.
        server.on("list_open_folder_details") { _ in
            .body(#"[{"id": 1, "name": "proj", "path": "/tmp/proj", "last_opened_at": "2026-10-14T08:00:00Z", "sort_order": 0, "color": "blue"}]"#)
        }
        server.on("list_all_folder_details") { _ in
            .body(#"[{"id": 1, "name": "proj", "path": "/tmp/proj", "last_opened_at": "2026-10-14T08:00:00Z", "sort_order": 0, "color": "blue"}]"#)
        }
        server.on("create_conversation") { _ in .body("12") }
        server.on("acp_find_connection_for_conversation") { _ in .body("null") }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        let fresh = SessionDetailViewModel(client: server.client, newSession: request, transcriptCache: nil)
        fresh.loadIfNeeded()
        let sent = await eventually { !self.server.calls("create_conversation").isEmpty }
        XCTAssertTrue(sent, "the new conversation was created with the edited message")
        XCTAssertEqual(fresh.pendingUserTurns.first.map(MessageEditRules.editableText), "a better first question")
        fresh.teardown()
    }
}

/// Whether the mock server has forked yet (its routes run off the main actor).
private final class ForkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
