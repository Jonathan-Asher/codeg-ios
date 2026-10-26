import Foundation

/// Tells the server which conversations the user opened on this phone
/// (`mark_conversations_viewed`, codeg fork), so every client orders its
/// lists by the later of a session's last activity and the last time it was
/// opened. Only opening a session counts, not a list scrolling past it.
///
/// Views are batched per server for a moment, and each is reported with its
/// age, so the phone's clock does not matter. A server without the endpoint
/// (an older codeg) is not asked again until the app restarts.
@MainActor
final class ConversationViews {
    static let shared = ConversationViews()

    private struct Batch {
        let client: CodegClient
        var views: [Int: Date] = [:]
    }

    private var batches: [String: Batch] = [:]
    private var unsupported: Set<String> = []
    private var flushTask: Task<Void, Never>?
    /// How long views gather before they go out.
    var delay: Duration = .milliseconds(1500)

    init() {}

    /// The user opened `conversationID` on the server behind `client`.
    func record(_ conversationID: Int, client: CodegClient, at date: Date = Date()) {
        let key = Self.key(for: client)
        guard !unsupported.contains(key) else { return }
        var batch = batches[key] ?? Batch(client: client)
        batch.views[conversationID] = date
        batches[key] = batch
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.delay)
            await self.flush()
        }
    }

    /// Send what has gathered now.
    func flush() async {
        flushTask = nil
        let pending = batches
        batches = [:]
        let now = Date()
        for (key, batch) in pending where !batch.views.isEmpty {
            do {
                try await batch.client.markConversationsViewed(Self.reports(batch.views, now: now))
            } catch {
                if PendingItemsStore.isMissingRoute(error) { unsupported.insert(key) }
            }
        }
    }

    /// One report per conversation, with how long ago it was opened.
    nonisolated static func reports(_ views: [Int: Date], now: Date) -> [ConversationViewReport] {
        views.sorted { $0.key < $1.key }.map { id, date in
            ConversationViewReport(conversationId: id, ageMs: max(0, Int((now.timeIntervalSince(date) * 1000).rounded())))
        }
    }

    private static func key(for client: CodegClient) -> String {
        "\(client.baseURL.absoluteString)|\(client.token)"
    }
}
