// FASTARecordsExportCLIGUIParityReplayTests.swift - The viewers' FASTA records export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M3, ARCH ruling on the export shape 1.7, on lane Q30's harness. Each case runs on three sides
// that start as copies of one root that holds the FASTA document a viewer shows. The four cases are the record shapes
// of the five callers of `exportFASTARecords`. An assembly's contigs wrap at 70 columns, an NVD contig is one line,
// the FASTA collection writes `FASTASelectionDetailFormatter`'s record with a description and may repeat a name, and
// an alignment's rows are ungapped with a block name for a column range. The extraction dialog's `.file` destination
// passes the records of the other four.
//
// - Side A is the writer of `exportFASTARecords` as `ViewerViewController` held it at add9b0713, frozen in this file
//   since the lane deletes it. It joins the records as given and writes them with a record that names the viewer's
//   document.
// - Side C is `ViewerViewController.runFASTARecordsExport`, which stages the records and the selection file beside the
//   output, begins the row and runs the built `lungfish-cli extract sequence` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with the inputs folder copied to root C'.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the output's digest and size, and every
// `resolved` key both sides write, with no file but the record and the inputs folder differing. The five identity
// fields, the options that name the inputs, and the inputs (side A the viewer's document, side C the staged records
// and the selection file with their digests) are prediction rows of the lane report (BIO 4, 6 and 7), pinned on each
// side by `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is
// declared, so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output, its record nor the staged
// inputs are left (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import CryptoKit
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
private final class FASTARecordsExportReports {
    var messages: [String] = []
}

