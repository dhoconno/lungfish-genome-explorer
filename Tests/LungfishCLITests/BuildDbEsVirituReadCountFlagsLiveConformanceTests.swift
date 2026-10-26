// BuildDbEsVirituReadCountFlagsLiveConformanceTests.swift - Reads and Unique Reads count each read once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane ESV (ESV-READCOUNT-FLAGS, the BIO-ESV ruling, S1). `build-db esviritu` overwrites each row's
// `read_count` with the count of its BAM and fills `unique_reads` after markdup. The BAM that EsViritu leaves holds
// secondary records, because its minimap2 runs with `--secondary=yes`, so `samtools view -c -F 0x4` counted one read
// once for each place it aligns. Reads now counts the mapped primary records (`-F 0x904`) and Unique Reads the same
// records without duplicates (`-F 0xD04`), so each read counts once, as EsViritu's own `read_count` does.
//
// The crafted BAM is built by the test from `Tests/Fixtures/esviritu-secondary/S1.sam`. It has two references, A and B,
// of 1000 bp, and twelve single-end records of six reads.
//   r1 has a primary on A:101 and a secondary on A:501, which is the same accession.
//   r2 has a primary on A:201 and a secondary on B:201.
//   r3 has a primary on B:301 and a secondary on A:301.
//   r4 has a primary on A:601 (60M40S) and a supplementary on B:701 (60H40M).
//   r5 and r6 are both primary on A:801, so markdup marks one of them a duplicate, and they have secondaries on B:801 and B:851.
//
//   Contig  Reads before  Reads now  Unique before  Unique now
//   A       7             5          6              4
//   B       5             1          5              1

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

