import Foundation

/// `codeg://` session links (``SessionLink``): the session they name, opened
/// on the saved server they name, as the desktop app opens them.
extension AppModel {
    /// How long a link waits for the saved servers to say who they are,
    /// when its `server` matched none of them.
    static let sessionLinkProbeTimeout: Duration = .seconds(6)

    /// Open the session `url` links to: find its server (the one shown,
    /// without `server`), look the session up there, switch to that server
    /// and open it on top of the screen you were on. An unknown server or a
    /// missing session says so in an alert.
    func openSessionLink(_ url: URL) async {
        guard let link = SessionLink.parse(url.absoluteString) else { return }
        guard let server = await sessionLinkServer(for: link) else { return }
        guard let client = serverStore.client(for: server) else {
            sessionLinkAlert(String(localized: "Can’t Open the Session"),
                             String(localized: "“\(server.name)” has no address or token saved."))
            return
        }
        let lookup = link.lookup
        let result: SessionLinkLookup
        do {
            result = try await client.resolveSessionLink(ref: lookup.ref, folderID: lookup.folderID,
                                                         agent: lookup.agent)
        } catch {
            // The server didn't answer: a link by codeg's own id still opens,
            // and the session screen says what it can.
            if let id = Int(lookup.ref) {
                openFromPush(serverID: server.id, conversationID: id)
            } else {
                sessionLinkAlert(String(localized: "Can’t Open the Session"),
                                 String(localized: "“\(server.name)” couldn’t be reached."))
            }
            return
        }
        switch result {
        case .found(let id):
            openFromPush(serverID: server.id, conversationID: id)
        case .unsupported:
            // A server from before session links: codeg's own id is all it
            // takes.
            if let id = Int(lookup.ref) {
                openFromPush(serverID: server.id, conversationID: id)
            } else {
                sessionLinkNotFound(on: server)
            }
        case .notFound:
            sessionLinkNotFound(on: server)
        }
    }

    /// The saved server a link is for: the one shown when it names none,
    /// else the one its `server` matches (``SessionLinkMatch``). When none
    /// matches, every saved server is asked who it is (a few seconds at
    /// most) and matched once more.
    func sessionLinkServer(for link: SessionLink) async -> ServerProfile? {
        guard let wanted = link.server else {
            if let selected = selectedServer { return selected }
            sessionLinkAlert(String(localized: "Can’t Open the Session"),
                             String(localized: "Add a server first, then open the link again."))
            return nil
        }
        if let server = matchSessionLinkServer(wanted) { return server }
        await learnServerIdentities(of: serverStore.servers, timeout: Self.sessionLinkProbeTimeout)
        if let server = matchSessionLinkServer(wanted) { return server }
        sessionLinkAlert(String(localized: "Unknown Server"),
                         String(localized: "No saved server matches “\(wanted)”. Add it in Manage Servers, then open the link again."))
        return nil
    }

    private func matchSessionLinkServer(_ wanted: String) -> ServerProfile? {
        let candidates = serverStore.servers.map { server in
            SessionLinkServer(id: server.id, name: server.name, baseURL: server.baseURL,
                              identity: serverIdentities.identity(for: server))
        }
        guard let id = SessionLinkMatch.server(wanted, in: candidates) else { return nil }
        return serverStore.servers.first { $0.id == id }
    }

    private func sessionLinkNotFound(on server: ServerProfile) {
        sessionLinkAlert(String(localized: "Session Not Found"),
                         String(localized: "The session this link names isn’t on “\(server.name)”. It may have been deleted."))
    }

    private func sessionLinkAlert(_ title: String, _ message: String) {
        actions.alert = SessionActionAlert(title: title, message: message)
    }

    // MARK: - Who the servers are

    /// Ask the shown server who it is (on every activation; it is cheap).
    func learnSelectedServerIdentity() async {
        guard let server = selectedServer else { return }
        await learnServerIdentities(of: [server], timeout: .seconds(20))
    }

    /// Ask `servers` who they are, at once, giving up on the ones that
    /// haven't answered after `timeout`.
    func learnServerIdentities(of servers: [ServerProfile], timeout: Duration) async {
        let probes: [(UUID, CodegClient)] = servers.compactMap { server in
            serverStore.client(for: server).map { (server.id, $0) }
        }
        guard !probes.isEmpty else { return }
        var answers: [(UUID, HealthResponse)] = []
        await withTaskGroup(of: (UUID, HealthResponse?)?.self) { group in
            for (id, client) in probes {
                group.addTask { (id, try? await client.health()) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            var pending = probes.count
            for await result in group {
                guard let result else { break }
                if let health = result.1 { answers.append((result.0, health)) }
                pending -= 1
                if pending == 0 { break }
            }
            group.cancelAll()
        }
        for (id, health) in answers {
            guard let server = serverStore.servers.first(where: { $0.id == id }) else { continue }
            serverIdentities.record(health, for: server)
            if (health.imagePreviews ?? 0) >= 1, let client = serverStore.client(for: server) {
                TranscriptSync.notePreviews(serverKey: TranscriptCache.serverKey(for: client))
            }
        }
    }
}
