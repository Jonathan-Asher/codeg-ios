import UIKit
import UserNotifications
import Observation
import os

/// iPhone push for every saved codeg server (codeg fork `docs/ios-push.md`).
///
/// - Asks for notification permission at a sensible moment: right after a
///   server is added, on launch when servers already exist and the question
///   was never asked, or from Settings › Notifications. Never on a first
///   launch with no server.
/// - Registers for remote notifications and sends the token to EVERY saved
///   server (`register_push_device`), on every launch and whenever the token
///   changes. Records each server's `server_id` and device id.
/// - Unregisters from a server when it is removed, and from all of them when
///   notifications are turned off (in the app or in iOS Settings): a server
///   that thinks the phone took an alert skips the chat-channel fallback.
/// - Handles the notification actions in the background (ACK, SNOOZE,
///   APPROVE) and routes taps / OPEN to the session.
@MainActor
@Observable
final class PushRegistration {
    static let shared = PushRegistration()

    /// Hex-encoded APNs device token, once iOS has issued one.
    private(set) var deviceToken: String?
    /// The last registration failure, e.g. an unsigned simulator build that
    /// carries no `aps-environment` entitlement.
    private(set) var lastError: String?
    /// iOS notification permission.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// The last registration error per saved server, for Settings.
    private(set) var serverErrors: [UUID: String] = [:]
    /// Bumped whenever a registration round finishes (Settings reloads).
    private(set) var registrationTick = 0

