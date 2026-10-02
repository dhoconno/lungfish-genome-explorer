// NvdImportSamtoolsParityTests.swift - The NVD import counts the same reads in the app and the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Import Center imports an NVD run through MetagenomicsImportHelper, which
// hands MetagenomicsImportService.importNvd the managed samtools, so the copied
// BAMs get duplicate marks and every hit gets a unique-read count. The
// Operations panel records `lungfish-cli import nvd` for that import, and
// `nvd import` is its second spelling. Both commands passed no samtools, so a
// pasted command skipped duplicate marking and left every unique-read count
// empty (R3). They now resolve the managed samtools the way the app does.
// This test imports one small NVD run all three ways and compares the counts.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow

final class NvdImportSamtoolsParityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-samtools-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// An NVD run with one sample whose BAM is the SARS-CoV-2 fixture, and two
    /// BLAST hits on its reference, the layout `05_labkey_bundling` plus
    /// `02_human_viruses/03_human_virus_results` that the importer reads.
    private func makeNvdRun() throws -> URL {
        let fileManager = FileManager.default
        let run = root.appendingPathComponent("nvd-run", isDirectory: true)
        let labkey = run.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        let results = run.appendingPathComponent("02_human_viruses/03_human_virus_results", isDirectory: true)
        let mappedReads = results.appendingPathComponent("mapped_reads", isDirectory: true)
        try fileManager.createDirectory(at: labkey, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mappedReads, withIntermediateDirectories: true)
        let header = "experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,"
            + "bitscore,sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,"
            + "stat_db_version,adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank"
        let rows = [
            "EXP001,megablast,S1,NODE_1,29829,MT192765.1,Severe acute respiratory syndrome coronavirus 2,"
                + "species:SARS-CoV-2,29800,99.9,0.0,55000.0,SARS-CoV-2,2697049,2.5.0,run-001,197,200,"
                + "2.5.0,2697049,dominant,SARS-CoV-2,species",
            "EXP001,megablast,S1,NODE_2,1200,MT192765.1,Severe acute respiratory syndrome coronavirus 2,"
                + "species:SARS-CoV-2,1190,99.1,0.0,2100.0,SARS-CoV-2,2697049,2.5.0,run-001,40,200,"
                + "2.5.0,2697049,dominant,SARS-CoV-2,species",
        ]
        try ([header] + rows).joined(separator: "\n").appending("\n")
            .write(to: labkey.appendingPathComponent("EXP001_blast_concatenated.csv"), atomically: true, encoding: .utf8)
        try fileManager.copyItem(
            at: TestFixtures.sarscov2.sortedBam,
            to: mappedReads.appendingPathComponent("S1.filtered.bam")
        )
        try fileManager.copyItem(
            at: TestFixtures.sarscov2.bamIndex,
            to: mappedReads.appendingPathComponent("S1.filtered.bam.bai")
        )
        try ">NODE_1\nACGT\n>NODE_2\nACGT\n".write(
            to: results.appendingPathComponent("S1.human_virus.fasta"),
            atomically: true,
            encoding: .utf8
        )
        return run
    }

    /// The counts an import produced, read back from its bundle.
    private struct ImportCounts: Equatable {
        let uniqueReads: [String: Int?]
        let markdupBAMCount: ParameterValue?
        let uniqueReadRowsUpdated: ParameterValue?
        let samtoolsSteps: Int
    }

    private func counts(in bundle: URL) throws -> ImportCounts {
        let database = try NvdDatabase(at: bundle.appendingPathComponent("hits.sqlite"))
        var uniqueReads: [String: Int?] = [:]
        for hit in try database.childHits(sampleId: "S1", qseqid: "NODE_1")
            + database.childHits(sampleId: "S1", qseqid: "NODE_2") {
            uniqueReads["\(hit.qseqid) \(hit.sseqid)"] = hit.uniqueReads
        }
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
        return ImportCounts(
            uniqueReads: uniqueReads,
            markdupBAMCount: envelope.options.resolvedDefaults["markdupBAMCount"],
            uniqueReadRowsUpdated: envelope.options.resolvedDefaults["uniqueReadRowsUpdated"],
            samtoolsSteps: envelope.steps.filter { $0.toolName == "samtools" }.count
        )
    }

    func testAppHelperAndBothCLISpellingsProduceTheSameCounts() async throws {
        guard BundleBuildHelpers.managedToolExecutablePath(.samtools) != nil else {
            throw XCTSkip("The managed samtools is not installed, so the app skips duplicate marking too.")
        }
        let run = try makeNvdRun()

        // The app's path: the Import Center's helper process, run in process.
        // The helper waits on a semaphore for its own task, so it runs on a
        // dispatch thread rather than one of Swift's cooperative threads.
        let appOutput = root.appendingPathComponent("app", isDirectory: true)
        let helperArguments = [
            "Lungfish", "--metagenomics-import-helper",
            "--kind", "nvd",
            "--input-path", run.path,
            "--output-dir", appOutput.path,
        ]
        let status: Int32? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: MetagenomicsImportHelper.runIfRequested(arguments: helperArguments))
            }
        }
        XCTAssertEqual(status, 0)
        let app = try counts(in: appOutput.appendingPathComponent("nvd-EXP001", isDirectory: true))
        XCTAssertFalse(app.uniqueReads.isEmpty)
        XCTAssertTrue(app.uniqueReads.values.allSatisfy { $0 != nil }, "the app counts unique reads: \(app)")
        XCTAssertGreaterThan(app.samtoolsSteps, 0)

        // The command the Operations panel records, and its second spelling.
        for spelling in [["import", "nvd"], ["nvd", "import"]] {
            let output = root.appendingPathComponent(spelling.joined(separator: "-"), isDirectory: true)
            let parsed = try LungfishCLI.parseAsRoot(spelling + [run.path, "--output-dir", output.path, "--quiet"])
            var command = try XCTUnwrap(parsed as? AsyncParsableCommand)
            try await command.run()
            let cli = try counts(in: output.appendingPathComponent("nvd-EXP001", isDirectory: true))
            XCTAssertEqual(cli, app, "lungfish-cli \(spelling.joined(separator: " ")) counts as the app does")
        }
    }
}
