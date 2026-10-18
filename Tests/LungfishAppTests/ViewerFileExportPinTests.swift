// ViewerFileExportPinTests.swift - What the FASTA records, sequence FASTA and FASTQ metadata exports write today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M1 (QA 1). These pins pass at the base, with no Sources edit, and show the bytes and the
// record each in-app writer leaves, so the conversion that follows can name what moved.
//
// - The sequence FASTA writer is called as its context menu calls it, so its bytes and its whole record are pinned.
// - The FASTQ metadata writer sits inside a save panel completion, so no test reaches its record without driving the
//   panel. A panel sheet answered from a test aborts the test process (malloc, "freed pointer was not the last
//   allocation"), so these pins read the state the writer starts from and the CSV text it writes. The cases cover the
//   Samples tab, the symmetric and the asymmetric Demux tab, each with and without a cell edited in the drawer and not
//   saved. The record is pinned by the frozen writer of its parity class.
// - The FASTA records writer sits inside a save panel completion too. These pins reach only its source set
//   (fastaExportSourceURLs). Its bytes, its record and the records each of the five callers hand it are not pinned
//   here, and lane 12.34 pins them before it changes the writer.

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

    // MARK: - Sequence FASTA (A12)

    func testSequenceFASTAWrapsAt80ColumnsAndNamesTheDescription() throws {
        let source = scratch.appendingPathComponent("source.fasta")
        try Data(">chr1\nACGT\n".utf8).write(to: source)
        let output = scratch.appendingPathComponent("selected.fasta")
        let sequence = try Sequence(name: "chr1", description: "visible track", alphabet: .dna, bases: String(repeating: "ACGT", count: 50))

        try SequenceViewerView.writeSequenceFASTAExport(sequence, sourceURLs: [source], to: output)

        let eighty = String(repeating: "ACGT", count: 20)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            ">chr1 visible track\n\(eighty)\n\(eighty)\n\(String(repeating: "ACGT", count: 10))\n"
        )
        let record = try envelope(for: output)
        XCTAssertEqual(record.toolName, "Lungfish.app")
        XCTAssertEqual(record.tool.kind, "gui")
        XCTAssertEqual(record.workflowName, "lungfish app sequence fasta export")
        XCTAssertEqual(
            record.argv,
            ["Lungfish Genome Explorer", "export-sequence-fasta", "--source", source.path,
             "--sequence", "chr1", "--output", output.path]
        )
        XCTAssertEqual(record.durableReplayArgv, record.argv)
        XCTAssertEqual(record.output?.format, .fasta)
        XCTAssertEqual(record.options.explicit.keys.sorted(), ["outputPath", "sequenceDescription", "sequenceName", "sourcePaths"])
        XCTAssertEqual(record.options.explicit["sequenceName"], .string("chr1"))
        XCTAssertEqual(record.options.explicit["sequenceDescription"], .string("visible track"))
        XCTAssertEqual(record.options.defaults.keys.sorted(), ["lineWidth", "outputFormat"])
        XCTAssertEqual(record.options.defaults["lineWidth"], .integer(80))
        XCTAssertEqual(record.options.defaults["outputFormat"], .string("fasta"))
        XCTAssertEqual(record.options.resolvedDefaults.keys.sorted(), ["outputByteCount", "sequenceLength", "sourceCount"])
        XCTAssertEqual(record.options.resolvedDefaults["sequenceLength"], .integer(200))
        XCTAssertEqual(record.options.resolvedDefaults["outputByteCount"], .integer(20 + 81 + 81 + 41))
        XCTAssertEqual(record.options.resolvedDefaults["sourceCount"], .integer(1))
        XCTAssertEqual(inputPaths(of: record), [normalized(source)])
    }

    func testSequenceFASTAOfOneFullLineEndsWithoutABlankLine() throws {
        let output = scratch.appendingPathComponent("one-line.fasta")
        let sequence = try Sequence(name: "s", alphabet: .dna, bases: String(repeating: "A", count: 80))

        try SequenceViewerView.writeSequenceFASTAExport(sequence, sourceURLs: [], to: output)

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), ">s\n\(String(repeating: "A", count: 80))\n")
        let record = try envelope(for: output)
        XCTAssertEqual(record.options.explicit.keys.sorted(), ["outputPath", "sequenceName", "sourcePaths"])
        XCTAssertEqual(record.argv, ["Lungfish Genome Explorer", "export-sequence-fasta", "--sequence", "s", "--output", output.path])
        XCTAssertEqual(inputPaths(of: record), [])
    }

    // MARK: - FASTA records (A11)

    /// The sources the FASTA records export names are the viewer's (`fastaExportSourceURLs`), which the leaf will have
    /// to name as its inputs.
    func testFASTARecordsNameTheViewersBundleAsTheirSource() throws {
        let bundle = scratch.appendingPathComponent("assembly.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let viewController = ViewerViewController()
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
