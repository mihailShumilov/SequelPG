import AppKit

/// SQL syntax-highlight palette. Aligned with the editorial design tokens —
/// keywords in cool blue, functions in violet, strings in rose, numbers in
/// amber, comments in muted ink. Same palette in light and dark mode (the app
/// is dark-only).
enum SQLSyntaxColors {
    static let keyword = NSColor(srgbRed: 0x9e / 255, green: 0xc5 / 255, blue: 0xff / 255, alpha: 1)
    static let function = NSColor(srgbRed: 0xc5 / 255, green: 0xa7 / 255, blue: 0xff / 255, alpha: 1)
    static let string = NSColor(srgbRed: 0xef / 255, green: 0x9b / 255, blue: 0x8a / 255, alpha: 1)
    static let comment = NSColor(srgbRed: 0x8c / 255, green: 0x86 / 255, blue: 0x76 / 255, alpha: 1)
    static let number = NSColor(srgbRed: 0xff / 255, green: 0xd4 / 255, blue: 0x79 / 255, alpha: 1)
    static let op = NSColor(srgbRed: 0x8c / 255, green: 0x86 / 255, blue: 0x76 / 255, alpha: 1)
    static let type = NSColor(srgbRed: 0xd4 / 255, green: 0xa3 / 255, blue: 0xff / 255, alpha: 1)
    static let identifier = NSColor(srgbRed: 0xf0 / 255, green: 0xec / 255, blue: 0xe2 / 255, alpha: 1)
    static let plain = NSColor(srgbRed: 0xf0 / 255, green: 0xec / 255, blue: 0xe2 / 255, alpha: 1)
}
