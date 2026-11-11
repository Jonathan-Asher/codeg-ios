import XCTest
@testable import Codeg

/// Moving a session to another project (codeg fork.227's
/// `move_conversation_to_folder`) and connecting every session where it
/// really runs (`working_dir`): the summary's new fields, the connects, the
/// move's request and answer, its refusals in plain words, when "Move to
/// Project…" is offered (never on an older server), the picker's dry runs,
/// and what a move changes on the phone.
@MainActor
final class SessionMoveTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []
    private var suites: [String] = []

    override func setUp() async throws {
        server = MockCodegServer()
        SessionMoveCapabilities.shared.reset()
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites = []
        SessionMoveCapabilities.shared.reset()
        server = nil
    }

    // MARK: - Fixtures

    private func summaryJSON(id: Int = 7, folderID: Int = 1, workingDir: String? = nil, kind: String? = "regular",
                             parentID: Int? = nil, agent: String = "claude_code") -> String {
        var extra = ""
        if let workingDir { extra += #", "working_dir": "\#(workingDir)""# }
        if let kind { extra += #", "kind": "\#(kind)""# }
        if let parentID { extra += #", "parent_id": \#(parentID)"# }
        return """
        {"id": \(id), "folder_id": \(folderID), "title": "Migration", "agent_type": "\(agent)",
         "status": "pending_review", "external_id": "ext-\(id)", "message_count": 2,
         "created_at": "2026-11-10T08:00:00Z", "updated_at": "2026-11-10T09:00:00Z", "turn_state": null\(extra)}
        """
    }

    private func summary(id: Int = 7, folderID: Int = 1, workingDir: String? = nil, kind: String? = "regular",
                         parentID: Int? = nil) throws -> ConversationSummary {
        try CodegJSON.decoder.decode(ConversationSummary.self, from: Data(summaryJSON(
            id: id, folderID: folderID, workingDir: workingDir, kind: kind, parentID: parentID).utf8))
    }

    private func detailJSON(folderID: Int = 1, workingDir: String? = nil) -> String {
        """
        {"summary": \(summaryJSON(folderID: folderID, workingDir: workingDir)), "turns": [],
         "session_stats": null, "in_flight_user_turn_id": null}
        """
    }

    private let foldersJSON = """
    [{"id": 1, "name": "billing", "path": "/w/billing", "last_opened_at": "2026-11-10T08:00:00Z", "sort_order": 0, "color": "blue"},
     {"id": 2, "name": "payments", "path": "/w/payments", "last_opened_at": "2026-11-10T08:00:00Z", "sort_order": 1, "color": "green"}]
    """

    private func folder(_ id: Int, _ name: String, sortOrder: Int = 0, parentId: Int? = nil,
                        kind: FolderKind = .regular, archived: Bool? = nil) -> FolderDetail {
        FolderDetail(id: id, name: name, path: "/w/\(name)", gitBranch: nil, defaultAgentType: nil,
                     lastOpenedAt: Date(timeIntervalSince1970: 1_790_000_000), sortOrder: sortOrder,
                     color: "blue", parentId: parentId, kind: kind, archived: archived)
    }

    private var payments: FolderDetail { folder(2, "payments", sortOrder: 1) }

    private func moveResultJSON(folderID: Int = 2, workingDir: String = "/w/payments", mode: String = "full",
                                reason: String? = nil, children: [Int] = [], dryRun: Bool = false) -> String {
        let reasonJSON = reason.map { #", "reason": "\#($0)""# } ?? ""
        return """
        {"conversation": \(summaryJSON(folderID: folderID, workingDir: workingDir)), "mode": "\(mode)"\(reasonJSON),
         "moved_children": \(children), "dry_run": \(dryRun)}
        """
    }

    /// A codeg refusal body: the app error's `code`, the English message, and
    /// the move's own code in `i18n_params` (and `i18n_key`).
    private func refusalJSON(_ code: String, appCode: String, message: String = "English sentence.") -> String {
        #"{"code": "\#(appCode)", "message": "\#(message)", "i18n_key": "errors.\#(code)", "i18n_params": {"code": "\#(code)"}}"#
    }

    private let notImplemented = #"{"code": "not_implemented", "message": "API endpoint 'move_conversation_to_folder' is not available in web mode"}"#

    private func makeModel() -> SessionDetailViewModel {
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, conversationID: 7,
                                           makeEventStream: { _ in factory.make() })
        models.append(model)
        return model
    }

    private func makeApp() -> AppModel {
        let suite = "move-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let profile = ServerProfile(name: "Box", urlString: "http://\(server.host)")
        defaults.set(try! JSONEncoder().encode([profile]), forKey: ServerStore.storageKey)
        let store = ServerStore(defaults: defaults)
        let mock = server!
        store.clientFactory = { _ in mock.client }
        let sessions = SessionModelStore()
        sessions.makeModel = { client, id, _ in
            let factory = StreamFactory([])
            return SessionDetailViewModel(client: client, conversationID: id, makeEventStream: { _ in factory.make() })
        }
        let app = AppModel(serverStore: store, defaults: defaults, sessions: sessions, transcriptCache: nil)
        app.setLayout(compact: true, initial: true)
        return app
    }

    /// The lists an activity refresh reads.
    private func serveLists(conversations: String = "[]") {
        let folders = foldersJSON
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("list_open_folder_details") { _ in .body(folders) }
        server.on("list_all_conversations") { _ in .body(conversations) }
        server.on("list_conversation_attention") { _ in .body("[]") }
        server.on("list_folder_groups") { _ in .body("[]") }
    }

    private func isReady(_ preview: SessionMoveModel.Preview) -> Bool {
        if case .ready = preview { return true }
        return false
    }

    // MARK: - working_dir and kind on the summary

    func testTheSummaryReadsWorkingDir() throws {
        let moved = try summary(workingDir: "/w/billing-old")
        XCTAssertEqual(moved.workingDir, "/w/billing-old")
        XCTAssertEqual(moved.workingDirectory(folderPath: "/w/payments"), "/w/billing-old",
                       "a session moved without its files runs where it ran")
        XCTAssertEqual(moved.kind, .regular)
    }

    func testASummaryWithoutWorkingDirConnectsInItsFolder() throws {
        let older = try summary(workingDir: nil, kind: nil)
        XCTAssertNil(older.workingDir, "a server that predates the field")
        XCTAssertNil(older.kind)
        XCTAssertEqual(older.workingDirectory(folderPath: "/w/billing"), "/w/billing")
        XCTAssertNil(older.workingDirectory(folderPath: nil))
        let blank = try summary(workingDir: "  ")
        XCTAssertEqual(blank.workingDirectory(folderPath: "/w/billing"), "/w/billing")
    }

    func testTheKindIsLenient() throws {
        XCTAssertEqual(try summary(kind: "chat").kind, .chat)
        XCTAssertEqual(try summary(kind: "delegate").kind, .delegate)
        XCTAssertEqual(try summary(kind: "something-new").kind, .other, "never fails the list")
    }

    func testWorkingDirAndKindSurviveTheSavedCopy() throws {
        let original = try summary(workingDir: "/w/billing-old", kind: "loop")
        let data = try TranscriptCache.encoder.encode(original)
        let copy = try TranscriptCache.decoder.decode(ConversationSummary.self, from: data)
        XCTAssertEqual(copy.workingDir, "/w/billing-old")
        XCTAssertEqual(copy.kind, .loop)
    }

    // MARK: - Connects

    func testAMessageConnectsWhereTheSessionRuns() async throws {
        let detail = detailJSON(folderID: 2, workingDir: "/w/billing")
        let folders = foldersJSON
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.folder?.path, "/w/payments", "listed under payments")
        XCTAssertEqual(model.workingDir, "/w/billing", "but running in billing")

        model.draft = "Run the migration"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(server.calls("acp_connect").first?.body["workingDir"] as? String, "/w/billing")
        XCTAssertEqual(model.forkTarget?.workingDir, "/w/billing", "a fork resumes it there too")
    }

    func testWithoutWorkingDirAMessageConnectsInTheFolder() async throws {
        let detail = detailJSON(folderID: 2, workingDir: nil)
        let folders = foldersJSON
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        let model = makeModel()
        await model.load()

        model.draft = "Run the migration"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(server.calls("acp_connect").first?.body["workingDir"] as? String, "/w/payments",
                       "an older server: the folder's path, as before")
        XCTAssertEqual(model.forkTarget?.workingDir, "/w/payments")
    }

    // MARK: - The request and the answer

    func testTheDryRunAsksForNothingToChange() async throws {
        let answer = moveResultJSON(folderID: 1, workingDir: "/w/billing", mode: "listed_only",
                                    reason: "agent_unsupported", children: [8], dryRun: true)
        server.on("move_conversation_to_folder") { _ in .body(answer) }
        let result = try await server.client.moveConversation(conversationId: 7, folderId: 2, dryRun: true)
        let body = try XCTUnwrap(server.calls("move_conversation_to_folder").first?.body)
        XCTAssertEqual(body["conversationId"] as? Int, 7)
        XCTAssertEqual(body["folderId"] as? Int, 2)
        XCTAssertEqual(body["dryRun"] as? Bool, true)
        XCTAssertEqual(result.mode, .listedOnly)
        XCTAssertEqual(result.reason, .agentUnsupported)
        XCTAssertEqual(result.movedChildren, [8])
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.conversation.workingDir, "/w/billing")
    }

    func testAMoveLeavesDryRunOut() async throws {
        let answer = moveResultJSON()
        server.on("move_conversation_to_folder") { _ in .body(answer) }
        let result = try await server.client.moveConversation(conversationId: 7, folderId: 2, dryRun: false)
        let body = try XCTUnwrap(server.calls("move_conversation_to_folder").first?.body)
        XCTAssertNil(body["dryRun"], "the server's default: a real move")
        XCTAssertEqual(result.mode, .full)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.conversation.folderId, 2)
        XCTAssertEqual(result.conversation.workingDir, "/w/payments")
        XCTAssertFalse(result.dryRun)
    }

    // MARK: - Refusals

    private func refusal(status: Int, _ body: String) async -> Error? {
        server.on("move_conversation_to_folder") { _ in .status(status, body) }
        do {
            _ = try await server.client.moveConversation(conversationId: 7, folderId: 2, dryRun: true)
            return nil
        } catch {
            return error
        }
    }

    func testA409RefusalKeepsItsCode() async throws {
        let running = await refusal(status: 409, refusalJSON("conversation_running", appCode: "turn_in_progress"))
        let refused = try XCTUnwrap(running as? SessionMoveRefusal, "not taken for a running turn's 409")
        XCTAssertEqual(refused.known, .conversationRunning)
        XCTAssertEqual(refused.errorDescription, "The session is working. Move it once its reply has finished.")

        let elsewhere = await refusal(status: 409, refusalJSON("running_elsewhere", appCode: "session_running_elsewhere"))
        XCTAssertEqual((elsewhere as? SessionMoveRefusal)?.known, .runningElsewhere)
        XCTAssertEqual((elsewhere as? SessionMoveRefusal)?.errorDescription,
                       "Claude Code is running this session outside codeg. Move it once that process has finished.")

        let pending = await refusal(status: 409, refusalJSON("resume_pending", appCode: "turn_in_progress"))
        XCTAssertEqual((pending as? SessionMoveRefusal)?.known, .resumePending)
        let closing = await refusal(status: 409, refusalJSON("session_closing", appCode: "turn_in_progress"))
        XCTAssertEqual((closing as? SessionMoveRefusal)?.known, .sessionClosing)
    }

    func testEveryRefusalSaysItInPlainWords() async throws {
        let cases: [(Int, String, String, String)] = [
            (404, "conversation_not_found", "not_found", "This session no longer exists."),
            (404, "folder_not_found", "not_found", "That project is no longer in the workspace."),
            (400, "same_folder", "invalid_input", "The session is already in that project."),
            (400, "chat_conversation", "invalid_input", "Chat sessions have no project to move from."),
            (400, "chat_folder", "invalid_input", "A session can’t be moved into a chat."),
            (400, "subsession", "invalid_input", "A sub-session moves with the session that started it."),
            (400, "unsupported_conversation", "invalid_input", "This kind of session can’t be moved."),
            (400, "work_task_linked", "invalid_input", "A work task runs this session; it stays with the task’s project."),
            (500, "move_failed", "io_error", "The session’s files couldn’t be moved, so nothing was changed."),
        ]
        for (status, code, appCode, plain) in cases {
            let error = await refusal(status: status, refusalJSON(code, appCode: appCode))
            let refused = try XCTUnwrap(error as? SessionMoveRefusal, code)
            XCTAssertEqual(refused.code, code)
            XCTAssertEqual(refused.errorDescription, plain, code)
        }
        for code in SessionMoveRefusal.Code.allCases {
            let message = SessionMoveRefusal.message(for: code)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("_"), "\(code.rawValue) reads as words, not as its code")
        }
    }

    func testTheCodeAlsoComesFromTheKeyAndAnUnknownOneReadsTheServer() async throws {
        let keyOnly = await refusal(status: 400, #"{"code": "invalid_input", "message": "x", "i18n_key": "errors.same_folder"}"#)
        XCTAssertEqual((keyOnly as? SessionMoveRefusal)?.known, .sameFolder)

        let unknown = await refusal(status: 400, refusalJSON("brand_new_reason", appCode: "invalid_input",
                                                             message: "A reason this app predates."))
        let refused = try XCTUnwrap(unknown as? SessionMoveRefusal)
        XCTAssertNil(refused.known)
        XCTAssertEqual(refused.errorDescription, "A reason this app predates.")
    }

    func testAnOlderServerIsNoRefusal() async throws {
        let older = await refusal(status: 501, notImplemented)
        XCTAssertNil(older as? SessionMoveRefusal)
        XCTAssertTrue((older as? APIError)?.isEndpointMissing == true)

        let plain409 = await refusal(status: 409, #"{"code": "turn_in_progress", "message": "busy"}"#)
        XCTAssertNil(plain409 as? SessionMoveRefusal, "no move code: as any other call reads it")
        if case .turnInProgress? = plain409 as? APIError {} else { XCTFail("a plain 409 is still a running turn") }

        let auth = await refusal(status: 401, refusalJSON("same_folder", appCode: "invalid_input"))
        if case .unauthorized? = auth as? APIError {} else { XCTFail("a 401 is the token's") }
    }

    // MARK: - When "Move to Project…" is offered

    func testTheMenuOffersTheMoveForATopLevelSessionUnlessTheServerLacksIt() throws {
        let row = try summary()
        XCTAssertTrue(SessionMoveRules.offersMove(row, support: .available))
        XCTAssertTrue(SessionMoveRules.offersMove(row, support: .unknown), "not checked yet: the sheet finds out")
        XCTAssertFalse(SessionMoveRules.offersMove(row, support: .missing), "hidden on an older server")
        XCTAssertFalse(SessionMoveRules.offersMove(try summary(parentID: 3), support: .available),
                       "a sub-session moves with its parent")
        XCTAssertFalse(SessionMoveRules.offersMove(try summary(kind: "chat"), support: .available))
        XCTAssertTrue(SessionMoveRules.offersMove(try summary(kind: nil), support: .available))
    }

    func testTheCheckTellsAnOlderServerApart() async throws {
        let older = notImplemented
        server.on("move_conversation_to_folder") { _ in .status(501, older) }
        let capabilities = SessionMoveCapabilities()
        let checked = await capabilities.probeIfNeeded(client: server.client)
        XCTAssertEqual(checked, .missing)
        let probe = try XCTUnwrap(server.calls("move_conversation_to_folder").first?.body)
        XCTAssertEqual(probe["conversationId"] as? Int, 0, "asked about a conversation that can’t exist")
        XCTAssertEqual(probe["dryRun"] as? Bool, true, "and only for a dry run")
        _ = await capabilities.probeIfNeeded(client: server.client)
        XCTAssertEqual(server.calls("move_conversation_to_folder").count, 1, "checked once per server")

        let newer = MockCodegServer()
        let notFound = refusalJSON("conversation_not_found", appCode: "not_found")
        newer.on("move_conversation_to_folder") { _ in .status(404, notFound) }
        let available = await capabilities.probeIfNeeded(client: newer.client)
        XCTAssertEqual(available, .available)

        let offline = MockCodegServer()
        offline.on("move_conversation_to_folder") { _ in .fail(.notConnectedToInternet) }
        let unknown = await capabilities.probeIfNeeded(client: offline.client)
        XCTAssertEqual(unknown, .unknown, "an unreachable server is not an older one; asked again later")
    }

    func testTheMenuIsHiddenOnAnOlderServer() async throws {
        let app = makeApp()
        let older = notImplemented
        server.on("move_conversation_to_folder") { _ in .status(501, older) }
        let row = try summary()
        let client = try XCTUnwrap(app.selectedClient())
        await app.actions.probeServerCapabilities(client: client)
        XCTAssertFalse(app.actions.offersMove(row), "no Move to Project… on a server without the move")
        XCTAssertFalse(app.actions.offersMove(row, client: client))
    }

    func testTheMenuIsOfferedOnAServerWithTheMove() async throws {
        let app = makeApp()
        let notFound = refusalJSON("conversation_not_found", appCode: "not_found")
        server.on("move_conversation_to_folder") { _ in .status(404, notFound) }
        let row = try summary()
        let client = try XCTUnwrap(app.selectedClient())
        await app.actions.probeServerCapabilities(client: client)
        XCTAssertEqual(SessionMoveCapabilities.shared.support(for: client), .available)
        XCTAssertTrue(app.actions.offersMove(row))

        app.actions.requestMove(row)
        XCTAssertEqual(app.actions.moveRequest?.conversation.id, 7, "the picker opens for it")
        XCTAssertEqual(app.actions.moveRequest?.serverID, app.selectedServerID)
    }

    // MARK: - The picker

    func testThePickerListsTheOtherOpenProjects() {
        let folders = [
            folder(1, "billing", sortOrder: 0),
            folder(3, "web", sortOrder: 2),
            folder(2, "payments", sortOrder: 1),
            folder(4, "scratch", sortOrder: 3, kind: .chat),
            folder(5, "billing-wt", sortOrder: 4, parentId: 1),
            folder(6, "old-site", sortOrder: 5, archived: true),
        ]
        let all = SessionMoveRules.choices(folders, currentFolderID: 1, archivedIDs: [6], query: "")
        XCTAssertEqual(all.active.map(\.id), [2, 3],
                       "its own left out, and a chat folder and a worktree hidden under its repo; the server's order")
        XCTAssertEqual(all.archived.map(\.id), [6], "archived projects last")

        let searched = SessionMoveRules.choices(folders, currentFolderID: 1, archivedIDs: [6], query: "PAY")
        XCTAssertEqual(searched.active.map(\.id), [2])
        XCTAssertTrue(searched.archived.isEmpty)
        let byPath = SessionMoveRules.choices(folders, currentFolderID: 1, archivedIDs: [6], query: "/w/web")
        XCTAssertEqual(byPath.active.map(\.id), [3], "the path matches too")
    }

    func testThePreviewSaysWhatTheMoveDoes() throws {
        let full = try CodegJSON.decoder.decode(SessionMoveResult.self, from: Data(moveResultJSON(dryRun: true).utf8))
        XCTAssertEqual(SessionMoveRules.preview(full, project: "payments", agent: "Claude Code"),
                       "Moves the session and its files to payments. Its next message rereads the session once.")
        XCTAssertNil(SessionMoveRules.childrenNote(full))

        let listed = try CodegJSON.decoder.decode(SessionMoveResult.self, from: Data(moveResultJSON(
            folderID: 1, workingDir: "/w/billing", mode: "listed_only", reason: "agent_unsupported",
            children: [8, 9], dryRun: true).utf8))
        let text = SessionMoveRules.preview(listed, project: "payments", agent: "Gemini CLI")
        XCTAssertTrue(text.hasPrefix("Gemini CLI keeps its sessions tied to the folder they ran in"), text)
        XCTAssertTrue(text.contains("listed under payments"), text)
        XCTAssertTrue(text.hasSuffix("It keeps running in /w/billing."), text)
        XCTAssertTrue(SessionMoveRules.childrenNote(listed)?.contains("2") == true)

        let outdated = SessionMoveResult(conversation: listed.conversation, mode: .listedOnly,
                                         reason: .claudeAdapterOutdated)
        XCTAssertTrue(SessionMoveRules.preview(outdated, project: "payments", agent: "Claude Code")
            .contains("too old to move session files"))
        let notFound = SessionMoveResult(conversation: listed.conversation, mode: .listedOnly,
                                         reason: .sessionFilesNotFound)
        XCTAssertTrue(SessionMoveRules.preview(notFound, project: "payments", agent: "Claude Code")
            .hasPrefix("This session’s files aren’t where Claude Code keeps them"))
    }

    func testAPickChecksTheMoveAndMoveMovesIt() async throws {
        let dryRun = moveResultJSON(dryRun: true)
        let moved = moveResultJSON()
        server.on("move_conversation_to_folder") { call in
            (call.body["dryRun"] as? Bool) == true ? .body(dryRun) : .body(moved)
        }
        let capabilities = SessionMoveCapabilities()
        let model = SessionMoveModel(conversation: try summary(), client: server.client, capabilities: capabilities)
        var heard: (SessionMoveResult, FolderDetail)?
        model.onMoved = { heard = ($0, $1) }
        XCTAssertFalse(model.canMove, "nothing picked")

        model.pick(payments)
        XCTAssertEqual(model.preview, .checking(folderID: 2))
        let ready = await eventually { self.isReady(model.preview) }
        XCTAssertTrue(ready)
        XCTAssertTrue(model.canMove)
        XCTAssertEqual(capabilities.support(for: server.client), .available)

        await model.move()
        XCTAssertEqual(heard?.0.conversation.folderId, 2)
        XCTAssertEqual(heard?.1.id, 2)
        XCTAssertFalse(model.isMoving)
        let calls = server.calls("move_conversation_to_folder")
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[1].body["dryRun"], "the move itself")
    }

    func testARefusedPickSaysWhyAndCantMove() async throws {
        let running = refusalJSON("conversation_running", appCode: "turn_in_progress")
        server.on("move_conversation_to_folder") { _ in .status(409, running) }
        let model = SessionMoveModel(conversation: try summary(), client: server.client,
                                     capabilities: SessionMoveCapabilities())
        model.pick(payments)
        let refused = await eventually {
            model.preview == .refused(folderID: 2,
                                      message: "The session is working. Move it once its reply has finished.")
        }
        XCTAssertTrue(refused)
        XCTAssertFalse(model.canMove)
        await model.move()
        XCTAssertEqual(server.calls("move_conversation_to_folder").count, 1, "no move without a dry run that allows it")
    }

    func testAMoveRefusedAfterTheCheckSaysWhy() async throws {
        let dryRun = moveResultJSON(dryRun: true)
        let started = refusalJSON("conversation_running", appCode: "turn_in_progress")
        server.on("move_conversation_to_folder") { call in
            (call.body["dryRun"] as? Bool) == true ? .body(dryRun) : .status(409, started)
        }
        let model = SessionMoveModel(conversation: try summary(), client: server.client,
                                     capabilities: SessionMoveCapabilities())
        var heard = false
        model.onMoved = { _, _ in heard = true }
        model.pick(payments)
        let ready = await eventually { self.isReady(model.preview) }
        XCTAssertTrue(ready)
        await model.move()
        XCTAssertFalse(heard)
        XCTAssertEqual(model.preview, .refused(folderID: 2,
                                               message: "The session is working. Move it once its reply has finished."))
    }

    func testOnlyTheLatestPickLands() async throws {
        let gate = ReplyGate()
        let billingAnswer = moveResultJSON(folderID: 1, workingDir: "/w/billing", dryRun: true)
        let paymentsAnswer = moveResultJSON(dryRun: true)
        server.on("move_conversation_to_folder") { call in
            (call.body["folderId"] as? Int) == 3 ? .held(gate, .body(billingAnswer)) : .body(paymentsAnswer)
        }
        let model = SessionMoveModel(conversation: try summary(id: 7, folderID: 1), client: server.client,
                                     capabilities: SessionMoveCapabilities())
        model.pick(folder(3, "web"))
        model.pick(payments)
        let ready = await eventually { self.isReady(model.preview) }
        XCTAssertTrue(ready)
        gate.open()
        try? await Task.sleep(for: .milliseconds(300))
        guard case .ready(let folderID, _) = model.preview else { return XCTFail("still the latest pick's") }
        XCTAssertEqual(folderID, 2)
        XCTAssertEqual(model.picked?.id, 2)
    }

    func testOnAnOlderServerThePickerSaysSoAndTheMenuGoes() async throws {
        let older = notImplemented
        server.on("move_conversation_to_folder") { _ in .status(501, older) }
        let capabilities = SessionMoveCapabilities()
        let model = SessionMoveModel(conversation: try summary(), client: server.client, capabilities: capabilities)
        model.pick(payments)
        let said = await eventually { model.preview == .serverTooOld }
        XCTAssertTrue(said)
        XCTAssertEqual(capabilities.support(for: server.client), .missing)
        XCTAssertFalse(SessionMoveRules.offersMove(try summary(), support: capabilities.support(for: server.client)))
    }

    // MARK: - After a move

    func testAfterAMoveTheOpenSessionFollowsAndTheListsRefresh() async throws {
        let app = makeApp()
        serveLists()
        let detail = detailJSON(folderID: 1, workingDir: "/w/billing")
        server.on("get_folder_conversation") { _ in .body(detail) }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
        let profile = try XCTUnwrap(app.selectedServer)
        let client = try XCTUnwrap(app.selectedClient())
        let model = app.sessions.model(server: profile, client: client, conversationID: 7)
        models.append(model)
        await model.load()
        XCTAssertEqual(model.folder?.id, 1)
        XCTAssertEqual(model.workingDir, "/w/billing")

        let changed = expectation(forNotification: .conversationsDidChange, object: nil)
        let result = try CodegJSON.decoder.decode(SessionMoveResult.self, from: Data(moveResultJSON().utf8))
        let row = try summary()
        app.actions.requestMove(row)
        let request = try XCTUnwrap(app.actions.moveRequest)
        app.actions.didMove(result, to: payments, request: request)

        XCTAssertNil(app.actions.moveRequest, "the picker closes")
        XCTAssertEqual(app.actions.moveNotice?.title, "Moved to payments")
        XCTAssertNil(app.actions.moveNotice?.detail)
        XCTAssertEqual(model.summary?.folderId, 2, "the open session shows its new project")
        XCTAssertEqual(model.folder?.id, 2)
        XCTAssertEqual(model.workingDir, "/w/payments", "and connects there")
        await fulfillment(of: [changed], timeout: 2)
        let refreshed = await eventually { !self.server.calls("list_all_conversations").isEmpty }
        XCTAssertTrue(refreshed, "the lists show it under its new project")

        model.draft = "Carry on"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        XCTAssertEqual(server.calls("acp_connect").last?.body["workingDir"] as? String, "/w/payments")
    }

    func testAListedOnlyMoveSaysWhereTheSessionKeepsRunning() throws {
        let listed = try CodegJSON.decoder.decode(SessionMoveResult.self, from: Data(moveResultJSON(
            folderID: 2, workingDir: "/w/billing", mode: "listed_only", reason: "agent_unsupported").utf8))
        let notice = SessionMoveRules.notice(listed, project: "payments")
        XCTAssertEqual(notice.title, "Listed under payments")
        XCTAssertEqual(notice.detail, "It keeps running in /w/billing")
        XCTAssertEqual(notice.spoken, "Listed under payments. It keeps running in /w/billing")
    }
}
