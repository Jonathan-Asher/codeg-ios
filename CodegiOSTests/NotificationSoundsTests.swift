import AVFoundation
import XCTest
@testable import Codeg

/// Notification sounds (codeg `docs/ios-push.md`, "Sounds"): the choices and
/// what goes to each server, the registration request and the server's
/// answer, the picker's rows, the saved store with its imports, and the
/// conversion of an imported file.
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
        XCTAssertEqual(CodegTone.all.count, 8)
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
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(NotificationSoundSettings.self, from: data), settings)
        XCTAssertEqual(try JSONDecoder().decode(NotificationSoundSettings.self, from: Data("{}".utf8)),
                       NotificationSoundSettings())
    }

    func testDeletingAnImportPutsItsChoicesBackToDefault() {
        var settings = layered()
        settings.imports = [ImportedSound(fileName: "import-1a2b3c4d.caf", name: "Doorbell", seconds: 2.5, trimmed: false)]
        settings.set(.file("import-1a2b3c4d.caf"), for: .kind(.error))
        settings.set(.file("import-1a2b3c4d.caf"), for: .project(server: work, folderID: 5, name: "app"))
        XCTAssertEqual(settings.payload(for: work).projects, ["5": "import-1a2b3c4d.caf"])
        settings.removeImport("import-1a2b3c4d.caf")
        XCTAssertTrue(settings.imports.isEmpty)
        XCTAssertEqual(settings.sound(for: .kind(.error)), .standard)
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
        XCTAssertEqual(kind.tones.count, 8)
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
                                           onChange: { changes.append($0) })
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
