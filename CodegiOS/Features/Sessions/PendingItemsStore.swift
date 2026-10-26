import Foundation
import Observation
import UserNotifications

extension Notification.Name {
    /// A push said the pending list moved, or a notification action answered
    /// an item: reload it. `object` is the server profile's `UUID`.
    static let pendingItemsMayHaveChanged = Notification.Name("codeg.pendingItemsMayHaveChanged")
}

/// What waits on the user on the selected server ("Waiting for you" at the
/// top of the sessions list): `list_pending_items`, kept live by the
/// `app://pending-items` event (codeg fork `docs/ios-push.md` §9).
///
/// While the app is in front ``run(client:serverProfileID:ownSocket:)`` loads
/// the list and follows the event. Every event socket of the app hands the
/// event over (``EventStream/setGlobalEventHandler(_:)``), so while a session
/// is on screen its sockets carry it; otherwise the store keeps one socket of
/// its own. The count feeds the icon badge (``AppBadge``).
@MainActor
@Observable
final class PendingItemsStore {
    static let channel = "app://pending-items"

    private(set) var items: [PendingItem] = []
    private(set) var count = 0
    /// The list loaded at least once from this server.
    private(set) var hasLoaded = false
    /// Items with an answer from the list on its way (hidden meanwhile).
    private(set) var answering: Set<String> = []
    /// Why the last answer from the list didn't go through.
    private(set) var answerError: String?

