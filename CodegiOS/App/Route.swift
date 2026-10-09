import Foundation

/// The five top-level tabs of the compact (iPhone) shell: four content tabs
/// plus the system search tab (rendered by iOS 26 as the separated glass
/// magnifier next to the tab bar). Regular width (iPad) maps the same
/// destinations onto the split view's sidebar instead.
enum AppTab: String, Hashable, CaseIterable {
    case chats
    case projects
    case activity
    case settings
    case search
}

/// iPad sidebar selection — the split view's "source list". Settings is
/// presented as a sheet on iPad (gear in the sidebar toolbar), and search rides
/// the content column, so neither needs a sidebar row.
enum SidebarSection: String, Hashable {
    case chats
    case projects
    case activity
}

/// A pushable destination. Every entry point (list rows, search results,
/// activity, the running bar, deep links, future push notifications) converges
/// on this enum so navigation behaves identically regardless of origin.
enum Route: Hashable {
    case conversation(Int)
    case project(Int)
    /// The "start a new task" screen: a blank session detail. The agent, folder,
    /// and config are chosen in-page (from the nav-bar agent button), and the
    /// first send connects + prompts before a server conversation id exists
    /// (it adopts one on `conversation_linked`).
    case newSession(NewSessionRequest)
    /// One group of the Chats list (Pinned, a folder, Other) in full, opened
    /// from its card. Pushed rather than presented, so Back from a session
    /// opened in it returns to it.
    case sessionGroup(SessionGroup)

    /// A session screen (an existing conversation or a new task's draft).
    var isSession: Bool {
        switch self {
        case .conversation, .newSession: return true
        case .project, .sessionGroup: return false
        }
    }
}

/// A group of the Chats list.
enum SessionGroup: Hashable {
    case pinned
    case folder(Int)
    case other

    /// Pairs the card with the pushed list for the zoom transition.
    var transitionID: String {
        switch self {
        case .pinned: return "pinned"
        case .folder(let id): return "folder-\(id)"
        case .other: return "other"
        }
    }
}

extension AppTab {
    /// The tab showing what an iPad sidebar section shows.
    init(section: SidebarSection) {
        switch section {
        case .chats: self = .chats
        case .projects: self = .projects
        case .activity: self = .activity
        }
    }
}

extension SidebarSection {
    /// The sidebar section for a tab, `nil` for Settings (a sheet on iPad).
    init?(tab: AppTab) {
        switch tab {
        case .chats, .search: self = .chats
        case .projects: self = .projects
        case .activity: self = .activity
        case .settings: return nil
        }
    }
}

/// A draft new-task token. Carries only an optional preselected folder (e.g.
/// when launched from a project); the agent/folder/first message are all chosen
/// on the session screen itself, so this is just a stable identity for the
/// pushed/pending draft.
struct NewSessionRequest: Hashable, Identifiable {
    let id: UUID
    var preselectedFolderID: Int?

    init(id: UUID = UUID(), preselectedFolderID: Int? = nil) {
        self.id = id
        self.preselectedFolderID = preselectedFolderID
    }
}

extension Route {
    /// Parse a deep link on the app's own scheme (`AppIdentity.urlScheme`,
    /// written `codeg://` here): `codeg://conversation/<id>` and
    /// `codeg://project/<id>`. (`codeg://tab/<name>` switches tabs rather than
    /// pushing, so `AppModel.handle(url:)` deals with it before calling this.)
    static func from(url: URL) -> Route? {
        guard AppIdentity.owns(url) else { return nil }
        let id = url.pathComponents.count > 1 ? Int(url.pathComponents[1]) : nil
        switch url.host?.lowercased() {
        case "conversation": return id.map { .conversation($0) }
        case "project": return id.map { .project($0) }
        default: return nil
        }
    }
}
