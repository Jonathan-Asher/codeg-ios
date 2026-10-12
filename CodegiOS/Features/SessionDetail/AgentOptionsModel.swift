import SwiftUI
import Observation

/// Backs the agent-options sheet: loads the mode/config catalog + current state
/// and applies the user's picks.
///
/// Source of truth is the AUTHORITATIVE live session snapshot
/// (`acp_get_session_snapshot_by_conversation`, injected as `loadSnapshot`), which
/// reflects the real chat session's current mode/config. When no live session
/// exists yet, it falls back to a server-side *probe* agent
/// (`acp_describe_agent_options`) just to enumerate the catalog (its `current_*`
/// are fresh-session defaults). The snapshot query is cheap (no spawn) and the
/// sheet auto-loads it on open; when there's no live session and no cached
/// catalog, it also auto-runs the probe (no manual "Load options" tap).
///
/// Applying targets the live *chat* connection via the injected
/// `resolveConnection` closure (which validates connection liveness — see
/// `SessionDetailViewModel.resolveConnectionForOptions`). Because `set_mode` /
/// `set_config_option` only *enqueue* the change server-side (HTTP 200 ≠ applied),
/// an apply optimistically updates the selection and then RECONCILES by polling
/// the snapshot until it reflects the change (or settles on the agent's
/// normalized value). An HTTP error — including a dead connection — reverts and
/// notices, and so does a change the session never takes (the agent refused
/// it, or the running turn reported `set_mode_failed`).
///
/// Picks apply mid-turn too, as on the codeg web composer (see
/// `AgentOptionsGate`), and the selection follows the session's live events
/// (`mode_changed`, `session_modes`, `session_config_options`, the attach
/// snapshot), so a mode the agent leaves on its own (plan mode after an
/// approved plan) or another client picks shows here at once.
@MainActor
@Observable
final class AgentOptionsModel {

    enum Phase: Equatable {
        case idle              // not loaded yet — transient; prepare() auto-loads
        case loading           // probe agent starting
        case loaded            // modes/config available
        case empty             // loaded, but nothing configurable
        case failed(String)
    }

    private let client: CodegClient

    /// Injected by the owner to resolve (and cache) the shared chat connection.
    var resolveConnection: (() async throws -> String)?

    /// Injected by the owner to fetch the authoritative live session snapshot for
    /// this conversation (nil when no live session exists).
    var loadSnapshot: (() async throws -> SessionSnapshot?)?

    private(set) var phase: Phase = .idle
    private(set) var snapshot: AgentOptionsSnapshot?

    /// Current selection. Authoritative when sourced from the live snapshot; a
    /// fresh-session default when only the probe catalog is available.
    private(set) var selectedModeId: String?
    private(set) var selectedConfig: [String: String] = [:]   // configId → valueId

    /// Keys currently being applied (`modeKey` or a configId) so a row can spin.
    private(set) var applying: Set<String> = []
    /// The value each in-flight apply asked for, by key.
    private var applyingDesired: [String: String] = [:]
    /// Why the server couldn't apply an in-flight change, by key.
    private var serverFailures: [String: String] = [:]

    /// Transient apply failure surfaced under the selectors.
    var errorNotice: String?
    /// Told about every failed change, so the session screen can show it once
    /// the sheet is closed.
    var onFailure: ((String) -> Void)?
    /// The options sheet is on screen (it shows `errorNotice` itself then).
    var isSheetShown = false

    /// Catalog cache per agent type so re-opening the sheet doesn't re-spawn a
    /// probe when there's no live session.
    private var cache: [AgentType: AgentOptionsSnapshot] = [:]

    private var agentType: AgentType?
    private var workingDir: String?
    private var loadTask: Task<Void, Never>?
    /// The cheap auto snapshot-load kicked off on `prepare`.
    private var autoLoadTask: Task<Void, Never>?
    /// Memoized chat-connection resolution, shared across concurrent applies.
    private var connectionTask: Task<String, Error>?

