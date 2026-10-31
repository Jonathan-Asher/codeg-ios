import AVFoundation

/// The audio session's side of ``TalkEchoPolicy`` on the iPhone: the session
/// mode each echo mode needs and the route from the session's ports.
extension TalkEchoPolicy {
    /// The session mode each echo mode needs: echo-cancelled input works only
    /// in `.default`, voice processing belongs with `.voiceChat`.
    static func sessionMode(for echo: TalkEchoMode) -> AVAudioSession.Mode {
        switch echo {
        case .voiceProcessing: return .voiceChat
        case .echoCancelledInput, .none: return .default
        }
    }

    /// What kind of route the session is on now.
    static func route(_ description: AVAudioSessionRouteDescription) -> TalkRoute {
        route(inputs: description.inputs.map(\.portType), outputs: description.outputs.map(\.portType))
    }

    /// The route from its port types: a Bluetooth headset (HFP) on either
    /// side, the built-in microphone with the built-in speaker (or receiver),
    /// a wired headset, or something else (CarPlay, USB, AirPlay, nothing).
    static func route(inputs: [AVAudioSession.Port], outputs: [AVAudioSession.Port]) -> TalkRoute {
        if inputs.contains(.bluetoothHFP) || outputs.contains(.bluetoothHFP) { return .bluetoothHFP }
        let builtInOut = outputs.contains(.builtInSpeaker) || outputs.contains(.builtInReceiver)
        if inputs.contains(.builtInMic), builtInOut || outputs.isEmpty { return .builtIn }
        if inputs.contains(.headsetMic) || outputs.contains(.headphones) { return .wired }
        return .other
    }
}
