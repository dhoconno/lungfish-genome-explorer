// ClassifierReadIDListConformanceTests.swift - Each classifier's extraction diffed against read-ID lists the tool gave
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane IDPINS, task 3e acceptance. Before any result viewer moves onto ViewportHost, one selection of each
// classifier goes through `ClassifierReadResolver.resolveAndExtract`, the call every viewer's Extract Reads dialog
// ends in, on a fixture with reads, and the read names it writes are compared with a list frozen from the tool's own
// output (`Resources/ClassifierReadIDLists`, the command is the second line of each file). The selections here hold no
// secondary, supplementary or duplicate record, so they pass on the extraction of today and keep passing when the
// samtools mask of extraction changes to 0xD04. The selections that hold such records are in
// `ClassifierReadIDListFlaggedConformanceTests`.
//
// Each selection is also one where `samtools fastq` writes every record the list holds. It writes one record for
// two consecutive records of one read name when neither carries a READ1 or READ2 flag, so a selection that holds
// both mates under one name (an SRA name, the mates mapped as single reads) comes out one record short, and the
// mask does not change that. No test here pins it. It is a finding in the lane report, for BIO.
//
// Fixtures. Kraken2 reads the two hand-made results in Kraken2's own file formats. EsViritu and TaxTriage read their
// `-mini` results, real pipeline BAMs. NAO-MGS imports the real `virus_hits_final.tsv.gz` rows as the app does, which
// builds the BAM and the database the viewer opens. NVD has no result of an NVD run in the repository, so its BAM is the
// sarscov2 paired-end fixture BAM, laid out where the resolver looks for an NVD sample's BAM.
//
// It runs the managed samtools and seqkit, so its name holds Conformance and it skips without them unless
// `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ClassifierReadIDListConformanceTests: XCTestCase {
    private typealias Support = ClassifierReadIDListSupport

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-read-id-list")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    // MARK: - Kraken2

    /// The taxonomy view's Extract Reads takes the taxon with its descendants. One case reaches a child
    /// (3050292 holds no read of its own, 10298 below it holds four pairs whose mates share one SRA name), one takes
    /// a taxon's own reads (exact), and one takes a genus whose two species hold the reads (`/1` and `/2` names).
    func testKraken2ExtractionWritesTheFrozenReadIDs() async throws {
        try await Support.requireTool(.seqkit)
        let cases: [(list: String, fixture: String, taxId: Int, scope: TaxonScope)] = [
            ("kraken2-interleaved-sra-names-3050292-children", "kraken2/interleaved-sra-names", 3050292, .children),
            ("kraken2-interleaved-sra-names-10325-exact", "kraken2/interleaved-sra-names", 10325, .exact),
            ("kraken2-bracken-reopen-10294-children", "kraken2-bracken-reopen", 10294, .children),
        ]
        for testCase in cases {
            let result = try Support.copyFixtureFolder(testCase.fixture, into: root, named: testCase.list)
            let names = try await Support.extract(
                .kraken2,
                result: result,
                [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [testCase.taxId])],
                options: ExtractionOptions(format: .fastq, taxonScope: testCase.scope),
                to: root.appendingPathComponent("out/\(testCase.list).fastq")
            )
            Support.assertMatches(names, try Support.list(named: testCase.list), "Kraken2 \(testCase.list)")
        }
    }

    // MARK: - EsViritu

    /// A single-sample EsViritu result, the viewer's selection of the three detected viruses of the sample, which
    /// are the three rows of `SRR35517702.detected_virus.info.tsv` (Bocaparvovirus NC_007455.1, rhinovirus A102
    /// EF155421.1 and High Island virus MF094130.1, whose 92 reads are most of the 96).
    func testEsVirituExtractionWritesTheFrozenReadIDs() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.copyFixtureFolder("esviritu-mini/SRR35517702", into: root, named: "esviritu-SRR35517702")
        let names = try await Support.extract(
            .esviritu,
            result: folder,
            [ClassifierRowSelector(
                sampleId: nil, accessions: ["NC_007455.1", "EF155421.1", "MF094130.1"], taxIds: []
            )],
            to: root.appendingPathComponent("out/esviritu.fastq")
        )
        Support.assertMatches(names, try Support.list(named: "esviritu-SRR35517702-three-viruses"), "EsViritu")
    }

    // MARK: - TaxTriage

    /// The viewer's selection of five references of one sample, whose reads hold no supplementary record.
    func testTaxTriageExtractionWritesTheFrozenReadIDs() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.copyFixtureFolder("taxtriage-mini", into: root, named: "taxtriage-mini")
        let accessions = ["NC_029119.1", "NC_033774.1", "NC_053512.1", "NC_050152.1", "NC_074405.1"]
        let names = try await Support.extract(
            .taxtriage,
            result: folder,
            [ClassifierRowSelector(sampleId: "SRR35517705", accessions: accessions, taxIds: [])],
            to: root.appendingPathComponent("out/taxtriage.fastq")
        )
        Support.assertMatches(names, try Support.list(named: "taxtriage-SRR35517705-five-contigs"), "TaxTriage")
    }

    // MARK: - NAO-MGS

    /// The result a NAO-MGS import leaves, built as the import builds it from the fixture rows (the database, the BAMs
    /// it materializes and marks, the BAM paths it records, the hits it then purges), and the selector the NAO-MGS
    /// viewer builds for one taxon of one sample: the accessions of the database's accession summaries and the
    /// taxon's read names as the allowlist.
    func testNaoMgsExtractionWritesTheFrozenReadIDs() async throws {
        let samtools = try await Support.requireTool(.samtools)
        let folder = try Support.makeResultFolder(in: root, named: "naomgs")
        let hits = folder.appendingPathComponent("hits.sqlite")
        try await Self.importNaoMgsFixture(into: folder, hits: hits, samtools: samtools)

        // The import reads the lane and the flow-cell number off the sample column, so the rows of
        // `..._20260308_S19_L002` and `..._S19_L006` make the one sample `..._20260308`. The import marks duplicates,
        // so the lists hold the reads of a taxon that are not duplicates of another read: 4 of the 6 reads of the
        // Chicago sample, 1 of the 3 of the water sample, and the 2 of the 3 of the NY sample that are a discordant
        // pair (two mates) and a single read (one record), as the Unique Reads count of the viewer holds them.
        let cases: [(list: String, sample: String, taxId: Int)] = [
            ("naomgs-IL_CHI_StickneyWS-28875", "MU-CASPER-2026-03-31-a-IL_CHI_StickneyWS_20260308", 28875),
            ("naomgs-Water-2748378", "MU-CASPER-2026-03-31-a-Water_20260323", 2748378),
            ("naomgs-NY_PLC_009-1187973", "MU-CASPER-2026-03-31-a-NY_PLC_009_20260318", 1187973),
        ]
        let database = try NaoMgsDatabase(at: hits)
        for testCase in cases {
            var seen = Set<String>()
            let accessions = try database.fetchAccessionSummaries(sample: testCase.sample, taxId: testCase.taxId)
                .map(\.accession).filter { seen.insert($0).inserted }
            let readNames = try database.fetchReadNames(sample: testCase.sample, taxId: testCase.taxId)
            XCTAssertFalse(accessions.isEmpty, "\(testCase.list) has no accession in the database")
            XCTAssertFalse(readNames.isEmpty, "\(testCase.list) has no read name in the database")

            let names = try await Support.extract(
                .naomgs,
                result: hits,
                [ClassifierRowSelector(
                    sampleId: testCase.sample, accessions: accessions, taxIds: [testCase.taxId], readNameAllowlist: readNames
                )],
                to: root.appendingPathComponent("out/\(testCase.list).fastq")
            )
            Support.assertMatches(names, try Support.list(named: testCase.list), "NAO-MGS \(testCase.list)")
        }
    }

    /// The import of the fixture rows as `MetagenomicsImportService` stages them, minus the provenance and the merge
    /// of several stage folders, which a result of one folder does not need.
    static func importNaoMgsFixture(into folder: URL, hits: URL, samtools: URL) async throws {
        _ = try await NaoMgsDatabase.createStreaming(at: hits, from: [Support.fixture("naomgs/virus_hits_final.tsv.gz")])
        let bams = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: hits.path, resultURL: folder, samtoolsPath: samtools.path
        ).bamURLs
        XCTAssertFalse(bams.isEmpty, "the import materialized no BAM")
        var pointers: [String: (bamPath: String, bamIndexPath: String?)] = [:]
        for bam in bams {
            let relative = "bams/\(bam.lastPathComponent)"
            let indexed = FileManager.default.fileExists(atPath: bam.path + ".bai")
            pointers[bam.deletingPathExtension().lastPathComponent] = (relative, indexed ? relative + ".bai" : nil)
        }
        let writable = try NaoMgsDatabase.openReadWrite(at: hits)
        try writable.updateBamPaths(pointers)
        try writable.deleteVirusHitsAndVacuum()
    }

    // MARK: - NVD

    /// The viewer's selector for one contig of one sample. The BAM is the paired-end sarscov2 fixture, whose reference
    /// stands for the contig, in the `bam/<sample>.filtered.bam` place an NVD import leaves a sample's BAM. Three of its
    /// 200 records are unmapped mates, which the extraction leaves out, so 197 records stand for 100 read names.
    func testNvdExtractionWritesTheFrozenReadIDs() async throws {
        try await Support.requireTool(.samtools)
        let folder = try Support.makeResultFolder(in: root, named: "nvd")
        try Support.place(
            bam: Support.fixture("sarscov2/test.paired_end.sorted.bam"), at: "bam/S1.filtered.bam", in: folder
        )
        let names = try await Support.extract(
            .nvd,
            result: folder.appendingPathComponent("hits.sqlite"),
            [ClassifierRowSelector(sampleId: "S1", accessions: ["MT192765.1"], taxIds: [])],
            to: root.appendingPathComponent("out/nvd.fastq")
        )
        Support.assertMatches(names, try Support.list(named: "nvd-sarscov2-paired-MT192765.1"), "NVD")
    }
}
