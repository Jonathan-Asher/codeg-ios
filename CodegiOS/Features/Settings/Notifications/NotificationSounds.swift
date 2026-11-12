import Foundation

// The sounds codeg's notifications play on this iPhone (codeg
// `docs/ios-push.md`, "Sounds"). The phone sends its choices to every saved
// server with the push registration; the server names the file in each
// push's `aps.sound`, and iOS plays it from the app's `Library/Sounds`
// (imported sounds, and every sound's quieter copies for the volume
// slider) or from the app bundle (the Codeg tones). A notification plays
// the first that is set: its session's sound, its project's, the one for
// every critical session, its kind's, then the one for all notifications.
// The servers have no "all notifications" level: each kind left on default
// goes to them as that sound.

/// The kinds of notification that get a sound each: one row each in
/// Settings › Notifications › Sounds.
enum NotificationSoundKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// A question or a permission request.
    case needsYou = "needs_you"
    /// A plan waiting for approval.
    case plan
    /// A reminder of anything still waiting.
    case reminder
    /// A finished turn, and the test push.
    case turnFinished = "turn_finished"
    /// A critical session's alert (idle, may be stuck).
    case critical
    case error

    var id: String { rawValue }

    /// The kind a key names: the server's snake_case, or the camelCase the
    /// shared decoder turns dictionary keys into.
    init?(wireKey: String) {
        let folded = wireKey.replacingOccurrences(of: "_", with: "").lowercased()
        guard let kind = Self.allCases.first(where: {
            $0.rawValue.replacingOccurrences(of: "_", with: "") == folded
        }) else { return nil }
        self = kind
    }

    var title: String {
        switch self {
        case .needsYou: String(localized: "Questions & permissions")
        case .plan: String(localized: "Plans")
        case .reminder: String(localized: "Reminders")
        case .turnFinished: String(localized: "Finished replies")
        case .critical: String(localized: "Critical / idle alerts")
        case .error: String(localized: "Errors")
        }
    }

    var hint: String {
        switch self {
        case .needsYou: String(localized: "A question or a permission request is waiting.")
        case .plan: String(localized: "A plan is waiting for your approval.")
        case .reminder: String(localized: "Something is still waiting for you.")
        case .turnFinished: String(localized: "An agent finished responding. The test push plays it too.")
        case .critical: String(localized: "A session you marked critical sits idle or may be stuck.")
        case .error: String(localized: "An error broke a session.")
        }
    }
}

/// What a notification plays. On the wire: `"default"`, `"none"` or a
/// sound file name.
enum NotificationSound: Hashable, Identifiable, Sendable {
    /// For all notifications, the iOS default sound; for a kind, what all
    /// notifications play; for the critical sessions, a project or a
    /// session, whatever the next level plays.
    case standard
    /// The iOS default sound, picked for a kind over the sound for all
    /// notifications (a kind's alone). `"default"` on the wire, which is a
    /// kind's iOS sound to the server; saved as that in
    /// ``NotificationSoundSettings/kinds``.
    case system
    /// No sound: the banner still shows.
    case silent
    /// A Codeg tone or an imported sound, by file name.
    case file(String)

    /// An unknown value, or a file name the server would refuse, reads as
    /// `.standard`.
    init(wire: String) {
        switch wire {
        case "none": self = .silent
        case let name where Self.isSoundFileName(name): self = .file(name)
        default: self = .standard
        }
    }

    var wire: String {
        switch self {
        case .standard, .system: "default"
        case .silent: "none"
        case .file(let name): name
        }
    }

    /// The wire value, but `system` for the iOS sound picked over all
    /// notifications (no file name can be that).
    var id: String { self == .system ? "system" : wire }

    var fileName: String? {
        if case .file(let name) = self { return name }
        return nil
    }

    /// The server's rule for `aps.sound`: a plain file name, never a path.
    /// ASCII letters, digits, `-`, `_` and `.`, starting with a letter or a
    /// digit, no `..`, a `.caf`, `.wav` or `.aiff` extension, 64 characters
    /// at most.
    static func isSoundFileName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count <= 64, let first = scalars.first, isAlphanumeric(first),
              !name.contains(".."), let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard ["caf", "wav", "aiff"].contains(ext) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
}

