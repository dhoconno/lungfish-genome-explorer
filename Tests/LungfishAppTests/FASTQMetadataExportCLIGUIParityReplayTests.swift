// FASTQMetadataExportCLIGUIParityReplayTests.swift - The FASTQ metadata drawer's export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34, ARCH ruling on the export shape 1.7, on lane Q30's harness. Each case runs on three sides
// that start as copies of one root that holds a FASTQ file.
//
// - Side A is the drawer's writer, the body of `exportClicked`'s panel completion as the drawer held it at
//   ddfa835cd, frozen in this file since the lane deletes it from the drawer. It runs on a drawer built from
//   assignments and a demux plan, with cells edited through the table delegate and not saved.
// - Side C is the drawer's `runSampleBarcodeExport`, which writes the selection file beside the output, begins the
//   row and runs the built `lungfish-cli fastq export sample-barcodes` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with the selection file copied to root C'.
//
// A against C compares what 1.7 names, which is the payload byte for byte, the output's digest and size, and every
// `resolved` key both sides write, with no file but the record and the selection file differing. The five identity
// fields, the options that name the inputs, and the input itself (side A the FASTQ file it never opened, side C the
// one selection file the leaf reads) are prediction rows of the lane report (BIO 4, 6 and 7), pinned on each side by
// `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is declared,
// so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
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
private final class FASTQMetadataExportReports {
    var messages: [String] = []
}

