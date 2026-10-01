// ProvenanceWorkflowExportGoldenTests.swift - Nextflow and Snakemake exports that their engines accept
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The run below mirrors the HG002 minimap2 mapping result of the "Human
// Mapping and Variants (with results)" demo project: a reference import
// whose wrapper step and the bgzip it ran both record sequence.fa.gz, a
// read import whose wrapper and clumpify both record the bundle FASTQ,
// and a flagstat step that lists the whole result bundle (its own input
// among it) as outputs. The previous renderers produced a main.nf that
// Nextflow refused to compile (a two-input process called with one
// channel, the same params line twice) and a Snakefile Snakemake rejected
// (ambiguous producers, a rule whose output is its input). The goldens
// under Resources/ProvenanceExportGoldens were checked with `nextflow
// lint` (nextflow 26.04.6) and `snakemake -n` (snakemake 9.25.2).
//
// Set LUNGFISH_UPDATE_GOLDENS=1 to rewrite the goldens from the renderers.

import Foundation
import Testing
@testable import LungfishWorkflow

struct ProvenanceWorkflowExportGoldenTests {
    private static let goldenDirectory = "ProvenanceExportGoldens"

    @Test("Nextflow export of the mapping chain matches its golden")
    func nextflowMatchesGolden() throws {
        let script = ProvenanceExporter(signingProvider: nil).exportNextflow(Self.mappingRun())
        try Self.assertGolden(script, named: "mapping-run.nf")
    }

    @Test("Snakemake export of the mapping chain matches its golden")
    func snakemakeMatchesGolden() throws {
        let script = ProvenanceExporter(signingProvider: nil).exportSnakemake(Self.mappingRun())
        try Self.assertGolden(script, named: "mapping-run.smk")
    }

    @Test("Nextflow calls every process with one channel per input")
    func nextflowCallArityMatchesInputs() {
        let script = ProvenanceExporter(signingProvider: nil).exportNextflow(Self.mappingRun())
        #expect(script.contains("CLUMPIFYSH_4(reads_r1_fastq_gz_ch, reads_r2_fastq_gz_ch)"))
        #expect(script.contains("MINIMAP2_6(LUNGFISH_IMPORT_FASTQ_5.out[0], BGZIP_2.out[0])"))
        #expect(script.contains("SAMTOOLS_10(SAMTOOLS_8.out[0])"))
        #expect(script.components(separatedBy: "params.reference_fasta = ").count == 2)
        #expect(script.components(separatedBy: "params.reads_r1_fastq_gz = ").count == 2)
        #expect(!script.contains("Channel.fromPath"))
    }

    @Test("Snakemake gives every path one producer and no self-cycle")
    func snakemakeResolvesAmbiguousProducers() {
        let script = ProvenanceExporter(signingProvider: nil).exportSnakemake(Self.mappingRun())
        let flagstat = script.components(separatedBy: "rule samtools_10:")[1]
        let flagstatOutputs = flagstat.components(separatedBy: "    output:")[1].components(separatedBy: "    log:")[0]
        #expect(!flagstatOutputs.contains("reads.sorted.bam\""), "flagstat must not claim its own input as an output")
        #expect(!flagstatOutputs.contains("sequence.fa.gz"), "the reference import already produces the reference")
        #expect(flagstatOutputs.contains("mapping-result.json"))
        #expect(flagstatOutputs.contains("manifest.json"))
        // The read import wrapper repeats clumpify's output and keeps none.
        let importFastq = script.components(separatedBy: "rule lungfish_import_fastq_5:")[1].components(separatedBy: "# Step 6")[0]
        #expect(!importFastq.contains("    output:"))
        let all = script.components(separatedBy: "rule all:")[1].components(separatedBy: "# Step 1")[0]
        #expect(all.contains("reads.sorted.bam.bai"))
        #expect(all.contains("sequence.fa.gz.fai"))
        #expect(all.contains("mapping-result.json"))
        #expect(!all.contains("reads.raw.sam\""), "an intermediate is planned, not asked for")
    }

