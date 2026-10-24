// ViralDetectionTableIdentityTests.swift - The EsViritu Identity shows percent and the exports keep the fraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane OBS6 (walk obs-6, row 18's EsViritu half, vote V12). EsViritu reports the average read identity as a
// fraction from 0 to 1. The table shows it as a percent, so 0.99699 reads 99.7% in an assembly row, in a detection row
// and in the detection's hover text. The two export sites write the fraction as the tool wrote it, so the same value
// reads 0.99699. The sites are the table's Copy Row as TSV and `EsVirituDetectionExport`, which the viewer export and
// `esviritu export detections` share (BIO, V12).

import AppKit
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishEsVirituUI

@MainActor
final class ViralDetectionTableIdentityTests: XCTestCase {
    private var window: NSWindow!
    private var table: ViralDetectionTableView!
    /// A pasteboard of this test's own, since the general pasteboard is one per machine.
    private let pasteboard = NSPasteboard.withUniqueName()
    private var outline: NSOutlineView { table.testOutlineView }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        table = nil
        pasteboard.releaseGlobally()
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// Shows one two-segment virus whose assembly and both segments carry `identity`, with the outline expanded, so
    /// row 0 is the assembly and rows 1 and 2 are its segments.
    private func showTable(identity: Double) {
        window?.orderOut(nil)
        let layouts = makeTestDefaultsSuite(prefix: "ViralDetectionTableIdentityTests")
        let assembly = Self.assembly(identity: identity)
        table = ViralDetectionTableView(frame: NSRect(x: 0, y: 0, width: 760, height: 220))
        table.metadataColumns.userDefaults = layouts.defaults
        table.pasteboard = pasteboard
        table.result = Self.result(of: assembly)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = table
        table.frame = window.contentView!.bounds
        table.autoresizingMask = [.width, .height]
        window.layoutIfNeeded()
        table.expandAllOutlineItems(nil)
        table.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
    }

    private static func detection(accession: String, segment: String, identity: Double) -> ViralDetection {
        ViralDetection(
            sampleId: "S1", name: "Identity virus", description: "Identity virus", length: 100, segment: segment,
            accession: accession, assembly: "GCF_IDENTITY", assemblyLength: 200,
            kingdom: "Viruses", phylum: nil, tclass: nil, order: nil, family: "Testviridae",
            genus: nil, species: "Identity virus", subspecies: nil, rpkmf: 10, readCount: 10,
            coveredBases: 100, meanCoverage: 1, avgReadIdentity: identity, pi: 0,
            filteredReadsInSample: 100_000
        )
    }

    private static func assembly(identity: Double) -> ViralAssembly {
        ViralAssembly(
            assembly: "GCF_IDENTITY", assemblyLength: 200, name: "Identity virus", family: "Testviridae",
            genus: nil, species: "Identity virus", totalReads: 20, rpkmf: 20, meanCoverage: 1,
            avgReadIdentity: identity,
            contigs: [
                detection(accession: "NC_IDENTITY1", segment: "S1", identity: identity),
                detection(accession: "NC_IDENTITY2", segment: "S2", identity: identity),
            ]
        )
    }

    private static func result(of assembly: ViralAssembly) -> LungfishIO.EsVirituResult {
        LungfishIO.EsVirituResult(
            sampleId: "S1", detections: assembly.contigs, assemblies: [assembly], taxProfile: [],
            coverageWindows: [], totalFilteredReads: 100_000, detectedFamilyCount: 1, detectedSpeciesCount: 1,
            runtime: nil, toolVersion: nil
        )
    }

    private func cell(column id: String, row: Int) throws -> NSTableCellView {
        let index = outline.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
        let column = try XCTUnwrap(index >= 0 ? index : nil, "the \(id) column exists")
        return try XCTUnwrap(outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
    }

    // MARK: - Display

    /// The table shows the identity as a percent. The assembly cell, the detection cell and the detection's hover
    /// line read the same digits (UX, V12).
    func testIdentityCellsShowPercent() throws {
        let cases: [(fraction: Double, percent: String)] = [(0.99699, "99.7%"), (0, "0.0%"), (1, "100.0%")]
        for (fraction, percent) in cases {
            showTable(identity: fraction)
            XCTAssertEqual(outline.numberOfRows, 3, "one virus and its two segments at \(fraction)")
            XCTAssertEqual(
                try cell(column: "identity", row: 0).textField?.stringValue, percent,
                "assembly row cell at \(fraction)"
            )
            XCTAssertEqual(
                try cell(column: "identity", row: 1).textField?.stringValue, percent,
                "detection row cell at \(fraction)"
            )
            let hoverText = try XCTUnwrap(try cell(column: "name", row: 1).toolTip, "hover text at \(fraction)")
            XCTAssertTrue(
                hoverText.components(separatedBy: "\n").contains("Identity: \(percent)"),
                "detection hover text at \(fraction) reads\n\(hoverText)"
            )
        }
    }

    // MARK: - Exports

    /// Both export sites write the fraction as the tool wrote it. The shortest round-trip text keeps every digit
    /// (0.99699), and writes 0.0 for 0 and 1.0 for 1 (BIO, QA and SWIFT, V12).
    func testExportKeepsTheFraction() throws {
        let cases: [(fraction: Double, text: String)] = [(0.99699, "0.99699"), (0, "0.0"), (1, "1.0")]
        for (fraction, text) in cases {
            showTable(identity: fraction)

            // The table's Copy Row as TSV holds Identity in field 8 of an assembly row and of a detection row.
            for (row, kind) in [(0, "assembly"), (1, "detection")] {
                pasteboard.clearContents()
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.copySelectedRowAsTSV(nil)
                let copied = try XCTUnwrap(pasteboard.string(forType: .string), "\(kind) row copy at \(fraction)")
                let fields = copied.components(separatedBy: "\t")
                XCTAssertEqual(fields.count, 11, "\(kind) row copy at \(fraction): \(copied)")
                XCTAssertEqual(fields.count > 8 ? fields[8] : nil, text, "table TSV, \(kind) row at \(fraction)")
            }

            // The export that the viewer and `esviritu export detections` share writes detection rows.
            let exported = EsVirituDetectionExport.buildDelimitedExport(
                result: Self.result(of: Self.assembly(identity: fraction)),
                separator: "\t", metadataHeaders: [], metadataValuesBySample: [:]
            )
            let lines = exported.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 3, "a header and two detection rows at \(fraction)")
            let header = (lines.first ?? "").components(separatedBy: "\t")
            let identityField = try XCTUnwrap(header.firstIndex(of: "Identity"), "the export header holds Identity")
            for line in lines.dropFirst() {
                let fields = line.components(separatedBy: "\t")
                XCTAssertEqual(fields.count, header.count, "a detection row has a field for each header at \(fraction)")
                XCTAssertEqual(
                    fields.count > identityField ? fields[identityField] : nil, text,
                    "EsVirituDetectionExport at \(fraction)"
                )
            }
        }
    }
}
