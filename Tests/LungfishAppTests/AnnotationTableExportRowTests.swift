// AnnotationTableExportRowTests.swift - The Operations row of the annotation table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling 1.5 rule 3 and the ARCH ruling on 12.39 R1. `AnnotationTableDrawerView`'s
// `beginAnnotationTableExportOperation` begins an export row with no lock and a cancel callback, records the
// `bundle export-annotation-table` command the runner runs, and launches nothing when the row is refused. The
// collected rows reach the leaf in a selection file written before the row begins, and a row no database stores is
// refused before anything is written (R1 item 7).

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishWorkflow

@MainActor
final class AnnotationTableExportRowTests: XCTestCase {
    private let leafInvocation = AnnotationTableExport.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.39/Reference, one.lungfishref", isDirectory: true),
        tab: .variants,
        format: .tsv,
        selectionURL: URL(fileURLWithPath: "/tmp/lane 12.39/.lungfish-export-inputs/one/selection.json"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.39/variants, all.tsv"),
        force: true
    )

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AnnotationTableDrawerView.beginAnnotationTableExportOperation(
            invocation: leafInvocation,
            rowCount: 2,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Variants Table")
        XCTAssertEqual(item.initialDetail, "Writing 2 rows to variants, all.tsv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: BundleExportAnnotationTableSubcommand.self)
        XCTAssertEqual(command.invocation(), leafInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.39/Reference, one.lungfishref")
        XCTAssertEqual(command.tab.tab, .variants)
        XCTAssertEqual(command.format.format, .tsv)
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = AnnotationTableDrawerView.beginAnnotationTableExportOperation(
            invocation: leafInvocation,
            rowCount: 1,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: BundleExportAnnotationTableSubcommand.self)
        XCTAssertEqual(command.invocation(), leafInvocation)
    }

    /// R1 items 1 to 3. The collected rows' identities in order, the sample tab's visible flags and display names,
    /// and the snapshot's scope and query go to a selection file in a new inputs folder beside the output.
    func testTheCollectedRowsGoToASelectionFileBeforeTheRow() throws {
        let rows = [
            AnnotationTableSampleRow(rowKey: "S2|b.vcf", name: "S2", sourceFile: "b.vcf", isVisible: false, metadata: [:]),
            AnnotationTableSampleRow(
                rowKey: "S1|a.vcf", name: "S1", sourceFile: "a.vcf", isVisible: true, metadata: [:], displayName: "First"
            ),
        ]
        let columns = [ScientificTableColumn(id: "SampleNameColumn", title: "Sample")]
        let snapshot = AnnotationTableExportSnapshot.captureSamples(
            rows, columns: columns, scope: .allMatching, sourceURLs: [], queryDescription: ["sort": "name:ascending"]
        )
        let bundle = folder.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let output = folder.appendingPathComponent("samples.csv")
        let invocation = try AnnotationTableDrawerView.annotationTableExportInvocation(
            snapshot: snapshot, bundleURL: bundle,
            tableSelection: AnnotationTableExportSelection(scope: "", columns: columns),
            editedValues: AnnotationTableDrawerView.sampleEditedValues(rows),
            format: .csv, outputURL: output
        )

        XCTAssertEqual(invocation.input, bundle.standardizedFileURL.path)
        XCTAssertEqual(invocation.tab, "samples")
        XCTAssertEqual(invocation.outputFormat, "csv")
        XCTAssertTrue(invocation.force, "the save panel confirmed a replace")
        let path = try XCTUnwrap(invocation.selection)
        XCTAssertTrue(path.hasPrefix(folder.standardizedFileURL.path + "/.lungfish-export-inputs/"), path)
        let selection = try ViewerExportSelection.read(from: URL(fileURLWithPath: path))
        XCTAssertEqual(selection.schemaVersion, 2)
        XCTAssertEqual(selection.identities, ["S2|b.vcf", "S1|a.vcf"])
        XCTAssertEqual(selection.editedValues, [
            "S2|b.vcf": ["visible": "false"],
            "S1|a.vcf": ["visible": "true", "displayName": "First"],
        ])
        XCTAssertEqual(selection.annotationTable?.scope, "allMatching")
        XCTAssertEqual(selection.annotationTable?.query, ["sort": "name:ascending"])
        XCTAssertEqual(selection.annotationTable?.columns, columns)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the helper writes no output")
    }

    /// R1 item 7. A row with no database row id is refused under "Export Failed" with the ruling's words, before
    /// any file is written.
    func testARowNoDatabaseStoresIsRefusedBeforeAnythingIsWritten() throws {
        let row = AnnotationSearchResult(
            name: "unsaved", chromosome: "chr1", start: 1, end: 9, trackId: "genes", trackName: "Genes",
            type: "gene", strand: "+", attributes: nil, annotationRowId: nil
        )
        let columns = [ScientificTableColumn(id: "NameColumn", title: "Name")]
        let snapshot = AnnotationTableExportSnapshot.captureAnnotations(
            [row], columns: columns, scope: .selected, sourceURLs: [], queryDescription: [:]
        )
        XCTAssertThrowsError(try AnnotationTableDrawerView.annotationTableExportInvocation(
            snapshot: snapshot, bundleURL: folder.appendingPathComponent("Reference.lungfishref"),
            tableSelection: AnnotationTableExportSelection(scope: "", columns: columns), editedValues: [:],
            format: .tsv, outputURL: folder.appendingPathComponent("genes.tsv")
        )) { error in
            XCTAssertEqual(error as? AnnotationTableExportRowNotStored, AnnotationTableExportRowNotStored())
            XCTAssertEqual(
                error.localizedDescription,
                "This row is not stored in an annotation database, so it cannot be exported."
            )
        }
        let inputs = folder.appendingPathComponent(ViewerExportSelection.inputsFolderName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputs.path), "nothing is written before the refusal")
    }
}