    @Test("Snakemake config maps each parameter once")
    func snakemakeConfigDeduplicatesKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-export-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = Self.mappingRun()
        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish map",
            toolName: "lungfish map",
            files: run.steps.flatMap(\.inputs).map { ProvenanceFileDescriptor(fileRecord: $0) },
            steps: run.steps.map { ProvenanceStep(stepExecution: $0) },
            legacyWorkflowRun: run
        )
        _ = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: .snakemake,
            to: directory,
            sourceSidecarURL: nil
        )
        let config = try String(contentsOf: directory.appendingPathComponent("config.yaml"), encoding: .utf8)
        let keys = config.split(separator: "\n").map { $0.split(separator: ":", maxSplits: 1)[0] }
        #expect(keys.count == Set(keys).count, "config.yaml repeats a key: \(config)")
        #expect(config.contains("reference_fasta: \"/data/inputs/reference.fasta\""), Comment(rawValue: config))
        #expect(config.contains("project: \".\""), Comment(rawValue: config))
    }

    @Test("Graph drops a step's own inputs from its outputs and traces producers")
    func graphTracesProducers() {
        let graph = WorkflowExportGraph(run: Self.mappingRun())
        #expect(graph.nodes.count == 10)
        let flagstat = graph.nodes[9]
        #expect(flagstat.inputFilenames == ["reads.sorted.bam"])
        #expect(!flagstat.outputFilenames.contains("reads.sorted.bam"))
        let minimap = graph.nodes[5]
        guard case .process(let readsProducer, let readsIndex) = graph.source(of: "reads.fastq.gz", before: minimap) else {
            Issue.record("reads.fastq.gz should come from an earlier process")
            return
        }
        #expect(readsProducer.index == 5)
        #expect(readsIndex == 0)
        guard case .parameter = graph.source(of: "reads_R1.fastq.gz", before: graph.nodes[3]) else {
            Issue.record("reads_R1.fastq.gz should be a parameter")
            return
        }
        #expect(graph.parameterFilenames == ["reference.fasta", "reads_R1.fastq.gz", "reads_R2.fastq.gz"])
        #expect(graph.finalOutputPaths.contains(.project("Analyses/minimap2/mapping-result.json")))
    }

    // MARK: - Fixture

    /// A stand-in for the demo project's minimap2 chain: paths are short
    /// and stable so the goldens read well, but the step shapes (wrapper
    /// duplication, flagstat's bundle listing) are the real ones.
    static func mappingRun() -> WorkflowRun {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var run = WorkflowRun(
            name: "lungfish map",
            startTime: start,
            appVersion: "Lungfish 2026.9.52 (1)",
            hostOS: "macOS 26.6.2 (arm64)",
            runtime: WorkflowRuntime(appVersion: "Lungfish 2026.9.52 (1)", hostOS: "macOS 26.6.2 (arm64)", user: nil)
        )
        let inputs = "/data/inputs"
        let reference = "/data/project.lungfish/Reference Sequences/reference.lungfishref"
        let bundle = "/data/project.lungfish/Imports/reads.lungfishfastq"
        let analysis = "/data/project.lungfish/Analyses/minimap2"
        func file(_ path: String, _ role: FileRole = .input) -> FileRecord {
            FileRecord(path: path, role: role)
        }
        let steps: [StepExecution] = [
            StepExecution(
                toolName: "lungfish import fasta", toolVersion: "Lungfish 2026.9.52 (1)",
                command: ["lungfish-cli", "import", "fasta", "\(inputs)/reference.fasta", "--output-dir", "/data/project.lungfish", "--name", "reference"],
                inputs: [file("\(inputs)/reference.fasta")],
                outputs: [file("\(reference)/genome/sequence.fa.gz", .output)],
                exitCode: 0, wallTime: 0.2
            ),
            StepExecution(
                toolName: "bgzip", toolVersion: "1.24",
                command: ["/tools/bgzip", "-f", "\(reference)/genome/sequence.fa"],
                inputs: [file("\(inputs)/reference.fasta")],
                outputs: [file("\(reference)/genome/sequence.fa.gz", .output)],
                exitCode: 0, wallTime: 0.1
            ),
            StepExecution(
                toolName: "samtools", toolVersion: "1.24",
                command: ["/tools/samtools", "faidx", "\(reference)/genome/sequence.fa.gz"],
                inputs: [file("\(reference)/genome/sequence.fa.gz")],
                outputs: [
                    file("\(reference)/genome/sequence.fa.gz.fai", .output),
                    file("\(reference)/genome/sequence.fa.gz.gzi", .output),
                ],
                exitCode: 0, wallTime: 0.05
            ),
            StepExecution(
                toolName: "clumpify.sh", toolVersion: "40.02",
                command: ["/tools/clumpify.sh", "in=\(inputs)/reads_R1.fastq.gz", "in2=\(inputs)/reads_R2.fastq.gz", "out=\(bundle)/reads.fastq.gz", "interleaved=t"],
                inputs: [file("\(inputs)/reads_R1.fastq.gz"), file("\(inputs)/reads_R2.fastq.gz")],
                outputs: [file("\(bundle)/reads.fastq.gz", .output)],
                exitCode: 0, wallTime: 0.7
            ),
            StepExecution(
                toolName: "lungfish import fastq", toolVersion: "Lungfish 2026.9.52 (1)",
                command: ["lungfish-cli", "import", "fastq", "\(inputs)/reads_R1.fastq.gz", "\(inputs)/reads_R2.fastq.gz", "--project", "/data/project.lungfish", "--recipe", "none"],
                inputs: [file("\(inputs)/reads_R1.fastq.gz"), file("\(inputs)/reads_R2.fastq.gz")],
                outputs: [file("\(bundle)/reads.fastq.gz", .output)],
                exitCode: 0, wallTime: 0.04
            ),
            StepExecution(
                toolName: "minimap2", toolVersion: "2.31",
                command: ["micromamba", "run", "-n", "minimap2", "minimap2", "-a", "-x", "sr", "-o", "\(analysis)/reads.raw.sam", "\(reference)/genome/sequence.fa.gz", "\(bundle)/reads.fastq.gz"],
                inputs: [file("\(bundle)/reads.fastq.gz"), file("\(reference)/genome/sequence.fa.gz", .reference)],
                outputs: [file("\(analysis)/reads.raw.sam", .output)],
                exitCode: 0, wallTime: 0.7
            ),
            StepExecution(
                toolName: "samtools", toolVersion: "1.24",
                command: ["/tools/samtools", "view", "-b", "-o", "\(analysis)/reads.filtered.bam", "-F", "256", "\(analysis)/reads.raw.sam"],
                inputs: [file("\(analysis)/reads.raw.sam")],
                outputs: [file("\(analysis)/reads.filtered.bam", .output)],
                exitCode: 0, wallTime: 0.7
            ),
            StepExecution(
                toolName: "samtools", toolVersion: "1.24",
                command: ["/tools/samtools", "sort", "-o", "\(analysis)/reads.sorted.bam", "\(analysis)/reads.filtered.bam"],
                inputs: [file("\(analysis)/reads.filtered.bam")],
                outputs: [file("\(analysis)/reads.sorted.bam", .output)],
                exitCode: 0, wallTime: 0.1
            ),
            StepExecution(
                toolName: "samtools", toolVersion: "1.24",
                command: ["/tools/samtools", "index", "\(analysis)/reads.sorted.bam"],
                inputs: [file("\(analysis)/reads.sorted.bam")],
                outputs: [file("\(analysis)/reads.sorted.bam.bai", .output)],
                exitCode: 0, wallTime: 0.02
            ),
            StepExecution(
                toolName: "samtools", toolVersion: "1.24",
                command: ["/tools/samtools", "flagstat", "\(analysis)/reads.sorted.bam"],
                inputs: [file("\(analysis)/reads.sorted.bam")],
                outputs: [
                    file("\(analysis)/reads.sorted.bam", .output),
                    file("\(analysis)/reads.sorted.bam.bai", .output),
                    file("\(analysis)/mapping-result.json", .output),
                    file("\(reference)/genome/sequence.fa.gz", .output),
                    file("\(reference)/genome/sequence.fa.gz.fai", .output),
                    file("\(reference)/genome/sequence.fa.gz.gzi", .output),
                    file("\(reference)/manifest.json", .output),
                    file("\(bundle)/reads.fastq.gz", .output),
                ],
                exitCode: 0, wallTime: 0.03
            ),
        ]
        run.steps = steps
        run.endTime = start.addingTimeInterval(3)
        run.status = .completed
        return run
    }

    private static func goldenURL(named name: String) throws -> URL {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(goldenDirectory, isDirectory: true)
        if ProcessInfo.processInfo.environment["LUNGFISH_UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            return sourceDirectory.appendingPathComponent(name)
        }
        if let resource = Bundle.module.resourceURL?
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(goldenDirectory, isDirectory: true)
            .appendingPathComponent(name),
           FileManager.default.fileExists(atPath: resource.path) {
            return resource
        }
        return sourceDirectory.appendingPathComponent(name)
    }

    private static func assertGolden(_ actual: String, named name: String) throws {
        let url = try goldenURL(named: name)
        if ProcessInfo.processInfo.environment["LUNGFISH_UPDATE_GOLDENS"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "\(name) drifted from its golden. Rendered:\n\(actual)")
    }
}
