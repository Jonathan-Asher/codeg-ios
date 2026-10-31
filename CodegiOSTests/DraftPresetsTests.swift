import SwiftUI
import XCTest
@testable import Codeg

/// A new session set up without waiting: the agent and folder pickers open on
/// the lists the server gave last (kept per server), the mode, model and
/// effort on the lists last seen for each agent, picks made before the
/// session connects go with its connect, switching agents asks nothing of the
/// server, and a first message sent before the draft is ready goes once it is.
@MainActor
final class DraftPresetsTests: XCTestCase {
    private var server: MockCodegServer!
    private var store: DraftCatalogStore!
    private var root: URL!
    private var models: [SessionDetailViewModel] = []
    private var gates: [ReplyGate] = []
    private var savedPrefs: Data?

    override func setUp() async throws {
        server = MockCodegServer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-catalog-\(UUID().uuidString)", isDirectory: true)
        store = DraftCatalogStore(root: root)
        OutboxStore.rootOverride = root.appendingPathComponent("outbox", isDirectory: true)
        savedPrefs = UserDefaults.standard.data(forKey: SelectorPrefsStore.key)
        UserDefaults.standard.removeObject(forKey: SelectorPrefsStore.key)
    }

    override func tearDown() async throws {
        gates.forEach { $0.open() }
        gates = []
        models.forEach { $0.teardown() }
        models = []
        store.flush()
        server = nil
        OutboxStore.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
        if let savedPrefs {
            UserDefaults.standard.set(savedPrefs, forKey: SelectorPrefsStore.key)
        } else {
            UserDefaults.standard.removeObject(forKey: SelectorPrefsStore.key)
        }
    }

    // MARK: - Fixtures

    nonisolated static let alpha = FolderDetail(id: 1, name: "alpha", path: "/work/alpha", gitBranch: "main",
                                    defaultAgentType: nil, lastOpenedAt: Date(timeIntervalSince1970: 2_000),
                                    sortOrder: 0, color: "blue")
    nonisolated static let beta = FolderDetail(id: 2, name: "beta", path: "/work/beta", gitBranch: "dev",
                                   defaultAgentType: .pi, lastOpenedAt: Date(timeIntervalSince1970: 1_000),
                                   sortOrder: 1, color: "green")
    nonisolated static let gamma = FolderDetail(id: 3, name: "gamma", path: "/work/gamma", gitBranch: "main",
                                    defaultAgentType: .pi, lastOpenedAt: Date(timeIntervalSince1970: 3_000),
                                    sortOrder: 2, color: "inherit")
    nonisolated static let delta = FolderDetail(id: 4, name: "delta", path: "/work/delta", gitBranch: "main",
                                    defaultAgentType: nil, lastOpenedAt: Date(timeIntervalSince1970: 4_000),
                                    sortOrder: 3, color: "inherit")

    /// The main agent's lists: mode, model and effort as config options,
    /// on `model`.
    static func mainOptionsJSON(model: String = "large") -> String {
        """
        [{"id": "mode", "name": "Mode", "category": "mode",
          "kind": {"type": "select", "current_value": "default", "options": [
            {"value": "default", "name": "Manual"}, {"value": "acceptEdits", "name": "Accept edits"},
            {"value": "plan", "name": "Plan"}], "groups": []}},
         {"id": "model", "name": "Model", "category": "model",
          "kind": {"type": "select", "current_value": "\(model)", "options": [
            {"value": "large", "name": "Large"}, {"value": "small", "name": "Small"}], "groups": []}},
         {"id": "effort", "name": "Effort", "category": "thought_level",
          "kind": {"type": "select", "current_value": "high", "options": [
            {"value": "high", "name": "High"}, {"value": "low", "name": "Low"}], "groups": []}}]
        """
    }

    static var mainOptions: AgentOptionsSnapshot {
        AgentOptionsSnapshot(modes: nil, configOptions: options(mainOptionsJSON()))
    }