/// A tone that ships with the app (`Resources/Sounds`, made by
/// `scripts/make-notification-sounds.py`).
struct CodegTone: Identifiable, Hashable, Sendable {
    /// The picker's sections of tones.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        /// Ringing tones of one strike: bells, glass, a ping.
        case chimes
        /// Short knocks, taps and blips.
        case percussive
        /// A few notes: a figure, an arpeggio, a chord.
        case melodic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chimes: String(localized: "Chimes")
            case .percussive: String(localized: "Percussive")
            case .melodic: String(localized: "Melodic")
            }
        }
    }

    let fileName: String
    let group: Group

    var id: String { fileName }

    var title: String {
        switch fileName {
        case "codeg-chime.caf": String(localized: "Chime")
        case "codeg-ping.caf": String(localized: "Ping")
        case "codeg-glass.caf": String(localized: "Glass")
        case "codeg-bell.caf": String(localized: "Bell")
        case "codeg-pop.caf": String(localized: "Pop")
        case "codeg-two-tone.caf": String(localized: "Two-Tone")
        case "codeg-marimba.caf": String(localized: "Marimba")
        case "codeg-knock.caf": String(localized: "Knock")
        case "codeg-kalimba.caf": String(localized: "Kalimba")
        case "codeg-halo.caf": String(localized: "Halo")
        case "codeg-woodblock.caf": String(localized: "Woodblock")
        case "codeg-bubbles.caf": String(localized: "Bubbles")
        case "codeg-sonar.caf": String(localized: "Sonar")
        case "codeg-doorbell.caf": String(localized: "Doorbell")
        case "codeg-harp.caf": String(localized: "Harp")
        case "codeg-cascade.caf": String(localized: "Cascade")
        case "codeg-triangle.caf": String(localized: "Triangle")
        case "codeg-steel-drum.caf": String(localized: "Steel Drum")
        case "codeg-glow.caf": String(localized: "Glow")
        case "codeg-retro.caf": String(localized: "Retro")
        default: fileName
        }
    }

    /// In the picker's order, section by section.
    static let all: [CodegTone] =
        tones(.chimes, "chime", "ping", "glass", "bell", "halo", "triangle", "sonar")
        + tones(.percussive, "pop", "knock", "woodblock", "bubbles", "retro")
        + tones(.melodic, "two-tone", "doorbell", "marimba", "kalimba", "harp", "cascade", "steel-drum", "glow")

    private static func tones(_ group: Group, _ names: String...) -> [CodegTone] {
        names.map { CodegTone(fileName: "codeg-\($0).caf", group: group) }
    }

    static func named(_ fileName: String) -> CodegTone? {
        all.first { $0.fileName == fileName }
    }
}

/// The volume slider. iOS plays a push's sound at the ringtone and alert
/// volume and has no volume of its own for it, so below 100% a sound plays
/// from a quieter copy of its file in `Library/Sounds`, with a name of its own
/// per level (iOS remembers a sound by its name): `codeg-chime-v60.caf`,
/// `import-1a2b3c4d-v60.caf`. At 100% the file itself plays. The iOS default
/// sound has no file, so the slider leaves it alone.
enum NotificationSoundVolume {
    /// The slider's steps, in percent.
    static let levels = Array(stride(from: 10, through: 100, by: 10))
    static let full = 100

    /// `level` put on the nearest step.
    static func clamped(_ level: Int) -> Int {
        min(full, max(10, Int((Double(level) / 10).rounded()) * 10))
    }

    /// The amplitude a level scales a sound by. The slider is in loudness,
    /// which halves about every 10 dB (loudness goes with amplitude to the
    /// 0.6): 50% is −10 dB, 10% is −33 dB.
    static func gain(_ level: Int) -> Float {
        Float(pow(Double(clamped(level)) / Double(full), 1 / 0.6))
    }

    /// The file `original` plays from at `level`: itself at 100%, else its
    /// copy for that level. One whose copy's name the servers would refuse
    /// (longer than 64 characters) keeps playing at full volume.
    static func fileName(of original: String, level: Int) -> String {
        let level = clamped(level)
        guard level < full else { return original }
        let copy = "\((original as NSString).deletingPathExtension)-v\(level).caf"
        return NotificationSound.isSoundFileName(copy) ? copy : original
    }

    /// The original and the level a copy's name stands for; nil for a name
    /// that is not a copy's.
    static func copy(_ fileName: String) -> (original: String, level: Int)? {
        guard fileName.hasSuffix(".caf") else { return nil }
        let stem = fileName.dropLast(4)
        guard let mark = stem.range(of: "-v", options: .backwards), mark.lowerBound > stem.startIndex,
              let level = Int(stem[mark.upperBound...]), "\(level)" == stem[mark.upperBound...],
              level < full, levels.contains(level) else { return nil }
        return ("\(stem[..<mark.lowerBound]).caf", level)
    }
}

