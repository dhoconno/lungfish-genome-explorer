// NaoMgsBamWriterReadErrorTests.swift — The NAO-MGS BAM writer keeps no short BAM and keeps samtools' own words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Two ways the stream to samtools ends early, each on the real samtools (SWIFT's round 2 in the NAOBAM review).
/// A database that cannot be read to its end must leave no BAM, since the import purges the rows once a BAM stands.
/// A row samtools cannot parse must reach the person as samtools' own line, not as the broken pipe that the writer saw
/// after samtools had stopped.
struct NaoMgsBamWriterReadErrorTests {

    private static let sample = "walk_sample"

    private static let header = [
        "sample", "seq_id", "aligner_taxid_lca", "query_seq", "query_seq_rev", "query_qual", "query_qual_rev",
        "prim_align_genome_id_all", "prim_align_ref_start", "prim_align_ref_start_rev",
        "prim_align_edit_distance", "prim_align_edit_distance_rev", "query_len", "query_len_rev",
        "prim_align_query_rc", "prim_align_query_rc_rev", "prim_align_pair_status",
        "prim_align_best_alignment_score", "prim_align_best_alignment_score_rev", "prim_align_fragment_length",
        "prim_align_cigar", "prim_align_subject_title",
    ].joined(separator: "\t")

    /// One aligned pair of 150 bases each. `shortQuality` gives the first mate 2 quality characters, which samtools
    /// refuses. Each other parameter replaces the text of one field as the file would give it (`""` is an empty
    /// field and `"NA"` the file's mark for a missing value).
    private static func row(
        _ index: Int, shortQuality: Bool = false, quality: String? = nil, qualityRev: String? = nil,
        sequence: String? = nil, sequenceRev: String? = nil, start: String? = nil, startRev: String? = nil,
        lengthRev: String = "150"
    ) -> String {
        let forward = String(repeating: "ACGT", count: 37) + "AC"
        let reverse = String(repeating: "TGCA", count: 37) + "TG"
        return [
            sample, "read_\(index)", "82658", sequence ?? forward, sequenceRev ?? reverse,
            quality ?? (shortQuality ? "II" : String(repeating: "I", count: 150)),
            qualityRev ?? String(repeating: "J", count: 150),
            "X86557.1", start ?? String(100 + index % 500), startRev ?? String(400 + index % 500), "1", "2", "150", lengthRev,
            "False", "True", "CP", "90", "88", "450", "150M", "Lordsdale virus",
        ].joined(separator: "\t")
    }

    /// A stage database of `rows` pairs, made by the importer, and the folder that would hold its `bams/`.
    private static func buildDatabase(
        in workspace: URL, rows: Int, shortQualityOnFirstRow: Bool
    ) async throws -> (database: URL, stageDir: URL) {
        try await buildDatabase(in: workspace, lines: (0..<rows).map { row($0, shortQuality: shortQualityOnFirstRow && $0 == 0) })
    }

    /// A stage database of the table rows `lines`, made by the importer, and the folder that would hold its `bams/`.
    private static func buildDatabase(
        in workspace: URL, lines: [String]
    ) async throws -> (database: URL, stageDir: URL) {
        let table = workspace.appendingPathComponent("virus_hits_final.tsv")
        try ([header] + lines).joined(separator: "\n").write(to: table, atomically: true, encoding: .utf8)
        let stageDir = workspace.appendingPathComponent("staging/\(sample)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let database = stageDir.appendingPathComponent("hits.sqlite")
        _ = try await NaoMgsDatabase.createStreaming(at: database, from: [table], sampleNameOverride: sample, minIdentity: 0)
        return (database, stageDir)
    }

    /// Zeroes `count` pages of the database file from `fraction` of the way through it, as a bad sector does. The hits
    /// are written first and far outweigh the summaries, so the pages are rows of the scan and not its summaries.
    private static func zeroPages(of database: URL, from fraction: Double, count: Int) throws {
        let handle = try FileHandle(forUpdating: database)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 100) ?? Data()
        let declared = head.count > 17 ? Int(head[16]) << 8 | Int(head[17]) : 4096
        let pageSize = declared == 1 ? 65_536 : declared
        let pages = Int(try handle.seekToEnd()) / pageSize
        try handle.seek(toOffset: UInt64(max(3, Int(Double(pages) * fraction)) * pageSize))
        try handle.write(contentsOf: Data(count: pageSize * count))
    }

