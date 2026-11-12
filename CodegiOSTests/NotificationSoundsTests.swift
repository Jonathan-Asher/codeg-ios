import AVFoundation
import XCTest
@testable import Codeg

/// Notification sounds (codeg `docs/ios-push.md`, "Sounds"): the choices and
/// what goes to each server, the sound for all notifications against the
/// server's order of levels, the registration request and the server's
/// answer, the picker's rows, the saved store with its imports, the volume
/// copies (names, gain, making, deleting, re-sending, previews), the
/// conversion of an imported file, and the generated Codeg tones.
@MainActor
final class NotificationSoundsTests: XCTestCase {
    private let home = UUID()
    private let work = UUID()
    private var suites: [String] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        suites = []
        directories = []
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func defaults() -> UserDefaults {
        let suite = "codeg.tests.sounds.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func session(_ id: Int, folders: [Int], critical: Bool = false, server: UUID? = nil) -> NotificationSoundTarget {
        .session(server: server ?? home, conversationID: id, folderIDs: folders, critical: critical, title: "Fix login")
    }

    /// A settings value with a sound at every level.
    private func layered() -> NotificationSoundSettings {
        var settings = NotificationSoundSettings()
        settings.set(.file("codeg-chime.caf"), for: .kind(.needsYou))
        settings.set(.silent, for: .kind(.turnFinished))
        settings.set(.file("codeg-bell.caf"), for: .critical)
        settings.set(.file("codeg-glass.caf"), for: .project(server: home, folderID: 7, name: "codeg"))
        settings.set(.silent, for: session(42, folders: [7]))
        settings.set(.file("codeg-pop.caf"), for: session(3, folders: [1], server: work))
        return settings
    }

    // MARK: - Choices and payload

    func testSoundNamesFollowTheServersRule() {
        XCTAssertTrue(NotificationSound.isSoundFileName("codeg-chime.caf"))
        XCTAssertTrue(NotificationSound.isSoundFileName("import-1a2b3c4d.caf"))
        XCTAssertTrue(NotificationSound.isSoundFileName(String(repeating: "a", count: 60) + ".caf"))
        for bad in ["", "chime", "chime.mp3", ".caf", "-x.caf", "../x.caf", "a/b.caf", "a..b.caf", "my chime.caf",
                    "café.caf", String(repeating: "a", count: 61) + ".caf"] {
            XCTAssertFalse(NotificationSound.isSoundFileName(bad), bad)
        }
        XCTAssertEqual(NotificationSound(wire: "none"), .silent)
        XCTAssertEqual(NotificationSound(wire: "default"), .standard)
        XCTAssertEqual(NotificationSound(wire: "../x.caf"), .standard)
        XCTAssertEqual(NotificationSound(wire: "codeg-pop.caf"), .file("codeg-pop.caf"))
        XCTAssertEqual(NotificationSoundKind(wireKey: "needsYou"), .needsYou)
        XCTAssertEqual(NotificationSoundKind(wireKey: "turn_finished"), .turnFinished)
        XCTAssertNil(NotificationSoundKind(wireKey: "later"))
        XCTAssertEqual(CodegTone.all.count, 20)
        XCTAssertTrue(CodegTone.all.allSatisfy { NotificationSound.isSoundFileName($0.fileName) })
    }

    func testEachServerGetsTheKindsAndCriticalAndOnlyItsOwnProjectsAndSessions() throws {
        let settings = layered()
        let payload = settings.payload(for: home)
        XCTAssertEqual(payload.kinds, ["needs_you": "codeg-chime.caf", "turn_finished": "none"])
        XCTAssertEqual(payload.critical, "codeg-bell.caf")
        XCTAssertEqual(payload.projects, ["7": "codeg-glass.caf"])
        XCTAssertEqual(payload.sessions, ["42": "none"])
        let other = settings.payload(for: work)
        XCTAssertEqual(other.kinds, payload.kinds)
        XCTAssertEqual(other.projects, [:])
        XCTAssertEqual(other.sessions, ["3": "codeg-pop.caf"])
        // A choice put back to default leaves the payload.
        var reset = settings
        reset.set(.standard, for: .critical)
        reset.set(.standard, for: session(42, folders: [7]))
        XCTAssertNil(reset.payload(for: home).critical)
        XCTAssertEqual(reset.payload(for: home).sessions, [:])
        // A file that is gone plays (and is sent) as the default.
        var gone = settings
        gone.kinds["error"] = "import-deadbeef.caf"
        XCTAssertEqual(gone.sound(for: .kind(.error)), .standard)
        XCTAssertNil(gone.payload(for: home).kinds["error"])
    }

    func testTheSettingsSurviveARoundTrip() throws {
        var settings = layered()
        settings.imports = [ImportedSound(fileName: "import-1a2b3c4d.caf", name: "Doorbell", seconds: 2.5, trimmed: false)]
        settings.set(.file("codeg-kalimba.caf"), for: .all)
        settings.set(.system, for: .kind(.error))
        settings.volume = 70
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(NotificationSoundSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.sound(for: .kind(.error)), .system)
        XCTAssertEqual(decoded.sound(for: .all), .file("codeg-kalimba.caf"))
        // What 1.4.6 saved reads with the iOS sound for all notifications and full volume.
        let empty = try JSONDecoder().decode(NotificationSoundSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, NotificationSoundSettings())
        XCTAssertEqual(empty.sound(for: .all), .standard)
        XCTAssertEqual(empty.volume, 100)
        // A volume off the slider's steps is put on the nearest one.
        for (saved, level) in [(55, 60), (3, 10), (1000, 100), (-20, 10)] {
            let read = try JSONDecoder().decode(NotificationSoundSettings.self, from: Data("{\"volume\": \(saved)}".utf8))
            XCTAssertEqual(read.volume, level, "\(saved)")
        }
    }