/// A sound imported from Files: converted to a Core Audio file in
/// `Library/Sounds` under a name of its own, never reused (iOS remembers a
/// sound by its name).
struct ImportedSound: Codable, Hashable, Identifiable, Sendable {
    /// `import-<8 hex>.caf`.
    var fileName: String
    /// What the lists call it; the user can rename it.
    var name: String
    var seconds: Double
    /// Cut to the 30 seconds iOS plays for a notification.
    var trimmed: Bool

    var id: String { fileName }
}

/// One server's project and session sounds, by that server's own folder and
/// conversation ids (wire values, never `"default"`).
struct ServerSoundOverrides: Codable, Hashable, Sendable {
    var projects: [Int: String] = [:]
    var sessions: [Int: String] = [:]

    var isEmpty: Bool { projects.isEmpty && sessions.isEmpty }
}

/// What a sound picker sets.
enum NotificationSoundTarget: Hashable, Identifiable, Sendable {
    /// Every kind left on default.
    case all
    case kind(NotificationSoundKind)
    /// Every notification of a session marked critical.
    case critical
    case project(server: UUID, folderID: Int, name: String)
    /// `folderIDs`: the session's folder, then its root folder when that is
    /// a worktree folder (the server plays a project's sound for its
    /// worktrees too).
    case session(server: UUID, conversationID: Int, folderIDs: [Int], critical: Bool, title: String)

    var id: String {
        switch self {
        case .all: "all"
        case .kind(let kind): "kind:\(kind.rawValue)"
        case .critical: "critical"
        case .project(let server, let folderID, _): "project:\(server.uuidString):\(folderID)"
        case .session(let server, let conversationID, _, _, _): "session:\(server.uuidString):\(conversationID)"
        }
    }

    var title: String {
        switch self {
        case .all: String(localized: "All notifications")
        case .kind(let kind): kind.title
        case .critical: String(localized: "Critical sessions")
        case .project(_, _, let name): name
        case .session(_, _, _, _, let title): title
        }
    }

    var isKind: Bool {
        if case .kind = self { return true }
        return false
    }
}

/// The `sounds` of a registration, and of the device the server answers
/// with: the kinds and the critical sessions are this iPhone's, the projects
/// and sessions that server's.
struct NotificationSoundPayload: Codable, Hashable, Sendable {
    var kinds: [String: String] = [:]
    var critical: String?
    var projects: [String: String] = [:]
    var sessions: [String: String] = [:]

    init(kinds: [String: String] = [:], critical: String? = nil, projects: [String: String] = [:],
         sessions: [String: String] = [:]) {
        self.kinds = kinds
        self.critical = critical
        self.projects = projects
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case kinds, critical, projects, sessions
    }

    /// The shared decoder turns `needs_you` into `needsYou`: the kinds are
    /// put back in the server's spelling.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKinds = (try? c.decodeIfPresent([String: String].self, forKey: .kinds)) ?? [:]
        var kinds: [String: String] = [:]
        for (key, value) in rawKinds {
            kinds[NotificationSoundKind(wireKey: key)?.rawValue ?? key] = value
        }
        self.kinds = kinds
        critical = (try? c.decodeIfPresent(String.self, forKey: .critical)) ?? nil
        projects = (try? c.decodeIfPresent([String: String].self, forKey: .projects)) ?? [:]
        sessions = (try? c.decodeIfPresent([String: String].self, forKey: .sessions)) ?? [:]
    }
}

/// How a server took the sounds at the last registration.
enum NotificationSoundSupport: String, Codable, Sendable {
    /// It kept them as sent (less the projects and sessions it no longer has).
    case kept
    /// It answered with other kinds or another critical sound.
    case partly
    /// It sent no sounds back: an older codeg, whose pushes keep the
    /// default sound.
    case unsupported

    /// What the server's answer to `sent` says.
    static func of(_ echo: NotificationSoundPayload?, sent: NotificationSoundPayload) -> Self {
        guard let echo else { return .unsupported }
        return echo.kinds == sent.kinds && echo.critical == sent.critical ? .kept : .partly
    }
}

