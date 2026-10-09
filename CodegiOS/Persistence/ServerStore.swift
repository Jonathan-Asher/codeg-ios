import Foundation
import Observation

/// Observable store of saved server profiles. Owns persistence (UserDefaults
/// for metadata, Keychain for tokens) and vends `CodegClient`s. Main-actor
/// isolated since it backs SwiftUI state.
@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [ServerProfile]

    private let defaults: UserDefaults
    private let storageKey = ServerStore.storageKey
    static let storageKey = "codeg.servers.v1"

    /// Called after any change to the saved servers or their tokens (the app
    /// drops cached transcripts of an endpoint or token that is gone).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Builds clients instead of the Keychain path (tests point the app at an
    /// in-process mock server this way).
    @ObservationIgnored var clientFactory: (@MainActor (ServerProfile) -> CodegClient?)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.servers = ServerStore.load(from: defaults, key: storageKey)
    }

    /// The saved servers as persisted right now, without an instance. Push
    /// registration reads these so it always sees the latest list, whichever
    /// window's store last saved it.
    static func persistedServers(defaults: UserDefaults = .standard) -> [ServerProfile] {
        load(from: defaults, key: storageKey)
    }

    /// A client for `profile` from its persisted token (see `client(for:)`).
    static func makeClient(for profile: ServerProfile) -> CodegClient? {
        guard let baseURL = profile.baseURL, let token = Keychain.token(for: profile.id) else { return nil }
        return CodegClient(baseURL: baseURL, token: token)
    }

    // MARK: - Mutations

    /// Add a new server. Returns the created profile, or `nil` if the token
    /// could not be persisted securely — in which case nothing is added, so the
    /// list never holds a server whose token silently failed to save.
    @discardableResult
    func add(name: String, urlString: String, token: String) -> ServerProfile? {
        let profile = ServerProfile(name: name, urlString: urlString)
        guard Keychain.setToken(token, for: profile.id) else { return nil }
        servers.append(profile)
        persist()
        // A server was just added: the moment to ask for notification
        // permission, and to hand this phone's push token to the server.
        PushRegistration.shared.serverAdded(profile)
        return profile
    }

    /// Update a server's metadata and, if `token` is non-empty, its secret.
    /// A nil/empty `token` means "keep the existing token unchanged" — including
    /// when the endpoint changed, since editing a server's address (e.g. it moved
    /// to a new IP) shouldn't force the user to re-paste a token they want to
    /// reuse. Returns `false` (and leaves the stored profile untouched) when a
    /// provided token fails to persist, so we never bind new host metadata to a
    /// lost token.
    @discardableResult
    func update(_ profile: ServerProfile, token: String?) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return false }
        if let token, !token.isEmpty {
            // Store the new secret first; abort the whole update if it fails.
            guard Keychain.setToken(token, for: profile.id) else { return false }
        }
        let endpointChanged = servers[index].urlString != profile.urlString || !(token ?? "").isEmpty
        servers[index] = profile
        persist()
        if endpointChanged { PushRegistration.shared.serverEndpointChanged(profile) }
        return true
    }

    func delete(_ profile: ServerProfile) {
        // Take the client before the token is gone: the server must forget
        // this phone's push token.
        PushRegistration.shared.serverRemoved(profile, client: client(for: profile))
        servers.removeAll { $0.id == profile.id }
        Keychain.deleteToken(for: profile.id)
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let profile = servers[index]
            PushRegistration.shared.serverRemoved(profile, client: client(for: profile))
            Keychain.deleteToken(for: profile.id)
        }
        servers.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Access

    func token(for profile: ServerProfile) -> String? {
        Keychain.token(for: profile.id)
    }

    /// Build an HTTP client for a profile, or nil if the URL/token is missing.
    func client(for profile: ServerProfile) -> CodegClient? {
        if let clientFactory { return clientFactory(profile) }
        guard let baseURL = profile.baseURL, let token = token(for: profile) else { return nil }
        return CodegClient(baseURL: baseURL, token: token)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: storageKey)
        onChange?()
    }

    private static func load(from defaults: UserDefaults, key: String) -> [ServerProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}
