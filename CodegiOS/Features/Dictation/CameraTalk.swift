import Foundation

// "Camera Control to talk": while a session is open, hold the Camera Control
// (or a volume button) to record, and let go to transcribe, clean up and send.
// iOS hands those buttons to an app through AVCaptureEventInteraction only
// while the app is in the foreground with a running AVCaptureSession, so the
// mode keeps a minimal capture session running while it is on. This file holds
// the pure parts: the press state machine, when the mode may run, and its
// settings. CameraTalkController runs the camera; CameraTalkViews hosts the
// interaction.

/// Settings for Camera Control to talk.
enum CameraTalkPrefs {
    private static let defaults = UserDefaults.standard

    /// The toolbar switch in a session, remembered across launches.
    static var enabled: Bool {
        get { defaults.bool(forKey: "codeg.cameraTalk.enabled") }
        set { defaults.set(newValue, forKey: "codeg.cameraTalk.enabled") }
    }

    /// The explanation before the first camera permission request was shown.
    static var introShown: Bool {
        get { defaults.bool(forKey: "codeg.cameraTalk.introShown") }
        set { defaults.set(newValue, forKey: "codeg.cameraTalk.introShown") }
    }

    /// Show a small live camera preview in the indicator. Off by default; for
    /// the case where iOS turns out to deliver the buttons only to an app that
    /// shows its camera.
    static var showPreview: Bool {
        get { defaults.bool(forKey: "codeg.cameraTalk.showPreview") }
        set { defaults.set(newValue, forKey: "codeg.cameraTalk.showPreview") }
    }
}

/// Hold-to-talk on the hardware buttons. `primary` is the Camera Control, the
/// volume-down button and the Action button (iOS doesn't say which); the
/// `secondary` button is volume up. Either one is a talk key:
///
/// - press (`began`) starts recording;
/// - release (`ended`) sends, unless the press was shorter than
///   ``minimumHold``, which throws the recording away;
/// - `cancelled` throws it away;
/// - pressing the other button while one is held throws the recording away,
///   and nothing more happens until both are released.
struct CameraTalkPress: Equatable, Sendable {
    /// Shorter presses are clicks, not speech.
    static let minimumHold: TimeInterval = 0.3

    enum Source: String, Hashable, Sendable {
        case primary
        case secondary
    }

    enum Phase: String, Sendable {
        case began
        case ended
        case cancelled
    }

    enum Discard: String, Equatable, Sendable {
        case tooShort
        case cancelled
        case otherButton
    }

    enum Action: Equatable, Sendable {
        case none
        /// Start recording.
        case start
        /// Stop, transcribe and send.
        case finish
        /// Stop and throw the recording away.
        case discard(Discard)
    }

    private enum State: Equatable, Sendable {
        case idle
        case holding(Source, since: TimeInterval)
        /// A press was thrown away; wait until these buttons are released.
        case draining(Set<Source>)
    }

    private var state = State.idle

    /// A talk key is down and its recording is wanted.
    var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    mutating func handle(_ phase: Phase, from source: Source, at time: TimeInterval) -> Action {
        switch (state, phase) {
        case (.idle, .began):
            state = .holding(source, since: time)
            return .start
        case (.idle, _):
            return .none

        case (.holding(let held, _), .began):
            if held == source { return .none }
            state = .draining([held, source])
            return .discard(.otherButton)
        case (.holding(let held, let since), .ended):
            guard held == source else { return .none }
            state = .idle
            return time - since < Self.minimumHold ? .discard(.tooShort) : .finish
        case (.holding(let held, _), .cancelled):
            guard held == source else { return .none }
            state = .idle
            return .discard(.cancelled)

        case (.draining(var down), .began):
            down.insert(source)
            state = .draining(down)
            return .none
        case (.draining(var down), .ended), (.draining(var down), .cancelled):
            down.remove(source)
            state = down.isEmpty ? .idle : .draining(down)
            return .none
        }
    }

    /// The press ended some other way (the mode turned off, the app left the
    /// screen). Later events for it are ignored until a fresh press.
    mutating func reset() { state = .idle }
}

/// When the capture session may run: the mode is on, the camera is allowed,
/// the app is active, and a session screen is visible in an active scene with
/// nothing else using the camera. With several session screens (a pushed
/// session, iPad windows), the one that became visible last owns it.
struct CameraTalkGate: Equatable, Sendable {
    struct Presence: Equatable, Sendable {
        /// The session screen's composer is on screen.
        var visible: Bool
        /// Its scene is `.active` (not inactive or in the background).
        var sceneActive: Bool
        /// Something on that screen is using the camera itself (taking a
        /// photo for an attachment).
        var suspended: Bool = false
    }

    var enabled = false
    var cameraAuthorized = false
    /// The app is active (not resigning active or in the background).
    var appActive = true

    private(set) var presences: [UUID: Presence] = [:]
    /// Owners in the order they last became visible.
    private(set) var order: [UUID] = []

    mutating func update(_ owner: UUID, _ presence: Presence) {
        let wasVisible = presences[owner]?.visible ?? false
        presences[owner] = presence
        if !order.contains(owner) || (presence.visible && !wasVisible) {
            order.removeAll { $0 == owner }
            order.append(owner)
        }
    }

    mutating func remove(_ owner: UUID) {
        presences[owner] = nil
        order.removeAll { $0 == owner }
    }

    /// The visible session screen that gets the buttons.
    var activeOwner: UUID? {
        order.last { presences[$0]?.visible == true }
    }

    var shouldRun: Bool {
        guard enabled, cameraAuthorized, appActive,
              let owner = activeOwner, let presence = presences[owner] else { return false }
        return presence.sceneActive && !presence.suspended
    }

    /// `owner` should receive the buttons now.
    func isLive(_ owner: UUID) -> Bool {
        shouldRun && activeOwner == owner
    }

    /// One line for the log.
    var summary: String {
        let owner = activeOwner.map { String($0.uuidString.prefix(8)) } ?? "none"
        let presence = activeOwner.flatMap { presences[$0] }
        return "enabled=\(enabled) camera=\(cameraAuthorized) appActive=\(appActive) owner=\(owner) "
            + "sceneActive=\(presence?.sceneActive ?? false) suspended=\(presence?.suspended ?? false) "
            + "screens=\(presences.count) run=\(shouldRun)"
    }
}
