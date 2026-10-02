import UIKit
import os

/// Remote-notification plumbing. For now it only obtains the APNs device
/// token on launch (no permission prompt is shown: registering for a token
/// does not need one). Asking for alert permission and handing the token to
/// the codeg server, so it can push turn-complete and approval alerts, comes
/// with the server's push endpoint.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Hex-encoded APNs device token, once iOS has issued one.
    private(set) var deviceToken: String?
    /// The last registration failure, e.g. an unsigned simulator build that
    /// carries no `aps-environment` entitlement.
    private(set) var lastError: String?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg", category: "push")

    private init() {}

    func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        lastError = nil
        log.info("APNs device token received (\(String(token.prefix(8)), privacy: .public)...)")
    }

    func didFailToRegister(_ error: Error) {
        lastError = error.localizedDescription
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// UIKit app delegate, attached through `@UIApplicationDelegateAdaptor` for
/// the callbacks SwiftUI has no equivalent for (APNs registration).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushRegistration.shared.register()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistration.shared.didFailToRegister(error)
    }
}
