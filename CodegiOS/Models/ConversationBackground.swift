import Foundation

/// What a live session is doing in the background (codeg fork `background`,
/// Rust `acp::background_status::ConversationBackground`), served on the
/// conversation list and the attention snapshot.
///
/// `turn_state` only covers turns codeg sends. It reads `running` while a turn
/// is held open for background work (the agent answered long ago), and null
/// while background tasks still run after the turn ended or while the agent
/// runs a whole turn of its own after a task notification woke it. This says
/// which. Absent from a server that predates it, and for a session with
/// nothing in the background: the app then behaves exactly as before.
struct ConversationBackground: Codable, Equatable, Hashable, Sendable {
    /// One running background task.
    struct Brief: Codable, Equatable, Hashable, Sendable {
        /// The agent's own task id.
        let id: String
        /// `agent` (async sub-agent), `shell`, `monitor`, `workflow` or `task`.
        let kind: String
        /// The description the agent gave it, if any.
        var label: String? = nil

        /// How the kind reads in a list ("Shell"), English like the other
        /// activity strings (see `SessionActivity.label`).
        var kindName: String {
            switch kind {
            case "agent": return "Sub-agent"
            case "shell": return "Shell"
            case "monitor": return "Monitor"
            case "workflow": return "Workflow"
            default: return "Task"
            }
        }

        /// "Shell: Wait for runs, then judge", or the kind alone.
        var line: String {
            if let label, !label.isEmpty { return "\(kindName): \(label)" }
            return kindName
        }
    }

    /// Background tasks still running (sub-agents, shells, monitors,
    /// workflows). 0 while a turn is held open with no task known by name.
    var taskCount: Int = 0
    /// The running tasks, at most a handful (`taskCount` has them all).
    var tasks: [Brief] = []
    /// The agent is running a turn of its own right now, woken by its
    /// background work (a task finished, a monitor fired, a cron prompt).
    var outOfTurn: Bool = false
    /// The turn codeg sent is still open only because background work holds
    /// it; the agent itself is idle.
    var heldOpen: Bool = false

    init(taskCount: Int = 0, tasks: [Brief] = [], outOfTurn: Bool = false, heldOpen: Bool = false) {
        self.taskCount = taskCount
        self.tasks = tasks
        self.outOfTurn = outOfTurn
        self.heldOpen = heldOpen
    }

    private enum CodingKeys: String, CodingKey {
        case taskCount, tasks, outOfTurn, heldOpen
    }

    /// Lenient like the other fork fields: a missing or odd member never fails
    /// the whole conversation list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .taskCount)) ?? 0)
        tasks = (try? c.decodeIfPresent([Brief].self, forKey: .tasks)) ?? []
        outOfTurn = (try? c.decodeIfPresent(Bool.self, forKey: .outOfTurn)) ?? false
        heldOpen = (try? c.decodeIfPresent(Bool.self, forKey: .heldOpen)) ?? false
    }

    /// Whether there is anything in the background at all.
    var isActive: Bool { taskCount > 0 || outOfTurn || heldOpen }

    /// One line per listed task, then "+N more" for the rest.
    var taskLines: [String] {
        var lines = tasks.map(\.line)
        let unlisted = taskCount - tasks.count
        if unlisted > 0, !tasks.isEmpty { lines.append("+\(unlisted) more") }
        return lines
    }
}

extension ConversationSummary {
    /// Whether the session has work in progress for the lists: an open turn
    /// (the review status codeg keeps `in_progress` while a turn runs) or
    /// anything in the background. What Activity's "Running" section, the
    /// running badges and the folder counts count.
    var isRunningForLists: Bool {
        status.isLive || (background?.isActive ?? false)
    }
}
