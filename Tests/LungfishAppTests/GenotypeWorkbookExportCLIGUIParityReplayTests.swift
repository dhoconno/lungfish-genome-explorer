// GenotypeWorkbookExportCLIGUIParityReplayTests.swift - The genotype viewer's workbook export in the app against its leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B1, ARCH-12.35-B1 route (a) and 1.4, on lane Q30's harness. Each case runs one frozen
// capture of one fixture, built once outside the case folder, with one managed openpyxl Python, on three sides.
//
// - Side A is the in-app writer, `GenotypeViewportExportService.exportExcel` as it stood at a4cde2987 after the
//   condition 6 fix, frozen in this file since the lane deletes it.
// - Side C is the view's begin helper, `runWorkbookExport`, given the same capture. It writes `capture.json` and
//   `request.json`, begins the row and runs the built `lungfish-cli genotype export-xlsx --snapshot` on
//   `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with side C's inputs folder copied to
//   root C' as the region extraction parity class copies its stage.
//
// A against C compares the workbook through the goldens' XLSX normalization (`workbookDifferences`, manager decision
// MGR-12.35-B1C item 1), the receipt's scientific witnesses, snapshot digest and size, output size, `generatedAt`,
// `toolName`, and every key of A's options, defaults and runtime context with A's value (item 3). The argv, workflow
// name, durable replay argv, inputs and the leaf's own keys are prediction rows of the lane report (BIO 7), pinned by
// `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks, the workbook as A
// against C does, and the Excel service's `<out>.export-<UUID>/` folders paired by this class
// (`exportFolderDifferences`, item 2). Each side's receipt states the digest and size of its own workbook, replay
// script and request. A negative control fails each of the two compares. Nothing is declared, so the old writer goes
// in the lane with no key (R-A1, C4).
//
// Each case root sits five folders below the temporary folder (SCR/lanes/12.31/12.31-cancel.md). The cancel runs
// through the real transport. The leaf holds inside its transaction on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's
// Cancel stops it, and no workbook, receipt or `<out>.export-<UUID>/` folder is left (condition 7, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishGenotypeUI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class WorkbookExportParityFailureCalls {
    var messages: [String] = []
}

@MainActor
final class GenotypeWorkbookExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case oneCallWithThresholds
        case twoSamplesWithAQuickFilter
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let timestamp = "2026-10-18T00:00:00Z"
    static let outputName = "report.xlsx"

    private var scratch: URL!
    private var harness: RouteParityHarness!
    private var python: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "genotype-workbook-export-parity")
        python = try XCTUnwrap(Self.managedPython, "the managed openpyxl Python renders every side's workbook")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// One call, with the matrix and support thresholds the view applied.
    func testOneCallWithThresholdsMatches() async throws {
        let runs = try await assertParity(.oneCallWithThresholds)
        let c = try Self.receipt(in: runs.c.root)
        XCTAssertEqual((c["options"] as? [String: String])?["matrixMinimumReads"], "5")
    }

    /// Two samples under a quick filter, whose predicate the receipt keeps in plain text.
    func testTwoSamplesWithAQuickFilterMatches() async throws {
        let runs = try await assertParity(.twoSamplesWithAQuickFilter)
        let c = try Self.receipt(in: runs.c.root)
        XCTAssertNotNil((c["options"] as? [String: String])?["quickFilterPredicate"])
    }

    /// Condition 7 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with no
    /// alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the workbook, its receipt or the export folder.
    func testACancelledExportExits125AndLeavesNoWorkbookNoReceiptAndNoExportFolder() async throws {
        let root = Self.caseFolder(in: scratch).appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent(Self.outputName)
        let hold = root.appendingPathComponent("held")

        let failures = WorkbookExportParityFailureCalls()
        let started = try await GenotypeResultViewController.runWorkbookExport(
            snapshot: try Self.snapshot(for: .oneCallWithThresholds, bundleURL: fixtureBundleURL),
            outputURL: output,
            pythonURL: python,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) }
        let begun = try XCTUnwrap(started)
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        try Self.assertNothingLeft(in: root)

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(120),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        try Self.assertNothingLeft(in: root)
    }
}