    /// A live session's snapshot with the main agent's lists, on `model`.
    static func snapshotJSON(model: String) -> String {
        """
        {"connection_id": "conn-1", "status": "connected", "selectors_ready": true,
         "config_options": \(mainOptionsJSON(model: model)), "available_commands": []}
        """
    }

    /// An existing conversation with the main agent.
    static let detailJSON = """
    {"summary": {"id": 7, "folder_id": 1, "title": "Docs", "agent_type": "codex", "status": "pending_review",
      "external_id": "ext-7", "message_count": 2, "created_at": "2026-10-04T16:00:00Z",
      "updated_at": "2026-10-04T16:20:00Z", "turn_state": null},
     "turns": [], "session_stats": null, "in_flight_user_turn_id": null}
    """

    static let piOptionsJSON = """
    [{"id": "model", "name": "Model", "category": "model",
      "kind": {"type": "select", "current_value": "fast", "options": [
        {"value": "fast", "name": "Fast"}, {"value": "deep", "name": "Deep"}], "groups": []}},
     {"id": "thinking", "name": "Thinking", "category": "thought_level",
      "kind": {"type": "select", "current_value": "high", "options": [
        {"value": "low", "name": "Low"}, {"value": "high", "name": "High"}, {"value": "max", "name": "Max"}],
       "groups": []}}]
    """

    /// Pi's lists: model and thinking level.
    static var piOptions: AgentOptionsSnapshot {
        AgentOptionsSnapshot(modes: nil, configOptions: options(piOptionsJSON))
    }

    static func options(_ json: String) -> [SessionConfigOption] {
        try! CodegJSON.decoder.decode([SessionConfigOption].self, from: Data(json.utf8))
    }

    /// `acp_list_agents`: each agent installed and enabled, in this order.
    static func agentsJSON(_ agents: [String]) -> String {
        let items = agents.enumerated().map { index, agent in
            """
            {"agent_type": "\(agent)", "registry_id": "\(agent)", "name": "\(agent)", "description": "",
             "available": true, "enabled": true, "sort_order": \(index)}
            """
        }
        return "[" + items.joined(separator: ", ") + "]"
    }

    static func foldersJSON(_ folders: [FolderDetail]) -> String {
        String(data: try! CodegJSON.encoder.encode(folders), encoding: .utf8)!
    }

    private var serverKey: String { TranscriptCache.serverKey(for: server.client) }

    /// What the last draft on this server left.
    private func seed(agents: [AgentType]? = [.codex, .pi],
                      folders: [FolderDetail]? = [DraftPresetsTests.alpha, DraftPresetsTests.beta],
                      options: [AgentType: AgentOptionsSnapshot] = [:]) {
        store.update(serverKey: serverKey) { catalog in
            catalog.agents = agents
            catalog.openFolders = folders
            catalog.allFolders = folders
            for (agent, lists) in options { catalog.agentOptions[agent.wireValue] = lists }
        }
    }

    /// A gate the test opens to let the server answer.
    private func hold() -> ReplyGate {
        let gate = ReplyGate()
        gates.append(gate)
        return gate
    }

    /// The server's agent and folder lists, held by `gate` when one is given.
    private func serveLists(agents: [String] = ["codex", "pi"],
                            folders: [FolderDetail] = [DraftPresetsTests.alpha, DraftPresetsTests.beta],
                            gate: ReplyGate? = nil) {
        let agentsReply = MockCodegServer.Reply.body(Self.agentsJSON(agents))
        let foldersReply = MockCodegServer.Reply.body(Self.foldersJSON(folders))
        let held: (MockCodegServer.Reply) -> MockCodegServer.Reply = { reply in
            guard let gate else { return reply }
            return .held(gate, reply)
        }
        server.on("acp_list_agents") { _ in held(agentsReply) }
        server.on("list_open_folder_details") { _ in held(foldersReply) }
        server.on("list_all_folder_details") { _ in held(foldersReply) }
    }