    /// The app-level switch in Settings › Notifications (default on).
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task {
                if enabled {
                    await requestAuthorizationIfNeeded()
                    await registerAll()
                } else {
                    await unregisterAll()
                }
            }
        }
    }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "push")
    private let center = UNUserNotificationCenter.current()
    private let notificationDelegate = NotificationDelegate()

    private static let enabledKey = "codeg.push.enabled"
    private static let askedKey = "codeg.push.askedPermission"

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - Launch

    /// From `application(_:didFinishLaunchingWithOptions:)`: the delegate must
    /// be set before launch finishes so a tap that launched the app is seen.
    func appDidLaunch() {
        center.delegate = notificationDelegate
        center.setNotificationCategories(Self.categories)
        Task {
            await refreshAuthorization()
            // Servers exist but the question was never asked (an install that
            // predates push): ask now. A first launch has no server yet.
            if authorization == .notDetermined, enabled, !ServerStore.persistedServers().isEmpty {
                await requestAuthorizationIfNeeded()
            }
            if isAllowed { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// The app came back to the foreground: notice a permission change made in
    /// iOS Settings.
    func refreshOnForeground() {
        Task {
            let before = authorization
            await refreshAuthorization()
            guard before != authorization else { return }
            if isAllowed {
                UIApplication.shared.registerForRemoteNotifications()
            } else if authorization == .denied {
                await unregisterAll()
            }
        }
    }

    var isAllowed: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
    }

    /// Ask for alerts, sounds and badges. Time-sensitive delivery needs no
    /// option of its own: it comes from the entitlement and the per-app
    /// "Time Sensitive Notifications" switch iOS shows once one arrives.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorization()
        if authorization == .notDetermined {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                lastError = error.localizedDescription
            }
            await refreshAuthorization()
        }
        if isAllowed { UIApplication.shared.registerForRemoteNotifications() }
        return isAllowed
    }

    // MARK: - Token

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        lastError = nil
        log.info("APNs device token received (\(String(token.prefix(8)), privacy: .public)...)")
        Task { await registerAll() }
    }

    func didFailToRegister(_ error: Error) {
        lastError = error.localizedDescription
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Servers

    /// A server was added: ask (once) and register with it.
    func serverAdded(_ profile: ServerProfile) {
        Task {
            guard enabled else { return }
            let allowed = await requestAuthorizationIfNeeded()
            if allowed { await register(with: profile) }
        }
    }

    /// The server's address or token changed: register again.
    func serverEndpointChanged(_ profile: ServerProfile) {
        PushServerIndex.forget(profile.id)
        Task { await register(with: profile) }
    }

    /// A server is being removed: tell it to forget this phone.
    func serverRemoved(_ profile: ServerProfile, client: CodegClient?) {
        let entry = PushServerIndex.entry(for: profile.id)
        PushServerIndex.forget(profile.id)
        serverErrors[profile.id] = nil
        guard let client, let token = entry?.token ?? deviceToken else { return }
        Task { try? await client.unregisterPushDevice(token: token) }
    }

    /// Register this phone with every saved server.
    func registerAll() async {
        guard enabled, isAllowed, deviceToken != nil else { return }
        let profiles = ServerStore.persistedServers()
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.register(with: profile) }
            }
        }
        registrationTick &+= 1
    }

    func register(with profile: ServerProfile) async {
        guard enabled, isAllowed, let token = deviceToken,
              let client = ServerStore.makeClient(for: profile) else { return }
        let previous = PushServerIndex.entry(for: profile.id)
        do {
            // The token changed since this server last saw it: drop the old row.
            if let old = previous?.token, old != token {
                _ = try? await client.unregisterPushDevice(token: old)
            }
            let result = try await client.registerPushDevice(
                token: token,
                environment: APNsEnvironment.current,
                bundleId: Bundle.main.bundleIdentifier ?? "io.ashurov.codeg",
                name: UIDevice.current.name
            )
            PushServerIndex.save(PushServerIndex.Entry(
                serverID: result.serverId, deviceID: result.device.id, token: token), for: profile.id)
            serverErrors[profile.id] = nil
            log.info("Registered for push with \(profile.displayHost, privacy: .public)")
        } catch {
            serverErrors[profile.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Push registration with \(profile.displayHost, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forget this phone on every saved server (notifications turned off).
    func unregisterAll() async {
        let token = deviceToken
        let profiles = ServerStore.persistedServers()
        var targets: [(CodegClient, String)] = []
        for profile in profiles {
            let entry = PushServerIndex.entry(for: profile.id)
            if let client = ServerStore.makeClient(for: profile), let t = entry?.token ?? token {
                targets.append((client, t))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for (client, t) in targets {
                group.addTask { _ = try? await client.unregisterPushDevice(token: t) }
            }
        }
        for profile in profiles { PushServerIndex.forget(profile.id) }
        registrationTick &+= 1
    }

    // MARK: - Notification responses

    /// Whether a push arriving in the foreground shows: not when it is about
    /// the session on screen.
    func presentationOptions(for payload: PushPayload?) -> UNNotificationPresentationOptions {
        let all: UNNotificationPresentationOptions = [.banner, .list, .sound, .badge]
        guard let payload else { return all }
        let visible = PresenceTracker.shared.visible
        let saved = ServerStore.persistedServers().map(\.id)
        if PushRouting.isAboutVisibleSession(payload, visibleServer: visible?.serverProfileID,
                                             visibleConversation: visible?.conversationID,
                                             recorded: PushServerIndex.serverIDs(), saved: saved) {
            return []
        }
        return all
    }

    /// A tap or an action button.
    func handle(actionIdentifier: String, payload: PushPayload) async {
        let action = PushRouting.action(for: actionIdentifier, payload: payload)
        let saved = ServerStore.persistedServers()
        guard let profileID = PushRouting.serverProfileID(
                for: payload.serverID, recorded: PushServerIndex.serverIDs(), saved: saved.map(\.id)),
              let profile = saved.first(where: { $0.id == profileID }) else {
            log.error("Push from an unknown server \(payload.serverID ?? "-", privacy: .public)")
            return
        }
        let client = ServerStore.makeClient(for: profile)
        switch action {
        case .open(let conversationID, let folderID):
            PushRouter.shared.open(serverProfileID: profile.id, conversationID: conversationID, folderID: folderID)
            // Opening a critical session acknowledges its alert, as on the desktop.
            if payload.kind == "critical" {
                try? await client?.ackCriticalSession(conversationId: conversationID)
            }
        case .ack(let conversationID):
            try? await client?.ackCriticalSession(conversationId: conversationID)
        case .snooze(let conversationID, let minutes):
            try? await client?.snoozeCriticalSession(conversationId: conversationID, minutes: minutes)
        case .approve(let connectionID, let requestID, let optionID):
            do {
                guard let client else { throw APIError.unauthorized }
                try await client.respondPermission(connectionId: connectionID, requestId: requestID, optionId: optionID)
            } catch {
                // Answered elsewhere, or its connection is gone.
                await postAlreadyHandled(payload)
            }
        case .none:
            break
        }
    }

    /// "Already handled": a local notification whose tap opens the session.
    private func postAlreadyHandled(_ payload: PushPayload) async {
        let content = UNMutableNotificationContent()
        content.title = "Already handled"
        content.body = "That permission request was answered elsewhere or has ended. Tap to open the session."
        content.categoryIdentifier = PushCategory.session
        if let thread = payload.threadID { content.threadIdentifier = thread }
        content.userInfo = payload.routingUserInfo.merging(["kind": "already_handled"]) { _, new in new }
        let request = UNNotificationRequest(identifier: "already-handled-\(UUID().uuidString)", content: content,
                                            trigger: nil)
        try? await center.add(request)
    }

    // MARK: - Categories

    static var categories: Set<UNNotificationCategory> {
        let open = UNNotificationAction(identifier: PushActionID.open, title: "Open", options: [.foreground],
                                        icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        let ack = UNNotificationAction(identifier: PushActionID.ack, title: "Acknowledge", options: [],
                                       icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        let snooze = UNNotificationAction(identifier: PushActionID.snooze, title: "Snooze 15 min", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "moon.zzz"))
        let approve = UNNotificationAction(identifier: PushActionID.approve, title: "Approve",
                                           options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "checkmark.shield"))
        return [
            UNNotificationCategory(identifier: PushCategory.critical, actions: [ack, snooze, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.permission, actions: [approve, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategory.session, actions: [open],
                                   intentIdentifiers: [], options: []),
        ]
    }
}

/// Which APNs environment this build's tokens belong to. A build signed with
/// a development profile (run from Xcode) carries `aps-environment =
/// development` in its embedded profile and gets sandbox tokens. TestFlight and
/// App Store builds carry no embedded profile (or a distribution one) and get
/// production tokens. Without a profile (the simulator), the compile flag
/// decides: Debug is sandbox.
enum APNsEnvironment {
    static let current: String = {
        if let env = provisioningAPSEnvironment() {
            return env == "development" ? "sandbox" : "production"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()

    private static func provisioningAPSEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let xml = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}

/// Each saved server's codeg push identity (`server_id`), this device's row id
/// there, and the token it was registered with. Keyed by the server profile.
enum PushServerIndex {
    struct Entry: Codable, Equatable {
        var serverID: String
        var deviceID: Int
        var token: String
    }

    private static let key = "codeg.push.servers.v1"

    static func all() -> [UUID: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        var out: [UUID: Entry] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }

    static func entry(for profileID: UUID) -> Entry? { all()[profileID] }

    static func serverIDs() -> [UUID: String] { all().mapValues(\.serverID) }

    static func save(_ entry: Entry, for profileID: UUID) {
        var map = all()
        map[profileID] = entry
        write(map)
    }

    static func forget(_ profileID: UUID) {
        var map = all()
        guard map.removeValue(forKey: profileID) != nil else { return }
        write(map)
    }

    private static func write(_ map: [UUID: Entry]) {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// A session to open because a notification was tapped. `RootView` picks it
/// up (also after a cold launch from the notification).
@MainActor
@Observable
final class PushRouter {
    static let shared = PushRouter()

    struct Request: Equatable, Identifiable {
        let id = UUID()
        let serverProfileID: UUID
        let conversationID: Int
        let folderID: Int?
    }

    private(set) var pending: Request?

    private init() {}

    func open(serverProfileID: UUID, conversationID: Int, folderID: Int?) {
        pending = Request(serverProfileID: serverProfileID, conversationID: conversationID, folderID: folderID)
    }

    /// Hand the pending request to the caller, once.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// `UNUserNotificationCenterDelegate`, kept off the main actor so its
/// requirements match whatever isolation the SDK declares; it reads the
/// payload, then hops to `PushRegistration` on the main actor.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        return await PushRegistration.shared.presentationOptions(for: payload)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let actionID = response.actionIdentifier
        guard let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
        await PushRegistration.shared.handle(actionIdentifier: actionID, payload: payload)
    }
}

/// UIKit app delegate, attached through `@UIApplicationDelegateAdaptor` for
/// the callbacks SwiftUI has no equivalent for (APNs registration).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushRegistration.shared.appDidLaunch()
        // Reconnect speech-model downloads that were running at the last quit.
        SpeechModelStores.resumeActiveDownloads()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistration.shared.didFailToRegister(error)
    }

    /// Model downloads run in a background `URLSession`; iOS relaunches the
    /// app to deliver their events.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == VoiceModelCatalog.pack.sessionIdentifier {
            VoiceModelStore.shared.handleBackgroundEvents(completion: completionHandler)
        } else if let store = SpeechModelStores.store(forSessionIdentifier: identifier) {
            store.handleBackgroundEvents(completion: completionHandler)
        } else {
            completionHandler()
        }
    }
}
