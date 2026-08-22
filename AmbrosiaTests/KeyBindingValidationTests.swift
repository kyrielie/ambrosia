import XCTest
@testable import Ambrosia

// Covers `validate(_:for:against:)` in KeyBinding.swift. That function's own
// doc comment claims it is "Pure, UI/NSEvent-free so it's unit-testable
// alongside LibraryVisibilityPolicyTests" -- this file is what backs that
// claim up. No fixture needed: KeyBinding/ModifierKey/ValidationResult have
// no actor or AppKit dependency (KeyBinding.swift imports AppKit only for
// NSEvent.ModifierFlags on the unrelated `keyEquivalentModifierMask`
// property, which these tests don't touch).
final class KeyBindingValidationTests: XCTestCase {

    // MARK: - Reserved combinations

    func test_reservedCommandC_isRejected() {
        let binding = KeyBinding(character: "c", modifiers: [.command])
        let result = validate(binding, for: .addAnnotation, against: [:])
        guard case .reservedBySystem(let combo) = result else {
            return XCTFail("expected .reservedBySystem, got \(result)")
        }
        XCTAssertEqual(combo, "⌘C")
    }

    func test_reservedShiftCommandZ_isRejected() {
        let binding = KeyBinding(character: "z", modifiers: [.command, .shift])
        XCTAssertFalse(validate(binding, for: .toggleFindBar, against: [:]).isValid)
    }

    func test_reservedCommandComma_isRejectedEvenThoughNotARebindableAction() {
        // Cmd+, is wired to Preferences in AmbrosiaApp.swift, not to any
        // RebindableAction -- it must still be rejected here, or a user could
        // silently steal it by rebinding an action onto it.
        let binding = KeyBinding(character: ",", modifiers: [.command])
        XCTAssertFalse(validate(binding, for: .showTOCSidebar, against: [:]).isValid)
    }

    // MARK: - Collisions with an existing binding

    func test_collisionWithDifferentAction_isRejected() {
        let existing: [RebindableAction: KeyBinding] = [
            .toggleReadingMode: KeyBinding(character: "d", modifiers: [.command])
        ]
        let attempted = KeyBinding(character: "d", modifiers: [.command])
        let result = validate(attempted, for: .addAnnotation, against: existing)
        guard case .collidesWith(let action) = result else {
            return XCTFail("expected .collidesWith, got \(result)")
        }
        XCTAssertEqual(action, .toggleReadingMode)
    }

    func test_sameBindingOnSameAction_isValid() {
        // Re-validating an action's own current binding (e.g. opening the
        // Shortcuts tab without changing anything) must not flag itself as
        // a collision with itself.
        let existing: [RebindableAction: KeyBinding] = [
            .addAnnotation: KeyBinding(character: "n", modifiers: [.command, .shift])
        ]
        let result = validate(
            KeyBinding(character: "n", modifiers: [.command, .shift]),
            for: .addAnnotation,
            against: existing
        )
        XCTAssertTrue(result.isValid)
    }

    func test_noReservedOrCollision_isValid() {
        let result = validate(
            KeyBinding(character: "k", modifiers: [.control, .option]),
            for: .findNext,
            against: [:]
        )
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.rejectionMessage)
    }

    // MARK: - displayString

    func test_displayString_ordersModifiersControlOptionShiftCommand() {
        let binding = KeyBinding(character: "m", modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘M")
    }

    func test_displayString_uppercasesCharacter() {
        let binding = KeyBinding(character: "f", modifiers: [.command])
        XCTAssertEqual(binding.displayString, "⌘F")
    }
}