/// Every choice, as saved on this iPhone (UserDefaults, see
/// ``NotificationSoundStore``).
struct NotificationSoundSettings: Codable, Equatable, Sendable {
    /// What every kind left on default plays: a wire value, `"default"`
    /// being the iOS sound.
    var all = "default"
    /// ``NotificationSoundKind`` raw value → wire value; absent plays `all`,
    /// `"default"` the iOS sound (``NotificationSound/system``).
    var kinds: [String: String] = [:]
    var critical = "default"
    /// By server profile id.
    var servers: [String: ServerSoundOverrides] = [:]
    var imports: [ImportedSound] = []
    /// The volume slider, in percent (``NotificationSoundVolume``).
    var volume = NotificationSoundVolume.full

    init() {}

    private enum CodingKeys: String, CodingKey {
        case all, kinds, critical, servers, imports, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        all = (try? c.decodeIfPresent(String.self, forKey: .all)) ?? "default"
        kinds = (try? c.decodeIfPresent([String: String].self, forKey: .kinds)) ?? [:]
        critical = (try? c.decodeIfPresent(String.self, forKey: .critical)) ?? "default"
        servers = (try? c.decodeIfPresent([String: ServerSoundOverrides].self, forKey: .servers)) ?? [:]
        imports = (try? c.decodeIfPresent([ImportedSound].self, forKey: .imports)) ?? []
        volume = NotificationSoundVolume.clamped(
            (try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? NotificationSoundVolume.full)
    }

    // MARK: - Reading

    /// Every file a choice can name: the Codeg tones and the imports.
    var availableFiles: Set<String> {
        Set(CodegTone.all.map(\.fileName)).union(imports.map(\.fileName))
    }

    /// A choice as it plays: a file that is gone plays as `.standard`.
    func playable(_ sound: NotificationSound) -> NotificationSound {
        if let name = sound.fileName, !availableFiles.contains(name) { return .standard }
        return sound
    }

    func sound(for target: NotificationSoundTarget) -> NotificationSound {
        let wire: String? = switch target {
        case .all: all
        case .kind(let kind): kinds[kind.rawValue]
        case .critical: critical
        case .project(let server, let folderID, _): servers[server.uuidString]?.projects[folderID]
        case .session(let server, let conversationID, _, _, _): servers[server.uuidString]?.sessions[conversationID]
        }
        if target.isKind, wire == NotificationSound.system.wire { return .system }
        return playable(wire.map(NotificationSound.init(wire:)) ?? .standard)
    }

    /// What the lists call a sound: a tone's or an import's name, "None",
    /// "iOS Default", or "Default" (also for a file that is gone).
    func name(of sound: NotificationSound) -> String {
        switch playable(sound) {
        case .standard: String(localized: "Default")
        case .system: String(localized: "iOS Default")
        case .silent: String(localized: "None")
        case .file(let fileName):
            CodegTone.named(fileName)?.title
                ?? imports.first { $0.fileName == fileName }?.name
                ?? fileName
        }
    }

    /// What a row of Settings › Notifications › Sounds shows: the sound's
    /// name, and for a kind left on default while all notifications play
    /// something else, "Default (All: Chime)".
    func label(for target: NotificationSoundTarget) -> String {
        let sound = self.sound(for: target)
        let all = self.sound(for: .all)
        if target.isKind, sound == .standard, all != .standard {
            return String(localized: "Default (All: \(name(of: all)))")
        }
        return name(of: sound)
    }

    /// What a target plays while left at default: the next level that is
    /// set. Nil for all notifications, and for a kind while all
    /// notifications play the iOS sound.
    func inherited(by target: NotificationSoundTarget) -> String? {
        let all = sound(for: .all)
        let ownKinds = NotificationSoundKind.allCases.contains { sound(for: .kind($0)) != .standard }
        let byKind = !ownKinds && all != .standard
            ? String(localized: "All notifications: \(name(of: all))")
            : String(localized: "Each kind's own sound")
        let criticalSound = sound(for: .critical)
        switch target {
        case .all:
            return nil
        case .kind:
            return all == .standard ? nil : String(localized: "All notifications: \(name(of: all))")
        case .critical:
            return byKind
        case .project:
            guard criticalSound != .standard else { return byKind }
            return String(localized: "\(byKind); critical sessions: \(name(of: criticalSound))")
        case .session(let server, _, let folderIDs, let critical, _):
            let project = folderIDs.lazy
                .map { self.sound(for: .project(server: server, folderID: $0, name: "")) }
                .first { $0 != .standard }
            if let project {
                return String(localized: "Project: \(name(of: project))")
            }
            if critical, criticalSound != .standard {
                return String(localized: "Critical sessions: \(name(of: criticalSound))")
            }
            return byKind
        }
    }

