// ViewerFileExportPinTests.swift - What the FASTA records, sequence FASTA and FASTQ metadata exports write today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M1 (QA 1). These pins pass at the base, with no Sources edit, and show the bytes and the
// record each in-app writer leaves, so the conversion that follows can name what moved.
//
// - The sequence FASTA writer's pins ended with the writer (A12). Its bytes and its record are frozen in
//   SequenceFASTAExportCLIGUIParityReplayTests.
// - The FASTA records writer ended with A11. Its bytes and its record are frozen in
//   FASTARecordsExportCLIGUIParityReplayTests. The one pin left under "FASTA records" reads fastaExportSourceURLs,
//   which BLAST submit and the annotated reference import still use.
// - The FASTQ metadata writers sit inside a save panel completion, so no test reaches their record without driving the
//   panel. A panel sheet answered from a test aborts the test process (malloc, "freed pointer was not the last
//   allocation"), so these pins read the state each writer starts from and the CSV text it writes. The FASTQ cases
//   cover the Samples tab, the symmetric and the asymmetric Demux tab, each with and without a cell edited in the
//   drawer and not saved. The record of each is pinned by the frozen writer of its parity class.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViewerFileExportPinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "viewer-file-export-pins")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - FASTA records (A11)

    /// The sources a viewer names for a durable record are its bundle when it holds one, and a bundle that is gone is
    /// left out. The FASTA records export no longer names them, since its record names the staged files the leaf reads
    /// (lane 12.34, A11).
    func testFASTARecordsNameTheViewersBundleAsTheirSource() throws {
        let bundle = scratch.appendingPathComponent("assembly.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let viewController = ViewerViewController()
        // UserDefaults.standard resolves to the app's real identity inside xctest, and the drawer writes its height
        // through annotationDrawerDefaults, so the viewer gets a suite of its own, as AnnotationDrawerSizingTests does.
        viewController.annotationDrawerDefaults = makeTestDefaultsSuite(prefix: "ViewerFileExportPinTests").defaults
        _ = viewController.view
        XCTAssertEqual(viewController.fastaExportSourceURLs(), [], "a viewer with no document or bundle names no source")

        viewController.currentBundleURL = bundle
        XCTAssertEqual(viewController.fastaExportSourceURLs(), [bundle.standardizedFileURL])

        viewController.currentBundleURL = scratch.appendingPathComponent("missing.lungfishref", isDirectory: true)
        XCTAssertEqual(viewController.fastaExportSourceURLs(), [], "a source that is gone is left out")
    }

    // MARK: - FASTQ metadata (A13)

    func testSamplesTabWritesTheFullSheet() throws {
        let plain = drawerExport(tab: "samples", asymmetric: false, edits: [])
        XCTAssertEqual(plain, Self.fullSheet)
        let edited = drawerExport(tab: "samples", asymmetric: false, edits: Self.edits)
        XCTAssertEqual(edited, Self.editedFullSheet)
    }

    func testSymmetricDemuxTabWritesTheFullSheet() throws {
        XCTAssertEqual(drawerExport(tab: "demux", asymmetric: false, edits: []), Self.fullSheet)
        XCTAssertEqual(drawerExport(tab: "demux", asymmetric: false, edits: Self.edits), Self.editedFullSheet)
    }

    func testAsymmetricDemuxTabWritesBarcodeIdsOnly() throws {
        XCTAssertEqual(
            drawerExport(tab: "demux", asymmetric: true, edits: []),
            "sample_id,barcode_1,barcode_2\nS1,BC01,BC02\nS2,BC03,BC04\n"
        )
        XCTAssertEqual(
            drawerExport(tab: "demux", asymmetric: true, edits: Self.edits),
            "sample_id,barcode_1,barcode_2\nS1,BC09,BC02\nS2,BC03,BC04\n"
        )
    }

    /// The Samples tab ignores the demux pattern's symmetry and writes the full sheet.
    func testSamplesTabOfAnAsymmetricPlanStillWritesTheFullSheet() throws {
        XCTAssertEqual(drawerExport(tab: "samples", asymmetric: true, edits: []), Self.fullSheet)
    }

    /// The edit is held by the drawer and is not what it saves, which is the state the selection file has to carry.
    func testAnEditedCellIsInTheDrawerAndNotInWhatWasConfigured() throws {
        let drawer = makeDrawer(asymmetric: false)
        drawer.tableView(
            makeMainTable(), setObjectValue: "Edited",
            for: NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sampleName")), row: 0
        )
        let held = drawer.currentMetadata().sampleAssignments
        XCTAssertEqual(held.map(\.sampleName), ["Edited", nil])
        XCTAssertEqual(Self.assignments.map(\.sampleName), ["Alpha", nil])
        XCTAssertEqual(held.map(\.sampleID), ["S1", "S2"])
    }

    // MARK: - Helpers

    /// The text `exportClicked` writes. The drawer holds the rows and the demux step. Only the Demux tab of an
    /// asymmetric step writes barcode ids alone.
    private func drawerExport(tab: String, asymmetric: Bool, edits: [(column: String, row: Int, value: String)]) -> String {
        let drawer = makeDrawer(asymmetric: asymmetric)
        if tab == "demux" {
            drawer.selectDemuxTab()
        }
        let table = makeMainTable()
        for edit in edits {
            drawer.tableView(
                table, setObjectValue: edit.value,
                for: NSTableColumn(identifier: NSUserInterfaceItemIdentifier(edit.column)), row: edit.row
            )
        }
        let assignments = drawer.currentMetadata().sampleAssignments
        let isAsymmetric = drawer.currentDemuxPlan().steps.first?.symmetryMode == .asymmetric
        if isAsymmetric && tab == "demux" {
            return FASTQSampleBarcodeCSV.exportAsymmetricCSV(assignments)
        }
        return FASTQSampleBarcodeCSV.exportCSV(assignments)
    }

    private func makeDrawer(asymmetric: Bool) -> FASTQMetadataDrawerView {
        var step = DemultiplexStep(label: "Demux", barcodeKitID: "NBD114", ordinal: 0)
        step.symmetryMode = asymmetric ? .asymmetric : .symmetric
        let planJSON = (try? JSONEncoder().encode(DemultiplexPlan(steps: [step], compositeSampleNames: [:])))
            .flatMap { String(data: $0, encoding: .utf8) }
        let drawer = FASTQMetadataDrawerView()
        drawer.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        drawer.configure(
            fastqURL: scratch.appendingPathComponent("reads.fastq"),
            metadata: FASTQDemultiplexMetadata(sampleAssignments: Self.assignments, demuxPlanJSON: planJSON)
        )
        return drawer
    }

    /// The drawer's main table is told by its tag, which the delegate method reads.
    private func makeMainTable() -> NSTableView {
        let table = NSTableView()
        table.tag = 100
        return table
    }

    private static let fullSheet = """
        sample_id,sample_name,barcode_5p,forward_sequence,barcode_3p,reverse_sequence,Batch,Cohort
        S1,Alpha,BC01,ACGT,BC02,TGCA,b1,case
        S2,,BC03,,BC04,,,

        """

    private static let editedFullSheet = """
        sample_id,sample_name,barcode_5p,forward_sequence,barcode_3p,reverse_sequence,Batch,Cohort
        S1,Edited,BC09,ACGT,BC02,TGCA,b1,case
        S2,,BC03,,BC04,,,

        """

    private static let edits: [(column: String, row: Int, value: String)] = [
        (column: "sampleName", row: 0, value: "Edited"),
        (column: "forwardBarcodeID", row: 0, value: "BC09"),
    ]

    private static let assignments = [
        FASTQSampleBarcodeAssignment(
            sampleID: "S1", sampleName: "Alpha", forwardBarcodeID: "BC01", forwardSequence: "acgt",
            reverseBarcodeID: "BC02", reverseSequence: "tgca", metadata: ["Batch": "b1", "Cohort": "case"]
        ),
        FASTQSampleBarcodeAssignment(sampleID: "S2", forwardBarcodeID: "BC03", reverseBarcodeID: "BC04"),
    ]

    private func envelope(for output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
    }

    private func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func inputPaths(of record: ProvenanceEnvelope) -> [String] {
        record.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }.sorted()
    }
}
