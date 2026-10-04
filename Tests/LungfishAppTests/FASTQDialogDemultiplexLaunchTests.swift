// FASTQDialogDemultiplexLaunchTests.swift - Demultiplex Barcodes run from the FASTQ operations dialog writes its barcode bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog runs Demultiplex Barcodes through
// `runFASTQOperationLaunchRequestValidated`. The run's folder comes from
// `uniqueFASTQOperationOutputDirectory` under the dialog's output directory,
// the planner makes that folder the demultiplex output, and
// `FASTQOperationExecutionService` resolves the input, runs
// `lungfish-cli fastq demultiplex` and hands the folder to
// `BundleFASTQOperationImporter`. Each test takes those steps in that order,
// with the request the dialog builds and the real subcommand in this process
// (`DialogRowInProcessCLIRunner`), on a physical bundle and on a virtual
// subset, with the dialog's default cutadapt engine. The tests skip when the
// managed cutadapt (and, for the subset, seqkit) is not installed.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQDialogDemultiplexLaunchTests: XCTestCase {
    private static let bc01 = "ACGTTGCAAGTC"
    private static let bc02 = "TTGACCGATGCA"
    private static let insert = "GATTACAGATTACAGATTACA"
    /// Six reads carry BC01 and four carry BC02 at the 5' end.
    private static let bc01IDs = (1...6).map { "r\($0)" }
    private static let bc02IDs = (7...10).map { "r\($0)" }
    /// The virtual subset holds three BC01 reads and two BC02 reads.
    private static let subsetBC01IDs = ["r2", "r3", "r5"]
    private static let subsetBC02IDs = ["r8", "r9"]

    /// A project that holds a physical bundle and a virtual subset of it, and a barcode CSV.
    private struct Fixture {
        let scratch: URL
        let project: URL
        let physicalBundle: URL
        let virtualSubset: URL
        let kitCSV: URL
    }

    private func makeFixture() throws -> Fixture {
        // The physical path (/private/var, not /var), which the input
        // resolvers and the CLI use, so the paths the test compares agree.
        let made = try TestTempDirectory.make(prefix: "fastq-dialog-demultiplex")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        let scratch = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        addTeardownBlock { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)

        let physicalBundle = imports.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalBundle, withIntermediateDirectories: true)
        let reads = Self.bc01IDs.map { (id: $0, sequence: Self.bc01 + Self.insert) }
            + Self.bc02IDs.map { (id: $0, sequence: Self.bc02 + Self.insert) }
        try FASTQOperationTestHelper.writeFASTQ(records: reads, to: physicalBundle.appendingPathComponent("Sample.fastq"))

        let subsetIDs = Self.subsetBC01IDs + Self.subsetBC02IDs
        let virtualSubset = imports.appendingPathComponent("Subset.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: virtualSubset, withIntermediateDirectories: true)
        try subsetIDs.joined(separator: "\n").appending("\n")
            .write(to: virtualSubset.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try FASTQOperationTestHelper.writeFASTQ(
            records: reads.filter { subsetIDs.contains($0.id) },
            to: virtualSubset.appendingPathComponent("preview.fastq")
        )
        let operation = FASTQDerivativeOperation(kind: .searchText, query: "r")
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "Subset",
                parentBundleRelativePath: "@/Imports/Sample.lungfishfastq",
                rootBundleRelativePath: "@/Imports/Sample.lungfishfastq",
                rootFASTQFilename: "Sample.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: subsetIDs.count, baseCount: Int64(subsetIDs.count * 33)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: virtualSubset
        )

        let kitCSV = scratch.appendingPathComponent("barcodes.csv")
        try "id,sequence\nBC01,\(Self.bc01)\nBC02,\(Self.bc02)\n"
            .write(to: kitCSV, atomically: true, encoding: .utf8)
        return Fixture(
            scratch: scratch,
            project: project,
            physicalBundle: physicalBundle,
            virtualSubset: virtualSubset,
            kitCSV: kitCSV
        )
    }

    private func requireTools(seqkit: Bool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        if seqkit, !(await NativeToolRunner.shared.isToolAvailable(.seqkit)) {
            try ToolAvailability.skipOrFail("managed seqkit is not installed (the subset is materialized with it)")
        }
    }

    /// What one dialog run left behind.
    private struct DialogRun {
        let outputDirectory: URL
        let result: FASTQOperationExecutionResult
        let commandAtBegin: String
        let rowCommand: String?
    }

    /// Builds the request with the dialog's state, as Run does, then takes the
    /// launch site's steps: the output root, the run's folder, the row, the
    /// run and the row's refinement.
    private func runDemultiplexFromTheDialog(
        on input: URL,
        in fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DialogRun {
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [input],
            projectURL: fixture.project
        )
        state.selectTool(.demultiplexBarcodes)
        state.demultiplexBarcodeSource = .customDefinition
        state.setAuxiliaryInput(fixture.kitCSV, for: .barcodeDefinition)
        state.prepareForRun()
        XCTAssertTrue(state.isRunEnabled, file: file, line: line)
        let launch = try XCTUnwrap(state.pendingLaunchRequest, file: file, line: line)
        guard case .derivative(.demultiplex(_, _, _, _, _, _, _, let engine, _, _, _), let inputs, _) = launch else {
            XCTFail("the dialog builds a demultiplex request, got \(launch)", file: file, line: line)
            throw CocoaError(.featureUnsupported)
        }
        XCTAssertEqual(engine, .cutadapt, "the dialog's default engine", file: file, line: line)
        XCTAssertEqual(inputs, [input], file: file, line: line)
        XCTAssertTrue(launch.isDemultiplexRequest, file: file, line: line)

        // runFASTQOperationLaunchRequest(_:preferredOutputDirectory:) with the
        // dialog's output directory, then the demultiplex branch of
        // runFASTQOperationLaunchRequestValidated.
        let destinationRoot = try XCTUnwrap(state.outputDirectoryURL, file: file, line: line).standardizedFileURL
        XCTAssertEqual(
            destinationRoot,
            fixture.project.appendingPathComponent("Analyses", isDirectory: true).standardizedFileURL,
            file: file, line: line
        )
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let workingDirectory = MainSplitViewController().uniqueFASTQOperationOutputDirectory(
            in: destinationRoot,
            request: launch
        )
        let service = FASTQOperationExecutionService(
            commandRunner: DialogRowInProcessCLIRunner(),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destinationRoot)
        )
        XCTAssertEqual(
            FASTQOperationPlanner().executionOutputDirectory(for: launch, workingDirectory: workingDirectory),
            workingDirectory,
            "the run's folder is the demultiplex output",
            file: file, line: line
        )

        let reporter = RecordingOperationReporter()
        let id = try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(launch.operationDisplayTitle)",
            request: launch,
            executionService: service,
            routeContext: nil,
            reporter: reporter
        ) { _ in }.requireStarted()
        let commandAtBegin = try XCTUnwrap(reporter.items.first?.cliCommand, file: file, line: line)

        let result = try await service.execute(request: launch, workingDirectory: workingDirectory)
        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)
        return DialogRun(
            outputDirectory: workingDirectory,
            result: result,
            commandAtBegin: commandAtBegin,
            rowCommand: reporter.items.first?.cliCommand
        )
    }

    /// The read identifiers a barcode bundle holds, physical or virtual.
    private func readIDs(
        inBarcodeBundle bundle: URL,
        scratch: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        let payload: URL
        if FASTQBundle.isDerivedBundle(bundle) {
            payload = scratch.appendingPathComponent("barcode-\(UUID().uuidString).fastq")
            try await FASTQDerivativeService.shared.exportMaterializedFASTQ(fromDerivedBundle: bundle, to: payload)
        } else {
            payload = try XCTUnwrap(
                FASTQBundle.resolvePrimaryFASTQURL(for: bundle),
                "the reads of \(bundle.lastPathComponent)",
                file: file, line: line
            )
        }
        return try await FASTQOperationTestHelper.loadFASTQRecords(from: payload).map(\.identifier)
    }

    /// Checks the run's barcode bundles, its staging and its row.
    private func assertTheRun(
        _ run: DialogRun,
        input: URL,
        in fixture: Fixture,
        assigns expected: [String: [String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertEqual(run.result.importedURLs, [run.outputDirectory], "the dialog opens the run's folder", file: file, line: line)
        let manifest = try XCTUnwrap(
            DemultiplexManifest.load(from: run.outputDirectory),
            "a demux manifest in \(run.outputDirectory.path)",
            file: file, line: line
        )
        XCTAssertEqual(manifest.inputReadCount, expected.values.map(\.count).reduce(0, +), file: file, line: line)
        XCTAssertEqual(manifest.unassigned.readCount, 0, file: file, line: line)
        for (barcodeID, ids) in expected {
            let barcode = try XCTUnwrap(manifest.barcodes.first { $0.barcodeID == barcodeID }, barcodeID, file: file, line: line)
            XCTAssertEqual(barcode.readCount, ids.count, barcodeID, file: file, line: line)
            let bundle = run.outputDirectory.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let held = try await readIDs(inBarcodeBundle: bundle, scratch: fixture.scratch, file: file, line: line)
            XCTAssertEqual(Set(held), Set(ids), "the reads of \(barcodeID)", file: file, line: line)
            XCTAssertEqual(held.count, ids.count, barcodeID, file: file, line: line)
        }

        // The resolved input is staged for the run only. No staging folder is
        // left in the project, in the run's folder or beside it.
        let leftovers = (FileManager.default.subpaths(atPath: fixture.project.path) ?? [])
            .filter { $0.split(separator: "/").contains { $0.hasPrefix("materialized-inputs-") } }
        XCTAssertEqual(leftovers, [], "staging left in the project", file: file, line: line)

        // The row keeps the command recorded at launch, which names the
        // dialog's input, never a staging path.
        XCTAssertEqual(run.rowCommand, run.commandAtBegin, file: file, line: line)
        XCTAssertTrue(run.commandAtBegin.hasPrefix("lungfish-cli fastq demultiplex "), run.commandAtBegin, file: file, line: line)
        XCTAssertTrue(run.commandAtBegin.contains(input.path), run.commandAtBegin, file: file, line: line)
        XCTAssertFalse(run.commandAtBegin.contains("materialized-inputs-"), run.commandAtBegin, file: file, line: line)
    }

    func testDemultiplexingAPhysicalBundleFromTheDialogWritesItsBarcodeBundles() async throws {
        try await requireTools(seqkit: false)
        let fixture = try makeFixture()
        let run = try await runDemultiplexFromTheDialog(on: fixture.physicalBundle, in: fixture)
        try await assertTheRun(
            run,
            input: fixture.physicalBundle,
            in: fixture,
            assigns: ["BC01": Self.bc01IDs, "BC02": Self.bc02IDs]
        )
    }

    func testDemultiplexingAVirtualBundleFromTheDialogWritesTheBarcodeBundlesOfItsReads() async throws {
        try await requireTools(seqkit: true)
        let fixture = try makeFixture()
        let run = try await runDemultiplexFromTheDialog(on: fixture.virtualSubset, in: fixture)
        try await assertTheRun(
            run,
            input: fixture.virtualSubset,
            in: fixture,
            assigns: ["BC01": Self.subsetBC01IDs, "BC02": Self.subsetBC02IDs]
        )
    }
}