@MainActor
final class FASTQMetadataExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case samplesTabWithAnEdit
        case asymmetricDemux
        case samplesTabOfAnAsymmetricPlan

        var tab: FASTQSampleBarcodeTab { self == .asymmetricDemux ? .demux : .samples }
        var asymmetric: Bool { self != .samplesTabWithAnEdit }
        /// The cells edited in the drawer and not saved.
        var edits: [(column: String, row: Int, value: String)] {
            switch self {
            case .samplesTabWithAnEdit:
                return [(column: "sampleName", row: 0, value: "Edited"), (column: "forwardBarcodeID", row: 0, value: "BC09")]
            case .asymmetricDemux:
                return [(column: "forwardBarcodeID", row: 0, value: "BC09")]
            case .samplesTabOfAnAsymmetricPlan:
                return []
            }
        }
    }

    /// The `resolved` keys both sides write, compared value for value.
    static let sharedResolvedKeys: Set<String> = ["assignmentCount", "asymmetricDemux"]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let fullSheet = "sample_id,sample_name,barcode_5p,forward_sequence,barcode_3p,reverse_sequence,Batch,Cohort\n"
        + "S1,Alpha,BC01,ACGT,BC02,TGCA,b1,case\nS2,,BC03,,BC04,,,\n"
    static let editedFullSheet = "sample_id,sample_name,barcode_5p,forward_sequence,barcode_3p,reverse_sequence,Batch,Cohort\n"
        + "S1,Edited,BC09,ACGT,BC02,TGCA,b1,case\nS2,,BC03,,BC04,,,\n"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "fastq-metadata-export-parity")
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

    /// The Samples tab with a name and a barcode edited and not saved. Both sides write the edited full sheet.
    func testSamplesTabWithAnEditMatches() async throws {
        let runs = try await assertParity(.samplesTabWithAnEdit)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), Self.editedFullSheet)
        let resolved = try Self.envelope(in: runs.c.root).options.resolvedDefaults
        XCTAssertEqual(resolved["assignmentCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["asymmetricDemux"], .boolean(false))
    }

    /// The Demux tab of an asymmetric step writes barcode ids alone, with the edit in them.
    func testAsymmetricDemuxMatches() async throws {
        let runs = try await assertParity(.asymmetricDemux)
        XCTAssertEqual(
            try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8),
            "sample_id,barcode_1,barcode_2\nS1,BC09,BC02\nS2,BC03,BC04\n"
        )
        XCTAssertEqual(try Self.envelope(in: runs.c.root).options.resolvedDefaults["asymmetricDemux"], .boolean(true))
    }

    /// The one choice for BIO (lane report, prediction rows). The Samples tab writes the full sheet whatever the
    /// step's symmetry, and side A records the step's mode on both tabs, so side C records it too.
    func testSamplesTabOfAnAsymmetricPlanMatches() async throws {
        let runs = try await assertParity(.samplesTabOfAnAsymmetricPlan)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), Self.fullSheet)
        XCTAssertEqual(try Self.envelope(in: runs.c.root).options.resolvedDefaults["asymmetricDemux"], .boolean(true))
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no message, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let drawer = Self.configuredDrawer(root, .samplesTabWithAnEdit)

        let reports = FASTQMetadataExportReports()
        let begun = try XCTUnwrap(drawer.runSampleBarcodeExport(
            sourceURL: Self.fastqURL(in: root), tab: .samples,
            selection: Self.selection(of: drawer), outputURL: output,
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

// MARK: - The sides and the comparison

extension FASTQMetadataExportCLIGUIParityReplayTests {
    static let fastqName = "reads.fastq"
    static let outputName = "sample-sheet.csv"

    static func fastqURL(in root: URL) -> URL {
        root.appendingPathComponent(fastqName)
    }

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent(outputName)
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The root every side starts from, a FASTQ file the drawer shows. The leaf checks it exists and never opens it.
    static func makeFixture(_ root: URL) throws {
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: fastqURL(in: root))
    }

    static let assignments = [
        FASTQSampleBarcodeAssignment(
            sampleID: "S1", sampleName: "Alpha", forwardBarcodeID: "BC01", forwardSequence: "acgt",
            reverseBarcodeID: "BC02", reverseSequence: "tgca", metadata: ["Batch": "b1", "Cohort": "case"]
        ),
        FASTQSampleBarcodeAssignment(sampleID: "S2", forwardBarcodeID: "BC03", reverseBarcodeID: "BC04"),
    ]

    /// A drawer configured as the app configures it, with the case's edits made through the table delegate and not
    /// saved, and the Demux tab selected for the demux case.
    static func configuredDrawer(_ root: URL, _ parityCase: Case) -> FASTQMetadataDrawerView {
        var step = DemultiplexStep(label: "Demux", barcodeKitID: "NBD114", ordinal: 0)
        step.symmetryMode = parityCase.asymmetric ? .asymmetric : .symmetric
        let planJSON = (try? JSONEncoder().encode(DemultiplexPlan(steps: [step], compositeSampleNames: [:])))
            .flatMap { String(data: $0, encoding: .utf8) }
        let drawer = FASTQMetadataDrawerView()
        drawer.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        drawer.configure(
            fastqURL: fastqURL(in: root),
            metadata: FASTQDemultiplexMetadata(sampleAssignments: assignments, demuxPlanJSON: planJSON)
        )
        if parityCase.tab == .demux {
            drawer.selectDemuxTab()
        }
        let table = NSTableView()
        table.tag = 100
        for edit in parityCase.edits {
            drawer.tableView(
                table, setObjectValue: edit.value,
                for: NSTableColumn(identifier: NSUserInterfaceItemIdentifier(edit.column)), row: edit.row
            )
        }
        return drawer
    }

    /// What `exportClicked` freezes at the click, from the drawer's public state.
    static func selection(of drawer: FASTQMetadataDrawerView) -> ViewerExportSelection {
        FASTQSampleBarcodeExport.selection(
            assignments: drawer.currentMetadata().sampleAssignments,
            asymmetric: drawer.currentDemuxPlan().steps.first?.symmetryMode == .asymmetric
        )
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Side A. The drawer's writer before the leaf, frozen below.
    private func sideA(_ root: URL, _ parityCase: Case) throws -> RouteParitySideOutcome {
        let drawer = Self.configuredDrawer(root, parityCase)
        do {
            try Self.frozenExport(
                drawer: drawer, tab: parityCase.tab, fastqURL: Self.fastqURL(in: root), to: Self.outputURL(in: root)
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(Self.outputName).")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// The body of the panel completion of `exportClicked`, `fastqMetadataExportSourceURLs` and
    /// `fastqMetadataExportArgv` as `FASTQMetadataDrawerView` held them at ddfa835cd, reading the drawer's rows and
    /// demux step through its public accessors.
    private static func frozenExport(
        drawer: FASTQMetadataDrawerView,
        tab: FASTQSampleBarcodeTab,
        fastqURL: URL,
        to outputURL: URL
    ) throws {
        let runClock = ProvenanceRunClock()
        let assignments = drawer.currentMetadata().sampleAssignments
        let isAsymmetric = drawer.currentDemuxPlan().steps.first?.symmetryMode == .asymmetric
        let sourceURLs = [fastqURL.standardizedFileURL]
        let content: String
        if isAsymmetric && tab == .demux {
            content = FASTQSampleBarcodeCSV.exportAsymmetricCSV(assignments)
        } else {
            content = FASTQSampleBarcodeCSV.exportCSV(assignments)
        }
        var argv = [
            "Lungfish.app",
            "export-fastq-metadata",
            "--tab", tab.rawValue,
            "--format", "csv",
            "--output", outputURL.path,
        ]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app fastq metadata export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: sourceURLs,
            outputURL: outputURL,
            outputFormat: .text,
            argv: argv,
            explicitOptions: [
                "sourcePaths": .array(sourceURLs.map { .file($0) }),
                "outputPath": .file(outputURL),
                "activeTab": .string(tab.rawValue),
            ],
            defaults: [
                "outputFormat": .string("csv"),
            ],
            resolved: [
                "assignmentCount": .integer(assignments.count),
                "asymmetricDemux": .boolean(isAsymmetric),
            ],
            runClock: runClock
        )) { tempURL in
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
        }
    }

    /// Side C. The drawer's run, which writes the selection file, begins the row and runs the built CLI behind it on
    /// the shared runner. The selection folder is then copied to root C', so the rebased command reads it there.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let drawer = Self.configuredDrawer(root, parityCase)
        let reports = FASTQMetadataExportReports()
        guard let begun = drawer.runSampleBarcodeExport(
            sourceURL: Self.fastqURL(in: root), tab: parityCase.tab,
            selection: Self.selection(of: drawer), outputURL: Self.outputURL(in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            report: { reports.messages.append($0) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start: \(reports.messages)")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(reports.messages, ["Exported \(Self.outputName)."])
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

    /// A against C on the facts of 1.7. No file but the record and the selection file differs, and the compared
    /// facts of the record are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(ViewerExportSelection.inputsFolderName)
        }
        XCTAssertEqual(others.map(\.description), [], "only the record and the selection file may differ between A and C")

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
    /// to the leaf, the options that name the inputs change with them, and the one input is the selection file the
    /// leaf reads, with its digest, where side A named the FASTQ file it never opened. The record's argv is the row's
    /// command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let tab = parityCase.tab.rawValue
        let argvA = [
            "Lungfish.app", "export-fastq-metadata", "--tab", tab, "--format", "csv",
            "--output", Self.outputURL(in: runs.a.root).path,
            "--source", Self.fastqURL(in: runs.a.root).standardizedFileURL.path,
        ]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app fastq metadata export")
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["activeTab", "outputPath", "sourcePaths"])
        XCTAssertEqual(a.options.explicit["activeTab"], .string(tab))
        XCTAssertEqual(a.options.defaults.keys.sorted(), ["outputFormat"])
        XCTAssertEqual(a.options.defaults["outputFormat"], .string("csv"))
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root).keys.sorted(), ["/" + Self.fastqName], "side A names the FASTQ")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(3)), FASTQSampleBarcodeExport.commandPath)
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, FASTQSampleBarcodeExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["outputPath", "selection", "tab"])
        XCTAssertEqual(c.options.explicit["tab"], .string(tab))
        XCTAssertTrue(c.options.defaults.isEmpty)

        let inputsC = Self.inputs(of: c, under: runs.c.root)
        XCTAssertEqual(inputsC.count, 1, "\(inputsC)")
        let selectionPath = try XCTUnwrap(inputsC.keys.first)
        XCTAssertTrue(selectionPath.hasPrefix("/" + ViewerExportSelection.inputsFolderName + "/"), selectionPath)
        XCTAssertTrue(selectionPath.hasSuffix("/" + ViewerExportSelection.fileName), selectionPath)
        let selectionBytes = try Data(contentsOf: URL(fileURLWithPath: runs.c.root.path + selectionPath))
        let digest = SHA256.hash(data: selectionBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(inputsC[selectionPath], digest, "the record names the selection file with its digest")
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
