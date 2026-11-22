// LungfishInfoButtonTests.swift - The info button, its popover, Esc and the catalog check (5.6 U2, U3, A1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
import LungfishTestSupport
@testable import LungfishKit

/// A view behind the popover that records each key it gets. Its keyDown maps keys to commands as a text view does, so
/// Esc also reaches its `cancelOperation`.
private final class RecordingResponderView: NSView {
    private(set) var keyCodes: [UInt16] = []
    private(set) var cancels = 0

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        keyCodes.append(event.keyCode)
        interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) {
        cancels += 1
    }
}

/// A dialog footer in miniature, a field label, its info button and a Cancel button bound to Esc, as the Operations
/// dialogs bind it.
private struct HostedDialog: View {
    let item: LungfishHelpContent.HelpItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Threads")
            LungfishInfoButtonView(item, about: "threads")
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .frame(width: 420, height: 120)
    }
}

private final class CancelCounter {
    var count = 0
}

@MainActor
final class LungfishInfoButtonTests: XCTestCase {
    private let item = LungfishHelpContent.HelpItem(
        id: "test.info.threads",
        summary: "Sets how many threads the tool uses.",
        detail: "More threads finish sooner on a Mac with free cores. The result is the same for any count.",
        audience: .analyst
    )

    private var identifier: String { LungfishInfoButton.accessibilityIdentifier(for: item) }

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    // MARK: The catalog check

    func testCatalogFaultsFlagADuplicateIDALongSummaryAndABannedWord() {
        let longSummary = Array(repeating: "word", count: 21).joined(separator: " ")
        let items = [
            LungfishHelpContent.HelpItem(id: "leaf.one", summary: "Shows one thing.", audience: .benchScientist),
            LungfishHelpContent.HelpItem(id: "leaf.one", summary: "Shows it again.", audience: .benchScientist),
            LungfishHelpContent.HelpItem(id: "leaf.long", summary: longSummary, audience: .benchScientist),
            LungfishHelpContent.HelpItem(
                id: "leaf.banned",
                summary: "Sorts the rows.",
                detail: "A powerful sort.",
                audience: .benchScientist
            ),
            LungfishHelpContent.HelpItem(
                id: "leaf.fine",
                summary: Array(repeating: "word", count: 20).joined(separator: " "),
                audience: .benchScientist
            ),
        ]

        XCTAssertEqual(LungfishHelpContent.catalogFaults(in: items), [
            LungfishHelpContent.CatalogFault(id: "leaf.one", kind: .duplicateID),
            LungfishHelpContent.CatalogFault(id: "leaf.long", kind: .summaryTooLong(words: 21)),
            LungfishHelpContent.CatalogFault(id: "leaf.banned", kind: .bannedWord("powerful")),
        ])
    }

    func testKitCatalogPassesTheCatalogCheck() {
        XCTAssertEqual(LungfishHelpContent.catalogFaults(in: LungfishHelpContent.allItems), [])
    }

    // MARK: The AppKit button

    func testWindowlessButtonHoldsItsWordsBeforeAnyWindow() {
        let button = LungfishInfoButton(item: item, about: "threads")

        _ = button.accessibilityPerformPress()
        XCTAssertFalse(button.isPopoverShown, "with no window nothing shows")
        XCTAssertEqual(button.popoverController.text, item.detail)
        XCTAssertEqual(button.accessibilityLabel(), "About threads")
        XCTAssertEqual(button.toolTip, item.summary)
        XCTAssertEqual(button.accessibilityHelp(), item.summary)
    }

