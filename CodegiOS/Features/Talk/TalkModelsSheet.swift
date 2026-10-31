import SwiftUI

/// Shown when Talk is tapped and a model it needs isn't on this iPhone yet:
/// each download with its size, what it does for Talk and its state, one
/// button for the required ones (and the voice), and Start Talk once the
/// required ones are here. Swiping the sheet away is Cancel too.
struct TalkModelsSheet: View {
    var onStart: () -> Void
    var onCancel: () -> Void

    /// Start or Cancel was tapped (otherwise closing the sheet cancels).
    @State private var answered = false

    /// Required first, then the voice and whisper.
    private static var requirements: [TalkModels.Requirement] {
        TalkModels.Requirement.allCases.filter { $0.isRequired }
            + TalkModels.Requirement.allCases.filter { !$0.isRequired }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Talk listens and speaks on this iPhone, so it needs these models first. Only the transcribed words go to the session.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                        EditorSection(
                            title: "Models",
                            footer: "Wi-Fi is best. Downloads continue in the background, even with the app closed."
                        ) {
                            ForEach(Self.requirements) { requirement in
                                if requirement != Self.requirements.first { InsetDivider(leading: 16) }
                                Row(requirement: requirement)
                            }
                        }
                        actions
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Talk needs a few models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(onCancel) }
                        .tint(Theme.textSecondary)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            for requirement in TalkModels.Requirement.allCases {
                TalkModels.store(for: requirement)?.refreshFromDisk()
            }
        }
        .onDisappear {
            if !answered { onCancel() }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var actions: some View {
        let canStart = TalkModels.missingRequired.isEmpty
        let downloads = downloadsToStart
        VStack(spacing: 10) {
            if !downloads.isEmpty {
                FlatPrimaryButton(
                    title: downloadTitle(downloads),
                    systemImage: "arrow.down.circle",
                    tint: canStart ? Theme.accentDim : Theme.accent,
                    onTint: canStart ? Theme.accent : Theme.onAccent
                ) {
                    for requirement in downloads { TalkModels.store(for: requirement)?.start() }
                }
            } else if !canStart {
                FlatPrimaryButton(title: "Downloading…", isLoading: true) {}
            }
            FlatPrimaryButton(
                title: "Start Talk",
                systemImage: "waveform",
                tint: canStart ? Theme.accent : Theme.accentDim,
                onTint: canStart ? Theme.onAccent : Theme.accent
            ) {
                finish(onStart)
            }
            .disabled(!canStart)
            if let note = startNote(canStart: canStart) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The missing required downloads, and the voice, that aren't running.
    private var downloadsToStart: [TalkModels.Requirement] {
        var wanted = TalkModels.missingRequired
        if !TalkModels.isReady(.voice) { wanted.append(.voice) }
        return wanted.filter { requirement in
            guard let store = TalkModels.store(for: requirement) else { return false }
            switch store.state {
            case .notDownloaded, .paused, .failed: return true
            case .downloading, .verifying, .ready: return false
            }
        }
    }

    private func downloadTitle(_ downloads: [TalkModels.Requirement]) -> LocalizedStringKey {
        let bytes = downloads.reduce(Int64(0)) { total, requirement in
            total + (TalkModels.store(for: requirement)?.bytesMissing ?? TalkModels.bytes(for: requirement))
        }
        let size = TalkModels.megabytes(bytes)
        let required = downloads.contains { $0.isRequired }
        let voice = downloads.contains(.voice)
        if required && voice { return "Download required and the voice (\(size))" }
        if required { return "Download required (\(size))" }
        return "Download the voice (\(size))"
    }

    private func startNote(canStart: Bool) -> LocalizedStringKey? {
        if !canStart { return "Talk can start once the required models are on this iPhone." }
        if !TalkModels.isReady(.voice) { return "Until the voice is here, Talk speaks with the iPhone's own voices." }
        return nil
    }

    private func finish(_ choice: () -> Void) {
        answered = true
        choice()
    }

    // MARK: - Row

    /// One download: what it is for, its size and state, and its button.
    private struct Row: View {
        let requirement: TalkModels.Requirement

        private var store: ModelPackStore? { TalkModels.store(for: requirement) }
        private var isReady: Bool { TalkModels.isReady(requirement) }
        private var size: String { TalkModels.megabytes(TalkModels.bytes(for: requirement)) }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: requirement.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    accessory
                }
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tagColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tagColor.opacity(0.14), in: Capsule())
                    Text(verbatim: size)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(verbatim: requirement.purpose)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Theme.danger : Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .tint(isPaused ? Theme.textTertiary : Theme.accent)
                }
                button
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var tag: LocalizedStringKey {
            switch requirement {
            case .liveTranscriber, .turnClassifier: "Required"
            case .voice: "For the natural voice"
            case .whisper: "Optional"
            }
        }

        private var tagColor: Color { requirement.isRequired ? Theme.accent : Theme.textSecondary }

        private var statusText: String {
            guard let store else { return "Not in this version of the app." }
            if isReady { return "Ready (\(size) on this iPhone)." }
            let done = TalkModels.megabytes(store.bytesDone)
            switch store.state {
            case .notDownloaded:
                return store.bytesDone > 0 ? "Partly downloaded (\(done) of \(size))." : "Not downloaded yet."
            case .downloading:
                return "Downloading… \(Int(store.progress * 100))% (\(done) of \(size))"
            case .paused:
                return "Paused at \(done) of \(size)."
            case .verifying:
                return "Checking the files…"
            case .ready:
                return "Ready (\(size) on this iPhone)."
            case .failed(let message):
                return "Download failed: \(message)"
            }
        }

        /// How far the download is, while it runs or is paused.
        private var progress: Double? {
            guard let store, !isReady else { return nil }
            switch store.state {
            case .downloading, .paused: return store.progress
            default: return nil
            }
        }

        private var isPaused: Bool {
            guard let store, !isReady else { return false }
            return store.state == .paused
        }

        private var isFailed: Bool {
            guard let store, !isReady, case .failed = store.state else { return false }
            return true
        }

        @ViewBuilder
        private var accessory: some View {
            if isReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            } else if let store {
                switch store.state {
                case .downloading, .verifying:
                    ProgressView().controlSize(.small)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                default:
                    EmptyView()
                }
            }
        }

        @ViewBuilder
        private var button: some View {
            if let store, !isReady {
                switch store.state {
                case .notDownloaded:
                    AccentPillButton(title: "Download", systemImage: "arrow.down") { store.start() }
                case .downloading:
                    AccentPillButton(title: "Pause", systemImage: "pause.fill") { store.pause() }
                case .paused:
                    AccentPillButton(title: "Resume", systemImage: "play.fill") { store.start() }
                case .failed:
                    AccentPillButton(title: "Try again", systemImage: "arrow.clockwise") { store.start() }
                case .verifying, .ready:
                    EmptyView()
                }
            }
        }
    }
}
