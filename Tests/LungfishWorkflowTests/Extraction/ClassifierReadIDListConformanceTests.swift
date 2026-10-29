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

    // MARK: - NAO-MGS orientation (lane NAO-BAM-ORIENT, BIO ruling BIO-NAO-BAM-ORIENT)

    /// NAO-MGS holds each mate as the instrument sequenced it and names the strand it aligned to (`prim_align_query_rc`).
    /// SAM wants a record flagged 0x10 to hold the reverse complement, so the BAM of the import must, and `samtools fastq`
    /// then gives each read back as sequenced. The read ending `:2423:14340:5078` of the Los Angeles sample is a pair
    /// whose two mates read the whole 106-base insert, R1 on the reverse strand and `query_seq` the reverse complement of
    /// `query_seq_rev`, so on the reference strand both records hold one string.
    func testNaoMgsBamStoresReverseFlaggedRecordsInReferenceOrientation() async throws {
        let samtools = try await Support.requireTool(.samtools)
        let folder = try Support.makeResultFolder(in: root, named: "naomgs")
        let hits = folder.appendingPathComponent("hits.sqlite")
        try await Self.importNaoMgsFixture(into: folder, hits: hits, samtools: samtools)

        let name = "LH00642:161:23KFJ7LT4:1:2423:14340:5078"
        let rows = try Self.fixtureRows().filter { $0.name == name }
        XCTAssertEqual(rows.count, 1, "one row of the fixture holds the read \(name)")
        let mates = try XCTUnwrap(rows.first?.mates)
        XCTAssertEqual(mates.count, 2, "the read is a pair")
        guard mates.count == 2 else { return }

        let bam = folder.appendingPathComponent("bams/MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304.bam")
        let records = try Self.samtoolsText(samtools, ["view", bam.path]).split(separator: "\n").compactMap { line -> BAMRecord? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields[0] == name else { return nil }
            return BAMRecord(flag: Int(fields[1]) ?? -1, position: fields[3], cigar: fields[5], sequence: fields[9])
        }
        XCTAssertEqual(records.map(\.flag).sorted(), [83, 163], "the read is one pair with R1 on the reverse strand")
        let reverse = try XCTUnwrap(records.first { $0.flag == 83 })
        let forward = try XCTUnwrap(records.first { $0.flag == 163 })
        XCTAssertEqual([reverse.position, forward.position], ["1495", "1495"], "both mates start at 1495")
        XCTAssertEqual([reverse.cigar, forward.cigar], ["106M", "106M"], "both mates are 106M")
        XCTAssertEqual(
            reverse.sequence, forward.sequence,
            "mates that read one insert hold one string on the reference strand (flag 83 against flag 163)"
        )
        XCTAssertEqual(
            reverse.sequence, Self.reverseComplement(mates[0].sequence),
            "the flag-83 record holds the reverse complement of query_seq"
        )
        XCTAssertEqual(forward.sequence, mates[1].sequence, "the flag-163 record is query_seq_rev as sequenced")

        let byName = root.appendingPathComponent("by-name.bam")
        _ = try Self.samtoolsText(samtools, ["sort", "-n", "-o", byName.path, bam.path])
        let fastq = Self.fastqRecords(try Self.samtoolsText(samtools, ["fastq", byName.path]))
        XCTAssertEqual(fastq.first { $0.name == "\(name)/1" }?.sequence, mates[0].sequence, "samtools fastq /1 is query_seq")
        XCTAssertEqual(fastq.first { $0.name == "\(name)/2" }?.sequence, mates[1].sequence, "samtools fastq /2 is query_seq_rev")
    }

    /// Every record the extraction writes for the three NAO-MGS selections is a mate as the instrument sequenced it. The
    /// sorted (name, SEQ, QUAL) of the written FASTQ equal those of the fixture's `query_seq` and `query_qual` (R1) and
    /// `query_seq_rev` and `query_qual_rev` (R2), for the reads the frozen list holds.
    func testNaoMgsExtractionWritesEveryMateAsSequenced() async throws {
        let samtools = try await Support.requireTool(.samtools)
        let folder = try Support.makeResultFolder(in: root, named: "naomgs")
        let hits = folder.appendingPathComponent("hits.sqlite")
        try await Self.importNaoMgsFixture(into: folder, hits: hits, samtools: samtools)
        let rows = try Self.fixtureRows()

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
            let output = root.appendingPathComponent("out/\(testCase.list).fastq")
            _ = try await Support.extract(
                .naomgs,
                result: hits,
                [ClassifierRowSelector(
                    sampleId: testCase.sample, accessions: accessions, taxIds: [testCase.taxId], readNameAllowlist: readNames
                )],
                to: output
            )
            let written = Self.fastqRecords(try String(contentsOf: output, encoding: .utf8))
                .map { "\($0.name)\t\($0.sequence)\t\($0.quality)" }.sorted()

            var expected: [String] = []
            for id in try Support.list(named: testCase.list).ids {
                let held = rows.filter { $0.name == id && $0.sample.hasPrefix(testCase.sample + "_") }
                XCTAssertEqual(held.count, 1, "\(testCase.list) read \(id) is one row of the fixture")
                expected += held.flatMap(\.mates).map { "\(id)\t\($0.sequence)\t\($0.quality)" }
            }
            XCTAssertFalse(expected.isEmpty, "\(testCase.list) holds no mate")
            XCTAssertEqual(written, expected.sorted(), "NAO-MGS \(testCase.list) writes each mate as the instrument sequenced it")
        }
    }

    /// One row of `Tests/Fixtures/naomgs/virus_hits_final.tsv.gz`, read from the file with `gzip` and not through the
    /// parser. `mates` holds R1 then R2 as sequenced, for each mate the row has both a sequence and a start for.
    private struct FixtureRow {
        let name: String
        let sample: String
        let mates: [(sequence: String, quality: String)]
    }

    /// A BAM record of the one read the orientation test follows.
    private struct BAMRecord {
        let flag: Int
        let position: String
        let cigar: String
        let sequence: String
    }

    private static func fixtureRows() throws -> [FixtureRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", Support.fixture("naomgs/virus_hits_final.tsv.gz").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Support.SupportError(description: "gzip could not read the NAO-MGS fixture") }
        let table = text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard let header = table.first else { throw Support.SupportError(description: "the NAO-MGS fixture is empty") }
        func column(_ title: String) throws -> Int {
            guard let index = header.firstIndex(of: title) else { throw Support.SupportError(description: "the fixture has no \(title) column") }
            return index
        }
        let (name, sample) = (try column("seq_id"), try column("sample"))
        let (seq1, qual1, start1) = (try column("query_seq"), try column("query_qual"), try column("prim_align_ref_start"))
        let (seq2, qual2, start2) = (try column("query_seq_rev"), try column("query_qual_rev"), try column("prim_align_ref_start_rev"))
        func present(_ field: String) -> Bool { !field.isEmpty && field != "NA" }
        return table.dropFirst().map { fields in
            var mates: [(sequence: String, quality: String)] = []
            if present(fields[seq1]), present(fields[start1]) { mates.append((fields[seq1], fields[qual1])) }
            if present(fields[seq2]), present(fields[start2]) { mates.append((fields[seq2], fields[qual2])) }
            return FixtureRow(name: fields[name], sample: fields[sample], mates: mates)
        }
    }

    /// The standard output of `samtools <arguments>`.
    private static func samtoolsText(_ samtools: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = samtools
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Support.SupportError(description: "samtools \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(stderr)")
        }
        return text
    }

    /// The records of a plain FASTQ text as (name up to the first space or tab, SEQ, QUAL), in file order.
    private static func fastqRecords(_ text: String) -> [(name: String, sequence: String, quality: String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var records: [(name: String, sequence: String, quality: String)] = []
        var index = 0
        while index + 3 < lines.count {
            let name = lines[index].dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            records.append((name, lines[index + 1], lines[index + 3]))
            index += 4
        }
        return records
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A", "N": "N"]
        return String(sequence.reversed().map { complement[$0] ?? "N" })
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