    /// What a draft's first send asks for.
    private func serveFirstSend() {
        server.on("create_conversation") { _ in .body("12") }
        server.on("acp_connect") { _ in .body(#""conn-9""#) }
    }

    private func makeDraft(_ request: NewSessionRequest = NewSessionRequest(),
                           factory: StreamFactory? = nil) -> SessionDetailViewModel {
        let factory = factory ?? StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, newSession: request, draftCatalog: store) { _ in
            factory.make()
        }
        models.append(model)
        return model
    }

    // MARK: - Agent and folder at once

    func testTheAgentButtonAndPickersAreReadyBeforeTheServerAnswers() async {
        seed()
        let gate = hold()
        serveLists(agents: ["codex", "pi", "gemini"], folders: [Self.alpha, Self.beta, Self.gamma], gate: gate)

        let model = makeDraft()
        // Nothing asked of the server yet.
        XCTAssertTrue(model.showsAgentButton)
        XCTAssertTrue(model.isDraftEditable)
        XCTAssertEqual(model.availableAgents, [.codex, .pi])
        XCTAssertEqual(model.availableFolders.map(\.id), [1, 2], "the most recently opened first")
        XCTAssertEqual(model.folder?.id, 1)
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertEqual(model.selectedAgent, .codex)

        model.loadIfNeeded()
        let asked = await eventually { self.server.calls("acp_list_agents").count == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.showsAgentButton)

        // Choosing doesn't wait for the server.
        model.selectAgent(.pi)
        XCTAssertEqual(model.agentTypeForUI, .pi)
        model.selectFolder(Self.beta)
        XCTAssertEqual(model.folder?.id, 2)
        XCTAssertEqual(model.currentBranch, "dev")
        XCTAssertEqual(model.availableAgents, [.codex, .pi], "the saved lists while the server is quiet")

        gate.open()
        let refreshed = await eventually { model.availableAgents == [.codex, .pi, .gemini] }
        XCTAssertTrue(refreshed, "the server's lists replace them")
        XCTAssertEqual(model.availableFolders.map(\.id), [3, 1, 2])
        XCTAssertEqual(model.selectedAgent, .pi, "a pick the server still offers stays")
        XCTAssertEqual(model.folder?.id, 2)
        XCTAssertTrue(server.calls("acp_connect").isEmpty, "no session was started for any of it")
        XCTAssertTrue(server.calls("acp_describe_agent_options").isEmpty)

        // Kept for the next draft, on disk.
        let saved = store.catalog(serverKey: serverKey)
        XCTAssertEqual(saved.agents, [.codex, .pi, .gemini])
        XCTAssertEqual(saved.openFolders?.map(\.id), [1, 2, 3])
        store.flush()
        XCTAssertEqual(DraftCatalogStore(root: root).catalog(serverKey: serverKey).agents, [.codex, .pi, .gemini])
    }

    func testUnchosenDefaultsFollowTheServersLatestLists() async {
        seed()
        serveLists(folders: [Self.alpha, Self.beta, Self.gamma])
        let model = makeDraft()
        XCTAssertEqual(model.folder?.id, 1)
        XCTAssertEqual(model.selectedAgent, .codex)

        await model.load()
        XCTAssertEqual(model.folder?.id, 3, "the folder opened most recently now")
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertEqual(model.selectedAgent, .pi, "with its default agent, as on a first load")
    }

    func testTheRequestsAgentIsCheckedAgainstTheServersListNotTheSavedOne() async {
        // An edited first message keeps its session's agent, newer than the saved list.
        seed(agents: [.codex, .pi])
        let gate = hold()
        serveLists(agents: ["codex", "pi", "gemini"], gate: gate)
        let model = makeDraft(NewSessionRequest(agent: .gemini))
        XCTAssertEqual(model.selectedAgent, .gemini)
        model.loadIfNeeded()
        gate.open()
        let refreshed = await eventually { model.availableAgents.contains(.gemini) }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.selectedAgent, .gemini, "the server offers it")

        // One the server doesn't offer falls back.
        let other = makeDraft(NewSessionRequest(agent: .grok))
        await other.load()
        XCTAssertEqual(other.selectedAgent, .codex)
    }

