// ViewerViewControllerPerformTreeBundleOperationViaCLIParseTests.swift - performTreeBundleOperationViaCLI records a command the CLI parses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.20 (QR-a). `ViewerViewController.performTreeBundleOperationViaCLI` (ViewerViewController.swift)
// needs a project folder that encloses the tree bundle and a window that holds the viewer. It begins an Operations row
// for a re-root or an extract-subtree and runs the command it records. Each test gives the viewer a window and a
// project folder, runs the real method against a stand-in `lungfish-cli` (BeginSiteCLIStandIn), reads the command off
// the row, parses it with the real `tree reroot` or `tree extract-subtree` leaf, and compares the parsed values with
// the request.

import AppKit
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishPhylogeneticsUI
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class ViewerViewControllerPerformTreeBundleOperationViaCLIParseTests: XCTestCase {
    private var root: URL!
    private var standIn: BeginSiteCLIStandIn!

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "viewer-tree-bundle-operation")
        standIn = BeginSiteCLIStandIn(root: root)
    }

    override func tearDown() async throws {
        standIn.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// The row one real `performTreeBundleOperationViaCLI` call began, with the project and the tree bundle it named.
    private struct Run {
        let row: OperationCenter.Item
        let project: URL
        let bundle: URL
    }

    private func transform(
        _ operation: PhylogeneticTreeViewController.TreeBundleOperation,
        nodeID: String,
        nodeLabel: String,
        tipLabels: [String] = []
    ) async throws -> Run {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Phylogenetic Trees/Source tree.lungfishtree", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        defer {
            window.contentViewController = nil
            window.close()
        }
        let request = PhylogeneticTreeViewController.TreeBundleOperationRequest(
            operation: operation,
            bundleURL: bundle,
            nodeID: nodeID,
            nodeLabel: nodeLabel,
            tipLabels: tipLabels
        )
        let capture = try await standIn.capture {
            viewer.performTreeBundleOperationViaCLI(request)
        }
        XCTAssertEqual(capture.rows.count, 1, "one tree transform begins one row")
        let row = try XCTUnwrap(capture.rows.first, "the tree transform began no row")
        XCTAssertEqual(row.operationType, .phylogeneticTreeTransform)
        XCTAssertEqual(row.targetBundleURL?.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(row.routeContext?.projectURL?.standardizedFileURL, project.standardizedFileURL)
        XCTAssertEqual(
            capture.launchedArguments,
            try RecordedCLICommand.arguments(of: row.cliCommand),
            "the runner launched the arguments the row records"
        )
        return Run(row: row, project: project, bundle: bundle)
    }

    func testRerootRecordsATreeRerootTheCLIParses() async throws {
        let run = try await transform(.reroot, nodeID: "node-7", nodeLabel: "Outgroup A")
        XCTAssertEqual(run.row.title, "Re-root Tree")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: TreeCommand.RerootSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.standardizedFileURL.path)
        XCTAssertEqual(parsed.selector, "node-7")
        let output = URL(fileURLWithPath: parsed.outputPath)
        XCTAssertEqual(
            output.lastPathComponent,
            "Source-tree-rerooted.lungfishtree",
            "the output name is the bundle name with its spaces made hyphens, plus -rerooted"
        )
        XCTAssertTrue(
            output.standardizedFileURL.path.hasPrefix(run.project.standardizedFileURL.path + "/"),
            "the output lands inside the project: \(parsed.outputPath)"
        )
    }

    func testExtractSubtreeRecordsATreeExtractSubtreeTheCLIParses() async throws {
        let run = try await transform(
            .extractSubtree,
            nodeID: "node-12",
            nodeLabel: "Clade A",
            tipLabels: ["Human", "Chimp"]
        )
        XCTAssertEqual(run.row.title, "Extract Subtree")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: TreeCommand.ExtractSubtreeSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.standardizedFileURL.path)
        XCTAssertEqual(parsed.node, "node-12")
        let output = URL(fileURLWithPath: parsed.outputPath)
        XCTAssertEqual(output.pathExtension, "lungfishtree")
        XCTAssertTrue(
            output.lastPathComponent.hasSuffix("-subtree.lungfishtree"),
            "the output is named for the subtree: \(output.lastPathComponent)"
        )
        XCTAssertTrue(
            output.standardizedFileURL.path.hasPrefix(run.project.standardizedFileURL.path + "/"),
            "the output lands inside the project: \(parsed.outputPath)"
        )
    }
}
