import AppKit

/// SQL syntax-highlight palette. Aligned with the editorial design tokens —
/// keywords in cool blue, functions in violet, strings in rose, numbers in
/// amber, comments in muted ink. Each color is a dynamic `NSColor` that
/// resolves to the light or dark variant based on the text view's effective
/// appearance, so highlighting stays readable when the user switches themes.
enum SQLSyntaxColors {
    static let keyword = Theme.blueNS
    static let function = Theme.violetNS
    static let string = Theme.roseNS
    static let comment = Theme.ink3NS
    static let number = Theme.amberNS
    static let op = Theme.ink3NS
    static let type = Theme.mauveNS
    static let identifier = Theme.inkNS
    static let plain = Theme.inkNS
}
