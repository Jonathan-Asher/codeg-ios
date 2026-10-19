import SwiftUI
import Observation

/// Where a fork was asked for, which decides where Back goes afterwards.
enum ForkOrigin: Equatable, Sendable {
    /// A session row in a list (Activity, Chats, a folder, Search): the fork
    /// opens on top of the list.
    case list
    /// The open session itself (its ⋯ menu or a reply): the fork opens with
    /// the original under it, so Back returns to the original.
    case session(Int)
}

/// The app-wide session actions a row's long-press menu and the session
/// screen share: forking (with its progress, errors and where the fork
/// opens), and the list rows' Pin, Copy Title and Archive Folder. Owned by
/// ``AppModel`` and handed to the views through the environment.
@MainActor
@Observable
final class SessionActions {
    @ObservationIgnored weak var app: AppModel?
    let capabilities: ForkCapabilities

    /// Conversations a fork is being taken from.
    private(set) var forking: Set<Int> = []
    /// A list row's action that failed, for the alert.
    var alert: SessionActionAlert?

    init(capabilities: ForkCapabilities = .shared) {
        self.capabilities = capabilities
    }

    func isForking(_ conversationID: Int) -> Bool { forking.contains(conversationID) }

    // MARK: - Availability

    /// "Fork Session" on a list row: greyed out, with the reason, when the
    /// server is too old, the agent said it can't fork, or a turn runs and the
    /// agent only forks between turns.
    func forkAvailability(for summary: ConversationSummary) -> ForkAvailability {
        guard let client = app?.selectedClient() else { return .hidden }
        return SessionForkRules.listAvailability(
            endpoints: capabilities.endpoints(for: client),
            agent: summary.agentType,
            agentForks: capabilities.agentForks(summary.agentType, client: client),
            turnRunning: SessionForkRules.turnRunning(summary),
            forking: forking.contains(summary.id)
        )
    }

    // MARK: - Forking

    /// Fork a session from its list row: the whole session between turns, the
    /// latest finished reply while a turn runs. The fork opens on top of the
    /// list.
    func fork(_ summary: ConversationSummary) {
        guard let app, let client = app.selectedClient() else { return }
        let folder = app.activity.folders.first { $0.id == summary.folderId }
        let target = ForkTarget(summary: summary, workingDir: folder?.path)
        start(target, at: .latest, origin: .list, client: client, onError: { [weak self] message in
            self?.alert = SessionActionAlert(title: String(localized: "Couldn’t Fork the Session"), message: message)
        })
    }

    /// Fork `target` at `point` and open the fork. `onError` says why it
    /// didn't happen; the session screen shows it in its notice line.
    func start(
        _ target: ForkTarget,
        at point: ForkPoint,
        origin: ForkOrigin,
        client: CodegClient,
        resolveConnection: (() async throws -> String)? = nil,
        onConnection: ((String) -> Void)? = nil,
        onError: @escaping (String) -> Void
    ) {
        guard !forking.contains(target.conversationID) else { return }
        forking.insert(target.conversationID)
        Task {
            defer { forking.remove(target.conversationID) }
            var connection: String?
            do {
                let outcome = try await SessionForker(client: client, capabilities: capabilities).fork(
                    target, at: point, resolveConnection: resolveConnection,
                    onConnection: { conn in
                        connection = conn
                        onConnection?(conn)
                    }
                )
                await finish(outcome, origin: origin, client: client, connection: connection)
            } catch is CancellationError {
                // Nothing to say.
            } catch {
                onError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// The fork happened: bring the lists up to date, make sure no screen
    /// shows the original's history under the fork's id, and open the fork.
    private func finish(_ outcome: ForkOutcome, origin: ForkOrigin, client: CodegClient,
                        connection: String?) async {
        guard let app else { return }
        if outcome.isInPlace, let server = app.selectedServer {
            await app.sessions.reloadAfterInPlaceFork(
                server: server, client: client,
                conversationID: outcome.forkConversationID, connectionID: connection
            )
        }
        await app.activity.refresh(client: client)
        NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
        app.openFork(outcome, from: origin)
    }

    // MARK: - Row extras

    /// Pin or unpin from a row whose list has no pin action of its own.
    func togglePin(_ summary: ConversationSummary) {
        guard let app, let client = app.selectedClient() else { return }
        Task {
            do {
                try await client.setPinned(conversationId: summary.id, pinned: !summary.isPinned)
                NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
                await app.activity.refresh(client: client)
            } catch {
                alert = SessionActionAlert(title: String(localized: "Couldn’t Change the Pin"),
                                           message: Self.describe(error))
            }
        }
    }

    /// Mark or unmark a session critical from its row. Shown at once on the
    /// row, put back with an alert if the server refuses it.
    func toggleCritical(_ summary: ConversationSummary) {
        guard let app, let client = app.selectedClient(),
              let action = CriticalSessionRules.action(for: summary) else { return }
        app.activity.setCriticalLocally(summary.id, action.marks)
        Task {
            do {
                try await client.setCritical(conversationId: summary.id, critical: action.marks)
                NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
                await app.activity.refresh(client: client)
            } catch {
                app.activity.setCriticalLocally(summary.id, summary.critical)
                alert = SessionActionAlert(title: String(localized: "Couldn’t Change the Critical Mark"),
                                           message: CriticalSessionRules.failure(Self.describe(error)))
            }
        }
    }

    /// The folder a session row's Archive items act on: the folder the Folders
    /// tab shows it under (a worktree's repo).
    func archiveFolder(for summary: ConversationSummary) -> FolderDetail? {
        guard let activity = app?.activity else { return nil }
        let id = FolderVisibility.mergedFolderId(summary.folderId, childToParent: activity.childToParent)
        return activity.displayFolders.first { $0.id == id }
            ?? activity.folders.first { $0.id == summary.folderId }
    }

    func archiveState(of folder: FolderDetail) -> FolderArchive.State {
        app?.activity.archiveState(of: folder) ?? .unsupported
    }

    func group(of folder: FolderDetail) -> FolderGroupDetail? {
        app?.activity.group(of: folder)
    }

    func setArchived(_ folder: FolderDetail, _ archived: Bool) {
        guard let app else { return }
        let client = app.selectedClient()
        Task {
            do {
                try await app.activity.setArchived(folderID: folder.id, archived: archived, client: client)
            } catch {
                alert = SessionActionAlert(title: String(localized: "Couldn’t Change the Archive"),
                                           message: Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func setGroupArchived(_ group: FolderGroupDetail, _ archived: Bool) {
        guard let app else { return }
        let client = app.selectedClient()
        Task {
            do {
                try await app.activity.setGroupArchived(groupID: group.id, archived: archived, client: client)
            } catch {
                alert = SessionActionAlert(title: String(localized: "Couldn’t Change the Archive"),
                                           message: Self.describe(error))
            }
        }
    }
}

/// A failed row action, as the alert shows it.
struct SessionActionAlert: Equatable {
    let title: String
    let message: String
}

/// "Fork Session" in a menu: a new session with this one's history that
/// continues on its own. Greyed out, with the reason under it, when the fork
/// can't be taken now.
struct ForkSessionMenuItem: View {
    let availability: ForkAvailability
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Fork Session")
                if let reason = availability.reason { Text(verbatim: reason) }
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
        }
        .disabled(!availability.isEnabled)
    }
}
