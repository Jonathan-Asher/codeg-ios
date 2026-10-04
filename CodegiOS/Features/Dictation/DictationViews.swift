import SwiftUI

/// The composer's mic. Tap to start and tap again to finish, or hold to talk
/// and let go to finish. While this composer's dictation records it is the
/// one control that ends it: filled, with a paper plane when the dictation
/// is sent right after transcribing and a check mark when it goes into the
/// message bar. While it transcribes, a spinner.
struct DictationMicButton: View {
    let owner: UUID
    let isRecording: Bool
    let isTranscribing: Bool
    /// Another composer is dictating.
    let isDisabled: Bool
    /// Finishing sends the message (the strip's Send chip).
    var sendOnFinish = false
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
                    Image(systemName: symbol)
                        .font(.system(size: isRecording ? 15 : 16, weight: isRecording ? .bold : .semibold))
                        .foregroundStyle(isRecording ? Theme.onAccent : Theme.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 26, height: 26)
            // Drawn in the label, which sits above the glass (anything
            // outside the button renders under it). The fill covers the
            // whole glass capsule while recording.
            .background {
                Capsule()
                    .fill(Theme.accent)
                    .padding(.horizontal, -Self.glassPadding.width)
                    .padding(.vertical, -Self.glassPadding.height)
                    .opacity(isRecording ? 1 : 0)
            }
        }
        // One style in every state: switching button styles would replace the
        // view under a finger that is holding to talk. No clip shape: the
        // glass ignores it, and it would cut the fill.
        .buttonStyle(.glass)
        .tint(Theme.textSecondary)
        .animation(.snappy(duration: 0.2), value: isRecording)
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
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(Text("Tap to start and tap again to finish, or hold while you speak."))
    }

    /// How far the glass button style pads its label (measured on iOS 26).
    private static let glassPadding = CGSize(width: 12, height: 7)

    private var symbol: String {
        guard isRecording else { return "mic" }
        return sendOnFinish ? "paperplane.fill" : "checkmark"
    }

    private var spokenLabel: Text {
        guard isRecording else { return Text("Dictate") }
        return sendOnFinish ? Text("Finish and send") : Text("Finish dictation")
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

/// Above the composer while dictating, in two rows. The first says what is
/// happening: a pulsing dot, the elapsed time and a live level meter while
/// recording (with the Camera Control glyph when it started there), or a
/// spinner with "Transcribing…", "Cleaning up…" or "Translating…"; and cancel.
/// The second holds the chips, which wrap onto another line when they don't
/// fit (large text): the language of this message (Auto, עב, EN), what
/// happens after transcribing (the setting itself: as spoken, clean up, to
/// English), and Send (send right after transcribing). While the codeg
/// server cleans up, "Use as spoken" stops waiting for it.
///
/// Ending the recording is the mic button's job (it turns into the finish
/// control), so the strip has no second stop.
struct DictationStrip: View {
    let phase: DictationController.Phase
    let levels: [Float]
    let elapsed: TimeInterval
    var source: DictationSource = .mic
    @Binding var autoSend: Bool
    /// The "after transcribing" setting; `nil` hides the chip (no server, or
    /// one that can't clean up).
    var refineMode: Binding<DictationRefineMode>? = nil
    /// This message's language; `nil` hides the chip.
    var language: Binding<DictationLanguageChoice>? = nil
    /// The language the setting starts each message with; the chip is
    /// filled when this message differs from it.
    var languageDefault: DictationLanguageChoice = .automatic
    let onCancel: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var meterHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            FlowLayout(spacing: 8, lineSpacing: 8) { chips }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(phase == .recording ? 0.35 : 0))
        .animation(Theme.Motion.chrome, value: phase)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if phase == .recording {
                RecordingDot()
                if source == .cameraControl {
                    Image(systemName: CameraTalkSymbols.on)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel(Text("From the Camera Control"))
                }
                Text(verbatim: Self.format(elapsed))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(Text("Recording, \(Self.format(elapsed))"))
                LevelMeter(levels: levels)
                    .frame(height: meterHeight)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView().controlSize(.small)
                Text(verbatim: progressLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if phase != .refining {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(phase == .recording ? Text("Cancel dictation") : Text("Stop transcribing"))
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        if phase == .refining {
            Button(action: onCancel) {
                StripChip(title: "Use as spoken", systemImage: "text.quote", filled: false)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Stops waiting for the codeg server and inserts the words as spoken."))
        } else {
            if let language, phase == .recording {
                LanguageChip(choice: language, highlighted: language.wrappedValue != languageDefault)
            }
            if let refineMode {
                RefineChip(mode: refineMode)
            }
        }
        Button {
            autoSend.toggle()
        } label: {
            StripChip(title: "Send", systemImage: autoSend ? "paperplane.fill" : "paperplane", filled: autoSend)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Send right after transcribing"))
        .accessibilityValue(autoSend ? Text("On") : Text("Off"))
    }

    private var progressLabel: String {
        phase == .refining ? (refineMode?.wrappedValue ?? .cleanUp).progressLabel : "Transcribing…"
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The strip's chip: filled with the accent when it is on (or differs from
/// the setting), outlined otherwise. One line; it truncates rather than grow.
private struct StripChip: View {
    let title: String
    var systemImage: String?
    let filled: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(filled ? Theme.onAccent : Theme.textSecondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background { Capsule().fill(filled ? Theme.accent : Theme.surface) }
        .overlay { Capsule().strokeBorder(filled ? Color.clear : Theme.hairline) }
        .contentShape(Capsule())
        .contentTransition(.opacity)
    }
}

/// Cycles this message's language: Auto (Hebrew or English, told apart on
/// the phone), עב (Hebrew), EN (English). This message only.
private struct LanguageChip: View {
    @Binding var choice: DictationLanguageChoice
    /// The message differs from the Language setting.
    let highlighted: Bool

    var body: some View {
        Button {
            choice = choice.next
        } label: {
            StripChip(title: choice.shortTitle, systemImage: "character.bubble", filled: highlighted)
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
        Button {
            mode = mode.next
        } label: {
            StripChip(title: mode.shortTitle, systemImage: mode.systemImage, filled: mode != .asSpoken)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: mode)
        .accessibilityLabel(Text("After transcribing"))
        .accessibilityValue(Text(verbatim: mode.title))
        .accessibilityHint(Text("Changes the setting for this and later dictations."))
    }
}

/// The recording dot, pulsing.
private struct RecordingDot: View {
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: size, height: size)
            .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) }
                animation: { _ in .easeInOut(duration: 0.7) }
            .accessibilityHidden(true)
    }
}

/// Bars for the most recent input levels, newest on the trailing edge.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            // Thin bars, as many of the newest levels as fit.
            let bar: CGFloat = 3
            let spacing: CGFloat = 2.5
            let fits = max(1, Int((geo.size.width + spacing) / (bar + spacing)))
            let shown = Array(levels.suffix(fits))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Theme.danger.opacity(0.85))
                        .frame(width: bar, height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(.linear(duration: 0.06), value: levels)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
