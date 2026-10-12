import XCTest
@testable import Codeg

/// Archived folders (codeg's sidebar "Archive"): the flag decodes when the
/// server sends it and is absent otherwise, archived folders' sessions leave
/// Activity's "Last 24 Hours" and "Earlier", and the folder lists move them to
/// an "Archived" group. A server that predates archiving changes nothing.
@MainActor
final class FolderArchiveTests: XCTestCase {
    // MARK: - Fixtures

    private func folderJSON(_ id: Int, name: String? = nil, extra: String = "") -> String {
        """
        {"id": \(id), "name": "\(name ?? "f\(id)")", "path": "/p/\(id)", "git_branch": null,
         "default_agent_type": null, "last_opened_at": "2026-09-01T08:00:00Z", "sort_order": \(id),
         "color": "inherit", "parent_id": null, "kind": "regular"\(extra)}
        """
    }

    private func groupJSON(_ id: Int, archived: Bool?) -> String {
        let flag = archived.map { ", \"archived\": \($0)" } ?? ""
        return #"{"id": \#(id), "name": "Group \#(id)", "color": "inherit", "sort_order": 1\#(flag)}"#
    }

    private func summary(_ id: Int, folder: Int, hoursAgo: Double, status: String = "pending_review") -> String {
        let updated = TranscriptTime.string(date: Date().addingTimeInterval(-hoursAgo * 3600))
        return """
        {"id": \(id), "folder_id": \(folder), "title": "Session \(id)", "agent_type": "claude_code",
         "status": "\(status)", "message_count": 4, "created_at": "2026-09-01T08:00:00Z",
         "updated_at": "\(updated)", "turn_state": null}
        """
    }

    private func decodeFolder(_ json: String) throws -> FolderDetail {
        try CodegJSON.decoder.decode(FolderDetail.self, from: Data(json.utf8))
    }

