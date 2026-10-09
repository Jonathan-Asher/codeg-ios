import SwiftUI

/// An App Store editorial-style card wrapping one session group (Pinned / a
/// folder / Other). It shows the group header plus a capped preview of its
/// rows, separated by inset dividers. Each preview row opens its own session;
/// the header and the "Show all" footer zoom-expand the card to a fullscreen
/// list (``SessionSectionFullScreen``) via the host's `.fullScreenCover` +
/// `.navigationTransition(.zoom)`.
struct SessionSectionCard: View {
    let title: String
    var tint: Color = Theme.accent
    let conversations: [ConversationSummary]
    /// Per-row folder tag (return `nil` to omit) — shown on cross-folder groups
    /// like Pinned / Other, hidden inside a single folder's card.
    var folderName: (ConversationSummary) -> String? = { _ in nil }
    /// How many rows to preview before the "Show all" affordance.
    var previewLimit: Int = 5
    /// The session that is open (iPad) or was opened last (iPhone); its row is
    /// marked.
    var markedID: Int? = nil
    /// Opens a session from its preview row. Without it the rows are
    /// display-only.
    var onOpen: ((Int) -> Void)? = nil
    var onTogglePin: ((ConversationSummary) -> Void)? = nil
    /// Header / "Show all" tap → host presents the fullscreen list.
    let onExpand: () -> Void

