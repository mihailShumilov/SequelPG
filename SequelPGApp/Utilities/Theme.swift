import AppKit
import SwiftUI

/// Visual design system for SequelPG — translates the marketing site's editorial
/// "technical journal" aesthetic into the native macOS app. Warm charcoal canvas,
/// phosphor-lime accent, Instrument Serif italic for editorial headlines, JetBrains
/// Mono for technical content (SQL, types, identifiers), SF Pro for UI chrome.
enum Theme {
    // MARK: - Palette (mirrors --app-* tokens in the web design)

    static let bg = Color(red: 0x14 / 255, green: 0x13 / 255, blue: 0x0f / 255)
    static let bg2 = Color(red: 0x1a / 255, green: 0x19 / 255, blue: 0x16 / 255)
    static let panel = Color(red: 0x1d / 255, green: 0x1c / 255, blue: 0x19 / 255)
    static let panel2 = Color(red: 0x23 / 255, green: 0x21 / 255, blue: 0x20 / 255)
    static let line = Color(red: 0x2a / 255, green: 0x29 / 255, blue: 0x25 / 255)
    static let line2 = Color(red: 0x36 / 255, green: 0x34 / 255, blue: 0x2f / 255)

    static let ink = Color(red: 0xf0 / 255, green: 0xec / 255, blue: 0xe2 / 255)
    static let ink2 = Color(red: 0xc8 / 255, green: 0xc2 / 255, blue: 0xb3 / 255)
    static let ink3 = Color(red: 0x8c / 255, green: 0x86 / 255, blue: 0x76 / 255)
    static let ink4 = Color(red: 0x5e / 255, green: 0x5a / 255, blue: 0x4f / 255)

    static let accent = Color(red: 0xb9 / 255, green: 0xf2 / 255, blue: 0x5a / 255)
    static let accentDim = Color(red: 0x94 / 255, green: 0xc9 / 255, blue: 0x48 / 255)

    // Editorial color tokens — used for syntax highlighting and type pills.
    static let rose = Color(red: 0xef / 255, green: 0x9b / 255, blue: 0x8a / 255)
    static let blue = Color(red: 0x9e / 255, green: 0xc5 / 255, blue: 0xff / 255)
    static let violet = Color(red: 0xc5 / 255, green: 0xa7 / 255, blue: 0xff / 255)
    static let amber = Color(red: 0xff / 255, green: 0xd4 / 255, blue: 0x79 / 255)
    static let mauve = Color(red: 0xd4 / 255, green: 0xa3 / 255, blue: 0xff / 255)
    static let cyan = Color(red: 0x80 / 255, green: 0xd4 / 255, blue: 0xd6 / 255)

    /// Foreground color to use on top of `accent` fills (lime is bright — needs
    /// near-black ink for legibility).
    static let onAccent = Color(red: 0x0f / 255, green: 0x0f / 255, blue: 0x0e / 255)

    // MARK: - NSColor bridges (for AppKit views: NSTableView, NSTextView, etc.)

    static let bgNS = NSColor(srgbRed: 0x14 / 255, green: 0x13 / 255, blue: 0x0f / 255, alpha: 1)
    static let bg2NS = NSColor(srgbRed: 0x1a / 255, green: 0x19 / 255, blue: 0x16 / 255, alpha: 1)
    static let lineNS = NSColor(srgbRed: 0x2a / 255, green: 0x29 / 255, blue: 0x25 / 255, alpha: 1)
    static let accentNS = NSColor(srgbRed: 0xb9 / 255, green: 0xf2 / 255, blue: 0x5a / 255, alpha: 1)
    static let inkNS = NSColor(srgbRed: 0xf0 / 255, green: 0xec / 255, blue: 0xe2 / 255, alpha: 1)
    static let ink3NS = NSColor(srgbRed: 0x8c / 255, green: 0x86 / 255, blue: 0x76 / 255, alpha: 1)

    // MARK: - Fonts
    //
    // Custom font PostScript names. When the bundled .ttf files are present
    // Font.custom() picks them up; otherwise SwiftUI silently falls back to the
    // system font for that face, so the app keeps rendering. Inter is already
    // covered by `-apple-system` (SF Pro), so we don't bundle it.

