import Foundation
import Observation

/// Reports to the codeg server that this phone is looking at one session, so
/// the server does not push notifications about it while it is on screen
/// (codeg fork `crate::presence`, `docs/ios-push.md` §7).
///
/// An iOS client never counts as "someone at the desk" (the phone is where
/// alerts go when the user is away), only as looking at the session it shows.
/// The report rides its own event socket, declared iOS with the
/// `codeg-client.ios` subprotocol, opened only while a session is on screen
/// and the app is in the foreground. It repeats every 25 s (the server drops
/// reports older than 90 s) and says `visible: false` before closing.
@MainActor
final class SessionPresenceReporter {
    private let baseURL: URL
    private let token: String
    private var stream: EventStream?
    private var consumer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var conversationID: Int?
    private var looking = false
    private var ready = false

    private static let heartbeatInterval: Duration = .seconds(25)

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// `looking`: the session's screen is visible and the app is active.
    func update(conversationID: Int?, looking: Bool) {
        let want = looking && conversationID != nil
        let changed = want != self.looking || conversationID != self.conversationID
        self.conversationID = conversationID
        self.looking = want
        if want {
            if stream == nil { open() } else if changed { report() }
        } else if stream != nil {
            report()
            close()
        }
    }

    func stop() {
        looking = false
        if stream != nil {
            report()
            close()
        }
    }

    // MARK: - Socket

    private func open() {
        reconnect?.cancel()
        reconnect = nil
        ready = false
        let newStream = EventStream(baseURL: baseURL, token: token)
        stream = newStream
        newStream.start()
        consumer = Task { [weak self] in
            for await frame in newStream.frames {
                guard let self, self.stream === newStream else { return }
                switch frame {
                case .ready:
                    self.ready = true
                    self.report()
                    self.startHeartbeat()
                case .closed:
                    self.ready = false
                    self.stream = nil
                    self.heartbeat?.cancel()
                    self.scheduleReconnect()
                    return
                default:
                    break
                }
            }
        }
    }

    private func close() {
        heartbeat?.cancel()
        heartbeat = nil
        reconnect?.cancel()
        reconnect = nil
        consumer?.cancel()
        consumer = nil
        stream?.close()
        stream = nil
        ready = false
    }

    private func report() {
        guard ready, let stream else { return }
        let ids = looking ? conversationID.map { [$0] } ?? [] : []
        stream.reportPresence(visible: looking, focused: looking, idleSecs: 0, conversationIds: ids)
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                self.report()
            }
        }
    }

    private func scheduleReconnect() {
        guard looking else { return }
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.looking, self.stream == nil else { return }
            self.open()
        }
    }
}

/// Which session is on screen right now, app-wide, so a push about that very
/// session is not also shown as a banner while the app is in the foreground.
@MainActor
@Observable
final class PresenceTracker {
    static let shared = PresenceTracker()

    struct Visible: Equatable {
        let serverProfileID: UUID
        let conversationID: Int
    }

    private(set) var visible: Visible?

    private init() {}

    func show(serverProfileID: UUID, conversationID: Int?) {
        guard let conversationID else { return }
        let next = Visible(serverProfileID: serverProfileID, conversationID: conversationID)
        if visible != next { visible = next }
    }

    /// Clear, unless another screen has already taken over.
    func hide(serverProfileID: UUID, conversationID: Int?) {
        guard let current = visible, current.serverProfileID == serverProfileID,
              conversationID == nil || current.conversationID == conversationID else { return }
        visible = nil
    }

    func isShowing(serverProfileID: UUID, conversationID: Int) -> Bool {
        visible == Visible(serverProfileID: serverProfileID, conversationID: conversationID)
    }
}
