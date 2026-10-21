import CryptoKit
import Foundation

/// Why a message did not reach the server, and whether it goes out again by
/// itself. See docs/FORK.md, "Messages that could not be sent (1.3.19)".
///
/// A failed message is never dropped and never put back into the message bar:
/// it waits in the queue above it, marked "Not sent" with this reason. Failures
/// that only mean "the server could not be reached" (`autoRetry`) are sent
/// again by themselves once it answers; one the server refused waits for
/// Send now. Every attempt carries the message's client id, so a send that did
/// arrive before its answer was lost is answered as a duplicate, not delivered
/// twice.
struct SendFailure: Hashable, Codable, Sendable {
    enum Reason: String, Codable, Sendable {
        case network, timeout, server, connection, unauthorized, rejected, interrupted
    }

    var reason: Reason
    var autoRetry: Bool
    var attempts: Int

    /// Automatic attempts for an unexpected server error before it waits for
    /// the user: it may pass, but must not loop.
    static let maxUnexpectedAttempts = 3

    /// A message restored after the app went away while it was on its way:
    /// whether it arrived is unknown, so it goes again with the same id.
    static let interrupted = SendFailure(reason: .interrupted, autoRetry: true, attempts: 0)

    /// The failure to record when a message that had failed `previous` (or
    /// never) fails again with `error`.
    static func next(after error: Error, previous: SendFailure?) -> SendFailure {
        let reason = classify(error)
        let attempts = (previous?.attempts ?? 0) + 1
        let auto: Bool
        switch reason {
        case .network, .timeout, .connection, .unauthorized, .interrupted: auto = true
        case .server: auto = attempts < maxUnexpectedAttempts
        case .rejected: auto = false
        }
        return SendFailure(reason: reason, autoRetry: auto, attempts: attempts)
    }

    static func classify(_ error: Error) -> Reason {
        if let api = error as? APIError {
            switch api {
            case .transport(let detail):
                return detail.lowercased().contains("timed out") ? .timeout : .network
            case .unauthorized:
                return .unauthorized
            case .streamGone:
                return .connection
            case .server(let status, let code, _):
                if api.isStaleConnection { return .connection }
                if status >= 500 { return .server }
                if status == 401 || status == 403 || code == "authentication_failed" { return .unauthorized }
                if status == 408 { return .timeout }
                return .rejected
            case .decoding, .turnInProgress:
                return .server
            case .invalidURL:
                return .rejected
            }
        }
        if let url = error as? URLError { return url.code == .timedOut ? .timeout : .network }
        return .server
    }

    /// Seconds before the next automatic attempt.
    var retryDelay: Double {
        attempts <= 0 ? 0 : min(30, pow(2, Double(attempts - 1)))
    }

    /// What the queued row says after "Not sent".
    var label: String {
        if !autoRetry {
            return reason == .rejected ? "Refused by the server" : "Still failing — tap Send now"
        }
        switch reason {
        case .network, .connection: return "Connection lost — will resend"
        case .timeout: return "No answer — will resend"
        case .server: return "Server error — will resend"
        case .unauthorized: return "Signed out — will resend after you sign in"
        case .interrupted: return "Interrupted — will resend"
        case .rejected: return "Refused by the server"
        }
    }
}

/// One message of a conversation that the server does not have yet, as stored.
struct OutboxMessage: Codable, Hashable, Sendable {
    struct Image: Codable, Hashable, Sendable {
        var name: String
        var mimeType: String
        var data: Data
    }

    var clientMessageID: String
    var text: String
    var images: [Image]
    var holdUntilTurnEnd: Bool
    var failure: SendFailure?
}

/// A conversation's unsent messages on disk: the queue above the message bar
/// and the messages on their way that the server has not acknowledged. Written
/// on every change, so an app that is killed, a screen that is closed while a
/// message is on its way, or a restart gives them back when the conversation
/// opens again: the queue as it was, and every message that was still on its
/// way at its front, sent again with the same id.
///
/// One file per server and conversation, under Application Support/Outbox.
enum OutboxStore {
    struct Contents: Codable, Hashable, Sendable {
        var queue: [OutboxMessage] = []
        var inflight: [OutboxMessage] = []

        var isEmpty: Bool { queue.isEmpty && inflight.isEmpty }

        /// The queue this restores to: the messages that were on their way
        /// first (they were sent before anything queued), marked interrupted.
        var restoredQueue: [OutboxMessage] {
            let queued = Set(queue.map(\.clientMessageID))
            let interrupted = inflight
                .filter { !queued.contains($0.clientMessageID) }
                .map { message -> OutboxMessage in
                    var restored = message
                    restored.failure = .interrupted
                    restored.holdUntilTurnEnd = false
                    return restored
                }
            return interrupted + queue
        }
    }

    /// Where the files live; tests point it elsewhere.
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Outbox", isDirectory: true)
    }

    /// The server half of the key: its address only, so a new token does not
    /// orphan what was waiting.
    static func serverKey(baseURL: URL) -> String {
        let digest = SHA256.hash(data: Data(baseURL.absoluteString.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(serverKey: String, conversationID: Int) -> URL {
        root.appendingPathComponent(serverKey, isDirectory: true)
            .appendingPathComponent("conversation-\(conversationID).json")
    }

    static func load(serverKey: String, conversationID: Int) -> Contents? {
        let url = fileURL(serverKey: serverKey, conversationID: conversationID)
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              !contents.isEmpty
        else { return nil }
        return contents
    }

    static func save(_ contents: Contents, serverKey: String, conversationID: Int) {
        let url = fileURL(serverKey: serverKey, conversationID: conversationID)
        if contents.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(contents)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Nothing more to do: the messages are still in memory.
        }
    }
}
