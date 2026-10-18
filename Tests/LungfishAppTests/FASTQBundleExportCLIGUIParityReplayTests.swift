// FASTQBundleExportCLIGUIParityReplayTests.swift - The sidebar FASTQ bundle export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling on the export shape 1.7, on lane Q30's harness. Each case runs on three sides
// that start as copies of one root that holds a plain bundle, a bundle of three source chunks and a derived bundle.
//
// - Side A is the in-app writer, `exportFASTQBundleForSidebar` as AppDelegate held it at add9b0713, frozen in
//   FASTQBundleExportFrozenWriter since the lane deletes it from AppDelegate.
// - Side C is `AppDelegate.runFASTQBundleExports`, which begins the row and runs the built
//   `lungfish-cli fastq export reads` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the output's digest and size, the record's
// input set with its digests, and the three values the base kept as explicit parameters and the leaf keeps as
// `resolved`. The five identity fields (tool name, tool kind, argv, durable replay argv, workflow name) and the
// partition of the options are prediction rows of the lane report (BIO 4, 6 and 7), pinned on each side by
// `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. The one input digest
// that differs is a derived bundle's folder, which side A recorded with none and the leaf records with a digest of
// its contents (BIO 6). Nothing else is declared, so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output, its record nor a staged file
// is left (ARCH ruling 1.6, X14). It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it
// to the integration tier.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class FASTQBundleExportReports {
    var failures: [String] = []
}

@MainActor
final class FASTQBundleExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable, CaseIterable {
        case plainBundle
        case severalChunks
        case derivedBundle

