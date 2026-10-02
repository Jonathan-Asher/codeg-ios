import Foundation
import Observation

/// What each session of the selected server is blocked on (permission,
/// question or plan approval), from the fork's `list_conversation_attention`.
/// Refreshed with every list pulse (Chats and Activity) and read by the
/// session rows, so a row can say "Needs you" without opening the session.
@MainActor
@Observable
final class AttentionStore {
    static let shared = AttentionStore()

    private(set) var kinds: [Int: String] = [:]

    private init() {}

    func kind(for conversationID: Int) -> String? { kinds[conversationID] }

    /// Replace the snapshot. A failed fetch passes nil and keeps the last one.
    func update(_ snapshot: [Int: String]?) {
        guard let snapshot, snapshot != kinds else { return }
        kinds = snapshot
    }

    /// One session's card appeared or was answered on this device.
    func set(_ kind: String?, for conversationID: Int) {
        if kinds[conversationID] != kind { kinds[conversationID] = kind }
    }

    func clear() {
        if !kinds.isEmpty { kinds = [:] }
    }
}
