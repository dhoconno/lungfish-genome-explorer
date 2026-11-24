// ViewSwitchViewStateDrivers+Alignment.swift - The alignment's and the tree's drivers for the view state cases (VS-ALN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The alignment fixture is the committed SARS-CoV-2 MAFFT alignment and the tree fixture the committed sarcopterygian
// Newick tree (RoutingSafetyNetFixtures). A changed bundle is another import at the same path: its manifest gets a new
// identifier, so the data key differs while the folder stays the one the view was kept for.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishKit
@testable import LungfishPhylogeneticsUI

/// What both drivers share.
enum ViewStateAlignmentFixtures {
    /// Gives the bundle's manifest a new identifier, as a new import at the same path does.
    static func giveNewIdentifier(toManifestIn bundle: URL) throws {
        let url = bundle.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        manifest["identifier"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}

/// The change zooms in, picks the conservation colours, types a find text, shows the Annotations tab and selects a
/// block of rows 1 and 2 by columns 10 to 20.
@MainActor
struct AlignmentViewStateDriver: ViewStateDriver {
    let kind = "MSA"

    func viewer(in harness: ViewSwitchWindowHarness) -> MultipleSequenceAlignmentViewController? {
        harness.split.viewerController.multipleSequenceAlignmentViewController
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        viewer(in: harness) != nil
    }

    func change(in harness: ViewSwitchWindowHarness) throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        viewer.testingSelectBlock(rowRange: 1...2, displayedColumnRange: 10...20)
        viewer.testingPerformZoomIn()
        viewer.testingSetColorScheme(.conservation)
        viewer.testingSetSearchText("MN908947")
        viewer.bottomPane.select(.annotations)
    }

    /// The zoom, the colour scheme, the find field, the bottom pane, the selected rows and the selected columns.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let width = String(format: "%.3f", Double(viewer.testingAlignmentColumnWidth))
        let columns = viewer.testingSelectedAlignmentColumnRange.map { "\($0.lowerBound)-\($0.upperBound)" }
        return [
            "zoom \(viewer.fitsViewport ? "fit" : width)",
            "colour \(viewer.testingColorSchemeName)",
            "find \(viewer.searchField.stringValue)",
            "pane \(viewer.isBottomPaneOpen ? "open" : "closed") \(viewer.bottomPane.selectedTab.title)",
            "rows \(viewer.testingSelectedRowIndices.map(String.init).joined(separator: ", "))",
            "columns \(columns ?? "whole rows")",
        ]
    }

    func changeBundle(of fixture: ViewSwitchFixture) throws {
        try ViewStateAlignmentFixtures.giveNewIdentifier(toManifestIn: try XCTUnwrap(fixture.item.url))
    }

    /// A block is a coordinate selection, so a changed key drops it, never clamped, and the open's own first cell
    /// shows. The zoom, the colours, the find text and the pane come back (VS B3).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[4] = "rows 0"
        reading[5] = "columns 0-0"
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.selection) }
}

/// The change draws a cladogram coloured by branch length, collapses a clade and selects a tip inside it (lesson 11),
/// zooms in, pans, widens the node column and types a find text.
@MainActor
struct TreeViewStateDriver: ViewStateDriver {
    let kind = "Tree"

    func viewer(in harness: ViewSwitchWindowHarness) -> PhylogeneticTreeViewController? {
        harness.split.viewerController.phylogeneticTreeViewController
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        viewer(in: harness) != nil
    }

    func change(in harness: ViewSwitchWindowHarness) throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        Self.openingSelectionReading = try read(in: harness)[5]
        viewer.layoutModeControl.selectedSegment = 1
        _ = viewer.layoutModeControl.sendAction(viewer.layoutModeControl.action, to: viewer.layoutModeControl.target)
        viewer.colorModeControl.selectedSegment = 2
        _ = viewer.colorModeControl.sendAction(viewer.colorModeControl.action, to: viewer.colorModeControl.target)
        let clade = try XCTUnwrap(viewer.nodes.first { node in
            !node.isTip && node.parentID != nil && node.childIDs.contains { viewer.nodesByID[$0]?.isTip == true }
        })
        viewer.selectNode(id: clade.id, center: false)
        viewer.toggleSelectedCladeCollapse(nil)
        let tip = try XCTUnwrap(clade.childIDs.first { viewer.nodesByID[$0]?.isTip == true })
        viewer.selectNode(id: tip, center: false)
        viewer.treeCanvasView.zoom(by: 1.25)
        viewer.testingSetCanvasScrollOrigin(NSPoint(x: 40, y: 30))
        viewer.testingSetNodeColumnWidth(identifier: "node", width: 233)
        viewer.testingSetSearchText("Latimeria")
    }

    /// The layout, the colour mode, the zoom, the pan, the collapsed clades, the selected node, the find field and the
    /// node column's width.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let origin = viewer.testingCanvasScrollOrigin
        let collapsed = viewer.collapsedNodeIDs.compactMap { viewer.nodesByID[$0]?.displayLabel }.sorted()
        let selected = viewer.selectedNodeIDs.compactMap { viewer.nodesByID[$0]?.displayLabel }.sorted()
        return [
            "layout \(viewer.layoutModeControl.selectedSegment)",
            "colour \(viewer.colorModeControl.selectedSegment)",
            "zoom \(String(format: "%.4f", Double(viewer.treeCanvasView.zoomScale)))",
            "pan \(Int(origin.x.rounded())) \(Int(origin.y.rounded()))",
            "collapsed \(collapsed.joined(separator: ", "))",
            "selected \(viewer.selectedNodeID.flatMap { viewer.nodesByID[$0]?.displayLabel } ?? "none") \(selected)",
            "find \(viewer.testingSearchField.stringValue)",
            "node width \(Int((viewer.testingNodeColumnWidths["node"] ?? 0).rounded()))",
        ]
    }

    func changeBundle(of fixture: ViewSwitchFixture) throws {
        try ViewStateAlignmentFixtures.giveNewIdentifier(toManifestIn: try XCTUnwrap(fixture.item.url))
    }

    /// The node and the pan come back only on an equal tree key (VS B4), so the open's first tip shows selected at the
    /// tree's top left. The look, the zoom, the collapsed clade and the find text come back.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[3] = "pan 0 0"
        reading[5] = TreeViewStateDriver.openingSelectionReading
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged([.place, .selection]) }

    /// The reading of the open's own selection, the first tip, as `change(in:)` found it before its change.
    static var openingSelectionReading = ""
}