// MARK: - The fixture

extension GenotypeWorkbookExportCLIGUIParityReplayTests {
    static var managedPython: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"].flatMap { folder in
            ["python3", "python"].map { home.appendingPathComponent("\(folder)/conda/envs/openpyxl/bin/\($0)") }
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The folder the case roots sit in, five folders below the temporary folder.
    static func caseFolder(in scratch: URL) -> URL {
        scratch.appendingPathComponent("cases/of/the/workbook", isDirectory: true)
    }

    /// The bundle every side's capture names, outside the case folder, so no side's record names another's root.
    var fixtureBundleURL: URL {
        scratch.appendingPathComponent("fixture/run.lungfishgenotype", isDirectory: true)
    }

    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent(outputName)
    }

    static func receipt(in root: URL) throws -> [String: Any] {
        let url = outputURL(in: root).appendingPathExtension("provenance.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The capture the coordinator freezes for a case before the save panel opens, with the view's filters, encoded
    /// as `captureExcelExportSnapshot` encodes it.
    static func snapshot(for parityCase: Case, bundleURL: URL) throws -> GenotypeViewportExportSnapshot {
        var calls = [GenotypeTestFixtures.makeCall(sample: "AnimalA", genotype: "Mafa-A*001", reads: 9)]
        var filters = [
            "matrixMinimumReads": "5",
            "matrixMinimumPercent": "0.0",
            "minimumSupportPercent": "7.5",
            "matrixMinimumPrevalencePercent": "0.0",
        ]
        if parityCase == .twoSamplesWithAQuickFilter {
            calls.append(GenotypeTestFixtures.makeCall(sample: "AnimalB", genotype: "Mafa-A*002", reads: 14))
            filters["quickFilter"] = "Sample is AnimalA"
            filters["quickFilterPredicate"] = #"{"field":"sample","value":"AnimalA"}"#
        }
        let result = GenotypeTestFixtures.makeResult(bundleURL: bundleURL, calls: calls)
        let capture = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil),
            filter: .init(matrixMinimumReads: 5))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return GenotypeViewportExportSnapshot(bundleURL: bundleURL, analysisName: "run", lens: "genotype",
            filters: filters, sampleNames: parityCase == .twoSamplesWithAQuickFilter ? ["AnimalA", "AnimalB"] : ["AnimalA"],
            rows: [], excelSnapshotData: try encoder.encode(capture))
    }

    /// No workbook, no receipt and no export folder in `root`.
    static func assertNothingLeft(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains(outputName), "a cancel leaves no workbook", file: file, line: line)
        XCTAssertFalse(names.contains(outputName + ".provenance.json"), "a cancel leaves no receipt", file: file, line: line)
        XCTAssertEqual(names.filter { $0.hasPrefix(outputName + ".export-") }, [], "a cancel leaves no export folder",
            file: file, line: line)
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