    /// Folder 1 live, folder 2 archived on its own, folder 3 in archived group
    /// 7, folder 4 in live group 8 — each with one recent, one older session;
    /// folder 2 also has a running one.
    private func newServer() -> MockCodegServer {
        let server = MockCodegServer()
        let folders = "[" + [
            folderJSON(1, extra: #", "group_id": null, "archived": false"#),
            folderJSON(2, extra: #", "group_id": null, "archived": true"#),
            folderJSON(3, extra: #", "group_id": 7, "archived": false"#),
            folderJSON(4, extra: #", "group_id": 8, "archived": false"#),
        ].joined(separator: ",") + "]"
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("list_open_folder_details") { _ in .body(folders) }
        let groups = "[" + groupJSON(7, archived: true) + "," + groupJSON(8, archived: false) + "]"
        server.on("list_folder_groups") { _ in .body(groups) }
        server.on("list_conversation_attention") { _ in .body("[]") }
        let sessions = [
            summary(11, folder: 1, hoursAgo: 1), summary(12, folder: 1, hoursAgo: 40),
            summary(21, folder: 2, hoursAgo: 1), summary(22, folder: 2, hoursAgo: 40),
            summary(23, folder: 2, hoursAgo: 0.1, status: "in_progress"),
            summary(31, folder: 3, hoursAgo: 2), summary(32, folder: 3, hoursAgo: 50),
            summary(41, folder: 4, hoursAgo: 3), summary(42, folder: 4, hoursAgo: 60),
        ]
        server.on("list_all_conversations") { _ in .body("[" + sessions.joined(separator: ",") + "]") }
        return server
    }

    // MARK: - Decoding

    func testFolderDecodesTheFlagAndItsGroup() throws {
        let folder = try decodeFolder(folderJSON(5, extra: #", "group_id": 7, "archived": true"#))
        XCTAssertEqual(folder.archived, true)
        XCTAssertEqual(folder.groupId, 7)
    }

    func testFolderFromAnOlderServerHasNoFlag() throws {
        let folder = try decodeFolder(folderJSON(5))
        XCTAssertNil(folder.archived, "absent means the server predates archiving")
        XCTAssertNil(folder.groupId)
        XCTAssertFalse(FolderArchive.isSupported([folder]))
        XCTAssertEqual(FolderArchive.state(of: folder, groups: [], supported: false), .unsupported)
    }

    func testGroupDecodesWithAndWithoutTheFlag() throws {
        let archived = try CodegJSON.decoder.decode(FolderGroupDetail.self, from: Data(groupJSON(7, archived: true).utf8))
        XCTAssertEqual(archived.archived, true)
        XCTAssertEqual(archived.sortOrder, 1)
        let old = try CodegJSON.decoder.decode(FolderGroupDetail.self, from: Data(groupJSON(8, archived: nil).utf8))
        XCTAssertNil(old.archived)
    }

    // MARK: - Rules

    func testArchivedIDsFollowGroupsAndRepos() throws {
        let folders = [
            try decodeFolder(folderJSON(1, extra: #", "archived": true"#)),
            try decodeFolder(folderJSON(2, extra: #", "group_id": 7, "archived": false"#)),
            try decodeFolder(folderJSON(3, extra: #", "group_id": 99, "archived": false"#)),
            try decodeFolder(folderJSON(10, extra: #", "archived": false"#)),
            try decodeFolder(folderJSON(4, extra: #", "archived": false"#)),
        ]
        let groups = [FolderGroupDetail(id: 7, name: "Old", archived: true)]
        // Folder 10 is a worktree shown under folder 1, so it follows it.
        let ids = FolderArchive.archivedIDs(folders: folders, groups: groups, childToParent: [10: 1])
        XCTAssertEqual(ids, [1, 2, 10], "own flag, through the group, through the repo; an unknown group is no group")
    }

    func testTheMenuOffersWhatTheFolderCanDo() throws {
        let group = FolderGroupDetail(id: 7, name: "Old", archived: true)
        let live = try decodeFolder(folderJSON(1, extra: #", "archived": false"#))
        let own = try decodeFolder(folderJSON(2, extra: #", "archived": true"#))
        let viaGroup = try decodeFolder(folderJSON(3, extra: #", "group_id": 7, "archived": false"#))
        XCTAssertEqual(FolderArchive.state(of: live, groups: [group], supported: true), .active)
        XCTAssertEqual(FolderArchive.state(of: own, groups: [group], supported: true), .archived)
        XCTAssertEqual(FolderArchive.state(of: viaGroup, groups: [group], supported: true), .group(group))
    }

    // MARK: - Activity

    func testActivityLeavesArchivedFoldersOutOfRecentAndEarlier() async throws {
        let server = newServer()
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        XCTAssertTrue(activity.archiveSupported)
        XCTAssertEqual(activity.archivedFolderIDs, [2, 3])
        XCTAssertEqual(Set(activity.recent.map(\.id)), [11, 41], "no sessions of folder 2 or of group 7's folder 3")
        XCTAssertEqual(Set(activity.earlier.map(\.id)), [12, 42])
        XCTAssertEqual(activity.running.map(\.id), [23], "a running session keeps running, and shows")
    }

    func testActivityAgainstAnOlderServerIsUnchanged() async throws {
        let server = MockCodegServer()
        let folders = "[" + folderJSON(1) + "," + folderJSON(2) + "]"
        server.on("list_all_folder_details") { _ in .body(folders) }
        server.on("list_open_folder_details") { _ in .body(folders) }
        // No such endpoint before folder groups.
        server.on("list_folder_groups") { _ in .status(404, #"{"error":"not found"}"#) }
        server.on("list_conversation_attention") { _ in .body("[]") }
        let sessions = [summary(11, folder: 1, hoursAgo: 1), summary(21, folder: 2, hoursAgo: 40)]
        server.on("list_all_conversations") { _ in .body("[" + sessions.joined(separator: ",") + "]") }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        XCTAssertFalse(activity.archiveSupported)
        XCTAssertTrue(activity.archivedFolderIDs.isEmpty)
        XCTAssertEqual(activity.recent.map(\.id), [11])
        XCTAssertEqual(activity.earlier.map(\.id), [21])
        XCTAssertEqual(activity.archiveState(of: activity.displayFolders[0]), .unsupported)
    }

    func testArchivingFromThePhoneMovesTheFolderAtOnceAndTellsTheServer() async throws {
        let server = newServer()
        let updated = folderJSON(1, extra: #", "archived": true"#)
        server.on("set_folder_archived") { _ in .body(updated) }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        try await activity.setArchived(folderID: 1, archived: true, client: server.client)
        XCTAssertTrue(activity.archivedFolderIDs.contains(1))
        XCTAssertFalse(activity.recent.contains { $0.folderId == 1 })
        let call = try XCTUnwrap(server.calls("set_folder_archived").first)
        XCTAssertEqual(call.body["folderId"] as? Int, 1)
        XCTAssertEqual(call.body["archived"] as? Bool, true)
    }

    func testARefusedArchiveIsPutBack() async throws {
        let server = newServer()
        server.on("set_folder_archived") { _ in .status(500, #"{"error":"nope"}"#) }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        do {
            try await activity.setArchived(folderID: 1, archived: true, client: server.client)
            XCTFail("the error reaches the view")
        } catch {}
        XCTAssertFalse(activity.archivedFolderIDs.contains(1))
    }

    func testUnarchivingAGroupBringsItsFoldersBack() async throws {
        let server = newServer()
        let updated = groupJSON(7, archived: false)
        server.on("set_folder_group_archived") { _ in .body(updated) }
        let activity = ActivityModel()
        await activity.refresh(client: server.client)

        try await activity.setGroupArchived(groupID: 7, archived: false, client: server.client)
        XCTAssertEqual(activity.archivedFolderIDs, [2])
        XCTAssertTrue(activity.recent.contains { $0.id == 31 })
        XCTAssertEqual(server.calls("set_folder_group_archived").first?.body["groupId"] as? Int, 7)
    }

    // MARK: - Chats

    func testChatsMoveArchivedFoldersToTheirOwnGroup() async throws {
        let server = newServer()
        let model = SessionListViewModel(client: server.client)
        await model.load()

        XCTAssertEqual(model.folderGroups(searchText: "").map(\.folder.id), [1, 4])
        XCTAssertEqual(model.folderGroups(searchText: "", archived: true).map(\.folder.id), [2, 3])
        XCTAssertTrue(model.ungrouped(searchText: "").isEmpty, "archived sessions don't fall into Other")
    }
}