    /// Passes only when the scan of the rows ends in SQLITE_DONE. A scan that ends on any other code gave a BAM that
    /// stopped at the damaged page, and the import then purged the rows it came from.
    @Test(ManagedSamtoolsGate.enabled)
    func testRowReadErrorMidScanLeavesNoBam() async throws {
        let samtools = try #require(SamtoolsLocator.locate())
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-read-error")
        defer { TestTempDirectory.cleanup(workspace) }
        let (database, stageDir) = try await Self.buildDatabase(in: workspace, rows: 4000, shortQualityOnFirstRow: false)
        try Self.zeroPages(of: database, from: 0.35, count: 24)

        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: database.path, resultURL: stageDir, samtoolsPath: samtools, lungfishVersion: "test"
        )
        #expect(result.bamURLs.isEmpty, "A BAM cut short at the damaged page is no BAM of the sample")
        let reason = result.failures[Self.sample] ?? ""
        #expect(!reason.isEmpty, "The sample is recorded as failed, with the reason from SQLite")
        let bam = stageDir.appendingPathComponent("bams/\(Self.sample).bam")
        #expect(!FileManager.default.fileExists(atPath: bam.path), "No short BAM stays for the merge to pick up")
    }

    /// The first pair has 2 quality characters for 150 bases, so samtools stops at line 3. Past one 64 KiB batch the
    /// writer sees a broken pipe, and the sample must still fail with samtools' own line.
    @Test(ManagedSamtoolsGate.enabled)
    func testImportStopsOnARowSamtoolsCannotParse() async throws {
        let samtools = try #require(SamtoolsLocator.locate())
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-parse-error")
        defer { TestTempDirectory.cleanup(workspace) }
        let (database, stageDir) = try await Self.buildDatabase(in: workspace, rows: 1000, shortQualityOnFirstRow: true)

        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: database.path, resultURL: stageDir, samtoolsPath: samtools, lungfishVersion: "test"
        )
        #expect(result.bamURLs.isEmpty, "A BAM that samtools stopped on is no BAM")
        let reason = result.failures[Self.sample] ?? ""
        #expect(reason.contains("Parse error"), "samtools' own line reaches the reason, got: \(reason)")
        #expect(!reason.contains("Broken pipe"), "The pipe that broke after samtools stopped says nothing, got: \(reason)")
        let bam = stageDir.appendingPathComponent("bams/\(Self.sample).bam")
        #expect(!FileManager.default.fileExists(atPath: bam.path), "No short BAM stays for the merge to pick up")
    }

    // MARK: - A mate with no quality, and the count the BAM must match

    /// The records of `bam` as `samtools view` prints them, each split into its tab-separated fields.
    private static func records(of bam: URL, samtools: String) throws -> [[String]] {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: samtools), arguments: ["view", bam.path],
            environment: ToolProcessSpec.inheritedEnvironment(), stderr: .discard, label: "samtools view"
        )
        let result = try ToolProcess.runBlocking(spec)
        #expect(result.isSuccess, "samtools reads the BAM it was given")
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Which mate of which read a paired record is, as `read_0/1`.
    private static func mateName(_ record: [String]) -> String {
        "\(record[0])/\((Int(record[1]) ?? 0) & 0x40 != 0 ? 1 : 2)"
    }

    /// Four pairs each have one mate with no quality: an empty R1 quality, an R1 quality of `NA`, an empty R2 quality
    /// and an R2 quality of `NA`. The bases are there, so the record stays and writes `*`, SAM's own mark for a missing
    /// quality. At the base samtools refused the two R1 mates (QUAL and SEQ of different lengths), which stopped the
    /// import of every sample, and the writer dropped the two R2 mates with no word.
    @Test(ManagedSamtoolsGate.enabled)
    func testRowWithNoQualityKeepsItsRecord() async throws {
        let samtools = try #require(SamtoolsLocator.locate())
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-no-quality")
        defer { TestTempDirectory.cleanup(workspace) }
        let (database, stageDir) = try await Self.buildDatabase(in: workspace, lines: [
            Self.row(0, quality: ""), Self.row(1, quality: "NA"), Self.row(2, qualityRev: ""), Self.row(3, qualityRev: "NA"),
        ])

        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: database.path, resultURL: stageDir, samtoolsPath: samtools, lungfishVersion: "test"
        )
        #expect(result.failures[Self.sample] == nil, "A mate with no quality keeps its record, got: \(result.failures[Self.sample] ?? "")")
        let bam = try #require(result.bamURLs.first, "The sample has its BAM")
        #expect(result.bamURLs.count == 1)
        let records = try Self.records(of: bam, samtools: samtools)
        #expect(records.count == 8, "Both mates of the four pairs are in the BAM, got \(records.count)")
        let withoutQuality = Set(records.filter { $0.count > 10 && $0[10] == "*" }.map(Self.mateName))
        #expect(withoutQuality == ["read_0/1", "read_1/1", "read_2/2", "read_3/2"],
                "Field 11 is * on the four mates that had no quality and on no other, got: \(withoutQuality.sorted())")
    }

    /// `query_len_rev` is the file's word, and the sequence is what samtools checks. A second mate of 150 bases whose
    /// `query_len_rev` says 120 gets the CIGAR of its sequence. At the base its CIGAR read 120M, which samtools refused.
    @Test(ManagedSamtoolsGate.enabled)
    func testMate2CigarComesFromItsSequence() async throws {
        let samtools = try #require(SamtoolsLocator.locate())
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-mate-cigar")
        defer { TestTempDirectory.cleanup(workspace) }
        let (database, stageDir) = try await Self.buildDatabase(in: workspace, lines: [Self.row(0, lengthRev: "120")])

        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: database.path, resultURL: stageDir, samtoolsPath: samtools, lungfishVersion: "test"
        )
        #expect(result.failures[Self.sample] == nil, "No CIGAR is refused, got: \(result.failures[Self.sample] ?? "")")
        let bam = try #require(result.bamURLs.first, "The sample has its BAM")
        let records = try Self.records(of: bam, samtools: samtools)
        #expect(records.count == 2, "Both mates are in the BAM, got \(records.count)")
        let mate2 = try #require(records.first { Self.mateName($0) == "read_0/2" }, "The second mate is in the BAM")
        #expect(mate2[5] == "150M", "The CIGAR of the second mate is the length of its sequence, got: \(mate2[5])")
    }

    /// The import purges the stored rows once a BAM stands, so a mate the importer counted and the writer left out is
    /// lost with no word. Eight pairs cover the ways a mate is counted or not, and the BAM must hold exactly the mates
    /// the importer counted. At the base the empty-quality R2 was counted and not written, and the R1 with a quality of
    /// `NA` made samtools refuse the sample.
    @Test(ManagedSamtoolsGate.enabled)
    func testBamHoldsEveryMateTheDatabaseCounted() async throws {
        let samtools = try #require(SamtoolsLocator.locate())
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-counted")
        defer { TestTempDirectory.cleanup(workspace) }
        let (database, stageDir) = try await Self.buildDatabase(in: workspace, lines: [
            Self.row(0),                                       // both mates placed
            Self.row(1, startRev: "0"),                        // R2 at the first base
            Self.row(2, qualityRev: "NA", sequenceRev: "NA"),  // R1 only
            Self.row(3, quality: "NA", sequence: "NA"),        // R2 only
            Self.row(4, qualityRev: ""),                       // R2 with an empty quality
            Self.row(5, quality: "NA"),                        // R1 with a quality of NA
            Self.row(6, start: "NA"),                          // R1 with a sequence and no start, beside a placed R2
            Self.row(7, startRev: "NA"),                       // R2 with a sequence and no start, beside a placed R1
        ])

        let result = try NaoMgsBamMaterializer.materializeAllWithProvenance(
            dbPath: database.path, resultURL: stageDir, samtoolsPath: samtools, lungfishVersion: "test"
        )
        #expect(result.failures.isEmpty, "No sample fails, got: \(result.failures)")
        let bam = try #require(result.bamURLs.first, "The sample has its BAM")
        let counted = try NaoMgsDatabase(at: database).fetchTaxonSummaryRows(samples: nil).reduce(0) { $0 + $1.hitCount }
        let records = try Self.records(of: bam, samtools: samtools)
        #expect(counted > 0, "The importer counted mates")
        #expect(records.count == counted, "The BAM holds \(records.count) records and the importer counted \(counted) mates")
    }
}