@MainActor
final class FASTARecordsExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case assemblyContigs
        case nvdContig
        case collectionRecords
        case alignmentRows

        /// The records the caller hands `exportFASTARecords`, one element for each record.
        func records() throws -> [String] {
            switch self {
            case .assemblyContigs:
                return [
                    ">NODE_1_length_100_cov_5.2\n\(String(repeating: "ACGTACGTAC", count: 7))\n\(String(repeating: "GT", count: 15))\n",
                    ">NODE_2_length_40_cov_1.0\n\(String(repeating: "TTGCA", count: 8))\n",
                ]
            case .nvdContig:
                return [">NODE_7_length_90\n\(String(repeating: "ACGTT", count: 18))\n"]
            case .collectionRecords:
                let sequences = [
                    try LungfishCore.Sequence(name: "chr1", description: "visible track", alphabet: .dna, bases: String(repeating: "ACGT", count: 30)),
                    try LungfishCore.Sequence(name: "chr1", alphabet: .dna, bases: "TTGGCCAA"),
                    try LungfishCore.Sequence(name: "plasmid", description: "circular", alphabet: .dna, bases: "GATTACA"),
                ]
                return sequences.map { FASTASelectionDetailFormatter.record(for: $0) }
            case .alignmentRows:
                return [">row one\nACGTACGTAC\n", ">row one:3-6\nGTAC\n", ">row_two\nACGT\n"]
            }
        }
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let sharedResolvedKeys: Set<String> = ["outputByteCount", "recordCount"]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "fasta-records-export-parity")
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

    /// An assembly's contigs, wrapped at 70 columns.
    func testAssemblyContigsMatch() async throws {
        let runs = try await assertParity(.assemblyContigs)
        XCTAssertEqual(
            try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8),
            try Case.assemblyContigs.records().joined()
        )
        XCTAssertEqual(try Self.envelope(in: runs.c.root).options.resolvedDefaults["recordCount"]?.integerValue, 2)
    }

    /// An NVD contig, one line of bases.
    func testAnNvdContigMatches() async throws {
        let runs = try await assertParity(.nvdContig)
        XCTAssertEqual(try Self.envelope(in: runs.c.root).options.resolvedDefaults["recordCount"]?.integerValue, 1)
    }

    /// The FASTA collection's records, which carry a description and repeat a name.
    func testCollectionRecordsMatch() async throws {
        let runs = try await assertParity(.collectionRecords)
        XCTAssertEqual(try Self.envelope(in: runs.c.root).options.resolvedDefaults["recordCount"]?.integerValue, 3)
    }

    /// An alignment's ungapped rows, one named for a column range.
    func testAlignmentRowsMatch() async throws {
        let runs = try await assertParity(.alignmentRows)
        XCTAssertEqual(try Self.envelope(in: runs.c.root).options.resolvedDefaults["recordCount"]?.integerValue, 3)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no message, the staged inputs go, and the row's command, cancelled on the launcher every CLI route uses, exits
    /// 125 inside the grace. Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        // The leaf's record looks for a sidecar of each input in the input's folder and the four folders above it, and
        // lists each one (`ProvenanceRecorder.findProvenanceReading`). The staged inputs sit two folders under this
        // root, so from `scratch/cancel` that walk reached the shared temporary folder, whose listing (135,212
        // entries) took the leaf 20 to 40 seconds to reach its hold, past the 30 second wait. Two more levels keep
        // the walk inside this case's folders, as the NAO-MGS and NVD cancel cases do.
        let root = scratch.appendingPathComponent("cancel/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let records = try Case.assemblyContigs.records()

        let reports = FASTARecordsExportReports()
        let begun = try unwrapStarted(await ViewerViewController.runFASTARecordsExport(
            records: records, outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { reports.messages.append($0) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(reports.messages, [], "a cancel shows nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
        let staged = root.appendingPathComponent(ViewerExportSelection.inputsFolderName)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? [], [], "a cancel removes the staged inputs")

        // The cancel removed the inputs the recorded command names, so restage them where it looks.
        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let stagedPath = arguments[2]
        let selectionPath = try XCTUnwrap(arguments.firstIndex(of: "--selection").map { arguments[$0 + 1] })
        let document = FASTARecordsExport.document(from: Data(records.joined().utf8))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: stagedPath).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(records.joined().utf8).write(to: URL(fileURLWithPath: stagedPath))
        try FASTARecordsExport.selection(headers: document.records.map(\.header)).encoded()
            .write(to: URL(fileURLWithPath: selectionPath))
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

// MARK: - The sides and the comparison

extension FASTARecordsExportCLIGUIParityReplayTests {
    static let documentName = "document.fa"
    static let outputName = "selected.fa"

    static func documentURL(in root: URL) -> URL {
        root.appendingPathComponent(documentName)
    }

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent(outputName)
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The root every side starts from, the FASTA document the viewer shows. Side A names it, side C never opens it.
    static func makeFixture(_ root: URL) throws {
        try Data(">doc\nACGT\n".utf8).write(to: documentURL(in: root))
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Side A. The viewer's writer before the leaf, frozen below.
    private func sideA(_ root: URL, _ parityCase: Case) throws -> RouteParitySideOutcome {
        do {
            try Self.frozenExport(
                records: try parityCase.records(), suggestedName: Self.outputName,
                sourceURLs: [Self.documentURL(in: root).standardizedFileURL], to: Self.outputURL(in: root)
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(Self.outputName).")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// The body of `exportFASTARecords`'s task and `fastaExportArgv` as `ViewerViewController` held them at
    /// add9b0713, with `fastaExportSourceURLs()` passed in.
    private static func frozenExport(
        records: [String],
        suggestedName: String,
        sourceURLs: [URL],
        to destination: URL
    ) throws {
        let runClock = ProvenanceRunClock()
        let normalized = records.joined(separator: "")
        var argv = ["Lungfish Genome Explorer", "export-fasta"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        argv.append(contentsOf: ["--output", destination.path])
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app fasta export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: sourceURLs,
            outputURL: destination,
            outputFormat: .fasta,
            argv: argv,
            explicitOptions: [
                "sourcePaths": .array(sourceURLs.map { .file($0) }),
                "outputPath": .file(destination),
                "suggestedName": .string(suggestedName),
            ],
            resolved: [
                "recordCount": .integer(records.count),
                "outputByteCount": .integer(normalized.utf8.count),
            ],
            runClock: runClock
        )) { staged in
            try normalized.write(to: staged, atomically: true, encoding: .utf8)
        }
    }

    /// Side C. The viewer's run, which stages the records and the selection file, begins the row and runs the built
    /// CLI behind it on the shared runner. The inputs folder is then copied to root C', so the rebased command reads
    /// it there.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let reports = FASTARecordsExportReports()
        guard let begun = await ViewerViewController.runFASTARecordsExport(
            records: try parityCase.records(), outputURL: Self.outputURL(in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { reports.messages.append($0) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start: \(reports.messages)")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(reports.messages, [])
            try RegionExtractionWithoutBundleParityReplayTests.copyStage(
                root.appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true), from: root
            )
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
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
            sideA: { root in try self.sideA(root, parityCase) },
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
        try assertAEqualsC(runs)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7. No file but the record and the inputs folder differs, and the compared facts
    /// of the record are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(ViewerExportSelection.inputsFolderName)
        }
        XCTAssertEqual(others.map(\.description), [], "only the record and the inputs folder may differ between A and C")

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
        let resolvedA = a.options.resolvedDefaults
        let resolvedC = c.options.resolvedDefaults
        XCTAssertEqual(Set(resolvedA.keys), Self.sharedResolvedKeys)
        XCTAssertEqual(Set(resolvedC.keys), Self.sharedResolvedKeys)
        for key in Self.sharedResolvedKeys.sorted() {
            XCTAssertEqual(resolvedA[key], resolvedC[key], "resolved \(key)")
        }
    }

    /// The prediction rows of the lane report (BIO 4, 6 and 7). The five identity fields move from the app's writer
    /// to the leaf, the options that name the inputs change with them, and the inputs are the staged records and the
    /// selection file the leaf reads, with their digests, where side A named the viewer's document it never opened.
    /// The record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let argvA = [
            "Lungfish Genome Explorer", "export-fasta",
            "--source", Self.documentURL(in: runs.a.root).standardizedFileURL.path,
            "--output", Self.outputURL(in: runs.a.root).path,
        ]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app fasta export")
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["outputPath", "sourcePaths", "suggestedName"])
        XCTAssertEqual(a.options.explicit["suggestedName"], .string(Self.outputName))
        XCTAssertTrue(a.options.defaults.isEmpty)
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root).keys.sorted(), ["/" + Self.documentName], "side A names the document")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(2)), FASTARecordsExport.commandPath)
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, FASTARecordsExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["outputPath", "selection"])
        XCTAssertTrue(c.options.defaults.isEmpty)

        let inputsC = Self.inputs(of: c, under: runs.c.root)
        XCTAssertEqual(inputsC.count, 2, "\(inputsC)")
        let stagedPath = try XCTUnwrap(inputsC.keys.first { $0.hasSuffix("/" + FASTARecordsExport.stagedFileName) })
        let selectionPath = try XCTUnwrap(inputsC.keys.first { $0.hasSuffix("/" + ViewerExportSelection.fileName) })
        for path in [stagedPath, selectionPath] {
            XCTAssertTrue(path.hasPrefix("/" + ViewerExportSelection.inputsFolderName + "/"), path)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: runs.c.root.path + path))
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(inputsC[path], digest, "the record names \(path) with its digest")
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: runs.c.root.path + stagedPath)),
            Data(try parityCase.records().joined().utf8),
            "the staged file holds the records as the viewer gave them"
        )
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
