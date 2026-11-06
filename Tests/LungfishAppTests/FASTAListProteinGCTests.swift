// FASTAListProteinGCTests.swift - A protein record of a FASTA list shows no GC percent (Phase 3.2 lane PROTEINGC)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

/// FASTA-PROTEIN-GC (S1, BIO): the list counted the A, C, G and T letters of a protein record as bases, so a peptide
/// showed a GC percent made of alanine, cysteine, glycine and threonine, and a protein record beside DNA records moved
/// the GC Content card. A record that holds a letter no nucleotide code uses now reads a dash, and the card pools only
/// the nucleotide records. Every file here opens through the list's real route: the sidebar row, the surface host, the
/// FASTA reader and the GC pass.
@MainActor
final class FASTAListProteinGCTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!
    private let dash = "\u{2014}"

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "FASTAListProteinGC")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The defect

    /// The first peptide holds I, Q and F, which no nucleotide code uses, so it has no GC percent. At the base its A, A and
    /// T counted as bases and its row read 0.0%, and the second peptide's G, C, G, T and A made the card read 37.5%. A
    /// file of one record never opens as a list, so the file holds two.
    func testProteinRecordShowsNoGCPercent() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        let list = try await openList(
            ">peptide a protein record\nMKTAYIAKQRQISFVKSHFSRQ\n>peptide2 with G and C\nMGCGTAPLEIVWNKDF\n", in: harness
        )

        XCTAssertEqual(list.testTableView.numberOfRows, 2, "the protein FASTA did not open as a list")
        let record = try LungfishCore.Sequence(name: "peptide", alphabet: .protein, bases: "MKTAYIAKQRQISFVKSHFSRQ")
        let composition = try XCTUnwrap(FASTACollectionGC.composition(of: record))
        XCTAssertNil(composition.percent, "A protein record has a GC percent.")
        XCTAssertEqual(gcColumn(list), [dash, dash], "A protein record's row shows a GC percent.")
        XCTAssertEqual(FASTAListGCPassTests.barGC(list), dash, "The GC Content card shows a number for a list with no nucleotide record.")
        XCTAssertTrue(
            gcToolTip(list, row: 0)?.contains("protein record") == true,
            "The dash does not say that the record is a protein record."
        )
        XCTAssertEqual(card("Protein records", in: list), "2 (left out of GC Content)")
    }

    /// A list that mixes records pools only the nucleotide ones. The peptide's G, C and T would add 3 of 5 to the
    /// pooled 10 of 20 and move the card from 50.0% to 52.0%.
    func testMixedListPoolsOnlyTheNucleotideRecords() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        let list = try await openList(">dna1\nGGCCAAAATT\n>peptide\nMGCGTAPLEI\n>dna2\nGGGGGGAATT\n", in: harness)

        XCTAssertEqual(gcColumn(list), ["40.0%", dash, "60.0%"], "A row's GC percent changed or the peptide shows one.")
        XCTAssertEqual(FASTAListGCPassTests.barGC(list), "50.0%", "The card pooled the peptide's letters.")
        XCTAssertEqual(card("Protein records", in: list), "1 (left out of GC Content)", "The card does not say what it left out.")
    }

    /// A record with no value, a protein record or one of only N, sorts last whichever way the column runs.
    func testSortByGCPutsRecordsWithNoValueLastEitherWay() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        let list = try await openList(
            ">high\nGGGGCCAAAA\n>low\nGGCCAAAATT\n>peptide\nMKTAYIAKQRQISFVKSHFSRQ\n>blank\nNNNNNNNN\n", in: harness
        )

        list.testSort(column: "gc", ascending: true)
        XCTAssertEqual(gcColumn(list), ["40.0%", "60.0%", dash, dash], "Ascending did not put the records with no value last.")
        XCTAssertEqual(Set(nameColumn(list).suffix(2)), ["peptide", "blank"])

        list.testSort(column: "gc", ascending: false)
        XCTAssertEqual(gcColumn(list), ["60.0%", "40.0%", dash, dash], "Descending did not put the records with no value last.")
        XCTAssertEqual(Set(nameColumn(list).suffix(2)), ["peptide", "blank"])
    }

    // MARK: - What stays the same

    /// A DNA record, an RNA record written with U (the reader stores it with T), an IUPAC record with N, R and Y, and the same
    /// in lower case keep the numbers they had, and the list names no protein record.
    func testNucleotideRNAAndIUPACRecordsKeepTheirNumbers() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        let list = try await openList(
            ">dna\nGGCCAAAATT\n>rna\nGGCCAAAAUU\n>iupac\nGGCCAANNRRYY\n>masked\nggccaannrryy\n", in: harness
        )

        XCTAssertEqual(gcColumn(list), ["40.0%", "40.0%", "66.7%", "66.7%"])
        XCTAssertEqual(FASTAListGCPassTests.barGC(list), "50.0%")
        XCTAssertNil(card("Protein records", in: list), "A nucleotide list names protein records.")
    }

    // MARK: - Helpers

    /// Writes `records` as a FASTA file in a project, opens it as the sidebar does, and waits for the GC pass to deliver.
    private func openList(
        _ records: String, in harness: ViewSwitchWindowHarness, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> FASTACollectionViewController {
        let folder = root.appendingPathComponent("\(UUID().uuidString).lungfish/Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("records.fasta")
        try records.write(to: url, atomically: true, encoding: .utf8)
        let viewer = try XCTUnwrap(harness.split.viewerController)
        harness.select(RoutingSafetyNetItems.scanned(url))
        _ = await waitUntil(budget: .lookup) { viewer.fastaCollectionController != nil }
        let list = try XCTUnwrap(viewer.fastaCollectionController, "the FASTA file never opened as a list", file: file, line: line)
        _ = await waitUntil(budget: .lookup) { FASTAListGCPassTests.barGC(list) != "" }
        XCTAssertNotEqual(FASTAListGCPassTests.barGC(list), "", "The GC pass never delivered.", file: file, line: line)
        return list
    }

    private func gcColumn(_ list: FASTACollectionViewController) -> [String] {
        (0..<list.testTableView.numberOfRows).map { FASTAListGCPassTests.gcCell(list, row: $0) }
    }

    private func nameColumn(_ list: FASTACollectionViewController) -> [String] {
        (0..<list.testTableView.numberOfRows).map { FASTAListGCPassTests.cell(list, column: "name", row: $0) }
    }

    private func gcToolTip(_ list: FASTACollectionViewController, row: Int) -> String? {
        let table = list.testTableView
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "gc" }),
              let cell = table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView else {
            return nil
        }
        return cell.textField?.toolTip
    }

    private func card(_ label: String, in list: FASTACollectionViewController) -> String? {
        FASTAListGCPassTests.summaryBar(list)?.cards.first { $0.label == label }?.value
    }
}