    func testAppKitButtonIsFoundByIDAndOpensOnPressAndOnSpace() throws {
        let (window, _, _) = makeAppKitWindow()
        let element = try XCTUnwrap(axElement(withIdentifier: identifier, in: window), "no AX element \(identifier)")
        let button = try XCTUnwrap(infoButton(of: element), "the element is the info button's cell")

        assertVisibleButton(button, element: element, in: window)

        _ = element.accessibilityPerformPress()
        XCTAssertTrue(button.isPopoverShown, "a VoiceOver press opens the popover")
        XCTAssertEqual(button.popoverController.text, item.detail)
        XCTAssertEqual(
            button.popoverController.textField.accessibilityIdentifier(),
            "\(identifier)-detail"
        )
        XCTAssertTrue(button.closePopover())
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !button.isPopoverShown })

        button.keyDown(with: try key(" ", keyCode: 49, in: window))
        XCTAssertTrue(button.isPopoverShown, "Space opens the popover")
    }

    func testAppKitEscapeClosesThePopoverAndReachesNothingBehind() throws {
        let (window, button, behind) = makeAppKitWindow()
        XCTAssertTrue(window.makeFirstResponder(behind))

        NSApp.sendEvent(try key("\u{1b}", keyCode: 53, in: window))
        XCTAssertEqual(behind.keyCodes, [53], "with no popover, Esc reaches the view behind")
        XCTAssertEqual(behind.cancels, 1)

        button.performClick(nil)
        XCTAssertTrue(button.isPopoverShown)
        NSApp.sendEvent(try key("\u{1b}", keyCode: 53, in: window))
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !button.isPopoverShown }, "Esc closes the popover")
        XCTAssertEqual(behind.keyCodes, [53], "no keyDown of key code 53 reaches the view behind")
        XCTAssertEqual(behind.cancels, 1, "no cancelOperation reaches the view behind")

        button.performClick(nil)
        XCTAssertTrue(button.isPopoverShown)
        NSApp.sendEvent(try key(".", keyCode: 47, modifiers: .command, in: window))
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !button.isPopoverShown }, "Command-period closes it")
        XCTAssertEqual(behind.keyCodes, [53])
        XCTAssertEqual(behind.cancels, 1)

        NSApp.sendEvent(try key("\u{1b}", keyCode: 53, in: window))
        XCTAssertEqual(behind.keyCodes, [53, 53], "once the popover is closed, Esc reaches the view behind again")
    }

    func testHeldSpaceDoesNotToggleThePopover() throws {
        let (window, button, behind) = makeAppKitWindow()
        XCTAssertTrue(window.makeFirstResponder(behind))

        button.keyDown(with: try key(" ", keyCode: 49, in: window))
        XCTAssertTrue(button.isPopoverShown, "Space opens the popover")
        button.keyDown(with: try key(" ", keyCode: 49, isARepeat: true, in: window))
        NSApp.sendEvent(try key("\u{1b}", keyCode: 53, in: window))
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !button.isPopoverShown }, "Esc closes the popover")
        XCTAssertEqual(behind.keyCodes, [], "the repeat left the popover open, so Esc went to it and not to the view behind")
    }

    func testPopoverHasAFixedWidthAndTheHeightOfItsText() {
        let short = LungfishInfoButton(item: item, about: "threads")
        let long = LungfishInfoButton(
            item: LungfishHelpContent.HelpItem(
                id: "test.info.long",
                summary: "Sets the long thing.",
                detail: Array(repeating: item.detail ?? "", count: 6).joined(separator: " "),
                audience: .analyst
            ),
            about: "the long thing"
        )

        let shortSize = short.popoverController.fittedSize()
        let longSize = long.popoverController.fittedSize()

        XCTAssertEqual(shortSize.width, LungfishInfoButton.popoverWidth)
        XCTAssertEqual(longSize.width, LungfishInfoButton.popoverWidth)
        XCTAssertGreaterThan(shortSize.height, 2 * LungfishInfoPopoverController.inset)
        XCTAssertGreaterThan(longSize.height, shortSize.height, "a longer text makes a taller popover")
    }

    // MARK: The SwiftUI form

    func testSwiftUIFormInAHostedWindowReadsThroughAX() throws {
        let (window, _) = makeHostedDialog()
        let (button, element) = try hostedButton(in: window)

        assertVisibleButton(button, element: element, in: window)

        _ = element.accessibilityPerformPress()
        XCTAssertTrue(button.isPopoverShown, "a VoiceOver press opens the popover")
        XCTAssertEqual(button.popoverController.text, item.detail)
        XCTAssertTrue(button.closePopover())
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !button.isPopoverShown })

        button.keyDown(with: try key(" ", keyCode: 49, in: window))
        XCTAssertTrue(button.isPopoverShown, "Space opens the popover")
    }

    func testSwiftUIEscapeWithThePopoverOpenKeepsTheDialog() throws {
        let (window, counter) = makeHostedDialog()
        let (button, element) = try hostedButton(in: window)

        NSApp.sendEvent(try key("\u{1b}", keyCode: 53, in: window))
        XCTAssertEqual(counter.count, 1, "with no popover, Esc runs the cancel action")

        _ = element.accessibilityPerformPress()
        XCTAssertTrue(button.isPopoverShown)
        NSApp.sendEvent(try key("\u{1b}", keyCode: 53, in: window))
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !button.isPopoverShown }, "Esc closes the popover")
        XCTAssertEqual(counter.count, 1, "Esc with the popover open does not run the cancel action")
    }

    // MARK: Helpers

    private func makeAppKitWindow() -> (NSWindow, LungfishInfoButton, RecordingResponderView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        let behind = RecordingResponderView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        container.addSubview(behind)
        let button = LungfishInfoButton(item: item, about: "threads")
        button.frame = NSRect(x: 220, y: 140, width: 20, height: 20)
        container.addSubview(button)
        let window = makeWindow(content: container)
        addTeardownBlock { @MainActor in
            button.closePopover()
            window.orderOut(nil)
        }
        return (window, button, behind)
    }

    private func makeHostedDialog() -> (NSWindow, CancelCounter) {
        let counter = CancelCounter()
        let host = NSHostingView(rootView: HostedDialog(item: item, onCancel: { counter.count += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        let window = makeWindow(content: host)
        addTeardownBlock { @MainActor in
            if let content = window.contentView {
                self.infoButtons(in: content).forEach { $0.closePopover() }
            }
            window.orderOut(nil)
        }
        return (window, counter)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// The SwiftUI form's button and its accessibility element. With no accessibility client running, SwiftUI publishes
    /// no element tree for its hosting view, so the search walks the views to the wrapped button and then reads the
    /// element that clients reach, the button's cell, which must carry the identifier.
    private func hostedButton(in window: NSWindow) throws -> (LungfishInfoButton, NSAccessibilityProtocol) {
        var button: LungfishInfoButton?
        let found = waitUntilOnRunLoop(budget: .standard) {
            window.contentView?.layoutSubtreeIfNeeded()
            button = window.contentView.flatMap { infoButtons(in: $0).first }
            return button != nil
        }
        XCTAssertTrue(found, "no info button in the hosted window")
        let hosted = try XCTUnwrap(button)
        let element = try XCTUnwrap(hosted.cell as NSAccessibilityProtocol?)
        XCTAssertEqual(element.accessibilityIdentifier(), identifier)
        return (hosted, element)
    }

    private func infoButtons(in view: NSView) -> [LungfishInfoButton] {
        let own = (view as? LungfishInfoButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { infoButtons(in: $0) }
    }

    /// The info button whose accessibility element `element` is, the button itself or its cell.
    private func infoButton(of element: NSAccessibilityProtocol) -> LungfishInfoButton? {
        (element as? LungfishInfoButton) ?? ((element as? NSCell)?.controlView as? LungfishInfoButton)
    }

    private func assertVisibleButton(
        _ button: LungfishInfoButton,
        element: NSAccessibilityProtocol,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, file: file, line: line)
        let frame = button.convert(button.bounds, to: nil)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertTrue(window.contentView?.bounds.contains(frame) ?? false, "\(frame) is outside the window", file: file, line: line)
        XCTAssertEqual(element.accessibilityRole(), .button, file: file, line: line)
        XCTAssertEqual(element.accessibilityLabel(), "About threads", file: file, line: line)
        XCTAssertEqual(element.accessibilityHelp(), item.summary, file: file, line: line)
        XCTAssertEqual(button.toolTip, item.summary, file: file, line: line)
        XCTAssertFalse(button.refusesFirstResponder, file: file, line: line)
    }

    private func axElement(withIdentifier id: String, in root: Any) -> NSAccessibilityProtocol? {
        guard let element = root as? NSAccessibilityProtocol else { return nil }
        if element.accessibilityIdentifier() == id { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let found = axElement(withIdentifier: id, in: child) { return found }
        }
        return nil
    }

    private func key(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }
}
