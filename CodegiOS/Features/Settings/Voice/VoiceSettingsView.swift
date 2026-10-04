import SwiftUI

/// Settings › Voice: voice typing (on-device whisper, see
/// ``VoiceTypingSection``), Camera Control to talk, then the on-device
/// read-aloud voice (BlueTTS 2.5, Hebrew and English) — its 575 MB model
/// download — plus the voice, the speed and what gets read.
struct VoiceSettingsView: View {
    /// The selected server, for dictation clean-up's status.
    var client: CodegClient? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var cameraTalkProblem: String?
    @State private var confirmDownload = false
    @State private var confirmDelete = false
    @State private var voice = VoicePrefs.voice
    @State private var speed = VoicePrefs.speed
    @State private var readCode = VoicePrefs.readCode
    @State private var readToolOutput = VoicePrefs.readToolOutput

    private var models: ModelPackStore { VoiceModelStore.shared }
    private var player: ReadAloudPlayer { ReadAloudPlayer.shared }

    private static let sampleID = "voice-settings-sample"
    private static let sample = "שלום! זו הקראה לדוגמה: עדכנתי את ה-Dockerfile ודחפתי ל-main. Everything builds."

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    VoiceTypingSection(client: client)
                    if CameraTalkController.isSupported {
                        cameraTalkSection
                    }
                    modelSection
                    voiceSection
                    readingSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .screenTitle("Voice", compact: horizontalSizeClass == .compact)
        .onAppear { models.refreshFromDisk() }
        .alert("Download the voice?", isPresented: $confirmDownload) {
            Button("Download 575 MB") { models.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The BlueTTS voice model is about 575 MB. It downloads in the background, even with the app closed. Wi-Fi is best.")
        }
        .alert("Delete the voice?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                player.stop()
                models.delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Read aloud then uses the iPhone's own voice until you download it again.")
        }
    }

    // MARK: - Camera Control

    private var cameraTalk: CameraTalkController { CameraTalkController.shared }

