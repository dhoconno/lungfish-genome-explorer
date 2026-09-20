import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class HoverTooltipViewTests: XCTestCase {
    private var retainedWindows: [NSWindow] = []

    override func tearDown() async throws {
        retainedWindows.forEach { $0.close() }
        retainedWindows.removeAll()
        try await super.tearDown()
    }

    func testPinPreservesVisibleSnapshotAcrossLaterShowAndPointerHide() throws {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Variant A\nDepth: 2685", near: NSPoint(x: 120, y: 120), in: parent)
        tooltip.testFirePendingShow()

        tooltip.pin()
        tooltip.show(text: "Variant B", near: NSPoint(x: 220, y: 220), in: parent)
        tooltip.requestHide()

        XCTAssertTrue(tooltip.isPinned)
        XCTAssertFalse(tooltip.isHidden)
        XCTAssertEqual(tooltip.currentText, "Variant A\nDepth: 2685")
        XCTAssertEqual(tooltip.testStatusText, "Pinned details")
        XCTAssertNotNil(try XCTUnwrap(parent.window).childWindows?.first)
    }

    func testDismissClearsTextPinStateAndChildPanel() throws {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Annotation\nGene: N", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        tooltip.pin()

        tooltip.dismiss()

        XCTAssertTrue(tooltip.isHidden)
        XCTAssertFalse(tooltip.isPinned)
        XCTAssertEqual(tooltip.currentText, "")
        XCTAssertTrue(try XCTUnwrap(parent.window).childWindows?.isEmpty ?? true)
    }

    func testRequestHideDismissesTransientCardAfterGraceCallback() {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Transient", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()

        tooltip.requestHide()
        XCTAssertFalse(tooltip.isHidden)
        tooltip.testFirePendingHide()

        XCTAssertTrue(tooltip.isHidden)
        XCTAssertEqual(tooltip.currentText, "")
    }

    func testStaleShowCallbackCannotReplaceNewerTarget() {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Old", near: NSPoint(x: 60, y: 60), in: parent)
        let staleGeneration = tooltip.testGeneration
        tooltip.show(text: "New", near: NSPoint(x: 80, y: 80), in: parent)

        tooltip.testCompleteShow(generation: staleGeneration, targetText: "Old")

        XCTAssertEqual(tooltip.currentText, "New")
        XCTAssertTrue(tooltip.isHidden)
        tooltip.testFirePendingShow()
        XCTAssertFalse(tooltip.isHidden)
        XCTAssertEqual(tooltip.currentText, "New")
    }

    func testPendingHideCannotDismissNewerTarget() {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Old", near: NSPoint(x: 60, y: 60), in: parent)
        tooltip.testFirePendingShow()
        tooltip.requestHide()

        tooltip.show(text: "New", near: NSPoint(x: 80, y: 80), in: parent)
        tooltip.testFirePendingHide()

        XCTAssertFalse(tooltip.isHidden)
        XCTAssertEqual(tooltip.currentText, "New")
    }

    func testAttributedDisplayAndCopyPreserveExactPlainText() {
        let (tooltip, parent) = makeTooltip()
        let text = """
        NC_045512:29409  C → T
        Allele: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        Sample: ivar.tsv-prefix
          Note: alpha:beta\ncontinued
        """
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        tooltip.show(text: text, near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        tooltip.copy(to: pasteboard)

        XCTAssertEqual(tooltip.testAttributedText.string, text)
        XCTAssertEqual(tooltip.testTextView.string, text)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertGreaterThan(tooltip.testTextDocumentHeight, 0)
    }

    func testLongIvarContentGrowsDocumentWhilePanelRemainsBounded() throws {
        let (tooltip, parent) = makeTooltip(size: NSSize(width: 420, height: 260))
        let lastField = "Last field: retained"
        let samples = (0..<24).flatMap { sample in
            [
                "Sample: ivar-sample-\(sample)",
                "  Depth (FORMAT/DP): 2685",
                "  Allele frequency (FORMAT/ALT_FREQ): 0.999628",
                "  Consequence: missense_variant_\(String(repeating: "long", count: 20))",
            ]
        }
        let text = (["NC_045512:29409  C → T", "Track: minimap2 Mapping • iVar"] + samples + [lastField])
            .joined(separator: "\n")

        tooltip.show(text: text, near: NSPoint(x: 200, y: 120), in: parent)
        tooltip.testFirePendingShow()

        let panel = try XCTUnwrap(try XCTUnwrap(parent.window).childWindows?.first)
        XCTAssertLessThanOrEqual(panel.frame.height, 260)
        XCTAssertGreaterThan(tooltip.testTextDocumentHeight, panel.frame.height)
        XCTAssertTrue(tooltip.testTextView.string.hasSuffix(lastField))
        XCTAssertTrue(tooltip.testScrollView.hasVerticalScroller)
    }

    func testNarrowPanelKeepsAllHeaderControlsInsideAndContentHitTestable() throws {
        let (tooltip, parent) = makeTooltip(size: NSSize(width: 120, height: 240))
        tooltip.show(text: "Short details\nDepth: 4", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()

        let panel = tooltip.testPanelWindow
        let identifiers = panel.contentView?.subviewsRecursively.compactMap { $0.accessibilityIdentifier() } ?? []
        XCTAssertTrue(identifiers.contains("hover-details-pin"))
        XCTAssertTrue(identifiers.contains("hover-details-copy"))
        XCTAssertTrue(identifiers.contains("hover-details-close"))
        XCTAssertTrue(identifiers.contains("hover-details-text"))
        XCTAssertNotNil(panel.contentView?.hitTest(NSPoint(x: panel.frame.width / 2, y: 20)))

        for identifier in ["hover-details-pin", "hover-details-copy", "hover-details-close"] {
            let control = try XCTUnwrap(panel.contentView?.subviewsRecursively.first {
                $0.accessibilityIdentifier() == identifier
            })
            XCTAssertTrue(panel.contentView?.bounds.contains(control.convert(control.bounds, to: panel.contentView)) == true)
        }
    }

    func testMouseDownOnTextPinsBeforeNativeDispatch() throws {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Variant\nDepth: 9", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        let panel = tooltip.testPanelWindow
        let location = tooltip.testTextView.convert(NSPoint(x: 6, y: 6), to: panel.contentView)
        XCTAssertNotNil(panel.contentView?.hitTest(location))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0.01,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.postEvent(mouseUp, atStart: false)

        panel.sendEvent(event)

        XCTAssertTrue(tooltip.isPinned)
        XCTAssertEqual(tooltip.currentText, "Variant\nDepth: 9")
    }

    func testApplicationDeactivationRemovesChildPanel() throws {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Pinned details", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        tooltip.pin()

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertTrue(tooltip.isHidden)
        XCTAssertFalse(tooltip.isPinned)
        XCTAssertTrue(try XCTUnwrap(parent.window).childWindows?.isEmpty ?? true)
    }

    func testCloseSuppressesSameSourceUntilPointerLeaves() {
        let (tooltip, parent) = makeTooltip()
        tooltip.show(text: "Same target", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        tooltip.dismiss()

        tooltip.show(text: "Same target", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        XCTAssertTrue(tooltip.isHidden)

        tooltip.requestHide()
        tooltip.show(text: "Same target", near: NSPoint(x: 100, y: 100), in: parent)
        tooltip.testFirePendingShow()
        XCTAssertFalse(tooltip.isHidden)
    }

    private func makeTooltip(size: NSSize = NSSize(width: 800, height: 600)) -> (HoverTooltipView, NSView) {
        let parent = NSView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: parent.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = parent
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        window.orderFront(nil)
        retainedWindows.append(window)
        return (HoverTooltipView(frame: .zero, schedulesAutomatically: false), parent)
    }
}

private extension NSView {
    var subviewsRecursively: [NSView] {
        subviews + subviews.flatMap(\.subviewsRecursively)
    }
}
