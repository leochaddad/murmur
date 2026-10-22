import XCTest
@testable import Murmur

final class ActiveScreenTests: XCTestCase {
    // Built-in display as primary, a 4K display to its right and one above it (AppKit coordinates).
    private let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let right = NSRect(x: 1512, y: -200, width: 2560, height: 1440)
    private let above = NSRect(x: -300, y: 982, width: 2560, height: 1440)

    func testAccessibilityFramesAreFlippedAgainstThePrimaryScreen() {
        // A window at the very top left of the primary screen.
        let topLeft = ActiveScreen.appKitFrame(fromAccessibility: .zero, size: CGSize(width: 800, height: 600), primaryScreenHeight: 982)
        XCTAssertEqual(topLeft, NSRect(x: 0, y: 382, width: 800, height: 600))

        // Displays above the primary one have negative Accessibility y.
        let onAbove = ActiveScreen.appKitFrame(fromAccessibility: CGPoint(x: 100, y: -1000), size: CGSize(width: 800, height: 600), primaryScreenHeight: 982)
        XCTAssertEqual(onAbove, NSRect(x: 100, y: 1382, width: 800, height: 600))
        XCTAssertEqual(ActiveScreen.bestMatch(for: onAbove, in: [builtIn, right, above]), 2)
    }

    func testPicksTheScreenShowingMostOfTheWindow() {
        let screens = [builtIn, right, above]
        // A full-screen window on the right display.
        XCTAssertEqual(ActiveScreen.bestMatch(for: right, in: screens), 1)
        // Straddling: mostly on the built-in display.
        XCTAssertEqual(ActiveScreen.bestMatch(for: NSRect(x: 900, y: 100, width: 800, height: 600), in: screens), 0)
        // Straddling: mostly on the right display.
        XCTAssertEqual(ActiveScreen.bestMatch(for: NSRect(x: 1300, y: 100, width: 800, height: 600), in: screens), 1)
    }

    func testOffscreenWindowHasNoScreen() {
        XCTAssertNil(ActiveScreen.bestMatch(for: NSRect(x: 9000, y: 9000, width: 100, height: 100), in: [builtIn, right, above]))
        XCTAssertNil(ActiveScreen.bestMatch(for: .zero, in: [builtIn]))
    }
}
