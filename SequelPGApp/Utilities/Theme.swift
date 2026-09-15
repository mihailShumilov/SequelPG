import AppKit
import SwiftUI

/// Visual vocabulary for SequelPG. The chrome — windows, sidebar, toolbars,
/// lists, sheets, buttons, labels — uses the system's semantic colors and
/// SF Pro so the app looks and behaves like any other macOS application and
/// respects the user's accent-color and appearance settings. Monospaced type
/// and the syntax palette below are reserved for *data and code*: SQL, DDL,
/// identifiers, cell values, type names.
///
/// Colors are exposed both as SwiftUI `Color` and as `NSColor` so AppKit-backed
/// views (the SQL editor, the results grid) resolve to the same values.
enum Theme {
    // MARK: - Semantic surfaces (system-backed)

    /// Content canvas: editors, result grids, definition text.
    static let bg = Color(nsColor: bgNS)
    /// Window chrome: bars, panels, the sidebar's fallback.
    static let bg2 = Color(nsColor: bg2NS)
    /// Raised panel inside content (cards, popup lists).
    static let panel = Color(nsColor: panelNS)
    /// Slightly recessed panel (card headers, secondary strips).
    static let panel2 = Color(nsColor: panel2NS)
    static let line = Color(nsColor: lineNS)
    static let line2 = Color(nsColor: line2NS)

    static let ink = Color(nsColor: inkNS)
    static let ink2 = Color(nsColor: ink2NS)
    static let ink3 = Color(nsColor: ink3NS)
    static let ink4 = Color(nsColor: ink4NS)

    static let accent = Color.accentColor
    static let accentDim = Color.accentColor.opacity(0.7)
    /// Foreground on top of an accent fill.
    static let onAccent = Color.white

    // MARK: - Data/code palette (syntax highlighting, type pills, ERD)

    static let rose = Color(nsColor: roseNS)
    static let blue = Color(nsColor: blueNS)
    static let violet = Color(nsColor: violetNS)
    static let amber = Color(nsColor: amberNS)
    static let mauve = Color(nsColor: mauveNS)
    static let cyan = Color(nsColor: cyanNS)

    // MARK: - NSColor bridges

    static let bgNS = NSColor.textBackgroundColor
    static let bg2NS = NSColor.windowBackgroundColor
    static let panelNS = NSColor.controlBackgroundColor
    static let panel2NS = NSColor.underPageBackgroundColor
    static let lineNS = NSColor.separatorColor
    static let line2NS = NSColor.gridColor

    static let inkNS = NSColor.labelColor
    static let ink2NS = NSColor.secondaryLabelColor
    static let ink3NS = NSColor.secondaryLabelColor
    static let ink4NS = NSColor.tertiaryLabelColor

    static let accentNS = NSColor.controlAccentColor

    static let roseNS = dynamic("app.rose", dark: 0xEF_9B_8A, light: 0xB8_4A_2E)
    static let blueNS = dynamic("app.blue", dark: 0x9E_C5_FF, light: 0x2F_5F_B7)
    static let violetNS = dynamic("app.violet", dark: 0xC5_A7_FF, light: 0x6A_4A_C8)
    static let amberNS = dynamic("app.amber", dark: 0xFF_D4_79, light: 0x9E_74_0F)
    static let mauveNS = dynamic("app.mauve", dark: 0xD4_A3_FF, light: 0x84_4F_C0)
    static let cyanNS = dynamic("app.cyan", dark: 0x80_D4_D6, light: 0x1F_7B_7D)

    // MARK: - Dynamic color helpers

