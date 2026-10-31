import Foundation

/// How a new session's agent and folder are chosen from what the server
/// offers, or last offered (``DraftCatalog``). Pure, so the saved lists a
/// draft opens with and the fresh ones that replace them choose alike.
enum DraftChoices {
    /// The agents a new session can start with: installed and enabled, in
    /// the server's order, each once.
    static func usableAgents(_ agents: [AcpAgentInfo]) -> [AgentType] {
        var usable: [AgentType] = []
        for agent in agents.filter({ $0.available && $0.enabled }).sorted(by: { $0.sortOrder < $1.sortOrder })
        where !usable.contains(agent.agentType) {
            usable.append(agent.agentType)
        }
        return usable
    }

    /// The folders the picker offers: the open top-level folders (a new
    /// session doesn't start in a worktree directly), the most recently
    /// opened first.
    static func offeredFolders(_ open: [FolderDetail]) -> [FolderDetail] {
        FolderVisibility.filterTopLevel(open).sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// The folder to use. `kept` (one the user picked) stays while the server
    /// still has it, as it now is; otherwise the preselected folder, else the
    /// most recently opened one.
    static func folder(keeping kept: FolderDetail?, preselectedID: Int?,
                       offered: [FolderDetail], all: [FolderDetail]) -> FolderDetail? {
        if let kept, let current = find(kept.id, offered, all) { return current }
        if let preselectedID, let preselected = find(preselectedID, all, offered) { return preselected }
        return offered.first
    }

    /// The agent to use. `kept` stays while the server offers it (or while
    /// what it offers isn't known yet); otherwise the folder's default agent,
    /// else the first one offered.
    static func agent(keeping kept: AgentType?, folder: FolderDetail?, available: [AgentType]?) -> AgentType? {
        guard let available else { return kept ?? folder?.defaultAgentType }
        if let kept, available.contains(kept) { return kept }
        if let preferred = folder?.defaultAgentType, available.contains(preferred) { return preferred }
        return available.first
    }

    private static func find(_ id: Int, _ first: [FolderDetail], _ second: [FolderDetail]) -> FolderDetail? {
        first.first { $0.id == id } ?? second.first { $0.id == id }
    }
}

/// A new session's first message has no folder (or agent) to start in.
struct DraftSetupError: LocalizedError {
    var errorDescription: String? { "Pick a folder and agent first." }
}
