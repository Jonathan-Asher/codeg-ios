import Foundation
import Observation

/// What the app says about its link to the server, with the rules of codeg
/// web's `src/lib/connection-display.ts`: never as a modal, and never by
/// taking content away. On the phone it is a capsule under the navigation
/// bar (``ConnectionCapsule``).
enum ConnectionDisplay: Equatable, Sendable {
    case none
    /// Down for a second or more, under ten seconds of the app being in
    /// front: "Reconnecting…".
    case reconnecting
    /// Down ten seconds or more in front, or no network at all: "Offline ·
    /// updated 3 min ago".
    case offline
    /// Back, and the first refresh after the outage has run for half a
    /// second or more: "Updating…".
    case updating
    /// For two seconds after any of the above: "Back online".
    case backOnline
}

struct ConnectionDisplayInputs: Equatable, Sendable {
    /// The server can't be reached right now: no network, a list refresh
    /// that couldn't reach it, or a session's socket reconnecting.
    var down: Bool
    /// Back, and the first refresh after the outage runs.
    var syncing: Bool
    /// The phone has a network.
    var online: Bool
    /// The app is in front.
    var visible: Bool
}

/// Turns the inputs into what shows, and when to look again. Down time is
/// counted only while the app is in front, so coming back from the
/// background resyncs quietly first. Unlike the web, no network at all also
/// waits the second before showing, since a switch from Wi-Fi to LTE can
/// report none for a moment.
struct ConnectionDisplayTracker {
    static let pillDelay: TimeInterval = 1
    static let offlineAfter: TimeInterval = 10
    static let updatingAfter: TimeInterval = 0.5
    static let backOnlineFor: TimeInterval = 2

    /// When the current stretch of down time in front began.
    private var visibleDownSince: Date?
    private var syncingSince: Date?
    /// This outage showed something, so its end says "Back online".
    private(set) var shown = false
    private var backOnlineUntil = Date.distantPast

    mutating func update(_ input: ConnectionDisplayInputs, now: Date) -> (display: ConnectionDisplay, nextAt: Date?) {
        if !input.down || !input.visible {
            visibleDownSince = nil
        } else if visibleDownSince == nil {
            visibleDownSince = now
        }

        if input.down {
            guard let since = visibleDownSince else { return (.none, nil) }
            let downFor = now.timeIntervalSince(since)
            if downFor < Self.pillDelay { return (.none, since + Self.pillDelay) }
            shown = true
            if !input.online || downFor >= Self.offlineAfter { return (.offline, nil) }
            return (.reconnecting, since + Self.offlineAfter)
        }

        if input.syncing {
            let start = syncingSince ?? now
            syncingSince = start
            // Straight on from the capsule; otherwise only once slow.
            if shown || now.timeIntervalSince(start) >= Self.updatingAfter {
                shown = true
                return (.updating, nil)
            }
            return (.none, start + Self.updatingAfter)
        }
        syncingSince = nil

        if shown {
            shown = false
            backOnlineUntil = now + Self.backOnlineFor
        }
        if now < backOnlineUntil { return (.backOnline, backOnlineUntil) }
        return (.none, nil)
    }
}

/// The app's link state, from the network path (``ConnectivityMonitor``),
/// the list pulse (``ActivityModel``) and the session screens' sockets.
@MainActor
@Observable
final class LinkStatus {
    static let shared = LinkStatus(connectivity: .shared)

    private(set) var display: ConnectionDisplay = .none
    /// When the server last gave the lists; opened offline, the saved lists'
    /// date. What the offline capsule calls "updated".
    private(set) var lastContact: Date?

    @ObservationIgnored private let connectivity: ConnectivityMonitor?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tracker = ConnectionDisplayTracker()
    @ObservationIgnored private var pulseDown = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var downStreams: Set<ObjectIdentifier> = []
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var observation: ConnectivityObservation?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var evaluationQueued = false

    init(connectivity: ConnectivityMonitor?, now: @escaping () -> Date = Date.init) {
        self.connectivity = connectivity
        self.now = now
        observation = connectivity?.observe { [weak self] event in self?.networkChanged(event) }
    }

    var inputs: ConnectionDisplayInputs {
        let online = connectivity?.isOnline ?? true
        return ConnectionDisplayInputs(down: !online || pulseDown || !downStreams.isEmpty,
                                       syncing: recovering && refreshing, online: online, visible: visible)
    }

    // MARK: - Inputs

    /// A list refresh started.
    func pulseStarted() {
        refreshing = true
        changed()
    }

    /// A list refresh brought the lists.
    func pulseSucceeded(at date: Date = Date()) {
        refreshing = false
        pulseDown = false
        recovering = false
        lastContact = date
        changed()
    }

    /// A list refresh failed. `unreachable`: it couldn't reach the server
    /// (a server that answered with an error is up).
    func pulseFailed(unreachable: Bool) {
        refreshing = false
        pulseDown = unreachable
        changed()
    }

    /// A list refresh was cancelled or superseded.
    func pulseEnded() {
        refreshing = false
        changed()
    }

    /// The lists on screen are the saved copy from `savedAt`.
    func showingSavedLists(savedAt: Date) {
        if lastContact.map({ $0 < savedAt }) ?? true { lastContact = savedAt }
    }

    /// A session screen's socket is reconnecting (`down`), or attached again.
    func setStream(_ id: ObjectIdentifier, down: Bool) {
        let changedSet = down ? downStreams.insert(id).inserted : downStreams.remove(id) != nil
        if changedSet { changed() }
    }

    func setVisible(_ isVisible: Bool) {
        guard visible != isVisible else { return }
        visible = isVisible
        changed()
    }

    private func networkChanged(_ event: ConnectivityMonitor.Event) {
        if event == .cameOnline {
            // The failures were the network's; the refresh it triggers decides.
            pulseDown = false
            recovering = tracker.shown
        }
        changed()
    }

    // MARK: - Evaluation

    /// Inputs that change together in one pass (a socket closed and its
    /// reconnect scheduled) are judged once.
    private func changed() {
        guard !evaluationQueued else { return }
        evaluationQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.evaluationQueued = false
            self.evaluate()
        }
    }

    /// Judge the inputs now, and look again when the tracker asks.
    func evaluate() {
        let result = tracker.update(inputs, now: now())
        if display != result.display { display = result.display }
        timer?.cancel()
        timer = nil
        guard let nextAt = result.nextAt else { return }
        let delay = max(0, nextAt.timeIntervalSince(now()))
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