extension GenotypeWorkbookExportCLIGUIParityReplayTests {
    /// Side A. The in-app writer the view's Export to Excel ran before the leaf, frozen below.
    private func sideA(_ root: URL, snapshot: GenotypeViewportExportSnapshot) async throws -> RouteParitySideOutcome {
        do {
            try await Self.frozenExportExcel(
                snapshot: snapshot, to: Self.outputURL(in: root), python: python, replayExecutable: harness.cliBinary
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(Self.outputName)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `GenotypeViewportExportService.exportExcel` as it stood at a4cde2987, after the condition 6 fix, with the
    /// CLI that `LungfishCLIRunner.findCLI()` finds under `LUNGFISH_CLI_PATH` given as the built `lungfish-cli`.
    private static func frozenExportExcel(
        snapshot: GenotypeViewportExportSnapshot, to outputURL: URL, python: URL, replayExecutable: URL
    ) async throws {
        let capture = try GenotypeViewportExportService.decodedCapture(snapshot)
        let output = outputURL.standardizedFileURL
        let replacing = FileManager.default.fileExists(atPath: output.path)
        let result = try await GenotypeExcelExportService(pythonExecutableURL: python, replayExecutableURL: replayExecutable).export(
            snapshot: capture, outputURL: output,
            provenance: GenotypeViewportExportService.provenanceRequest(snapshot: snapshot, capture: capture,
                outputURL: output, python: python, replacingExisting: replacing,
                argv: ["Lungfish", "genotype.export.excel", "--captured-at", capture.generatedAt, "--output", output.path]), commandPath: GenotypeWorkbookExport.commandPath,
            replacingExisting: replacing)
        guard FileManager.default.fileExists(atPath: result.outputURL.path),
              FileManager.default.fileExists(atPath: result.receiptURL.path) else {
            throw GenotypeViewportExportError.missingProvenance(result.receiptURL.path)
        }
    }

    /// Side C. The view's run helper, which writes the capture and request and runs the built CLI behind the row on
    /// the shared runner. Its inputs folder is copied to root C' so side C' reads the files its command names.
    private func sideC(_ root: URL, snapshot: GenotypeViewportExportSnapshot) async throws -> RouteParitySideOutcome {
        let failures = WorkbookExportParityFailureCalls()
        guard let begun = try await GenotypeResultViewController.runWorkbookExport(
            snapshot: snapshot,
            outputURL: Self.outputURL(in: root),
            pythonURL: python,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        try RegionExtractionWithoutBundleParityReplayTests.copyStage(
            root.appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true), from: root
        )
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

extension GenotypeWorkbookExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.4 reads it.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let snapshot = try Self.snapshot(for: parityCase, bundleURL: fixtureBundleURL)
        let runs = try await harness.run(
            in: Self.caseFolder(in: scratch).appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { _ in },
            sideA: { root in try await self.sideA(root, snapshot: snapshot) },
            sideC: { root in try await self.sideC(root, snapshot: snapshot) }
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
        let harnessCAgainstCPrime = (found[.cAgainstCPrime] ?? []).filter { !Self.isComparedByThisClass($0) }
        XCTAssertEqual(harnessCAgainstCPrime.map(\.description), [], "C against C' declares nothing")
        for run in runs.all {
            try Self.assertDescriptorsMatchOwnFiles(in: run.root)
        }
        try assertAEqualsC(runs)
        try assertCEqualsCPrime(runs)
        try assertPredictedRecordChanges(runs)
        try assertNegativeControls(runs, parityCase: parityCase)
        return runs
    }

    /// How two sides' workbooks differ under the goldens' XLSX normalization (decision item 1).
    private func workbookDifferences(_ a: RouteParitySideRun, _ b: RouteParitySideRun) throws -> [String] {
        try Self.workbookDifferences(Self.outputURL(in: a.root), root: a.root, Self.outputURL(in: b.root), root: b.root,
            python: python)
    }

    /// C against C' on what the harness cannot pair. The workbook as A against C compares it, and the Excel service's
    /// folders paired by this class (decision items 1 and 2). The workbook's size is not compared across sides, since
    /// the zip holds run times and its deflated size moves by a byte between runs. `assertDescriptorsMatchOwnFiles`
    /// checks each side's recorded size against that side's own workbook instead.
    private func assertCEqualsCPrime(_ runs: RouteParityRuns) throws {
        XCTAssertEqual(try workbookDifferences(runs.c, runs.cPrime), [], "the workbook, C against C' (item 1)")
        XCTAssertEqual(try Self.exportFolderDifferences(runs.c.root, runs.cPrime.root), [],
            "the Excel service's folder, C against C' (item 2)")
    }

    /// Each compare fails on a change it must catch (decision items 1 and 2). One cell value changed in side C's
    /// workbook fails the workbook compare against side A, and one byte of side C''s request changed outside the root
    /// path fails the folder compare against side C. Run last, since the second control edits root C'.
    private func assertNegativeControls(_ runs: RouteParityRuns, parityCase: Case) throws {
        let controls = scratch.appendingPathComponent("controls/\(parityCase.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: controls, withIntermediateDirectories: true)
        let changed = controls.appendingPathComponent(Self.outputName)
        let part = try Self.runPython(python, script: Self.changeOneCellScript,
            arguments: [Self.outputURL(in: runs.c.root).path, changed.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cell = try Self.workbookDifferences(Self.outputURL(in: runs.a.root), root: runs.a.root, changed,
            root: runs.c.root, python: python)
        XCTAssertFalse(part.isEmpty)
        XCTAssertTrue(cell.contains("\(part) differs under xlsx_parts"), "one changed cell fails item 1's compare: \(cell)")

        let folder = try XCTUnwrap(try Self.exportFolders(in: runs.cPrime.root).values.first?.first)
        let request = folder.appendingPathComponent("request.json")
        var bytes = try Data(contentsOf: request)
        XCTAssertEqual(bytes.first, UInt8(ascii: "{"), "the changed byte is the request's first, outside the root path")
        bytes[bytes.startIndex] = UInt8(ascii: "[")
        try bytes.write(to: request)
        let folders = try Self.exportFolderDifferences(runs.c.root, runs.cPrime.root)
        XCTAssertEqual(folders.count, 1, "\(folders)")
        XCTAssertEqual(folders.first?.hasSuffix("/request.json differs at line 1: { | ["), true,
            "one changed byte fails item 2's compare: \(folders)")
    }

    /// A against C on the compare column of 1.4, with each path read relative to its side root.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(Self.outputName + ".provenance.json") && !$0.id.contains(Self.outputName + ".export-")
                && !$0.id.contains(ViewerExportSelection.inputsFolderName) && $0.id != Self.workbookDifferenceID
        }
        XCTAssertEqual(others.map(\.description), [], "only the workbook, the receipt, its export folder and the inputs may differ")
        XCTAssertEqual(try workbookDifferences(runs.a, runs.c), [], "the workbook under the goldens' XLSX normalization (item 1)")
        let a = try Self.receipt(in: runs.a.root)
        let c = try Self.receipt(in: runs.c.root)
        let witnesses = try XCTUnwrap(a["scientificInputWitnesses"] as? [String: String])
        XCTAssertEqual(witnesses, c["scientificInputWitnesses"] as? [String: String], "the scientific witnesses")
        // The snapshot is the same bytes on both sides. The workbook's digest and size are not compared across sides,
        // since its zip holds run times and its deflated size moves by a byte between runs. The descriptor checks of
        // `assertDescriptorsMatchOwnFiles` read each side's recorded digest and size against that side's own workbook.
        let snapshotA = try XCTUnwrap(a["snapshot"] as? [String: Any])
        let snapshotC = try XCTUnwrap(c["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshotA["sha256"] as? String, snapshotC["sha256"] as? String, "snapshot sha256")
        XCTAssertEqual(snapshotA["sizeBytes"] as? Int, snapshotC["sizeBytes"] as? Int, "snapshot size")
        for key in ["generatedAt", "toolName", "toolKind", "workflowName", "toolVersion", "status"] {
            XCTAssertEqual(a[key] as? String, c[key] as? String, key)
        }
        XCTAssertEqual(a["replacingExisting"] as? Bool, false)
        XCTAssertEqual(a["replacingExisting"] as? Bool, c["replacingExisting"] as? Bool, "replacingExisting")
        for group in ["options", "resolvedDefaults", "runtimeContext"] {
            let groupA = try XCTUnwrap(a[group] as? [String: String])
            let groupC = try XCTUnwrap(c[group] as? [String: String])
            for (key, value) in groupA {
                XCTAssertEqual(Self.relative(groupC[key], under: runs.c.root), Self.relative(value, under: runs.a.root), "\(group).\(key)")
            }
        }
    }

    /// The prediction rows of the lane report (BIO 7, PLAN:371). The argv, the workflow name and the inputs move to
    /// the leaf's, the receipt gains the leaf's own keys, and the request the viewer wrote names no app tool.
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns) throws {
        let a = try Self.receipt(in: runs.a.root)
        let c = try Self.receipt(in: runs.c.root)
        let generatedAt = try XCTUnwrap(a["generatedAt"] as? String)
        XCTAssertEqual(a["argv"] as? [String], ["Lungfish", "genotype.export.excel", "--captured-at", generatedAt,
            "--output", Self.outputURL(in: runs.a.root).standardizedFileURL.path])
        XCTAssertEqual(a["requestWorkflowName"] as? String, GenotypeWorkbookExport.requestWorkflowName)
        XCTAssertEqual((a["inputs"] as? [Any])?.count, 0, "the in-app writer named no input")

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(2)), GenotypeWorkbookExport.commandPath)
        XCTAssertFalse(rowArguments.contains("--format"), "a result row runs without events")
        XCTAssertEqual(c["argv"] as? [String], [CLICommandIdentity.executableName] + rowArguments, "the receipt's argv is the row's command")
        XCTAssertEqual(c["requestWorkflowName"] as? String, "genotype.export.excel.replay")
        XCTAssertEqual(c["workflowName"] as? String, GenotypeExcelExportService.receiptWorkflowName(commandPath: GenotypeWorkbookExport.commandPath))
        XCTAssertEqual(c["toolName"] as? String, CLICommandIdentity.executableName)
        XCTAssertEqual(c["toolKind"] as? String, "cli")
        let context = try XCTUnwrap(c["runtimeContext"] as? [String: String])
        XCTAssertEqual(context["originalWorkflowName"], GenotypeWorkbookExport.requestWorkflowName)
        XCTAssertEqual(context["captureMode"], "durable-scientific-snapshot")
        let options = try XCTUnwrap(c["options"] as? [String: String])
        XCTAssertEqual(options["force"], "false")
        XCTAssertEqual(options["python"], python.standardizedFileURL.path)
        XCTAssertEqual(Self.relative(options["original.output"], under: runs.c.root), "/" + Self.outputName)
        let captureURL = URL(fileURLWithPath: try XCTUnwrap(options["snapshot"]))
        let requestURL = URL(fileURLWithPath: try XCTUnwrap(options["provenanceRequest"]))
        let inputs = try XCTUnwrap(c["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.compactMap { $0["path"] as? String }, [captureURL.path, requestURL.path], "the two files the leaf read")
        for input in inputs {
            let path = try XCTUnwrap(input["path"] as? String)
            XCTAssertEqual(input["sha256"] as? String, Self.digest(try Data(contentsOf: URL(fileURLWithPath: path))), path)
        }
        XCTAssertEqual(inputs.first?["sha256"] as? String, (c["snapshot"] as? [String: Any])?["sha256"] as? String, "condition 1")
        let request = try JSONDecoder().decode(GenotypeExcelExportService.ProvenanceRequest.self, from: Data(contentsOf: requestURL))
        XCTAssertEqual(request.workflowName, GenotypeWorkbookExport.requestWorkflowName)
        XCTAssertEqual(request.argv, c["argv"] as? [String], "the request records the row's command (condition 3)")
        XCTAssertFalse(request.argv.contains("Lungfish"))
        XCTAssertEqual(request.options["annotationsSource"],
            "the sidecar the viewer held at capture, not read from the bundle's annotations.json")
        for receipt in [a, c] {
            let first = try XCTUnwrap((receipt["durableReplayArgv"] as? [String])?.first)
            XCTAssertEqual(URL(fileURLWithPath: first).lastPathComponent, CLICommandIdentity.executableName)
        }
    }

    static func relative(_ path: String?, under root: URL) -> String? {
        guard let path else { return nil }
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        return rootPaths.first { path.hasPrefix($0 + "/") }.map { String(path.dropFirst($0.count)) } ?? path
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
