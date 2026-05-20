import AppKit
import Observation
import SwiftUI

/// User's chosen appearance: follow the system, force light, or force dark.
enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Auto (System)"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SwiftUI color scheme override. `nil` means "do not override" — the
    /// window inherits the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Persists the user's theme choice and exposes it to SwiftUI / AppKit. A
/// single shared instance is injected into the SwiftUI environment from the
/// app entry point.
@MainActor
@Observable
final class ThemePreference {
    static let shared = ThemePreference()

    private let defaultsKey = "com.sequelpg.themeMode"
    private let defaults: UserDefaults

    var mode: ThemeMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: defaultsKey)
            applyToAppKit()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: defaultsKey) ?? ThemeMode.system.rawValue
        mode = ThemeMode(rawValue: raw) ?? .system
        applyToAppKit()
    }

    /// SwiftUI views read this and pass it to `.preferredColorScheme`.
    var colorScheme: ColorScheme? { mode.colorScheme }

    /// Drives `NSApp.appearance` so AppKit-only chrome (window titlebars,
    /// system menus surfaced by the app, dynamic `NSColor` resolution in
    /// detached panels like the SQL completion popup) follows the same choice
    /// as SwiftUI's `preferredColorScheme`.
    private func applyToAppKit() {
        let appearance: NSAppearance?
        switch mode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp?.appearance = appearance
    }
}