    private static func dynamic(_ name: String, dark: Int, light: Int) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
            ]) != nil
            return color(fromHex: isDark ? dark : light)
        }
    }

    private static func color(fromHex hex: Int) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - Fonts

    /// Monospaced font for identifiers, values, and SQL fragments shown inside
    /// otherwise-proportional UI. Uses the system monospaced face (SF Mono).
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Emphasised proportional font for object titles and empty-state headlines.
    static func display(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// Registers the bundled JetBrains Mono faces so the editor-font preference
    /// can offer them. The build also sets `INFOPLIST_KEY_ATSApplicationFontsPath`;
    /// registering again is harmless and keeps previews/tests working.
    static func registerBundledFonts() {
        let fontNames = [
            "JetBrainsMono-Regular",
            "JetBrainsMono-Medium",
            "JetBrainsMono-Bold",
        ]
        for name in fontNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            else { continue }
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}

// MARK: - Type Pill Colors

extension Theme {
    /// Color used for the "type pill" decoration that follows a column name.
    /// Built-in PG types get violet; user-defined types get mauve; timestamps cyan;
    /// json/jsonb amber. Falls back to violet for anything else.
    static func typePillColor(dataType: String?, udtName: String? = nil) -> Color {
        let dt = (dataType ?? "").lowercased()
        let udt = (udtName ?? "").lowercased()
        if dt == "json" || dt == "jsonb" || udt == "json" || udt == "jsonb" { return amber }
        if dt.contains("timestamp") || dt.contains("time") || dt == "date" { return cyan }
        if udt == "user-defined" || dt == "user-defined" { return mauve }
        if udt.isEmpty || ["uuid", "text", "varchar", "char", "int2", "int4", "int8", "bool", "boolean",
                           "smallint", "integer", "bigint", "numeric", "decimal", "real",
                           "double precision", "float4", "float8", "bytea", "money"].contains(dt) {
            return violet
        }
        return mauve
    }
}

// MARK: - Reusable view modifiers

extension View {
    /// Standard 13pt body text in the primary label color.
    func appBody(_ size: CGFloat = 13) -> some View {
        font(.system(size: size))
            .foregroundStyle(.primary)
    }

    /// Monospaced text for identifiers, values, and SQL fragments.
    func appMono(_ size: CGFloat = 12, weight: Font.Weight = .regular, color: Color = .secondary) -> some View {
        font(Theme.mono(size: size, weight: weight))
            .foregroundStyle(color)
    }

    /// Emphasised title for object headers and empty states.
    func appDisplay(_ size: CGFloat = 20, color: Color = .primary) -> some View {
        font(Theme.display(size: size))
            .foregroundStyle(color)
    }

    /// Quiet uppercase section caption (like Finder's sidebar group titles).
    func appSectionLabel() -> some View {
        font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Reusable UI pieces

/// A small uppercase tag with a colored tint, used for things like "BTREE",
/// "PRIMARY", "PARTIAL" next to index names, or "uuid", "user-defined" next to
/// column names.
struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = Theme.violet) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(.rect(cornerRadius: 3))
    }
}

/// Section title used inside content panes (Structure, Inspector, EXPLAIN).
/// Headline on the left, optional count, optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            if let count {
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// Compact status strip pinned to the bottom of a content pane (Finder-style).
/// Hosts small controls and read-only status text on a bar material.
struct BottomBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            content()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Inline, non-modal message banner (errors, warnings, notes) that sits at the
/// top of a pane instead of interrupting with an alert.
struct InlineBanner: View {
    enum Kind {
        case error, warning, info

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return .accentColor
            }
        }

        var icon: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let kind: Kind
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.icon)
                .foregroundStyle(kind.color)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(kind.color.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Standard bottom-right button row for sheets: optional leading content, then
/// Cancel and a prominent default action.
struct SheetButtonBar<Leading: View>: View {
    let cancelTitle: String
    let confirmTitle: String
    let confirmDisabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let leading: () -> Leading

    init(
        cancelTitle: String = "Cancel",
        confirmTitle: String,
        confirmDisabled: Bool = false,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }
    ) {
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.confirmDisabled = confirmDisabled
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.leading = leading
    }

    var body: some View {
        HStack {
            leading()
            Spacer()
            Button(cancelTitle, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(confirmDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Text field with a menu of suggested values. Used wherever a PostgreSQL
/// type name (or similar free-form identifier) is entered: the user can pick
/// a common value or type any custom one.
struct SuggestingTextField: View {
    let label: String
    @Binding var text: String
    let suggestions: [String]
    var monospaced: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
            Menu {
                ForEach(suggestions, id: \.self) { value in
                    Button(value) { text = value }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a common value")
        }
    }
}

/// Common PostgreSQL column type names offered by `SuggestingTextField`.
enum PGTypeSuggestions {
    static let column = [
        "text", "varchar(255)", "integer", "bigint", "smallint",
        "boolean", "numeric", "numeric(10,2)", "real", "double precision",
        "date", "timestamp", "timestamptz", "time", "timetz", "interval",
        "uuid", "jsonb", "json", "bytea", "serial", "bigserial",
    ]
}

// MARK: - Native search field

/// `NSSearchField` bridge: rounded search-style field with the system
/// magnifier, clear button, and Escape-to-clear. Used for sidebar and list
/// filtering where SwiftUI's `.searchable` placement isn't appropriate.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String = "Filter"
    var controlSize: NSControl.ControlSize = .small

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.controlSize = controlSize
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }
    }
}