    func testAPreselectedFolderTheSavedListsDontHaveComesWithTheServers() async {
        seed()
        let gate = hold()
        serveLists(folders: [Self.alpha, Self.beta, Self.gamma], gate: gate)
        serveFirstSend()
        let model = makeDraft(NewSessionRequest(preselectedFolderID: 3))
        XCTAssertNil(model.folder, "no other folder stands in for it")
        model.loadIfNeeded()
        model.draft = "Check the worktree"
        model.sendFromComposer()
        XCTAssertEqual(model.pendingUserTurns.count, 1)

        gate.open()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let created = server.calls("create_conversation").first
        XCTAssertEqual(created?.body["folderId"] as? Int, 3)
        XCTAssertEqual(created?.body["agentType"] as? String, "pi", "the folder's default agent")
    }

    func testAMessageGoesToTheFolderAndAgentShownWhenItWasSent() async {
        seed()
        let gate = hold()
        // Meanwhile another folder became the most recently opened, with another default agent.
        serveLists(folders: [Self.alpha, Self.beta, Self.gamma], gate: gate)
        serveFirstSend()
        let model = makeDraft()
        model.loadIfNeeded()
        XCTAssertEqual(model.folder?.id, 1)
        XCTAssertEqual(model.selectedAgent, .codex)

        model.draft = "Run the tests"
        model.sendFromComposer()
        gate.open()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let created = server.calls("create_conversation").first
        XCTAssertEqual(created?.body["folderId"] as? Int, 1, "where it was sent, not the newer default")
        XCTAssertEqual(created?.body["agentType"] as? String, "codex")
        XCTAssertEqual(model.folder?.id, 1)
    }

    func testAChoiceTheServerNoLongerOffersFallsBackAsOnAFirstLoad() async {
        seed(agents: [.codex, .pi, .gemini], folders: [Self.alpha, Self.beta])
        serveLists(agents: ["codex"], folders: [Self.alpha, Self.gamma])
        let model = makeDraft()
        model.selectAgent(.gemini)
        model.selectFolder(Self.beta)

        await model.load()
        XCTAssertEqual(model.availableAgents, [.codex])
        XCTAssertEqual(model.folder?.id, 3, "the closed folder gave way to the most recently opened")
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertEqual(model.selectedAgent, .codex, "the agent gone from the server gave way to one it has")
    }

    // MARK: - Options at once