    private var cameraTalkSection: some View {
        EditorSection(
            title: "Camera Control",
            footer: "With a session open, hold the Camera Control and speak, then let go: the message is transcribed on this iPhone, cleaned up if that's on, and sent to the session's agent. A quick click does nothing. iOS lets an app use the Camera Control only while its camera runs, so with this on, the camera runs at its lowest quality whenever a session is on screen; nothing is recorded or saved, and the green dot shows it. The volume buttons become talk keys as well, and pressing one while holding another throws the recording away. Change the volume from Control Center, or turn this off."
        ) {
            settingRow("Camera Control to talk", hint: cameraTalkProblem.map { LocalizedStringKey($0) }
                        ?? "Also the button at the top of a session.") {
                Toggle("", isOn: Binding(get: { cameraTalk.isEnabled }, set: { on in
                    cameraTalkProblem = nil
                    guard on else {
                        cameraTalk.setEnabled(false)
                        return
                    }
                    Task {
                        switch await cameraTalk.enable() {
                        case .enabled: break
                        case .cameraDenied:
                            cameraTalkProblem = "Camera access is off for \(AppIdentity.displayName). Allow it in the Settings app."
                        case .noCamera:
                            cameraTalkProblem = "This device has no camera."
                        }
                    }
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
            rowDivider
            settingRow("Catch the first words (keeps the microphone ready)",
                       hint: "Starting the microphone takes a moment, which cut off the first words. With this on, the microphone stays on while the mode runs for a session on screen, so the orange dot shows. It keeps only the last 1.5 seconds, in memory, and throws them away unless you press. It uses the iPhone's microphone, so AirPods keep playing in full quality, and it steps aside while a reply is read aloud.") {
                Toggle("", isOn: Binding(get: { cameraTalk.catchFirstWords }, set: { cameraTalk.catchFirstWords = $0 }))
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            rowDivider
            settingRow("Show the camera in the indicator",
                       hint: "A small live view next to \"Hold the Camera Control to talk\". Try it if the Camera Control doesn't respond.") {
                Toggle("", isOn: Binding(get: { cameraTalk.showPreview }, set: { cameraTalk.showPreview = $0 }))
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        EditorSection(
            title: "On-Device Voice",
            footer: "BlueTTS 2.5 with RenikudPlus reads Hebrew and English code terms in one voice, entirely on this iPhone. Without it, the iPhone's own Hebrew and English voices read instead."
        ) {
            settingRow("BlueTTS model", hint: LocalizedStringKey(statusText)) {
                statusAccessory
            }
            if case .downloading = models.state {
                ProgressView(value: models.progress)
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            rowDivider
            modelActions
        }
    }

    private var statusText: String {
        let total = Self.megabytes(VoiceModelCatalog.totalBytes)
        switch models.state {
        case .notDownloaded:
            return models.bytesDone > 0
                ? "Partly downloaded (\(Self.megabytes(models.bytesDone)) of \(total))."
                : "Not downloaded (\(total))."
        case .downloading:
            return "Downloading… \(Int(models.progress * 100))% (\(Self.megabytes(models.bytesDone)) of \(total))"
        case .paused:
            return "Paused at \(Self.megabytes(models.bytesDone)) of \(total)."
        case .verifying:
            return "Checking the files…"
        case .ready:
            return "Ready (\(total) on this iPhone)."
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch models.state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
        case .downloading, .verifying:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var modelActions: some View {
        switch models.state {
        case .notDownloaded:
            actionRow("Download", systemImage: "arrow.down.circle") { confirmDownload = true }
        case .failed:
            actionRow("Try again", systemImage: "arrow.clockwise") { models.start() }
        case .downloading:
            actionRow("Pause", systemImage: "pause.circle") { models.pause() }
        case .paused:
            actionRow("Resume", systemImage: "play.circle") { models.start() }
        case .verifying:
            EmptyView()
        case .ready:
            actionRow("Delete the model", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        EditorSection(title: "Voice") {
            settingRow("Speaker", hint: "BlueTTS voices. The system voice is used without the model.") {
                Menu {
                    ForEach(VoiceModelCatalog.voices, id: \.self) { name in
                        Button {
                            voice = name
                            VoicePrefs.voice = name
                        } label: {
                            if name == voice {
                                Label(name.capitalized, systemImage: "checkmark")
                            } else {
                                Text(verbatim: name.capitalized)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: voice.capitalized).font(.subheadline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            rowDivider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speed").font(.body).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(verbatim: String(format: "%.1f×", speed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $speed, in: 0.7...1.5, step: 0.1, onEditingChanged: { editing in
                    if !editing { VoicePrefs.speed = speed }
                })
                .tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            rowDivider
            actionRow(player.isReading(Self.sampleID) ? "Stop" : "Play a sample",
                      systemImage: player.isReading(Self.sampleID) ? "stop.circle" : "play.circle") {
                VoicePrefs.speed = speed
                player.toggle(id: Self.sampleID, title: "Voice sample", text: Self.sample)
            }
            if let error = player.lastError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - What gets read

    private var readingSection: some View {
        EditorSection(
            title: "Reading",
            footer: "Read aloud reads a reply's prose with the Markdown removed. It keeps reading with the screen locked; the lock screen can pause or stop it."
        ) {
            settingRow("Read code blocks", hint: "Fenced code is skipped unless this is on.") {
                Toggle("", isOn: Binding(get: { readCode }, set: {
                    readCode = $0
                    VoicePrefs.readCode = $0
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
            rowDivider
            settingRow("Read tool output", hint: "Tool calls and their results are skipped unless this is on.") {
                Toggle("", isOn: Binding(get: { readToolOutput }, set: {
                    readToolOutput = $0
                    VoicePrefs.readToolOutput = $0
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - Helpers

    private static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    @ViewBuilder
    private func settingRow<Trailing: View>(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String, role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(role == .destructive ? Theme.danger : Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16)
    }
}
