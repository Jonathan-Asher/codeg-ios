import Foundation

/// Archived folders, as the codeg desktop sidebar has them.
///
/// Archiving is presentational: an archived folder (or every folder in an
/// archived folder group) leaves the main folder lists for an "Archived" group
/// at the bottom, and its sessions leave Activity's "Last 24 Hours" and
/// "Earlier". Nothing about the sessions changes: a running one keeps running,
/// stays in "Running", and still notifies.
///
/// A server that predates archiving sends no `archived` field: then nothing is
/// archived and no Archive action is offered, so the app behaves as before.
/// Pure, so the view models share it and it is trivially testable.
enum FolderArchive {
    /// Why a folder is archived, which decides what its menu offers.
    enum State: Equatable {
        /// The server doesn't know about archiving: offer nothing.
        case unsupported
        /// Not archived: offer "Archive Folder".
        case active
        /// Archived on its own: offer "Unarchive Folder".
        case archived
        /// Archived through its desktop folder group: offer "Unarchive Group".
        case group(FolderGroupDetail)
    }

    /// Whether the server sent archive flags at all (any folder carries one).
    static func isSupported(_ folders: [FolderDetail]) -> Bool {
        folders.contains { $0.archived != nil }
    }

    /// The ids of the archived folders in `folders`: archived on their own,
    /// through an archived group, or — a worktree shown under its repo
    /// (`childToParent`) — through that repo, whose state it always follows.
    /// A group id that isn't in `groups` counts as no group.
    static func archivedIDs(
        folders: [FolderDetail],
        groups: [FolderGroupDetail],
        childToParent: [Int: Int]
    ) -> Set<Int> {
        let archivedGroups = Set(groups.filter { $0.archived == true }.map(\.id))
        var direct: [Int: Bool] = [:]
        for folder in folders {
            let viaGroup = folder.groupId.map { archivedGroups.contains($0) } ?? false
            direct[folder.id] = folder.archived == true || viaGroup
        }
        var out = Set<Int>()
        for folder in folders {
            let archived: Bool
            if let repo = childToParent[folder.id], let repoArchived = direct[repo] {
                archived = repoArchived
            } else {
                archived = direct[folder.id] ?? false
            }
            if archived { out.insert(folder.id) }
        }
        return out
    }

    /// What the folder's menu should offer. `supported` is
    /// ``isSupported(_:)`` over the folder list the row came from.
    static func state(of folder: FolderDetail, groups: [FolderGroupDetail], supported: Bool) -> State {
        guard supported else { return .unsupported }
        if folder.archived == true { return .archived }
        if let groupID = folder.groupId,
           let group = groups.first(where: { $0.id == groupID }),
           group.archived == true {
            return .group(group)
        }
        return .active
    }
}
