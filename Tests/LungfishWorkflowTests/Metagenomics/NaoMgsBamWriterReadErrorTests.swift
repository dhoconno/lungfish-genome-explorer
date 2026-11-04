// NaoMgsBamWriterReadErrorTests.swift — The NAO-MGS BAM writer keeps no short BAM and keeps samtools' own words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
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
    /// refuses.
    private static func row(_ index: Int, shortQuality: Bool = false) -> String {
        let forward = String(repeating: "ACGT", count: 37) + "AC"
        let reverse = String(repeating: "TGCA", count: 37) + "TG"
        return [
            sample, "read_\(index)", "82658", forward, reverse,
            shortQuality ? "II" : String(repeating: "I", count: 150), String(repeating: "J", count: 150),
            "X86557.1", String(100 + index % 500), String(400 + index % 500), "1", "2", "150", "150",
            "False", "True", "CP", "90", "88", "450", "150M", "Lordsdale virus",
        ].joined(separator: "\t")
    }

    /// A stage database of `rows` pairs, made by the importer, and the folder that would hold its `bams/`.
    private static func buildDatabase(
        in workspace: URL, rows: Int, shortQualityOnFirstRow: Bool
    ) async throws -> (database: URL, stageDir: URL) {
        let table = workspace.appendingPathComponent("virus_hits_final.tsv")
        let lines = [header] + (0..<rows).map { row($0, shortQuality: shortQualityOnFirstRow && $0 == 0) }
        try lines.joined(separator: "\n").write(to: table, atomically: true, encoding: .utf8)
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
}
