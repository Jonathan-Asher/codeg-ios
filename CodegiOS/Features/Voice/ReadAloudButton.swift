import SwiftUI

/// "Read aloud" under an agent reply. The first use without the voice model
/// asks whether to download it (575 MB); meanwhile, and if declined, the
/// iPhone's own voice reads.
struct ReadAloudButton: View {
    let id: String
    let blocks: [ContentBlock]

    @State private var askDownload = false
    private var player: ReadAloudPlayer { ReadAloudPlayer.shared }
    private var models: ModelPackStore { VoiceModelStore.shared }

    private var isReading: Bool { player.isReading(id) }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: player.currentID == id && player.state == .preparing)
                (isReading ? Text("Stop") : Text("Read"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isReading ? Theme.accent : Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReading ? Text("Stop reading") : Text("Read aloud"))
        .alert("Download the voice?", isPresented: $askDownload) {
            Button("Download 575 MB") {
                models.start()
                read()
            }
            Button("Use the System Voice") { read() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Read aloud sounds best with the on-device Hebrew and English voice (BlueTTS), a one-time 575 MB download. Until it is ready the iPhone's own voice reads. You can manage it in Settings › Voice.")
        }
    }

    private var icon: String {
        guard player.currentID == id else { return "speaker.wave.2" }
        switch player.state {
        case .idle: return "speaker.wave.2"
        case .preparing: return "waveform"
        case .playing: return "stop.fill"
        case .paused: return "pause.fill"
        }
    }

    private func tap() {
        if isReading {
            player.stop()
            return
        }
        let modelBusy: Bool = {
            switch models.state {
            case .ready, .downloading, .verifying: return true
            default: return false
            }
        }()
        if !modelBusy, !VoicePrefs.askedDownload {
            VoicePrefs.askedDownload = true
            askDownload = true
            return
        }
        read()
    }

    private func read() {
        let text = SpeechText.from(blocks: blocks, options: VoicePrefs.speechOptions)
        let title = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? "Agent reply"
        player.toggle(id: id, title: title, text: text)
    }
}
