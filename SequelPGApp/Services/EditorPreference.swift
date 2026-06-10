import Observation
import SwiftUI

/// Persists the user's SQL-editor preferences and exposes them to SwiftUI. A
/// single shared instance is injected into the environment from the app entry
/// point, mirroring `ThemePreference`.
///
/// Holds the completion-popup switch and the query-timeout setting.
///
/// The as-you-type completion popup is divisive — some users lean on it,
/// others find it fights their typing (GH #4) — so it needs to be
/// turn-off-able. Disabling it only suppresses the automatic trigger; the
/// macOS-standard on-demand completion (Escape / F5) still works, so the
/// feature remains available to anyone who wants it without getting in the way
/// of anyone who doesn't.
@MainActor
@Observable
final class EditorPreference {
    static let shared = EditorPreference()

    /// Fallback when the user never picked a timeout — matches the historical
    /// hard-coded cap so existing installs keep their behavior.
    static let defaultQueryTimeoutSeconds = 10

    private let autocompleteKey = "com.sequelpg.autocompleteWhileTyping"
    private let queryTimeoutKey = "com.sequelpg.queryTimeoutSeconds"
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
    }
}