/// The live form, over a crafted BAM and the BAMs of `esviritu-mini` and `taxtriage-mini`, with the managed samtools,
/// whose markdup marks each BAM in place (2.9 O5). `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a failure. The stand-in form is
/// the scripted samtools of `BuildDbCommandMarkdupTests`, which answers each count by its flag and so pins the flags.
final class BuildDbEsVirituReadCountFlagsLiveConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbEsVirituReadCountFlags")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, with 7 and 5 reads and 6 and 5 unique reads. A secondary or supplementary record belongs to a
    /// read that its primary record already counts, and a duplicate is a read that another primary record counts.
    func testReadsAndUniqueReadsCountEachReadOnceAtItsPrimaryAlignment() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let result = try Self.craftedResult(in: root, samtools: samtools)

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"]).run()

        let rows = try Self.builtRows(in: result, samples: ["S1"])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.accession, $0.readCount) }), ["A": 5, "B": 1],
            "Reads counts r1 r2 r4 r5 r6 on A and r3 on B, so the secondary records of r1 r2 r3 r5 r6 and the supplementary of r4 add nothing"
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.accession, $0.uniqueReads) }), ["A": 4, "B": 1],
            "Unique Reads leaves out the one of r5 and r6 that markdup marks, which leaves 4 on A and r3 on B"
        )
    }

    /// The `read_count` that the build leaves is the `read_count` of EsViritu's own table, which counts primary
    /// alignments only, so Reads and RPKMF agree. Red at the base, with 7 and 5 against 5 and 1.
    func testReadsEqualEsVirituReadCount() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let result = try Self.craftedResult(in: root, samtools: samtools)
        let table = try Self.tableReadCounts(of: "S1", in: result)
        XCTAssertEqual(table, ["A": 5, "B": 1], "the table holds one count per read, 5 on A and 1 on B")

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"]).run()

        let rows = try Self.builtRows(in: result, samples: ["S1"])
        XCTAssertEqual(rows.count, table.count, "a row for each accession of the table")
        for row in rows {
            XCTAssertEqual(row.readCount, table[row.accession], "the Reads of \(row.accession) equal the read_count of its table")
        }
    }

    /// Green before and after the change, since no BAM of the two samples holds a secondary or supplementary record.
    /// It pins what Reads means on real EsViritu output, that it equals the table. It leaves out SRR35517702, whose BAM
    /// is not the BAM behind its table (MF094130.1 is 6 in the table and 92 in the BAM, and the BAM holds 12 more
    /// accessions), so no parity holds there. That is a fixture finding, not a counting one.
    func testReadsEqualEsVirituReadCountOnTheMiniFixtures() async throws {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixtures = BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-mini", isDirectory: true)
        let result = root.appendingPathComponent("esviritu-mini", isDirectory: true)
        try FileManager.default.copyItem(at: fixtures, to: result)
        try FileManager.default.removeItem(at: result.appendingPathComponent("SRR35517702", isDirectory: true))

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"]).run()

        let samples = ["SRR35517703", "SRR35517705"]
        let rows = try Self.builtRows(in: result, samples: samples)
        for sample in samples {
            let table = try Self.tableReadCounts(of: sample, in: fixtures)
            for row in rows where row.sample == sample {
                XCTAssertEqual(row.readCount, table[row.accession], "\(sample) \(row.accession), the Reads against the read_count of its table")
            }
        }
        XCTAssertEqual(rows.count, 16, "14 rows of SRR35517703 and 2 rows of SRR35517705")
    }

    /// The real-data pin of the ruled meaning on TaxTriage rows (BIO's review of lane ESV, SF1). Two of the three
    /// `taxtriage-mini` BAMs hold supplementary records of split reads whose primary record sits on the same contig, so
    /// three rows count one read less than they did while the count passed alignment records. Before the change those
    /// rows read 31, 17 and 993 Reads and 23, 11 and 277 Unique Reads. SRR35517703 holds no supplementary record, so its
    /// row keeps 9 reads, the count that TaxTriage's own report holds for it. `updateUniqueReadsInDB` is one function for
    /// both tools, so this is the number-level guard of the TaxTriage Reads and Unique Reads columns.
    func testTaxTriageMiniCountsASplitReadOnceAtItsPrimaryAlignment() async throws {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixture = BuildDbStreamCapture.fixturesFolder.appendingPathComponent("taxtriage-mini", isDirectory: true)
        let result = root.appendingPathComponent("taxtriage-mini", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)

        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path, "-q"]).run()

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let rows = try database.fetchRows(samples: try database.fetchSamples().map(\.sample))
        func row(_ sample: String, _ accession: String) throws -> TaxTriageTaxonomyRow {
            let matches = rows.filter { $0.sample == sample && $0.primaryAccession == accession }
            XCTAssertEqual(matches.count, 1, "one row for \(sample) \(accession)")
            return try XCTUnwrap(matches.first, "a row for \(sample) \(accession)")
        }

        let split702 = try row("SRR35517702", "NC_045512.2")
        XCTAssertEqual(split702.readsAligned, 30, "SRR35517702 NC_045512.2 holds 31 records, one of them the supplementary of read 4096958")
        XCTAssertEqual(split702.uniqueReads, 22, "the supplementary record is not a duplicate, so Unique Reads drops with Reads")
        let shortSplit705 = try row("SRR35517705", "NC_045512.2")
        XCTAssertEqual(shortSplit705.readsAligned, 16, "SRR35517705 NC_045512.2 holds 17 records, one of them the supplementary of read 2920")
        XCTAssertEqual(shortSplit705.uniqueReads, 10, "the supplementary record is not a duplicate, so Unique Reads drops with Reads")
        let longSplit705 = try row("SRR35517705", "NC_074583.1")
        XCTAssertEqual(longSplit705.readsAligned, 983, "SRR35517705 NC_074583.1 holds 993 records, ten of them supplementary")
        XCTAssertEqual(longSplit705.uniqueReads, 267, "the ten supplementary records are not duplicates, so Unique Reads drops with Reads")
        let whole703 = try row("SRR35517703", "NC_045512.2")
        XCTAssertEqual(whole703.readsAligned, 9, "SRR35517703 holds no supplementary record, so its count stays as TaxTriage's own report has it")
    }

    // MARK: - Staging

    /// A result folder of the one sample S1. Its BAM is made by `samtools sort` and `samtools index` from the crafted
    /// SAM, and its detection table lists A with a `read_count` of 5 and B with 1, the primary alignments on each.
    private static func craftedResult(in root: URL, samtools: URL) throws -> URL {
        let result = root.appendingPathComponent("esviritu-secondary", isDirectory: true)
        let folder = result.appendingPathComponent("S1", isDirectory: true)
        let temp = folder.appendingPathComponent("S1_temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let sam = BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-secondary/S1.sam")
        let bam = temp.appendingPathComponent("S1.third.filt.sorted.bam")
        let sorted = try ProcessRunner.run(samtools, ["sort", "-o", bam.path, sam.path])
        XCTAssertEqual(sorted.status, 0, sorted.stderr)
        let indexed = try ProcessRunner.run(samtools, ["index", bam.path])
        XCTAssertEqual(indexed.status, 0, indexed.stderr)
        try Data(craftedTable().utf8).write(to: folder.appendingPathComponent("S1.detected_virus.info.tsv"))
        return result
    }

    /// The header of EsViritu's detection table and two rows in its shape, one for each reference of the crafted SAM.
    private static func craftedTable() -> String {
        let header = [
            "sample_ID", "Name", "description", "Length", "Segment", "Accession", "Assembly", "Asm_length", "kingdom", "phylum",
            "tclass", "order", "family", "genus", "species", "subspecies", "RPKMF", "read_count", "covered_bases",
            "mean_coverage", "avg_read_identity", "Pi", "filtered_reads_in_sample",
        ]
        func row(_ accession: String, reads: Int) -> [String] {
            [
                "S1", "Crafted virus \(accession)", "Crafted virus \(accession)", "1000", "NA", accession, "acc:\(accession)", "1000",
                "k__Viruses", "p__Crafted", "c__Crafted", "o__Crafted", "f__Crafted", "g__Crafted", "s__Crafted virus \(accession)",
                "t__Crafted virus \(accession)", "1.0", String(reads), "500", "0.5", "1.0", "0.001", "12",
            ]
        }
        return [header, row("A", reads: 5), row("B", reads: 1)].map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// The `read_count` that EsViritu wrote for each accession of `sample`, read from its detection table in `result`.
    private static func tableReadCounts(of sample: String, in result: URL) throws -> [String: Int] {
        let table = result.appendingPathComponent("\(sample)/\(sample).detected_virus.info.tsv")
        let lines = try String(contentsOf: table, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = try XCTUnwrap(lines.first).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let accessionColumn = try XCTUnwrap(header.firstIndex(of: "Accession"))
        let countColumn = try XCTUnwrap(header.firstIndex(of: "read_count"))
        var counts: [String: Int] = [:]
        for line in lines.dropFirst() {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            counts[cells[accessionColumn]] = try XCTUnwrap(Int(cells[countColumn]))
        }
        XCTAssertEqual(counts.count, lines.count - 1, "each row of \(table.lastPathComponent) names its own accession")
        return counts
    }

    /// The detection rows of `samples` in the database that `build-db esviritu` wrote into `result`.
    private static func builtRows(in result: URL, samples: [String]) throws -> [EsVirituDetectionRow] {
        try EsVirituDatabase(at: result.appendingPathComponent("esviritu.sqlite")).fetchRows(samples: samples)
    }
}
