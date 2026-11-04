// NaoMgsImportBamWordsTests.swift — A NAO-MGS sample whose BAM is not written stops the import with words (NAO-IMPORT-BAM-FAILED-SILENT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// QA's tests for the stage seam. Each stage of `importNaoMgs` holds one sample, so a stage that has hits and no BAM
/// is that sample's BAM not written. The stage is where the sample is named, and `importNaoMgs` wraps what it throws in
/// `importAborted`, whose description is what a person reads. Nothing here reaches a service.
struct NaoMgsImportBamWordsTests {

    private static let sample = "walk_sample"

    private static let header = [
        "sample", "seq_id", "aligner_taxid_lca", "query_seq", "query_seq_rev", "query_qual", "query_qual_rev",
        "prim_align_genome_id_all", "prim_align_ref_start", "prim_align_ref_start_rev",
        "prim_align_edit_distance", "prim_align_edit_distance_rev", "query_len", "query_len_rev",
        "prim_align_query_rc", "prim_align_query_rc_rev", "prim_align_pair_status",
        "prim_align_best_alignment_score", "prim_align_best_alignment_score_rev", "prim_align_fragment_length",
        "prim_align_cigar", "prim_align_subject_title",
    ].joined(separator: "\t")

    /// A one-sample table with one aligned pair, so the stage has hits and a BAM to write.
    private static func writeTable(in directory: URL) throws -> URL {
        let row = [
            sample, "read_001", "82658", "ACGTACGT", "TGCATGCA", "IIIIIIII", "JJJJJJJJ", "X86557.1",
            "100", "240", "1", "2", "8", "8", "False", "True", "CP", "90", "88", "148", "8M", "Lordsdale virus",
        ].joined(separator: "\t")
        let table = directory.appendingPathComponent("virus_hits_final.tsv")
        try [header, row].joined(separator: "\n").write(to: table, atomically: true, encoding: .utf8)
        return table
    }

    /// A samtools that stops at once with status 1, as one does when it cannot write its output.
    private static func failingSamtools(in directory: URL) throws -> String {
        let script = directory.appendingPathComponent("samtools")
        try "#!/bin/sh\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private static func runStage(
        in workspace: URL, samtoolsPath: String?, minIdentity: Double = 0
    ) async throws -> Result<NaoMgsSingleSampleStageResult, Error> {
        let table = try writeTable(in: workspace)
        let staging = workspace.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            return .success(try await MetagenomicsImportService.importNaoMgsSingleSampleStage(
                inputURL: table, stagingDirectory: staging, sampleName: sample,
                minIdentity: minIdentity, samtoolsPath: samtoolsPath
            ))
        } catch {
            return .failure(error)
        }
    }

    /// The description a person reads, since `importNaoMgs` wraps what its stage throws in `importAborted`.
    private static func wordsAPersonReads(_ error: Error, workspace: URL) -> String {
        MetagenomicsImportError.importAborted(resultDirectory: workspace, underlying: error).localizedDescription
    }

    @Test
    func testStageStopsAndNamesTheSampleWhoseBamCannotBeWritten() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-words")
        defer { TestTempDirectory.cleanup(workspace) }
        let samtools = try Self.failingSamtools(in: workspace)

        let outcome = try await Self.runStage(in: workspace, samtoolsPath: samtools)
        guard case .failure(let error) = outcome else {
            Issue.record("The stage returned although the BAM of \(Self.sample) was not written")
            return
        }
        let words = Self.wordsAPersonReads(error, workspace: workspace)
        #expect(words.contains(Self.sample), "The words name the sample, got: \(words)")
        #expect(words.contains("alignment file"), "The words name the alignment file, got: \(words)")
        #expect(words.contains("kept no result"), "The words say nothing was kept, got: \(words)")
        #expect(!words.lowercased().contains("disk"), "The cause is not known, so the words do not guess at the disk")
        let bam = workspace.appendingPathComponent("staging/\(Self.sample)/bams/\(Self.sample).bam")
        #expect(!FileManager.default.fileExists(atPath: bam.path), "No short BAM stays for the merge to pick up")
    }

    @Test
    func testStageWithNoSamtoolsStopsWithWords() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-no-samtools")
        defer { TestTempDirectory.cleanup(workspace) }

        let outcome = try await Self.runStage(in: workspace, samtoolsPath: nil)
        guard case .failure(let error) = outcome else {
            Issue.record("The stage returned although there was no samtools to write the BAM of \(Self.sample)")
            return
        }
        let words = Self.wordsAPersonReads(error, workspace: workspace)
        #expect(words.contains(Self.sample), "The words name the sample, got: \(words)")
        #expect(words.contains("alignment file"), "The words name the alignment file, got: \(words)")
        #expect(words.contains("samtools could not be found"), "The words say what is missing, got: \(words)")
    }

    /// Passes at the base and after the fix. It keeps the `hitCount` test honest, since a stage that `minIdentity`
    /// emptied has no hits and so no BAM to write.
    @Test
    func testStageThatMinIdentityEmptiedStillCompletes() async throws {
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-emptied")
        defer { TestTempDirectory.cleanup(workspace) }
        let samtools = try Self.failingSamtools(in: workspace)

        // The pair has 87.5 percent identity, so a floor of 99 drops it.
        let outcome = try await Self.runStage(in: workspace, samtoolsPath: samtools, minIdentity: 99)
        guard case .success(let result) = outcome else {
            Issue.record("A stage that minIdentity emptied must complete")
            return
        }
        #expect(result.hitCount == 0)
        #expect(!result.createdBAM)
    }

    /// Passes at the base and after the fix. A working samtools still gives the stage its BAM.
    @Test
    func testStageStillWritesTheBamWhenSamtoolsWorks() async throws {
        guard let samtools = SamtoolsLocator.locate() else { return }
        let workspace = try TestTempDirectory.make(prefix: "naomgs-bam-works")
        defer { TestTempDirectory.cleanup(workspace) }

        let outcome = try await Self.runStage(in: workspace, samtoolsPath: samtools)
        guard case .success(let result) = outcome else {
            Issue.record("The stage threw although samtools works: \(outcome)")
            return
        }
        #expect(result.hitCount == 1, "The table has one row, which is one hit of the stage")
        #expect(result.createdBAM)
    }
}
