// NvdUniqueReadsFlagsLiveConformanceTests.swift - NVD Unique Reads counts each read once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NVD (NVD-UNIQUE-READS-DOUBLE-COUNT, S1, row 1 of BIO's backlog in the ESV review of 3.0). The NVD
// import marks duplicates in the BAM it copies, then fills `unique_reads` of each hit with
// `samtools view -c -F <mask> <bam> <accession>`. The mask was 0x404, which keeps secondary (0x100) and supplementary
// (0x800) records, so a read that aligns in more than one place counted once for each. It is 0xD04 now, the mask the
// BIO-ESV ruling set for Unique Reads, so a read counts once at its primary alignment.
//
// The crafted BAM is `Tests/Fixtures/nvd/secondary-supplementary/S1.filtered.bam`, made by the real samtools from
// `source.sam`. It has one accession, SYN0001.1, and eight single-end records of six reads.
//   r1 to r6 each have one primary record.
//   r3 also has a secondary record at 601 and r4 a supplementary record at 701.
//   r5 and r6 are both primary at 501, so markdup marks one of them a duplicate.
//
//   samtools view -c, run directly            -F 0x404   -F 0xD04
//   the BAM as the pipeline leaves it             8          6
//   the BAM after the import's markdup            7          5

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// The live form, with the managed samtools (2.9 O5). `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a
/// failure. The stand-in form is `NvdSamtoolsSpawnPinTests`, whose scripted samtools pins the argv that the count
/// records, flag included.
final class NvdUniqueReadsFlagsLiveConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "NvdUniqueReadsFlags")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, with 7 where 5 is true. A secondary or supplementary record belongs to a read that its primary
    /// record already counts, and the duplicate is a read that another primary record counts.
    func testUniqueReadsCountsEachReadOnceAtItsPrimaryAlignment() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let imported = try await MetagenomicsImportService.importNvd(
            inputURL: try Self.craftedRun(in: root),
            outputDirectory: root.appendingPathComponent("imports", isDirectory: true),
            samtoolsPath: samtools.path
        )
        XCTAssertEqual(imported.markdupBAMCount, 1, "the import marks the crafted BAM")
        XCTAssertEqual(imported.uniqueReadRowsUpdated, 1)

        let database = try NvdDatabase(at: imported.resultDirectory.appendingPathComponent("hits.sqlite"))
        let hit = try XCTUnwrap(try database.bestHits(forSamples: ["S1"]).first)
        let bam = imported.resultDirectory.appendingPathComponent(try XCTUnwrap(try database.bamPath(forSample: "S1")))
        XCTAssertEqual(try Self.count(samtools, bam, mask: "0x404"), 7,
                       "the old mask counts r1 r2 r3 r4 and one of r5 and r6, then the secondary of r3 and the supplementary of r4")
        XCTAssertEqual(try Self.count(samtools, bam, mask: "0xD04"), 5,
                       "the new mask counts r1 r2 r3 r4 and one of r5 and r6")
        XCTAssertEqual(hit.uniqueReads, 5, "Unique Reads is the stored count, one for each read left after deduplication")
    }

    // MARK: - Staging

    private static let csv = """
    experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
    EXP001,blastn,S1,contig-1,120,SYN0001.1,Synthetic virus,S,118,99.2,1e-20,250.5,Synthetic virus,12345,nt-2026,run-001,6,100000,stat-1,12345,unchanged,Synthetic virus,species

    """

    /// An NVD run of the one sample S1 whose BAM is the crafted fixture, with one BLAST hit on its accession.
    private static func craftedRun(in root: URL) throws -> URL {
        let run = root.appendingPathComponent("nvd-run", isDirectory: true)
        let labkey = run.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        let results = run.appendingPathComponent("02_human_viruses/03_human_virus_results", isDirectory: true)
        let mapped = results.appendingPathComponent("mapped_reads", isDirectory: true)
        try FileManager.default.createDirectory(at: labkey, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mapped, withIntermediateDirectories: true)
        try csv.write(to: labkey.appendingPathComponent("sample_blast_concatenated.csv"), atomically: true, encoding: .utf8)
        let fixture = ConformanceFixtures.fixture("nvd/secondary-supplementary")
        for name in ["S1.filtered.bam", "S1.filtered.bam.bai"] {
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: mapped.appendingPathComponent(name))
        }
        try ">contig-1\nACGTACGT\n".write(to: results.appendingPathComponent("S1.human_virus.fasta"), atomically: true, encoding: .utf8)
        return run
    }

    /// `samtools view -c -F <mask>` over the accession of the crafted BAM, run directly.
    private static func count(_ samtools: URL, _ bam: URL, mask: String) throws -> Int {
        let result = try ProcessRunner.run(samtools, ["view", "-c", "-F", mask, bam.path, "SYN0001.1"])
        XCTAssertEqual(result.status, 0, result.stderr)
        return try XCTUnwrap(Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
