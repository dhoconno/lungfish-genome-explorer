// BuildDbTaxTriageTaxIDSynonymTests.swift - A TaxTriage row reported under a synonym links to its reference by tax ID
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// TT-TAXID-SYNONYM. In the SRR24010784 pilot TaxTriage reported Haemophilus parainfluenzae (taxid 729) and downloaded
// its reference under the assembly summary's name, Parahaemophilus parainfluenzae, also taxid 729. The row's name
// matched no gcfmap organism, so it had no primary accession and the viewer said "No reference was recorded for this
// organism in this sample." The build now falls back to the tax ID that `map/<sample>.merged.taxid.tsv` gives each
// reference. The fixture is synthetic and built here. The test needs samtools and never runs TaxTriage.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbTaxTriageTaxIDSynonymTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageTaxIDSynonym")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red before the fallback, where the row had no primary accession.
    func testRowReportedUnderSynonymLinksToItsReferenceBySharedTaxID() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let result = try makeResult(referenceTaxID: 729, samtools: samtools)

        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let rows = try database.fetchRows(samples: ["pilot"])
        let row = try XCTUnwrap(rows.first { $0.taxId == 729 })
        XCTAssertEqual(row.organism, "Haemophilus parainfluenzae", "the row keeps the reported name")
        XCTAssertEqual(row.primaryAccession, "synthetic_ref")
        XCTAssertEqual(row.uniqueReads, 2)

        let references = try database.fetchOrganismReferences(of: [row])
        let stored = try XCTUnwrap(references[TaxTriageOrganismReference.rowKey(sample: "pilot", primaryAccession: "synthetic_ref")])
        XCTAssertEqual(stored.map(\.accession), ["synthetic_ref"])
        XCTAssertEqual(stored.first?.mappedReads, 2, "the viewer is handed both alignments")

        let bamPath = try XCTUnwrap(row.bamPath)
        let bam = bamPath.hasPrefix("/") ? URL(fileURLWithPath: bamPath) : result.appendingPathComponent(bamPath)
        let view = try ProcessRunner.run(samtools, ["view", "-c", "-F", "0x904", bam.path, "synthetic_ref"])
        XCTAssertEqual(view.status, 0, view.stderr)
        XCTAssertEqual(view.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "2", "the row's BAM holds both reads on synthetic_ref")
    }

    /// The cleanup keeps `map/<sample>.merged.taxid.tsv`, so a rebuild of the cleaned folder links the row again.
    func testRebuildAfterCleanupKeepsTheLink() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let result = try makeResult(referenceTaxID: 729, samtools: samtools)

        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("map/pilot.merged.taxid.tsv").path))
        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q", "--force"]).run()

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let row = try XCTUnwrap(try database.fetchRows(samples: ["pilot"]).first { $0.taxId == 729 })
        XCTAssertEqual(row.primaryAccession, "synthetic_ref")
    }

    /// The negative control. A reference of another tax ID is not the row's, so the row stays unlinked.
    func testRowStaysUnlinkedWhenTheReferenceTaxIDDiffers() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let result = try makeResult(referenceTaxID: 730, samtools: samtools)

        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let row = try XCTUnwrap(try database.fetchRows(samples: ["pilot"]).first { $0.taxId == 729 })
        XCTAssertEqual(row.organism, "Haemophilus parainfluenzae")
        XCTAssertNil(row.primaryAccession)
    }

    /// Two unmatched rows of one tax ID are ambiguous, and so are references of one tax ID under two organism names.
    func testAmbiguousTaxIDEvidenceLeavesRowsUnresolved() {
        let gcfmap = [(accession: "a1", organism: "Name A"), (accession: "b1", organism: "Name B")]
        let twoRows = BuildDbCommand.TaxTriageSubcommand.taxTriageTaxIDGroups(
            [:], rows: [("Row one", 729), ("Row two", 729)], gcfmap: [gcfmap[0]], referenceTaxIDs: ["a1": 729]
        )
        XCTAssertTrue(twoRows.isEmpty)
        let twoNames = BuildDbCommand.TaxTriageSubcommand.taxTriageTaxIDGroups(
            [:], rows: [("Row one", 729)], gcfmap: gcfmap, referenceTaxIDs: ["a1": 729, "b1": 729]
        )
        XCTAssertTrue(twoNames.isEmpty)
        let exact = BuildDbCommand.TaxTriageSubcommand.taxTriageTaxIDGroups(
            ["Name A": ["a1"]], rows: [("Name A", 729), ("Row two", 729)], gcfmap: [gcfmap[0]], referenceTaxIDs: ["a1": 729]
        )
        XCTAssertEqual(exact, ["Name A": ["a1"]], "an exact-name match keeps its reference, and no other row takes it")
    }

    // MARK: - Fixture

    private func makeResult(referenceTaxID: Int, samtools: URL) throws -> URL {
        let result = root.appendingPathComponent("taxtriage", isDirectory: true)
        let fm = FileManager.default
        for folder in ["report", "combine", "map", "minimap2"] {
            try fm.createDirectory(at: result.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func write(_ lines: [[String]], to relative: String) throws {
            let text = lines.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: result.appendingPathComponent(relative))
        }
        try write([
            ["Detected Organism", "Specimen ID", "# Reads Aligned", "Taxonomic ID #", "Status", "Breadth %", "TASS Score", "TASS Threshold"],
            ["Haemophilus parainfluenzae", "pilot", "2", "729", "established", "1.0", "90", "70"],
        ], to: "report/pilot.odr.txt")
        try write([
            ["synthetic_ref", "GCF_000000001.1", "Parahaemophilus parainfluenzae", "Parahaemophilus parainfluenzae synthetic"],
        ], to: "combine/pilot.combined.gcfmap.tsv")
        try write([
            ["Acc", "Assembly", "Organism_Name", "Description", "Mapped_Value"],
            ["synthetic_ref", "GCF_000000001.1", "Parahaemophilus parainfluenzae", "Parahaemophilus parainfluenzae synthetic", "\(referenceTaxID)"],
        ], to: "map/pilot.merged.taxid.tsv")

        let sam = root.appendingPathComponent("pilot.sam")
        try write([
            ["@HD", "VN:1.6", "SO:coordinate"],
            ["@SQ", "SN:synthetic_ref", "LN:1000"],
            ["r1", "0", "synthetic_ref", "101", "60", "10M", "*", "0", "0", "ACGTACGTAC", "IIIIIIIIII"],
            ["r2", "0", "synthetic_ref", "401", "60", "10M", "*", "0", "0", "TTGCATTGCA", "IIIIIIIIII"],
        ], to: "../pilot.sam")
        let bam = result.appendingPathComponent("minimap2/pilot.pilot.dwnld.references.bam")
        let sorted = try ProcessRunner.run(samtools, ["sort", "-o", bam.path, sam.path])
        XCTAssertEqual(sorted.status, 0, sorted.stderr)
        let indexed = try ProcessRunner.run(samtools, ["index", bam.path])
        XCTAssertEqual(indexed.status, 0, indexed.stderr)
        try fm.removeItem(at: sam)
        return result
    }
}
