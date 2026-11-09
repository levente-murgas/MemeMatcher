import Foundation
import CoreGraphics

/// Everything about *what* the keyboard shows, kept as plain data so the view
/// controller only has to worry about *how* to render and wire it up.
///
/// Layouts are data, so swapping QWERTY for QWERTZ/AZERTY is a one-line change
/// (see `letterRows`) rather than a rewrite.
enum Plane {
    case letters
    case numbers   // 123
    case symbols   // #+=
}

enum ShiftState {
    case off
    case on        // one-shot: reverts after the next character
    case capsLock

    var isUppercase: Bool { self != .off }
}

/// A single thing the user can press.
enum Key: Equatable {
    case character(String)
    case shift
    case backspace
    case space
    case `return`
    case plane(PlaneTarget)
    case globe
    /// Invisible half-key used to inset a row (e.g. the A–L row).
    case spacer

    /// Which plane a plane-switch key moves to. Separate from `Plane` so the
    /// key can be `Equatable` without recursion headaches.
    enum PlaneTarget: Equatable {
        case letters, numbers, symbols
    }

    /// Keys that type something into the document.
    var isCharacter: Bool {
        if case .character = self { return true }
        return self == .space
    }

    /// Special keys get the darker "function key" styling, like iOS.
    var isFunctionKey: Bool {
        switch self {
        case .character, .space, .spacer: return false
        default: return true
        }
    }
}

/// A key plus how much horizontal space it takes, in "letter key" units.
struct KeySpec {
    let key: Key
    let widthUnits: CGFloat

    init(_ key: Key, width: CGFloat = 1) {
        self.key = key
        self.widthUnits = width
    }
}

/// Which letter arrangement the keyboard uses. Switchable from the keyboard
/// itself and remembered between sessions.
enum LetterLayout: String, CaseIterable {
    case qwerty
    case qwertz

    var displayName: String {
        switch self {
        case .qwerty: return "QWERTY"
        case .qwertz: return "QWERTZ"
        }
    }

    var next: LetterLayout {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    fileprivate var rows: [String] {
        switch self {
        case .qwerty:
            return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .qwertz:
            return ["qwertzuiop", "asdfghjkl", "yxcvbnm"]
        }
    }
}

enum KeyboardLayout {

    private static let numberRows = [
        "1234567890",
        "-/:;()$&@\"",
        ".,?!'",
    ]

    private static let symbolRows = [
        "[]{}#%^*+=",
        "_\\|~<>€£¥•",
        ".,?!'",
    ]

    /// The four rows for a plane. Shift only affects rendering, not structure.
    static func rows(for plane: Plane, letters: LetterLayout = .qwerty) -> [[KeySpec]] {
        switch plane {
        case .letters:
            let letterRows = letters.rows
            return [
                letterRows[0].map { KeySpec(.character(String($0))) },
                // Inset by half a key each side, exactly like iOS.
                [KeySpec(.spacer, width: 0.5)]
                    + letterRows[1].map { KeySpec(.character(String($0))) }
                    + [KeySpec(.spacer, width: 0.5)],
                [KeySpec(.shift, width: 1.5)]
                    + letterRows[2].map { KeySpec(.character(String($0))) }
                    + [KeySpec(.backspace, width: 1.5)],
                bottomRow(planeKey: .numbers, planeTitle: "123"),
            ]

        case .numbers:
            return [
                numberRows[0].map { KeySpec(.character(String($0))) },
                numberRows[1].map { KeySpec(.character(String($0))) },
                [KeySpec(.plane(.symbols), width: 1.5)]
                    + numberRows[2].map { KeySpec(.character(String($0))) }
                    + [KeySpec(.backspace, width: 1.5)],
                bottomRow(planeKey: .letters, planeTitle: "ABC"),
            ]

        case .symbols:
            return [
                symbolRows[0].map { KeySpec(.character(String($0))) },
                symbolRows[1].map { KeySpec(.character(String($0))) },
                [KeySpec(.plane(.numbers), width: 1.5)]
                    + symbolRows[2].map { KeySpec(.character(String($0))) }
                    + [KeySpec(.backspace, width: 1.5)],
                bottomRow(planeKey: .letters, planeTitle: "ABC"),
            ]
        }
    }

    private static func bottomRow(planeKey: Key.PlaneTarget, planeTitle: String) -> [KeySpec] {
        [
            KeySpec(.plane(planeKey), width: 1.5),
            KeySpec(.globe),
            KeySpec(.space, width: 5),
            KeySpec(.return, width: 2.5),
        ]
    }

    /// What to draw on a key.
    static func title(for key: Key, plane: Plane, shift: ShiftState) -> String? {
        switch key {
        case .character(let value):
            // Only letters change case; digits and symbols never do.
            return (plane == .letters && shift.isUppercase) ? value.uppercased() : value
        case .space:      return "space"
        case .return:     return "return"
        case .plane(let target):
            switch target {
            case .letters: return "ABC"
            case .numbers: return "123"
            case .symbols: return "#+="
            }
        case .shift, .backspace, .globe, .spacer:
            return nil   // these use SF Symbols instead
        }
    }

    /// SF Symbol for keys drawn as icons.
    static func symbolName(for key: Key, shift: ShiftState) -> String? {
        switch key {
        case .shift:
            switch shift {
            case .off:      return "shift"
            case .on:       return "shift.fill"
            case .capsLock: return "capslock.fill"
            }
        case .backspace: return "delete.left"
        case .globe:     return "globe"
        default:         return nil
        }
    }
}
