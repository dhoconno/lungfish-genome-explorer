// TreeSubtreeExportCLIGUIParityReplayTests.swift - The tree viewer's subtree export in the app against its leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row A15, ARCH ruling on the export shape 1.7, BIO-12.31-G3, on lane Q30's harness. Each case
// runs on three sides that start as copies of one `.lungfishtree` bundle, which is imported once outside the case
// folder and copied in, so no fixture file names a side's root.
//
// - Side A is the in-app writer, `writeSubtreeExport` as the view held it after the G3 commit (c27e85e54), frozen in
//   this file since the lane deletes it from the view, given the subtree the view's loaded bundle exports.
// - Side C is the view's begin helper, `runSubtreeExport`, given the same node. It begins the row and runs the built
//   `lungfish-cli tree export subtree` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares the payload byte for byte, the output's digest and size, the two inputs with their digests,
// the `resolved` and `defaults` keys and every explicit option, with no file but the record differing. The five
// identity fields are prediction rows of the lane report (BIO 7), pinned on each side by
// `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is declared,
// so the old writer goes in the lane with no key (R-A1, C4).
//
// Each case root sits five folders below the temporary folder, since a record's sidecar search lists each input's
// folder and four above it (SCR/lanes/12.31/12.31-cancel.md).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishPhylogeneticsUI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class SubtreeExportParityFailureCalls {
    var messages: [String] = []
}

