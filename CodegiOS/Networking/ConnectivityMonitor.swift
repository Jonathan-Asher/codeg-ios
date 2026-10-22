import Foundation
import Network
import Observation

/// The phone's network path, reduced to what the app acts on.
struct NetworkPath: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// No report yet (the first arrives within moments of starting).
        case unknown
        case satisfied
        case unsatisfied
    }

    var status: Status
    /// The kinds of interface the path uses ("wifi", "cellular", …), to tell
    /// a switch from Wi-Fi to LTE from no change at all.
    var interfaces: Set<String> = []

    static let unknown = NetworkPath(status: .unknown)
}

extension NetworkPath {
    init(_ path: NWPath) {
        switch path.status {
        case .unsatisfied:
            status = .unsatisfied
        default:
            // `.requiresConnection` (an on-demand VPN, say) means a connection
            // attempt may bring the path up, so attempts are not held back.
            status = .satisfied
        }
        let kinds: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"),
        ]
        interfaces = Set(kinds.filter { path.usesInterfaceType($0.0) }.map(\.1))
    }
}

/// Where path reports come from: `NWPathMonitor` in the app, the unit tests'
/// own reports otherwise.
protocol NetworkPathSource: AnyObject {
    func start(_ onUpdate: @escaping @Sendable (NetworkPath) -> Void)
    func cancel()
}

/// The system's path monitor.
final class SystemNetworkPathSource: NetworkPathSource {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "codeg.connectivity", qos: .utility)

    func start(_ onUpdate: @escaping @Sendable (NetworkPath) -> Void) {
        monitor.pathUpdateHandler = { path in onUpdate(NetworkPath(path)) }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }
}

/// Whether the phone has a network, from `NWPathMonitor`.
///
/// What depends on it:
/// - a session's event socket makes no reconnect attempt while there is no
///   network, and tries at once when it is back (``SessionDetailViewModel``);
/// - a change of network (Wi-Fi to LTE) checks the open socket with a short
///   deadline instead of dropping it, since a tunnelled connection often
///   survives the switch (``EventStream/checkLink()``);
/// - the list pulse waits for the network instead of hanging on requests
///   that wait for connectivity (``ActivityModel``);
/// - the connection capsule says "Offline" (``ConnectionStatus``).
///
/// A path being up doesn't mean the server can be reached (the box can be
/// off while the tailnet is up), so nothing treats `isOnline` as proof of
/// that; only the absence of a network holds attempts back.
@MainActor
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor(source: SystemNetworkPathSource())

    enum Event: Equatable, Sendable {
        case wentOffline
        case cameOnline
        /// Still online, over another kind of interface.
        case pathChanged
    }

    private(set) var path = NetworkPath.unknown
    /// When the phone lost its network; nil while it has one.
    private(set) var offlineSince: Date?

    /// No network attempt is worth making while this is false. An unknown
    /// path counts as online: nothing is held back before the first report.
    var isOnline: Bool { path.status != .unsatisfied }

    @ObservationIgnored private let source: NetworkPathSource?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observers: [UUID: @MainActor (Event) -> Void] = [:]
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// `source` nil: reports come only through ``apply(_:)`` (the unit tests).
    init(source: NetworkPathSource?, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
        source?.start { [weak self] update in
            guard let self else { return }
            Task { @MainActor in self.apply(update) }
        }
    }

    /// What a new report means, given the last one. The first report only
    /// sets the state, unless it says there is no network.
    nonisolated static func event(from old: NetworkPath, to new: NetworkPath) -> Event? {
        switch (old.status, new.status) {
        case (.unsatisfied, .satisfied):
            return .cameOnline
        case (.satisfied, .unsatisfied), (.unknown, .unsatisfied):
            return .wentOffline
        case (.satisfied, .satisfied):
            return old.interfaces == new.interfaces ? nil : .pathChanged
        default:
            return nil
        }
    }

    /// Take a path report.
    func apply(_ update: NetworkPath) {
        let event = Self.event(from: path, to: update)
        path = update
        switch event {
        case .wentOffline?:
            offlineSince = now()
        case .cameOnline?:
            offlineSince = nil
            let resumed = waiters
            waiters.removeAll()
            for waiter in resumed.values { waiter.resume() }
        case .pathChanged?, nil:
            break
        }
        if let event {
            for observer in Array(observers.values) { observer(event) }
        }
    }

    /// Returns once the phone has a network (at once if it has one), or when
    /// the calling task is cancelled.
    func waitUntilOnline() async {
        guard !isOnline else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOnline || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.releaseWaiter(id) }
        }
    }

    private func releaseWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Calls `handler` with every change until the returned token is released.
    func observe(_ handler: @escaping @MainActor (Event) -> Void) -> ConnectivityObservation {
        let id = UUID()
        observers[id] = handler
        return ConnectivityObservation { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.removeObserver(id) }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

/// Keeps a ``ConnectivityMonitor`` observer registered while it lives.
final class ConnectivityObservation {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    deinit { cancel() }
}
