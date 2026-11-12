import SwiftUI

/// Presents "Move to Project…" for the row or session screen that asked
/// (``SessionActions/moveRequest``), and the banner once a session moved.
/// On the app's root, inside the environment it hands the sheet, so neither
/// the session screen's modifier chain nor a row has to host it.
struct SessionMoveSheetHost: ViewModifier {
    let actions: SessionActions
    let activity: ActivityModel

    private var request: Binding<SessionMoveRequest?> {
        Binding(get: { actions.moveRequest }, set: { actions.moveRequest = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: request) { request in
                SessionMoveSheet(request: request, activity: activity) { result, folder in
                    actions.didMove(result, to: folder, request: request)
                }
            }
            .overlay(alignment: .top) {
                SessionMoveNoticeOverlay(notice: actions.moveNotice)
            }
    }
}

/// The project picker: the session, a search field, the server's open
/// projects (its own left out, archived ones last) and, once one is picked,
/// what moving the session there does (the server's dry run) with Move.
struct SessionMoveSheet: View {
    let request: SessionMoveRequest
    let activity: ActivityModel

    @State private var model: SessionMoveModel
    @Environment(\.dismiss) private var dismiss

    init(request: SessionMoveRequest, activity: ActivityModel,
         onMoved: @escaping (SessionMoveResult, FolderDetail) -> Void) {
        self.request = request
        self.activity = activity
        let model = SessionMoveModel(conversation: request.conversation, client: request.client)
        model.onMoved = onMoved
        _model = State(initialValue: model)
    }

    private var choices: (active: [FolderDetail], archived: [FolderDetail]) {
        SessionMoveRules.choices(activity.displayFolders, currentFolderID: request.conversation.folderId,
                                 archivedIDs: activity.archivedFolderIDs, query: model.query)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle("Move to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                        .disabled(model.isMoving)
                }
            }
            .safeAreaInset(edge: .bottom) { moveBar }
            .task {
                if !activity.hasLoaded { await activity.refresh(client: request.client) }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isMoving)
        .onChange(of: model.preview) { _, preview in announce(preview) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.preview == .serverTooOld {
            EmptyStateView(
                icon: "arrow.up.circle",
                title: "Needs a Newer Server",
                message: "Moving sessions needs a newer codeg server."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionCard
                    searchField
                    projectSections
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private var projectSections: some View {
        let choices = self.choices
        if choices.active.isEmpty && choices.archived.isEmpty {
            if !activity.hasLoaded {
                loadingRow
            } else {
                emptyRow
            }
        } else {
            if !choices.active.isEmpty {
                section("Projects", choices.active)
            }
            if !choices.archived.isEmpty {
                section("Archived", choices.archived)
            }
        }
    }

    /// The session being moved, and the project it is in now.
    private var sessionCard: some View {
        HStack(spacing: 12) {
            AgentAvatar(agent: request.conversation.agentType, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                if let title = request.conversation.trimmedTitle {
                    Text(verbatim: title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .blockDirection(TextDirection.detect(title))
                } else {
                    Text("Untitled session")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let current = currentProjectName {
                    Text("Currently in \(current)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var currentProjectName: String? {
        activity.folders.first { $0.id == request.conversation.folderId }?.name
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            TextField("Search projects", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private func section(_ title: LocalizedStringKey, _ folders: [FolderDetail]) -> some View {
        EditorSection(title: title, flat: true) {
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                if index > 0 { InsetDivider(leading: Self.dividerInset) }
                row(folder)
            }
        }
    }

    private static let badgeSize: CGFloat = 32
    private static let dividerInset: CGFloat = 14 + badgeSize + 12

    private func row(_ folder: FolderDetail) -> some View {
        let isPicked = model.picked?.id == folder.id
        return Button { model.pick(folder) } label: {
            HStack(spacing: 12) {
                FolderBadge(color: Color(hexString: folder.color) ?? Theme.accent, size: Self.badgeSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: folder.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: folder.path)
                        .font(.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isPicked {
                    rowMark
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .disabled(model.isMoving)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    /// The picked row's mark: a spinner while its dry run is on its way.
    @ViewBuilder
    private var rowMark: some View {
        if case .checking = model.preview {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text("Loading projects…")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyRow: some View {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        Group {
            if query.isEmpty {
                Text("No other project is open.")
            } else {
                Text("No projects match “\(query)”.")
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Move

    /// Under the list once a project is picked: what the move does, and Move.
    @ViewBuilder
    private var moveBar: some View {
        if let picked = model.picked, model.preview != .serverTooOld {
            VStack(alignment: .leading, spacing: 10) {
                previewText(for: picked)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FlatPrimaryButton(title: "Move", systemImage: "folder", isLoading: model.isMoving) {
                    Task { await model.move() }
                }
                .disabled(!model.canMove)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.bg)
        }
    }

    @ViewBuilder
    private func previewText(for folder: FolderDetail) -> some View {
        switch model.preview {
        case .idle, .serverTooOld:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .ready(_, let result):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: previewLine(result, folder: folder))
                    .foregroundStyle(result.mode == .full ? Theme.textSecondary : Theme.warning)
                if let children = SessionMoveRules.childrenNote(result) {
                    Text(verbatim: children)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case .refused(_, let message):
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.danger)
        }
    }

    private func previewLine(_ result: SessionMoveResult, folder: FolderDetail) -> String {
        SessionMoveRules.preview(result, project: folder.name, agent: request.conversation.agentType.displayName)
    }

    /// VoiceOver hears what a pick found, which shows away from the row.
    private func announce(_ preview: SessionMoveModel.Preview) {
        let text: String
        switch preview {
        case .ready(_, let result):
            guard let folder = model.picked else { return }
            text = [previewLine(result, folder: folder), SessionMoveRules.childrenNote(result)]
                .compactMap { $0 }.joined(separator: " ")
        case .refused(_, let message):
            text = message
        case .serverTooOld:
            text = String(localized: "Moving sessions needs a newer codeg server.")
        case .idle, .checking:
            return
        }
        AccessibilityNotification.Announcement(text).post()
    }
}

/// "Move to Project…" in a session row's long-press menu and the session's
/// ⋯ menu.
struct MoveToProjectMenuItem: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Move to Project…", systemImage: "folder")
        }
    }
}

/// The banner after a move, at the top of the screen for a few seconds.
private struct SessionMoveNoticeOverlay: View {
    let notice: SessionMoveNotice?

    var body: some View {
        ZStack {
            if let notice {
                SessionMoveNoticeBanner(notice: notice)
                    .id(notice.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: notice?.id)
        .allowsHitTesting(false)
    }
}

/// "Moved to Payments", or "Listed under Payments" with where the session
/// keeps running.
private struct SessionMoveNoticeBanner: View {
    let notice: SessionMoveNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: notice.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = notice.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}
