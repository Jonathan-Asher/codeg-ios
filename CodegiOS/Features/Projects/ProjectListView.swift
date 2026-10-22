import Combine
import SwiftUI

/// The Folders tab: every folder/workspace on the server as a first-class
/// destination — color, path, branch, default agent, and a live running count.
/// Data rides the shared `ActivityModel` snapshot (folders + conversations),
/// so this adds no new requests.
struct ProjectListView: View {
    let activity: ActivityModel
    let client: CodegClient?
    let onOpenProject: (Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var browseOpen = false
    @State private var cloneOpen = false
    @State private var actionError: String?
    /// The archived folders' group at the bottom; closed until asked for.
    @AppStorage("codeg.folders.archivedExpanded") private var archivedExpanded = false
    @State private var archiveError: String?

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .connectionCapsule()
        .screenTitle("Folders", compact: horizontalSizeClass == .compact)
        .toolbar {
            if client != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            browseOpen = true
                        } label: {
                            Label("Open Folder", systemImage: "folder.badge.plus")
                        }
                        Button {
                            cloneOpen = true
                        } label: {
                            Label("Clone Repository", systemImage: "arrow.triangle.branch")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add Folder")
                }
            }
        }
        .sheet(isPresented: $browseOpen) {
            if let client {
                DirectoryBrowserView(client: client) { path in
                    Task { await addFolder(path: path) }
                }
            }
        }
        .sheet(isPresented: $cloneOpen) {
            if let client {
                CloneRepoView(client: client) {
                    Task { await activity.refresh(client: client) }
                }
            }
        }
        .alert(
            "Couldn’t Open Folder",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert(
            "Couldn’t Change the Archive",
            isPresented: Binding(get: { archiveError != nil }, set: { if !$0 { archiveError = nil } })
        ) {
            Button("OK", role: .cancel) { archiveError = nil }
        } message: {
            Text(archiveError ?? "")
        }
        .task {
            if !activity.hasLoaded {
                await activity.refresh(client: client)
            }
        }
        // A worktree folder registered from the branch switcher (or other
        // out-of-band folder change) refreshes the list promptly.
        .onReceive(NotificationCenter.default.publisher(for: .foldersDidChange)) { _ in
            Task { await activity.refresh(client: client) }
        }
    }

    /// Add a folder by absolute server path, then refresh so it appears in the list.
    private func addFolder(path: String) async {
        guard let client else { return }
        do {
            _ = try await client.openFolder(path: path)
            await activity.refresh(client: client)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if client == nil {
            EmptyStateView(
                icon: "server.rack",
                title: "No Server Selected",
                message: "Pick a server in the Chats tab to browse its folders."
            )
        } else if !activity.hasLoaded, activity.isRefreshing {
            LoadingView(label: "Loading folders…")
        } else if let error = activity.error, !activity.hasLoaded {
            InlineErrorView(message: error) {
                Task { await activity.refresh(client: client) }
            }
        } else if sortedFolders.isEmpty && archivedFolders.isEmpty {
            EmptyStateView(
                icon: "folder",
                title: "No Folders",
                message: "Add a folder in the codeg desktop app, then start tasks in it from here."
            )
        } else {
            projectList
        }
    }

    /// One continuous grouped surface holding all folders as borderless rows split
    /// by inset hairlines — the iOS grouped-list look (matching Settings), instead
    /// of a stack of individually-bordered cards. Bounded by the folder count, so a
    /// plain `VStack` inside the card is fine (no virtualization needed here).
    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !sortedFolders.isEmpty {
                    folderCard(sortedFolders)
                }
                // Archived folders (on the desktop or here) sit in their own
                // group at the bottom, closed until asked for. They open and
                // work as usual from there.
                if !archivedFolders.isEmpty {
                    ArchivedSectionHeader(count: archivedFolders.count, expanded: $archivedExpanded)
                    if archivedExpanded {
                        folderCard(archivedFolders)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await activity.refresh(client: client) }
    }

    private func folderCard(_ folders: [FolderDetail]) -> some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        InsetDivider(leading: FolderRowMetrics.dividerInset)
                    }
                    ProjectRow(
                        folder: folder,
                        runningCount: activity.runningCount(folderID: folder.id),
                        onTap: { onOpenProject(folder.id) }
                    )
                    .contextMenu {
                        FolderArchiveMenuItems(
                            state: activity.archiveState(of: folder),
                            group: activity.group(of: folder),
                            onSetArchived: { archived in setArchived(folder, archived) },
                            onSetGroupArchived: { group, archived in setGroupArchived(group, archived) }
                        )
                    }
                }
            }
        }
    }

    private func setArchived(_ folder: FolderDetail, _ archived: Bool) {
        Task {
            do {
                try await activity.setArchived(folderID: folder.id, archived: archived, client: client)
            } catch {
                archiveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func setGroupArchived(_ group: FolderGroupDetail, _ archived: Bool) {
        Task {
            do {
                try await activity.setGroupArchived(groupID: group.id, archived: archived, client: client)
            } catch {
                archiveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Server `sortOrder` first, then name. Reads `displayFolders` (open + regular,
    /// worktree children hidden) — not the full `folders` set used for by-id
    /// lookups — so worktree/chat folders never get their own row. Archived
    /// folders are left out; they are listed in ``archivedFolders``.
    private var sortedFolders: [FolderDetail] {
        let archived = activity.archivedFolderIDs
        return Self.sorted(activity.displayFolders.filter { !archived.contains($0.id) })
    }

    /// The archived folders, in the same order, for the group at the bottom.
    /// Empty on a server that predates archiving.
    private var archivedFolders: [FolderDetail] {
        let archived = activity.archivedFolderIDs
        guard !archived.isEmpty else { return [] }
        return Self.sorted(activity.displayFolders.filter { archived.contains($0.id) })
    }

    private static func sorted(_ folders: [FolderDetail]) -> [FolderDetail] {
        folders.sorted {
            $0.sortOrder != $1.sortOrder
                ? $0.sortOrder < $1.sortOrder
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Row

/// Shared metrics for the grouped folder rows so the inset divider lines up under
/// the folder name (past the leading color tile), iOS grouped-list style.
private enum FolderRowMetrics {
    static let tileSize: CGFloat = 40
    static let iconGap: CGFloat = 12
    /// Leading inset for the inter-row divider: aligns with the name text.
    static var dividerInset: CGFloat { SettingsRowMetrics.hInset + tileSize + iconGap }
}

/// One folder: a colored workspace tile + name, the full path and branch
/// underneath, then a row-trailing status — a live running count when tasks are
/// active, otherwise the relative last-opened time — and a chevron marking the
/// drill-in. Borderless: the enclosing grouped card draws the surface. (No agent
/// icon — the default agent belongs in the folder's detail, not its list row.)
private struct ProjectRow: View {
    let folder: FolderDetail
    let runningCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            GroupedRow(vInset: 12) {
                HStack(spacing: FolderRowMetrics.iconGap) {
                    FolderBadge(color: folderColor, size: FolderRowMetrics.tileSize)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            // Full path (not just the tail, which often repeats
                            // the name); head-truncates to keep the leaf visible.
                            Text(folder.path)
                                .font(.mono(11))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if let branch = folder.gitBranch, !branch.isEmpty {
                                BranchPill(branch: branch)
                                    // Priority over the path so a short branch
                                    // always shows in full, truncating only when
                                    // genuinely long.
                                    .layoutPriority(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    trailingStatus

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if runningCount > 0 {
            HStack(spacing: 4) {
                LivePulse()
                Text("\(runningCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accentDim, in: Capsule())
            .fixedSize()
        } else {
            Text(RelativeTime.compact(from: folder.lastOpenedAt))
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }

    private var folderColor: Color {
        Color(hexString: folder.color) ?? Theme.accent
    }
}

/// The git branch as a subtle monospaced pill.
private struct BranchPill: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
            Text(branch)
                .font(.mono(10))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
