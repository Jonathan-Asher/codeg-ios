import SwiftUI

/// Settings › Voice › Talk: how Talk listens and answers (kept on this
/// iPhone), the agent's language and how it addresses you (the codeg
/// server's Talk settings), the downloads Talk runs on, and the Lab.
struct TalkSettingsSection: View {
    /// The selected server, which keeps the agent's language and address.
    var client: CodegClient? = nil

    /// Where the server's Talk settings stand on this screen.
    enum ServerPhase: Equatable {
        /// No server is selected.
        case noClient
        case loading
        case ready
        /// The server predates Talk.
        case unsupported
        case failed(String)
    }

    /// The server's Talk settings last loaded or saved, as JSON-encoded
    /// ``TalkSettings``, so Talk has them before the server answers.
    nonisolated static let serverSettingsKey = "codeg.talk.serverSettings"

    private let prefs = TalkPrefs()
    @State private var handsFree = TalkPrefs().handsFree
    @State private var patience = TalkPrefs().patience
    @State private var interruptBySpeaking = TalkPrefs().interruptBySpeaking
    @State private var speakProgress = TalkPrefs().speakProgress
    @State private var shareTelemetry = TalkPrefs().shareTelemetry
    @State private var server = ServerPhase.loading
    /// The server `serverSettings` belong to.
    @State private var serverURL: URL?
    @State private var serverSettings = TalkSettingsSection.cachedServerSettings() ?? TalkSettings()
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmDownload: TalkModels.Requirement?
    @State private var confirmDelete: TalkModels.Requirement?

    private var voice: ModelPackStore { VoiceModelStore.shared }

