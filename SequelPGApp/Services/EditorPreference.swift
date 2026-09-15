import AppKit
import Observation
import SwiftUI

/// Monospaced faces offered for the SQL editor and the Definition view.
enum EditorFontFamily: String, CaseIterable, Identifiable, Sendable {
    case system
    case jetBrainsMono
    case menlo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "SF Mono (System)"
        case .jetBrainsMono: return "JetBrains Mono"
        case .menlo: return "Menlo"
        }
    }

    /// Resolves the family at the requested size, falling back to the system
    /// monospaced font when a bundled/installed face is unavailable.
    func nsFont(size: CGFloat) -> NSFont {
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        switch self {
        case .system: return fallback
        case .jetBrainsMono: return NSFont(name: "JetBrainsMono-Regular", size: size) ?? fallback
        case .menlo: return NSFont(name: "Menlo", size: size) ?? fallback
        }
    }
}

/// Persists the user's SQL-editor preferences and exposes them to SwiftUI. A
/// single shared instance is injected into the environment from the app entry
/// point, mirroring `ThemePreference`.
///
/// Holds the completion-popup switch, the query-timeout setting, and the
/// editor font.
///
/// The as-you-type completion popup is divisive — some users lean on it,
/// others find it fights their typing (GH #4) — so it needs to be
/// turn-off-able. Disabling it only suppresses the automatic trigger; the
/// on-demand completion (Escape / ⌃Space) still works.
@MainActor
@Observable
final class EditorPreference {
    static let shared = EditorPreference()

    /// Fallback when the user never picked a timeout — matches the historical
    /// hard-coded cap so existing installs keep their behavior.
    static let defaultQueryTimeoutSeconds = 10
    static let defaultFontSize = 13
    static let fontSizeRange = 10 ... 20

    private let autocompleteKey = "com.sequelpg.autocompleteWhileTyping"
    private let queryTimeoutKey = "com.sequelpg.queryTimeoutSeconds"
    private let fontFamilyKey = "com.sequelpg.editorFontFamily"
    private let fontSizeKey = "com.sequelpg.editorFontSize"
    private let defaults: UserDefaults

    /// When true (the default), the completion popup appears automatically
    /// while typing an identifier. When false, the editor never triggers it on
    /// its own — the user can still invoke completion manually with Escape.
    var autocompleteWhileTyping: Bool {
        didSet {
            guard oldValue != autocompleteWhileTyping else { return }
            defaults.set(autocompleteWhileTyping, forKey: autocompleteKey)
        }
    }

    /// Maximum time a user-run query (Run / Explain / content page load) may
    /// execute before it is aborted, in seconds. `0` disables the limit — the
    /// query runs until it finishes or the user presses Stop.
    var queryTimeoutSeconds: Int {
        didSet {
            guard oldValue != queryTimeoutSeconds else { return }
            defaults.set(queryTimeoutSeconds, forKey: queryTimeoutKey)
        }
    }

    /// Monospaced face used by the SQL editor and the Definition view.
    var fontFamily: EditorFontFamily {
        didSet {
            guard oldValue != fontFamily else { return }
            defaults.set(fontFamily.rawValue, forKey: fontFamilyKey)
        }
    }

    /// Point size for the SQL editor and the Definition view.
    var fontSize: Int {
        didSet {
            guard oldValue != fontSize else { return }
            defaults.set(fontSize, forKey: fontSizeKey)
        }
    }

    /// The resolved editor font.
    var editorFont: NSFont {
        fontFamily.nsFont(size: CGFloat(fontSize))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` lets us tell "never set" (→ default on) apart from
        // an explicit `false` the user chose. `bool(forKey:)` alone would read
        // a missing key as false and silently flip the default.
        if let stored = defaults.object(forKey: autocompleteKey) as? Bool {
            autocompleteWhileTyping = stored
        } else {
            autocompleteWhileTyping = true
        }
        if let stored = defaults.object(forKey: queryTimeoutKey) as? Int, stored >= 0 {
            queryTimeoutSeconds = stored
        } else {
            queryTimeoutSeconds = Self.defaultQueryTimeoutSeconds
        }
        if let raw = defaults.string(forKey: fontFamilyKey), let family = EditorFontFamily(rawValue: raw) {
            fontFamily = family
        } else {
            fontFamily = .system
        }
        if let stored = defaults.object(forKey: fontSizeKey) as? Int, Self.fontSizeRange.contains(stored) {
            fontSize = stored
        } else {
            fontSize = Self.defaultFontSize
        }
    }
}
