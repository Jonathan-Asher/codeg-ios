import SwiftUI

/// The composer's mic. Tap to start and tap again to stop, or hold to talk and
/// let go to stop. While this composer's dictation records it shows a stop
/// square; while it transcribes, a spinner.
struct DictationMicButton: View {
    let owner: UUID
    let isRecording: Bool
    let isTranscribing: Bool
    /// Another composer is dictating.
    let isDisabled: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    @State private var press = DictationPress()
    @State private var pressed = false
    @State private var lastGesture = Date.distantPast
    @State private var haptic = 0

    var body: some View {
        Button(action: accessibilityToggle) {
            ZStack {
                if isTranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic")
                        .font(.system(size: isRecording ? 14 : 16, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .tint(isRecording ? Theme.danger : Theme.textSecondary)
        .scaleEffect(pressed ? 1.12 : 1)
        .animation(.snappy(duration: 0.18), value: pressed)
        .disabled(isDisabled || isTranscribing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    press.sync(isRecording: isRecording)
                    handle(press.down(at: Date().timeIntervalSinceReferenceDate))
                }
                .onEnded { _ in
                    pressed = false
                    lastGesture = Date()
                    handle(press.up(at: Date().timeIntervalSinceReferenceDate))
                }
        )
        .onChange(of: isRecording) { _, recording in
            // Stopped from elsewhere (the strip's cancel, an interruption).
            if !recording, press.isRecording, !pressed { press.reset() }
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: haptic)
        .accessibilityLabel(isRecording ? Text("Stop dictation") : Text("Dictate"))
        .accessibilityHint(Text("Tap to start and tap again to stop, or hold while you speak."))
    }

    private func handle(_ action: DictationPress.Action) {
        switch action {
        case .none:
            break
        case .start:
            haptic &+= 1
            onStart()
        case .stop:
            haptic &+= 1
            onStop()
        }
    }

    /// The Button's own action. A touch is handled by the gesture above (which
    /// ended just before); VoiceOver and other assistive activations land here.
    private func accessibilityToggle() {
        guard Date().timeIntervalSince(lastGesture) > 0.6 else { return }
        if isRecording {
            press.reset()
            onStop()
        } else {
            press.reset()
            _ = press.down(at: 0)
            _ = press.up(at: 0)
            onStart()
        }
    }
}

/// Above the composer while dictating: a live level meter, the elapsed time,
/// the language of this message (Auto, Hebrew, English), what happens after
/// transcribing (as spoken, clean up, translate) for this message, the "send
/// right after transcribing" switch, and cancel. While the codeg server cleans
/// up, cancel keeps the words as spoken instead.
struct DictationStrip: View {
    let phase: DictationController.Phase
    let levels: [Float]
    let elapsed: TimeInterval
    @Binding var autoSend: Bool
    /// This message's clean-up; `nil` hides the chip (no server, or one that
    /// can't clean up).
    var refineMode: Binding<DictationRefineMode>? = nil
    /// This message's language; `nil` hides the chip.
    var language: Binding<DictationLanguageChoice>? = nil
    /// The language the setting starts each message with; the chip is
    /// highlighted when this message differs from it.
    var languageDefault: DictationLanguageChoice = .automatic
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if phase == .transcribing || phase == .refining {
                ProgressView().controlSize(.small)
                Text(verbatim: progressLabel)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else {
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 8, height: 8)
                    .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) }
                        animation: { _ in .easeInOut(duration: 0.7) }
                Text(Self.format(elapsed))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                LevelMeter(levels: levels)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
            }
            if let language, phase == .recording {
                LanguageChip(choice: language, highlighted: language.wrappedValue != languageDefault)
            }
            if let refineMode, phase != .refining {
                RefineChip(mode: refineMode)
            }
            Button {
                autoSend.toggle()
            } label: {
                Label("Send", systemImage: autoSend ? "paperplane.fill" : "paperplane")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(autoSend ? Color.white : Theme.textSecondary)
                    .background(autoSend ? Theme.accent : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(autoSend ? Color.clear : Theme.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Send right after transcribing"))
            .accessibilityValue(autoSend ? Text("On") : Text("Off"))
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(phase == .refining ? Text("Use as spoken") : Text("Cancel dictation"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(phase == .recording ? 0.35 : 0))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var progressLabel: String {
        phase == .refining ? (refineMode?.wrappedValue ?? .cleanUp).progressLabel : "Transcribing…"
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Cycles this message's language: Auto (Hebrew or English, told apart on
/// the phone), עב (Hebrew), EN (English).
private struct LanguageChip: View {
    @Binding var choice: DictationLanguageChoice
    /// The message differs from the Language setting.
    let highlighted: Bool

    var body: some View {
        Button {
            choice = choice.next
        } label: {
            Text(verbatim: choice.shortTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 24)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(highlighted ? Color.white : Theme.textSecondary)
                .background(highlighted ? Theme.accent : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(highlighted ? Color.clear : Theme.hairline))
                .contentTransition(.opacity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: choice)
        .accessibilityLabel(Text("Language for this message"))
        .accessibilityValue(Text(verbatim: choice.accessibilityTitle))
        .accessibilityHint(Text("Changes it for this message only."))
    }
}

/// Cycles what happens after transcribing: as spoken, clean up, to English.
/// It is the setting (Settings › Voice), so it stays for the next dictation.
private struct RefineChip: View {
    @Binding var mode: DictationRefineMode

    var body: some View {
        let active = mode != .asSpoken
        Button {
            mode = mode.next
        } label: {
            Label(mode.shortTitle, systemImage: mode.systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(active ? Theme.onAccent : Theme.textSecondary)
                .background(active ? Theme.accent : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Color.clear : Theme.hairline))
                .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: mode)
        .accessibilityLabel(Text("After transcribing"))
        .accessibilityValue(Text(verbatim: mode.title))
        .accessibilityHint(Text("Changes the setting for this and later dictations."))
    }
}

/// Bars for the most recent input levels, newest on the trailing edge.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, levels.count)
            let spacing: CGFloat = 2
            let width = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Theme.danger.opacity(0.85))
                        .frame(width: width, height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(.linear(duration: 0.06), value: levels)
        }
        .accessibilityHidden(true)
    }
}