    var body: some View {
        VStack(spacing: 22) {
            talkSection
            serverSection
            modelsSection
            labSection
        }
        .onAppear {
            // Talk and the Lab change some of these too.
            handsFree = prefs.handsFree
            patience = prefs.patience
            interruptBySpeaking = prefs.interruptBySpeaking
            speakProgress = prefs.speakProgress
            shareTelemetry = prefs.shareTelemetry
            for requirement in TalkModels.Requirement.allCases {
                TalkModels.store(for: requirement)?.refreshFromDisk()
            }
        }
        .task(id: client?.baseURL) { await loadServerSettings() }
        .alert(
            downloadTitle,
            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
            presenting: confirmDownload
        ) { requirement in
            Button("Download \(TalkModels.megabytes(TalkModels.bytes(for: requirement)))") {
                TalkModels.store(for: requirement)?.start()
            }
            Button("Cancel", role: .cancel) {}
        } message: { requirement in
            Text("It is \(TalkModels.megabytes(TalkModels.bytes(for: requirement))) and downloads in the background, even with the app closed. Wi-Fi is best.")
        }
        .alert(
            deleteTitle,
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { requirement in
            Button("Delete", role: .destructive) {
                if requirement == .whisper { DictationController.shared.cancel() }
                TalkModels.store(for: requirement)?.delete()
            }
            Button("Cancel", role: .cancel) {}
        } message: { requirement in
            Text(Self.deleteMessage(requirement))
        }
    }

    // MARK: - Talk

    private var talkSection: some View {
        EditorSection(
            title: "Talk",
            footer: "Tap Talk in a session to talk with it hands-free, also with the screen locked and with AirPods. Listening and speech run on this iPhone; only the transcribed words go to the session."
        ) {
            settingRow("Listening", hint: "Hands-free sends what you said when you pause. Push to talk: hold the orb or the Camera Control while you speak.") {
                Menu {
                    ForEach([true, false], id: \.self) { option in
                        Button {
                            handsFree = option
                            prefs.handsFree = option
                        } label: {
                            if option == handsFree {
                                Label(Self.listeningTitle(option), systemImage: "checkmark")
                            } else {
                                Text(verbatim: Self.listeningTitle(option))
                            }
                        }
                    }
                } label: {
                    menuLabel(Self.listeningTitle(handsFree))
                }
            }
            rowDivider
            settingRow("Patience", hint: "How long a pause before Talk takes what you said: about a second at Normal, 0.7× that at Short, 1.5× at Long. It waits longer after a word like \"של\" or \"and\".") {
                Menu {
                    ForEach(TalkPatience.allCases, id: \.self) { option in
                        Button {
                            patience = option
                            prefs.patience = option
                        } label: {
                            if option == patience {
                                Label(Self.patienceTitle(option), systemImage: "checkmark")
                            } else {
                                Text(verbatim: Self.patienceTitle(option))
                            }
                        }
                    }
                } label: {
                    menuLabel(Self.patienceTitle(patience))
                }
            }
            rowDivider
            settingRow("Interrupt by speaking", hint: "Talking over a reply stops it. Off, tap the orb or press the Camera Control.") {
                Toggle("", isOn: Binding(get: { interruptBySpeaking }, set: {
                    interruptBySpeaking = $0
                    prefs.interruptBySpeaking = $0
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
            rowDivider
            settingRow("Speak progress", hint: "A short status phrase while the agent works, at most every 20 seconds.") {
                Toggle("", isOn: Binding(get: { speakProgress }, set: {
                    speakProgress = $0
                    prefs.speakProgress = $0
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - The agent's language (server)

    private var serverSection: some View {
        EditorSection(
            title: "Agent's language",
            footer: "These are your codeg server's Talk settings. The agent reads them with each spoken message."
        ) {
            settingRow("Language", hint: languageHint) {
                serverControl { languageMenu }
            }
            rowDivider
            settingRow("Address you as", hint: "How the agent addresses you in Hebrew. Neutral wording avoids gendered forms.") {
                serverControl { addressMenu }
            }
            if case .failed = server {
                rowDivider
                actionRow("Try again", systemImage: "arrow.clockwise") {
                    Task { await loadServerSettings() }
                }
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(TalkSettings.Language.allCases, id: \.self) { option in
                Button {
                    var settings = serverSettings
                    settings.language = option
                    save(settings)
                } label: {
                    if option == serverSettings.language {
                        Label(Self.languageTitle(option), systemImage: "checkmark")
                    } else {
                        Text(verbatim: Self.languageTitle(option))
                    }
                }
            }
        } label: {
            menuLabel(Self.languageTitle(serverSettings.language), enabled: server == .ready)
        }
    }

    private var addressMenu: some View {
        Menu {
            ForEach(TalkSettings.Address.allCases, id: \.self) { option in
                Button {
                    var settings = serverSettings
                    settings.address = option
                    save(settings)
                } label: {
                    if option == serverSettings.address {
                        Label(Self.addressTitle(option), systemImage: "checkmark")
                    } else {
                        Text(verbatim: Self.addressTitle(option))
                    }
                }
            }
        } label: {
            menuLabel(Self.addressTitle(serverSettings.address), enabled: server == .ready)
        }
    }

    /// A spinner while the server answers; the control, disabled unless the
    /// server's settings can be changed now.
    @ViewBuilder
    private func serverControl<Control: View>(@ViewBuilder _ control: () -> Control) -> some View {
        if server == .loading {
            ProgressView().controlSize(.small)
        } else {
            control().disabled(server != .ready || saving)
        }
    }

    /// What the language does, or why the server's settings can't be
    /// changed.
    private var languageHint: LocalizedStringKey {
        switch server {
        case .noClient:
            return "Connect to a server to change these."
        case .unsupported:
            return "This codeg server doesn't have Talk yet."
        case .failed(let message):
            return "Couldn't load these from your codeg server: \(message)"
        case .loading, .ready:
            if let saveError { return "Couldn't save the change: \(saveError)" }
            switch serverSettings.language {
            case .auto: return "Answers in your language, the one you spoke last; Hebrew when unsure."
            case .hebrew: return "Answers in Hebrew."
            case .english: return "Answers in English."
            }
        }
    }

    /// Ask the selected server for its Talk settings.
    private func loadServerSettings() async {
        let baseURL = client?.baseURL
        // Coming back to the screen refreshes without the spinner.
        let refreshing = server == .ready && serverURL == baseURL
        if serverURL != baseURL {
            serverURL = baseURL
            saving = false
        }
        saveError = nil
        guard let client else {
            server = .noClient
            return
        }
        if !refreshing { server = .loading }
        do {
            let settings = try await client.getTalkSettings()
            guard !Task.isCancelled, serverURL == baseURL else { return }
            serverSettings = settings
            server = .ready
            Self.cacheServerSettings(settings)
        } catch {
            guard !Task.isCancelled, serverURL == baseURL else { return }
            if TalkServerSupport.isMissingRoute(error) {
                server = .unsupported
            } else if !refreshing {
                server = .failed(error.localizedDescription)
            }
        }
    }

    /// Store a change on the server and show what it kept.
    private func save(_ settings: TalkSettings) {
        guard let client, server == .ready, !saving, settings != serverSettings else { return }
        let previous = serverSettings
        let baseURL = client.baseURL
        serverSettings = settings
        saving = true
        saveError = nil
        Task {
            do {
                let kept = try await client.updateTalkSettings(settings)
                guard serverURL == baseURL else { return }
                saving = false
                serverSettings = kept
                Self.cacheServerSettings(kept)
            } catch {
                guard serverURL == baseURL else { return }
                saving = false
                serverSettings = previous
                if TalkServerSupport.isMissingRoute(error) {
                    server = .unsupported
                } else {
                    saveError = error.localizedDescription
                }
            }
        }
    }

    /// The server's Talk settings last loaded or saved, if any.
    nonisolated static func cachedServerSettings() -> TalkSettings? {
        guard let data = UserDefaults.standard.data(forKey: serverSettingsKey) else { return nil }
        return try? JSONDecoder().decode(TalkSettings.self, from: data)
    }

    /// Keep the server's Talk settings for ``cachedServerSettings()``.
    nonisolated static func cacheServerSettings(_ settings: TalkSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: serverSettingsKey)
    }

    // MARK: - Models

    private var modelsSection: some View {
        EditorSection(title: "Models", footer: modelsFooter) {
            ForEach(TalkModels.Requirement.allCases) { requirement in
                if requirement != TalkModels.Requirement.allCases.first { rowDivider }
                modelBlock(requirement)
            }
        }
    }

    private var modelsFooter: LocalizedStringKey {
        let required = TalkModels.Requirement.allCases.filter { $0.isRequired }
            .reduce(Int64(0)) { $0 + TalkModels.bytes(for: $1) }
        let requiredSize = TalkModels.megabytes(required)
        let voiceSize = TalkModels.megabytes(TalkModels.bytes(for: .voice))
        let whisperSize = TalkModels.megabytes(TalkModels.bytes(for: .whisper))
        return "Live transcription and end of turn are required (\(requiredSize) together); the voice (\(voiceSize)) and whisper (\(whisperSize)) are optional. Downloads continue in the background, even with the app closed. Wi-Fi is best."
    }

    @ViewBuilder
    private func modelBlock(_ requirement: TalkModels.Requirement) -> some View {
        if let model = TalkModels.model(for: requirement), let store = TalkModels.store(for: requirement) {
            ModelPackRows(model: model, store: store,
                          onDownload: { confirmDownload = requirement },
                          onDelete: { confirmDelete = requirement })
            purposeLine(requirement.purpose)
        } else if requirement == .voice {
            voiceRows
            purposeLine(requirement.purpose + " Also under On-Device Voice below.")
        } else {
            settingRow(LocalizedStringKey(requirement.title), hint: "Not in this version of the app.") {
                EmptyView()
            }
        }
    }

    /// BlueTTS has no speech-model manifest entry: its status and download
    /// here, its deletion under On-Device Voice.
    @ViewBuilder
    private var voiceRows: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: TalkModels.Requirement.voice.title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: voiceStatusText)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            statusAccessory(voice.state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        if case .downloading = voice.state {
            ProgressView(value: voice.progress)
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        voiceActions
    }

    private var voiceStatusText: String {
        let total = TalkModels.megabytes(VoiceModelCatalog.totalBytes)
        let done = TalkModels.megabytes(voice.bytesDone)
        switch voice.state {
        case .notDownloaded:
            return voice.bytesDone > 0 ? "Partly downloaded (\(done) of \(total))." : "Not downloaded (\(total))."
        case .downloading:
            return "Downloading… \(Int(voice.progress * 100))% (\(done) of \(total))"
        case .paused:
            return "Paused at \(done) of \(total)."
        case .verifying:
            return "Checking the files…"
        case .ready:
            return "Ready (\(total) on this iPhone)."
        case .failed(let message):
            return "Download failed: \(message)"
        }
    }

    @ViewBuilder
    private var voiceActions: some View {
        switch voice.state {
        case .notDownloaded:
            rowDivider
            actionRow("Download", systemImage: "arrow.down.circle") { confirmDownload = .voice }
        case .failed:
            rowDivider
            actionRow("Try again", systemImage: "arrow.clockwise") { voice.start() }
        case .downloading:
            rowDivider
            actionRow("Pause", systemImage: "pause.circle") { voice.pause() }
        case .paused:
            rowDivider
            actionRow("Resume", systemImage: "play.circle") { voice.start() }
        case .verifying, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusAccessory(_ state: ModelPackStore.State) -> some View {
        switch state {
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

    private func purposeLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var downloadTitle: LocalizedStringKey {
        let name = confirmDownload.map { Self.downloadName($0) } ?? ""
        return "Download \(name)?"
    }

    private var deleteTitle: LocalizedStringKey {
        let name = confirmDelete.map { Self.downloadName($0) } ?? ""
        return "Delete \(name)?"
    }

    /// What the alerts call a download.
    private static func downloadName(_ requirement: TalkModels.Requirement) -> String {
        TalkModels.model(for: requirement)?.title ?? "the natural voice"
    }

    private static func deleteMessage(_ requirement: TalkModels.Requirement) -> LocalizedStringKey {
        requirement == .whisper
            ? "Voice typing needs it again before its next use. Talk goes on without it, with the live transcript."
            : "Talk needs it again before its next use."
    }

    // MARK: - Lab

    private var labSection: some View {
        EditorSection(title: "Lab") {
            NavigationLink {
                TalkLabView()
            } label: {
                settingRow("Talk Lab", hint: "Compare transcribers, time the voice, test echo on this route and see what this iPhone can do.") {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            rowDivider
            settingRow("Share Talk telemetry", hint: "After each Talk, its timings and what was heard and said, as text and never audio, go to the session's codeg server for tuning.") {
                Toggle("", isOn: Binding(get: { shareTelemetry }, set: {
                    shareTelemetry = $0
                    prefs.shareTelemetry = $0
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - Helpers

    private static func listeningTitle(_ handsFree: Bool) -> String {
        handsFree ? "Hands-free" : "Push to talk"
    }

    private static func patienceTitle(_ patience: TalkPatience) -> String {
        switch patience {
        case .short: "Short"
        case .normal: "Normal"
        case .long: "Long"
        }
    }

    private static func languageTitle(_ language: TalkSettings.Language) -> String {
        switch language {
        case .auto: "Automatic"
        case .hebrew: "Hebrew"
        case .english: "English"
        }
    }

    private static func addressTitle(_ address: TalkSettings.Address) -> String {
        switch address {
        case .auto: "Neutral wording"
        case .masculine: "Masculine"
        case .feminine: "Feminine"
        }
    }

    private func menuLabel(_ title: String, enabled: Bool = true) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title).font(.subheadline)
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary)
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

    private func actionRow(_ title: LocalizedStringKey, systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
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
