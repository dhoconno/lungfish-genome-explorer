// GenotypeManualDefinitionsExportCLIGUIParityReplayTests.swift - The manual definitions export in the app against its leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 M2, ARCH ruling on the export shape 1.7 and row A14, BIO answer to Q-A3, on lane Q30's
// harness. Each case runs on three sides that start as copies of one genotype bundle whose saved sidecar holds the
// manual assignments of scenario B (`GenotypeCharacterizationScenarios.makeGenotypeOnlyManualScenario`).
//
// - Side A is the in-app writer, `exportManualDefinitions` and `writeManualDefinitionsExport` as the view held them
//   at 898cbd050, frozen in this file since the lane deletes them from the view. It reads the store's assignments,
//   which for a saved store are the sidecar's.
// - Side C is the view's begin helper, `runManualDefinitionsExport`, given the same assignments. It writes the
//   selection file, begins the row and runs the built `lungfish-cli genotype export-manual-definitions` on
//   `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with side C's selection folder copied to
//   root C' as the region extraction parity class copies its stage.
//
// A against C compares the payload byte for byte, the output's digest and size, and the `resolved` and `defaults`
// keys and the bundle and output options, with no file but the record and the selection folder differing. The
// five identity fields, the inputs (the sidecar the writer never opened on A, the selection file on C) and the
// `selection` option are prediction rows of the lane report (BIO 7), pinned on each side by
// `assertPredictedRecordChanges`. C against C' compares everything under the contract's masks. Nothing is declared,
// so the old writer goes in the lane with no key (R-A1, C4).
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

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
private final class ManualDefinitionsExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class GenotypeManualDefinitionsExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case scenarioBFiveAssignments
        case aReplacedAssignment
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let bundleRelativePath = "Project/Analyses/run/manual.lungfishgenotype"
    /// The output digest `GenotypeManualDefinitionsExportPinTests` pins for scenario B at the base.
    static let scenarioBPayloadDigest = "0ec3211c0efef9500f2d53e7e625db173c5adf28b2b8aa6e50dcec896a40b675"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "manual-definitions-export-parity")
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

    /// Scenario B's five assignments, the label the validator rejects included, which the index keeps.
    func testScenarioBFiveAssignmentsMatches() async throws {
        let runs = try await assertParity(.scenarioBFiveAssignments)
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(c.output?.checksumSHA256, Self.scenarioBPayloadDigest, "the bytes pinned at the base")
        XCTAssertEqual(c.options.resolvedDefaults["assignmentCount"]?.integerValue, 5)
    }

    /// A sixth assignment for the slot of the first, so the index drops the one it replaces on both sides, and the
    /// leaf reads the raw order from the selection file.
    func testAReplacedAssignmentMatches() async throws {
        let runs = try await assertParity(.aReplacedAssignment)
        let raw = Self.assignments(for: .aReplacedAssignment)
        let current = GenotypeManualDefinitionsExport.currentAssignments(raw)
        XCTAssertLessThan(current.count, raw.count, "the case replaces an assignment")
        let c = try Self.envelope(in: runs.c.root)
        XCTAssertEqual(c.options.resolvedDefaults["assignmentCount"]?.integerValue, current.count)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cases/of/the/manual/cancel", isDirectory: true)
        XCTAssertGreaterThanOrEqual(root.pathComponents.count - FileManager.default.temporaryDirectory.pathComponents.count, 5, "the case root sits at least five folders below the temporary folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root, case: .scenarioBFiveAssignments)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")

        let failures = ManualDefinitionsExportFailureCalls()
        let begun = try XCTUnwrap(try GenotypeResultViewController.runManualDefinitionsExport(
            assignments: try Self.savedAssignments(in: root),
            bundleURL: Self.bundleURL(in: root),
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

extension GenotypeManualDefinitionsExportCLIGUIParityReplayTests {
    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent(bundleRelativePath, isDirectory: true)
    }

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent("manual-haplotype-definitions.json")
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The raw assignments of a case, in the sidecar's order. Scenario B's five come first.
    static func assignments(for parityCase: Case) -> [ManualHaplotypeAssignment] {
        var assignments: [ManualHaplotypeAssignment] = [
            .init(sample: "AnimalA", locus: "MHC-A", slot: .h1, label: "M1A", colorTokenIndex: 0, diagnosticAlleles: ["01_Mafa_A1_001_01"], notes: "Pedigree confirmed"),
            .init(sample: "AnimalA", locus: "MHC-A", slot: .h2, label: "M2A", colorTokenIndex: 1, diagnosticAlleles: ["02_Mafa_A1_002_01"], notes: ""),
            .init(sample: "AnimalA", locus: "MHC-B", slot: .h1, label: "M1B", colorTokenIndex: 2, diagnosticAlleles: ["03_Mafa_B_075_01"], notes: ""),
            .init(sample: "AnimalB", locus: "MHC-A", slot: .h1, label: "M3A", colorTokenIndex: 3, diagnosticAlleles: [], notes: "Provisional"),
            .init(sample: "AnimalB", locus: "MHC-B", slot: .h2, label: "bad\nlabel", colorTokenIndex: 4, diagnosticAlleles: [], notes: "Rejected by the validator"),
        ]
        if parityCase == .aReplacedAssignment {
            assignments.append(
                .init(sample: "AnimalA", locus: "MHC-A", slot: .h1, label: "M9A", colorTokenIndex: 5, diagnosticAlleles: ["01_Mafa_A1_001_01"], notes: "Revised")
            )
        }
        return assignments
    }

    /// A genotype bundle whose saved sidecar holds the case's assignments.
    static func makeFixture(_ root: URL, case parityCase: Case) throws {
        let bundle = bundleURL(in: root)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-01T00:00:00Z")
        sidecar.manualHaplotypeAssignments = assignments(for: parityCase)
        try sidecar.encoded().write(to: bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename))
    }

    /// The assignments a saved store holds, which are its sidecar's (`store.sidecar.manualHaplotypeAssignments`).
    static func savedAssignments(in root: URL) throws -> [ManualHaplotypeAssignment] {
        let data = try Data(contentsOf: bundleURL(in: root).appendingPathComponent(GenotypeAnnotationSidecar.filename))
        return try GenotypeAnnotationSidecar.decode(data).manualHaplotypeAssignments
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

extension GenotypeManualDefinitionsExportCLIGUIParityReplayTests {
    /// Side A. The in-app writer the view's Export ran before the leaf, frozen below.
    private func sideA(_ root: URL) throws -> RouteParitySideOutcome {
        do {
            try Self.frozenExportManualDefinitions(
                bundleURL: Self.bundleURL(in: root), rawAssignments: try Self.savedAssignments(in: root), url: Self.outputURL(in: root)
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported manual-haplotype-definitions.json")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// The save panel's completion of `exportManualDefinitions` and `writeManualDefinitionsExport` as
    /// `GenotypeResultViewController` held them at 898cbd050, with the store's `bundleURL` and sidecar assignments
    /// passed in.
    private static func frozenExportManualDefinitions(
        bundleURL: URL,
        rawAssignments: [ManualHaplotypeAssignment],
        url: URL
    ) throws {
        let assignments = GenotypeManualHaplotypeAssignmentIndex(assignments: rawAssignments).currentAssignments
        let runClock = ProvenanceRunClock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(assignments)
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let annotationExists = FileManager.default.fileExists(atPath: annotationURL.path)
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app manual haplotype definition export",
            toolName: "Lungfish Genome Explorer",
            toolKind: "gui",
            sourceURLs: annotationExists ? [annotationURL] : [],
            outputURL: url,
            outputFormat: .json,
            argv: [
                "Lungfish Genome Explorer",
                "export-manual-haplotype-definitions",
                "--bundle", bundleURL.path,
                "--output", url.path,
            ],
            explicitOptions: [
                "bundle": .file(bundleURL),
                "output": .file(url),
            ],
            defaults: [
                "format": .string("json"),
            ],
            resolved: [
                "assignmentCount": .integer(assignments.count),
            ],
            runClock: runClock
        )) { staged in
            try data.write(to: staged, options: .atomic)
        }
    }

    /// Side C. The view's run helper, which writes the selection file and runs the built CLI behind the row on the
    /// shared runner. Its selection folder is copied to root C' so side C' reads the file its command names.
    private func sideC(_ root: URL) async throws -> RouteParitySideOutcome {
        let failures = ManualDefinitionsExportFailureCalls()
        guard let begun = try GenotypeResultViewController.runManualDefinitionsExport(
            assignments: try Self.savedAssignments(in: root),
            bundleURL: Self.bundleURL(in: root),
            outputURL: Self.outputURL(in: root),
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

extension GenotypeManualDefinitionsExportCLIGUIParityReplayTests {
    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("cases/of/the/manual/\(parityCase.rawValue)", isDirectory: true),
            fixture: { root in try Self.makeFixture(root, case: parityCase) },
            sideA: { root in try self.sideA(root) },
            sideC: { root in try await self.sideC(root) }
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

    /// A against C on the facts of 1.7, with each path read relative to its side root. No file but the record and
    /// side C's selection folder differs, and the record's compared facts are equal.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(ViewerExportSelection.inputsFolderName)
        }
        XCTAssertEqual(others.map(\.description), [], "only the record and the selection may differ between A and C")

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
        XCTAssertEqual(a.options.resolvedDefaults, c.options.resolvedDefaults, "resolved assignmentCount")
        XCTAssertEqual(a.options.defaults, c.options.defaults, "default format")
        for key in ["bundle", "output"] {
            XCTAssertEqual(
                Self.relativeFile(a.options.explicit[key], under: runs.a.root),
                Self.relativeFile(c.options.explicit[key], under: runs.c.root),
                "explicit \(key)"
            )
        }
    }

    /// The prediction rows of the lane report (BIO 7). The five identity fields move from the app's writer to the
    /// leaf, the input moves from the sidecar the writer never opened to the selection file it reads, and the
    /// options gain `selection`. The record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns) throws {
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let argvA = [
            "Lungfish Genome Explorer", "export-manual-haplotype-definitions",
            "--bundle", Self.bundleURL(in: runs.a.root).path, "--output", Self.outputURL(in: runs.a.root).path,
        ]
        XCTAssertEqual(a.toolName, "Lungfish Genome Explorer")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app manual haplotype definition export")
        XCTAssertEqual(a.options.explicit.keys.sorted(), ["bundle", "output"])
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root).keys.sorted(), ["/\(Self.bundleRelativePath)/annotations.json"])

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, GenotypeManualDefinitionsExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["bundle", "output", "selection"])
        let inputsC = Self.inputs(of: c, under: runs.c.root).keys.sorted()
        XCTAssertEqual(inputsC.count, 1, "the selection file is the leaf's one input")
        XCTAssertTrue(inputsC.allSatisfy { $0.hasPrefix("/\(ViewerExportSelection.inputsFolderName)/") && $0.hasSuffix("/selection.json") }, "\(inputsC)")
        XCTAssertEqual(
            Self.relativeFile(c.options.explicit["selection"], under: runs.c.root), inputsC.first,
            "the option names the input"
        )
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
