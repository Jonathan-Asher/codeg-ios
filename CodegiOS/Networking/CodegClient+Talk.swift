import Foundation

// Talk: Hebrew voice conversations with a session from the iPhone. The codeg
// server keeps whether Talk is on per conversation, and the person's Talk
// settings; see the server's `docs/talk-mode.md`.

/// The person's Talk settings on the server (`get_talk_settings`,
/// `update_talk_settings`): which language the agent answers in, and how it
/// addresses the person in Hebrew. The server writes them into Talk's hidden
/// note on each spoken message.
struct TalkSettings: Codable, Hashable, Sendable {
    enum Language: String, Codable, CaseIterable, Sendable {
        /// The language of the person's last message (Hebrew when unsure).
        case auto
        case hebrew = "he"
        case english = "en"
    }

    enum Address: String, Codable, CaseIterable, Sendable {
        /// Wording without gendered second-person forms.
        case auto
        case masculine
        case feminine
    }

    var language: Language = .auto
    var address: Address = .auto

    init(language: Language = .auto, address: Address = .auto) {
        self.language = language
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case language, address }

    /// Lenient: a value this build doesn't know reads as `auto`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = ((try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil).flatMap { Language(rawValue: $0) } ?? .auto
        address = ((try? c.decodeIfPresent(String.self, forKey: .address)) ?? nil).flatMap { Address(rawValue: $0) } ?? .auto
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(language.rawValue, forKey: .language)
        try c.encode(address.rawValue, forKey: .address)
    }
}

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

    /// The server doesn't have the endpoint (an older codeg).
    static func isMissingRoute(_ error: Error) -> Bool {
        guard case APIError.server(let status, _, _) = error else { return false }
        return [404, 405, 501].contains(status)
    }

    private static func key(_ baseURL: URL) -> String {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
