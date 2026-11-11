import AudioToolbox
import Foundation
import Observation
import os

/// This iPhone's notification sounds: the choices (UserDefaults), the
/// imported files (`Library/Sounds`, where iOS looks for a push's sound) and
/// the previews. Every change goes to the saved servers with the push
/// registration (``PushRegistration/soundsChanged(server:)``): a kind, the
/// critical sessions or an import to every server, a project or a session
/// to its own.
@MainActor
@Observable
final class NotificationSoundStore {
    static let shared = NotificationSoundStore()

    private(set) var settings: NotificationSoundSettings

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let soundsDirectory: URL
    @ObservationIgnored private let bundle: Bundle
    /// The sounds changed for one server (a project or a session), or for
    /// every server (nil).
    @ObservationIgnored var onChange: (UUID?) -> Void
    @ObservationIgnored private let player = SoundPreviewPlayer()
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg",
                                                 category: "sounds")

    static let defaultsKey = "codeg.notificationSounds.v1"

    /// `Library/Sounds` of the app's container.
    nonisolated static var librarySounds: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard, soundsDirectory: URL = NotificationSoundStore.librarySounds,
         bundle: Bundle = .main, onChange: ((UUID?) -> Void)? = nil) {
        self.defaults = defaults
        self.soundsDirectory = soundsDirectory
        self.bundle = bundle
        self.onChange = onChange ?? { server in PushRegistration.shared.soundsChanged(server: server) }
        var loaded = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(NotificationSoundSettings.self, from: $0) }
            ?? NotificationSoundSettings()
        // An import whose file went (a restore without it) is forgotten, and
        // so is every choice that named it.
        for sound in loaded.imports where !FileManager.default.fileExists(
            atPath: soundsDirectory.appendingPathComponent(sound.fileName).path) {
            loaded.removeImport(sound.fileName)
        }
        settings = loaded
    }

    // MARK: - Choices

    func sound(for target: NotificationSoundTarget) -> NotificationSound {
        settings.sound(for: target)
    }

    /// Pick `sound` for `target`, play it, save it and send it.
    func choose(_ sound: NotificationSound, for target: NotificationSoundTarget) {
        preview(sound)
        guard settings.sound(for: target) != sound else { return }
        settings.set(sound, for: target)
        save()
        onChange(Self.server(of: target))
    }

    /// What goes to `server` with its registration.
    func payload(for server: UUID) -> NotificationSoundPayload {
        settings.payload(for: server)
    }

    /// The server answered the registration that sent `sent`: take in the
    /// projects and sessions it dropped.
    func adopt(_ echo: NotificationSoundPayload, sent: NotificationSoundPayload, server: UUID) {
        var next = settings
        next.adopt(echo, sent: sent, server: server)
        guard next != settings else { return }
        settings = next
        save()
    }

    /// A server was removed: its projects and sessions go with it.
    func forgetServer(_ server: UUID) {
        guard settings.servers[server.uuidString] != nil else { return }
        settings.forgetServer(server)
        save()
    }

    // MARK: - Imports

    /// Convert the audio file at `url` (from Files: security-scoped) into
    /// `Library/Sounds` and add it to the imported sounds.
    func importSound(from url: URL) async throws -> ImportedSound {
        let directory = soundsDirectory
        let fileName = "import-\(UUID().uuidString.prefix(8).lowercased()).caf"
        let result = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try NotificationSoundImporter.convert(from: url, into: directory, fileName: fileName)
        }.value
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let sound = ImportedSound(fileName: fileName, name: name.isEmpty ? String(localized: "Imported sound") : name,
                                  seconds: result.seconds, trimmed: result.trimmed)
        settings.imports.append(sound)
        save()
        log.info("Imported a sound (\(result.seconds, format: .fixed(precision: 1)) s, trimmed: \(result.trimmed))")
        return sound
    }

    func rename(_ sound: ImportedSound, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = settings.imports.firstIndex(where: { $0.fileName == sound.fileName }) else {
            return
        }
        settings.imports[index].name = String(name.prefix(60))
        save()
    }

    /// Delete an import and its file; what played it plays the default
    /// again, on every server.
    func delete(_ sound: ImportedSound) {
        player.stop()
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(sound.fileName))
        settings.removeImport(sound.fileName)
        save()
        onChange(nil)
    }

    // MARK: - Preview

    /// Play a sound as a notification would (nothing for the default sound
    /// or none).
    func preview(_ sound: NotificationSound) {
        guard let name = settings.playable(sound).fileName, let url = url(of: name) else {
            player.stop()
            return
        }
        player.play(url)
    }

    /// Where a sound file is: a Codeg tone in the app bundle, an import in
    /// `Library/Sounds`.
    func url(of fileName: String) -> URL? {
        if CodegTone.named(fileName) != nil {
            let base = (fileName as NSString).deletingPathExtension
            return bundle.url(forResource: base, withExtension: "caf")
        }
        let url = soundsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func server(of target: NotificationSoundTarget) -> UUID? {
        switch target {
        case .project(let server, _, _), .session(let server, _, _, _, _): server
        case .kind, .critical: nil
        }
    }
}

/// Plays a sound file through System Sound Services, as iOS plays a
/// notification's: no audio session of the app's own (Talk, read aloud and a
/// recording keep theirs), mixed with other audio, at the ringer volume and
/// silent with the Ring/Silent switch.
final class SoundPreviewPlayer {
    private var current: SystemSoundID = 0

    func play(_ url: URL) {
        stop()
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return }
        current = id
        AudioServicesPlaySystemSoundWithCompletion(id) {
            AudioServicesDisposeSystemSoundID(id)
        }
    }

    /// Stop the sound playing, if any.
    func stop() {
        guard current != 0 else { return }
        AudioServicesDisposeSystemSoundID(current)
        current = 0
    }
}