    /// What goes to `server` with the registration: the choices that are
    /// set and can be played there, each file at the volume
    /// (``sent(_:)``). The server has no level for all notifications: a kind
    /// left on default goes as that sound, so the server's order (session,
    /// project, critical sessions, kind) ends in it; a kind that plays the
    /// iOS sound is left out, which is the server's default for a kind.
    func payload(for server: UUID) -> NotificationSoundPayload {
        var payload = NotificationSoundPayload()
        let all = sound(for: .all)
        for kind in NotificationSoundKind.allCases {
            let own = sound(for: .kind(kind))
            switch own == .standard ? all : own {
            case .standard, .system: break
            case let sound: payload.kinds[kind.rawValue] = sent(sound)
            }
        }
        let critical = sound(for: .critical)
        if critical != .standard { payload.critical = sent(critical) }
        if let overrides = servers[server.uuidString] {
            for (id, wire) in overrides.projects {
                let sound = playable(NotificationSound(wire: wire))
                if sound != .standard { payload.projects[String(id)] = sent(sound) }
            }
            for (id, wire) in overrides.sessions {
                let sound = playable(NotificationSound(wire: wire))
                if sound != .standard { payload.sessions[String(id)] = sent(sound) }
            }
        }
        return payload
    }

    /// A sound as it goes to the servers: a file as the copy it plays from
    /// at the volume (``NotificationSoundVolume/fileName(of:level:)``).
    func sent(_ sound: NotificationSound) -> String {
        guard let fileName = sound.fileName else { return sound.wire }
        return NotificationSoundVolume.fileName(of: fileName, level: volume)
    }

    /// Every file a choice names, as chosen (at full volume).
    var chosenFiles: Set<String> {
        var wires = [all, critical] + Array(kinds.values)
        for overrides in servers.values {
            wires += Array(overrides.projects.values) + Array(overrides.sessions.values)
        }
        return Set(wires.compactMap { playable(NotificationSound(wire: $0)).fileName })
    }

    /// What the volume slider plays to try a level: the sound for all
    /// notifications when it is a file, else the first kind's that is,
    /// else the first tone.
    var volumeSample: NotificationSound {
        let sounds = [sound(for: .all)] + NotificationSoundKind.allCases.map { sound(for: .kind($0)) }
        return sounds.first { $0.fileName != nil } ?? .file(CodegTone.all[0].fileName)
    }

    // MARK: - Changing

    mutating func set(_ sound: NotificationSound, for target: NotificationSoundTarget) {
        // The iOS sound over all notifications is a kind's alone; for all
        // notifications it is their default.
        let sound = sound == .system && !target.isKind ? .standard : sound
        let wire = sound == .standard ? nil : sound.wire
        switch target {
        case .all:
            all = wire ?? "default"
        case .kind(let kind):
            kinds[kind.rawValue] = wire
        case .critical:
            critical = wire ?? "default"
        case .project(let server, let folderID, _):
            updateServer(server) { $0.projects[folderID] = wire }
        case .session(let server, let conversationID, _, _, _):
            updateServer(server) { $0.sessions[conversationID] = wire }
        }
    }

    /// The server is no longer saved: forget its projects and sessions.
    mutating func forgetServer(_ server: UUID) {
        servers[server.uuidString] = nil
    }

    /// An import is deleted: every choice naming it goes back to default.
    mutating func removeImport(_ fileName: String) {
        imports.removeAll { $0.fileName == fileName }
        if all == fileName { all = "default" }
        kinds = kinds.filter { $0.value != fileName }
        if critical == fileName { critical = "default" }
        servers = servers.compactMapValues { overrides in
            var kept = overrides
            kept.projects = overrides.projects.filter { $0.value != fileName }
            kept.sessions = overrides.sessions.filter { $0.value != fileName }
            return kept.isEmpty ? nil : kept
        }
    }

    /// The server answered `sent` with what it kept: it drops the projects
    /// and sessions it no longer has, so they go here too. Nothing changes
    /// when the choices moved on since `sent` was built (the next round
    /// sends those).
    mutating func adopt(_ echo: NotificationSoundPayload, sent: NotificationSoundPayload, server: UUID) {
        guard payload(for: server) == sent else { return }
        updateServer(server) { overrides in
            overrides.projects = overrides.projects.filter { echo.projects[String($0.key)] != nil }
            overrides.sessions = overrides.sessions.filter { echo.sessions[String($0.key)] != nil }
        }
    }