    /// Bounded reconcile poll after an apply (~2.3s total).
    private static let reconcileAttempts = 6

    init(client: CodegClient) {
        self.client = client
    }

    /// Call when the sheet appears. Sets context and auto-loads: a cheap
    /// authoritative snapshot first (no agent spawn) — if a live session exists the
    /// sheet populates immediately; otherwise it shows a cached catalog, or auto-
    /// runs the probe (`load()`) when there's neither.
    func prepare(agentType: AgentType, workingDir: String?) {
        // Switching agents (draft new-session picker) invalidates the previous
        // catalog + selection — clear them so the new agent's options reload clean.
        if let current = self.agentType, current != agentType {
            snapshot = nil
            selectedModeId = nil
            selectedConfig = [:]
            phase = .idle
        }
        self.agentType = agentType
        self.workingDir = workingDir
        errorNotice = nil
        // A new sheet session should re-validate the chat connection (it may have
        // gone stale since last open). Don't cancel — an in-flight apply still
        // holds its own reference to the prior task.
        connectionTask = nil
        if case .failed = phase { phase = .idle }

        autoLoadTask?.cancel()
        autoLoadTask = Task { [weak self] in
            guard let self else { return }
            // 1) Cheap authoritative snapshot first (no agent spawn).
            if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                if Task.isCancelled { return }
                self.cache[agentType] = snap.asOptionsSnapshot
                self.applyAuthoritative(snap)
                return
            }
            if Task.isCancelled { return }
            // 2) No live session — show a previously fetched catalog if we have one
            //    (highlights are defaults, not authoritative).
            if let cached = self.cache[agentType] {
                self.applyCatalog(cached)
                return
            }
            // 3) Otherwise auto-run the probe (formerly the manual "Load options"
            //    tap) so opening the sheet loads the config on its own.
            self.load()
        }
    }

    /// Load the catalog (auto-run by `prepare()`, and by the failure "Try Again").
    /// Prefers the authoritative snapshot (no spawn); only when there's no live
    /// session does it spawn a probe agent to enumerate the catalog (uses the
    /// client's longer probe timeout).
    func load() {
        guard let agentType else { return }
        if case .loading = phase { return }
        errorNotice = nil
        // Neutral loading during the cheap snapshot re-check; switch to the
        // probe-specific phase (`.loading`) only once a probe actually starts, so
        // the "starting an agent" copy never shows for a snapshot/cache result
        // (incl. a "Try Again" where a live session has since appeared).
        phase = .idle
        loadTask?.cancel()
        let workingDir = self.workingDir
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                if Task.isCancelled { return }
                self.cache[agentType] = snap.asOptionsSnapshot
                self.applyAuthoritative(snap)
                return
            }
            if Task.isCancelled { return }
            self.phase = .loading   // no live selectors — a probe agent is now starting
            do {
                let probe = try await self.client.describeAgentOptions(agentType: agentType, workingDir: workingDir)
                if Task.isCancelled { return }
                self.cache[agentType] = probe
                self.applyCatalog(probe)
            } catch is CancellationError {
                // superseded / torn down
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    private func fetchSnapshot() async throws -> SessionSnapshot? {
        guard let loadSnapshot else { return nil }
        return try await loadSnapshot()
    }

    /// Adopt authoritative current mode/config from the live snapshot (overwrites
    /// any optimistic selection — the snapshot IS the truth).
    private func applyAuthoritative(_ snap: SessionSnapshot) {
        let options = snap.asOptionsSnapshot
        snapshot = options
        // A change still on its way keeps its pick until it settles.
        if let mode = snap.modes?.currentModeId ?? snap.currentMode {
            adoptLive(key: Self.modeKey, value: mode)
        }
        for option in snap.configOptions ?? [] {
            if let current = option.kind.selectCurrentValue, !current.isEmpty {
                adoptLive(key: option.id, value: current)
            }
        }
        phase = options.isEmpty ? .empty : .loaded
    }

    /// Adopt a probe catalog (no live session — drafts / fresh agents). Seed
    /// selections, only where the user hasn't already picked, preferring the
    /// LOCALLY CACHED last-used choice (validated against this catalog) and
    /// falling back to the catalog's fresh-session default. This is what makes a
    /// new session's options sheet open on the user's remembered mode/config.
    private func applyCatalog(_ snap: AgentOptionsSnapshot) {
        snapshot = snap
        let prefs = agentType.map { SelectorPrefsStore.prefs(for: $0) } ?? SelectorPrefs()
        if selectedModeId == nil {
            if let saved = prefs.modeId,
               snap.modes?.availableModes.contains(where: { $0.id == saved }) == true {
                selectedModeId = saved
            } else {
                selectedModeId = snap.modes?.currentModeId
            }
        }
        for option in snap.configOptions where selectedConfig[option.id] == nil {
            if let saved = prefs.configValues?[option.id], option.kind.allSelectValues.contains(saved) {
                selectedConfig[option.id] = saved
            } else if let current = option.kind.selectCurrentValue, !current.isEmpty {
                selectedConfig[option.id] = current
            }
        }
        phase = snap.isEmpty ? .empty : .loaded
    }

    // MARK: - Apply

    func selectMode(_ modeId: String) {
        guard modeId != selectedModeId, canApply(Self.modeKey) else { return }
        let previous = selectedModeId
        selectedModeId = modeId   // optimistic (only after the guards pass)
        // Remember the pick per agent so the next new session starts in this mode
        // (re-applied via acp_connect's preferredModeId). Mirrors the web client.
        if let agentType { SelectorPrefsStore.saveMode(agent: agentType, modeId: modeId) }
        run(key: Self.modeKey, desired: modeId, previous: previous,
            revert: { [weak self] in self?.selectedModeId = previous }) { client, conn in
            try await client.setMode(connectionId: conn, modeId: modeId)
        }
    }

    func selectConfig(optionId: String, valueId: String) {
        guard selectedConfig[optionId] != valueId, canApply(optionId) else { return }
        let previous = selectedConfig[optionId]
        selectedConfig[optionId] = valueId   // optimistic (only after the guards pass)
        if let agentType { SelectorPrefsStore.saveConfig(agent: agentType, configId: optionId, valueId: valueId) }
        run(key: optionId, desired: valueId, previous: previous,
            revert: { [weak self] in self?.selectedConfig[optionId] = previous }) { client, conn in
            try await client.setConfigOption(connectionId: conn, configId: optionId, valueId: valueId)
        }
    }

    /// True when an apply for `key` can start: a connection resolver is wired and
    /// no apply for the same key is already in flight — so a rapid/second tap can't
    /// move the highlighted selection without sending a matching network command.
    private func canApply(_ key: String) -> Bool {
        resolveConnection != nil && !applying.contains(key)
    }

    private func run(
        key: String,
        desired: String,
        previous: String?,
        revert: @escaping () -> Void,
        action: @escaping (CodegClient, String) async throws -> Void
    ) {
        guard resolveConnection != nil else { revert(); return }
        applying.insert(key)
        applyingDesired[key] = desired
        errorNotice = nil
        let client = self.client
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await self.sharedConnection()
                try await action(client, conn)
                // Drop the memoized resolution so the NEXT apply re-validates the
                // connection's liveness (only concurrent in-flight applies, which
                // already hold this task, share one resolve).
                self.connectionTask = nil
                // HTTP 200 only means the command was enqueued — reconcile against
                // the authoritative snapshot of the EXACT connection we targeted
                // (by id, so it works even before the connection binds to the
                // conversation) before trusting the optimistic value.
                await self.reconcile(key: key, desired: desired, connectionId: conn)
            } catch is CancellationError {
                revert()
                self.connectionTask = nil
            } catch {
                revert()
                self.connectionTask = nil   // re-resolve on the next apply
                self.failed(key: key, desired: desired, previous: previous, reason: Self.describe(error))
            }
            self.applying.remove(key)
            self.applyingDesired[key] = nil
        }
    }

    /// The change of `key` to `desired` didn't go through: say what, why, and
    /// what the session is still on.
    private func failed(key: String, desired: String, previous: String?, reason: String?) {
        let label = self.label(forKey: key)
        let wanted = valueName(forKey: key, value: desired)
        var message = "Couldn't change \(label) to \(wanted)"
        let because = (reason ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        if !because.isEmpty { message += ": \(because)" }
        message += "."
        if let current = currentSelection(forKey: key) ?? previous {
            message += " It stays on \(valueName(forKey: key, value: current))."
        }
        errorNotice = message
        onFailure?(message)
    }

    /// The name the sheet shows for `key` ("Mode", "Model", …).
    func label(forKey key: String) -> String {
        if key == Self.modeKey { return "Mode" }
        return snapshot?.configOptions.first { $0.id == key }?.name ?? key
    }

    /// The display name of `value` for `key`, or the value itself.
    func valueName(forKey key: String, value: String) -> String {
        if let option = snapshot?.configOptions.first(where: { $0.id == key }) {
            let choices = (option.kind.selectOptions ?? []) + (option.kind.selectGroups ?? []).flatMap(\.options)
            if let name = choices.first(where: { $0.value == value })?.name { return name }
        }
        if key == Self.modeKey, let name = snapshot?.modes?.availableModes.first(where: { $0.id == value })?.name {
            return name
        }
        return value
    }

    private func currentSelection(forKey key: String) -> String? {
        key == Self.modeKey ? selectedModeId : selectedConfig[key]
    }

    /// Resolve the chat connection once and share it across concurrent applies, so
    /// a rapid mode+config change can't each resolve a different connection (which
    /// would strand one setting on an orphan). The model is `@MainActor`, so the
    /// synchronous prologue here is race-free: the first caller installs the task,
    /// later callers await the same one. Cleared after each apply (so the next one
    /// re-validates liveness) and on (re)prepare / teardown.
    private func sharedConnection() async throws -> String {
        if let task = connectionTask {
            return try await task.value
        }
        guard let resolveConnection else { throw APIError.transport("Session closed.") }
        let task = Task { try await resolveConnection() }
        connectionTask = task
        return try await task.value
    }

    /// Poll the authoritative snapshot of the targeted connection until it confirms
    /// `desired` for `key`, or it settles on a different (agent-normalized) value,
    /// or we time out. Adopts the authoritative value when seen; otherwise keeps
    /// the optimistic pick. Queries by `connectionId` so it works even before the
    /// connection is bound to the conversation.
    private func reconcile(key: String, desired: String, connectionId: String) async {
        var lastSeen: String?
        for attempt in 0..<Self.reconcileAttempts {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 400))
            if Task.isCancelled { return }
            guard let snap = try? await client.connectionSnapshot(connectionId: connectionId),
                  let current = currentValue(forKey: key, in: snap) else { continue }
            lastSeen = current
            if current == desired {
                setSelection(key: key, value: current)   // confirmed
                serverFailures[key] = nil
                return
            }
        }
        // Settled without confirming the pick — adopt the last authoritative value
        // we saw (the agent may have normalized/rejected it) and say so; if we
        // never saw one, keep the optimistic pick as a best effort.
        let serverReason = serverFailures.removeValue(forKey: key)
        if let lastSeen {
            setSelection(key: key, value: lastSeen)
            if errorNotice == nil || serverReason != nil {
                failed(key: key, desired: desired, previous: lastSeen, reason: serverReason)
            }
        } else if let serverReason {
            report(serverReason)
        }
    }

    private func currentValue(forKey key: String, in snap: SessionSnapshot) -> String? {
        if key == Self.modeKey { return snap.modes?.currentModeId ?? snap.currentMode }
        return snap.configOptions?.first { $0.id == key }?.kind.selectCurrentValue
    }

    // MARK: - Live updates from the session's event stream

    /// The selection key of the mode list. Config options use their id, and
    /// Claude's mode is a config option whose id is `mode`, so the mode list
    /// has a key no config id can be.
    nonisolated static let modeKey = "\u{1}modes"

    /// The session's mode changed (`mode_changed`): the agent left plan mode,
    /// or another client switched it. The open sheet follows at once.
    func applyLiveMode(_ modeId: String) {
        guard !modeId.isEmpty else { return }
        if let modes = snapshot?.modes {
            snapshot = AgentOptionsSnapshot(
                modes: SessionModeState(currentModeId: modeId, availableModes: modes.availableModes),
                configOptions: snapshot?.configOptions ?? [])
        }
        adoptLive(key: Self.modeKey, value: modeId)
        // Claude shows its mode as a config option; follow it there too, should
        // the option list that normally comes with the change be late.
        if let option = snapshot?.configOptions.first(where: AgentOptionsGate.isModeOption),
           option.kind.allSelectValues.contains(modeId) {
            adoptLive(key: option.id, value: modeId)
        }
    }

    /// A new mode list from the agent (`session_modes`).
    func applyLiveModes(_ modes: SessionModeState) {
        snapshot = AgentOptionsSnapshot(modes: modes, configOptions: snapshot?.configOptions ?? [])
        adoptLive(key: Self.modeKey, value: modes.currentModeId)
        if case .loaded = phase {} else if snapshot?.isEmpty == false { phase = .loaded }
    }

    /// The agent's config options with their current values
    /// (`session_config_options`), after any change, from any client.
    func applyLiveConfigOptions(_ options: [SessionConfigOption]) {
        snapshot = AgentOptionsSnapshot(modes: snapshot?.modes, configOptions: options)
        for option in options {
            if let current = option.kind.selectCurrentValue, !current.isEmpty {
                adoptLive(key: option.id, value: current)
            }
        }
        if case .loaded = phase {} else if snapshot?.isEmpty == false { phase = .loaded }
    }

    /// The selectors an attach snapshot carries, current as of that snapshot.
    func applyLiveSnapshot(modes: SessionModeState?, currentMode: String?, configOptions: [SessionConfigOption]?) {
        let hasModes = !(modes?.availableModes.isEmpty ?? true)
        let hasConfig = !(configOptions?.isEmpty ?? true)
        guard hasModes || hasConfig else {
            if let currentMode, !currentMode.isEmpty { adoptLive(key: Self.modeKey, value: currentMode) }
            return
        }
        if hasModes, let modes { applyLiveModes(modes) }
        if let currentMode, !currentMode.isEmpty { applyLiveMode(currentMode) }
        if hasConfig, let configOptions { applyLiveConfigOptions(configOptions) }
    }

    /// The agent kept another value than the one picked (`config_option_rejected`).
    func applyRejection(configId: String, optionName: String, requested: String, actual: String, actualValue: String) {
        if !actualValue.isEmpty { setSelection(key: configId, value: actualValue) }
        let name = optionName.isEmpty ? label(forKey: configId) : optionName
        var message = "Couldn't change \(name) to \(requested)."
        let kept = actual.isEmpty ? actualValue : actual
        if !kept.isEmpty { message += " The agent kept \(kept)." }
        report(message)
    }

    /// The server couldn't apply a change: the `set_mode_failed` or
    /// `set_config_option_failed` error a running turn reports instead of
    /// failing the request. The change in flight of that kind is put back
    /// (the reconcile then says so with this reason); with none in flight the
    /// reason is shown as it came.
    func applyServerFailure(isModeChange: Bool, message: String) {
        let reason = Self.serverReason(message)
        guard let key = applying.first(where: { isModeChange ? $0 == Self.modeKey : $0 != Self.modeKey }) else {
            report(isModeChange ? "Couldn't change the mode: \(reason)." : "Couldn't change that option: \(reason).")
            return
        }
        serverFailures[key] = reason
    }

    /// The agent's own reason, without the server's "Failed to set …:" lead-in
    /// (the message around it already says what failed).
    nonisolated static func serverReason(_ message: String) -> String {
        var reason = message
        for prefix in ["Failed to set mode: ", "Failed to set config option: "] where reason.hasPrefix(prefix) {
            reason = String(reason.dropFirst(prefix.count))
        }
        return reason.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
    }

    /// The session's current mode as the sheet shows it: the mode config option
    /// (Claude's `mode`) when the agent has one, else the mode list.
    var currentMode: ModeChoice? {
        if let option = snapshot?.configOptions.first(where: AgentOptionsGate.isModeOption),
           let id = selectedConfig[option.id] {
            return ModeChoice(id: id, name: valueName(forKey: option.id, value: id))
        }
        guard let id = selectedModeId else { return nil }
        return ModeChoice(id: id, name: valueName(forKey: Self.modeKey, value: id))
    }

    struct ModeChoice: Equatable {
        let id: String
        let name: String
    }

    private func report(_ message: String) {
        errorNotice = message
        onFailure?(message)
    }

    /// A live value for `key`. While a change of that key is on its way, only
    /// the value asked for is taken (it confirms the change): an older value
    /// can still be in flight from before the change, and the reconcile that
    /// follows the change adopts what the agent finally settled on.
    private func adoptLive(key: String, value: String) {
        if let desired = applyingDesired[key] {
            if value == desired { setSelection(key: key, value: value) }
            return
        }
        setSelection(key: key, value: value)
    }

    private func setSelection(key: String, value: String) {
        if key == Self.modeKey { selectedModeId = value } else { selectedConfig[key] = value }
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        autoLoadTask?.cancel()
        autoLoadTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        applying.removeAll()
        applyingDesired.removeAll()
        serverFailures.removeAll()
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}

