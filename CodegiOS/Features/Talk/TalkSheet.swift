import SwiftUI

/// Talk's sheet (large, not swiped away): an orb whose ring follows the
/// microphone (or the speech), what Talk is doing, the "You" and "Agent"
/// captions with the sentence being said highlighted, big buttons for a
/// choice Talk asks, and Mute, Skip and End. In push to talk, hold the orb
/// to speak; hands-free, a tap on it stops the speech.
struct TalkSheet: View {
    let talk: TalkController
    /// The session's token use, when the server reports it.
    var stats: SessionStats?
    var onEnd: () -> Void

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    orb
                        .padding(.top, 8)
                    statusLine
                    captions
                    if let ask = talk.ask, !ask.choices.isEmpty {
                        choices(ask)
                    }
                    if talk.canReportCutOff {
                        Button {
                            talk.reportCutOff()
                        } label: {
                            Label("You cut me off", systemImage: "scissors")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHint(Text("Tell Talk it took what you said before you finished."))
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin + 4)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { controls }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.large])
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text(verbatim: talk.title.isEmpty ? "Talk" : talk.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            chips
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chips: some View {
        let background = talk.backgroundOutstanding > 0 || talk.awaitingBackground
        let context = stats?.contextWindowUsagePercent
        if background || talk.fastMode || !talk.naturalVoice || context != nil {
            HStack(spacing: 6) {
                if background {
                    chip(talk.backgroundOutstanding > 1 ? "\(talk.backgroundOutstanding) running in the background"
                         : "Working in the background", systemImage: "gearshape.2")
                }
                if talk.fastMode {
                    chip("Fast mode", systemImage: "hare")
                }
                if !talk.naturalVoice {
                    chip("iPhone voice", systemImage: "speaker.wave.2")
                }
                if let context {
                    chip("Context \(Int(context.rounded()))%", systemImage: "text.word.spacing")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func chip(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Theme.surface, in: Capsule())
    }

    // MARK: - The orb

    private var level: CGFloat {
        CGFloat(talk.status == .speaking ? talk.outputLevel : talk.inputLevel)
    }

    private var orbSymbol: String {
        if talk.mute == .hard { return "mic.slash.fill" }
        if talk.mute == .soft { return "mic.slash" }
        switch talk.status {
        case .starting: return "ellipsis"
        case .listening, .hearing: return "mic.fill"
        case .thinking, .working: return "ellipsis"
        case .speaking: return "waveform"
        case .asking, .confirmingCancel: return "questionmark"
        case .paused: return "pause.fill"
        case .ended: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var orb: some View {
        ZStack {
            Circle()
                .stroke(talk.status == .speaking ? Theme.textSecondary.opacity(0.5) : Theme.accent.opacity(0.55),
                        lineWidth: 3)
                .frame(width: 150, height: 150)
                .scaleEffect(1 + min(0.45, level * 0.45))
                .animation(.easeOut(duration: 0.12), value: level)
            Circle()
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.95), Theme.accent.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 128, height: 128)
                .opacity(talk.mute == .none ? 1 : 0.45)
            Image(systemName: orbSymbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 220, height: 220)
        .contentShape(Circle())
        .gesture(orbGesture)
        .accessibilityElement()
        .accessibilityLabel(Text("Talk"))
        .accessibilityValue(Text(verbatim: statusText))
        .accessibilityHint(talk.handsFree ? Text("Tap to stop the speech and talk.")
                           : Text("Hold while you speak, then let go."))
        .accessibilityAddTraits(.isButton)
    }

    private var orbGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !talk.handsFree, !pressing else { return }
                pressing = true
                talk.press(true)
            }
            .onEnded { _ in
                if talk.handsFree {
                    talk.tapOrb()
                } else if pressing {
                    pressing = false
                    talk.press(false)
                }
            }
    }

    @State private var pressing = false

    // MARK: - Status

    private var statusText: String {
        if talk.mute == .hard { return talk.speaksHebrew ? "המיקרופון כבוי" : "Mic off" }
        if talk.mute == .soft { return talk.speaksHebrew ? "מושתק" : "Muted" }
        let hebrew = talk.speaksHebrew
        switch talk.status {
        case .starting: return hebrew ? "מתחיל…" : "Starting…"
        case .listening: return talk.handsFree ? (hebrew ? "מקשיב…" : "Listening…")
            : (hebrew ? "לחיצה ארוכה על העיגול כדי לדבר" : "Hold to talk")
        case .hearing: return hebrew ? "שומע…" : "Hearing you…"
        case .thinking: return hebrew ? "רגע…" : "One moment…"
        case .working: return hebrew ? "עובד על זה…" : "Working on it…"
        case .speaking: return hebrew ? "מדבר…" : "Speaking…"
        case .asking: return hebrew ? "מחכה לתשובה שלך" : "Waiting for your answer"
        case .confirmingCancel: return hebrew ? "לבטל את העבודה?" : "Cancel the work?"
        case .paused(let reason):
            switch reason {
            case .phoneCall: return hebrew ? "מושהה בגלל שיחה" : "Paused for a call"
            case .siri, .interruption: return hebrew ? "מושהה" : "Paused"
            }
        case .ended: return hebrew ? "השיחה הסתיימה" : "Talk ended"
        case .failed: return hebrew ? "משהו השתבש" : "Something went wrong"
        }
    }

    private var muteHint: String? {
        switch talk.mute {
        case .none: return nil
        case .soft: return talk.speaksHebrew ? "אפשר לומר \"תקשיב\" או ללחוץ על ה-AirPods כדי לחזור" : "Say \"listen\" or press the AirPods to come back"
        case .hard: return talk.speaksHebrew ? "המיקרופון חוזר עם Unmute" : "Tap Unmute to come back"
        }
    }

    private var statusLine: some View {
        VStack(spacing: 4) {
            Text(verbatim: statusText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let muteHint {
                Text(verbatim: muteHint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if case .failed(let message) = talk.status {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Captions

    private var captions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !talk.heardText.isEmpty {
                caption(label: "You", lines: [(talk.heardText, !talk.heardIsFinal, false)])
            }
            let recent = Array(talk.spokenLog.suffix(3))
            if !recent.isEmpty {
                caption(label: "Agent", lines: recent.map { ($0.text, false, $0.id == talk.currentSpokenID) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(label: LocalizedStringKey, lines: [(text: String, partial: Bool, current: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.Typography.microLabel)
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.text)
                    .font(line.current ? .body.weight(.semibold) : .body)
                    .foregroundStyle(line.current ? Theme.accent
                                     : (line.partial ? Theme.textSecondary : Theme.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blockDirection(TextDirection.detect(line.text))
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Choices

    private func choices(_ ask: TalkAsk) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(ask.choices.enumerated()), id: \.offset) { _, choice in
                Button {
                    talk.choose(choice)
                } label: {
                    Text(verbatim: choice.label)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .padding(.horizontal, 12)
                        .foregroundStyle(choice.meaning.isNegative ? Theme.danger : Theme.onAccent)
                        .background(choice.meaning.isNegative ? Theme.danger.opacity(0.14) : Theme.accent,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            control(talk.mute == .none ? "Mute" : "Unmute",
                    systemImage: talk.mute == .none ? "mic.slash" : "mic",
                    tint: talk.mute == .none ? Theme.textPrimary : Theme.accent) {
                talk.toggleMuteButton()
            }
            control("Skip", systemImage: "forward.end", tint: Theme.textPrimary) {
                talk.skip()
            }
            .disabled(talk.status != .speaking)
            control("End", systemImage: "xmark", tint: Theme.danger, action: onEnd)
        }
        .padding(.horizontal, Theme.Layout.screenHMargin + 4)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private func control(_ title: LocalizedStringKey, systemImage: String, tint: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 58, height: 58)
                    .background(Theme.surface, in: Circle())
                Text(title)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private extension TalkChoice.Meaning {
    var isNegative: Bool {
        switch self {
        case .rejectOnce, .rejectAlways, .abandon: true
        default: false
        }
    }
}

/// Talk's sheets on a session's screen: the Talk sheet while Talk runs for
/// it (until Talk ends), the first-run model download, and why a start
/// didn't happen.
struct TalkSessionSheets: ViewModifier {
    let conversationID: Int?
    let stats: SessionStats?

    private var center: TalkCenter { TalkCenter.shared }

    private var talkShown: Binding<Bool> {
        Binding(get: { conversationID != nil && center.controller?.conversationID == conversationID },
                set: { _ in })
    }

    private var modelsShown: Binding<Bool> {
        Binding(get: { conversationID != nil && center.modelsRequestedFor == conversationID },
                set: { shown in if !shown { center.modelsCancelled() } })
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { center.problem != nil }, set: { if !$0 { center.clearProblem() } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: talkShown) {
                if let talk = center.controller, talk.conversationID == conversationID {
                    TalkSheet(talk: talk, stats: stats, onEnd: { center.end() })
                }
            }
            .sheet(isPresented: modelsShown) {
                TalkModelsSheet(onStart: { center.modelsReady() }, onCancel: { center.modelsCancelled() })
            }
            .alert("Talk", isPresented: problemShown) {
                Button("OK", role: .cancel) { center.clearProblem() }
            } message: {
                Text(verbatim: center.problem ?? "")
            }
    }
}

/// The Talk button at the top of a session: starts Talk, or opens its sheet
/// when it runs. Filled while Talk runs for this session.
struct TalkToolbarButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform")
                .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(Text("Talk"))
        .accessibilityValue(isActive ? Text("On") : Text("Off"))
        .accessibilityHint(Text("Talk with this session hands-free; also with the screen locked."))
    }
}