    private mutating func updateServer(_ server: UUID, _ change: (inout ServerSoundOverrides) -> Void) {
        var overrides = servers[server.uuidString] ?? ServerSoundOverrides()
        change(&overrides)
        servers[server.uuidString] = overrides.isEmpty ? nil : overrides
    }
}

/// The rows of a sound picker: default (or "Use default" with what it
/// inherits) and None, for a kind the iOS sound while all notifications
/// play another, the Codeg tones by section, the imported sounds. Exactly
/// one is checked.
struct NotificationSoundChoices: Equatable {
    struct Row: Identifiable, Equatable {
        let sound: NotificationSound
        let title: String
        var subtitle: String?
        var checked: Bool
        /// Set for an imported sound (rename, delete).
        var imported: ImportedSound?

        var id: String { sound.id }
    }

    /// A section of Codeg tones.
    struct Section: Identifiable, Equatable {
        let group: CodegTone.Group
        let rows: [Row]

        var id: CodegTone.Group { group }
    }

    var top: [Row]
    var sections: [Section]
    var imported: [Row]

    init(target: NotificationSoundTarget, settings: NotificationSoundSettings) {
        let current = settings.sound(for: target)
        let iosSound = String(localized: "iOS notification sound")
        let standard: Row = switch target {
        case .all:
            Row(sound: .standard, title: String(localized: "Default"), subtitle: iosSound,
                checked: current == .standard)
        case .kind:
            Row(sound: .standard, title: String(localized: "Default"),
                subtitle: settings.inherited(by: target) ?? iosSound, checked: current == .standard)
        default:
            Row(sound: .standard, title: String(localized: "Use default"),
                subtitle: settings.inherited(by: target), checked: current == .standard)
        }
        top = [
            standard,
            Row(sound: .silent, title: String(localized: "None"),
                subtitle: String(localized: "A banner without a sound"), checked: current == .silent),
        ]
        // A kind's Default plays the sound for all notifications: while that
        // isn't the iOS sound, the iOS sound is a choice of its own.
        if target.isKind, settings.sound(for: .all) != .standard || current == .system {
            top.append(Row(sound: .system, title: String(localized: "iOS Default"), subtitle: iosSound,
                           checked: current == .system))
        }
        sections = CodegTone.Group.allCases.map { group in
            Section(group: group, rows: CodegTone.all.filter { $0.group == group }.map { tone in
                Row(sound: .file(tone.fileName), title: tone.title, checked: current == .file(tone.fileName))
            })
        }
        imported = settings.imports.map { sound in
            Row(sound: .file(sound.fileName), title: sound.name,
                subtitle: NotificationSoundText.length(sound), checked: current == .file(sound.fileName),
                imported: sound)
        }
    }

    var tones: [Row] { sections.flatMap(\.rows) }

    var all: [Row] { top + tones + imported }
}

/// How the sound settings read.
enum NotificationSoundText {
    /// "12 sec", or "30 sec, cut to fit" for a long import.
    static func length(_ sound: ImportedSound) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = sound.seconds < 60 ? [.second] : [.minute, .second]
        let text = formatter.string(from: max(1, sound.seconds.rounded())) ?? "\(Int(sound.seconds)) s"
        return sound.trimmed ? String(localized: "\(text), cut to fit") : text
    }

    /// The volume slider's level: "60%".
    static func percent(_ level: Int) -> String {
        (Double(level) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The Sounds section's footer: what the rows apply to, and which saved
    /// servers keep the default sound.
    static func footer(unsupported: [String], partly: [String]) -> String {
        var parts = [String(localized: "Every saved server plays these. A preview follows the Ring/Silent switch, as notifications do.")]
        switch unsupported.count {
        case 0: break
        case 1:
            parts.append(String(localized: "\(quoted(unsupported)) doesn't play custom sounds yet: its notifications keep the default sound until its codeg is updated."))
        default:
            parts.append(String(localized: "\(quoted(unsupported)) don't play custom sounds yet: their notifications keep the default sound until their codeg is updated."))
        }
        switch partly.count {
        case 0: break
        case 1: parts.append(String(localized: "\(quoted(partly)) didn't keep every sound; update its codeg."))
        default: parts.append(String(localized: "\(quoted(partly)) didn't keep every sound; update their codeg."))
        }
        return parts.joined(separator: " ")
    }

    private static func quoted(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
    }
}