@MainActor
final class TreeSubtreeExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case namedClade
        case aTip
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let bundleRelativePath = "Project/Trees/primates.lungfishtree"
    static let newick = "((A:0.1,B:0.2)Clade:0.3,(C:0.4,D:0.5)Pair:0.6);"

    private var scratch: URL!
    private var fixtureBundle: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "tree-subtree-export-parity")
        let source = scratch.appendingPathComponent("fixture/source.nwk")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.newick.write(to: source, atomically: true, encoding: .utf8)
        fixtureBundle = scratch.appendingPathComponent("fixture/primates.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: source, to: fixtureBundle)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// An internal node with a label, two tips below it.
    func testNamedCladeMatches() async throws {
        let runs = try await assertParity(.namedClade)
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(try Data(contentsOf: Self.outputURL(in: runs.c.root)), Data("(A:0.1,B:0.2)Clade:0.3;\n".utf8))
        XCTAssertEqual(c.options.resolvedDefaults["descendantTipCount"]?.integerValue, 2)
    }

    /// One tip, whose subtree is the tip alone.
    func testATipMatches() async throws {
        let runs = try await assertParity(.aTip)
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(c.options.resolvedDefaults["descendantTipCount"]?.integerValue, 1)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = Self.caseFolder(in: scratch).appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")

        let failures = SubtreeExportParityFailureCalls()
        let begun = try XCTUnwrap(PhylogeneticTreeViewController.runSubtreeExport(
            bundleURL: Self.bundleURL(in: root),
            nodeID: try Self.nodeID(for: .namedClade, in: root),
            outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

// MARK: - The fixture

extension TreeSubtreeExportCLIGUIParityReplayTests {
    /// The folder the case roots sit in, five folders below the temporary folder.
    static func caseFolder(in scratch: URL) -> URL {
        scratch.appendingPathComponent("cases/of/the/subtree", isDirectory: true)
    }

    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent(bundleRelativePath, isDirectory: true)
    }

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("subtree.nwk")
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The normalized node ID of a case's node in the bundle at `root`, as the view holds it selected.
    static func nodeID(for parityCase: Case, in root: URL) throws -> String {
        let label = parityCase == .namedClade ? "Clade" : "C"
        let bundle = try PhylogeneticTreeBundle.load(from: bundleURL(in: root))
        return try XCTUnwrap(bundle.normalizedTree.nodes.first { $0.displayLabel == label }?.id, "no node \(label)")
    }

    /// The bundle imported once in setUp, copied into the root.
    func makeFixture(_ root: URL) throws {
        let bundle = Self.bundleURL(in: root)
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureBundle, to: bundle)
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

// MARK: - The sides

extension TreeSubtreeExportCLIGUIParityReplayTests {
    /// Side A. The in-app writer the view's Export Subtree ran before the leaf, frozen below, given the subtree the
    /// view's loaded bundle exports for the selected node.
    private func sideA(_ root: URL, case parityCase: Case) throws -> RouteParitySideOutcome {
        do {
            let bundle = try PhylogeneticTreeBundle.load(from: Self.bundleURL(in: root))
            let export = try bundle.subtreeExport(nodeID: try Self.nodeID(for: parityCase, in: root))
            try Self.frozenWriteSubtreeExport(export, sourceBundleURL: bundle.url, to: Self.outputURL(in: root))
            return RouteParitySideOutcome(end: .completed, detail: "Exported subtree.nwk")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `writeSubtreeExport` as `PhylogeneticTreeViewController` held it at c27e85e54, after the M3 newline
    /// (d775e6a57) and the G3 inputs (c27e85e54), with the view's run clock started at the save panel's OK.
    private static func frozenWriteSubtreeExport(
        _ export: PhylogeneticTreeSubtreeExport,
        sourceBundleURL: URL?,
        to outputURL: URL
    ) throws {
        let runClock = ProvenanceRunClock()
        let sourceURLs = sourceBundleURL.map { [$0] } ?? []
        var argv = ["Lungfish Genome Explorer", "export-tree-subtree"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        argv.append(contentsOf: ["--node", export.selectedNodeID, "--output", outputURL.path])
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app phylogenetic subtree export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: sourceBundleURL.map(TreeSubtreeExport.inputURLs(bundleURL:)) ?? [],
            outputURL: outputURL,
            outputFormat: .text,
            argv: argv,
            explicitOptions: [
                "sourceBundlePath": sourceBundleURL.map(ParameterValue.file) ?? .string("none"),
                "outputPath": .file(outputURL),
                "selectedNodeID": .string(export.selectedNodeID),
                "selectedLabel": .string(export.selectedLabel),
            ],
            defaults: [
                "outputFormat": .string("newick"),
            ],
            resolved: [
                "descendantTipCount": .integer(export.descendantTipCount),
                "outputByteCount": .integer(export.newick.utf8.count + 1),
            ],
            runClock: runClock
        )) { staged in
            try Data((export.newick + "\n").utf8).write(to: staged, options: .atomic)
        }
    }

    /// Side C. The view's run helper, which runs the built CLI behind the row on the shared runner.
    private func sideC(_ root: URL, case parityCase: Case) async throws -> RouteParitySideOutcome {
        let failures = SubtreeExportParityFailureCalls()
        guard let begun = PhylogeneticTreeViewController.runSubtreeExport(
            bundleURL: Self.bundleURL(in: root),
            nodeID: try Self.nodeID(for: parityCase, in: root),
            outputURL: Self.outputURL(in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }
}

// MARK: - The comparison

extension TreeSubtreeExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: Self.caseFolder(in: scratch).appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try self.makeFixture(root) },
            sideA: { root in try self.sideA(root, case: parityCase) },
            sideC: { root in try await self.sideC(root, case: parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs)
        try assertPredictedRecordChanges(runs)
        return runs
    }

    /// A against C on the facts of 1.7, with each path read relative to its side root. No file but the record
    /// differs, and the record's compared facts are equal, the two inputs and their digests included (G3).
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root))
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root)), "the payload byte for byte")
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let outputA = try XCTUnwrap(a.output)
        let outputC = try XCTUnwrap(c.output)
        XCTAssertNotNil(outputA.checksumSHA256)
        XCTAssertEqual(outputA.checksumSHA256, outputC.checksumSHA256, "the output digest")
        XCTAssertEqual(outputA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(outputA.fileSize, outputC.fileSize, "the output size")
        XCTAssertEqual(outputA.format, outputC.format, "the output format")
        let inputsA = Self.inputs(of: a, under: runs.a.root)
        XCTAssertEqual(inputsA.keys.sorted(), ["manifest.json", "tree/primary.normalized.json"].map {
            "/\(Self.bundleRelativePath)/\($0)"
        })
        XCTAssertEqual(inputsA, Self.inputs(of: c, under: runs.c.root), "the inputs and their digests")
        XCTAssertEqual(a.options.resolvedDefaults, c.options.resolvedDefaults, "resolved tip and byte counts")
        XCTAssertEqual(a.options.defaults, c.options.defaults, "default output format")
        XCTAssertEqual(a.options.explicit.keys.sorted(), c.options.explicit.keys.sorted(), "the explicit keys")
        for key in ["sourceBundlePath", "outputPath"] {
            XCTAssertEqual(
                Self.relativeFile(a.options.explicit[key], under: runs.a.root),
                Self.relativeFile(c.options.explicit[key], under: runs.c.root),
                "explicit \(key)"
            )
        }
        for key in ["selectedNodeID", "selectedLabel"] {
            XCTAssertEqual(a.options.explicit[key], c.options.explicit[key], "explicit \(key)")
        }
    }

    /// The prediction rows of the lane report (BIO 7). The five identity fields move from the app's writer to the
    /// leaf. The record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let nodeID = try XCTUnwrap(a.options.explicit["selectedNodeID"]?.stringValue)
        let argvA = [
            "Lungfish Genome Explorer", "export-tree-subtree",
            "--source", Self.bundleURL(in: runs.a.root).path,
            "--node", nodeID, "--output", Self.outputURL(in: runs.a.root).path,
        ]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app phylogenetic subtree export")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, TreeSubtreeExport.workflowName)
        XCTAssertEqual(Array(rowArguments.prefix(3)), TreeSubtreeExport.commandPath)
        XCTAssertTrue(rowArguments.contains("--node") && rowArguments.contains(nodeID), "\(rowArguments)")
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            inputs[relativePath(file.path, under: root)] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }

    /// The path of a `.file` option below `root`.
    private static func relativeFile(_ value: ParameterValue?, under root: URL) -> String? {
        guard case .file(let url)? = value else { return nil }
        return relativePath(url.path, under: root)
    }

    private static func relativePath(_ path: String, under root: URL) -> String {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        let rootPath = rootPaths.first { path.hasPrefix($0 + "/") }
        return rootPath.map { String(path.dropFirst($0.count)) } ?? path
    }
}