    enum FontName {
        static let displaySerif = "InstrumentSerif-Regular"
        static let displaySerifItalic = "InstrumentSerif-Italic"
        static let monoRegular = "JetBrainsMono-Regular"
        static let monoMedium = "JetBrainsMono-Medium"
        static let monoBold = "JetBrainsMono-Bold"
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium, .semibold: name = FontName.monoMedium
        case .bold, .heavy, .black: name = FontName.monoBold
        default: name = FontName.monoRegular
        }
        return .custom(name, size: size).weight(weight)
    }

    static func serifItalic(size: CGFloat) -> Font {
        .custom(FontName.displaySerifItalic, size: size)
            .italic()
    }

    static func serif(size: CGFloat) -> Font {
        .custom(FontName.displaySerif, size: size)
    }

    /// Registers bundled `.ttf` files at runtime. Called once from the app entry
    /// point. The build also sets `INFOPLIST_KEY_ATSApplicationFontsPath` so the
    /// fonts are available without this call; running both is harmless and means
    /// we still get the fonts in unit tests / preview hosts that bypass Info.plist.
    static func registerBundledFonts() {
        let fontNames = [
            "InstrumentSerif-Regular",
            "InstrumentSerif-Italic",
            "JetBrainsMono-Regular",
            "JetBrainsMono-Medium",
            "JetBrainsMono-Bold",
        ]
        for name in fontNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            else { continue }
            var error: Unmanaged<CFError>?
            // Ignore failures from "already registered" — re-registering on hot reload
            // is a no-op but returns false.
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
        // Heuristic: PG built-ins typically have lowercase short names without
        // an underscore prefix. User-defined types in this app commonly look
        // like `address_t`, `email_address`, `order_status`, etc.
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
    /// Inter / SF Pro 13pt body text in the warm off-white ink color. Used for
    /// the default UI chrome — labels, list rows, button text — wherever the
    /// design uses the `--app-font-ui` token.
    func appBody(_ size: CGFloat = 13) -> some View {
        font(.system(size: size))
            .foregroundStyle(Theme.ink)
    }

    /// JetBrains Mono for technical content: identifiers, SQL keywords, types,
    /// counts. Matches the `--app-font-mono` token from the web design.
    func appMono(_ size: CGFloat = 12, weight: Font.Weight = .regular, color: Color = Theme.ink2) -> some View {
        font(Theme.mono(size: size, weight: weight))
            .foregroundStyle(color)
    }

    /// Instrument Serif italic — the editorial flourish. Used very sparingly:
    /// object names ("orders", "users"), inspector section titles, empty-state
    /// headlines, the app brand. Never for body text.
    func appDisplayItalic(_ size: CGFloat = 22, color: Color = Theme.ink) -> some View {
        font(Theme.serifItalic(size: size))
            .foregroundStyle(color)
    }

    /// Section header label: tiny uppercase mono text. Mirrors the `.sb-sec`,
    /// `.cf-section-h`, `.struct-sub-h` titles in the web CSS — a quiet structural
    /// cue that doesn't compete with content.
    func appSectionLabel() -> some View {
        font(Theme.mono(size: 10, weight: .regular))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.ink3)
    }
}

// MARK: - Reusable UI pieces

/// A small uppercase tag with a colored tint, used for things like "BTREE",
/// "PRIMARY", "PARTIAL" next to index names, or "uuid", "user-defined" next to
/// column names in headers.
struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = Theme.violet) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.mono(size: 9, weight: .medium))
            .tracking(0.8)
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(.rect(cornerRadius: 3))
    }
}

/// Section header for editorial structure — italic display title with an optional
/// roman-numeral cue (i, ii, iii…) and right-aligned metadata. Used at the top
/// of the Structure tab and the Definition tab, and for the Inspector's "Row
/// Detail" / "Inspector" headers.
struct EditorialSectionHeader: View {
    let title: String
    var numeral: String? = nil
    var kicker: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let numeral {
                Text(numeral)
                    .appMono(11, color: Theme.ink4)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let kicker {
                    Text(kicker)
                        .appSectionLabel()
                }
                Text(title)
                    .appDisplayItalic(28)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Sub-section heading inside Structure / Inspector — a single line with a
/// monospaced "— Title" prefix, a count, and an optional trailing "+" button.
struct SubSectionHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("— \(title)")
                .font(Theme.mono(size: 11, weight: .regular))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.ink2)
            if let count {
                Text("\(count)")
                    .appMono(11, color: Theme.ink4)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Decorative keyboard-cap glyph — `⌘`, `↵`, `F`, etc. — used in empty-state
/// hints and the Run-query toolbar's "⌘↵ to run" affordance.
struct AppKbd: View {
    let key: String
    var body: some View {
        Text(key)
            .font(Theme.mono(size: 11, weight: .regular))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.panel2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.line2, lineWidth: 1)
                    )
            )
    }
}

/// Dashed dotted rule — used between Inspector sections, replacing the macOS
/// default solid Divider where the design calls for the lighter editorial cue.
struct DottedRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Theme.line)
            )
    }
}
