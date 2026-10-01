import AppKit
import XCTest
import LungfishTestSupport
@testable import LungfishApp

/// The AI assistant's copy button is hover-styled, so it must be named for
/// AX clients and reachable without a pointer.
@MainActor
final class AIMessageCopyButtonAccessibilityTests: XCTestCase {
    private func copyButton(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.accessibilityIdentifier() == "ai-message-copy-button" {
                return button
            }
            if let found = copyButton(in: subview) { return found }
        }
        return nil
    }

    func testCopyButtonIsLabelledCopyMessageAndCopiesThroughPress() throws {
        // The general pasteboard is one per machine, so a copy made by a test
        // in another parallel process would show up in the assertion.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bubble = AIMessageBubbleView(text: "Hello from the assistant", isUser: false)
        bubble.pasteboard = pasteboard
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bubble.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        window.contentView = container
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        container.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(copyButton(in: bubble))
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(AccessibilityTreeProbe.role(button), NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(AccessibilityTreeProbe.label(button), "Copy Message")
        XCTAssertNotNil(AccessibilityTreeProbe.help(button))
        XCTAssertEqual(button.toolTip, AccessibilityTreeProbe.label(button), "label and tooltip share one title")
        XCTAssertGreaterThanOrEqual(
            button.alphaValue, 0.6,
            "the resting icon must keep 3:1 non-text contrast"
        )
        _ = try XCTUnwrap(button as? AIMessageCopyButton)
        _ = window.makeFirstResponder(button)
        if button.acceptsFirstResponder, window.firstResponder === button {
            XCTAssertEqual(button.alphaValue, 1.0, "keyboard focus lifts the icon to full strength")
        }
        pasteboard.clearContents()
        // NSButton performs the click and reports false from the press call.
        _ = AccessibilityTreeProbe.press(button)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello from the assistant")
    }

    func testUserMessagesHaveNoCopyButton() {
        let bubble = AIMessageBubbleView(text: "Question", isUser: true)
        XCTAssertNil(copyButton(in: bubble))
    }
}
