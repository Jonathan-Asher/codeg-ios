import Foundation
import SwiftUI

/// Settings › Voice › Talk › Lab: Talk's engines measured on this iPhone
/// (``TalkLab``): the transcribers side by side, the voice's time to first
/// audio and an echo test on the current route; then Talk's echo and Smart
/// Turn settings, and what this iPhone offers.
struct TalkLabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var echoSetting = TalkPrefs().echoMode
    @State private var smartTurnActive = TalkPrefs().smartTurnActive
    @FocusState private var editingSentence: Bool

    private let prefs = TalkPrefs()

    private var lab: TalkLab { TalkLab.shared }

    init() {}

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    notices
                    transcribersSection
                    voiceSection
                    echoSection
                    tuningSection
                    deviceSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Talk Lab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            lab.appear()
            echoSetting = prefs.echoMode
            smartTurnActive = prefs.smartTurnActive
        }
        .onDisappear { lab.disappear() }
        .onChange(of: lab.talkRunning) { _, running in
            // Talk takes the microphone and the engines.
            if running { lab.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            // No test goes on in the background.
            if phase == .background { lab.cancel() }
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if lab.talkRunning {
            notice(Text("End Talk to use the Lab. While Talk runs, the microphone and the engines are its own."),
                   systemImage: "waveform.circle")
        } else if !TalkModels.missingRequired.isEmpty {
            notice(Text(verbatim: missingText), systemImage: "arrow.down.circle")
        }
    }

    private var missingText: String {
        let names = TalkModels.missingRequired.map(\.title).joined(separator: ", ")
        return "Not on this iPhone yet: \(names). Download Talk's models in Settings › Voice › Talk; until then the Lab measures what is here."
    }

    private func notice(_ text: Text, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
            text
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Transcribers

    private var transcribersSection: some View {
        EditorSection(
            title: "Transcribers",
            footer: "Tap Record, say a sentence, then tap Stop; it stops by itself at 30 seconds. The Zipformer is Talk's live transcriber: its time for the whole clip at once, and the wait after the end of speech with the clip streamed in 32 ms frames, as Talk feeds it. whisper is the final transcriber, with voice typing's language and no prompt; its first use loads it. Smart Turn hears the clip up to just after the last word, as Talk asks it at a pause; 0.5 or more says you finished. RTF is the time taken per second of audio. The audio isn't kept or sent."
        ) {
            recordRow
            if lab.activity == .transcribing {
                rowDivider
                progressRow(lab.step ?? "Transcribing…")
            }
            if let error = lab.transcriberError {
                rowDivider
                problemLine(error)
            }
            ForEach(lab.transcriptions) { result in
                rowDivider
                TalkLabTranscriptionRow(result: result, sideBySide: horizontalSizeClass == .regular)
            }
            if !lab.transcriptions.isEmpty {
                rowDivider
                actionRow("Clear", systemImage: "trash", tint: Theme.danger) { lab.clearTranscriptions() }
            }
        }
    }

    private var recordRow: some View {
        let recording = lab.activity == .recording
        let enabled = recording || (lab.canStart && lab.canTranscribe)
        return Button {
            editingSentence = false
            lab.toggleRecording()
        } label: {
            HStack(spacing: 12) {
                if recording {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .foregroundStyle(Theme.danger)
                } else {
                    Label("Record", systemImage: "mic.circle")
                        .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary)
                }
                Spacer(minLength: 12)
                if recording {
                    Text(verbatim: TalkLabFormat.length(lab.recordingElapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    TalkLabLevelBar(level: lab.recordingLevel)
                }
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Voice

    private var voiceSection: some View {
        EditorSection(
            title: "Voice",
            footer: "Time to first audio runs from the call to the first sound out of the synthesizer, the first chunk cut at a comma when it runs past about 90 characters, as for the first sentence of a reply. BlueTTS runs with Talk's 4 threads; its first use loads it. RTF is the synthesis time per second of audio. The sentence plays on Talk's audio, as in Talk."
        ) {
            if !VoiceModelStore.shared.isReady {
                hintRow("BlueTTS isn't downloaded, so this times the iPhone's own voice, which Talk speaks with until it is. Download BlueTTS under On-Device Voice.")
                rowDivider
            }
            TextField("A sentence to speak", text: Binding(get: { lab.speakText }, set: { lab.speakText = $0 }),
                      axis: .vertical)
                .lineLimit(1...4)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .focused($editingSentence)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .blockDirection(TextDirection.detect(lab.speakText))
            rowDivider
            speakControls
            if let error = lab.voiceError {
                rowDivider
                problemLine(error)
            }
            ForEach(lab.voiceResults) { result in
                rowDivider
                TalkLabVoiceRow(result: result)
            }
        }
    }

    @ViewBuilder
    private var speakControls: some View {
        if lab.activity == .speaking {
            actionRow("Stop", systemImage: "stop.circle", tint: Theme.danger) { lab.cancel() }
            rowDivider
            progressRow(lab.step ?? "Starting…")
        } else {
            actionRow("Speak", systemImage: "play.circle", enabled: lab.canStart && !speakTextIsEmpty) {
                editingSentence = false
                lab.speak()
            }
        }
    }

    private var speakTextIsEmpty: Bool {
        lab.speakText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Echo test

    private var echoSection: some View {
        EditorSection(
            title: "Echo test",
            footer: "A voice onset is voice detection at 0.5 or more for two frames in a row, as when Talk hears you start: with a good echo mode there are none. Peak and Mean are the microphone's level while the sentence played, Before its mean in the second before, in dB from full scale; the nearer Mean stays to Before, the less of Talk's own speech reaches the microphone."
        ) {
            hintRow("Stay quiet. The test plays a sentence through the speaker, or the AirPods, three times: once with each echo mode. It counts how often the microphone heard a voice while the sentence played, and compares the microphone's level with the second before it.")
            rowDivider
            echoControls
            if let error = lab.echoError {
                rowDivider
                problemLine(error)
            }
            if !lab.echoResults.isEmpty {
                rowDivider
                echoTable
            }
        }
    }

    @ViewBuilder
    private var echoControls: some View {
        if lab.activity == .echoTest {
            actionRow("Cancel", systemImage: "xmark.circle", tint: Theme.danger) { lab.cancel() }
            rowDivider
            progressRow(lab.step ?? "Starting…")
        } else {
            actionRow("Run the echo test", systemImage: "speaker.wave.2.circle",
                      enabled: lab.canStart && lab.canTestEcho) {
                editingSentence = false
                lab.runEchoTest()
            }
        }
    }

    /// Mode asked → mode used and route, onsets, and the levels.
    private var echoTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                tableHeader("Mode")
                tableHeader("Onsets").gridColumnAlignment(.trailing)
                tableHeader("Peak").gridColumnAlignment(.trailing)
                tableHeader("Mean").gridColumnAlignment(.trailing)
                tableHeader("Before").gridColumnAlignment(.trailing)
            }
            ForEach(lab.echoResults) { result in
                Divider()
                    .overlay(Theme.hairline)
                    .gridCellUnsizedAxes(.horizontal)
                echoRows(result)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func echoRows(_ result: TalkLab.EchoResult) -> some View {
        let started = result.used != nil
        let onsetTint = !started ? Theme.textTertiary : (result.onsets == 0 ? Theme.accent : Theme.warning)
        GridRow(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: TalkLab.title(of: result.asked))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                if let used = Self.usedText(result) {
                    Text(verbatim: used)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            tableValue(started ? "\(result.onsets)" : "–", tint: onsetTint)
            tableValue(started ? TalkLabFormat.decibels(result.during.peak) : "–")
            tableValue(started ? TalkLabFormat.decibels(result.during.mean) : "–")
            tableValue(started ? TalkLabFormat.decibels(result.before.mean) : "–")
        }
        if let note = Self.echoNote(result) {
            GridRow {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(result.error == nil ? Theme.textTertiary : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(5)
            }
        }
    }

    private func tableHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.Typography.microLabel)
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
    }

    private func tableValue(_ text: String, tint: Color = Theme.textSecondary) -> some View {
        Text(verbatim: text)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    /// "→ Voice processing · builtIn"; nil when the audio didn't start.
    private static func usedText(_ result: TalkLab.EchoResult) -> String? {
        guard let used = result.used else { return nil }
        var mode = TalkLab.title(of: used)
        if used == .echoCancelledInput, !result.echoCancelledInputOn { mode += ", which iOS didn't turn on" }
        let route = result.route.map { TalkEchoPolicy.name(of: $0) } ?? "?"
        return "→ \(mode) · \(route)"
    }

    /// What went wrong for a mode, if anything.
    private static func echoNote(_ result: TalkLab.EchoResult) -> String? {
        var notes: [String] = []
        if let error = result.error { notes.append(error) }
        if result.routeChanged { notes.append("The route changed during the test.") }
        if result.used != nil, result.error == nil, !result.heardToEnd {
            notes.append("The sentence didn't play to its end.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    // MARK: - Tuning

    private var tuningSection: some View {
        EditorSection(title: "Tuning") {
            settingRow("Echo control", hint: "Talk uses it from its next start. Automatic picks per route: echo-cancelled input on the built-in mic and speaker where iOS has it, voice processing otherwise, none on AirPods.") {
                Menu {
                    ForEach(TalkEchoSetting.allCases, id: \.self) { option in
                        Button {
                            echoSetting = option
                            prefs.echoMode = option
                        } label: {
                            if option == echoSetting {
                                Label(Self.echoSettingTitle(option), systemImage: "checkmark")
                            } else {
                                Text(verbatim: Self.echoSettingTitle(option))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: Self.echoSettingTitle(echoSetting)).font(.subheadline)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            rowDivider
            settingRow("Smart Turn decides", hint: "Off, Smart Turn is only logged. Turn it on only when the telemetry shows it is right at least 85 percent of the time on your speech.") {
                Toggle("", isOn: Binding(get: { smartTurnActive }, set: {
                    smartTurnActive = $0
                    prefs.smartTurnActive = $0
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
        }
    }

    private static func echoSettingTitle(_ setting: TalkEchoSetting) -> String {
        switch setting {
        case .automatic: "Automatic"
        case .echoCancelledInput: "Echo-cancelled input"
        case .voiceProcessing: "Voice processing"
        case .off: "Off"
        }
    }

    // MARK: - This iPhone

    private var deviceSection: some View {
        EditorSection(title: "This iPhone") {
            deviceRows
            capacityRows
            modelRows
            rowDivider
            actionRow("Refresh", systemImage: "arrow.clockwise") {
                lab.refreshDevice()
                lab.refreshModels()
            }
        }
    }

    @ViewBuilder
    private var deviceRows: some View {
        valueRow("Model", value: lab.device.model)
        rowDivider
        valueRow("iOS", value: lab.device.system)
        rowDivider
        valueRow("Echo-cancelled input", value: echoAvailable ? "Yes" : "No", hint: echoAvailableHint)
        rowDivider
        valueRow("Audio route", value: TalkEchoPolicy.name(of: lab.device.route), hint: lab.device.ports)
    }

    @ViewBuilder
    private var capacityRows: some View {
        rowDivider
        valueRow("Background GPU", value: lab.device.backgroundGPU ? "Yes" : "No",
                 hint: "Whether iOS offers the app GPU work in the background here. It may also want the Background GPU Access capability, which the app doesn't have yet.")
        rowDivider
        valueRow("Available memory", value: "\(lab.device.availableMemory / 1_048_576) MB",
                 hint: "Talk loads whisper only with \(TalkController.whisperMemoryFloor / 1_048_576) MB to spare.")
        rowDivider
        valueRow("Thermal state", value: Self.thermalName(lab.device.thermal))
    }

    @ViewBuilder
    private var modelRows: some View {
        ForEach(TalkModels.Requirement.allCases) { requirement in
            rowDivider
            valueRow(LocalizedStringKey(requirement.title),
                     value: TalkModels.isReady(requirement) ? "Downloaded" : "Not downloaded")
        }
        rowDivider
        valueRow("whisper in memory", value: SpeechEngineHost.shared.isWhisperLoaded ? "Yes" : "No")
    }

    /// What iOS said while the Lab's audio ran on the built-in mic and
    /// speaker, else what it says now.
    private var echoAvailable: Bool {
        lab.echoCancelledInputSeen ?? lab.device.echoCancelledInputNow
    }

    private var echoAvailableHint: String {
        lab.echoCancelledInputSeen == nil
            ? "As iOS says with the audio off. It tells for sure only while Talk's audio runs on the built-in mic and speaker, as in the echo test."
            : "As iOS said when the Lab's audio last ran on the built-in mic and speaker."
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    // MARK: - Rows

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

    private func valueRow(_ title: LocalizedStringKey, value: String, hint: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let hint, !hint.isEmpty {
                    Text(verbatim: hint)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String, tint: Color = Theme.accent,
                           enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(enabled ? tint : Theme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func hintRow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func problemLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16)
    }
}

// MARK: - Results

/// One recording: the Zipformer's and whisper's text with their times, and
/// Smart Turn's probability.
private struct TalkLabTranscriptionRow: View {
    let result: TalkLab.TranscriberResult
    /// The two transcripts next to each other (a regular width), else one
    /// under the other.
    let sideBySide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: header)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                Text(verbatim: smartTurn)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            if sideBySide {
                HStack(alignment: .top, spacing: 16) {
                    TalkLabTranscript(title: "Zipformer (live)", content: zipformer)
                    TalkLabTranscript(title: "whisper (final)", content: whisper)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    TalkLabTranscript(title: "Zipformer (live)", content: zipformer)
                    TalkLabTranscript(title: "whisper (final)", content: whisper)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: String {
        let time = result.date.formatted(date: .omitted, time: .standard)
        return "\(time) · \(TalkLabFormat.length(result.audioSeconds))"
    }

    private var smartTurn: String {
        switch result.smartTurn {
        case .running:
            return "Smart Turn…"
        case .stopped:
            return "Smart Turn: stopped"
        case .notDownloaded:
            return "Smart Turn isn't downloaded"
        case .failed:
            return "Smart Turn didn't answer"
        case .done(let probability, let heardSpeech):
            let verdict = probability >= EndOfTurnConfig.standard.smartTurnThreshold ? "finished" : "not finished"
            let note = heardSpeech ? "" : ", no speech heard"
            return "Smart Turn \(String(format: "%.2f", probability)): \(verdict)\(note)"
        }
    }

    private var zipformer: TalkLabTranscript.Content {
        switch result.zipformer {
        case .running:
            return .running
        case .stopped:
            return .note("Stopped.", problem: false)
        case .failed(let message):
            return .note(message, problem: true)
        case .done(let pass):
            let audio = result.audioSeconds
            let details = [
                "Whole clip \(TalkLabFormat.time(pass.onceSeconds)), RTF \(TalkLabFormat.factor(pass.onceSeconds, audio))",
                "After the end of speech \(TalkLabFormat.time(pass.finishSeconds))",
                "Streamed, RTF \(TalkLabFormat.factor(pass.feedSeconds, audio))",
            ]
            return .text(pass.onceText, details: details,
                         alternate: pass.streamedText == pass.onceText ? nil : pass.streamedText)
        }
    }

    private var whisper: TalkLabTranscript.Content {
        switch result.whisper {
        case .running:
            return .running
        case .stopped:
            return .note("Stopped.", problem: false)
        case .notDownloaded:
            return .note("Not downloaded. It is voice typing's model, under Voice Typing.", problem: false)
        case .skipped(let reason):
            return .note(reason, problem: false)
        case .failed(let message):
            return .note(message, problem: true)
        case .done(let text, let decodeSeconds, let loadSeconds):
            let audio = result.audioSeconds
            var details = ["Decode \(TalkLabFormat.time(decodeSeconds)), RTF \(TalkLabFormat.factor(decodeSeconds, audio))"]
            if let loadSeconds { details.append("Loaded first, in \(TalkLabFormat.time(loadSeconds))") }
            return .text(text, details: details, alternate: nil)
        }
    }
}

/// One engine's transcript of a recording, laid out in its own direction.
private struct TalkLabTranscript: View {
    enum Content {
        case running
        /// The text, its times, and the streamed run's text when it differs.
        case text(String, details: [String], alternate: String?)
        case note(String, problem: Bool)
    }

    let title: LocalizedStringKey
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.Typography.microLabel)
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
            switch content {
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .text(let text, let details, let alternate):
                transcript(text, font: .body)
                ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let alternate {
                    Text("Streamed")
                        .font(Theme.Typography.microLabel)
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                    transcript(alternate, font: .callout)
                }
            case .note(let text, let problem):
                Text(verbatim: text)
                    .font(.caption)
                    .foregroundStyle(problem ? Theme.danger : Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transcript(_ text: String, font: Font) -> some View {
        Text(verbatim: text.isEmpty ? "(nothing heard)" : text)
            .font(font)
            .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockDirection(TextDirection.detect(text))
    }
}

/// One timing of the voice.
private struct TalkLabVoiceRow: View {
    let result: TalkLab.VoiceResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: voice)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(verbatim: firstAudio)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Text(verbatim: details)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: result.text)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blockDirection(TextDirection.detect(result.text))
            if let error = result.error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voice: String {
        guard result.natural else { return "iPhone voice" }
        return "BlueTTS · \((result.voiceName ?? "noa").capitalized)"
    }

    private var firstAudio: String {
        guard let seconds = result.firstAudioSeconds else { return "–" }
        return "First audio \(TalkLabFormat.time(seconds))"
    }

    private var details: String {
        var parts = ["Total \(TalkLabFormat.time(result.totalSeconds))",
                     "\(TalkLabFormat.length(result.audioSeconds)) of audio",
                     "RTF \(TalkLabFormat.factor(result.totalSeconds, result.audioSeconds))"]
        if let load = result.loadSeconds { parts.append("loaded first, in \(TalkLabFormat.time(load))") }
        if !result.played { parts.append("not played") }
        return parts.joined(separator: " · ")
    }
}

/// The microphone's level while recording.
private struct TalkLabLevelBar: View {
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.surface)
            Capsule()
                .fill(Theme.accent)
                .frame(width: 4 + 76 * CGFloat(min(1, max(0, level))))
        }
        .frame(width: 80, height: 6)
        .accessibilityHidden(true)
    }
}

/// How the Lab writes its numbers.
private enum TalkLabFormat {
    /// "420 ms", "1.24 s".
    static func time(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    /// A length of audio: "3.4 s".
    static func length(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    /// Seconds of work per second of audio: "0.31".
    static func factor(_ seconds: Double, _ audio: Double) -> String {
        audio > 0 ? String(format: "%.2f", seconds / audio) : "–"
    }

    /// An RMS level in dB from full scale: "-42".
    static func decibels(_ rms: Float) -> String {
        String(format: "%.0f", 20 * log10(max(Double(rms), 0.000_01)))
    }
}
