import UIKit

/// A `beginBackgroundTask` assertion, ended once: by ``end()``, or when iOS
/// says the time is up. A notification's button and the end of a Talk hold one.
@MainActor
final class BackgroundTime {
    private var task = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
