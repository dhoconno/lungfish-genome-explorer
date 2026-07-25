// LungfishPhylogeneticsUISmokeTests.swift - leaf module presence smoke test
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import LungfishCore
import LungfishKit
import LungfishWorkflow
@testable import LungfishIO
@testable import LungfishPhylogeneticsUI

@MainActor
final class LungfishPhylogeneticsUISmokeTests: XCTestCase {
    func testTreeViewControllerLoadsViewStandalone() {
        let controller = PhylogeneticTreeViewController()
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "phylogenetic-tree-bundle-view")
    }

    func testPrimaryContentTypographyUsesResolvedMetricsWithoutMutatingTreeState() throws {
        try preservingPhylogeneticContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .system
            settings.save()
            let provider = MutablePhylogeneticFontProvider(pointSize: 13)
            let controller = PhylogeneticTreeViewController()
            controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
            controller.testingSetContentPreferredFontProvider(provider)
            let bundleURL = try makePhylogeneticTreeBundle()
            defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
            try controller.displayBundle(at: bundleURL)
            controller.testingSetNodeColumnWidth(identifier: "node", width: 213)
            controller.testingSetSearchText("B")
            controller.testingSelectNode(label: "90")
            controller.testingPerformSelectedNodeOperation(.collapse)
            controller.testingSelectNode(label: "A")
            controller.testingSelectNode(label: "B", extendingSelection: true)
            controller.testingPerformZoomIn()
            controller.testingSetTreeLayoutMode(.cladogram)
            controller.testingSetTreeColorMode(.support)
            controller.testingSetCanvasScrollOrigin(NSPoint(x: 34, y: 18))

            try withSafePhylogeneticHostWindow(
                content: controller.view,
                size: controller.view.frame.size
            ) { window in
                controller.view.layoutSubtreeIfNeeded()
                controller.testingSetNodeTableScrollOrigin(NSPoint(x: 0, y: 18))
                XCTAssertTrue(window.makeFirstResponder(controller.testingSearchField))
                let responder = try XCTUnwrap(window.firstResponder)
                let baseline = controller.testingPrimaryContentMetrics
                let scientificCounts = controller.testingScientificMutationCounts
                let baselineScroll = controller.testingCanvasScrollOrigin
                let baselineNodeTableScroll = controller.testingNodeTableScrollOrigin

                provider.pointSize = 24
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()

                let enlarged = controller.testingPrimaryContentMetrics
                XCTAssertEqual(enlarged.summaryFontPointSize, 24, accuracy: 0.01)
                XCTAssertEqual(enlarged.detailFontPointSize, 24, accuracy: 0.01)
                XCTAssertEqual(enlarged.searchFontPointSize, baseline.searchFontPointSize, accuracy: 0.01)
                XCTAssertEqual(enlarged.nodeCellFontPointSize, 24, accuracy: 0.01)
                XCTAssertGreaterThan(enlarged.rowHeight, baseline.rowHeight)
                XCTAssertGreaterThan(enlarged.headerHeight, baseline.headerHeight)
                XCTAssertGreaterThanOrEqual(enlarged.toolbarHeight, baseline.toolbarHeight)
                XCTAssertGreaterThan(enlarged.nodeDrawerHeight, baseline.nodeDrawerHeight)
                XCTAssertEqual(
                    enlarged.typographyApplicationCount,
                    baseline.typographyApplicationCount + 1
                )
                XCTAssertGreaterThan(controller.testingNodeColumnWidths["node"] ?? 0, 213)
                XCTAssertEqual(controller.testingSelectedNodeLabel, "B")
                XCTAssertEqual(controller.testingSelectedTipLabels, ["A", "B"])
                XCTAssertEqual(controller.testingSelectedNodeRow, controller.testingNodeTableSelectedRow)
                XCTAssertTrue(controller.testingCollapsedNodeLabels.contains("90"))
                XCTAssertEqual(controller.testingCanvasLayoutMode, "cladogram")
                XCTAssertEqual(controller.testingCanvasColorMode, "support")
                XCTAssertEqual(controller.testingScientificMutationCounts, scientificCounts)
                XCTAssertEqual(controller.testingCanvasScrollOrigin.x, baselineScroll.x, accuracy: 0.01)
                XCTAssertEqual(controller.testingCanvasScrollOrigin.y, baselineScroll.y, accuracy: 0.01)
                XCTAssertEqual(
                    controller.testingNodeTableScrollOrigin.y,
                    baselineNodeTableScroll.y,
                    accuracy: 0.01
                )
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(responder))
                XCTAssertEqual(controller.testingNodeTableAccessibilityLabel, "Phylogenetic tree nodes")
                XCTAssertEqual(
                    controller.testingNodeCellAccessibilityValue(column: "node", row: controller.testingSelectedNodeRow),
                    "B"
                )
                XCTAssertFalse(
                    try XCTUnwrap(controller.testingTreeLayoutFrames["treeScrollView"])
                        .intersects(try XCTUnwrap(controller.testingTreeLayoutFrames["detailLabel"]))
                )
                XCTAssertFalse(controller.testingHasAmbiguousPrimaryLayout)

                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()
                let repeated = controller.testingPrimaryContentMetrics
                XCTAssertEqual(repeated.summaryFontPointSize, enlarged.summaryFontPointSize)
                XCTAssertEqual(repeated.detailFontPointSize, enlarged.detailFontPointSize)
                XCTAssertEqual(repeated.nodeCellFontPointSize, enlarged.nodeCellFontPointSize)
                XCTAssertEqual(repeated.rowHeight, enlarged.rowHeight)
                XCTAssertEqual(repeated.headerHeight, enlarged.headerHeight)
                XCTAssertEqual(repeated.toolbarHeight, enlarged.toolbarHeight)
                XCTAssertEqual(repeated.nodeDrawerHeight, enlarged.nodeDrawerHeight)
                XCTAssertEqual(
                    repeated.typographyApplicationCount,
                    enlarged.typographyApplicationCount + 1
                )
                XCTAssertEqual(controller.testingScientificMutationCounts, scientificCounts)

                provider.pointSize = 13
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()

                let recovered = controller.testingPrimaryContentMetrics
                XCTAssertEqual(recovered.summaryFontPointSize, baseline.summaryFontPointSize, accuracy: 0.01)
                XCTAssertEqual(recovered.detailFontPointSize, baseline.detailFontPointSize, accuracy: 0.01)
                XCTAssertEqual(recovered.rowHeight, baseline.rowHeight, accuracy: 0.01)
                XCTAssertEqual(recovered.headerHeight, baseline.headerHeight, accuracy: 0.01)
                XCTAssertEqual(controller.testingNodeColumnWidths["node"] ?? 0, 213, accuracy: 0.01)
                XCTAssertEqual(controller.testingScientificMutationCounts, scientificCounts)
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(responder))

                settings.contentTextSizePreference = .custom(100)
                settings.save()
                controller.view.layoutSubtreeIfNeeded()
                let customBaseline = controller.testingPrimaryContentMetrics
                XCTAssertEqual(customBaseline.summaryFontPointSize, 13, accuracy: 0.01)
                XCTAssertEqual(customBaseline.detailFontPointSize, 13, accuracy: 0.01)
                XCTAssertEqual(customBaseline.nodeCellFontPointSize, 13, accuracy: 0.01)

                settings.contentTextSizePreference = .custom(200)
                settings.save()
                controller.view.layoutSubtreeIfNeeded()
                let customEnlarged = controller.testingPrimaryContentMetrics
                XCTAssertEqual(customEnlarged.summaryFontPointSize, 26, accuracy: 0.01)
                XCTAssertEqual(customEnlarged.detailFontPointSize, 26, accuracy: 0.01)
                XCTAssertEqual(customEnlarged.nodeCellFontPointSize, 26, accuracy: 0.01)
                XCTAssertGreaterThan(customEnlarged.rowHeight, customBaseline.rowHeight)
                XCTAssertGreaterThan(customEnlarged.headerHeight, customBaseline.headerHeight)
                XCTAssertGreaterThan(customEnlarged.toolbarHeight, customBaseline.toolbarHeight)
                XCTAssertGreaterThan(customEnlarged.nodeDrawerHeight, customBaseline.nodeDrawerHeight)
                XCTAssertFalse(
                    try XCTUnwrap(controller.testingTreeLayoutFrames["treeScrollView"])
                        .intersects(try XCTUnwrap(controller.testingTreeLayoutFrames["detailLabel"]))
                )
                XCTAssertEqual(controller.testingScientificMutationCounts, scientificCounts)

                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()
                let customRepeated = controller.testingPrimaryContentMetrics
                XCTAssertEqual(customRepeated.summaryFontPointSize, customEnlarged.summaryFontPointSize)
                XCTAssertEqual(customRepeated.detailFontPointSize, customEnlarged.detailFontPointSize)
                XCTAssertEqual(customRepeated.nodeCellFontPointSize, customEnlarged.nodeCellFontPointSize)
                XCTAssertEqual(customRepeated.rowHeight, customEnlarged.rowHeight)
                XCTAssertEqual(customRepeated.headerHeight, customEnlarged.headerHeight)
                XCTAssertEqual(customRepeated.toolbarHeight, customEnlarged.toolbarHeight)
                XCTAssertEqual(customRepeated.nodeDrawerHeight, customEnlarged.nodeDrawerHeight)
                XCTAssertEqual(
                    customRepeated.typographyApplicationCount,
                    customEnlarged.typographyApplicationCount + 1
                )

                settings.contentTextSizePreference = .custom(100)
                settings.save()
                controller.view.layoutSubtreeIfNeeded()
                let customRecovered = controller.testingPrimaryContentMetrics
                XCTAssertEqual(customRecovered.summaryFontPointSize, customBaseline.summaryFontPointSize)
                XCTAssertEqual(customRecovered.detailFontPointSize, customBaseline.detailFontPointSize)
                XCTAssertEqual(customRecovered.nodeCellFontPointSize, customBaseline.nodeCellFontPointSize)
                XCTAssertEqual(customRecovered.rowHeight, customBaseline.rowHeight)
                XCTAssertEqual(customRecovered.headerHeight, customBaseline.headerHeight)
                XCTAssertEqual(customRecovered.toolbarHeight, customBaseline.toolbarHeight)
                XCTAssertEqual(customRecovered.nodeDrawerHeight, customBaseline.nodeDrawerHeight)
                XCTAssertEqual(controller.testingNodeColumnWidths["node"] ?? 0, 213, accuracy: 0.01)
                XCTAssertFalse(
                    try XCTUnwrap(controller.testingTreeLayoutFrames["treeScrollView"])
                        .intersects(try XCTUnwrap(controller.testingTreeLayoutFrames["detailLabel"]))
                )
                XCTAssertEqual(controller.testingScientificMutationCounts, scientificCounts)
            }
        }
    }

    func testTreeTypographyObserverTearsDownWithController() {
        weak var released: PhylogeneticTreeViewController?
        autoreleasepool {
            let controller = PhylogeneticTreeViewController()
            _ = controller.view
            released = controller
        }
        XCTAssertNil(released)
    }

    func testSelectionStateEquatable() {
        let lhs = PhylogeneticTreeSelectionState(title: "A", subtitle: "tip", detailRows: [("Type", "Tip")])
        let rhs = PhylogeneticTreeSelectionState(title: "A", subtitle: "tip", detailRows: [("Type", "Tip")])
        XCTAssertEqual(lhs, rhs)
    }

    func testSubtreeExportWritesScientificProvenanceSidecar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishPhylogeneticsUISmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundleURL = tempDir.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        let outputURL = tempDir.appendingPathComponent("subtree.nwk")
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try "(A:1,B:1);\n".write(
            to: sourceBundleURL.appendingPathComponent("tree.nwk"),
            atomically: true,
            encoding: .utf8
        )
        let export = PhylogeneticTreeSubtreeExport(
            selectedNodeID: "node-1",
            selectedLabel: "Reviewed Clade",
            newick: "(A:1,B:1);",
            descendantTipCount: 2
        )

        let sidecarURL = try PhylogeneticTreeViewController.writeSubtreeExport(
            export,
            sourceBundleURL: sourceBundleURL,
            to: outputURL,
            startedAt: Date()
        )

        XCTAssertEqual(sidecarURL, ProvenanceRecorder.fileSidecarURL(for: outputURL))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), export.newick)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app phylogenetic subtree export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.format, .text)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.explicit["selectedNodeID"]?.stringValue, "node-1")
        XCTAssertEqual(envelope.options.explicit["selectedLabel"]?.stringValue, "Reviewed Clade")
        XCTAssertEqual(envelope.options.defaults["outputFormat"]?.stringValue, "newick")
        XCTAssertEqual(envelope.options.resolvedDefaults["descendantTipCount"]?.integerValue, 2)
        XCTAssertTrue(envelope.argv.contains("--node"))
        let hasSourceInput = envelope.files.contains { descriptor in
            descriptor.path == sourceBundleURL.path && descriptor.role == FileRole.input
        }
        XCTAssertTrue(hasSourceInput)
    }

    func testSubtreeExportRemovesPayloadWhenProvenanceSidecarFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishPhylogeneticsUISmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("blocked-subtree.nwk")
        try FileManager.default.createDirectory(
            at: ProvenanceRecorder.fileSidecarURL(for: outputURL),
            withIntermediateDirectories: true
        )
        let export = PhylogeneticTreeSubtreeExport(
            selectedNodeID: "node-1",
            selectedLabel: "Reviewed Clade",
            newick: "(A:1,B:1);",
            descendantTipCount: 2
        )

        XCTAssertThrowsError(
            try PhylogeneticTreeViewController.writeSubtreeExport(
                export,
                sourceBundleURL: nil,
                to: outputURL,
                startedAt: Date()
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }
}

@MainActor
private func preservingPhylogeneticContentTextSizePreference(
    _ body: () throws -> Void
) rethrows {
    let settings = AppSettings.shared
    let original = settings.contentTextSizePreference
    defer {
        settings.contentTextSizePreference = original
        settings.save()
    }
    try body()
}

@MainActor
private final class MutablePhylogeneticFontProvider: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }
}

@MainActor
private func makePhylogeneticTreeBundle() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LungfishPhylogeneticsTypography-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent(
        "a-very-long-phylogenetic-analysis-name-for-large-content-text.nwk"
    )
    try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(
        to: sourceURL,
        atomically: true,
        encoding: .utf8
    )
    let bundleURL = directory.appendingPathComponent("tree.lungfishtree", isDirectory: true)
    _ = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)
    return bundleURL
}

@MainActor
private func withSafePhylogeneticHostWindow<T>(
    content: NSView,
    size: NSSize,
    _ body: (NSWindow) throws -> T
) rethrows -> T {
    try autoreleasepool {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        content.frame = host.bounds
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        window.contentView = host
        defer {
            _ = window.makeFirstResponder(nil)
            content.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        return try body(window)
    }
}
