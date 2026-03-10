import AppKit

/// Adaptive colors for SQL syntax highlighting that work in both light and dark mode.
enum SQLSyntaxColors {
    static let keyword = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.81, green: 0.62, blue: 1.0, alpha: 1.0)   // light purple
            : NSColor(red: 0.36, green: 0.18, blue: 0.57, alpha: 1.0)  // dark purple
    }

    static let string = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 1.0, green: 0.51, blue: 0.44, alpha: 1.0)   // salmon
            : NSColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1.0)  // dark red
    }

    static let comment = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.42, green: 0.66, blue: 0.31, alpha: 1.0)  // muted green
            : NSColor(red: 0.0, green: 0.46, blue: 0.0, alpha: 1.0)    // forest green
    }

    static let number = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.36, green: 0.85, blue: 1.0, alpha: 1.0)   // light cyan
            : NSColor(red: 0.11, green: 0.43, blue: 0.57, alpha: 1.0)  // teal
    }

    static let op = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1.0)  // coral
            : NSColor(red: 0.68, green: 0.24, blue: 0.64, alpha: 1.0)  // magenta
    }

    static let identifier = NSColor.labelColor
    static let plain = NSColor.labelColor
}