    private var hasMore: Bool { conversations.count > previewLimit }

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.lg, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onExpand) {
                    header
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
                .accessibilityLabel("\(title), \(conversations.count) sessions")
                .accessibilityHint("Opens the full list")

                ForEach(Array(conversations.prefix(previewLimit).enumerated()), id: \.element.id) { index, conv in
                    if index > 0 {
                        // Starts under the row titles (6 card inset + 10 row
                        // inset + 34 avatar + 12 gap).
                        InsetDivider(leading: 62)
                            .padding(.trailing, 16)
                    }
                    SessionRow(
                        conversation: conv,
                        isSelected: conv.id == markedID,
                        folderName: folderName(conv),
                        onTap: onOpen.map { open in { open(conv.id) } },
                        onTogglePin: onTogglePin.map { toggle in { toggle(conv) } },
                        style: .inset
                    )
                    .padding(.horizontal, 6)
                }

                if hasMore {
                    Button(action: onExpand) {
                        showAllFooter
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableRowStyle())
                }
            }
            .padding(.bottom, hasMore ? 2 : 8)
        }
    }

    /// "N sessions total" eyebrow shown above the title — mirrors the fullscreen
    /// drill-in (``SessionSectionFullScreen``) so a card reads as a preview of the
    /// very screen it zoom-expands into.
    private var totalLabel: LocalizedStringKey {
        let n = conversations.count
        return n == 1 ? "1 session total" : "\(n) sessions total"
    }

    /// A bigger, left-aligned title with a small tinted count eyebrow above it and
    /// no leading icon — the editorial-card look, matching the fullscreen header.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(totalLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .tracking(0.8)
                    .textCase(.uppercase)
                Text(LocalizedStringKey(stringLiteral: title))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // Expands the card to the full list.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
    }

    private var showAllFooter: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Show all \(conversations.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

/// The fullscreen drill-in a ``SessionSectionCard`` zoom-expands into. It's a real
/// `NavigationStack` so the close affordance is a **native toolbar button** — a
/// custom button floating over a `.navigationTransition(.zoom)` cover does NOT
/// reliably receive taps (the cover's interactive-dismiss layer eats them), which
/// is why an earlier hand-rolled floating "X" did nothing. The nav bar background
/// is hidden so that native close button floats over a clean top (App Store
/// editorial style) above a big left-aligned title with a small "N sessions total"
/// eyebrow. The row list is a `List` (UICollectionView cell recycling) so a
/// many-hundred-row group scrolls without the lazy-stack stutter. Each row is its own
/// card; a tap reports the id via `onOpen` (the host opens the conversation
/// first — pushing the detail onto the nav stack behind the cover — *then* clears the
/// cover binding, so the cover's dismissal reveals the already-pushed detail in one
/// motion instead of flashing this list); the close button reports via `onClose`.
struct SessionSectionFullScreen: View {
    let title: String
    var tint: Color = Theme.accent
    /// Passed fresh by the host each render (never a frozen snapshot), so a
    /// background refresh while this is open keeps the list current.
    let conversations: [ConversationSummary]
    var folderName: (ConversationSummary) -> String? = { _ in nil }
    /// The session that is open (iPad) or was opened last (iPhone).
    var markedID: Int? = nil
    let onOpen: (Int) -> Void
    var onTogglePin: ((ConversationSummary) -> Void)?
    /// Dismisses the fullscreen when it is presented as a cover: it then has
    /// its own navigation stack and a close button. `nil` when it is pushed
    /// onto the app's stack (`SessionGroupView`), which gives it Back.
    var onClose: (() -> Void)? = nil

    /// "N sessions total" eyebrow shown above the big title.
    private var totalLabel: LocalizedStringKey {
        let n = conversations.count
        return n == 1 ? "1 session total" : "\(n) sessions total"
    }

    var body: some View {
        if let onClose {
            NavigationStack {
                list
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            .accessibilityLabel("Close")
                        }
                    }
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            header
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(conversations) { conv in
                SessionRow(
                    conversation: conv,
                    isSelected: conv.id == markedID,
                    folderName: folderName(conv),
                    onTap: { onOpen(conv.id) },
                    onTogglePin: onTogglePin.map { toggle in { toggle(conv) } }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .background(CodegBackground().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // Hidden bar background → the close button floats over a clean top
        // (App Store look) instead of sitting on a visible band above the title.
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// Big left-aligned group title with a small total-count eyebrow above it —
    /// no leading icon, no trailing number (the editorial-card look).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(totalLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .tracking(0.8)
                .textCase(.uppercase)
            Text(LocalizedStringKey(stringLiteral: title))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        // Keep a long title clear of the floating close button.
        .padding(.trailing, 44)
    }
}

/// One group of the Chats list in full, pushed from its card onto the tab's
/// (or the iPad content column's) stack. Pushed rather than presented as a
/// cover, so Back from a session opened here returns here, and Back again to
/// the Chats list. Reads the rows live from the list's model, so a refresh
/// while it is open keeps it current.
struct SessionGroupView: View {
    let group: SessionGroup
    let viewModel: SessionListViewModel
    var markedID: Int?
    let onOpen: (Int) -> Void

    var body: some View {
        let content = SessionGroupContent(group: group, viewModel: viewModel)
        SessionSectionFullScreen(
            title: content.title,
            tint: content.tint,
            conversations: content.conversations,
            folderName: { content.showFolder ? viewModel.folderNames[$0.folderId] : nil },
            markedID: markedID,
            onOpen: onOpen,
            onTogglePin: { conv in
                Task { await viewModel.setPinned(conv, pinned: !conv.isPinned) }
            }
        )
    }
}

/// What a Chats group shows: its title, tint and rows.
struct SessionGroupContent {
    let title: String
    let tint: Color
    let conversations: [ConversationSummary]
    /// Rows from several folders name their folder.
    let showFolder: Bool

    @MainActor
    init(group: SessionGroup, viewModel: SessionListViewModel) {
        switch group {
        case .pinned:
            title = "Pinned"
            tint = Theme.accent
            conversations = viewModel.pinned(searchText: "")
            showFolder = true
        case .folder(let id):
            let folderGroup = viewModel.folderGroups(searchText: "").first { $0.folder.id == id }
            title = folderGroup?.folder.name ?? "Folder"
            tint = folderGroup.flatMap { Color(hexString: $0.folder.color) } ?? Theme.accent
            conversations = folderGroup?.conversations ?? []
            showFolder = false
        case .other:
            title = "Other"
            tint = Theme.textSecondary
            conversations = viewModel.ungrouped(searchText: "")
            showFolder = true
        }
    }
}