/// What the options sheet lets you change while a turn runs. It mirrors the
/// codeg web composer, which disables none of its selectors mid-turn: the mode
/// (the mode list, or a `mode` config option) and every config option (model,
/// effort, …) change at once, also while a permission or plan card waits. The
/// server applies them inside the running turn. Only the workspace stays put
/// while the agent responds: the folder is fixed for a session, and switching
/// the branch would change the working tree under the agent.
enum AgentOptionsGate {
    struct Availability: Equatable {
        var enabled: Bool
        var hint: String?
    }

    enum Item {
        case modeList
        case config(SessionConfigOption)
        case branch
    }

    static let pendingRequestHint = "A request already waiting for you still needs an answer; the new mode applies to what the agent does next."
    static let branchBusyHint = "The branch can't change while the agent is responding."

    /// Whether `item` can be changed now, and what to say under it.
    /// - Parameters:
    ///   - isBusy: a turn is running.
    ///   - cardWaiting: a permission or plan card waits for an answer.
    ///   - applying: the keys whose change is on its way (`AgentOptionsModel.applying`).
    static func availability(of item: Item, isBusy: Bool, cardWaiting: Bool, applying: Set<String>) -> Availability {
        switch item {
        case .modeList:
            return Availability(enabled: !applying.contains(AgentOptionsModel.modeKey),
                                hint: cardWaiting ? pendingRequestHint : nil)
        case .config(let option):
            return Availability(enabled: !applying.contains(option.id),
                                hint: cardWaiting && isModeOption(option) ? pendingRequestHint : nil)
        case .branch:
            return Availability(enabled: !isBusy, hint: isBusy ? branchBusyHint : nil)
        }
    }

    /// A config option that is the agent's mode (Claude publishes its mode as
    /// the `mode` option, category `mode`).
    static func isModeOption(_ option: SessionConfigOption) -> Bool {
        option.category == "mode" || option.id == "mode"
    }
}
