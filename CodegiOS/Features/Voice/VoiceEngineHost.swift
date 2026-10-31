import Foundation
import Observation
import UIKit
import os
import BlueTTSKit
import BlueTTSEspeak

/// A loaded voice: BlueTTS in the app, a fake in the tests.
protocol HostedVoice: AnyObject, Sendable {
    /// ONNX Runtime threads it was loaded with.
    var threads: Int { get }
    /// Load every graph now instead of on first use.
    func load() async throws
    func synthesizeStream(_ text: String, options: SynthesisOptions,
                          firstChunkMaxChars: Int) -> AsyncThrowingStream<AudioChunk, Error>
}

extension BlueTTS: HostedVoice {
    var threads: Int { configuration.threads }
}

/// Who uses the voice; it stays loaded while any lease is held.
enum VoiceEngineLease: String, CaseIterable, Sendable {
    case readAloud
    case talk
    case lab
}

/// The one BlueTTS (Hebrew and English speech, ~0.9 GB in memory once
/// loaded), shared by read aloud and Talk, so the model never loads twice.
///
/// - It is made on first use; its graphs load on the first synthesis (or
///   ``preload()``).
/// - With no lease held it is dropped after 180 s, or at once on a memory
///   warning.
/// - ``setThreadCap(_:)``: Talk caps it at 4 threads, leaving cores for the
///   microphone's models. A loaded voice with more threads than the cap is
///   dropped and comes back with the cap on its next use; a lower one stays.
@MainActor
@Observable
final class VoiceEngineHost {
    static let shared = VoiceEngineHost()

    typealias Lease = VoiceEngineLease

    private(set) var leases: Set<Lease> = []
    /// A voice is made (its graphs load with the first synthesis).
    private(set) var isLoaded = false
    /// Most ONNX Runtime threads a voice is loaded with; nil for no cap.
    private(set) var threadCap: Int?

    @ObservationIgnored private var voice: HostedVoice?
    @ObservationIgnored private let makeVoice: @MainActor (Int) throws -> HostedVoice
    @ObservationIgnored private let defaultThreads: Int
    @ObservationIgnored private let idleUnload: Duration
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "codeg",
                                                 category: "voice-engine")

    /// `makeVoice` makes a voice with that many threads (BlueTTS from the
    /// downloaded models in the app). `defaultThreads`: without a cap.
    init(makeVoice: (@MainActor (Int) throws -> HostedVoice)? = nil,
         defaultThreads: Int = BlueTTSConfiguration().threads,
         idleUnload: Duration = .seconds(180),
         notificationCenter: NotificationCenter = .default) {
        self.makeVoice = makeVoice ?? { threads in try VoiceEngineHost.makeBlueTTS(threads: threads) }
        self.defaultThreads = max(1, defaultThreads)
        self.idleUnload = idleUnload
        observers.append(notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        })
    }

    /// BlueTTS over the models ``VoiceModelStore`` downloaded, with English
    /// phonemes from espeak-ng, as read aloud always made it.
    private static func makeBlueTTS(threads: Int) throws -> HostedVoice {
        var configuration = BlueTTSConfiguration()
        configuration.defaultVoice = VoicePrefs.voice
        configuration.threads = threads
        let phonemizer = try EspeakPhonemizer()
        return BlueTTS(modelDirectory: VoiceModelStore.shared.modelsDirectory,
                       englishPhonemizer: phonemizer,
                       configuration: configuration)
    }

    /// The threads a voice is made with now.
    var threads: Int { min(defaultThreads, max(1, threadCap ?? defaultThreads)) }

    // MARK: - Leases

    func acquire(_ lease: Lease) {
        leases.insert(lease)
        unloadTask?.cancel()
        unloadTask = nil
    }

    func release(_ lease: Lease) {
        guard leases.remove(lease) != nil, leases.isEmpty else { return }
        scheduleIdleUnload()
    }

    // MARK: - The voice

    /// Cap the voice's threads (Talk: 4), or lift the cap (nil).
    func setThreadCap(_ cap: Int?) {
        threadCap = cap.map { max(1, $0) }
        if let voice, voice.threads > threads {
            // Synthesis already under way keeps the old one until it ends.
            log.info("Dropping the voice loaded with \(voice.threads) threads for \(self.threads)")
            dropVoice()
        }
    }

    /// The voice, made if needed. Throws when it can't be made (espeak-ng's
    /// data didn't load).
    func loadedVoice() throws -> HostedVoice {
        if let voice { return voice }
        let made = try makeVoice(threads)
        voice = made
        isLoaded = true
        return made
    }

    /// Load the graphs ahead of the first sentence.
    func preload() async throws {
        let voice = try loadedVoice()
        try await voice.load()
    }

    /// BlueTTS's `synthesizeStream`, on the shared voice: sentence by
    /// sentence, the first chunk cut at a comma when it is longer than
    /// `firstChunkMaxChars`.
    func synthesizeStream(_ text: String, options: SynthesisOptions,
                          firstChunkMaxChars: Int = 90) throws -> AsyncThrowingStream<AudioChunk, Error> {
        try loadedVoice().synthesizeStream(text, options: options, firstChunkMaxChars: firstChunkMaxChars)
    }

    // MARK: - Unloading

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        let delay = idleUnload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.leases.isEmpty else { return }
            self.unloadTask = nil
            self.dropVoice()
        }
    }

    private func memoryWarning() {
        guard leases.isEmpty, voice != nil else { return }
        log.info("Dropping the voice on a memory warning")
        dropVoice()
    }

    private func dropVoice() {
        voice = nil
        isLoaded = false
    }
}
