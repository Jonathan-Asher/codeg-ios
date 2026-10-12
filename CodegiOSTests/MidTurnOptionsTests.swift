import XCTest
@testable import Codeg

/// Changing the agent's mode and options while a turn runs, as the codeg web
/// composer allows: what the options sheet lets you change mid-turn, a pick
/// applied at once and put back when the server or the agent refuses it, and
/// the sheet following the mode the agent (or another client) switches to.
@MainActor
final class MidTurnOptionsTests: XCTestCase {
    private var server: MockCodegServer!
    private var models: [SessionDetailViewModel] = []
    private var options: [AgentOptionsModel] = []

    override func setUp() async throws {
        server = MockCodegServer()
    }

    override func tearDown() async throws {
        models.forEach { $0.teardown() }
        models = []
        options.forEach { $0.teardown() }
        options = []
        server = nil
    }

    // MARK: - Wire fixtures (Claude: mode and model are config options)

    static let modeChoices = #"""
    [{"value": "default", "name": "Manual"}, {"value": "acceptEdits", "name": "Accept edits"},
     {"value": "plan", "name": "Plan"}, {"value": "bypassPermissions", "name": "Bypass permissions"}]
    """#

    static func configOptionsJSON(mode: String, model: String = "opus") -> String {
        """
        [{"id": "mode", "name": "Mode", "category": "mode",
          "kind": {"type": "select", "current_value": "\(mode)", "options": \(modeChoices), "groups": []}},
         {"id": "model", "name": "Model", "category": "model",
          "kind": {"type": "select", "current_value": "\(model)",
                   "options": [{"value": "opus", "name": "Opus"}, {"value": "sonnet", "name": "Sonnet"}],
                   "groups": []}},
         {"id": "effort", "name": "Effort", "category": "thought_level",
          "kind": {"type": "select", "current_value": "high",
                   "options": [{"value": "high", "name": "High"}, {"value": "low", "name": "Low"}],
                   "groups": []}}]
        """
    }

    static func modesJSON(current: String) -> String {
        """
        {"current_mode_id": "\(current)", "available_modes": [
          {"id": "default", "name": "Manual", "description": "Always ask"},
          {"id": "plan", "name": "Plan", "description": null},
          {"id": "bypassPermissions", "name": "Bypass permissions"}]}
        """
    }

    static func configOptions(mode: String, model: String = "opus") -> [SessionConfigOption] {
        try! CodegJSON.decoder.decode([SessionConfigOption].self, from: Data(configOptionsJSON(mode: mode, model: model).utf8))
    }

    static func modes(current: String) -> SessionModeState {
        try! CodegJSON.decoder.decode(SessionModeState.self, from: Data(modesJSON(current: current).utf8))
    }

    /// `acp_get_session_snapshot` for a connection on `mode` (both surfaces).
    static func connectionSnapshotJSON(mode: String, model: String = "opus") -> String {
        """
        {"connection_id": "conn-1", "status": "prompting", "selectors_ready": true,
         "current_mode": "\(mode)", "modes": \(modesJSON(current: mode)),
         "config_options": \(configOptionsJSON(mode: mode, model: model)), "available_commands": []}
        """
    }

    /// An attach snapshot of a running turn on `mode`, optionally with a
    /// permission card waiting.
    static func runningSnapshot(mode: String, permission: Bool = false) -> LiveSessionSnapshot {
        var fields = [
            #""connection_id": "conn-1""#, #""conversation_id": 7"#, #""status": "prompting""#,
            #""event_seq": 3"#,
            #""live_message": {"id": "m1", "role": "assistant", "content": [{"kind": "text", "text": "Working on it"}]}"#,
            "\"current_mode\": \"\(mode)\"",
            "\"modes\": \(modesJSON(current: mode))",
            "\"config_options\": \(configOptionsJSON(mode: mode))",
        ]
        if permission { fields.append("\"pending_permission\": \(permissionJSON(id: "perm-1"))") }
        let json = "{" + fields.joined(separator: ", ") + "}"
        return try! CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data(json.utf8))
    }

    static func permissionJSON(id: String) -> String {
        """
        {"request_id": "\(id)", "tool_call": {"title": "touch first.txt", "kind": "execute",
          "raw_input": {"command": "touch first.txt"}},
         "options": [{"option_id": "allow", "name": "Allow", "kind": "allow_once"},
                     {"option_id": "reject", "name": "Reject", "kind": "reject_once"}]}
        """
    }

    static func event(_ body: String) -> EventStream.Frame {
        Fixtures.event("{\"seq\": 10, \"connection_id\": \"conn-1\", \(body)}")
    }

    private func makeOptions(mode: String) -> AgentOptionsModel {
        let model = AgentOptionsModel(client: server.client)
        model.resolveConnection = { "conn-1" }
        model.applyLiveSnapshot(modes: nil, currentMode: nil, configOptions: Self.configOptions(mode: mode))
        options.append(model)
        return model
    }

    /// A screen opened on a session whose turn runs on the server.
    private func openLiveSession(_ factory: StreamFactory) async -> SessionDetailViewModel {
        server.on("get_folder_conversation") { _ in .body(Fixtures.detail(turnState: "running")) }
        server.on("acp_find_connection_for_conversation") { _ in .body(Fixtures.connectionInfo) }
        let model = SessionDetailViewModel(client: server.client, conversationID: Fixtures.conversationID) { _ in
            factory.make()
        }
        models.append(model)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        return model
    }

    // MARK: - What can change mid-turn

    func testTheModeAndEveryOptionStayChangeableWhileTheAgentResponds() {
        for option in Self.configOptions(mode: "plan") {
            let gate = AgentOptionsGate.availability(of: .config(option), isBusy: true, cardWaiting: false, applying: [])
            XCTAssertTrue(gate.enabled, "\(option.id) can change mid-turn, as on the web")
            XCTAssertNil(gate.hint, "no blanket 'can't be changed' message")
        }
        let modes = AgentOptionsGate.availability(of: .modeList, isBusy: true, cardWaiting: false, applying: [])
        XCTAssertTrue(modes.enabled)
        XCTAssertNil(modes.hint)
    }

    func testTheModeStaysChangeableWhileAPermissionCardWaitsAndSaysTheCardStillNeedsAnAnswer() {
        let options = Self.configOptions(mode: "default")
        let mode = options.first { $0.id == "mode" }!
        let model = options.first { $0.id == "model" }!

        let modeGate = AgentOptionsGate.availability(of: .config(mode), isBusy: true, cardWaiting: true, applying: [])
        XCTAssertTrue(modeGate.enabled)
        XCTAssertEqual(modeGate.hint, AgentOptionsGate.pendingRequestHint)

        let listGate = AgentOptionsGate.availability(of: .modeList, isBusy: true, cardWaiting: true, applying: [])
        XCTAssertTrue(listGate.enabled)
        XCTAssertEqual(listGate.hint, AgentOptionsGate.pendingRequestHint)

        let modelGate = AgentOptionsGate.availability(of: .config(model), isBusy: true, cardWaiting: true, applying: [])
        XCTAssertTrue(modelGate.enabled)
        XCTAssertNil(modelGate.hint, "the hint is about the mode only")
    }

    func testOnlyTheBranchIsLockedWhileTheAgentResponds() {
        let busy = AgentOptionsGate.availability(of: .branch, isBusy: true, cardWaiting: false, applying: [])
        XCTAssertFalse(busy.enabled)
        XCTAssertEqual(busy.hint, AgentOptionsGate.branchBusyHint)

        let idle = AgentOptionsGate.availability(of: .branch, isBusy: false, cardWaiting: false, applying: [])
        XCTAssertTrue(idle.enabled)
        XCTAssertNil(idle.hint)
    }

    func testAnOptionWaitsForItsOwnChangeOnly() {
        let options = Self.configOptions(mode: "plan")
        let mode = options.first { $0.id == "mode" }!
        let model = options.first { $0.id == "model" }!
        XCTAssertFalse(AgentOptionsGate.availability(of: .config(mode), isBusy: true, cardWaiting: false,
                                                     applying: ["mode"]).enabled)
        XCTAssertTrue(AgentOptionsGate.availability(of: .config(model), isBusy: true, cardWaiting: false,
                                                    applying: ["mode"]).enabled)
        XCTAssertTrue(AgentOptionsGate.availability(of: .modeList, isBusy: true, cardWaiting: false,
                                                    applying: ["mode"]).enabled,
                      "Claude's `mode` config option and the mode list are different keys")
        XCTAssertFalse(AgentOptionsGate.availability(of: .modeList, isBusy: false, cardWaiting: false,
                                                     applying: [AgentOptionsModel.modeKey]).enabled)
    }

    // MARK: - Optimistic apply, confirmed or put back

    func testAPickShowsAtOnceAndIsKeptOnceTheSessionConfirmsIt() async {
        server.on("acp_set_config_option") { _ in .body("null") }
        server.on("acp_get_session_snapshot") { _ in .body(Self.connectionSnapshotJSON(mode: "bypassPermissions")) }
        let model = makeOptions(mode: "plan")
        XCTAssertEqual(model.selectedConfig["mode"], "plan")

        model.selectConfig(optionId: "mode", valueId: "bypassPermissions")
        XCTAssertEqual(model.selectedConfig["mode"], "bypassPermissions", "optimistic")
        XCTAssertTrue(model.applying.contains("mode"))

        let settled = await eventually { model.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.selectedConfig["mode"], "bypassPermissions")
        XCTAssertNil(model.errorNotice)
        let call = server.calls("acp_set_config_option").first
        XCTAssertEqual(call?.body["connectionId"] as? String, "conn-1")
        XCTAssertEqual(call?.body["configId"] as? String, "mode")
        XCTAssertEqual(call?.body["valueId"] as? String, "bypassPermissions")
    }

    func testARefusedRequestPutsThePickBackAndSaysWhy() async {
        server.on("acp_set_config_option") { _ in .status(500, #"{"message": "connection is gone"}"#) }
        let model = makeOptions(mode: "plan")
        var reported: [String] = []
        model.onFailure = { reported.append($0) }

        model.selectConfig(optionId: "mode", valueId: "bypassPermissions")
        XCTAssertEqual(model.selectedConfig["mode"], "bypassPermissions")

        let settled = await eventually { model.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.selectedConfig["mode"], "plan", "reverted")
        let notice = model.errorNotice ?? ""
        XCTAssertTrue(notice.hasPrefix("Couldn't change Mode to Bypass permissions"), notice)
        XCTAssertTrue(notice.hasSuffix("It stays on Plan."), notice)
        XCTAssertEqual(reported, [notice])
    }

    func testAChangeTheAgentNeverTookIsPutBackWithTheServersReason() async {
        // The server took the request (it only queues it), the agent refused,
        // and the running turn reported it as a `set_config_option_failed`.
        server.on("acp_set_config_option") { _ in .body("null") }
        server.on("acp_get_session_snapshot") { _ in .body(Self.connectionSnapshotJSON(mode: "plan")) }
        let model = makeOptions(mode: "plan")

        model.selectConfig(optionId: "mode", valueId: "bypassPermissions")
        model.applyServerFailure(isModeChange: false,
                                 message: "Failed to set config option: Invalid value for config option mode")

        let settled = await eventually { model.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.selectedConfig["mode"], "plan")
        XCTAssertEqual(model.errorNotice,
                       "Couldn't change Mode to Bypass permissions: Invalid value for config option mode. It stays on Plan.")
    }

    func testTheModeListPickIsPutBackWhenTheSessionStaysOnTheOldMode() async {
        server.on("acp_set_mode") { _ in .body("null") }
        server.on("acp_get_session_snapshot") { _ in .body(Self.connectionSnapshotJSON(mode: "plan")) }
        let model = AgentOptionsModel(client: server.client)
        model.resolveConnection = { "conn-1" }
        model.applyLiveSnapshot(modes: Self.modes(current: "plan"), currentMode: "plan", configOptions: nil)
        options.append(model)

        model.selectMode("bypassPermissions")
        XCTAssertEqual(model.selectedModeId, "bypassPermissions")

        let settled = await eventually { model.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.selectedModeId, "plan")
        XCTAssertEqual(model.errorNotice, "Couldn't change Mode to Bypass permissions. It stays on Plan.")
        XCTAssertEqual(server.calls("acp_set_mode").first?.body["modeId"] as? String, "bypassPermissions")
    }

    func testAChangeThatLandsAfterTheReconcileGaveUpClearsItsMessage() async {
        server.on("acp_set_config_option") { _ in .body("null") }
        server.on("acp_get_session_snapshot") { _ in .body(Self.connectionSnapshotJSON(mode: "plan")) }
        let model = makeOptions(mode: "plan")

        model.selectConfig(optionId: "mode", valueId: "bypassPermissions")
        let settled = await eventually { model.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.selectedConfig["mode"], "plan")
        XCTAssertNotNil(model.errorNotice)

        // A slow agent answers after all; the live option list says so.
        model.applyLiveConfigOptions(Self.configOptions(mode: "bypassPermissions"))
        XCTAssertEqual(model.selectedConfig["mode"], "bypassPermissions")
        XCTAssertNil(model.errorNotice)
    }

    func testAnOlderLiveValueDoesNotUndoAPickOnItsWay() async {
        server.on("acp_set_config_option") { _ in .body("null") }
        server.on("acp_get_session_snapshot") { _ in .body(Self.connectionSnapshotJSON(mode: "bypassPermissions")) }
        let model = makeOptions(mode: "plan")

        model.selectConfig(optionId: "mode", valueId: "bypassPermissions")
        // An update the agent sent before it took the change.
        model.applyLiveConfigOptions(Self.configOptions(mode: "plan"))
        XCTAssertEqual(model.selectedConfig["mode"], "bypassPermissions")

        let settled = await eventually { model.applying.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.selectedConfig["mode"], "bypassPermissions")
    }

    func testTheAgentSettlingOnAnotherValueIsSaid() {
        let model = makeOptions(mode: "plan")
        model.applyRejection(configId: "model", optionName: "Model", requested: "Sonnet", actual: "Opus",
                             actualValue: "opus")
        XCTAssertEqual(model.selectedConfig["model"], "opus")
        XCTAssertEqual(model.errorNotice, "Couldn't change Model to Sonnet. The agent kept Opus.")
    }

    // MARK: - Live sync from the session's events

    func testTheModeEventsDecode() throws {
        let decode = { (json: String) in try CodegJSON.decoder.decode(AcpEvent.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"type": "mode_changed", "mode_id": "default"}"#), .modeChanged(modeId: "default"))
        XCTAssertEqual(try decode("{\"type\": \"session_config_options\", \"config_options\": \(Self.configOptionsJSON(mode: "acceptEdits"))}"),
                       .sessionConfigOptions(Self.configOptions(mode: "acceptEdits")))
        XCTAssertEqual(try decode("{\"type\": \"session_modes\", \"modes\": \(Self.modesJSON(current: "plan"))}"),
                       .sessionModes(Self.modes(current: "plan")))
        XCTAssertEqual(try decode(#"""
            {"type": "config_option_rejected", "config_id": "model", "option_name": "Model",
             "requested": "Sonnet", "actual": "Opus", "requested_value": "sonnet", "actual_value": "opus"}
            """#),
                       .configOptionRejected(configId: "model", optionName: "Model", requested: "Sonnet",
                                             actual: "Opus", actualValue: "opus"))
        XCTAssertEqual(try decode(#"{"type": "error", "message": "Failed to set mode: Invalid Mode", "agent_type": "claude_code", "code": "set_mode_failed"}"#),
                       .error(message: "Failed to set mode: Invalid Mode", code: "set_mode_failed"))
        // A malformed list never costs the stream its frame.
        XCTAssertEqual(try decode(#"{"type": "session_config_options", "config_options": 3}"#),
                       .unknown(type: "session_config_options"))

        let snap = Self.runningSnapshot(mode: "plan")
        XCTAssertEqual(snap.currentMode, "plan")
        XCTAssertEqual(snap.modes?.currentModeId, "plan")
        XCTAssertEqual(snap.configOptions?.map(\.id), ["mode", "model", "effort"])
    }

    /// The option list a codeg server sent when the mode was switched to
    /// Bypass permissions mid-turn (captured live; the model list left out).
    static let capturedOptionsEvent = #"""
    {"seq": 12, "connection_id": "conn-1", "type": "session_config_options", "config_options": [
     {"id": "mode", "name": "Mode", "description": "Session permission mode", "category": "mode",
      "kind": {"type": "select", "current_value": "bypassPermissions", "options": [
       {"value": "default", "name": "Manual", "description": "Always ask before making changes"},
       {"value": "acceptEdits", "name": "Accept edits", "description": "Automatically accept all file edits"},
       {"value": "plan", "name": "Plan", "description": "Create a plan before making changes"},
       {"value": "auto", "name": "Auto", "description": "The agent handles permission decisions"},
       {"value": "bypassPermissions", "name": "Bypass permissions", "description": "Accepts all permissions"}],
       "groups": []}, "recommended_value": null},
     {"id": "effort", "name": "Effort", "description": "Available effort levels for this model",
      "category": "thought_level", "kind": {"type": "select", "current_value": "xhigh", "options": [
       {"value": "low", "name": "Low", "description": null}, {"value": "medium", "name": "Medium", "description": null},
       {"value": "high", "name": "High", "description": null}, {"value": "xhigh", "name": "Xhigh", "description": null},
       {"value": "max", "name": "Max", "description": null}], "groups": []}, "recommended_value": "medium"},
     {"id": "fast", "name": "Fast mode", "description": "Faster responses on supported models", "category": "unknown",
      "kind": {"type": "select", "current_value": "off", "options": [
       {"value": "on", "name": "On", "description": null}, {"value": "off", "name": "Off", "description": null}],
       "groups": []}, "recommended_value": null}]}
    """#

    func testTheServersOptionListDecodes() throws {
        let envelope = try CodegJSON.decoder.decode(EventEnvelope.self, from: Data(Self.capturedOptionsEvent.utf8))
        guard case .sessionConfigOptions(let options) = envelope.event else {
            return XCTFail("decoded as \(envelope.event)")
        }
        XCTAssertEqual(options.map(\.id), ["mode", "effort", "fast"])
        XCTAssertEqual(options.first?.kind.selectCurrentValue, "bypassPermissions")
        XCTAssertTrue(AgentOptionsGate.isModeOption(options[0]))
        XCTAssertFalse(AgentOptionsGate.isModeOption(options[1]))

        let model = makeOptions(mode: "default")
        model.applyLiveConfigOptions(options)
        XCTAssertEqual(model.currentMode, AgentOptionsModel.ModeChoice(id: "bypassPermissions", name: "Bypass permissions"))
    }

    func testTheSheetFollowsTheModeTheAgentSwitchesTo() async {
        let factory = StreamFactory([.attach(Self.runningSnapshot(mode: "plan"))])
        let model = await openLiveSession(factory)
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live)
        XCTAssertEqual(model.agentOptions.selectedConfig["mode"], "plan", "seeded from the attach snapshot")
        XCTAssertEqual(model.agentOptions.selectedModeId, "plan")

        // ExitPlanMode approved: the agent leaves plan mode on its own.
        factory.opened[0].push(Self.event(#""type": "mode_changed", "mode_id": "default""#))
        let followed = await eventually { model.agentOptions.selectedModeId == "default" }
        XCTAssertTrue(followed)
        XCTAssertEqual(model.agentOptions.selectedConfig["mode"], "default")
        XCTAssertEqual(model.agentOptions.currentMode?.name, "Manual")

        // The option list that comes with it (or a change from the desktop).
        factory.opened[0].push(Self.event("\"type\": \"session_config_options\", \"config_options\": \(Self.configOptionsJSON(mode: "acceptEdits", model: "sonnet"))"))
        let listed = await eventually { model.agentOptions.selectedConfig["mode"] == "acceptEdits" }
        XCTAssertTrue(listed)
        XCTAssertEqual(model.agentOptions.selectedConfig["model"], "sonnet")
        XCTAssertTrue(model.isInFlight, "the turn goes on")
    }

    func testSwitchingModeLeavesAWaitingPermissionCardForAnAnswer() async {
        let factory = StreamFactory([.attach(Self.runningSnapshot(mode: "default", permission: true))])
        let model = await openLiveSession(factory)
        let carded = await eventually { model.pendingPermission != nil }
        XCTAssertTrue(carded)
        XCTAssertNil(model.permissionModeNote)

        // Bypass, picked here or on the desktop, while the card waits.
        factory.opened[0].push(Self.event("\"type\": \"session_config_options\", \"config_options\": \(Self.configOptionsJSON(mode: "bypassPermissions"))"))
        let switched = await eventually { model.agentOptions.currentMode?.id == "bypassPermissions" }
        XCTAssertTrue(switched)
        XCTAssertEqual(model.pendingPermission?.requestId, "perm-1", "the card still waits, as on the desktop")
        XCTAssertEqual(model.permissionModeNote,
                       "The mode is now Bypass permissions. This request came before the switch and still needs your answer.")

        factory.opened[0].push(Self.event(#""type": "permission_resolved", "request_id": "perm-1""#))
        let cleared = await eventually { model.pendingPermission == nil }
        XCTAssertTrue(cleared)
        XCTAssertNil(model.permissionModeNote)
    }

    func testAFailedModeChangeDoesNotEndTheTurn() async {
        let factory = StreamFactory([.attach(Self.runningSnapshot(mode: "default"))])
        let model = await openLiveSession(factory)
        let live = await eventually { model.isInFlight }
        XCTAssertTrue(live)

        factory.opened[0].push(Self.event(#""type": "error", "message": "Failed to set mode: Invalid Mode", "agent_type": "claude_code", "code": "set_mode_failed""#))
        let said = await eventually { model.notice != nil }
        XCTAssertTrue(said)
        XCTAssertEqual(model.notice, "Couldn't change the mode: Invalid Mode.")
        XCTAssertTrue(model.isInFlight, "a selector error is not a turn failure")

        // A real error still ends it.
        factory.opened[0].push(Self.event(#""type": "error", "message": "The agent crashed", "agent_type": "claude_code", "code": null"#))
        let ended = await eventually { !model.isInFlight }
        XCTAssertTrue(ended)
    }
}
