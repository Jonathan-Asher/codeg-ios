import Foundation

// iPhone push (codeg fork `docs/ios-push.md`): device registration, the
// device's own preferences, a test push, and the notification actions.

/// When a kind of notification is pushed (Rust `push::prefs::Delivery`).
enum PushDelivery: String, Codable, CaseIterable, Hashable, Sendable {
    case always
    /// Only while no desktop or web window is in use.
    case away
    case off

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PushDelivery(rawValue: raw) ?? .away
    }

    var title: String {
        switch self {
        case .always: return "Always"
        case .away: return "Only when away"
        case .off: return "Off"
        }
    }
}

/// One device's notification preferences (Rust `DevicePrefs`). Decoded from
/// the snake_case response through the shared decoder (camelCase here);
/// encoded with the snake_case keys the server reads, because the request
/// encoder keeps property names verbatim.
struct PushDevicePrefs: Codable, Hashable, Sendable {
    var turnFinished: PushDelivery = .away
    var needsYou: PushDelivery = .away
    var critical: Bool = true
    var errors: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case turnFinished, needsYou, critical, errors
    }

    private enum WireKeys: String, CodingKey {
        case turnFinished = "turn_finished"
        case needsYou = "needs_you"
        case critical, errors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnFinished = (try? c.decodeIfPresent(PushDelivery.self, forKey: .turnFinished)) ?? .away
        needsYou = (try? c.decodeIfPresent(PushDelivery.self, forKey: .needsYou)) ?? .away
        critical = (try? c.decodeIfPresent(Bool.self, forKey: .critical)) ?? true
        errors = (try? c.decodeIfPresent(Bool.self, forKey: .errors)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(turnFinished.rawValue, forKey: .turnFinished)
        try c.encode(needsYou.rawValue, forKey: .needsYou)
        try c.encode(critical, forKey: .critical)
        try c.encode(errors, forKey: .errors)
    }
}

/// A registered device as the server shows it (Rust `PushDeviceView`).
struct PushDeviceView: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let platform: String
    let environment: String
    let bundleId: String
    /// `…` and the token's last 8 characters.
    let tokenHint: String
    var prefs: PushDevicePrefs
    let lastSeenAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, platform, environment, bundleId, tokenHint, prefs, lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "iPhone"
        platform = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? "ios"
        environment = (try? c.decodeIfPresent(String.self, forKey: .environment)) ?? ""
        bundleId = (try? c.decodeIfPresent(String.self, forKey: .bundleId)) ?? ""
        tokenHint = (try? c.decodeIfPresent(String.self, forKey: .tokenHint)) ?? ""
        prefs = (try? c.decodeIfPresent(PushDevicePrefs.self, forKey: .prefs)) ?? PushDevicePrefs()
        lastSeenAt = (try? c.decodeIfPresent(Date.self, forKey: .lastSeenAt)) ?? nil
    }

    /// Whether this row is the device holding `token`.
    func matches(token: String) -> Bool {
        let tail = tokenHint.replacingOccurrences(of: "…", with: "")
        return !tail.isEmpty && token.lowercased().hasSuffix(tail.lowercased())
    }
}

/// `register_push_device`'s answer.
struct RegisteredPushDevice: Decodable, Sendable {
    let device: PushDeviceView
    /// This codeg server's push identity; every notification carries it.
    let serverId: String
}

/// One device's answer to "Send test push" (Rust `TestPushResult`).
struct TestPushResult: Decodable, Hashable, Sendable, Identifiable {
    let deviceId: Int
    let name: String
    let ok: Bool
    let error: String?
    let removed: Bool

    var id: Int { deviceId }
}

private struct RegisterPushDeviceBody: Encodable, Sendable {
    let token: String
    let environment: String
    let bundleId: String
    let name: String
    let platform: String
}

private struct UnregisterPushDeviceBody: Encodable, Sendable {
    var id: Int?
    var token: String?
}

private struct UpdatePushDevicePrefsBody: Encodable, Sendable {
    let id: Int
    let prefs: PushDevicePrefs
}

private struct SendTestPushBody: Encodable, Sendable {
    var deviceId: Int?
}

private struct SnoozeCriticalBody: Encodable, Sendable {
    let conversationId: Int
    let minutes: Int
}

extension CodegClient {
    func registerPushDevice(token: String, environment: String, bundleId: String, name: String) async throws -> RegisteredPushDevice {
        try await postJSON("register_push_device", RegisterPushDeviceBody(
            token: token, environment: environment, bundleId: bundleId, name: name, platform: "ios"))
    }

    @discardableResult
    func unregisterPushDevice(token: String? = nil, id: Int? = nil) async throws -> Bool {
        let data = try await send("unregister_push_device", body: UnregisterPushDeviceBody(id: id, token: token))
        return (try? CodegJSON.decoder.decode(Bool.self, from: data)) ?? false
    }

    func listPushDevices() async throws -> [PushDeviceView] {
        try await postJSON("list_push_devices", EmptyBody())
    }

    func updatePushDevicePrefs(id: Int, prefs: PushDevicePrefs) async throws -> PushDeviceView {
        try await postJSON("update_push_device_prefs", UpdatePushDevicePrefsBody(id: id, prefs: prefs))
    }

    func sendTestPush(deviceId: Int?) async throws -> [TestPushResult] {
        try await postJSON("send_test_push", SendTestPushBody(deviceId: deviceId))
    }

    /// Acknowledge a critical session's alert (the ACK action, or opening it).
    func ackCriticalSession(conversationId: Int) async throws {
        _ = try await send("ack_critical_session", body: ConversationIdBody(conversationId: conversationId))
    }

    /// Snooze a critical session's alerts for `minutes` (1–1440).
    func snoozeCriticalSession(conversationId: Int, minutes: Int) async throws {
        _ = try await send("snooze_critical_session",
                           body: SnoozeCriticalBody(conversationId: conversationId, minutes: min(1440, max(1, minutes))))
    }
}
