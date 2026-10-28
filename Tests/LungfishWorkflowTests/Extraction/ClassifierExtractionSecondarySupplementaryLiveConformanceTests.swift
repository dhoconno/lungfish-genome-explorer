// ClassifierExtractionSecondarySupplementaryLiveConformanceTests.swift - An extraction writes each read once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane EXTRACT-FLAGS (S1), ruling R1 of BIO's review of lane NVD. Extract Reads from an EsViritu, TaxTriage,
// NVD or NAO-MGS row runs `samtools view -c -F` (the estimate), `samtools view -b -F` (the subset) and
// `samtools fastq -F` (the writer) with `ExtractionOptions.samtoolsExcludeFlags`, which was 0x404. A `-F` given to
// `samtools fastq` replaces its own 0x900 default, so a BAM that holds secondary (0x100) or supplementary (0x800)
// records wrote a FASTQ record for each of them, and the estimate and the count shown after the write held them too.
// The mask is 0xD04 now (mapped, primary, not duplicate), the mask that counts the table's Unique Reads, so a read is
// written once, at its primary alignment, and the number written equals Unique Reads.
//
// The BAM is `Tests/Fixtures/nvd/secondary-supplementary/S1.filtered.bam`, which lane NVD's
// `NvdUniqueReadsFlagsLiveConformanceTests` imports. It has one accession, SYN0001.1, and eight single-end records of
// six reads. r3 also has a secondary record and r4 a supplementary record of 20 bases (30H20M). r5 and r6 are both
// primary at 501, so the import's markdup marks one of them a duplicate. The import stores Unique Reads 5.
//
//   after the import's markdup                          before the fix   after
//   the estimate (view -c -F <mask>)                          7            5
//   the FASTQ records (view -b -F, then fastq -F <mask>)      7            5

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// The live form, with the managed samtools (2.9 O5). `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a
/// failure. The stand-in forms are the resolver's own tests and the extraction invariants on the markers BAM.
final class ClassifierExtractionSecondarySupplementaryLiveConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExtractSecondarySupplementary")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".lungfish", isDirectory: true), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, with 7 where 5 is true. The secondary record of r3 and the supplementary record of r4 belong to
    /// reads that their primary records already write, so the estimate and the FASTQ each hold five records.
    func testExtractionWritesEachReadOnceAtItsPrimaryAlignment() async throws {
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let imported = try await MetagenomicsImportService.importNvd(
            inputURL: try Self.craftedRun(in: root),
            outputDirectory: root.appendingPathComponent("imports", isDirectory: true),
            samtoolsPath: samtools.path
        )
        let database = try NvdDatabase(at: imported.resultDirectory.appendingPathComponent("hits.sqlite"))
        let hit = try XCTUnwrap(try database.bestHits(forSamples: ["S1"]).first)
        XCTAssertEqual(hit.uniqueReads, 5, "the table's Unique Reads is the stored count, one for each read after deduplication")

        let resolver = ClassifierReadResolver()
        let selections = [ClassifierRowSelector(sampleId: "S1", accessions: [hit.sseqid])]
        let options = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        let estimate = try await resolver.estimateReadCount(
            tool: .nvd, resultPath: imported.resultDirectory, selections: selections, options: options
        )
        XCTAssertEqual(estimate, hit.uniqueReads, "the estimate is the table's Unique Reads")

        let output = root.appendingPathComponent("extracted.fastq")
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd, resultPath: imported.resultDirectory, selections: selections, options: options,
            destination: .file(output)
        )
        let records = try Self.fastqRecords(at: output)
        XCTAssertEqual(records.count, hit.uniqueReads, "the FASTQ holds one record for each of the table's Unique Reads")
        XCTAssertEqual(outcome.readCount, hit.uniqueReads, "the count the extraction reports is the table's Unique Reads")

        let names = records.map(\.name)
        XCTAssertEqual(names.filter { $0 == "r3" }.count, 1, "r3 has a primary and a secondary record, and is written once")
        XCTAssertEqual(names.filter { $0 == "r4" }.count, 1, "r4 has a primary and a supplementary record, and is written once")
        XCTAssertEqual(records.filter { $0.length == 20 }.count, 0, "the 20-base supplementary record of r4 is not written")
        XCTAssertEqual(names.count, Set(names).count, "no read name repeats: \(names.sorted())")
    }

    // MARK: - Staging

    private static let csv = """
    experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank
    EXP001,blastn,S1,contig-1,120,SYN0001.1,Synthetic virus,S,118,99.2,1e-20,250.5,Synthetic virus,12345,nt-2026,run-001,6,100000,stat-1,12345,unchanged,Synthetic virus,species

    """

    /// An NVD run of the one sample S1 whose BAM is the crafted fixture, with one BLAST hit on its accession, staged as
    /// lane NVD's `NvdUniqueReadsFlagsLiveConformanceTests` stages it.
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

    /// The records of a FASTQ file, each with its read name (the header up to the first blank) and its base count.
    private static func fastqRecords(at url: URL) throws -> [(name: String, length: Int)] {
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        XCTAssertEqual(lines.count % 4, 0, "the FASTQ file holds whole four-line records")
        return stride(from: 0, to: lines.count - 3, by: 4).map { index in
            let name = String(lines[index].dropFirst().prefix { $0 != " " && $0 != "\t" })
            return (name, lines[index + 1].count)
        }
    }
}