        var isDerived: Bool { self == .derivedBundle }
        var bundleName: String {
            switch self {
            case .plainBundle: return "plain.lungfishfastq"
            case .severalChunks: return "chunked.lungfishfastq"
            case .derivedBundle: return "derived.lungfishfastq"
            }
        }
        var chunkCount: Int {
            switch self {
            case .plainBundle: return 1
            case .severalChunks: return 3
            case .derivedBundle: return 0
            }
        }
        var outputName: String { "\(rawValue).fastq" }
        var expectedBytes: String {
            self == .severalChunks
                ? "@c0\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n@c2\nACGT\n+\nIIII\n"
                : FASTQBundleExportPinTests.reads
        }
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    /// The values the base kept as explicit parameters and the leaf keeps as `resolved`.
    static let sharedValueKeys = ["inputChunkCount", "isDerived", "outputGzipCompressed"]

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "fastq-bundle-export-parity")
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

    func testAPlainBundleMatches() async throws {
        _ = try await assertParity(.plainBundle)
    }

    func testSeveralChunksMatch() async throws {
        _ = try await assertParity(.severalChunks)
    }

    func testADerivedBundleMatches() async throws {
        let runs = try await assertParity(.derivedBundle)
        let inputsA = Self.inputs(of: try Self.envelope(in: runs.a.root, .derivedBundle), under: runs.a.root)
        let inputsC = Self.inputs(of: try Self.envelope(in: runs.c.root, .derivedBundle), under: runs.c.root)
        XCTAssertEqual(inputsA["/derived.lungfishfastq"], "no digest", "side A named the bundle folder with no digest")
        XCTAssertNotEqual(inputsC["/derived.lungfishfastq"], "no digest", "the leaf records the folder with a digest")
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no message, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output, its record or a staged file.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let parityCase = Case.plainBundle
        let output = Self.outputURL(in: root, parityCase)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let reports = FASTQBundleExportReports()

        let invocation = FASTQReadsExport.invocation(
            bundleURL: Self.bundleURL(in: root, parityCase), outputURL: output, isDerived: false, force: false
        )
        let begun = try XCTUnwrap(AppDelegate.beginFASTQBundleExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { reports.failures.append($0.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(reports.failures, [], "a cancel shows nothing")
        try assertNothingLeft(output, sidecar)

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
        try assertNothingLeft(output, sidecar)
    }

    private func assertNothingLeft(_ output: URL, _ sidecar: URL) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
        let left = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        XCTAssertEqual(left, [], "a cancel leaves no staged file")
    }
}

// MARK: - The sides and the comparison

extension FASTQBundleExportCLIGUIParityReplayTests {
    static func bundleURL(in root: URL, _ parityCase: Case) -> URL {
        root.appendingPathComponent(parityCase.bundleName, isDirectory: true)
    }

    static func outputURL(in root: URL, _ parityCase: Case) -> URL {
        root.appendingPathComponent("out", isDirectory: true).appendingPathComponent(parityCase.outputName)
    }

    static func envelope(in root: URL, _ parityCase: Case) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root, parityCase))))
    }

    /// The root every side starts from, the three bundles and the folder the exports go in.
    static func makeFixture(_ root: URL) throws {
        _ = try FASTQBundleExportPinTests.makePlainBundle(in: root)
        _ = try FASTQBundleExportPinTests.makeChunkedBundle(in: root)
        _ = try FASTQBundleExportPinTests.makeDerivedBundle(in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out", isDirectory: true), withIntermediateDirectories: true)
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Side A. The in-app writer, frozen.
    private func sideA(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        do {
            try await FASTQBundleExportFrozenWriter.export(
                bundleURL: Self.bundleURL(in: root, parityCase),
                outputURL: Self.outputURL(in: root, parityCase),
                isDerived: parityCase.isDerived
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(parityCase.outputName)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The batch runner, which begins the row and runs the built CLI behind it on the shared runner.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let export = AppDelegate.FASTQBundleExport(
            bundleURL: Self.bundleURL(in: root, parityCase),
            outputURL: Self.outputURL(in: root, parityCase),
            isDerived: parityCase.isDerived,
            title: parityCase.rawValue
        )
        let results = await AppDelegate.runFASTQBundleExports(
            [export], runner: { CLIViewerExportRunner(cliURLOverride: self.harness.cliBinary) }
        )
        let result = try XCTUnwrap(results.first)
        let item = OperationCenter.shared.items.first { $0.id == result.operationID }
        switch result.end {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let message):
            return RouteParitySideOutcome(end: .failed, detail: message, recordedCommand: item?.cliCommand)
        }
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: Self.makeFixture,
            sideA: { root in try await self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
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
        try assertAEqualsC(runs, parityCase)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7. No file but the record differs, and the compared facts of the record are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root, parityCase)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter { !$0.id.contains(sidecarName) }
        XCTAssertEqual(others.map(\.description), [], "only the record may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root, parityCase))
        XCTAssertEqual(String(decoding: payloadA, as: UTF8.self), parityCase.expectedBytes)
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root, parityCase)), "the payload byte for byte")
        let a = try Self.envelope(in: runs.a.root, parityCase)
        let c = try Self.envelope(in: runs.c.root, parityCase)
        let outputA = try XCTUnwrap(a.output)
        let outputC = try XCTUnwrap(c.output)
        XCTAssertNotNil(outputA.checksumSHA256)
        XCTAssertEqual(outputA.checksumSHA256, outputC.checksumSHA256, "the output digest")
        XCTAssertEqual(outputA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(outputA.fileSize, outputC.fileSize, "the output size")

        let inputsA = Self.inputs(of: a, under: runs.a.root)
        let inputsC = Self.inputs(of: c, under: runs.c.root)
        XCTAssertEqual(Set(inputsA.keys), Set(inputsC.keys), "the input set")
        for (path, digest) in inputsA where digest != "no digest" {
            XCTAssertEqual(inputsC[path], digest, "the digest of input \(path)")
        }
        for key in Self.sharedValueKeys {
            XCTAssertNotNil(a.options.explicit[key], key)
            XCTAssertEqual(a.options.explicit[key], c.options.resolvedDefaults[key], "the value of \(key)")
        }
    }

    /// The prediction rows of the lane report (BIO 4, 6 and 7). The tool moves from the in-app writer's name to the
    /// CLI, the record's argv is the row's command (ARCH 2), the workflow name follows the leaf, and the three
    /// parameters the base kept as explicit options are resolved facts now.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root, parityCase)
        let c = try Self.envelope(in: runs.c.root, parityCase)
        var argvA = [
            "Lungfish Genome Explorer", "export-fastq", Self.bundleURL(in: runs.a.root, parityCase).path,
            "--output", Self.outputURL(in: runs.a.root, parityCase).path,
        ]
        if parityCase.isDerived {
            argvA.append("--materialize-derived")
        }
        if parityCase.chunkCount > 1 {
            argvA += ["--source-chunks", "\(parityCase.chunkCount)"]
        }
        XCTAssertEqual(a.toolName, "Lungfish Genome Explorer FASTQ Export")
        XCTAssertEqual(a.tool.kind, "cli")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.workflowName, "FASTQ Export")
        XCTAssertEqual(
            a.options.explicit.keys.sorted(), ["inputChunkCount", "isDerived", "output", "outputGzipCompressed", "sourceBundle"]
        )
        XCTAssertTrue(a.options.resolvedDefaults.isEmpty)

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(3)), FASTQReadsExport.commandPath)
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, FASTQReadsExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), parityCase.isDerived ? ["materializeDerived", "outputPath"] : ["outputPath"])
        XCTAssertTrue(c.options.defaults.isEmpty)
        XCTAssertEqual(c.options.resolvedDefaults.keys.sorted(), Self.sharedValueKeys)
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = ["/private" + root.standardizedFileURL.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