    func testDeletingAnImportPutsItsChoicesBackToDefault() {
        var settings = layered()
        settings.imports = [ImportedSound(fileName: "import-1a2b3c4d.caf", name: "Doorbell", seconds: 2.5, trimmed: false)]
        settings.set(.file("import-1a2b3c4d.caf"), for: .kind(.error))
        settings.set(.file("import-1a2b3c4d.caf"), for: .all)
        settings.set(.file("import-1a2b3c4d.caf"), for: .project(server: work, folderID: 5, name: "app"))
        XCTAssertEqual(settings.payload(for: work).projects, ["5": "import-1a2b3c4d.caf"])
        settings.removeImport("import-1a2b3c4d.caf")
        XCTAssertTrue(settings.imports.isEmpty)
        XCTAssertEqual(settings.sound(for: .kind(.error)), .standard)
        XCTAssertEqual(settings.sound(for: .all), .standard)
        XCTAssertEqual(settings.payload(for: work).projects, [:])
        XCTAssertEqual(settings.sound(for: .kind(.needsYou)), .file("codeg-chime.caf"))
    }

    func testWhatDefaultInheritsIsNamed() {
        let settings = layered()
        let glass = String(localized: "Project: \(String(localized: "Glass"))")
        let bell = String(localized: "Critical sessions: \(String(localized: "Bell"))")
        XCTAssertNil(settings.inherited(by: .kind(.plan)))
        XCTAssertEqual(settings.inherited(by: .critical), String(localized: "Each kind's own sound"))
        // A session in a folder with a sound, also through its worktree's root.
        XCTAssertEqual(settings.inherited(by: session(99, folders: [7], critical: true)), glass)
        XCTAssertEqual(settings.inherited(by: session(99, folders: [70, 7])), glass)
        // A critical session elsewhere: the critical sessions' sound.
        XCTAssertEqual(settings.inherited(by: session(99, folders: [8], critical: true)), bell)
        XCTAssertEqual(settings.inherited(by: session(99, folders: [8])), String(localized: "Each kind's own sound"))
        XCTAssertEqual(settings.name(of: .silent), String(localized: "None"))
        XCTAssertEqual(settings.name(of: .file("import-gone0000.caf")), String(localized: "Default"))
    }

    func testThePickerChecksOneRowAndSaysWhatDefaultPlays() {
        let settings = layered()
        let kind = NotificationSoundChoices(target: .kind(.needsYou), settings: settings)
        XCTAssertEqual(kind.all.filter(\.checked).map(\.sound), [.file("codeg-chime.caf")])
        XCTAssertEqual(kind.top.map(\.sound), [.standard, .silent])
        XCTAssertEqual(kind.top[0].title, String(localized: "Default"))
        XCTAssertEqual(kind.top[0].subtitle, String(localized: "iOS notification sound"))
        XCTAssertEqual(kind.tones.count, 20)
        XCTAssertEqual(kind.sections.map(\.group), [.chimes, .percussive, .melodic])
        XCTAssertEqual(kind.sections.map(\.rows.count), [7, 5, 8])
        let open = NotificationSoundChoices(target: session(99, folders: [7]), settings: settings)
        XCTAssertEqual(open.all.filter(\.checked).map(\.sound), [.standard])
        XCTAssertEqual(open.top[0].title, String(localized: "Use default"))
        XCTAssertEqual(open.top[0].subtitle, String(localized: "Project: \(String(localized: "Glass"))"))
        let quiet = NotificationSoundChoices(target: session(42, folders: [7]), settings: settings)
        XCTAssertEqual(quiet.all.filter(\.checked).map(\.sound), [.silent])
        var withImport = settings
        withImport.imports = [ImportedSound(fileName: "import-1a2b3c4d.caf", name: "Doorbell", seconds: 41, trimmed: true)]
        let imported = NotificationSoundChoices(target: .critical, settings: withImport)
        XCTAssertEqual(imported.imported.map(\.title), ["Doorbell"])
        XCTAssertEqual(imported.imported.first?.imported?.fileName, "import-1a2b3c4d.caf")
        XCTAssertEqual(imported.all.filter(\.checked).map(\.sound), [.file("codeg-bell.caf")])
    }

    func testTheFooterNamesTheServersThatKeepTheDefaultSound() {
        let none = NotificationSoundText.footer(unsupported: [], partly: [])
        let one = NotificationSoundText.footer(unsupported: ["Home"], partly: [])
        XCTAssertFalse(none.contains("Home"))
        XCTAssertTrue(one.contains("“Home”"))
        XCTAssertTrue(one.hasPrefix(none))
        XCTAssertTrue(NotificationSoundText.footer(unsupported: ["Home", "Work"], partly: ["Lab"]).contains("“Lab”"))
    }

    // MARK: - Registration

