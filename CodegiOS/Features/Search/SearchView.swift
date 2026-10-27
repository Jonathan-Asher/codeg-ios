import SwiftUI

/// Root of the system search tab: server-side search across the selected
/// server's conversations, debounced as you type, with locally stored recent
/// searches when the field is empty. Two searches run side by side: session
/// titles (`list_all_conversations` with `search`) and the messages' text
/// (`message_search`, the full-text index codeg's ⌘K uses). A message hit
/// opens its session at that message. A query without a word of three
/// characters searches titles only, and so does a server without message
/// search. Replaces the old hand-rolled in-list search field — on iOS 26 the
/// search tab role gives the field its native placement for free.
struct SearchView: View {
    let client: CodegClient?
    /// The session opened last (or open, on iPad); its row is marked.
    var markedConversationID: Int? = nil
    /// Words to search for, sent from elsewhere (the Chats filter's "Search
    /// messages for …"): they replace the query.
    var request: SearchRequest? = nil
    /// The request was taken; the sender forgets it.
    var onRequestHandled: ((SearchRequest) -> Void)? = nil
    let onOpen: (Int) -> Void
    /// Opens a session at one of its messages. Without it a message hit
    /// opens its session like a title match.
    var onOpenMessage: ((Int, TranscriptJumpRequest) -> Void)? = nil

