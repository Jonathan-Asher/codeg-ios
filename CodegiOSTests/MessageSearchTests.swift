import SwiftUI
import XCTest
@testable import Codeg

/// Searching sessions by their messages: reading `message_search`'s hits and
/// their `[[mark]]` excerpts, grouping them by session, the short-query rule,
/// a server without message search, and a hit opening its session at its
/// message (the route, the session store, the model fetching older turns,
/// and the row the transcript opens at).
@MainActor
final class MessageSearchTests: XCTestCase {
    private var suites: [String] = []
    private var models: [SessionDetailViewModel] = []
    /// The transcripts the mock servers answer from (their routes hold them
    /// unowned).
    private var transcripts: [WindowedTranscriptServer] = []

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        transcripts = []
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "message-search-\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func hit(_ conversation: Int, turn: Int, rank: Double = -1, role: MessageSearchRole = .assistant,
                     snippet: String = "the [[mark]]voice[[/mark]] fix", title: String? = "Voice") -> MessageSearchHit {
        MessageSearchHit(conversationId: conversation, folderId: 1, agentType: .claudeCode, title: title,
                         turnIdx: turn, role: role, snippet: snippet, rank: rank)
    }

    // MARK: - Reading hits

    func testHitsDecodeFromTheServersSnakeCase() throws {
        let json = """
        [{"conversation_id": 12, "folder_id": 3, "agent_type": "claude_code", "title": "Voice typing",
          "turn_idx": 41, "role": "assistant", "snippet": "…the [[mark]]voice[[/mark]] path", "rank": -4.25},
         {"conversation_id": 9, "folder_id": 4, "agent_type": "a_newer_agent", "title": null,
          "turn_idx": 0, "role": "user", "snippet": "תקן את [[mark]]הקול[[/mark]]", "rank": 0}]
        """
        let hits = try CodegJSON.decoder.decode([MessageSearchHit].self, from: Data(json.utf8))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].conversationId, 12)
        XCTAssertEqual(hits[0].folderId, 3)
        XCTAssertEqual(hits[0].agentType, .claudeCode)
        XCTAssertEqual(hits[0].trimmedTitle, "Voice typing")
        XCTAssertEqual(hits[0].turnIdx, 41)
        XCTAssertEqual(hits[0].role, .assistant)
        XCTAssertEqual(hits[0].rank, -4.25)
        XCTAssertEqual(hits[1].agentType, .unknown("a_newer_agent"))
        XCTAssertNil(hits[1].trimmedTitle)
        XCTAssertEqual(hits[1].role, .user)
        XCTAssertEqual(MessageSnippet(hits[1].snippet).markedTexts, ["הקול"])
    }

    func testTheExcerptsMarksBecomeHighlightedRanges() {
        let snippet = MessageSnippet("…so the [[mark]]voice[[/mark]] typing [[mark]]fix[[/mark]] landed…")
        XCTAssertEqual(snippet.text, "…so the voice typing fix landed…")
        XCTAssertEqual(snippet.marks.map { String(snippet.text[$0]) }, ["voice", "fix"])
        XCTAssertEqual(snippet.markedTexts, ["voice", "fix"])
        XCTAssertEqual(snippet.segments.map(\.marked), [false, true, false, true, false])

        // Hebrew reads the same way.
        let hebrew = MessageSnippet("…צריך לתקן את [[mark]]ההקלטה[[/mark]] בטלפון")
        XCTAssertEqual(hebrew.text, "…צריך לתקן את ההקלטה בטלפון")
        XCTAssertEqual(hebrew.marks.map { String(hebrew.text[$0]) }, ["ההקלטה"])
    }

    func testTheExcerptFoldsWhitespaceAndSurvivesOddMarks() {
        // Line breaks and runs of spaces fold; the ends are trimmed.
        let folded = MessageSnippet("  first line\n\n  [[mark]]second[[/mark]]\tline  ")
        XCTAssertEqual(folded.text, "first line second line")
        XCTAssertEqual(folded.markedTexts, ["second"])

        // A mark left open runs to the end; a stray close is dropped.
        XCTAssertEqual(MessageSnippet("open [[mark]]to the end").markedTexts, ["to the end"])
        let stray = MessageSnippet("a [[/mark]]b [[mark]]c[[/mark]]")
        XCTAssertEqual(stray.text, "a b c")
        XCTAssertEqual(stray.markedTexts, ["c"])

        // Adjacent marks join; an empty one is nothing.
        XCTAssertEqual(MessageSnippet("[[mark]]voi[[/mark]][[mark]]ce[[/mark]] x").markedTexts, ["voice"])
        XCTAssertEqual(MessageSnippet("x [[mark]][[/mark]]y").markedTexts, [])
        XCTAssertEqual(MessageSnippet("no marks at all").segments, [.init(text: "no marks at all", marked: false)])
        XCTAssertEqual(MessageSnippet("").segments, [])
    }

    func testTheExcerptLightsOnlyTheMatchedWords() {
        let attributed = MessageHitExcerpt.attributed(MessageSnippet("the [[mark]]voice[[/mark]] fix"), role: "You")
        XCTAssertEqual(String(attributed.characters), "You · the voice fix")
        let lit = attributed.runs
            .filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(lit, ["voice"])
    }

    // MARK: - Grouping

    func testHitsGroupBySessionInTheOrderOfEachSessionsBestHit() {
        let hits = [hit(5, turn: 40, rank: -9), hit(2, turn: 3, rank: -8), hit(5, turn: 12, rank: -7),
                    hit(7, turn: 1, rank: -6), hit(2, turn: 90, rank: -5), hit(5, turn: 2, rank: -4)]
        let groups = MessageSearch.group(hits)
        XCTAssertEqual(groups.map(\.conversationID), [5, 2, 7])
        XCTAssertEqual(groups[0].hits.map(\.turnIdx), [40, 12, 2], "best first, as the server ranked them")
        XCTAssertEqual(groups[0].best.turnIdx, 40)
        XCTAssertEqual(groups[0].more.map(\.turnIdx), [12, 2])
        XCTAssertEqual(groups[1].hits.map(\.turnIdx), [3, 90])
        XCTAssertTrue(groups[2].more.isEmpty)
        XCTAssertEqual(groups[0].title, "Voice")
        XCTAssertNil(MessageSearch.group([hit(1, turn: 0, title: "  ")]).first?.title, "a blank title is none")
        XCTAssertEqual(MessageSearch.group([]), [])
    }

    // MARK: - The short-query rule

    func testMessagesAreSearchedForAWordOfThreeCharacters() {
        XCTAssertFalse(MessageSearch.canSearchMessages(""))
        XCTAssertFalse(MessageSearch.canSearchMessages("ab"))
        XCTAssertFalse(MessageSearch.canSearchMessages("  ab  "))
        XCTAssertFalse(MessageSearch.canSearchMessages("ab cd"), "no word long enough for the index")
        XCTAssertTrue(MessageSearch.canSearchMessages("abc"))
        XCTAssertTrue(MessageSearch.canSearchMessages("fix ui"))
        XCTAssertTrue(MessageSearch.canSearchMessages("קול"))
        XCTAssertFalse(MessageSearch.canSearchMessages("קו"))
        XCTAssertEqual(MessageSearch.words("  fix   the ui "), ["fix", "the", "ui"])
    }

    func testAShortQueryDoesNotAskTheServer() async {
        var asked = false
        let outcome = await MessageSearch.run("ab") { _ in
            asked = true
            return []
        }
        XCTAssertEqual(outcome, .tooShort)
        XCTAssertFalse(asked)
    }

    // MARK: - Against a server

    func testAServerWithoutMessageSearchLeavesTitlesOnly() async {
        let server = MockCodegServer()
        let client = server.client

        // codeg without the endpoint: 501 not_implemented.
        server.on("message_search") { _ in
            .status(501, #"{"code": "not_implemented", "message": "API endpoint 'message_search' is not available in web mode"}"#)
        }
        let old = await MessageSearch.run("voice") { try await client.searchMessages($0) }
        XCTAssertEqual(old, .unsupported)

        // A proxy in front of one: a bare 404.
        server.on("message_search") { _ in .status(404, "{}") }
        let proxied = await MessageSearch.run("voice") { try await client.searchMessages($0) }
        XCTAssertEqual(proxied, .unsupported)

        // Anything else is a failure worth a retry.
        server.on("message_search") { _ in .status(500, #"{"message": "database is locked"}"#) }
        guard case .failed(let message) = await MessageSearch.run("voice", search: { try await client.searchMessages($0) })
        else { return XCTFail("a server error is a failure") }
        XCTAssertTrue(message.contains("database is locked"))
    }

    func testAMessageSearchAsksWithTheQueryAndLimitAndGroups() async {
        let server = MockCodegServer()
        let client = server.client
        server.on("message_search") { _ in
            .body("""
            [{"conversation_id": 3, "folder_id": 1, "agent_type": "codex", "title": "A", "turn_idx": 8,
              "role": "user", "snippet": "[[mark]]voice[[/mark]]", "rank": -3},
             {"conversation_id": 4, "folder_id": 1, "agent_type": "codex", "title": "B", "turn_idx": 2,
              "role": "assistant", "snippet": "[[mark]]voice[[/mark]]", "rank": -2},
             {"conversation_id": 3, "folder_id": 1, "agent_type": "codex", "title": "A", "turn_idx": 30,
              "role": "assistant", "snippet": "[[mark]]voice[[/mark]]", "rank": -1}]
            """)
        }
        let outcome = await MessageSearch.run("voice typing") { try await client.searchMessages($0) }
        guard case .found(let groups) = outcome else { return XCTFail("found: \(outcome)") }
        XCTAssertEqual(groups.map(\.conversationID), [3, 4])
        XCTAssertEqual(groups[0].hits.map(\.turnIdx), [8, 30])
        let body = server.calls("message_search").last?.body
        XCTAssertEqual(body?["query"] as? String, "voice typing")
        XCTAssertEqual(body?["limit"] as? Int, MessageSearch.limit)
    }

    // MARK: - Opening a hit

    private func makeApp(defaults: UserDefaults, server: MockCodegServer, compact: Bool) throws -> AppModel {
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        defaults.set(try JSONEncoder().encode([profile]), forKey: ServerStore.storageKey)
        let store = ServerStore(defaults: defaults)
        store.clientFactory = { _ in server.client }
        let app = AppModel(serverStore: store, defaults: defaults, transcriptCache: nil,
                           readingPositions: ReadingPositionStore(defaults: defaults))
        app.setLayout(compact: compact, initial: true)
        return app
    }

    func testAHitOpensItsSessionOnTheSearchTabAtItsMessage() throws {
        let server = MockCodegServer()
        let app = try makeApp(defaults: scratchDefaults(), server: server, compact: true)
        app.selectedTab = .search
        let jump = MessageSearch.jumpRequest(for: hit(42, turn: 17), query: "voice  fix")
        XCTAssertEqual(jump, TranscriptJumpRequest(turnIndex: 17, terms: ["voice", "fix"]))

        app.openMessage(conversationID: 42, jump: jump)
        XCTAssertEqual(app.paths[.search], [.conversation(42)], "Back returns to the results")
        XCTAssertEqual(app.markedConversationID, 42)
        // The session's model, made as the screen is pushed, opens at the message.
        let model = app.sessions.model(server: try XCTUnwrap(app.selectedServer), client: server.client,
                                       conversationID: 42)
        XCTAssertEqual(model.jumpRequest, jump)
        app.sessions.removeAll()
    }

    func testOnIPadAHitFillsTheDetailColumn() throws {
        let server = MockCodegServer()
        let app = try makeApp(defaults: scratchDefaults(), server: server, compact: false)
        app.openMessage(conversationID: 42, jump: TranscriptJumpRequest(turnIndex: 3, terms: []))
        XCTAssertEqual(app.selectedConversationID, 42)
        XCTAssertTrue(app.contentPath.isEmpty)
        app.sessions.removeAll()
    }

    func testTheChatsFilterOpensTheSearchWithItsWords() throws {
        let server = MockCodegServer()
        let phone = try makeApp(defaults: scratchDefaults(), server: server, compact: true)
        phone.paths[.search] = [.conversation(5)]
        phone.openSearch(query: "voice")
        XCTAssertEqual(phone.selectedTab, .search)
        XCTAssertEqual(phone.paths[.search], [], "the results, not a session left open there")
        let request = try XCTUnwrap(phone.searchRequest)
        XCTAssertEqual(request.query, "voice")
        phone.openSearch(query: "voice")
        XCTAssertNotEqual(phone.searchRequest, request, "asked again, searched again")
        phone.searchRequestHandled(try XCTUnwrap(phone.searchRequest))
        XCTAssertNil(phone.searchRequest)

        // An iPad has no Search tab: the search is pushed in the content column.
        let pad = try makeApp(defaults: scratchDefaults(), server: server, compact: false)
        pad.sidebarSection = .activity
        pad.openSearch(query: "voice")
        XCTAssertEqual(pad.sidebarSection, .chats)
        XCTAssertEqual(pad.contentPath, [.search("voice")])
        XCTAssertFalse(Route.search("voice").isSession)
    }

    func testTheStoreHandsAHitToTheModelMadeForIt() {
        let server = MockCodegServer()
        serve(10, on: server)
        let store = SessionModelStore()
        store.transcriptCache = nil
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        let positions = ReadingPositionStore(defaults: scratchDefaults())
        store.makeModel = { client, id, _ in
            SessionDetailViewModel(client: client, conversationID: id, makeEventStream: { _ in StreamFactory([]).make() },
                                   transcriptCache: nil, readingPositions: positions)
        }
        let jump = TranscriptJumpRequest(turnIndex: 4, terms: ["voice"])

        // Not made yet: the model made next takes it.
        store.requestOpen(conversationID: 3, at: jump)
        XCTAssertEqual(store.model(server: profile, client: server.client, conversationID: 3).jumpRequest, jump)

        // Kept: it takes it now. A notification afterwards wins.
        let kept = store.model(server: profile, client: server.client, conversationID: 4)
        store.requestOpen(conversationID: 4, at: jump)
        XCTAssertEqual(kept.jumpRequest, jump)
        store.requestOpenAtLatest(conversationID: 4)
        XCTAssertNil(kept.jumpRequest)

        // A notification before the model is made drops a hit waiting for it.
        store.requestOpen(conversationID: 5, at: jump)
        store.requestOpenAtLatest(conversationID: 5)
        XCTAssertNil(store.model(server: profile, client: server.client, conversationID: 5).jumpRequest)
        store.removeAll()
    }

    // MARK: - The session model reaching the message

    private func serve(_ count: Int, on server: MockCodegServer) {
        let transcript = WindowedTranscriptServer(count: count)
        transcript.install(on: server)
        transcripts.append(transcript)
    }

    private func makeModel(_ server: MockCodegServer, count: Int) -> SessionDetailViewModel {
        serve(count, on: server)
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                           makeEventStream: { _ in StreamFactory([]).make() }, transcriptCache: nil,
                                           readingPositions: ReadingPositionStore(defaults: scratchDefaults()))
        models.append(model)
        return model
    }

    private func anchor(_ decision: ReadingRestore) -> ReadingPosition? {
        if case .anchored(let position) = decision { return position }
        return nil
    }

    func testAHeldTurnOpensThereAtOnce() async {
        let server = MockCodegServer()
        let model = makeModel(server, count: 300)
        await model.load()
        XCTAssertEqual(model.turnsOffset, 180, "the latest turns")
        let generation = model.transcriptGeneration

        // Turn 253 is the third turn of the reply that starts at 251.
        model.requestJump(TranscriptJumpRequest(turnIndex: 253, terms: ["message"]))
        XCTAssertFalse(model.isFindingJumpTarget)
        XCTAssertEqual(model.transcriptJump?.turnID, "turn-251")
        XCTAssertEqual(model.transcriptJump?.terms, ["message"])
        XCTAssertNil(model.jumpRequest)
        XCTAssertEqual(model.transcriptGeneration, generation + 1, "a transcript on screen opens again")

        let position = anchor(model.restoreDecision(screen: UUID()))
        XCTAssertEqual(position?.anchorTurnID, "turn-251")
        XCTAssertEqual(position?.offset, -Double(TranscriptJump.topGap))
        XCTAssertFalse(model.hasNewMessagesBelow, "nothing new: nothing was saved for this session")

        // Landed: the next screen opens where the reader is.
        model.jumpLanded(try! XCTUnwrap(model.transcriptJump))
        XCTAssertNil(model.transcriptJump)
        XCTAssertEqual(model.restoreDecision(screen: UUID()), .bottom)
    }

    func testAnOlderTurnIsFetchedFirst() async {
        let server = MockCodegServer()
        let model = makeModel(server, count: 300)
        await model.load()

        model.requestJump(TranscriptJumpRequest(turnIndex: 12, terms: []))
        XCTAssertTrue(model.isFindingJumpTarget, "the transcript waits behind Finding the message")
        let found = await eventually { model.transcriptJump != nil }
        XCTAssertTrue(found)
        XCTAssertFalse(model.isFindingJumpTarget)
        XCTAssertLessThanOrEqual(model.turnsOffset, 12)
        XCTAssertEqual(model.transcriptJump?.turnID, "turn-11")
        // One page, all the way back to it.
        let pages = server.calls("get_folder_conversation_turns")
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.body["limit"] as? Int, 180 - 12 + 1)
        XCTAssertEqual(anchor(model.restoreDecision(screen: UUID()))?.anchorTurnID, "turn-11")
    }

    func testAHitAskedForBeforeTheSessionLoadsWaitsForIt() async {
        let server = MockCodegServer()
        let model = makeModel(server, count: 300)
        model.requestJump(TranscriptJumpRequest(turnIndex: 40, terms: []))
        XCTAssertFalse(model.isFindingJumpTarget, "the session's own loading view shows meanwhile")
        await model.load()
        let found = await eventually { model.transcriptJump != nil }
        XCTAssertTrue(found)
        XCTAssertEqual(model.transcriptJump?.turnID, "turn-40")
        XCTAssertEqual(anchor(model.restoreDecision(screen: UUID()))?.anchorTurnID, "turn-40")
    }

    func testASavedTranscriptWithoutTheTurnFetchesItBeforeShowing() async {
        let server = MockCodegServer()
        serve(300, on: server)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranscriptCache(root: root)
        let positions = ReadingPositionStore(defaults: scratchDefaults())
        func make() -> SessionDetailViewModel {
            let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID,
                                               makeEventStream: { _ in StreamFactory([]).make() },
                                               transcriptCache: cache, readingPositions: positions)
            models.append(model)
            return model
        }
        let first = make()
        await first.load()
        let key = TranscriptCache.serverKey(for: server.client)
        let deadline = Date().addingTimeInterval(5)
        var saved = false
        while !saved, Date() < deadline {
            saved = await cache.contains(serverKey: key, conversationID: Fixtures.conversationID)
            if !saved { try? await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(saved)

        // Opened again from a hit far before the saved window.
        let second = make()
        second.requestJump(TranscriptJumpRequest(turnIndex: 20, terms: []))
        await second.load()
        let found = await eventually { second.transcriptJump != nil }
        XCTAssertTrue(found)
        XCTAssertEqual(second.transcriptJump?.turnID, "turn-20")
        XCTAssertFalse(second.isFindingJumpTarget)
        XCTAssertEqual(anchor(second.restoreDecision(screen: UUID()))?.anchorTurnID, "turn-20")
    }

    func testATurnThatIsNotThereOpensAsUsual() async {
        let server = MockCodegServer()
        let model = makeModel(server, count: 30)
        await model.load()
        model.requestJump(TranscriptJumpRequest(turnIndex: 99, terms: []))
        let settled = await eventually { model.jumpRequest == nil && !model.isFindingJumpTarget }
        XCTAssertTrue(settled)
        XCTAssertNil(model.transcriptJump)
        XCTAssertEqual(model.restoreDecision(screen: UUID()), .bottom)
    }

    func testANotificationWinsOverAHit() async {
        let server = MockCodegServer()
        let model = makeModel(server, count: 30)
        await model.load()
        model.requestJump(TranscriptJumpRequest(turnIndex: 10, terms: []))
        XCTAssertNotNil(model.transcriptJump)
        model.requestOpenAtLatest(onScreen: false)
        XCTAssertNil(model.transcriptJump)
        XCTAssertEqual(model.restoreDecision(screen: UUID()), .bottom)
    }

    // MARK: - The row the transcript opens at

    private func turn(_ id: String, _ role: TurnRole, _ blocks: [ContentBlock]) -> MessageTurn {
        MessageTurn(id: id, role: role, blocks: blocks, timestamp: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testTheRowIsTheTurnsTextThatHoldsTheWords() {
        let turns = [
            turn("turn-0", .user, [.text("Where is the voice typing fix?")]),
            turn("turn-1", .assistant, [.thinking("Let me look for it"),
                                        .toolUse(id: "t1", name: "Grep", inputPreview: "voice", meta: nil),
                                        .toolResult(id: "t1", outputPreview: "3 files", isError: false)]),
            turn("turn-2", .assistant, [.text("The voice typing fix is in DictationController.")]),
            turn("turn-3", .user, [.text("Thanks")]),
        ]
        // A hit in the reply's second turn: its rows carry the reply's first turn.
        XCTAssertEqual(TranscriptJump.rowTurnID(forTurnAt: 2, in: turns, offset: 0), "turn-1")
        XCTAssertEqual(TranscriptJump.rowTurnID(forTurnAt: 0, in: turns, offset: 0), "turn-0")
        XCTAssertEqual(TranscriptJump.rowTurnID(forTurnAt: 12, in: turns, offset: 10), "turn-1")
        XCTAssertNil(TranscriptJump.rowTurnID(forTurnAt: 4, in: turns, offset: 0))
        XCTAssertNil(TranscriptJump.rowTurnID(forTurnAt: 9, in: turns, offset: 10))

        let nodes = TranscriptTimeline.buildPersisted(turns: turns, pending: [], agent: .claudeCode, suppressInFlight: false)
        let textRow = nodes.first { node in
            if case .assistantText(let text) = node.content { return text.contains("DictationController") }
            return false
        }?.id
        XCTAssertNotNil(textRow)
        let jump = TranscriptJump(token: 1, turnIndex: 2, turnID: "turn-1", terms: ["VOICE", "typing"])
        XCTAssertEqual(TranscriptJump.row(for: jump, in: nodes), textRow, "the text, not the reasoning or the tool call")

        // Words found nowhere: the turn's first row.
        let elsewhere = TranscriptJump(token: 2, turnIndex: 2, turnID: "turn-1", terms: ["nowhere"])
        XCTAssertEqual(TranscriptJump.row(for: elsewhere, in: nodes), nodes.first { $0.turnID == "turn-1" }?.id)
        // A user message is its own row.
        let prompt = TranscriptJump(token: 3, turnIndex: 0, turnID: "turn-0", terms: ["voice"])
        XCTAssertEqual(TranscriptJump.row(for: prompt, in: nodes), "turn-0")
        // A turn the window doesn't show.
        XCTAssertNil(TranscriptJump.row(for: TranscriptJump(token: 4, turnIndex: 7, turnID: "turn-7", terms: []),
                                        in: nodes))
    }

    func testOlderTurnsComeInOnePageWhenTheServerAllows() {
        XCTAssertEqual(TranscriptJump.pageLimit(target: 12, offset: 180, pageTurns: 150), 169)
        XCTAssertEqual(TranscriptJump.pageLimit(target: 170, offset: 180, pageTurns: 150), 150)
        XCTAssertEqual(TranscriptJump.pageLimit(target: 0, offset: 5_000, pageTurns: 150), 500)
    }
}