    func testTheRegistrationSendsTheSoundsAndReadsWhatTheServerKept() async throws {
        let server = MockCodegServer()
        server.on("register_push_device") { call in
            // Echo what came in, less the session the server no longer has
            // (and with the kinds in snake_case, as codeg sends them).
            var sounds = call.body["sounds"] as? [String: Any] ?? [:]
            sounds["sessions"] = [String: String]()
            let device: [String: Any] = [
                "id": 3, "name": "iPhone", "platform": "ios", "environment": "production",
                "bundle_id": "io.ashurov.codeg", "token_hint": "…a1b2c3d4", "prefs": [String: Any](),
                "sounds": sounds, "created_at": "2026-11-11T10:00:00Z", "last_seen_at": "2026-11-11T10:00:00Z",
            ]
            let data = (try? JSONSerialization.data(withJSONObject: ["device": device, "server_id": "srv1"])) ?? Data()
            return .body(String(decoding: data, as: UTF8.self))
        }
        var settings = layered()
        let sent = settings.payload(for: home)
        let result = try await server.client.registerPushDevice(
            token: "a1b2c3d4", environment: "production", bundleId: "io.ashurov.codeg", name: "iPhone", sounds: sent)
        let body = try XCTUnwrap(server.calls("register_push_device").first?.body["sounds"] as? [String: Any])
        XCTAssertEqual(body["kinds"] as? [String: String], ["needs_you": "codeg-chime.caf", "turn_finished": "none"])
        XCTAssertEqual(body["critical"] as? String, "codeg-bell.caf")
        XCTAssertEqual(body["projects"] as? [String: String], ["7": "codeg-glass.caf"])
        XCTAssertEqual(body["sessions"] as? [String: String], ["42": "none"])

        let kept = try XCTUnwrap(result.device.sounds)
        XCTAssertEqual(kept.kinds, sent.kinds, "the kinds read back in the server's spelling")
        XCTAssertEqual(NotificationSoundSupport.of(kept, sent: sent), .kept)
        // The session the server dropped goes here too.
        settings.adopt(kept, sent: sent, server: home)
        XCTAssertEqual(settings.sound(for: session(42, folders: [7])), .standard)
        XCTAssertEqual(settings.sound(for: .project(server: home, folderID: 7, name: "")), .file("codeg-glass.caf"))
        // But not once the choices moved on.
        var moved = layered()
        moved.set(.file("codeg-ping.caf"), for: .kind(.error))
        let before = moved
        moved.adopt(kept, sent: sent, server: home)
        XCTAssertEqual(moved, before)
    }

