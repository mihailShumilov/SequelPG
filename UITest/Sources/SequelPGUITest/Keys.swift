import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Keyboard input posted to the app's process only — other apps and the
/// person's own typing are unaffected.
enum Keys {
    static let codes: [String: Int] = [
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "esc": kVK_Escape, "delete": kVK_Delete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C,
        "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I,
        "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
    ]

    /// Sends a shortcut such as `cmd+return` or `cmd+shift+w` to `pid`.
    static func press(_ shortcut: String, to pid: pid_t) throws {
        var flags: CGEventFlags = []
        var keyName = ""
        for part in shortcut.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: keyName = part
            }
        }
        guard let code = codes[keyName] else { throw Failure("unknown key “\(keyName)”") }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            else { continue }
            event.flags = flags
            event.postToPid(pid)
            usleep(20000)
        }
    }

    /// Types `text` into whatever has keyboard focus in `pid`.
    static func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for character in text.utf16 {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                var unit = character
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event.postToPid(pid)
            }
            usleep(8000)
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
