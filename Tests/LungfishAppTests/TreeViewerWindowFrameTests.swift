// TreeViewerWindowFrameTests.swift - Showing a tree never resizes the window (obs-22)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// obs-22. On the packaged walk of 2026-10-24 the main window grew from 2560x1049 to
/// 2560x1315 when a `.lungfishtree` was selected and to 2560x2163 on a subtree, its bottom
/// edge, with the Nodes table, far below a 1080-point screen. A tree larger than the viewer
/// scrolls inside it and the window keeps the frame the person gave it.
@MainActor
final class TreeViewerWindowFrameTests: XCTestCase {
    /// Full sequence names, as an alignment built from GenBank mitochondrial genomes carries
    /// them into the tree it infers.
    private static let tipNames = [
        "Zebrafish_outgroup": "Danio rerio mitochondrion, complete genome NC_002333.2",
        "Coelacanth": "Latimeria chalumnae mitochondrion, complete genome NC_001804.1",
        "Australian_lungfish": "Neoceratodus forsteri mitochondrion, complete genome NC_002296.1",
        "African_lungfish": "Protopterus dolloi mitochondrion, complete genome NC_001708.1",
        "Human": "Homo sapiens mitochondrion, complete genome NC_012920.1",
        "Frog": "Xenopus laevis mitochondrion, complete genome NC_001573.1",
    ]

    private var tempDir: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeViewerWindowFrameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testSelectingATreeThenASubtreeKeepsTheWindowFrameInsideTheScreen() throws {
        // The screen the test runs on, or the walk's 2560x1049 visible frame when there is none.
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2560, height: 1049)
        let viewer = ViewerViewController()
        let window = NSWindow(
            contentRect: visibleFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        self.window = window
        window.contentViewController = viewer
        window.setFrame(visibleFrame, display: false)
        window.layoutIfNeeded()
        let frameBefore = window.frame
        XCTAssertEqual(frameBefore, visibleFrame, "the window starts filling the screen's visible frame")

        // An IQ-TREE tree records its support labels and maps tips back to the alignment's names.
        let treeURL = tempDir.appendingPathComponent(
            "known-sarcopterygian mitochondrial genomes IQ-TREE.lungfishtree",
            isDirectory: true
        )
        let tree = try PhylogeneticTreeBundleImporter.importTree(
            from: fixtureTree(),
            to: treeURL,
            options: .init(supportLabels: ["UFBoot"], tipLabelMap: Self.tipNames)
        )
        try viewer.displayPhylogeneticTreeBundle(at: treeURL)
        window.layoutIfNeeded()
        assertWindow(window, keeps: frameBefore, inside: visibleFrame, after: "selecting the tree")

        // The subtree is named and written as the app's Extract Subtree names and writes it.
        let lungfishClade = try XCTUnwrap(tree.normalizedTree.nodes.first { node in
            !node.isTip && descendantTipLabels(of: node.id, in: tree).count == 2
                && descendantTipLabels(of: node.id, in: tree).allSatisfy { $0.contains("Neoceratodus") || $0.contains("Protopterus") }
        })
        let stem = TreeBundleTransformCommand.subtreeNameStem(
            tipLabels: descendantTipLabels(of: lungfishClade.id, in: tree),
            fallback: lungfishClade.displayLabel
        )
        let subtreeURL = ViewerViewController.treeOutputURL(projectURL: tempDir, suggestedName: "\(stem).lungfishtree")
        try FileManager.default.createDirectory(
            at: subtreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try tree.extractSubtreeBundle(
            nodeID: lungfishClade.id,
            to: subtreeURL,
            provenance: .init(toolName: "lungfish tree extract-subtree", argv: [])
        )
        try viewer.displayPhylogeneticTreeBundle(at: subtreeURL)
        window.layoutIfNeeded()
        assertWindow(window, keeps: frameBefore, inside: visibleFrame, after: "selecting the subtree")
    }

    private func assertWindow(
        _ window: NSWindow,
        keeps frameBefore: NSRect,
        inside visibleFrame: NSRect,
        after step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = window.frame
        let detail = "after \(step) the window frame is \(frame), it was \(frameBefore) on a visible frame of \(visibleFrame)"
        XCTAssertEqual(frame.height, frameBefore.height, accuracy: 0.5, "height changed, \(detail)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX - 0.5, "left edge off screen, \(detail)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX + 0.5, "right edge off screen, \(detail)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY - 0.5, "bottom edge off screen, \(detail)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY + 0.5, "top edge off screen, \(detail)", file: file, line: line)
    }

    private func descendantTipLabels(of ancestorID: String, in tree: PhylogeneticTreeBundle) -> [String] {
        let nodes = tree.normalizedTree.nodes
        let parentByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
        return nodes.filter { node in
            guard node.isTip else { return false }
            var parentID = node.parentID
            while let current = parentID {
                if current == ancestorID { return true }
                parentID = parentByID[current] ?? nil
            }
            return false
        }.map(\.displayLabel)
    }

    private func fixtureTree() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phylogenetics/known-sarcopterygian/expected.nwk")
    }
}
