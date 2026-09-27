// TaxonomySunburstZoomToFitTests.swift - ⌘0 in the sunburst is View > Zoom to Fit, dispatched through the responder chain
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class TaxonomySunburstZoomToFitTests: XCTestCase {
    private func tree() -> TaxonTree {
        func node(_ id: Int, _ name: String, _ clade: Int, _ direct: Int) -> TaxonNode {
            TaxonNode(
                taxId: id,
                name: name,
                rank: id == 1 ? .root : .phylum,
                depth: id == 1 ? 0 : 1,
                readsDirect: direct,
                readsClade: clade,
                fractionClade: Double(clade) / 1000,
                fractionDirect: Double(direct) / 1000,
                parentTaxId: id == 1 ? nil : 1
            )
        }
        let root = node(1, "Root", 100, 10)
        root.children = [node(2, "Alpha", 70, 70), node(3, "Beta", 20, 20)]
        for child in root.children {
            child.parent = root
        }
        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1000)
    }

    /// The View > Zoom to Fit item (⌘0) is nil-target. With the sunburst as
    /// first responder the action reaches the view ahead of the window
    /// controller's sequence-viewer handler and returns to the full chart.
    /// (A `keyDown` case for ⌘0, the previous implementation, is never
    /// reached because menu key equivalents are resolved first.)
    func testZoomToFitMenuActionReachesTheFocusedSunburstAndReturnsToTheRoot() throws {
        let taxonomy = tree()
        let view = TaxonomySunburstView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.tree = taxonomy
        view.centerNode = taxonomy.root.children[0]
        XCTAssertNotNil(view.centerNode)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(view))

        var zoomChanges: [Int?] = []
        view.onZoomChanged = { zoomChanges.append($0?.taxId) }

        let handled = window.firstResponder?.tryToPerform(#selector(ViewMenuActions.zoomToFit(_:)), with: nil) ?? false
        XCTAssertTrue(handled)
        XCTAssertNil(view.centerNode)
        XCTAssertEqual(zoomChanges, [nil])

        // Already at the root: nothing to do, and no spurious change.
        view.zoomToFit(nil)
        XCTAssertEqual(zoomChanges, [nil])
    }
}
