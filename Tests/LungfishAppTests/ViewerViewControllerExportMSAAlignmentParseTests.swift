// ViewerViewControllerExportMSAAlignmentParseTests.swift - exportMSAAlignment records a command the CLI parses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.20 (QR-a). `ViewerViewController.exportMSAAlignment` (ViewerViewController+MSAExport.swift)
// begins an Operations row for every alignment export and runs the command it records. Each test runs the real
// method against a stand-in `lungfish-cli` (BeginSiteCLIStandIn), reads the command off the row, parses it with
// the real `msa export` or `msa extract` leaf, and compares the parsed values with the request.

import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class ViewerViewControllerExportMSAAlignmentParseTests: XCTestCase {
    private var root: URL!
    private var standIn: BeginSiteCLIStandIn!

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "viewer-export-msa-alignment")
        standIn = BeginSiteCLIStandIn(root: root)
    }

    override func tearDown() async throws {
        standIn.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// The row one real `exportMSAAlignment` call began, with the bundle and the output it named.
    private struct Run {
        let row: OperationCenter.Item
        let bundle: URL
        let output: URL
    }

    private func export(
        outputName: String,
        destination: MSAExportDestination,
        layout: MSAExportLayout = .aligned,
        format: String = "aligned-fasta",
        scope: MSAExportScope = .entireAlignment,
        exportName: String = "Exported alignment",
        rows: String? = nil,
        columns: String? = nil
    ) async throws -> Run {
        let bundle = root.appendingPathComponent(
            "Project.lungfish/Multiple Sequence Alignments/Spike alignment.lungfishmsa",
            isDirectory: true
        )
        let output = root.appendingPathComponent("Exports/\(outputName)")
        let configuration = MSAAlignmentExportConfiguration(
            destination: destination,
            layout: layout,
            format: format,
            scope: scope,
            name: exportName
        )
        let viewer = ViewerViewController()
        let capture = try await standIn.capture {
            viewer.exportMSAAlignment(
                bundleURL: bundle,
                configuration: configuration,
                outputURL: output,
                rows: rows,
                columns: columns
            )
        }
        XCTAssertEqual(capture.rows.count, 1, "one export begins one row")
        let row = try XCTUnwrap(capture.rows.first, "the export began no row")
        XCTAssertEqual(row.operationType, .multipleSequenceAlignmentAction)
        XCTAssertEqual(row.targetBundleURL?.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(
            capture.launchedArguments,
            try RecordedCLICommand.arguments(of: row.cliCommand),
            "the runner launched the arguments the row records"
        )
        return Run(row: row, bundle: bundle, output: output)
    }

    func testSaveToFileOfTheEntireAlignmentRecordsAnMSAExportTheCLIParses() async throws {
        let run = try await export(
            outputName: "spike alignment.phy",
            destination: .file,
            format: "phylip",
            rows: "r1,r2",
            columns: "10-40"
        )
        XCTAssertEqual(run.row.title, "Export Alignment")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: MSACommand.ExportSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.path)
        XCTAssertEqual(parsed.outputFormat, "phylip")
        XCTAssertEqual(parsed.outputPath, run.output.path)
        XCTAssertNil(parsed.rows, "an export of the entire alignment sends no row subset")
        XCTAssertNil(parsed.columns, "an export of the entire alignment sends no column subset")
        XCTAssertTrue(parsed.force)
    }

    func testSaveToFileOfTheSelectionRecordsAnMSAExportWithItsRowsAndColumns() async throws {
        let run = try await export(
            outputName: "selection.fasta",
            destination: .file,
            format: "aligned-fasta",
            scope: .selectedRows,
            rows: "r2,r5",
            columns: "10-40,55"
        )
        XCTAssertEqual(run.row.title, "Export Alignment")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: MSACommand.ExportSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.path)
        XCTAssertEqual(parsed.outputFormat, "aligned-fasta")
        XCTAssertEqual(parsed.outputPath, run.output.path)
        XCTAssertEqual(parsed.rows, "r2,r5")
        XCTAssertEqual(parsed.columns, "10-40,55")
        XCTAssertTrue(parsed.force)
    }

    func testSaveAsAlignedBundleRecordsAnMSAExtractToAnMSABundle() async throws {
        let run = try await export(
            outputName: "Spike subset.lungfishmsa",
            destination: .bundle,
            layout: .aligned,
            scope: .selectedRows,
            exportName: "Spike subset",
            rows: "r2,r5",
            columns: "10-40"
        )
        XCTAssertEqual(run.row.title, "Create Alignment Bundle")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: MSACommand.ExtractSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.path)
        XCTAssertEqual(parsed.outputKind, MSAExportLayout.aligned.bundleOutputKind)
        XCTAssertEqual(parsed.outputKind, "msa")
        XCTAssertEqual(parsed.outputPath, run.output.path)
        XCTAssertEqual(parsed.name, "Spike subset")
        XCTAssertEqual(parsed.rows, "r2,r5")
        XCTAssertEqual(parsed.columns, "10-40")
        XCTAssertTrue(parsed.force)
    }

    func testSaveAsUnalignedBundleRecordsAnMSAExtractToAReferenceBundle() async throws {
        let run = try await export(
            outputName: "Spike sequences.lungfishref",
            destination: .bundle,
            layout: .unaligned,
            exportName: "Spike sequences",
            rows: "r1",
            columns: "1-5"
        )
        XCTAssertEqual(run.row.title, "Create Alignment Bundle")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: MSACommand.ExtractSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.path)
        XCTAssertEqual(parsed.outputKind, MSAExportLayout.unaligned.bundleOutputKind)
        XCTAssertEqual(parsed.outputKind, "reference")
        XCTAssertEqual(parsed.outputPath, run.output.path)
        XCTAssertEqual(parsed.name, "Spike sequences")
        XCTAssertNil(parsed.rows, "an export of the entire alignment sends no row subset")
        XCTAssertNil(parsed.columns, "an export of the entire alignment sends no column subset")
    }

    func testCopyToClipboardRecordsAnMSAExportToTheRetainedFile() async throws {
        let run = try await export(
            outputName: "clipboard.fasta",
            destination: .clipboard,
            format: "aligned-fasta"
        )
        XCTAssertEqual(run.row.title, "Copy Alignment")
        let parsed = try RecordedCLICommand.parse(run.row.cliCommand, as: MSACommand.ExportSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, run.bundle.path)
        XCTAssertEqual(parsed.outputFormat, "aligned-fasta")
        XCTAssertEqual(parsed.outputPath, run.output.path)
        XCTAssertNil(parsed.rows)
        XCTAssertNil(parsed.columns)
        XCTAssertTrue(parsed.force)
    }
}
