import SwiftUI

/// Settings › Voice › Voice Typing: the on-device whisper models, the
/// dictation language, and what happens after a transcript: clean-up or
/// translation through the codeg server, sending, the session context.
struct VoiceTypingSection: View {
    /// The selected server, which is asked whether clean-up is set up.
    var client: CodegClient? = nil

    @State private var language = DictationPrefs.language
    @State private var refineMode = DictationPrefs.afterTranscribing
    /// The server's answer; `nil` while asking.
    @State private var refineStatus: DictationRefineAvailability?
    @State private var autoSend = DictationPrefs.autoSend
    @State private var usePrompt = DictationPrefs.usePrompt
    @State private var confirmDownload: SpeechModelManifest.Model?
    @State private var confirmDelete: SpeechModelManifest.Model?

    private var hebrewModel: SpeechModelManifest.Model? { SpeechModelCatalog.model(id: SpeechModelCatalog.hebrewID) }
    private var multilingualModel: SpeechModelManifest.Model? {
        SpeechModelCatalog.model(id: SpeechModelCatalog.multilingualID)
    }

    var body: some View {
        VStack(spacing: 22) {
            EditorSection(
                title: "Voice Typing",
                footer: "The mic in the message bar transcribes on this iPhone with whisper (ivrit.ai's Hebrew fine-tune of large-v3-turbo); the audio never leaves it. Clean-up and translation send only the transcribed text to your codeg server, which passes it to the provider set up there. Without the model, use the mic key on the iOS keyboard."
            ) {
                if let hebrewModel {
                    ModelPackRows(model: hebrewModel, store: SpeechModelStores.store(for: hebrewModel),
                                  onDownload: { confirmDownload = hebrewModel },
                                  onDelete: { confirmDelete = hebrewModel })
                    rowDivider
                }
                settingRow("Language", hint: languageHint) {
                    Menu {
                        ForEach(DictationLanguage.allCases) { option in
                            Button {
                                language = option
                                DictationPrefs.language = option
                            } label: {
                                if option == language {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: option.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: language.title).font(.subheadline)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
                if language == .auto, let multilingualModel {
                    rowDivider
                    ModelPackRows(model: multilingualModel, store: SpeechModelStores.store(for: multilingualModel),
                                  onDownload: { confirmDownload = multilingualModel },
                                  onDelete: { confirmDelete = multilingualModel })
                }
                rowDivider
                settingRow("After transcribing", hint: LocalizedStringKey(refineHint)) {
                    Menu {
                        ForEach(DictationRefineMode.allCases) { option in
                            Button {
                                refineMode = option
                                DictationPrefs.afterTranscribing = option
                            } label: {
                                if option == refineMode {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: option.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: refineMode.menuLabel).font(.subheadline)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
            }

            EditorSection(
                title: "Sending",
                footer: "The session context gives whisper the workspace folder, the session title and a sentence of common code words, which helps it spell names and keep terms like commit or README in English letters."
            ) {
                settingRow("Send right after transcribing", hint: "Also a switch on the recording bar.") {
                    Toggle("", isOn: Binding(get: { autoSend }, set: {
                        autoSend = $0
                        DictationPrefs.autoSend = $0
                        DictationController.shared.autoSend = $0
                    }))
                    .labelsHidden()
                    .tint(Theme.accent)
                }
                rowDivider
                settingRow("Use the session context", hint: "Folder, session title and code words as a prompt.") {
                    Toggle("", isOn: Binding(get: { usePrompt }, set: {
                        usePrompt = $0
                        DictationPrefs.usePrompt = $0
                    }))
                    .labelsHidden()
                    .tint(Theme.accent)
                }
            }
        }
        .onAppear {
            autoSend = DictationController.shared.autoSend
            for model in SpeechModelCatalog.manifest.models { SpeechModelStores.store(for: model).refreshFromDisk() }
        }
        .task(id: client?.baseURL) {
            refineStatus = nil
            guard let client else { return }
            refineStatus = await TranscriptPostProcessor(transport: client).availability(maxAge: 0)
        }
        .alert(
            "Download the speech model?",
            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
            presenting: confirmDownload
        ) { model in
            Button("Download \(Self.megabytes(model.totalBytes))") { SpeechModelStores.store(for: model).start() }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("\(model.title) is \(Self.megabytes(model.totalBytes)). It downloads in the background, even with the app closed. Wi-Fi is best.")
        }
        .alert(
            "Delete the speech model?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { model in
            Button("Delete", role: .destructive) {
                DictationController.shared.cancel()
                SpeechModelStores.store(for: model).delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Voice typing needs it again before the next use.")
        }
    }

    /// What the choice does, and whether the server can do it.
    private var refineHint: String {
        guard refineMode != .asSpoken else {
            return "Exactly as transcribed. Clean-up and translation run on your codeg server; the chip on the recording bar changes it for one message."
        }
        guard client != nil else { return "Runs on your codeg server. Add or pick a server first." }
        switch refineStatus {
        case nil:
            return "Checking your codeg server…"
        case .ready(let settings)?:
            let with = settings.summary.map { " with \($0)" } ?? ""
            return "Runs on your codeg server\(with). If it fails or takes over 12 seconds, your words go in as spoken."
        case .notConfigured?:
            return "Set up translation in codeg Settings on your computer. Until then, your words go in as spoken."
        case .notAvailable?:
            return "This codeg server is too old to clean up dictation. Until it's updated, your words go in as spoken."
        case .unknown(let message)?:
            return "Couldn't ask your codeg server (\(message)). It's tried again with each message."
        }
    }

    private var languageHint: LocalizedStringKey {
        switch language {
        case .hebrew:
            "Hebrew with English terms. The ivrit.ai model, language fixed to Hebrew."
        case .english:
            "English only, with the same ivrit.ai model."
        case .auto:
            "Uses the stock multilingual whisper model, whose language detection works (ivrit.ai's doesn't). Its Hebrew is clearly weaker, and detecting costs an extra pass."
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
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

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16)
    }
}

/// Status, progress and the download / pause / resume / delete action for one
/// model download.
struct ModelPackRows: View {
    let model: SpeechModelManifest.Model
    let store: ModelPackStore
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: model.title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: statusText)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            statusAccessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        if case .downloading = store.state {
            ProgressView(value: store.progress)
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        Divider().overlay(Theme.hairline).padding(.leading, 16)
        actions
    }

    private var statusText: String {
        let total = VoiceTypingSection.megabytes(model.totalBytes)
        let done = VoiceTypingSection.megabytes(store.bytesDone)
        switch store.state {
        case .notDownloaded:
            return store.bytesDone > 0 ? "Partly downloaded (\(done) of \(total))." : "Not downloaded (\(total))."
        case .downloading:
            return "Downloading… \(Int(store.progress * 100))% (\(done) of \(total))"
        case .paused:
            return "Paused at \(done) of \(total)."
        case .verifying:
            return "Checking the files…"
        case .ready:
            return "Ready (\(total) on this iPhone). \(model.summary)"
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch store.state {
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
    private var actions: some View {
        switch store.state {
        case .notDownloaded:
            action("Download", systemImage: "arrow.down.circle", perform: onDownload)
        case .failed:
            action("Try again", systemImage: "arrow.clockwise") { store.start() }
        case .downloading:
            action("Pause", systemImage: "pause.circle") { store.pause() }
        case .paused:
            action("Resume", systemImage: "play.circle") { store.start() }
        case .verifying:
            EmptyView()
        case .ready:
            action("Delete the model", systemImage: "trash", role: .destructive, perform: onDelete)
        }
    }

    private func action(_ title: LocalizedStringKey, systemImage: String, role: ButtonRole? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
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
}
