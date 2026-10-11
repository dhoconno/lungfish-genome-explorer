// ProvenanceRecorderSavePinScenarios.swift - Recorder runs whose saved bytes the save pins capture
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// The runs `ProvenanceRecorderSaveBytePinTests` captures. Each one records through a recorder of its
/// own on a stepped time source, so its dates and wall times are the same on every run, saves, and
/// returns the sidecar it saved. Paths under `/fixture` name files that never exist, and each of them
/// carries a checksum and size the scenario gives it.
enum ProvenanceRecorderSavePinScenarios {
    /// 2026-10-07T00:00:00Z, where every scenario's clock starts.
    static let start = Date(timeIntervalSince1970: 1_791_331_200)

    /// A Kraken2 run as `ClassificationPipeline` records it. Two steps on files that exist, a first
    /// step whose durable argv differs from its argv, a raw output removed before the save, and a save
    /// with explicit, default and resolved options that drops the run-level files that are gone.
    static func completedRunWithOptions(in directory: URL) async throws -> URL {
        let analysis = directory.appendingPathComponent("Kraken2 run", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let reads1 = try write("@r1/1\nACGTACGT\n+\nIIIIIIII\n", to: directory.appendingPathComponent("reads_R1.fastq"))
        let reads2 = try write("@r1/2\nTGCATGCA\n+\nIIIIIIII\n", to: directory.appendingPathComponent("reads_R2.fastq"))
        let raw = try write("C\tr1\t10239\t8\t10239:1\n", to: analysis.appendingPathComponent("classification.kraken"))
        let report = try write("100.00\t1\t0\tR\t1\troot\n", to: analysis.appendingPathComponent("classification.kreport"))
        let bracken = try write("name\ttaxonomy_id\n", to: analysis.appendingPathComponent("classification.bracken"))

        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override {
            await recorder.beginRun(name: "Kraken2 Classification", parameters: [
                "database": .string("Viral"), "threads": .integer(4), "confidence": .number(0.1),
            ])
        }
        time.advance(by: 2.5)
        let krakenID = await recorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: "2.17.1",
            command: [
                "/fixture/tools/kraken2", "--db", "/fixture/db/viral", "--threads", "4", "--paired",
                reads1.path, reads2.path, "--output", raw.path, "--report", report.path,
            ],
            durableReplayArgv: [
                "kraken2", "--db", "/fixture/db/viral", "--threads", "4", "--paired",
                "reads_R1.fastq", "reads_R2.fastq", "--output", raw.path, "--report", report.path,
            ],
            resolvedOptions: ["confidence": .number(0.1)],
            inputs: [
                ProvenanceRecorder.fileRecord(url: reads1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: reads2, format: .fastq, role: .input),
            ],
            outputs: [
                ProvenanceRecorder.fileRecord(url: raw, role: .output),
                ProvenanceRecorder.fileRecord(url: report, format: .text, role: .report),
            ],
            exitCode: 0,
            wallTime: 2.5,
            peakMemoryBytes: 3_400_000_000,
            stderr: "Loading database information... done.\n1 sequences (0.00 Mbp) processed.\n"
        )
        time.advance(by: 1)
        await recorder.recordStep(
            runID: runID,
            toolName: "bracken",
            toolVersion: "3.1",
            command: [
                "/fixture/tools/bracken", "-d", "/fixture/db/viral", "-i", report.path,
                "-o", bracken.path, "-r", "150", "-l", "S",
            ],
            inputs: [ProvenanceRecorder.fileRecord(url: report, format: .text, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: bracken, format: .text, role: .output)],
            exitCode: 0,
            wallTime: 1,
            stderr: "",
            dependsOn: krakenID.map { [$0] } ?? []
        )
        // The pipeline gzips the raw output and removes it before it saves.
        try FileManager.default.removeItem(at: raw)
        time.advance(by: 0.5)
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(
            runID: runID,
            to: analysis,
            options: ProvenanceOptions(
                explicit: ["database": .string("Viral"), "threads": .integer(4)],
                defaults: ["confidence": .number(0.1), "minimumHitGroups": .integer(2)],
                resolvedDefaults: ["confidence": .number(0.1), "readFormat": .string("fastq")]
            ),
            dropMissingRunLevelFiles: true
        )
        return analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// A failed run whose second step exited 3 without stderr and whose last step exited 0 with an
    /// empty stderr. The record takes the failed step's exit status and the latest stderr that says
    /// something, and an output without a checksum or size.
    static func failedRunWithANonzeroStep(in directory: URL) async throws -> URL {
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override {
            await recorder.beginRun(name: "Assembly", parameters: ["sample": .string("S1")])
        }
        time.advance(by: 4)
        let trimID = await recorder.recordStep(
            runID: runID,
            toolName: "fastp",
            toolVersion: "0.23.4",
            command: ["fastp", "-i", "/fixture/reads.fastq", "-o", "/fixture/trimmed.fastq"],
            inputs: [FileRecord(path: "/fixture/reads.fastq", sha256: digest(1), sizeBytes: 1_000, format: .fastq)],
            outputs: [FileRecord(path: "/fixture/trimmed.fastq", sha256: digest(2), sizeBytes: 900, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 4,
            stderr: "fastp: 100 reads passed filters\n"
        )
        time.advance(by: 30)
        let assemblyID = await recorder.recordStep(
            runID: runID,
            toolName: "spades",
            toolVersion: "4.0.0",
            command: ["spades.py", "-s", "/fixture/trimmed.fastq", "-o", "/fixture/assembly"],
            inputs: [FileRecord(path: "/fixture/trimmed.fastq", sha256: digest(2), sizeBytes: 900, format: .fastq)],
            outputs: [FileRecord(path: "/fixture/assembly/contigs.fasta", format: .fasta, role: .output)],
            exitCode: 3,
            wallTime: 30,
            dependsOn: trimID.map { [$0] } ?? []
        )
        time.advance(by: 0.25)
        await recorder.recordStep(
            runID: runID,
            toolName: "Lungfish Assembly Sidecar",
            toolVersion: "1.0",
            command: ["LungfishWorkflow", "AssemblyResult.save"],
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 0.25,
            stderr: "",
            dependsOn: assemblyID.map { [$0] } ?? []
        )
        await recorder.completeRun(runID, status: .failed)
        try await recorder.save(runID: runID, to: directory)
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// A run cancelled after a last step that exited 0, as a cancel during Bracken preparation ends.
    /// Its record says cancelled with exit status 0, and the save passes explicit options.
    static func cancelledRunAfterAnExitZeroStep(in directory: URL) async throws -> URL {
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override {
            await recorder.beginRun(name: "Bracken Profile", parameters: ["limit": .integer(5), "rank": .string("S")])
        }
        time.advance(by: 6)
        let prepareID = await recorder.recordStep(
            runID: runID,
            toolName: "bracken-build",
            toolVersion: "3.1",
            command: ["bracken-build", "-d", "/fixture/db/viral", "-l", "150"],
            inputs: [FileRecord(path: "/fixture/db/viral/hash.k2d", sha256: digest(3), sizeBytes: 4_096, role: .reference)],
            outputs: [FileRecord(path: "/fixture/db/viral/database150mers.kmer_distrib", sha256: digest(4), sizeBytes: 2_048, role: .output)],
            exitCode: 0,
            wallTime: 6,
            stderr: "Generating the k-mer distribution\n"
        )
        time.advance(by: 2)
        await recorder.recordStep(
            runID: runID,
            toolName: "bracken",
            toolVersion: "3.1",
            command: ["bracken", "-d", "/fixture/db/viral", "-i", "/fixture/classification.kreport"],
            inputs: [FileRecord(path: "/fixture/classification.kreport", sha256: digest(5), sizeBytes: 300, format: .text)],
            outputs: [FileRecord(path: "/fixture/classification.bracken", sha256: digest(6), sizeBytes: 120, format: .text, role: .output)],
            exitCode: 0,
            wallTime: 2,
            stderr: "partial profile\n",
            dependsOn: prepareID.map { [$0] } ?? []
        )
        time.advance(by: 0.5)
        await recorder.completeRun(runID, status: .cancelled)
        try await recorder.save(
            runID: runID,
            to: directory,
            options: ProvenanceOptions(explicit: ["limit": .integer(5)])
        )
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// An EsViritu run as `EsVirituPipeline` records it. The sidecar step reads the four tables the
    /// tool step wrote with their output role, so the record's `files` repeats four paths, as the
    /// EsViritu golden record does. The first step and the parameters carry a release version.
    static func runWithRepeatedFilePaths(in directory: URL) async throws -> URL {
        let tables = [
            "sample.detected_virus.info.tsv", "sample.detected_virus.assembly_summary.tsv",
            "sample.tax_profile.tsv", "sample.virus_coverage_windows.tsv",
        ].enumerated().map { index, name in
            FileRecord(
                path: "/fixture/esviritu/\(name)",
                sha256: digest(10 + index),
                sizeBytes: UInt64(500 + index),
                format: .text,
                role: .output
            )
        }
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override {
            await recorder.beginRun(name: "EsViritu Detection", parameters: [
                "github_release_version": .string("v1.3.3"), "sample": .string("sample"), "threads": .integer(4),
            ])
        }
        time.advance(by: 20)
        let toolID = await recorder.recordStep(
            runID: runID,
            toolName: "EsViritu",
            toolVersion: "1.3.3",
            githubReleaseVersion: "v1.3.3",
            command: ["EsViritu", "-r", "/fixture/reads.fastq", "-s", "sample", "-t", "4", "-o", "/fixture/esviritu"],
            resolvedOptions: ["sample": .string("sample")],
            inputs: [FileRecord(path: "/fixture/reads.fastq", sha256: digest(9), sizeBytes: 2_000, format: .fastq)],
            outputs: tables,
            exitCode: 0,
            wallTime: 20,
            stderr: "EsViritu finished\n"
        )
        time.advance(by: 0.5)
        await recorder.recordStep(
            runID: runID,
            toolName: "Lungfish EsViritu Result Sidecar",
            toolVersion: "1.0",
            command: ["LungfishWorkflow", "EsVirituResult.save", "/fixture/esviritu/esviritu-result.json"],
            inputs: tables,
            outputs: [FileRecord(path: "/fixture/esviritu/esviritu-result.json", sha256: digest(20), sizeBytes: 80, format: .json, role: .output)],
            exitCode: 0,
            wallTime: 0.5,
            dependsOn: toolID.map { [$0] } ?? []
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: directory)
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// A run whose first step ran in a container. Its image and digest become the run's runtime
    /// identity, and the second step's container reaches no run-level key.
    static func runWithAContainerizedFirstStep(in directory: URL) async throws -> URL {
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override {
            await recorder.beginRun(name: "Variant Calling", parameters: ["ploidy": .integer(1)])
        }
        time.advance(by: 12)
        let callID = await recorder.recordStep(
            runID: runID,
            toolName: "gatk HaplotypeCaller",
            toolVersion: "4.6.1.0",
            containerImage: "broadinstitute/gatk:4.6.1.0",
            containerDigest: "sha256:" + digest(30),
            command: ["gatk", "HaplotypeCaller", "-I", "/fixture/sample.bam", "-O", "/fixture/sample.vcf"],
            inputs: [FileRecord(path: "/fixture/sample.bam", sha256: digest(31), sizeBytes: 10_000, format: .bam)],
            outputs: [FileRecord(path: "/fixture/sample.vcf", sha256: digest(32), sizeBytes: 700, format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 12,
            stderr: "HaplotypeCaller done\n"
        )
        time.advance(by: 1)
        await recorder.recordStep(
            runID: runID,
            toolName: "bcftools",
            toolVersion: "1.21",
            containerImage: "quay.io/biocontainers/bcftools:1.21",
            containerDigest: "sha256:" + digest(33),
            command: ["bcftools", "view", "-Oz", "-o", "/fixture/sample.vcf.gz", "/fixture/sample.vcf"],
            inputs: [FileRecord(path: "/fixture/sample.vcf", sha256: digest(32), sizeBytes: 700, format: .vcf)],
            outputs: [FileRecord(path: "/fixture/sample.vcf.gz", sha256: digest(34), sizeBytes: 300, format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 1,
            dependsOn: callID.map { [$0] } ?? []
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: directory)
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// A run with a `readSetPlan` among its parameters, saved with options that leave it out. The
    /// plan and the parameters the caller does not record become explicit options, the caller's
    /// value wins a clash, and a parameter the caller records as a default with the same value stays
    /// a default.
    static func runWithAReadSetPlan(in directory: URL) async throws -> URL {
        let plan: ParameterValue = .dictionary([
            "capability": .string("pairsOrSinglesPerRun"),
            "pairedFragments": .integer(1),
            "orphanReads": .integer(1),
            "mergedReads": .null,
            "runs": .integer(2),
            "singleReadReason": .string("orphan reads run as single reads"),
        ])
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override {
            await recorder.beginRun(name: "Kraken2 Classification", parameters: [
                "readSetPlan": plan,
                "database": .string("Viral"),
                "clash": .string("run value"),
                "inDefaults": .integer(4),
                "inResolved": .string("G"),
                "resolvedElsewhere": .integer(1),
            ])
        }
        time.advance(by: 3)
        await recorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: "2.17.1",
            command: ["kraken2", "--db", "/fixture/db/viral", "--paired", "/fixture/r1.fastq", "/fixture/r2.fastq"],
            inputs: [
                FileRecord(path: "/fixture/r1.fastq", sha256: digest(40), sizeBytes: 100, format: .fastq),
                FileRecord(path: "/fixture/r2.fastq", sha256: digest(41), sizeBytes: 100, format: .fastq),
            ],
            outputs: [FileRecord(path: "/fixture/classification.kreport", sha256: digest(42), sizeBytes: 50, format: .text, role: .report)],
            exitCode: 0,
            wallTime: 3
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(
            runID: runID,
            to: directory,
            options: ProvenanceOptions(
                explicit: ["clash": .string("caller value"), "database": .string("Viral")],
                defaults: ["inDefaults": .integer(4)],
                resolvedDefaults: ["inResolved": .string("G"), "resolvedElsewhere": .integer(2)]
            )
        )
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// A run saved while it is still running, whose one step reports a blank version. The record says
    /// running, holds no wall time, and names the app's version for the run's tool.
    static func runningRunWithABlankStepVersion(in directory: URL) async throws -> URL {
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override { await recorder.beginRun(name: "Import") }
        time.advance(by: 1.5)
        await recorder.recordStep(
            runID: runID,
            toolName: "lungfish import",
            toolVersion: "  ",
            command: ["lungfish-cli", "import", "fasta", "/fixture/genome.fa"],
            inputs: [FileRecord(path: "/fixture/genome.fa", sha256: digest(50), sizeBytes: 64, format: .fasta)],
            outputs: [],
            exitCode: 0,
            wallTime: 1.5
        )
        try await recorder.save(runID: runID, to: directory)
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// A run that failed before any step was recorded. The record names the run for its tool and
    /// the app's version for the tool's version, and says exit status 1.
    static func failedRunWithoutSteps(in directory: URL) async throws -> URL {
        let time = SteppedTimeSource(startingAt: start)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await time.override { await recorder.beginRun(name: "Nothing Ran") }
        time.advance(by: 0.75)
        await recorder.completeRun(runID, status: .failed)
        try await recorder.save(runID: runID, to: directory)
        return directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    // MARK: - Helpers

    /// A SHA-256 shaped value that names `seed`, so each fixture file has its own.
    static func digest(_ seed: Int) -> String {
        String(format: "%064x", seed)
    }

    @discardableResult
    static func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
}
