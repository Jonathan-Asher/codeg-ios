import Foundation

/// What a new session's pickers offer on one server, as it last gave them: the
/// agents it runs, its folders, and each agent's modes and options. A new
/// session (a draft) opens with all of it at once, so every choice is there
/// before the server answers (``DraftCatalogStore``).
struct DraftCatalog: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = DraftCatalog.currentVersion
    /// The agents a new session can start with (installed and enabled), in
    /// the server's order. Nil until a draft loaded them.
    var agents: [AgentType]?
    /// The open folders (`list_open_folder_details`). Nil until a draft
    /// loaded them.
    var openFolders: [FolderDetail]?
    /// Every folder but chat scratch folders (`list_all_folder_details`): a
    /// preselected worktree, and the roots the branch switcher looks up.
    var allFolders: [FolderDetail]?
    /// Each agent's mode and option lists as last seen on this server (a
    /// session's own, or read from an agent started for them), by
    /// `AgentType.wireValue`.
    var agentOptions: [String: AgentOptionsSnapshot] = [:]
}

/// The draft catalogs: one file per server, `draft-catalog.json` in the
/// server's folder of ``TranscriptCache`` (removing a server, or changing its
/// URL or token, removes it with the transcripts; transcript eviction leaves
/// it alone). Written with complete file protection like everything saved
/// there: folder names can name clients. Each server's file is read once,
/// then kept in memory; a change is written in the background.
@MainActor
final class DraftCatalogStore {
    static let shared = DraftCatalogStore()
    nonisolated static let fileName = "draft-catalog.json"

    private let root: URL
    private let files: any SavedFileStore
    /// The catalogs read so far, by server key.
    private var catalogs: [String: DraftCatalog] = [:]
    private let writer = DispatchQueue(label: "codeg.draft-catalog", qos: .utility)

    init(root: URL? = nil, files: any SavedFileStore = ProtectedFiles()) {
        self.root = root ?? TranscriptCache.defaultRoot
        self.files = files
    }

    func file(serverKey: String) -> URL {
        root.appendingPathComponent(serverKey, isDirectory: true).appendingPathComponent(Self.fileName)
    }

    /// The server's catalog: what was saved, or an empty one.
    func catalog(serverKey: String) -> DraftCatalog {
        if let known = catalogs[serverKey] { return known }
        switch read(serverKey: serverKey) {
        case .found(let catalog):
            catalogs[serverKey] = catalog
            return catalog
        case .missing:
            catalogs[serverKey] = DraftCatalog()
            return DraftCatalog()
        case .unreadable:
            // Protected while the phone is locked: not remembered, so the
            // next read gets what is on disk, and nothing overwrites it.
            return DraftCatalog()
        }
    }

    /// Change the server's catalog. Written in the background when it changed;
    /// not while the saved one can't be read, which it would overwrite.
    func update(serverKey: String, _ change: (inout DraftCatalog) -> Void) {
        _ = catalog(serverKey: serverKey)
        guard var catalog = catalogs[serverKey] else { return }
        let before = catalog
        change(&catalog)
        guard catalog != before else { return }
        catalogs[serverKey] = catalog
        guard let data = try? TranscriptCache.encoder.encode(catalog) else { return }
        let url = file(serverKey: serverKey)
        let files = self.files
        writer.async { try? files.write(data, to: url) }
    }

    /// Returns once every change made so far is on disk (tests).
    func flush() {
        writer.sync {}
    }

    private enum Read {
        case found(DraftCatalog)
        case missing
        case unreadable
    }

    private func read(serverKey: String) -> Read {
        let url = file(serverKey: serverKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        // Unreadable JSON or another format version starts over: the next
        // change replaces the file.
        guard let catalog = try? TranscriptCache.decoder.decode(DraftCatalog.self, from: data),
              catalog.version == DraftCatalog.currentVersion
        else { return .missing }
        return .found(catalog)
    }
}

/// One server's option lists in a ``DraftCatalogStore``, as the options sheet
/// reads and keeps them.
@MainActor
struct SavedAgentOptions {
    let store: DraftCatalogStore
    let serverKey: String

    func options(for agent: AgentType) -> AgentOptionsSnapshot? {
        store.catalog(serverKey: serverKey).agentOptions[agent.wireValue]
    }

    func save(_ options: AgentOptionsSnapshot, for agent: AgentType) {
        store.update(serverKey: serverKey) { $0.agentOptions[agent.wireValue] = options }
    }
}
