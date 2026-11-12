import AudioToolbox
import AVFoundation
import Foundation
import Observation
import os

/// This iPhone's notification sounds: the choices (UserDefaults), the
/// imported files and the volume slider's quieter copies (`Library/Sounds`,
/// where iOS looks first for a push's sound), and the previews. Every change
/// goes to the saved servers with the push registration
/// (``PushRegistration/soundsChanged(server:)``): all notifications, a kind,
/// the critical sessions, an import or the volume to every server, a project
/// or a session to its own. A registration names a volume copy only once
/// the copy is there (``preparedPayload(for:)``); a copy no server's pushes
/// and no choice name any more is deleted (``deleteUnusedCopies()``).
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
    @ObservationIgnored private let player: any SoundPreviewPlaying
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// The files each server's pushes name, by server profile id: what it
    /// kept at its last registration. A server that couldn't be reached
    /// since a change still names the old ones.
    @ObservationIgnored private var serverFiles: [String: [String]]
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg",
                                                 category: "sounds")

    static let defaultsKey = "codeg.notificationSounds.v1"
    static let serverFilesKey = "codeg.notificationSounds.serverFiles.v1"

    /// `Library/Sounds` of the app's container.
    nonisolated static var librarySounds: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard, soundsDirectory: URL = NotificationSoundStore.librarySounds,
         bundle: Bundle = .main, player: (any SoundPreviewPlaying)? = nil, onChange: ((UUID?) -> Void)? = nil) {
        self.defaults = defaults
        self.soundsDirectory = soundsDirectory
        self.bundle = bundle
        self.player = player ?? SoundPreviewPlayer()
        self.onChange = onChange ?? { server in PushRegistration.shared.soundsChanged(server: server) }
        serverFiles = defaults.dictionary(forKey: Self.serverFilesKey) as? [String: [String]] ?? [:]
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

    /// A server was removed: its projects and sessions go with it, and the
    /// volume copies only its pushes named.
    func forgetServer(_ server: UUID) {
        if settings.servers[server.uuidString] != nil {
            settings.forgetServer(server)
            save()
        }
        if serverFiles.removeValue(forKey: server.uuidString) != nil {
            defaults.set(serverFiles, forKey: Self.serverFilesKey)
            deleteUnusedCopies()
        }
    }

    // MARK: - Volume

    /// Set the volume slider: play what it changes at the new level (the
    /// task ends once it plays), save it and send it to every server.
    @discardableResult
    func setVolume(_ level: Int) -> Task<Void, Never> {
        let level = NotificationSoundVolume.clamped(level)
        let changed = level != settings.volume
        if changed {
            settings.volume = level
            save()
        }
        let playing = preview(settings.volumeSample)
        if changed { onChange(nil) }
        return playing
    }

    /// What goes to `server` with its registration, once the volume copies
    /// it names are in `Library/Sounds`. A copy that couldn't be made (a
    /// full disk) goes as its file, at full volume, rather than as a name iOS
    /// can't find, which would play the default sound.
    func preparedPayload(for server: UUID) async -> NotificationSoundPayload {
        var payload = settings.payload(for: server)
        await makeCopies(Self.files(in: payload))
        let made = { (name: String) -> String in
            guard let copy = NotificationSoundVolume.copy(name), self.url(of: name) == nil else { return name }
            return copy.original
        }
        payload.kinds = payload.kinds.mapValues(made)
        payload.critical = payload.critical.map(made)
        payload.projects = payload.projects.mapValues(made)
        payload.sessions = payload.sessions.mapValues(made)
        return payload
    }

    /// The server took a registration and answered with what it kept (nil:
    /// an older server, whose pushes play the default sound). Its pushes
    /// name those files from now on, so the copies nothing names go.
    func registered(_ kept: NotificationSoundPayload?, server: UUID) {
        let files = Self.files(in: kept).sorted()
        if serverFiles[server.uuidString] != files {
            serverFiles[server.uuidString] = files
            defaults.set(serverFiles, forKey: Self.serverFilesKey)
        }
        deleteUnusedCopies()
    }

    /// Delete the volume copies in `Library/Sounds` that no server's pushes
    /// name (as it kept them at its last registration) and no choice plays
    /// at the current volume: an old level, a sound no longer chosen, a
    /// preview's.
    func deleteUnusedCopies() {
        let current = settings.chosenFiles.map { NotificationSoundVolume.fileName(of: $0, level: settings.volume) }
        let keep = Set(serverFiles.values.joined()).union(current)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: soundsDirectory.path) else { return }
        for name in names where NotificationSoundVolume.copy(name) != nil && !keep.contains(name) {
            do {
                try FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(name))
            } catch {
                log.error("Couldn't delete \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Make the volume copies among `files` that aren't there yet, from the
    /// tone in the app bundle or the import, off the main actor.
    func makeCopies(_ files: Set<String>) async {
        var jobs: [(source: URL, destination: URL, gain: Float)] = []
        for file in files.sorted() {
            guard let copy = NotificationSoundVolume.copy(file) else { continue }
            let destination = soundsDirectory.appendingPathComponent(file)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let source = url(of: copy.original) else { continue }
            jobs.append((source, destination, NotificationSoundVolume.gain(copy.level)))
        }
        guard !jobs.isEmpty else { return }
        let log = self.log
        await Task.detached(priority: .userInitiated) {
            for job in jobs {
                do {
                    try NotificationSoundCopier.write(from: job.source, to: job.destination, gain: job.gain)
                } catch {
                    log.error("Couldn't make \(job.destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }.value
    }

    /// Every sound file a payload names.
    nonisolated static func files(in payload: NotificationSoundPayload?) -> Set<String> {
        guard let payload else { return [] }
        let names = Array(payload.kinds.values) + Array(payload.projects.values) + Array(payload.sessions.values)
            + [payload.critical].compactMap { $0 }
        return Set(names.filter(NotificationSound.isSoundFileName))
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
    /// again, on every server. Its volume copies go once no server names
    /// them.
    func delete(_ sound: ImportedSound) {
        previewTask?.cancel()
        player.stop()
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(sound.fileName))
        settings.removeImport(sound.fileName)
        save()
        deleteUnusedCopies()
        onChange(nil)
    }

    // MARK: - Preview

    /// Play a sound as a notification would, at the volume (nothing for the
    /// iOS sound or none). The task ends once it plays.
    @discardableResult
    func preview(_ sound: NotificationSound) -> Task<Void, Never> {
        previewTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let url = await self.previewFile(for: sound)
            guard !Task.isCancelled else { return }
            if let url {
                self.player.play(url)
            } else {
                self.player.stop()
            }
        }
        previewTask = task
        return task
    }

    /// The file a preview of `sound` plays: the one its pushes play at the
    /// volume (made if it isn't there yet).
    func previewFile(for sound: NotificationSound) async -> URL? {
        guard let name = settings.playable(sound).fileName else { return nil }
        let file = NotificationSoundVolume.fileName(of: name, level: settings.volume)
        await makeCopies([file])
        return url(of: file)
    }

    /// Where a sound file is: a Codeg tone in the app bundle, an import or a
    /// volume copy in `Library/Sounds`.
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
        case .all, .kind, .critical: nil
        }
    }
}

/// What plays a preview (``SoundPreviewPlayer``; a stand-in in tests).
protocol SoundPreviewPlaying: AnyObject {
    func play(_ url: URL)
    func stop()
}

/// Writes a volume copy of a sound: its audio scaled by a gain, as 16-bit
/// linear PCM at its own rate and channels in a Core Audio file, with no
/// file protection, so a push can play it while the iPhone is locked.
enum NotificationSoundCopier {
    static func write(from source: URL, to destination: URL, gain: Float) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else {
            throw NotificationSoundImporter.Failure.silent
        }
        try input.read(into: buffer)
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for i in 0..<Int(buffer.frameLength) { samples[i] *= gain }
            }
        }
        // Written aside and moved in whole, so iOS never finds half a file
        // under the name.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sound-\(UUID().uuidString.prefix(8)).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: scratch, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
        file.close()
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: scratch.path)
        do {
            try FileManager.default.moveItem(at: scratch, to: destination)
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            // A preview or another registration made the same copy meanwhile.
        }
    }
}

/// Plays a sound file through System Sound Services, as iOS plays a
/// notification's: no audio session of the app's own (Talk, read aloud and a
/// recording keep theirs), mixed with other audio, at the ringer volume and
/// silent with the Ring/Silent switch.
final class SoundPreviewPlayer: SoundPreviewPlaying {
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
