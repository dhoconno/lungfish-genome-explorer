// ViewportHostLineOnKraken2Tests.swift - The host's line on a real default surface, in a window with a toolbar (VS-HOST-LINE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishKit
@testable import LungfishTaxonomyUI

/// A toolbar with one item, so that the window's content layout starts below a toolbar as in the main window.
@MainActor
private final class OneItemToolbar: NSObject, NSToolbarDelegate {
    static let item = NSToolbarItem.Identifier("view-memory-kraken2-line-item")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Item"
        item.view = NSButton(title: "Item", target: nil, action: nil)
        return item
    }
}

/// Kraken2 keeps the default `pinsTopToSafeArea == false` and pads its own first row, the summary bar, with its own
/// safe-area constraint (`TaxonomyViewController.swift:854`). A Kit test cannot make it, since LungfishKit does not
/// depend on LungfishTaxonomyUI, so these cases run in the App test target. They draw the host's line through
/// `showResetLine`, the one call every line of the host goes through, since only the layout is in question here.
@MainActor
final class ViewportHostLineOnKraken2Tests: XCTestCase {
    private var window: NSWindow!
    private var toolbarDelegate: OneItemToolbar!

    override func tearDown() async throws {
        window?.close()
        window = nil
        toolbarDelegate = nil
    }

    private func firstSubview<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        for subview in view.subviews {
            if let match = subview as? View { return match }
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// A viewer showing Kraken2 in a window with `.fullSizeContentView` and a one-item toolbar, as the main window.
    private func showKraken2() throws -> (viewer: ViewerViewController, surface: NSView, summaryBar: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let delegate = OneItemToolbar()
        let toolbar = NSToolbar(identifier: "view-memory-kraken2-line-toolbar")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        self.window = window
        toolbarDelegate = delegate
        let viewer = ViewerViewController()
        window.contentView = viewer.view
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)
        let installed = try XCTUnwrap(viewer.installedSurface)
        XCTAssertFalse(installed.pinsTopToSafeArea, "Kraken2 keeps the default")
        layOut(viewer)
        XCTAssertGreaterThan(viewer.view.safeAreaInsets.top, 0, "the viewer runs under the title bar and toolbar")
        let surface = installed.viewController.view
        let summaryBar = try XCTUnwrap(firstSubview(of: TaxonomySummaryBar.self, in: surface))
        return (viewer, surface, summaryBar)
    }

    private func layOut(_ viewer: ViewerViewController) {
        window.layoutIfNeeded()
        viewer.view.layoutSubtreeIfNeeded()
    }

    private func inWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    func testTheLineShowsBelowTheToolbarAndKraken2sSummaryBarStartsAtItsBottom() throws {
        let (viewer, surfaceView, summaryBar) = try showKraken2()
        let visible = window.contentLayoutRect
        XCTAssertEqual(inWindow(summaryBar).maxY, visible.maxY, accuracy: 0.5,
                       "with no line, Kraken2 pads its own band and its summary bar starts below the toolbar")

        viewer.surfaceHost.showResetLine(ViewMemoryWords.viewReset)
        layOut(viewer)

        let line = try XCTUnwrap(viewer.surfaceHost.resetLine)
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor)
        let lineInWindow = inWindow(line)
        XCTAssertFalse(lineInWindow.isEmpty)
        XCTAssertLessThanOrEqual(lineInWindow.maxY, visible.maxY + 0.5,
                                 "the line starts below the toolbar, found \(lineInWindow.maxY) pt against \(visible.maxY) pt")
        XCTAssertGreaterThanOrEqual(lineInWindow.minY, visible.minY - 0.5)
        XCTAssertEqual(inWindow(surfaceView).maxY, lineInWindow.minY, accuracy: 0.5,
                       "the surface's top follows the line's bottom")
        XCTAssertEqual(inWindow(summaryBar).maxY, lineInWindow.minY, accuracy: 0.5,
                       "Kraken2's summary bar starts at the line's bottom, with no band of a toolbar's height above it")

        viewer.surfaceHost.removeResetLine()
        layOut(viewer)
        XCTAssertNil(line.superview, "the line is gone from the view tree")
        XCTAssertEqual(inWindow(surfaceView).maxY, inWindow(viewer.view).maxY, accuracy: 0.5,
                       "Kraken2 is back on its own pin at the container's edge")
        XCTAssertEqual(inWindow(summaryBar).maxY, visible.maxY, accuracy: 0.5, "and pads its own band again")
    }

    /// A line and an affected-results strip on one result (UX-F1-R17 item 5). The install draws the line and the viewer
    /// places the strip after it, as `ViewportHost.commit` calls `activeViewportDidChange` after `showResetLine`. Both
    /// show below the toolbar, neither covers the other, and Kraken2 starts below both. The frames go to the log.
    func testALineAndAnAffectedResultsStripStackBelowTheToolbar() throws {
        let (viewer, surfaceView, summaryBar) = try showKraken2()
        let visible = window.contentLayoutRect
        let rows = AffectedResults.rows(forAppVersion: "Lungfish 2026.10.28 (11807)", kind: .esViritu)
        XCTAssertGreaterThan(rows.count, 0)

        viewer.surfaceHost.showResetLine(ViewMemoryWords.viewReset)
        viewer.showAffectedResultsStrip(rows: rows)
        layOut(viewer)

        let line = inWindow(try XCTUnwrap(viewer.surfaceHost.resetLine))
        let strip = inWindow(try XCTUnwrap(AffectedResultsStrip.strip(in: viewer.view)))
        print("VS-HOST-LINE frames: line \(line) strip \(strip) content layout \(visible) surface \(inWindow(surfaceView))")
        for (name, frame) in [("line", line), ("strip", strip)] {
            XCTAssertFalse(frame.isEmpty, "the \(name) has a frame")
            XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 0.5,
                                     "the \(name) starts below the toolbar, found \(frame.maxY) pt against \(visible.maxY) pt")
        }
        XCTAssertLessThanOrEqual(line.intersection(strip).height, 0.5,
                                 "the line \(line) and the strip \(strip) do not cover each other")
        XCTAssertLessThanOrEqual(inWindow(surfaceView).maxY, min(line.minY, strip.minY) + 0.5,
                                 "Kraken2 starts below the line and the strip")
        XCTAssertLessThanOrEqual(inWindow(summaryBar).maxY, min(line.minY, strip.minY) + 0.5)

        // The strip goes while the line stays, as when the Inspector's notice for this item comes with no rows.
        viewer.showAffectedResultsStrip(rows: [])
        layOut(viewer)
        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view))
        let kept = inWindow(try XCTUnwrap(viewer.surfaceHost.resetLine))
        XCTAssertEqual(kept.maxY, visible.maxY, accuracy: 0.5, "the line keeps the safe-area top")
        XCTAssertEqual(inWindow(surfaceView).maxY, kept.minY, accuracy: 0.5, "Kraken2 starts at the line's bottom again")
    }
}