    @State private var query = ""
    @State private var results: [ConversationSummary] = []
    @State private var folderNames: [Int: String] = [:]
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?
    @State private var recents: [String] = RecentSearches.load()
    /// What the message search found for the query (nil until it answers).
    @State private var messages: MessageSearch.Outcome?
    /// Every title match shown, not only the first few.
    @State private var showAllSessions = false
    /// Sessions whose other message hits are unfolded.
    @State private var expandedGroups: Set<Int> = []
    /// The server has no message search (an older codeg): titles only, not
    /// asked again while this screen lasts (a new server makes a new one).
    @State private var messageSearchUnsupported = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Search", compact: horizontalSizeClass == .compact)
        .searchable(text: $query, prompt: "Search sessions")
        .task(id: query) {
            await runSearch()
        }
        .onChange(of: request, initial: true) { _, request in
            guard let request else { return }
            query = request.query
            onRequestHandled?(request)
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if client == nil {
            EmptyStateView(
                icon: "server.rack",
                title: "No Server Selected",
                message: "Pick a server in the Chats tab to search its sessions."
            )
        } else if trimmedQuery.isEmpty {
            recentsList
        } else if isSearching, !hasSearched {
            LoadingView(label: "Searching…")
        } else if let error {
            InlineErrorView(message: error) {
                Task { await runSearch(force: true) }
            }
        } else if results.isEmpty, hasSearched, messagesFoundNothing {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Matches",
                message: noMatchesMessage
            )
        } else {
            resultsList
        }
    }

    /// The message search has nothing to add to empty title results.
    private var messagesFoundNothing: Bool {
        switch messages {
        case .tooShort?, .unsupported?: return true
        case .found(let groups)?: return groups.isEmpty
        case .failed?, nil: return false
        }
    }

    private var noMatchesMessage: LocalizedStringKey {
        switch messages {
        case .tooShort?:
            return "No sessions match \"\(trimmedQuery)\". Message search needs a word of at least 3 characters."
        case .found?:
            return "No sessions or messages match \"\(trimmedQuery)\"."
        default:
            return "No sessions match \"\(trimmedQuery)\"."
        }
    }

    /// Headed sections once message hits come into it; titles alone stay a
    /// plain list, as before.
    private var showsMessages: Bool {
        switch messages {
        case .tooShort?, .unsupported?: return false
        case .failed?, .found?: return true
        case nil: return !messageSearchUnsupported && MessageSearch.canSearchMessages(trimmedQuery)
        }
    }

    /// Title matches shown before "Show all", while messages follow them.
    private static let sessionPreview = 5

    private var visibleSessions: ArraySlice<ConversationSummary> {
        guard showsMessages, !showAllSessions, results.count > Self.sessionPreview + 1 else { return results[...] }
        return results.prefix(Self.sessionPreview)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if messages == .tooShort {
                    SearchNoteRow(text: "Message search needs a word of at least 3 characters.",
                                  symbol: "info.circle")
                }
                if showsMessages, !results.isEmpty {
                    SearchSectionHeader(title: "Sessions")
                }
                ForEach(visibleSessions) { conversation in
                    SessionRow(
                        conversation: conversation,
                        isSelected: conversation.id == markedConversationID,
                        folderName: folderNames[conversation.folderId],
                        onTap: { open(conversation) }
                    )
                }
                if visibleSessions.count < results.count {
                    Button {
                        withAnimation(Theme.Motion.expand) { showAllSessions = true }
                    } label: {
                        Text("Show all \(results.count) sessions")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if showsMessages {
                    messagesSection
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var recentsList: some View {
        if recents.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Search Sessions",
                message: "Find sessions by their titles and messages across all of this server's folders."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Recent")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Clear") {
                            recents = []
                            RecentSearches.save([])
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 6)

                    ForEach(recents, id: \.self) { term in
                        Button {
                            query = term
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                                Text(term)
                                    .font(.body)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Theme.hairline)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var messagesSection: some View {
        SearchSectionHeader(title: "Messages")
        switch messages {
        case .found(let groups)? where !groups.isEmpty:
            ForEach(groups) { group in
                MessageHitCard(
                    group: group,
                    folderName: folderNames[group.folderID],
                    isSelected: group.conversationID == markedConversationID,
                    isExpanded: Binding(
                        get: { expandedGroups.contains(group.conversationID) },
                        set: { expanded in
                            if expanded {
                                expandedGroups.insert(group.conversationID)
                            } else {
                                expandedGroups.remove(group.conversationID)
                            }
                        }
                    ),
                    onOpen: { open($0) }
                )
            }
        case .found?:
            SearchNoteRow(text: "No messages match.")
        case .failed?:
            SearchNoteRow(text: "Couldn't search messages.", symbol: "exclamationmark.triangle",
                          actionTitle: "Try Again") {
                Task { await runSearch(force: true) }
            }
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching messages…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tooShort?, .unsupported?:
            EmptyView()
        }
    }

    // MARK: - Search

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runSearch(force: Bool = false) async {
        let term = trimmedQuery
        error = nil
        guard let client, !term.isEmpty else {
            results = []
            hasSearched = false
            isSearching = false
            messages = nil
            return
        }
        // A query too short for message search says so at once.
        let searchesMessages = MessageSearch.canSearchMessages(term) && !messageSearchUnsupported
        if !MessageSearch.canSearchMessages(term) {
            messages = .tooShort
        } else if messageSearchUnsupported {
            messages = .unsupported
        }
        // Debounce: typing cancels this task (`.task(id: query)`) and restarts it.
        if !force {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        if searchesMessages, force || messages == .tooShort { messages = nil }
        showAllSessions = false
        expandedGroups = []
        isSearching = true
        defer { isSearching = false }
        // The messages' text alongside the titles; it never fails the search.
        let supported = !messageSearchUnsupported
        async let messageOutcome = Self.searchMessages(term, client: client, supported: supported)
        do {
            async let matches = client.listConversations(search: term)
            async let folders = client.listFolders()
            let (loaded, loadedFolders) = try await (matches, folders)
            guard !Task.isCancelled else { return }
            results = loaded.sorted { $0.updatedAt > $1.updatedAt }
            folderNames = Dictionary(loadedFolders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            hasSearched = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let outcome = await messageOutcome
        guard !Task.isCancelled else { return }
        messages = outcome
        if outcome == .unsupported { messageSearchUnsupported = true }
    }

    /// The message search for `term` (``MessageSearch/run(_:search:)``).
    private static func searchMessages(_ term: String, client: CodegClient,
                                       supported: Bool) async -> MessageSearch.Outcome {
        guard supported else { return .unsupported }
        return await MessageSearch.run(term) { try await client.searchMessages($0) }
    }

    private func open(_ conversation: ConversationSummary) {
        recents = RecentSearches.record(trimmedQuery, in: recents)
        onOpen(conversation.id)
    }

    /// A message hit: its session, at that message.
    private func open(_ hit: MessageSearchHit) {
        recents = RecentSearches.record(trimmedQuery, in: recents)
        if let onOpenMessage {
            onOpenMessage(hit.conversationId, MessageSearch.jumpRequest(for: hit, query: trimmedQuery))
        } else {
            onOpen(hit.conversationId)
        }
    }
}

/// Tiny local store for recent search terms (most recent first, capped).
enum RecentSearches {
    private static let key = "codeg.recentSearches.v1"
    private static let cap = 10

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: key)
    }

    /// Prepend a term (deduplicated, capped) and persist; returns the new list.
    static func record(_ term: String, in current: [String]) -> [String] {
        guard !term.isEmpty else { return current }
        var next = current.filter { $0.localizedCaseInsensitiveCompare(term) != .orderedSame }
        next.insert(term, at: 0)
        next = Array(next.prefix(cap))
        save(next)
        return next
    }
}
