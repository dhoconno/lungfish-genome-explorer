import XCTest
import AppKit
@testable import LungfishApp
import LungfishKit

@MainActor
final class ViewerZoomShortcutHandlerTests: XCTestCase {
    func testCommandEqualsTriggersZoomIn() throws {
        let handler = makeHandler()

        XCTAssertTrue(handler.handleZoomShortcut(commandEvent(keyCode: 24, characters: "=")))
        XCTAssertEqual(actions, ["in"])
    }

    func testCommandMinusTriggersZoomOut() throws {
        let handler = makeHandler()

        XCTAssertTrue(handler.handleZoomShortcut(commandEvent(keyCode: 78, characters: "-")))
        XCTAssertEqual(actions, ["out"])
    }

    func testCommandZeroTriggersZoomToFit() throws {
        let handler = makeHandler()

        XCTAssertTrue(handler.handleZoomShortcut(commandEvent(keyCode: 82, characters: "0")))
        XCTAssertEqual(actions, ["fit"])
    }

    func testNonCommandShortcutIsIgnored() throws {
        let handler = makeHandler()

        XCTAssertFalse(handler.handleZoomShortcut(commandEvent(keyCode: 24, characters: "=", modifiers: [])))
        XCTAssertTrue(actions.isEmpty)
    }

    private var actions: [String] = []

    private func makeHandler() -> ZoomShortcutHandler {
        ZoomShortcutHandler(
            zoomIn: { self.actions.append("in") },
            zoomOut: { self.actions.append("out") },
            zoomToFit: { self.actions.append("fit") }
        )
    }

    private func commandEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
