import Observation
import SwiftUI

/// Persists the user's SQL-editor preferences and exposes them to SwiftUI. A
/// single shared instance is injected into the environment from the app entry
/// point, mirroring `ThemePreference`.
///
/// Right now this holds a single switch: whether the editor pops the
/// completion list *as you type*. The as-you-type popup is divisive — some
/// users lean on it, others find it fights their typing (GH #4) — so it needs
/// to be turn-off-able. Disabling it only suppresses the automatic trigger;
/// the macOS-standard on-demand completion (Escape / F5) still works, so the
/// feature remains available to anyone who wants it without getting in the way
/// of anyone who doesn't.
@MainActor
@Observable
final class EditorPreference {
    static let shared = EditorPreference()

    private let autocompleteKey = "com.sequelpg.autocompleteWhileTyping"
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
    }
}