    func testSavedOptionsShowAtOnceWithoutStartingAnAgent() async {
        seed(options: [.codex: Self.mainOptions, .pi: Self.piOptions])
        serveLists()
        let model = makeDraft()
        let options = model.agentOptions
        XCTAssertTrue(model.optionsWaitForConnect)

        options.prepare(agentType: .codex, workingDir: Self.alpha.path)
        XCTAssertEqual(options.phase, .loaded, "at once, nothing awaited")
        XCTAssertEqual(options.snapshot, Self.mainOptions)
        XCTAssertEqual(options.selectedConfig["mode"], "default")
        XCTAssertEqual(options.selectedConfig["model"], "large")
        XCTAssertEqual(options.selectedConfig["effort"], "high")
        XCTAssertTrue(options.waitsForConnect)

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls("acp_describe_agent_options").isEmpty, "no agent started to read them")
        XCTAssertTrue(server.calls("acp_connect").isEmpty)
        XCTAssertTrue(server.calls("acp_get_session_snapshot_by_conversation").isEmpty)
        XCTAssertEqual(options.phase, .loaded)
    }

    func testWithNothingSavedTheOptionsComeWithTheSessionOrWhenAsked() async {
        seed(options: [:])
        serveLists()
        server.on("acp_describe_agent_options") { _ in
            .body("{\"modes\": null, \"config_options\": \(Self.mainOptionsJSON())}")
        }
        let model = makeDraft()
        let options = model.agentOptions

        options.prepare(agentType: .codex, workingDir: Self.alpha.path)
        XCTAssertEqual(options.phase, .atConnect, "said, not waited for")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls("acp_describe_agent_options").isEmpty, "no agent started by itself")

        // "Load Options Now".
        options.load()
        let loaded = await eventually { options.phase == .loaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(server.calls("acp_describe_agent_options").count, 1)
        XCTAssertEqual(store.catalog(serverKey: serverKey).agentOptions["codex"], Self.mainOptions,
                       "kept for the next draft")
    }

    func testOptionsPickedBeforeTheConnectGoWithIt() async {
        seed(options: [.codex: Self.mainOptions])
        serveLists()
        serveFirstSend()
        let model = makeDraft()
        await model.load()

        let options = model.agentOptions
        options.prepare(agentType: .codex, workingDir: model.folder?.path)
        options.selectConfig(optionId: "model", valueId: "small")
        options.selectConfig(optionId: "mode", valueId: "plan")
        XCTAssertEqual(options.selectedConfig["model"], "small")
        XCTAssertEqual(options.selectedConfig["mode"], "plan")
        XCTAssertTrue(options.applying.isEmpty, "nothing to wait for")
        XCTAssertEqual(SelectorPrefsStore.prefs(for: .codex).configValues, ["model": "small", "mode": "plan"])
        XCTAssertTrue(server.calls("acp_connect").isEmpty, "no session started for a pick")
        XCTAssertTrue(server.calls("acp_set_config_option").isEmpty)

        model.draft = "Plan the refactor"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let connect = server.calls("acp_connect").first
        XCTAssertEqual(connect?.body["agentType"] as? String, "codex")
        XCTAssertEqual(connect?.body["workingDir"] as? String, "/work/alpha")
        XCTAssertNil(connect?.body["sessionId"], "a new session")
        XCTAssertEqual(connect?.body["preferredConfigValues"] as? [String: String],
                       ["model": "small", "mode": "plan", "effort": "high"],
                       "the picks, and the rest as the sheet showed them")
        XCTAssertTrue(server.calls("acp_set_config_option").isEmpty, "the connect carried them")
        XCTAssertTrue(server.calls("acp_set_mode").isEmpty)
    }

    func testAPickMadeWhileTheConnectIsOnItsWayIsSetBeforeThePrompt() async {
        seed(options: [.codex: Self.mainOptions])
        serveLists()
        let gate = hold()
        server.on("create_conversation") { _ in .body("12") }
        server.on("acp_connect") { _ in .held(gate, .body(#""conn-9""#)) }
        server.on("acp_set_config_option") { _ in .body("null") }
        let model = makeDraft()
        await model.load()

        model.draft = "Go"
        model.sendFromComposer()
        let connecting = await eventually { self.server.calls("acp_connect").count == 1 }
        XCTAssertTrue(connecting)
        XCTAssertTrue(model.optionsWaitForConnect)
        let options = model.agentOptions
        options.prepare(agentType: .codex, workingDir: model.folder?.path)
        options.selectConfig(optionId: "model", valueId: "small")
        XCTAssertTrue(server.calls("acp_set_config_option").isEmpty)

        gate.open()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted)
        let set = server.calls("acp_set_config_option")
        XCTAssertEqual(set.count, 1)
        XCTAssertEqual(set.first?.body["connectionId"] as? String, "conn-9")
        XCTAssertEqual(set.first?.body["configId"] as? String, "model")
        XCTAssertEqual(set.first?.body["valueId"] as? String, "small")
        let paths = server.paths
        XCTAssertLessThan(paths.firstIndex(of: "acp_set_config_option") ?? .max, paths.firstIndex(of: "acp_prompt") ?? .max,
                          "set before the first prompt")
    }

    func testSwitchingAgentsNeverWaitsForAConnection() async {
        seed(agents: [.codex, .pi, .gemini], options: [.codex: Self.mainOptions, .pi: Self.piOptions])
        // The server doesn't answer anything.
        let gate = hold()
        serveLists(gate: gate)
        server.on("acp_connect") { _ in .held(gate, .body(#""conn-9""#)) }
        server.on("acp_describe_agent_options") { _ in .held(gate, .body("{}")) }
        let model = makeDraft()
        model.loadIfNeeded()
        let options = model.agentOptions
        options.isSheetShown = true
        options.prepare(agentType: model.agentTypeForUI, workingDir: model.folder?.path)
        XCTAssertEqual(options.snapshot, Self.mainOptions)

        // As the sheet's agent chips do.
        model.selectAgent(.pi)
        options.prepare(agentType: .pi, workingDir: model.folder?.path)
        XCTAssertEqual(model.agentTypeForUI, .pi)
        XCTAssertEqual(options.phase, .loaded)
        XCTAssertEqual(options.snapshot, Self.piOptions)
        options.selectConfig(optionId: "thinking", valueId: "max")
        XCTAssertEqual(options.selectedConfig["thinking"], "max")

        model.selectAgent(.codex)
        options.prepare(agentType: .codex, workingDir: model.folder?.path)
        XCTAssertEqual(options.phase, .loaded)
        XCTAssertEqual(options.snapshot, Self.mainOptions)

        model.selectAgent(.pi)
        options.prepare(agentType: .pi, workingDir: model.folder?.path)
        XCTAssertEqual(options.selectedConfig["thinking"], "max", "its pick is kept")

        // An agent with nothing saved says so at once.
        model.selectAgent(.gemini)
        options.prepare(agentType: .gemini, workingDir: model.folder?.path)
        XCTAssertEqual(options.phase, .atConnect)

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls("acp_connect").isEmpty)
        XCTAssertTrue(server.calls("acp_describe_agent_options").isEmpty)
        XCTAssertTrue(server.calls("acp_set_config_option").isEmpty)
    }

    func testTheSheetStartsOverWhenTheFolderChangesUnderAnOptionsLoad() async {
        seed(options: [:])
        let lists = hold()
        serveLists(folders: [Self.alpha, Self.beta, Self.delta], gate: lists)
        let probe = hold()
        server.on("acp_describe_agent_options") { _ in .held(probe, .body("{}")) }
        let model = makeDraft()
        model.loadIfNeeded()
        let options = model.agentOptions
        options.isSheetShown = true
        options.prepare(agentType: .codex, workingDir: model.folder?.path)
        XCTAssertEqual(options.phase, .atConnect)
        options.load()
        let loading = await eventually { options.phase == .loading }
        XCTAssertTrue(loading)

        // The server's lists move the default folder; the agent stays.
        lists.open()
        let moved = await eventually { model.folder?.id == 4 }
        XCTAssertTrue(moved)
        XCTAssertEqual(model.selectedAgent, .codex)
        XCTAssertEqual(options.phase, .atConnect, "not left loading")
    }

    // MARK: - Sending before the draft is ready

    func testAMessageSentBeforeTheDraftIsReadyGoesOnceItIs() async {
        // The first draft on this server: nothing saved, and the server is slow.
        let gate = hold()
        serveLists(folders: [Self.beta], gate: gate)
        serveFirstSend()
        let model = makeDraft()
        XCTAssertNil(model.folder)
        model.loadIfNeeded()
        let loaded = await eventually { model.phase == .loaded }
        XCTAssertTrue(loaded)

        model.draft = "Summarize the README"
        model.sendFromComposer()
        XCTAssertNil(model.notice, "not refused for a missing folder")
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.pendingUserTurns.count, 1, "shown as sent")
        XCTAssertTrue(model.isInFlight)
        XCTAssertEqual(model.sendState, .connecting)
        XCTAssertFalse(model.isDraftEditable)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls("create_conversation").isEmpty, "it waits for the lists")

        gate.open()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 }
        XCTAssertTrue(prompted, "and goes once they came")
        let created = server.calls("create_conversation").first
        XCTAssertEqual(created?.body["folderId"] as? Int, 2)
        XCTAssertEqual(created?.body["agentType"] as? String, "pi", "the folder's default agent")
        XCTAssertEqual(server.calls("acp_connect").first?.body["workingDir"] as? String, "/work/beta")
        XCTAssertNil(server.calls("acp_connect").first?.body["preferredConfigValues"],
                     "no picks, and no sheet that showed any")
        XCTAssertTrue(server.calls("acp_prompt")[0].text.contains("Summarize the README"))
        XCTAssertEqual(model.pendingUserTurns.count, 1)
        XCTAssertNil(model.notice)
    }

    // MARK: - The saved lists follow the server

    func testTheSessionsOwnListsReplaceTheSavedOnes() async {
        seed(options: [.codex: Self.mainOptions])
        serveLists()
        serveFirstSend()
        let factory = StreamFactory([])
        let model = makeDraft(factory: factory)
        await model.load()

        model.draft = "Hello"
        model.sendFromComposer()
        let prompted = await eventually { self.server.calls("acp_prompt").count == 1 && !factory.opened.isEmpty }
        XCTAssertTrue(prompted)

        // The session reports its lists: a model this phone hadn't seen.
        let lists = """
        [{"id": "model", "name": "Model", "category": "model",
          "kind": {"type": "select", "current_value": "large", "options": [
            {"value": "large", "name": "Large"}, {"value": "small", "name": "Small"}, {"value": "tiny", "name": "Tiny"}],
           "groups": []}}]
        """
        factory.opened[0].push(MidTurnOptionsTests.event("\"type\": \"session_config_options\", \"config_options\": \(lists)"))
        let replaced = await eventually {
            self.store.catalog(serverKey: self.serverKey).agentOptions["codex"]?.configOptions
                .first(where: { $0.id == "model" })?.kind.allSelectValues == ["large", "small", "tiny"]
        }
        XCTAssertTrue(replaced)

        store.flush()
        let reread = DraftCatalogStore(root: root).catalog(serverKey: serverKey)
        XCTAssertEqual(reread.agentOptions["codex"]?.configOptions.first(where: { $0.id == "model" })?.kind.allSelectValues,
                       ["large", "small", "tiny"], "on disk for the next launch")
    }

    // MARK: - Existing sessions

    func testAnExistingSessionStillAppliesAPickToItsConnection() async {
        server.on("get_folder_conversation") { _ in .body(Self.detailJSON) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        server.on("acp_get_session_snapshot_by_conversation") { _ in
            .body(Self.snapshotJSON(model: "large"))
        }
        server.on("acp_set_config_option") { _ in .body("null") }
        server.on("acp_get_session_snapshot") { _ in
            .body(Self.snapshotJSON(model: "small"))
        }
        let factory = StreamFactory([])
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID) { _ in
            factory.make()
        }
        model.draftCatalog = store
        models.append(model)
        await model.load()
        XCTAssertFalse(model.optionsWaitForConnect)

        let options = model.agentOptions
        options.prepare(agentType: .codex, workingDir: nil)
        let loaded = await eventually { options.phase == .loaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(server.calls("acp_get_session_snapshot_by_conversation").count, 1, "read from its session")

        options.selectConfig(optionId: "model", valueId: "small")
        let applied = await eventually { self.server.calls("acp_set_config_option").count == 1 }
        XCTAssertTrue(applied, "sent to its connection at once")
        XCTAssertEqual(server.calls("acp_set_config_option").first?.body["connectionId"] as? String, "conn-1")
        XCTAssertNotNil(store.catalog(serverKey: serverKey).agentOptions["codex"],
                        "its lists are kept for new sessions")
    }

    // MARK: - The store

    func testTheCatalogIsKeptPerServerAcrossLaunches() {
        store.update(serverKey: "a") { $0.agents = [.pi]; $0.agentOptions["pi"] = Self.piOptions }
        store.update(serverKey: "b") { $0.agents = [.codex]; $0.openFolders = [Self.alpha] }
        store.flush()

        let next = DraftCatalogStore(root: root)
        XCTAssertEqual(next.catalog(serverKey: "a").agents, [.pi])
        XCTAssertEqual(next.catalog(serverKey: "a").agentOptions["pi"], Self.piOptions)
        XCTAssertNil(next.catalog(serverKey: "a").openFolders)
        XCTAssertEqual(next.catalog(serverKey: "b").agents, [.codex])
        XCTAssertEqual(next.catalog(serverKey: "b").openFolders, [Self.alpha])
        XCTAssertNil(next.catalog(serverKey: "c").agents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.file(serverKey: "a").path))
    }

    func testTheChoiceRules() {
        let offered = DraftChoices.offeredFolders([Self.alpha, Self.beta, Self.gamma])
        XCTAssertEqual(offered.map(\.id), [3, 1, 2])
        XCTAssertEqual(DraftChoices.folder(keeping: nil, preselectedID: 2, offered: offered, all: offered)?.id, 2)
        XCTAssertEqual(DraftChoices.folder(keeping: Self.alpha, preselectedID: 2, offered: offered, all: offered)?.id, 1)
        XCTAssertEqual(DraftChoices.folder(keeping: nil, preselectedID: 9, offered: offered, all: offered)?.id, 3)
        XCTAssertEqual(DraftChoices.agent(keeping: .gemini, folder: Self.beta, available: [.codex, .pi]), .pi)
        XCTAssertEqual(DraftChoices.agent(keeping: .gemini, folder: Self.alpha, available: [.codex, .pi]), .codex)
        XCTAssertEqual(DraftChoices.agent(keeping: .gemini, folder: Self.alpha, available: nil), .gemini,
                       "kept while what the server offers isn't known")
    }

    // MARK: - Screenshots

    /// The new-session sheet with saved options, and with none saved for the
    /// agent, into the `compose-screenshots` artifact.
    func testScreenshots() throws {
        seed(agents: [.codex, .pi, .gemini], options: [.codex: Self.mainOptions, .pi: Self.piOptions])
        let model = makeDraft()
        model.agentOptions.prepare(agentType: .codex, workingDir: model.folder?.path)
        for style in Shot.styles {
            try Shot.capture("draft-options-saved", style, in: Shot.composeDirectory) { sheet(model) }
        }
        model.selectAgent(.gemini)
        model.agentOptions.prepare(agentType: .gemini, workingDir: model.folder?.path)
        for style in Shot.styles {
            try Shot.capture("draft-options-at-connect", style, in: Shot.composeDirectory) { sheet(model) }
        }
    }

    private func sheet(_ model: SessionDetailViewModel) -> some View {
        AgentOptionsSheet(
            isBusy: false, cardWaiting: false, options: model.agentOptions,
            newSession: NewSessionAgentConfig(
                availableAgents: model.availableAgents, selectedAgent: model.agentTypeForUI,
                onSelectAgent: { _ in }, availableFolders: model.availableFolders,
                selectedFolder: model.folder, onSelectFolder: { _ in }
            ),
            branch: SessionBranchConfig(
                folderName: model.displayFolderName, folderPath: model.folder?.path, current: model.currentBranch,
                load: { nil }, switchTo: { _, _ in .noop }, create: { _, _ in false }
            )
        )
        .background(Theme.bg)
    }
}
