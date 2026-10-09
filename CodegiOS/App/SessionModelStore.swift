import UIKit

/// Owns the session screens' models, above the navigation containers, keyed
/// by server endpoint and conversation. A screen that is rebuilt (the iPad
/// switching between its split view and its tabs, a tab switched away and
/// back) is handed the same model, with its transcript, draft, live turn and
/// event socket, instead of starting a new one that loads and connects again.
///
/// Screens hold a model through a ``SessionLease`` between `onAppear` and
/// `onDisappear`. Once no screen holds it for `grace`, the model is
/// suspended (its sockets close, as leaving the screen always did) and kept,
/// so opening the session again is instant; only the `keepSuspended` most
/// recently used suspended models are kept.
@MainActor
final class SessionModelStore {
    enum Target: Hashable {
        case conversation(Int)
        case draft(UUID)
    }

    struct Key: Hashable {
        let server: UUID
        /// `TranscriptCache.serverKey`: a new URL or token is a new model.
        let endpoint: String
        let target: Target
    }

    private final class Entry {
        let model: SessionDetailViewModel
        var holders: Set<UUID> = []
        var suspendTask: Task<Void, Never>?
        var lastUsed = Date()

        init(model: SessionDetailViewModel) {
            self.model = model
        }
    }

    private var entries: [Key: Entry] = [:]
    /// How long a model may go unheld before it is suspended: a screen rebuilt
    /// around it (old one gone, new one not yet on screen) holds it again
    /// well within this.
    var grace: Duration = .milliseconds(700)
    /// While a send is still being handed to the server, suspension waits.
    var busyRetry: Duration = .seconds(2)
    static let keepSuspended = 6

    /// Where models keep transcripts between openings.
    var transcriptCache: TranscriptCache? = .shared
    /// What the session lists know of a conversation, shown while it loads.
    var summaryLookup: (@MainActor (Int) -> ConversationSummary?)?
    /// Builds models (tests inject scripted event sockets here).
    var makeModel: (@MainActor (CodegClient, Int, TranscriptCache?) -> SessionDetailViewModel)?

    private var memoryWarning: NSObjectProtocol?

    init() {
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropSuspended(keeping: 0) }
        }
    }

    // MARK: - Models

    func key(server: ServerProfile, client: CodegClient, target: Target) -> Key {
        Key(server: server.id, endpoint: TranscriptCache.serverKey(for: client), target: target)
    }

    /// The model for an existing conversation, made on first use.
    func model(server: ServerProfile, client: CodegClient, conversationID: Int) -> SessionDetailViewModel {
        let key = key(server: server, client: client, target: .conversation(conversationID))
        if let entry = entries[key] { return entry.model }
        let model = makeModel?(client, conversationID, transcriptCache)
            ?? SessionDetailViewModel(client: client, conversationID: conversationID, transcriptCache: transcriptCache)
        model.prime(summary: summaryLookup?(conversationID))
        entries[key] = Entry(model: model)
        return model
    }

    /// The model for a new task's draft, made on first use.
    func model(server: ServerProfile, client: CodegClient, draft request: NewSessionRequest) -> SessionDetailViewModel {
        let key = key(server: server, client: client, target: .draft(request.id))
        if let entry = entries[key] { return entry.model }
        let model = SessionDetailViewModel(client: client, newSession: request, transcriptCache: transcriptCache)
        entries[key] = Entry(model: model)
        return model
    }

    func lease(server: ServerProfile, client: CodegClient, target: Target) -> SessionLease {
        SessionLease(store: self, key: key(server: server, client: client, target: target))
    }

    /// The model kept for `conversationID` on any server (tests, prefetch).
    func existingModel(conversationID: Int) -> SessionDetailViewModel? {
        entries.first { $0.key.target == .conversation(conversationID) }?.value.model
    }

    /// Conversations a screen shows right now.
    var heldConversationIDs: Set<Int> {
        Set(entries.compactMap { key, entry in
            guard !entry.holders.isEmpty, case .conversation(let id) = key.target else { return nil }
            return id
        })
    }

    // MARK: - Holding

    fileprivate func acquire(_ key: Key, holder: UUID) {
        guard let entry = entries[key] else { return }
        entry.holders.insert(holder)
        entry.lastUsed = Date()
        entry.suspendTask?.cancel()
        entry.suspendTask = nil
        if entry.model.isSuspended {
            let model = entry.model
            Task { await model.resume() }
        }
    }

    fileprivate func release(_ key: Key, holder: UUID) {
        guard let entry = entries[key] else { return }
        entry.holders.remove(holder)
        entry.lastUsed = Date()
        guard entry.holders.isEmpty else { return }
        scheduleSuspend(entry, key: key, after: grace)
    }

    private func scheduleSuspend(_ entry: Entry, key: Key, after delay: Duration) {
        entry.suspendTask?.cancel()
        entry.suspendTask = Task { [weak self, weak entry] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let entry, entry.holders.isEmpty else { return }
            // A send still being handed to the server finishes first; leaving
            // the screen right after Send must not lose the message.
            if entry.model.isHandingOffSend {
                self.scheduleSuspend(entry, key: key, after: self.busyRetry)
                return
            }
            entry.suspendTask = nil
            entry.model.suspend()
            self.dropSuspended(keeping: Self.keepSuspended)
        }
    }

    /// Forget suspended models beyond the `keeping` most recently used.
    private func dropSuspended(keeping: Int) {
        let suspended = entries.filter { $0.value.holders.isEmpty && $0.value.model.isSuspended }
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
        for (key, _) in suspended.dropFirst(keeping) {
            entries.removeValue(forKey: key)
        }
    }

    /// Close and forget every model (the server changed).
    func removeAll() {
        for entry in entries.values {
            entry.suspendTask?.cancel()
            entry.model.suspend()
        }
        entries.removeAll()
    }
}

/// A screen's claim on a model in ``SessionModelStore``: acquired while the
/// screen is on screen, released when it goes away.
struct SessionLease {
    fileprivate weak var store: SessionModelStore?
    fileprivate let key: SessionModelStore.Key

    @MainActor func acquire(_ holder: UUID) { store?.acquire(key, holder: holder) }
    @MainActor func release(_ holder: UUID) { store?.release(key, holder: holder) }
}
