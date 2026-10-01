// GenotypeMatrixKeyEquivalentTests.swift - The matrix claims its ⌥⌘ shortcuts only while it owns keyboard focus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeMatrixKeyEquivalentTests: XCTestCase {
    private func keyEvent(_ character: String, modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ))
    }

    /// AppKit forwards `performKeyEquivalent` to every view in the window,
    /// so without a focus gate the matrix intercepted ⌥⌘N (Window > New
    /// Window for Current Project) and its other shortcuts from any control.
    func testMatrixIgnoresKeyEquivalentsWhileAnotherViewHasFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView!.bounds)
        let matrix = GenotypeComparisonMatrixView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        let textField = NSTextField(frame: NSRect(x: 0, y: 540, width: 200, height: 24))
        container.addSubview(matrix)
        container.addSubview(textField)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertFalse(matrix.ownsKeyboardFocus)
        for key in ["n", "x", "p", "r", "m"] {
            let event = try keyEvent(key, modifiers: [.command, .option], window: window)
            XCTAssertFalse(matrix.performKeyEquivalent(with: event), "⌥⌘\(key.uppercased()) must fall through to the menu bar while a text field has focus")
        }

        XCTAssertTrue(window.makeFirstResponder(matrix))
        XCTAssertTrue(matrix.ownsKeyboardFocus)
        // ⌥⌘N is no longer a matrix shortcut at all (it is New Window for
        // Current Project), so it falls through even with the matrix focused.
        let newWindow = try keyEvent("n", modifiers: [.command, .option], window: window)
        XCTAssertFalse(matrix.performKeyEquivalent(with: newWindow))
    }

    func testFalseNegativeShortcutIsOptionCommandX() {
        let state = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
            selectionTargets: [],
            capability: GenotypeMatrixReviewCapability.evaluate(
                selection: [], evidence: .init(), reviews: [], comments: [], isWritable: false
            ),
            visibilityCapability: .empty,
            keyModifierRawValue: NSEvent.ModifierFlags([.command, .option]).rawValue
        ))
        func key(_ command: GenotypeMatrixContextCommand) -> String? {
            state.items.first { $0.command == command }?.keyEquivalent
        }
        XCTAssertEqual(key(.markFalsePositive), "p")
        XCTAssertEqual(key(.markFalseNegative), "x")
        XCTAssertEqual(key(.clearReview), "r")
        XCTAssertEqual(key(.editComment), "", "Option-Command-M is macOS Minimize All")
        XCTAssertFalse(state.items.contains { $0.keyEquivalent == "n" })
    }
}
