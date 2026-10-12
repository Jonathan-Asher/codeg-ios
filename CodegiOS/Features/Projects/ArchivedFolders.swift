import SwiftUI

/// The tappable heading over the archived folders, at the bottom of the
/// Folders and Chats lists: an archive badge, "Archived", how many folders it
/// holds and a disclosure chevron. Collapsed by default, like the desktop
/// sidebar's Archived section, so archived folders stay out of the way until
/// asked for.
struct ArchivedSectionHeader: View {
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(Theme.Motion.content) { expanded.toggle() }
        } label: {
            HStack(spacing: 11) {
                SectionBadgeIcon(systemImage: "archivebox", tint: Theme.textSecondary)
                Text("Archived")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                CountBadge(count: count)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 2)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(expanded ? Text("Hides the archived folders") : Text("Shows the archived folders"))
    }
}

/// The Archive / Unarchive items of a folder's context menu. Nothing on a
/// server that predates archiving. A folder in a desktop folder group can also
/// archive the whole group; one archived through its group offers the group's
/// unarchive instead of its own.
struct FolderArchiveMenuItems: View {
    let state: FolderArchive.State
    /// The desktop group the folder sits in, when it is in one.
    let group: FolderGroupDetail?
    let onSetArchived: (Bool) -> Void
    let onSetGroupArchived: (FolderGroupDetail, Bool) -> Void

    var body: some View {
        switch state {
        case .unsupported:
            EmptyView()
        case .active:
            Button {
                onSetArchived(true)
            } label: {
                Label("Archive Folder", systemImage: "archivebox")
            }
            if let group {
                Button {
                    onSetGroupArchived(group, true)
                } label: {
                    Label("Archive Group “\(group.name)”", systemImage: "archivebox")
                }
            }
        case .archived:
            Button {
                onSetArchived(false)
            } label: {
                Label("Unarchive Folder", systemImage: "arrow.up.bin")
            }
        case .group(let archivedGroup):
            Button {
                onSetGroupArchived(archivedGroup, false)
            } label: {
                Label("Unarchive Group “\(archivedGroup.name)”", systemImage: "arrow.up.bin")
            }
        }
    }
}
