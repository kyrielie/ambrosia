import Foundation
import AppKit

// MARK: - KeyBinding

/// A single rebindable keyboard shortcut: one character plus a set of
/// modifier keys. Not scoped `private` — needed by `ReaderPreferences`,
/// `AmbrosiaApp`/`AppDelegate` (to read live values for `NSMenuItem`), and
/// `ShortcutsTab`/`ShortcutRecorderView` (per Invariant 16).
struct KeyBinding: Codable, Equatable {
    /// Single lowercase character, e.g. "d", "m", "f".
    var character: String
    var modifiers: Set<ModifierKey>

    /// Human-readable form, e.g. "⌘⇧M", for display in the recorder UI and
    /// validation-rejection messages.
    var displayString: String {
        let modifierGlyphs = ModifierKey.allCases
            .filter { modifiers.contains($0) }
            .map(\.glyph)
            .joined()
        return modifierGlyphs + character.uppercased()
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        modifiers.reduce(into: []) { $0.insert($1.nsFlag) }
    }
}

enum ModifierKey: String, Codable, CaseIterable, Hashable {
    case command, shift, option, control

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift:   return .shift
        case .option:  return .option
        case .control: return .control
        }
    }

    /// Display order matches macOS's conventional modifier glyph ordering:
    /// control, option, shift, command.
    static var allCases: [ModifierKey] { [.control, .option, .shift, .command] }

    var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        }
    }
}

// MARK: - RebindableAction

/// Every action whose shortcut can be changed from the Shortcuts preferences
/// tab. Find/Find-Next/Find-Previous were migrated in here per the Pass A
/// decision to remove `ReaderViewController.keyDown`'s local, independent
/// handling of those three keys rather than leave a mixed system.
enum RebindableAction: String, CaseIterable, Codable, Hashable {
    case toggleReadingMode
    case addAnnotation
    case showAnnotationSidebar
    case showTOCSidebar
    case toggleFindBar
    case findNext
    case findPrevious

    /// Must match the literal title string used for this action's
    /// `Button` in `AmbrosiaApp.swift`'s `CommandMenu("Reader")` — the
    /// AppDelegate menu-shortcut sync looks up `NSMenuItem`s by title.
    var displayName: String {
        switch self {
        case .toggleReadingMode:     return "Toggle Reading Mode"
        case .addAnnotation:         return "Add Annotation"
        case .showAnnotationSidebar: return "Show Annotations"
        case .showTOCSidebar:        return "Show Table of Contents"
        case .toggleFindBar:         return "Toggle Find Bar"
        case .findNext:              return "Find Next"
        case .findPrevious:          return "Find Previous"
        }
    }
}

// MARK: - Validation

enum ValidationResult: Equatable {
    case valid
    case reservedBySystem(combo: String)
    case collidesWith(action: RebindableAction)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var rejectionMessage: String? {
        switch self {
        case .valid:
            return nil
        case .reservedBySystem(let combo):
            return "\(combo) is reserved and can't be rebound."
        case .collidesWith(let action):
            return "That combination is already used by \(action.displayName)."
        }
    }
}

/// Reserved combinations that can never be assigned to a `RebindableAction`,
/// whether because they're universal system/clipboard expectations (Cmd+C/V/
/// X/Z/Shift+Cmd+Z) or because they're already wired to non-rebindable
/// app-level commands elsewhere in `AmbrosiaApp.swift` (Cmd+, for
/// Preferences, Cmd+O for Open Calibre Library…). The latter two are NOT
/// part of `RebindableAction`, so without this reserved set a user could
/// silently steal their shortcut by rebinding e.g. Add Annotation onto Cmd+,.
private let reservedBindings: [KeyBinding] = [
    KeyBinding(character: "c", modifiers: [.command]),
    KeyBinding(character: "v", modifiers: [.command]),
    KeyBinding(character: "x", modifiers: [.command]),
    KeyBinding(character: "z", modifiers: [.command]),
    KeyBinding(character: "z", modifiers: [.command, .shift]),
    KeyBinding(character: ",", modifiers: [.command]),
    KeyBinding(character: "o", modifiers: [.command]),
]

/// Pure, UI/NSEvent-free so it's unit-testable alongside
/// `LibraryVisibilityPolicyTests`.
func validate(
    _ binding: KeyBinding,
    for action: RebindableAction,
    against current: [RebindableAction: KeyBinding]
) -> ValidationResult {
    if let reserved = reservedBindings.first(where: { $0 == binding }) {
        return .reservedBySystem(combo: reserved.displayString)
    }
    if let collision = current.first(where: { $0.key != action && $0.value == binding }) {
        return .collidesWith(action: collision.key)
    }
    return .valid
}
