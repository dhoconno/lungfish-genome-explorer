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
        let bubble = AIMessageBubbleView(text: "Hello from the assistant", isUser: false)
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
        NSPasteboard.general.clearContents()
        // NSButton performs the click and reports false from the press call.
        _ = AccessibilityTreeProbe.press(button)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Hello from the assistant")
    }

    func testUserMessagesHaveNoCopyButton() {
        let bubble = AIMessageBubbleView(text: "Question", isUser: true)
        XCTAssertNil(copyButton(in: bubble))
    }
}
