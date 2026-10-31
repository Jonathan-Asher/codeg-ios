import AVFoundation

/// How Talk keeps the agent's own speech out of what the microphone hears,
/// per audio route. Pure, apart from the Lab's stored override.
///
/// - Built-in microphone and speaker, on an iPhone that has it (iOS 18.2,
///   2024 and later models): echo-cancelled input
///   (`setPrefersEchoCancelledInput`, the session in mode `.default`), tuned
///   for a wide range of sound rather than voice calls only. Checked again
///   after every route change.
/// - Otherwise (an older iPhone, a wired headset, other outputs): voice
///   processing on the engine's input (the session in mode `.voiceChat`).
/// - AirPods and other Bluetooth headsets (HFP): none; the headset keeps its
///   own speech out of its microphone.
/// - The Lab can force any of them to compare them.
enum TalkEchoPolicy {
    /// The echo mode for a route.
    static func choose(route: TalkRoute, echoCancelledInputAvailable: Bool,
                       override: TalkEchoMode? = nil) -> TalkEchoMode {
        if let override { return override }
        switch route {
        case .bluetoothHFP:
            return .none
        case .builtIn:
            return echoCancelledInputAvailable ? .echoCancelledInput : .voiceProcessing
        case .wired, .other:
            return .voiceProcessing
        }
    }

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

    // MARK: - The Lab's override

    private static let overrideKey = "codeg.talk.echoOverride"

    /// The echo mode the Lab forces, nil for the policy's choice. Talk passes
    /// it to ``TalkAudioIO/start(preferring:)``.
    static var labOverride: TalkEchoMode? {
        get { UserDefaults.standard.string(forKey: overrideKey).flatMap(echoMode(named:)) }
        set {
            if let newValue {
                UserDefaults.standard.set(name(of: newValue), forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
        }
    }

    /// A stable name for logs, breadcrumbs and the stored override.
    static func name(of echo: TalkEchoMode) -> String {
        switch echo {
        case .echoCancelledInput: return "echoCancelledInput"
        case .voiceProcessing: return "voiceProcessing"
        case .none: return "none"
        }
    }

    static func echoMode(named name: String) -> TalkEchoMode? {
        switch name {
        case "echoCancelledInput": return .echoCancelledInput
        case "voiceProcessing": return .voiceProcessing
        case "none": return TalkEchoMode.none
        default: return nil
        }
    }

    /// A stable name for a route.
    static func name(of route: TalkRoute) -> String {
        switch route {
        case .builtIn: return "builtIn"
        case .bluetoothHFP: return "bluetoothHFP"
        case .wired: return "wired"
        case .other: return "other"
        }
    }
}
