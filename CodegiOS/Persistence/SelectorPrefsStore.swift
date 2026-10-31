import Foundation

/// One agent's remembered "selector" choices: its last-used mode + per-option
/// config values. Mirrors the codeg web client's persisted shape.
struct SelectorPrefs: Codable, Equatable, Sendable {
    var modeId: String?
    var configValues: [String: String]?
}

/// Local cache of agent mode/config selections, keyed by agent type — a direct
/// port of the web client's `codeg:selector-prefs` localStorage.
///
/// Why: the agent options sheet's mode (plan/default/yolo) and config options
/// (e.g. model) otherwise reset to the server's fresh-session defaults every
/// time. We persist the user's pick per agent and re-apply it: passed to
/// `acp_connect` as `preferredModeId`/`preferredConfigValues` (the server applies
/// them before reporting state), and used to pre-select the draft options sheet.
///
/// Keyed purely by `AgentType` (not per-server) like the web — modes/config are
/// intrinsic to the agent; a value the current server doesn't know is simply
/// ignored on connect.
enum SelectorPrefsStore {
    /// The `UserDefaults` key (tests save and restore it).
    static let key = "codeg.selectorPrefs.v1"

    /// All persisted prefs, keyed by `AgentType.rawValue`.
    static func all() -> [String: SelectorPrefs] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: SelectorPrefs].self, from: data)
        else { return [:] }
        return map
    }

    /// The remembered choices for one agent (empty if none yet).
    static func prefs(for agent: AgentType) -> SelectorPrefs {
        all()[agent.rawValue] ?? SelectorPrefs()
    }

    /// Remember the agent's mode selection.
    static func saveMode(agent: AgentType, modeId: String) {
        update(agent) { $0.modeId = modeId }
    }

    /// Remember one config option's value, preserving the agent's other values.
    static func saveConfig(agent: AgentType, configId: String, valueId: String) {
        update(agent) {
            var values = $0.configValues ?? [:]
            values[configId] = valueId
            $0.configValues = values
        }
    }

    private static func update(_ agent: AgentType, _ mutate: (inout SelectorPrefs) -> Void) {
        var map = all()
        var prefs = map[agent.rawValue] ?? SelectorPrefs()
        mutate(&prefs)
        map[agent.rawValue] = prefs
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
