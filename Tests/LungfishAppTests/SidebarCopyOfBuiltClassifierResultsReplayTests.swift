// SidebarCopyOfBuiltClassifierResultsReplayTests.swift - A sidebar copy of a result that build-db built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane FXA2, QA's test in ARCH's ruling on A45 M3 (section 4) and follow-up 2 of the A39 review. A built
// EsViritu batch is a pin that passes at its base. A Kraken2 sample after `build-db kraken2` is the red case until the
// cleanup stops changing the files the classifier's record names.
//
// The sidebar copies an item with `FileManager.copyItem` and then calls `rehydrateScientificProvenance`
// (`SidebarViewController+ScientificProvenance.swift`). Two shapes of item carry a record.
//
// - A file with a sidecar next to it (the database, a BAM, a result sidecar). The schema-aware path finds the sidecar,
//   holds with no fallback and writes the copy's record into the project.
// - A result folder. A plain folder in a project holds its own records, which the schema-aware path never read, so the
//   sidebar rebinds them with `ProvenancePathRehydrator` (2.10 R-REBIND, SidebarMoveOfABuiltResultFolderReplayTests)
//   and the copy's records name the copy's files. Before that the copy kept every record of the source, which named the
//   source folder's files, and the folder half of each test checked the source as `build-db` left it. It now reads the
//   copy's own files.
//
// Both results are built in process with stand-ins, `build-db esviritu` over placeholder BAMs and `build-db kraken2`
// over `Tests/Fixtures/kraken2-mini`, so no real tool runs. The class name ends in ReplayTests, which sends it to the
// replay step with the other sidebar and classifier replays.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class SidebarCopyOfBuiltClassifierResultsReplayTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "SidebarCopyOfBuiltClassifierResults")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Analyses", isDirectory: true), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The pin

    /// A pin. A copy of a built EsViritu batch holds the records the build left, rebound to the copy's files, and each
    /// names files that exist with the digests it states. A step may name a `_temp/` BAM that the move took away when a removal step of its
    /// record says so (P1 of Phase 2.8), and the run level names only what is on disk (B3).
    func testASidebarCopyOfABuiltEsVirituBatchHoldsRecordsThatNameExistingFiles() async throws {
        let batch = project.appendingPathComponent("Analyses/esviritu-batch", isDirectory: true)
        try Self.makeEsVirituStandIn(at: batch, samples: ["S1", "S2"])
        try await BuildDbCommand.EsVirituSubcommand.parse([batch.path, "-q"]).run()

        let copy = try sidebarCopy(of: batch)

        let records = try BuiltResultRecordChecks.recordsOfTheTree(at: copy)
        XCTAssertEqual(records.map(\.name), [
            ".lungfish-provenance.json",
            "S1/bams/S1.third.filt.sorted.bam.bai.lungfish-provenance.json", "S1/bams/S1.third.filt.sorted.bam.lungfish-provenance.json",
            "S2/bams/S2.third.filt.sorted.bam.bai.lungfish-provenance.json", "S2/bams/S2.third.filt.sorted.bam.lungfish-provenance.json",
            "esviritu.sqlite.lungfish-provenance.json",
        ], "the copy holds the records of the source")
        XCTAssertEqual(BuiltResultRecordChecks.problems(of: records), [])
        try assertFilesWithASidecarRehydrate(
            in: batch, ["esviritu.sqlite", "S1/bams/S1.third.filt.sorted.bam", "S2/bams/S2.third.filt.sorted.bam"]
        )
    }

    // MARK: - The red case

    /// A copy of a Kraken2 sample after `build-db kraken2` holds the classifier's record, and every file it names exists
    /// with the digest it states. At the base the cleanup had removed the raw per-read output and rewritten the
    /// sidecar in place, so the record named a file that was gone and bytes the sidecar no longer had.
    func testASidebarCopyOfAKraken2SampleAfterBuildDbHoldsRecordsThatNameExistingFiles() async throws {
        let batch = project.appendingPathComponent("Analyses/kraken2-batch", isDirectory: true)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: batch)
        let sample = batch.appendingPathComponent("SRR35517702", isDirectory: true)
        // The record the app writes for a Kraken2 result, from the sidecar. It names the report, the raw per-read
        // output the fixture keeps and the sidecar, each with its digest, and `build-db` may not replace it.
        try ProvenanceWriter().write(ClassificationProvenanceReconstructor.reconstructEnvelope(resultDirectory: sample), to: sample)
        try await BuildDbCommand.Kraken2Subcommand.parse([batch.path, "-q"]).run()

        let copy = try sidebarCopy(of: sample)

        let records = try BuiltResultRecordChecks.recordsOfTheTree(at: copy)
        let classifier = try XCTUnwrap(records.first { $0.name == ".lungfish-provenance.json" }, "the sample's own record")
        XCTAssertEqual(classifier.envelope.workflowName, "Metagenomics Classification", "build-db leaves the classifier's record")
        XCTAssertEqual(BuiltResultRecordChecks.problems(of: records), [])
        try assertFilesWithASidecarRehydrate(in: batch, ["kraken2.sqlite", "SRR35517703/classification-result.json"])
    }

    // MARK: - The sidebar's copy

    /// What the sidebar does for an item: copies it, then rehydrates its provenance.
    private func sidebarCopy(of source: URL) throws -> URL {
        let copies = project.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent
        let destination = copies.appendingPathComponent(source.pathExtension.isEmpty ? "\(stem) copy" : "\(stem) copy.\(source.pathExtension)")
        try FileManager.default.copyItem(at: source, to: destination)
        SidebarViewController().rehydrateScientificProvenance(from: source, to: destination)
        return destination
    }

    /// For each file of `folder` named in `relativePaths`, a copy through the sidebar finds the file's sidecar in the schema-aware path,
    /// and what the rehydration wrote is the copy's record. It is the project's output sidecar, not a sidecar beside
    /// the copy (the fallback), and it ends in the import step and names the copy with the digest the copy has.
    private func assertFilesWithASidecarRehydrate(in folder: URL, _ relativePaths: [String]) throws {
        for relativePath in relativePaths {
            let source = folder.appendingPathComponent(relativePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: source).path), "\(relativePath) has a sidecar"
            )
            let copy = try sidebarCopy(of: source)
            let sidecar = try XCTUnwrap(
                ProvenanceWriter.bundleOutputSidecarURL(for: copy, inBundle: project), "\(relativePath) has a place in the project's records"
            )
            let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecar), "\(relativePath) was rehydrated by the schema-aware path")
            XCTAssertEqual(record.steps.last?.toolName, LungfishAppIdentity.recordedToolName, "\(relativePath) ends in the import step")
            let named = record.outputs.first { BuiltResultRecordChecks.resolved($0.path) == BuiltResultRecordChecks.resolved(copy.path) }
            XCTAssertNotNil(named, "\(relativePath) names its copy")
            XCTAssertEqual(named?.checksumSHA256, ProvenanceRecorder.sha256(of: copy), "\(relativePath) names its copy with the digest the copy has")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: copy).path), "\(relativePath) took no fallback to a sidecar beside the copy"
            )
        }
    }

    // MARK: - The stand-in EsViritu batch

    /// A batch whose samples each hold a detection table with its header only and a placeholder BAM and index in
    /// `<sample>_temp/`, as `BuildDbEsVirituRunLevelTests` stages it, so `build-db esviritu` moves the BAMs to `bams/`
    /// and removes `_temp/` with no samtools.
    private static func makeEsVirituStandIn(at batch: URL, samples: [String]) throws {
        let header = [
            "sample_ID", "name", "description", "length", "segment", "accession", "assembly", "assembly_length", "kingdom",
            "phylum", "class", "order", "family", "genus", "species", "subspecies", "rpkmf", "read_count", "covered_bases",
            "mean_coverage", "avg_read_identity", "pi", "filtered_reads_in_sample",
        ].joined(separator: "\t")
        for sample in samples {
            let folder = batch.appendingPathComponent(sample, isDirectory: true)
            let temp = folder.appendingPathComponent("\(sample)_temp", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try Data((header + "\n").utf8).write(to: folder.appendingPathComponent("\(sample).detected_virus.info.tsv"))
            try Data("stand-in BAM of \(sample)\n".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam"))
            try Data("stand-in index of \(sample)\n".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam.bai"))
        }
    }
}
