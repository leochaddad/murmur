import Carbon.HIToolbox
import XCTest
@testable import Murmur

final class ShortcutTests: XCTestCase {
    func testDefaultShortcut() {
        let shortcut = Shortcut.defaultDictation
        XCTAssertEqual(shortcut.displayString, "⌃⇧Space")
        XCTAssertEqual(shortcut.carbonModifiers, UInt32(controlKey | shiftKey))
        XCTAssertNil(shortcut.validationError)
    }

    func testOptionOnlyShortcutsAreRejected() {
        // macOS 15 refuses hot keys whose only modifiers are ⌥ or ⌥⇧.
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option]).validationError)
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option, .shift]).validationError)
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.option, .command]).validationError)
    }

    func testBareKeysNeedModifiersExceptFunctionKeys() {
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: []).validationError)
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_F13), modifiers: []).validationError)
    }

    func testModifierOnlyShortcuts() {
        let fn = Shortcut.modifierKey(UInt16(kVK_Function))
        XCTAssertTrue(fn.isModifierOnly)
        XCTAssertNil(fn.validationError)
        XCTAssertEqual(Shortcut.modifierKey(UInt16(kVK_RightOption)).displayString, "Right ⌥")
        XCTAssertNotNil(Shortcut.modifierKey(UInt16(kVK_Command)).validationError)
    }

    func testCodableRoundTrip() throws {
        let shortcut = Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .option])
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded, shortcut)
    }

    func testRightModifiersAreDistinguishedFromLeft() {
        // Device-dependent bits: right ⌥ = 0x40, left ⌥ = 0x20.
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        XCTAssertTrue(ModifierKeyMonitor.isPressed(UInt16(kVK_RightOption), in: rightOption))
        XCTAssertFalse(ModifierKeyMonitor.isPressed(UInt16(kVK_RightOption), in: leftOption))
        XCTAssertTrue(ModifierKeyMonitor.isOnlyModifier(UInt16(kVK_RightOption), in: rightOption))
        XCTAssertFalse(ModifierKeyMonitor.isOnlyModifier(UInt16(kVK_RightOption), in: rightOption.union(.command)))
    }

    func testPasteKeyCodeOnCurrentLayout() {
        // On QWERTY-like layouts (including ABNT2) ⌘V is key code 9.
        XCTAssertNotNil(KeyboardLayout.keyCode(for: "v"))
    }
}
