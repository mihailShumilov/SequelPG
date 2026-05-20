import AppKit
import SwiftUI

/// Visual design system for SequelPG — a developer-tool aesthetic. Warm
/// charcoal canvas in dark mode, warm cream canvas in light mode, phosphor-lime
/// accent in both, JetBrains Mono throughout (bold for display headlines,
/// regular for technical content), SF Pro for UI chrome. No serif and no italic
/// anywhere — the typographic hierarchy comes from size and weight, which
/// reads cleaner in a tool meant for code.
///
/// Colors are built with `NSColor(name:dynamicProvider:)` so a single token
/// resolves to the dark or light variant based on the host view's effective
/// appearance. SwiftUI `Color(nsColor:)` and AppKit drawing both honor the
/// dynamic resolution.
enum Theme {
    // MARK: - Palette (mirrors --app-* tokens in the web design)

    static let bg = swiftUI(bgNS)
    static let bg2 = swiftUI(bg2NS)
    static let panel = swiftUI(panelNS)
    static let panel2 = swiftUI(panel2NS)
    static let line = swiftUI(lineNS)
    static let line2 = swiftUI(line2NS)

    static let ink = swiftUI(inkNS)
    static let ink2 = swiftUI(ink2NS)
    static let ink3 = swiftUI(ink3NS)
    static let ink4 = swiftUI(ink4NS)

    static let accent = swiftUI(accentNS)
    static let accentDim = swiftUI(accentDimNS)

    // Editorial color tokens — used for syntax highlighting and type pills.
    static let rose = swiftUI(roseNS)
    static let blue = swiftUI(blueNS)
    static let violet = swiftUI(violetNS)
    static let amber = swiftUI(amberNS)
    static let mauve = swiftUI(mauveNS)
    static let cyan = swiftUI(cyanNS)

    /// Foreground color to use on top of `accent` fills (lime is bright — needs
    /// near-black ink for legibility).
    static let onAccent = swiftUI(onAccentNS)

    // MARK: - NSColor bridges (for AppKit views: NSTableView, NSTextView, etc.)

    static let bgNS = dynamic("app.bg", dark: 0x14_13_0F, light: 0xFA_F6_EC)
    static let bg2NS = dynamic("app.bg2", dark: 0x1A_19_16, light: 0xF1_EC_DE)
    static let panelNS = dynamic("app.panel", dark: 0x1D_1C_19, light: 0xEC_E5_D4)
    static let panel2NS = dynamic("app.panel2", dark: 0x23_21_20, light: 0xE2_DA_C7)
    static let lineNS = dynamic("app.line", dark: 0x2A_29_25, light: 0xD3_CC_B6)
    static let line2NS = dynamic("app.line2", dark: 0x36_34_2F, light: 0xBE_B5_9C)

    static let inkNS = dynamic("app.ink", dark: 0xF0_EC_E2, light: 0x1A_18_12)
    static let ink2NS = dynamic("app.ink2", dark: 0xC8_C2_B3, light: 0x40_3C_33)
    static let ink3NS = dynamic("app.ink3", dark: 0x8C_86_76, light: 0x6F_69_59)
    static let ink4NS = dynamic("app.ink4", dark: 0x5E_5A_4F, light: 0xA0_99_87)

    static let accentNS = dynamic("app.accent", dark: 0xB9_F2_5A, light: 0x73_A8_22)
    static let accentDimNS = dynamic("app.accentDim", dark: 0x94_C9_48, light: 0x5B_85_1A)

    static let roseNS = dynamic("app.rose", dark: 0xEF_9B_8A, light: 0xC6_5D_3F)
    static let blueNS = dynamic("app.blue", dark: 0x9E_C5_FF, light: 0x2F_5F_B7)
    static let violetNS = dynamic("app.violet", dark: 0xC5_A7_FF, light: 0x6A_4A_C8)
    static let amberNS = dynamic("app.amber", dark: 0xFF_D4_79, light: 0xB0_82_18)
    static let mauveNS = dynamic("app.mauve", dark: 0xD4_A3_FF, light: 0x84_4F_C0)
    static let cyanNS = dynamic("app.cyan", dark: 0x80_D4_D6, light: 0x1F_7B_7D)

    static let onAccentNS = dynamic("app.onAccent", dark: 0x0F_0F_0E, light: 0x10_14_06)

    // MARK: - Dynamic color helpers

    private static func dynamic(_ name: String, dark: Int, light: Int) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            return color(fromHex: isDark ? dark : light)
        }
    }

    private static func color(fromHex hex: Int) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func swiftUI(_ ns: NSColor) -> Color { Color(nsColor: ns) }

    // MARK: - Fonts
    //
    // Custom font PostScript names. When the bundled .ttf files are present
    // Font.custom() picks them up; otherwise SwiftUI silently falls back to the
    // system font for that face, so the app keeps rendering. Inter is already
    // covered by `-apple-system` (SF Pro), so we don't bundle it.

    enum FontName {
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

    /// Display headline font — JetBrains Mono Bold. Used for object names,
    /// section titles, and empty-state headlines. Replaces the earlier
    /// Instrument Serif italic; a developer tool reads better with a
    /// consistent monospace identity than with an editorial serif.
    static func display(size: CGFloat) -> Font {
        .custom(FontName.monoBold, size: size).weight(.bold)
    }

    /// Registers bundled `.ttf` files at runtime. Called once from the app entry
    /// point. The build also sets `INFOPLIST_KEY_ATSApplicationFontsPath` so the
    /// fonts are available without this call; running both is harmless and means
    /// we still get the fonts in unit tests / preview hosts that bypass Info.plist.
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

    /// Display headline — JetBrains Mono Bold. Used sparingly for object
    /// names, section titles, and empty-state headlines. Same family as the
    /// body mono so the whole UI reads as a single typographic system; size
    /// and weight do the work that an editorial serif used to.
    func appDisplay(_ size: CGFloat = 22, color: Color = Theme.ink) -> some View {
        font(Theme.display(size: size))
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
                    .appDisplay(28)
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
