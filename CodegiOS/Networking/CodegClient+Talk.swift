import Foundation

// Talk: Hebrew voice conversations with a session from the iPhone. The codeg
// server keeps whether Talk is on per conversation, and the person's Talk
// settings; see the server's `docs/talk-mode.md`.

private struct SetConversationTalkModeBody: Encodable, Sendable {
    let conversationId: Int
    let enabled: Bool
}

private struct UpdateTalkSettingsBody: Encodable, Sendable {
    let settings: TalkSettings
}

extension CodegClient {
    /// Turn Talk on or off for a conversation (`set_conversation_talk_mode`).
    /// It changes nothing the agent already has (its prompt, tools, model or
    /// mode), so the prompt cache stays; the next message carries the note.
    /// A server that answers is one that reads `talking` in presence frames
    /// (``TalkServerSupport``). Throws the server's error; an older server
    /// answers 404, which ``TalkServerSupport/isMissingRoute(_:)`` tells.
    func setConversationTalkMode(conversationId: Int, enabled: Bool) async throws {
        do {
            _ = try await send("set_conversation_talk_mode",
                               body: SetConversationTalkModeBody(conversationId: conversationId, enabled: enabled))
            TalkServerSupport.shared.noteAccepted(baseURL)
        } catch {
            if TalkServerSupport.isMissingRoute(error) { TalkServerSupport.shared.noteMissing(baseURL) }
            throw error
        }
    }

    /// The person's Talk settings (`get_talk_settings`).
    func getTalkSettings() async throws -> TalkSettings {
        try await postJSON("get_talk_settings", EmptyBody(), session: Self.readSession)
    }

    /// Store the Talk settings (`update_talk_settings`); returns what the
    /// server kept (the settings sent, from a server that answers with none).
    @discardableResult
    func updateTalkSettings(_ settings: TalkSettings) async throws -> TalkSettings {
        let data = try await send("update_talk_settings", body: UpdateTalkSettingsBody(settings: settings))
        return (try? CodegJSON.decoder.decode(TalkSettings.self, from: data)) ?? settings
    }
}

/// Which servers took `set_conversation_talk_mode`, by address. Only those
/// get `talking` in this phone's presence frames (``SessionPresenceReporter``);
/// an older server never sees the field.
final class TalkServerSupport: @unchecked Sendable {
    static let shared = TalkServerSupport()

    private let lock = NSLock()
    private var accepted: Set<String> = []

    func accepts(_ baseURL: URL) -> Bool {
        lock.withLock { accepted.contains(Self.key(baseURL)) }
    }

    func noteAccepted(_ baseURL: URL) {
        _ = lock.withLock { accepted.insert(Self.key(baseURL)) }
    }

    func noteMissing(_ baseURL: URL) {
        _ = lock.withLock { accepted.remove(Self.key(baseURL)) }
    }

    /// The server doesn't have the endpoint (an older codeg answers 501
    /// `not_implemented`). A 404 `not_found` is about the conversation, not
    /// the endpoint.
    static func isMissingRoute(_ error: Error) -> Bool {
        guard case APIError.server(let status, let code, _) = error else { return false }
        if status == 501 || status == 405 { return true }
        return status == 404 && (code == nil || code == "not_implemented")
    }

    private static func key(_ baseURL: URL) -> String {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
