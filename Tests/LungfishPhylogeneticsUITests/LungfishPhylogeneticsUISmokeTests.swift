// LungfishPhylogeneticsUISmokeTests.swift - leaf module presence smoke test
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishIO
@testable import LungfishPhylogeneticsUI

@MainActor
final class LungfishPhylogeneticsUISmokeTests: XCTestCase {
    func testTreeViewControllerLoadsViewStandalone() {
        let controller = PhylogeneticTreeViewController()
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "phylogenetic-tree-bundle-view")
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