    @ObservationIgnored private var client: CodegClient?
    @ObservationIgnored private(set) var serverProfileID: UUID?
    /// False once the server said it has no `list_pending_items` (an older
    /// codeg): nothing to show or follow.
    @ObservationIgnored private(set) var supported: Bool?
    /// Bumped by ``reset()`` so a load for the previous server is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .pendingItemsMayHaveChanged, object: nil, queue: .main
        ) { [weak self] note in
            let profileID = note.object as? UUID
            Task { @MainActor [weak self] in
                await self?.mayHaveChanged(profileID: profileID)
            }
        }
    }

    private func mayHaveChanged(profileID: UUID?) async {
        guard serverProfileID != nil, profileID == nil || profileID == serverProfileID else { return }
        await refresh()
    }

    /// The items to show: the list without the ones being answered.
    var visibleItems: [PendingItem] { items.filter { !answering.contains($0.id) } }

    // MARK: - Server

    /// Point the store at a server. Another server, address or token starts
    /// over with nothing shown.
    func bind(client: CodegClient?, serverProfileID: UUID?) {
        let same = serverProfileID == self.serverProfileID
            && client?.baseURL == self.client?.baseURL && client?.token == self.client?.token
        self.client = client
        self.serverProfileID = serverProfileID
        if !same { clear() }
    }

    /// The selected server changed: forget its list.
    func reset() {
        client = nil
        serverProfileID = nil
        clear()
    }

    private func clear() {
        generation += 1
        items = []
        count = 0
        hasLoaded = false
        answering = []
        answerError = nil
        supported = nil
    }

    // MARK: - Loading

    /// `list_pending_items`. A server without it shows nothing; any other
    /// failure keeps what is shown until the next try.
    func refresh() async {
        guard let client else { return }
        let token = generation
        do {
            let snapshot = try await client.listPendingItems()
            guard token == generation else { return }
            supported = true
            apply(snapshot)
        } catch {
            guard token == generation else { return }
            if Self.isMissingRoute(error) {
                supported = false
                apply(.empty)
            }
        }
    }

    /// Show a snapshot: a load, or an `app://pending-items` event.
    func apply(_ snapshot: PendingSnapshot) {
        items = snapshot.items
        count = snapshot.count
        hasLoaded = true
        if let serverProfileID { AppBadge.shared.set(snapshot.count, for: serverProfileID) }
    }

    /// An `app://pending-items` event from an event socket to `baseURL`.
    func receive(channel: String, payload: Data, from baseURL: URL) {
        guard channel == Self.channel, let client, baseURL == client.baseURL,
              let snapshot = try? CodegJSON.decoder.decode(PendingSnapshot.self, from: payload) else { return }
        apply(snapshot)
    }

    nonisolated static func isMissingRoute(_ error: Error) -> Bool {
        if case APIError.server(let status, _, _) = error { return status == 404 || status == 405 }
        return false
    }

    // MARK: - Answering from the list

    /// Answer a single-choice question with one of its labels. The item hides
    /// at once; if the answer fails and the item is still waiting, it comes
    /// back with the reason.
    func answer(_ item: PendingItem, label: String) async {
        guard let client, !answering.contains(item.id) else { return }
        answering.insert(item.id)
        answerError = nil
        var failure: String?
        do {
            try await client.answerPendingQuestion(item, label: label)
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await refresh()
        answering.remove(item.id)
        // Answered elsewhere in the meantime: it is gone, nothing to report.
        if let failure, items.contains(where: { $0.id == item.id }) {
            answerError = failure
        }
    }

    func dismissAnswerError() { answerError = nil }

    // MARK: - Following the list

    /// While the app is in front: load, then follow the event until the task
    /// is cancelled. With `ownSocket` the store keeps an event socket of its
    /// own (reconnecting after a drop); without it a session on screen keeps
    /// one, and the store only checks the list now and then.
    func run(client: CodegClient?, serverProfileID: UUID?, ownSocket: Bool) async {
        bind(client: client, serverProfileID: serverProfileID)
        guard let client else { return }
        EventStream.setGlobalEventHandler { [weak self] baseURL, channel, payload in
            Task { @MainActor [weak self] in
                self?.receive(channel: channel, payload: payload, from: baseURL)
            }
        }
        var delay: Duration = .seconds(2)
        while !Task.isCancelled {
            await refresh()
            if supported == false || Task.isCancelled { return }
            if ownSocket {
                let opened = ContinuousClock.now
                await listen(client)
                if Task.isCancelled { return }
                // A socket that lived a while starts the back-off over.
                if ContinuousClock.now - opened > .seconds(60) { delay = .seconds(2) }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            } else {
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// One event socket, until it closes or the task is cancelled. The
    /// events themselves arrive through the global handler.
    private func listen(_ client: CodegClient) async {
        let stream = EventStream(baseURL: client.baseURL, token: client.token)
        stream.start()
        loop: for await frame in stream.frames {
            switch frame {
            case .ready:
                // Catch up with what changed while it connected.
                await refresh()
            case .closed:
                break loop
            default:
                continue
            }
        }
        stream.close()
    }
}

/// The app icon's badge: how many items wait on the user, summed over the
/// saved servers. Each push carries its own server's count (`aps.badge`),
/// which iOS shows while the app is away; while it runs, the app sets the sum
/// itself from the lists it loads and the pushes it sees, and puts it right
/// when it comes to the front.
@MainActor
final class AppBadge {
    static let shared = AppBadge()

    private(set) var counts: [UUID: Int] = [:]
    /// Sets the icon badge; the unit tests record instead.
    var setBadge: (Int) -> Void = { count in
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
    /// The saved servers' ids.
    var savedServers: () -> Set<UUID> = { Set(ServerStore.persistedServers().map(\.id)) }
    /// Whether notifications are on in the app (no badge when they are off).
    var isEnabled: () -> Bool = { PushRegistration.shared.enabled }

    init() {}

    func set(_ count: Int, for profileID: UUID) {
        counts[profileID] = max(0, count)
        apply()
    }

    func forget(_ profileID: UUID) {
        counts[profileID] = nil
        apply()
    }

    var total: Int { Self.total(counts, saved: savedServers()) }

    static func total(_ counts: [UUID: Int], saved: Set<UUID>) -> Int {
        counts.filter { saved.contains($0.key) }.values.reduce(0) { $0 + max(0, $1) }
    }

    func apply() {
        setBadge(isEnabled() ? total : 0)
    }

    /// The app came to the front: ask every saved server but `skipping` (the
    /// selected one, which ``PendingItemsStore`` loads) for its count, then
    /// set the badge, replacing whatever a push left there.
    func refresh(skipping: UUID?) async {
        let clients = ServerStore.persistedServers()
            .filter { $0.id != skipping }
            .compactMap { profile in ServerStore.makeClient(for: profile).map { (profile.id, $0) } }
        var fetched: [(UUID, Int)] = []
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for (id, client) in clients {
                group.addTask {
                    do {
                        return (id, try await client.listPendingItems().count)
                    } catch {
                        return (id, PendingItemsStore.isMissingRoute(error) ? 0 : nil)
                    }
                }
            }
            for await (id, count) in group {
                if let count { fetched.append((id, count)) }
            }
        }
        for (id, count) in fetched { counts[id] = count }
        apply()
    }
}
