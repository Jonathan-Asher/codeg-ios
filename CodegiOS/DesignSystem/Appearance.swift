import SwiftUI
import Observation

/// The app's theme mode. `.system` follows the device's light/dark setting.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    /// The value to hand `.preferredColorScheme`. `.system` → `nil` (defer to the
    /// device).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-chosen appearance: light/dark/system mode, the accent color scheme and
/// the Activity tab's order. All persist to `UserDefaults` and survive relaunch. Owned at the app root
/// (`RootView`) and injected into the environment so the Settings screen can read
/// and mutate it; `mode` drives `.preferredColorScheme` and `accent` drives the
/// `\.codegAccent` trait bridge, both applied once in `RootView`.
@MainActor
@Observable
final class AppearanceStore {
    private static let modeKey = "codeg.appearance.mode"
    private static let accentKey = "codeg.appearance.accent"
    private static let newestAtBottomKey = "codeg.activity.newestAtBottom"

    var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    var accent: AccentPalette {
        didSet {
            guard oldValue != accent else { return }
            UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey)
        }
    }

    /// The Activity tab lists the most recent session at the bottom of the
    /// screen (thumb reach) and opens scrolled there. On unless turned off.
    var newestAtBottom: Bool {
        didSet {
            guard oldValue != newestAtBottom else { return }
            UserDefaults.standard.set(newestAtBottom, forKey: Self.newestAtBottomKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.mode = defaults.string(forKey: Self.modeKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        // Unset reads back as nil here (we use `object(forKey:)`, not
        // `integer(forKey:)`), so a fresh install falls through to the neutral
        // default; an out-of-range stored index also falls back to neutral.
        self.accent = (defaults.object(forKey: Self.accentKey) as? Int)
            .flatMap(AccentPalette.init(rawValue:)) ?? .neutral
        self.newestAtBottom = defaults.object(forKey: Self.newestAtBottomKey) as? Bool ?? true
    }
}