    func testAnOlderServerSendsNoSoundsBack() throws {
        let device = try CodegJSON.decoder.decode(PushDeviceView.self, from: Data("""
        {"id": 3, "name": "iPhone", "platform": "ios", "environment": "production",
         "bundle_id": "io.ashurov.codeg", "token_hint": "…a1b2c3d4",
         "prefs": {"turn_finished": "always", "needs_you": "away", "critical": true, "errors": false},
         "created_at": "2026-10-02T10:00:00Z", "last_seen_at": "2026-10-02T10:00:00Z"}
        """.utf8))
        XCTAssertNil(device.sounds)
        let sent = layered().payload(for: home)
        XCTAssertEqual(NotificationSoundSupport.of(device.sounds, sent: sent), .unsupported)
        var other = sent
        other.critical = nil
        XCTAssertEqual(NotificationSoundSupport.of(other, sent: sent), .partly)
        // Without sounds the registration body has none (the server keeps its own).
        let data = try CodegJSON.encoder.encode(NotificationSoundPayload())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["critical"])
        XCTAssertEqual(object["kinds"] as? [String: String], [:])
    }

    // MARK: - Store and imports

    func testTheStoreSavesSendsAndImports() async throws {
        let defaults = defaults()
        let directory = try scratchDirectory()
        var changes: [UUID?] = []
        let store = NotificationSoundStore(defaults: defaults, soundsDirectory: directory.appendingPathComponent("Sounds"),
                                           player: RecordingPlayer(), onChange: { changes.append($0) })
        store.choose(.file("codeg-marimba.caf"), for: .kind(.plan))
        store.choose(.file("codeg-knock.caf"), for: session(42, folders: [7]))
        store.choose(.file("codeg-knock.caf"), for: session(42, folders: [7]))
        XCTAssertEqual(changes, [nil, home], "a kind goes to every server, a session to its own; a repeat to none")
        XCTAssertNotNil(store.url(of: "codeg-marimba.caf"), "the tones ship in the app bundle")

        let source = try makeTone(seconds: 2, sampleRate: 48_000, channels: 2, in: directory)
        let imported = try await store.importSound(from: source)
        XCTAssertEqual(imported.name, "tone")
        XCTAssertTrue(imported.fileName.hasPrefix("import-") && NotificationSound.isSoundFileName(imported.fileName))
        XCTAssertNotNil(store.url(of: imported.fileName))
        store.choose(.file(imported.fileName), for: .critical)
        store.rename(imported, to: "  Doorbell  ")
        XCTAssertEqual(store.settings.imports.first?.name, "Doorbell")

        // A second store reads it all back.
        let again = NotificationSoundStore(defaults: defaults, soundsDirectory: directory.appendingPathComponent("Sounds"),
                                           onChange: { _ in })
        XCTAssertEqual(again.settings, store.settings)
        XCTAssertEqual(again.payload(for: home).critical, imported.fileName)

        changes = []
        store.delete(try XCTUnwrap(store.settings.imports.first))
        XCTAssertEqual(changes, [nil])
        XCTAssertNil(store.url(of: imported.fileName))
        XCTAssertEqual(store.sound(for: .critical), .standard)
        XCTAssertEqual(store.sound(for: .kind(.plan)), .file("codeg-marimba.caf"))

        // An import whose file is gone is forgotten at the next start.
        let lost = try await store.importSound(from: source)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Sounds/\(lost.fileName)"))
        let later = NotificationSoundStore(defaults: defaults, soundsDirectory: directory.appendingPathComponent("Sounds"),
                                           onChange: { _ in })
        XCTAssertTrue(later.settings.imports.isEmpty)
    }

    func testAnImportIsConvertedForNotificationsAndCutTo30Seconds() throws {
        let directory = try scratchDirectory()
        let long = try makeTone(seconds: 40, sampleRate: 48_000, channels: 2, in: directory)
        let cut = try NotificationSoundImporter.convert(from: long, into: directory.appendingPathComponent("Sounds"),
                                                        fileName: "import-aaaa1111.caf")
        XCTAssertTrue(cut.trimmed)
        XCTAssertEqual(cut.seconds, NotificationSoundImporter.maxSeconds, accuracy: 0.01)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("Sounds/import-aaaa1111.caf"))
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertLessThan(Double(file.length) / 44_100, 30)

        let short = try makeTone(seconds: 1.2, sampleRate: 22_050, channels: 1, in: directory)
        let kept = try NotificationSoundImporter.convert(from: short, into: directory.appendingPathComponent("Sounds"),
                                                         fileName: "import-bbbb2222.caf")
        XCTAssertFalse(kept.trimmed)
        XCTAssertEqual(kept.seconds, 1.2, accuracy: 0.02)

        let junk = directory.appendingPathComponent("junk.mp3")
        try Data("not audio".utf8).write(to: junk)
        XCTAssertThrowsError(try NotificationSoundImporter.convert(
            from: junk, into: directory.appendingPathComponent("Sounds"), fileName: "import-cccc3333.caf")) { error in
            XCTAssertEqual(error as? NotificationSoundImporter.Failure, .unreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Sounds/import-cccc3333.caf").path))
    }

    // MARK: - All notifications

    func testKindsLeftOnDefaultGoToTheServersAsTheSoundForAllNotifications() {
        var settings = NotificationSoundSettings()
        settings.set(.file("codeg-chime.caf"), for: .all)
        settings.set(.file("codeg-bell.caf"), for: .kind(.error))
        settings.set(.silent, for: .kind(.reminder))
        settings.set(.system, for: .kind(.plan))
        let payload = settings.payload(for: home)
        XCTAssertEqual(payload.kinds, [
            "needs_you": "codeg-chime.caf", "turn_finished": "codeg-chime.caf", "critical": "codeg-chime.caf",
            "error": "codeg-bell.caf", "reminder": "none",
        ], "a kind's own sound wins; the iOS sound picked for plans is the server's default for a kind")
        XCTAssertNil(payload.critical)
        XCTAssertEqual(settings.label(for: .all), String(localized: "Chime"))
        XCTAssertEqual(settings.label(for: .kind(.needsYou)),
                       String(localized: "Default (All: \(String(localized: "Chime")))"))
        XCTAssertEqual(settings.label(for: .kind(.error)), String(localized: "Bell"))
        XCTAssertEqual(settings.label(for: .kind(.plan)), String(localized: "iOS Default"))
        XCTAssertEqual(settings.inherited(by: .kind(.needsYou)),
                       String(localized: "All notifications: \(String(localized: "Chime"))"))

        // None for all notifications: a banner without a sound for every kind left on default.
        settings.set(.silent, for: .all)
        XCTAssertEqual(settings.payload(for: home).kinds["turn_finished"], "none")
        XCTAssertEqual(settings.label(for: .kind(.turnFinished)),
                       String(localized: "Default (All: \(String(localized: "None")))"))
        // The iOS sound for all notifications sends what 1.4.6 sent.
        settings.set(.standard, for: .all)
        XCTAssertEqual(settings.payload(for: home).kinds, ["error": "codeg-bell.caf", "reminder": "none"])
        XCTAssertEqual(settings.label(for: .kind(.needsYou)), String(localized: "Default"))
        XCTAssertNil(settings.inherited(by: .kind(.needsYou)))

        // The iOS sound over all notifications is a kind's alone.
        settings.set(.system, for: .critical)
        settings.set(.system, for: .all)
        settings.set(.system, for: .project(server: home, folderID: 7, name: "codeg"))
        XCTAssertEqual(settings.sound(for: .critical), .standard)
        XCTAssertEqual(settings.sound(for: .all), .standard)
        XCTAssertEqual(settings.payload(for: home).projects, [:])
    }

    func testTheLevelsAboveTheKindsSayWhenAllNotificationsPlayOneSound() {
        var settings = NotificationSoundSettings()
        settings.set(.file("codeg-harp.caf"), for: .all)
        let harp = String(localized: "All notifications: \(String(localized: "Harp"))")
        XCTAssertEqual(settings.inherited(by: .critical), harp)
        XCTAssertEqual(settings.inherited(by: session(1, folders: [2])), harp)
        settings.set(.file("codeg-bell.caf"), for: .kind(.error))
        XCTAssertEqual(settings.inherited(by: .critical), String(localized: "Each kind's own sound"))
    }

    /// The server's choice of a push's sound, as codeg's
    /// `DeviceSounds::from_wire` and `DeviceSounds::resolve` make it
    /// (`src-tauri/crates/codeg-lib/src/push/prefs.rs`): an entry of
    /// `"default"` counts as unset; then the first that is set of the
    /// session's sound, its folder's, its root folder's, the critical
    /// sessions' (for a critical session) and its kind's; else `"default"`.
    /// `"none"` sends no `aps.sound`.
    private func serverPlays(_ payload: NotificationSoundPayload, kind: NotificationSoundKind, conversation: Int?,
                             folder: Int?, root: Int?, criticalSession: Bool) -> String {
        func set(_ value: String?) -> String? { value == "default" ? nil : value }
        return conversation.flatMap { set(payload.sessions[String($0)]) }
            ?? folder.flatMap { set(payload.projects[String($0)]) }
            ?? root.flatMap { set(payload.projects[String($0)]) }
            ?? (criticalSession ? set(payload.critical) : nil)
            ?? set(payload.kinds[kind.rawValue])
            ?? "default"
    }

    /// What the iPhone means a push to play: the first of its session's
    /// sound, its folder's, its root folder's, the critical sessions' (for a
    /// critical session), its kind's own, then the one for all
    /// notifications; else the iOS sound. A file plays from its copy at the
    /// volume.
    private func phoneMeans(_ settings: NotificationSoundSettings, kind: NotificationSoundKind, conversation: Int?,
                            folder: Int?, root: Int?, criticalSession: Bool) -> String {
        let overrides: [NotificationSound] = [
            conversation.map { settings.sound(for: session($0, folders: [])) } ?? .standard,
            folder.map { settings.sound(for: .project(server: home, folderID: $0, name: "")) } ?? .standard,
            root.map { settings.sound(for: .project(server: home, folderID: $0, name: "")) } ?? .standard,
            criticalSession ? settings.sound(for: .critical) : .standard,
            settings.sound(for: .kind(kind)),
        ]
        let sound = overrides.first { $0 != .standard } ?? settings.sound(for: .all)
        switch sound {
        case .standard, .system: return "default"
        case .silent: return "none"
        case .file(let name): return NotificationSoundVolume.fileName(of: name, level: settings.volume)
        }
    }

    func testTheServerPlaysWhatTheIPhoneMeansAtEveryLevel() {
        let alls: [NotificationSound] = [.standard, .silent, .file("codeg-chime.caf")]
        let kindSounds: [NotificationSound] = [.standard, .system, .silent, .file("codeg-bell.caf")]
        let criticals: [NotificationSound] = [.standard, .silent, .file("codeg-glass.caf")]
        let projects: [NotificationSound] = [.standard, .silent, .file("codeg-pop.caf")]
        let sessions: [NotificationSound] = [.standard, .file("codeg-knock.caf")]
        var checked = 0
        for volume in [100, 60] {
            for all in alls {
                for kindSound in kindSounds {
                    for critical in criticals {
                        for project in projects {
                            for sessionSound in sessions {
                                var settings = NotificationSoundSettings()
                                settings.volume = volume
                                settings.set(all, for: .all)
                                settings.set(kindSound, for: .kind(.needsYou))
                                settings.set(.file("codeg-harp.caf"), for: .kind(.error))
                                settings.set(critical, for: .critical)
                                // Folder 7 is a project; folder 70 a worktree of it.
                                settings.set(project, for: .project(server: home, folderID: 7, name: "codeg"))
                                settings.set(sessionSound, for: session(42, folders: [7]))
                                let payload = settings.payload(for: home)
                                for kind in [NotificationSoundKind.needsYou, .error, .turnFinished] {
                                    for (conversation, folder, root) in [(42, 7, nil), (43, 7, nil), (44, 70, 7), (45, 8, nil),
                                                                         (nil, nil, nil)] as [(Int?, Int?, Int?)] {
                                        for criticalSession in [false, true] {
                                            XCTAssertEqual(
                                                serverPlays(payload, kind: kind, conversation: conversation, folder: folder,
                                                            root: root, criticalSession: criticalSession),
                                                phoneMeans(settings, kind: kind, conversation: conversation, folder: folder,
                                                           root: root, criticalSession: criticalSession),
                                                "all \(all), \(kind) \(kindSound), critical \(critical), project \(project), session \(sessionSound), volume \(volume), push \(String(describing: conversation)) in \(String(describing: folder))\(criticalSession ? ", critical session" : "")")
                                            checked += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 3 * 4 * 3 * 3 * 2 * 3 * 5 * 2)
    }

    func testThePickerOffersTheIOSSoundToAKindWhileAllNotificationsPlayAnother() {
        var settings = NotificationSoundSettings()
        let all = NotificationSoundChoices(target: .all, settings: settings)
        XCTAssertEqual(all.top.map(\.sound), [.standard, .silent])
        XCTAssertEqual(all.top[0].subtitle, String(localized: "iOS notification sound"))
        XCTAssertEqual(all.all.filter(\.checked).map(\.sound), [.standard])
        XCTAssertEqual(NotificationSoundTarget.all.title, String(localized: "All notifications"))

        settings.set(.file("codeg-glow.caf"), for: .all)
        let kind = NotificationSoundChoices(target: .kind(.plan), settings: settings)
        XCTAssertEqual(kind.top.map(\.sound), [.standard, .silent, .system])
        XCTAssertEqual(kind.top[0].subtitle, String(localized: "All notifications: \(String(localized: "Glow"))"))
        XCTAssertEqual(kind.top[2].title, String(localized: "iOS Default"))
        XCTAssertEqual(Set(kind.all.map(\.id)).count, kind.all.count, "the rows' ids are unique")
        XCTAssertEqual(kind.all.filter(\.checked).map(\.sound), [.standard])
        settings.set(.system, for: .kind(.plan))
        XCTAssertEqual(NotificationSoundChoices(target: .kind(.plan), settings: settings).all.filter(\.checked).map(\.sound),
                       [.system])
        // Back to the iOS sound for all: the kind keeps its choice, and the row with it.
        settings.set(.standard, for: .all)
        XCTAssertEqual(NotificationSoundChoices(target: .kind(.plan), settings: settings).top.map(\.sound),
                       [.standard, .silent, .system])
        XCTAssertEqual(NotificationSoundChoices(target: .kind(.error), settings: settings).top.map(\.sound),
                       [.standard, .silent])
        // Only a kind gets it.
        settings.set(.file("codeg-glow.caf"), for: .all)
        XCTAssertEqual(NotificationSoundChoices(target: .critical, settings: settings).top.map(\.sound), [.standard, .silent])
    }

    // MARK: - Volume

    func testVolumeCopiesHaveANameOfTheirOwnPerLevel() {
        XCTAssertEqual(NotificationSoundVolume.levels, [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        XCTAssertEqual(NotificationSoundVolume.fileName(of: "codeg-chime.caf", level: 60), "codeg-chime-v60.caf")
        XCTAssertEqual(NotificationSoundVolume.fileName(of: "import-1a2b3c4d.caf", level: 10), "import-1a2b3c4d-v10.caf")
        XCTAssertEqual(NotificationSoundVolume.fileName(of: "codeg-chime.caf", level: 100), "codeg-chime.caf")
        XCTAssertEqual(NotificationSoundVolume.fileName(of: "codeg-chime.caf", level: 57), "codeg-chime-v60.caf")
        // A name the servers would refuse plays at full volume rather than not at all.
        let long = String(repeating: "a", count: 58) + ".caf"
        XCTAssertEqual(NotificationSoundVolume.fileName(of: long, level: 50), long)
        // Every tone's and an import's copies fit the servers' rule, and read back.
        for name in CodegTone.all.map(\.fileName) + ["import-1a2b3c4d.caf"] {
            for level in NotificationSoundVolume.levels.dropLast() {
                let copy = NotificationSoundVolume.fileName(of: name, level: level)
                XCTAssertTrue(NotificationSound.isSoundFileName(copy), copy)
                XCTAssertLessThanOrEqual(copy.count, 64)
                XCTAssertNotEqual(copy, name)
                XCTAssertEqual(NotificationSoundVolume.copy(copy)?.original, name)
                XCTAssertEqual(NotificationSoundVolume.copy(copy)?.level, level)
            }
            XCTAssertNil(NotificationSoundVolume.copy(name), "an original is no copy")
        }
        for notCopy in ["codeg-chime-v100.caf", "codeg-chime-v05.caf", "codeg-chime-v65.caf", "-v60.caf",
                        "codeg-chime-v60.wav", "codeg-chime-vx.caf", "codeg-chime-v-60.caf"] {
            XCTAssertNil(NotificationSoundVolume.copy(notCopy), notCopy)
        }
        // The gain: full at 100%, −10 dB (about half as loud) at 50%, −33 dB at 10%.
        XCTAssertEqual(NotificationSoundVolume.gain(100), 1)
        XCTAssertEqual(20 * log10(Double(NotificationSoundVolume.gain(50))), -10, accuracy: 0.1)
        XCTAssertEqual(20 * log10(Double(NotificationSoundVolume.gain(10))), -33.3, accuracy: 0.1)
        let gains = NotificationSoundVolume.levels.map(NotificationSoundVolume.gain)
        XCTAssertEqual(gains, gains.sorted())
        XCTAssertEqual(Set(gains).count, gains.count)
    }

    func testTheStoreMakesTheVolumeCopiesBeforeTheyAreSentAndSendsAgainOnAChange() async throws {
        let defaults = defaults()
        let directory = try scratchDirectory()
        let sounds = directory.appendingPathComponent("Sounds")
        var changes: [UUID?] = []
        let store = NotificationSoundStore(defaults: defaults, soundsDirectory: sounds, player: RecordingPlayer(),
                                           onChange: { changes.append($0) })
        let imported = try await store.importSound(from: try makeTone(seconds: 1.5, sampleRate: 44_100, channels: 1,
                                                                       in: directory))
        store.choose(.file("codeg-chime.caf"), for: .all)
        store.choose(.file(imported.fileName), for: .project(server: home, folderID: 7, name: "codeg"))
        XCTAssertEqual(changes, [nil, home])
        XCTAssertEqual(store.payload(for: home).kinds["error"], "codeg-chime.caf", "100% sends the files themselves")

        changes = []
        await store.setVolume(60).value
        await store.setVolume(58).value
        XCTAssertEqual(changes, [nil], "a new level goes to every server, once")
        XCTAssertEqual(store.settings.volume, 60)
        XCTAssertEqual(NotificationSoundStore(defaults: defaults, soundsDirectory: sounds, player: RecordingPlayer(),
                                              onChange: { _ in }).settings.volume, 60, "the level is saved")

        let stem = (imported.fileName as NSString).deletingPathExtension
        let payload = await store.preparedPayload(for: home)
        XCTAssertEqual(payload.kinds["needs_you"], "codeg-chime-v60.caf")
        XCTAssertEqual(payload.projects["7"], "\(stem)-v60.caf")
        // Each copy is its original at the level's gain: same rate, length and channels, 16-bit.
        let gain = NotificationSoundVolume.gain(60)
        for (copy, original) in [("codeg-chime-v60.caf", try XCTUnwrap(store.url(of: "codeg-chime.caf"))),
                                 ("\(stem)-v60.caf", sounds.appendingPathComponent(imported.fileName))] {
            let url = sounds.appendingPathComponent(copy)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), copy)
            let file = try AVAudioFile(forReading: url)
            let source = try AVAudioFile(forReading: original)
            XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertEqual(file.fileFormat.sampleRate, source.fileFormat.sampleRate)
            let scaled = try Self.samples(of: url).samples
            let full = try Self.samples(of: original).samples
            XCTAssertEqual(scaled.count, full.count)
            let worst = zip(scaled, full).map { abs($0 - $1 * gain) }.max() ?? 1
            XCTAssertLessThanOrEqual(worst, 1.5 / 32_768, copy)
            XCTAssertEqual(Self.rms(scaled) / Self.rms(full), gain, accuracy: 0.002)
        }
        // A copy that is there is used as it is.
        let made = try FileManager.default.attributesOfItem(
            atPath: sounds.appendingPathComponent("codeg-chime-v60.caf").path)[.modificationDate] as? Date
        _ = await store.preparedPayload(for: home)
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: sounds.appendingPathComponent("codeg-chime-v60.caf").path)[.modificationDate] as? Date, made)

        // A choice made at this level is sent as its copy too.
        changes = []
        store.choose(.file("codeg-retro.caf"), for: .kind(.error))
        XCTAssertEqual(changes, [nil])
        let next = await store.preparedPayload(for: work)
        XCTAssertEqual(next.kinds["error"], "codeg-retro-v60.caf")
        XCTAssertEqual(next.kinds["plan"], "codeg-chime-v60.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sounds.appendingPathComponent("codeg-retro-v60.caf").path))
    }

    func testASoundWhoseCopyCouldNotBeMadeGoesAtFullVolume() async throws {
        // `Library/Sounds` can't be made under a file: no copy can be written.
        let blocked = try scratchDirectory().appendingPathComponent("file")
        try Data().write(to: blocked)
        let store = NotificationSoundStore(defaults: defaults(), soundsDirectory: blocked.appendingPathComponent("Sounds"),
                                           player: RecordingPlayer(), onChange: { _ in })
        store.choose(.file("codeg-glow.caf"), for: .all)
        await store.setVolume(40).value
        XCTAssertEqual(store.payload(for: home).kinds["error"], "codeg-glow-v40.caf")
        let payload = await store.preparedPayload(for: home)
        XCTAssertEqual(payload.kinds["error"], "codeg-glow.caf", "the tone itself, not a name iOS can't find")
    }

    func testCopiesNoServerAndNoChoiceNameAreDeleted() async throws {
        let defaults = defaults()
        let directory = try scratchDirectory()
        let sounds = directory.appendingPathComponent("Sounds")
        let store = NotificationSoundStore(defaults: defaults, soundsDirectory: sounds, player: RecordingPlayer(),
                                           onChange: { _ in })
        let imported = try await store.importSound(from: try makeTone(seconds: 1, sampleRate: 44_100, channels: 1,
                                                                       in: directory))
        store.choose(.file("codeg-chime.caf"), for: .all)
        store.choose(.file(imported.fileName), for: .critical)
        await store.setVolume(60).value
        let home60 = await store.preparedPayload(for: home)
        store.registered(home60, server: home)
        // The other server last kept the sounds at 80% and hasn't been reached since.
        await store.setVolume(80).value
        let work80 = await store.preparedPayload(for: work)
        store.registered(work80, server: work)
        await store.setVolume(60).value
        // Left behind: a copy at a level nobody uses, a preview's, a stray.
        await store.makeCopies(["codeg-bell-v30.caf", "codeg-pop-v60.caf"])
        let stem = (imported.fileName as NSString).deletingPathExtension
        try Data().write(to: sounds.appendingPathComponent("notes.caf"))
        func present() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: sounds.path)) ?? [])
        }
        XCTAssertTrue(present().isSuperset(of: ["codeg-bell-v30.caf", "codeg-pop-v60.caf", "codeg-chime-v80.caf"]))

        store.deleteUnusedCopies()
        XCTAssertEqual(present(), [
            imported.fileName, "notes.caf",
            "codeg-chime-v60.caf", "\(stem)-v60.caf",   // what home's pushes and the choices name
            "codeg-chime-v80.caf", "\(stem)-v80.caf",   // what work's pushes still name
        ])

        // Work takes the new level: its old copies go.
        store.registered(await store.preparedPayload(for: work), server: work)
        XCTAssertEqual(present(), [imported.fileName, "notes.caf", "codeg-chime-v60.caf", "\(stem)-v60.caf"])

        // A server that plays no custom sounds names none; a removed one, neither.
        await store.setVolume(40).value
        store.registered(await store.preparedPayload(for: home), server: home)
        XCTAssertTrue(present().contains("codeg-chime-v60.caf"), "work still names it")
        store.registered(nil, server: work)
        XCTAssertEqual(present(), [imported.fileName, "notes.caf", "codeg-chime-v40.caf", "\(stem)-v40.caf"])
        store.choose(.standard, for: .critical)
        store.registered(await store.preparedPayload(for: home), server: home)
        XCTAssertEqual(present(), [imported.fileName, "notes.caf", "codeg-chime-v40.caf"])
        store.forgetServer(home)
        XCTAssertEqual(present(), [imported.fileName, "notes.caf", "codeg-chime-v40.caf"], "still chosen")

        // What each server names is remembered across launches.
        await store.setVolume(20).value
        store.registered(await store.preparedPayload(for: work), server: work)
        let again = NotificationSoundStore(defaults: defaults, soundsDirectory: sounds, player: RecordingPlayer(),
                                           onChange: { _ in })
        await again.setVolume(90).value
        again.deleteUnusedCopies()
        XCTAssertTrue(present().contains("codeg-chime-v20.caf"))
        XCTAssertTrue(present().contains("codeg-chime-v90.caf"))
        XCTAssertFalse(present().contains("codeg-chime-v40.caf"))
    }

    func testThePreviewPlaysAtTheVolume() async throws {
        let directory = try scratchDirectory()
        let sounds = directory.appendingPathComponent("Sounds")
        let player = RecordingPlayer()
        let store = NotificationSoundStore(defaults: defaults(), soundsDirectory: sounds, player: player,
                                           onChange: { _ in })
        await store.preview(.file("codeg-cascade.caf")).value
        XCTAssertEqual(player.played.last, store.url(of: "codeg-cascade.caf"), "100% plays the tone itself")

        // The slider plays the sound for all notifications at the new level…
        store.choose(.file("codeg-sonar.caf"), for: .all)
        await store.setVolume(30).value
        let sonar = try XCTUnwrap(player.played.last)
        XCTAssertEqual(sonar, sounds.appendingPathComponent("codeg-sonar-v30.caf"))
        let ratio = Self.rms(try Self.samples(of: sonar).samples)
            / Self.rms(try Self.samples(of: try XCTUnwrap(store.url(of: "codeg-sonar.caf"))).samples)
        XCTAssertEqual(ratio, NotificationSoundVolume.gain(30), accuracy: 0.002)
        // …and a pick plays at it too.
        await store.preview(.file("codeg-harp.caf")).value
        XCTAssertEqual(player.played.last, sounds.appendingPathComponent("codeg-harp-v30.caf"))
        // Nothing for the iOS sound or none.
        let stops = player.stops
        await store.preview(.standard).value
        await store.preview(.silent).value
        await store.preview(.system).value
        XCTAssertEqual(player.stops, stops + 3)
        XCTAssertEqual(player.played.count, 3)
        // With nothing chosen, the slider plays the first tone.
        let fresh = NotificationSoundStore(defaults: defaults(), soundsDirectory: sounds, player: player,
                                           onChange: { _ in })
        await fresh.setVolume(50).value
        XCTAssertEqual(player.played.last, sounds.appendingPathComponent("codeg-chime-v50.caf"))
    }

    // MARK: - Codeg tones

    /// What `scripts/make-notification-sounds.py` made: every tone listed and
    /// bundled, 22.05 kHz mono, 0.25 to 1.5 s with its 20 ms of silence,
    /// quiet at both ends, small, never over the peak, and all at the
    /// script's loudness.
    func testTheCodegTonesAreShortSmallAndEquallyLoud() throws {
        XCTAssertEqual(Set(CodegTone.all.map(\.fileName)).count, 20)
        XCTAssertEqual(Set(CodegTone.all.map(\.title)).count, 20, "each has a name of its own")
        XCTAssertTrue(CodegTone.Group.allCases.allSatisfy { group in CodegTone.all.contains { $0.group == group } })
        let bundled = Set((Bundle.main.urls(forResourcesWithExtension: "caf", subdirectory: nil) ?? [])
            .map(\.lastPathComponent).filter { $0.hasPrefix("codeg-") })
        XCTAssertEqual(bundled, Set(CodegTone.all.map(\.fileName)), "every tone in the bundle is listed")
        for tone in CodegTone.all {
            let url = try XCTUnwrap(Bundle.main.url(forResource: (tone.fileName as NSString).deletingPathExtension,
                                                    withExtension: "caf"), tone.fileName)
            let (samples, rate) = try Self.samples(of: url)
            XCTAssertEqual(rate, 22_050, tone.fileName)
            XCTAssertEqual(try AVAudioFile(forReading: url).fileFormat.channelCount, 1)
            let seconds = Double(samples.count) / rate
            XCTAssertTrue((0.25...1.55).contains(seconds), "\(tone.fileName): \(seconds) s")
            XCTAssertLessThan(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int),
                              80_000, tone.fileName)
            XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 1, 0.901, tone.fileName)
            XCTAssertLessThan(abs(samples[0]), 0.01, "\(tone.fileName) starts softly")
            XCTAssertLessThan(samples.suffix(Int(0.015 * rate)).map(abs).max() ?? 1, 0.001,
                              "\(tone.fileName) ends in silence")
            let loudness = 20 * log10(Double(Self.loudness(samples, rate: rate)) / 0.21)
            XCTAssertEqual(loudness, 0, accuracy: 1, "\(tone.fileName) is \(loudness) dB off the others")
        }
    }

    /// The samples of an audio file, as floats, and its sample rate.
    private static func samples(of url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    private static func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
    }

    /// The script's `loudness`: halfway in dB between the loudest 50 ms and
    /// the loudest 50 ms through an 800 Hz high-pass (RBJ cookbook, Q 0.7071).
    private static func loudness(_ samples: [Float], rate: Double) -> Float {
        func loudest(_ x: [Float]) -> Float {
            let size = Int(0.05 * rate)
            var best: Float = 0
            for start in stride(from: 0, to: max(1, x.count - size), by: size / 2) {
                best = max(best, rms(Array(x[start..<min(x.count, start + size)])))
            }
            return best
        }
        let w0 = 2 * Double.pi * 800 / rate, alpha = sin(w0) / (2 * 0.7071), c = cos(w0)
        let (b0, b1, b2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
        let (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
        let high = samples.map { sample -> Float in
            let x0 = Double(sample)
            let y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            (x2, x1, y2, y1) = (x1, x0, y1, y0)
            return Float(y0)
        }
        return sqrt(loudest(samples) * loudest(high))
    }

    /// A sine of `seconds` written as a WAV file named `tone.wav`.
    private func makeTone(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
                          in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tone.wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for i in 0..<Int(frames) {
                samples[i] = Float(0.4 * sin(2 * Double.pi * 440 * Double(i) / sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }
}

/// Records what the store plays instead of playing it.
private final class RecordingPlayer: SoundPreviewPlaying {
    private(set) var played: [URL] = []
    private(set) var stops = 0

    func play(_ url: URL) { played.append(url) }
    func stop() { stops += 1 }
}
