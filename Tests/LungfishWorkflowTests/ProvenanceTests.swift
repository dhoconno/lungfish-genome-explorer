// ProvenanceTests.swift - Tests for provenance recording and export
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("Provenance Recording")
struct ProvenanceRecordingTests {

    @Test("Begin and complete a run")
    func testRunLifecycle() async {
        let recorder = ProvenanceRecorder()
        let runID = await recorder.beginRun(name: "Test Run")

        var run = await recorder.getRun(runID)
        #expect(run?.name == "Test Run")
        #expect(run?.status == .running)
        #expect(run?.steps.isEmpty == true)

        await recorder.completeRun(runID, status: .completed)

        run = await recorder.getRun(runID)
        #expect(run?.status == .completed)
        #expect(run?.endTime != nil)
    }

    @Test("Record a step in a run")
    func testRecordStep() async {
        let recorder = ProvenanceRecorder()
        let runID = await recorder.beginRun(name: "Assembly")

        let stepID = await recorder.recordStep(
            runID: runID,
            toolName: "samtools",
            toolVersion: "1.21",
            command: ["samtools", "faidx", "genome.fa"],
            inputs: [FileRecord(path: "/data/genome.fa", format: .fasta, role: .input)],
            outputs: [FileRecord(path: "/data/genome.fa.fai", format: .text, role: .index)],
            exitCode: 0,
            wallTime: 2.5
        )

        #expect(stepID != nil)

        let run = await recorder.getRun(runID)
        #expect(run?.steps.count == 1)
        #expect(run?.steps[0].toolName == "samtools")
        #expect(run?.steps[0].toolVersion == "1.21")
        #expect(run?.steps[0].exitCode == 0)
        #expect(run?.steps[0].wallTime == 2.5)
        #expect(run?.steps[0].inputs.count == 1)
        #expect(run?.steps[0].outputs.count == 1)
    }

    @Test("Step returns nil for nonexistent run")
    func testRecordStepNonexistentRun() async {
        let recorder = ProvenanceRecorder()
        let stepID = await recorder.recordStep(
            runID: UUID(),
            toolName: "samtools",
            toolVersion: "1.21",
            command: ["samtools", "version"],
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 0.1
        )
        #expect(stepID == nil)
    }

    @Test("Find run by output path")
    func testFindRunByOutput() async {
        let recorder = ProvenanceRecorder()
        let runID = await recorder.beginRun(name: "VCF Import")

        await recorder.recordStep(
            runID: runID,
            toolName: "bcftools",
            toolVersion: "1.21",
            command: ["bcftools", "view", "-Oz", "input.vcf"],
            inputs: [FileRecord(path: "/data/input.vcf", format: .vcf)],
            outputs: [FileRecord(path: "/output/variants.vcf.gz", format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 5.0
        )

        let found = await recorder.findRun(forOutputPath: "/output/variants.vcf.gz")
        #expect(found?.id == runID)

        let notFound = await recorder.findRun(forOutputPath: "/other/file.txt")
        #expect(notFound == nil)
    }

    @Test("Stderr is truncated to 10 KB")
    func testStderrTruncation() async {
        let recorder = ProvenanceRecorder()
        let runID = await recorder.beginRun(name: "Truncation Test")

        let longStderr = String(repeating: "x", count: 20_000)
        await recorder.recordStep(
            runID: runID,
            toolName: "test",
            toolVersion: "1.0",
            command: ["test"],
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 0.1,
            stderr: longStderr
        )

        let run = await recorder.getRun(runID)
        let stored = run?.steps[0].stderr ?? ""
        #expect(stored.count < 20_000)
        #expect(stored.hasSuffix("... [truncated]"))
    }

    @Test("Multiple steps with dependencies")
    func testMultiStepDAG() async {
        let recorder = ProvenanceRecorder()
        let runID = await recorder.beginRun(name: "Multi-Step")

        let step1ID = await recorder.recordStep(
            runID: runID,
            toolName: "fastp",
            toolVersion: "0.23.4",
            command: ["fastp", "-i", "reads.fq", "-o", "trimmed.fq"],
            inputs: [FileRecord(path: "reads.fq", format: .fastq)],
            outputs: [FileRecord(path: "trimmed.fq", format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 10.0
        )

        await recorder.recordStep(
            runID: runID,
            toolName: "bwa",
            toolVersion: "0.7.18",
            command: ["bwa", "mem", "ref.fa", "trimmed.fq"],
            inputs: [FileRecord(path: "trimmed.fq", format: .fastq)],
            outputs: [FileRecord(path: "aligned.bam", format: .bam, role: .output)],
            exitCode: 0,
            wallTime: 30.0,
            dependsOn: [step1ID!]
        )

        let run = await recorder.getRun(runID)
        #expect(run?.steps.count == 2)
        #expect(run?.steps[1].dependsOn == [step1ID!])
        #expect(run?.primaryInputFiles.count == 1)
        #expect(run?.primaryInputFiles[0].path == "reads.fq")
    }
}

@Suite("Provenance Persistence")
struct ProvenancePersistenceTests {

    @Test("Save and load provenance JSON")
    func testSaveAndLoad() async throws {
        let recorder = ProvenanceRecorder()
        let runID = await recorder.beginRun(name: "Persistence Test")

        await recorder.recordStep(
            runID: runID,
            toolName: "samtools",
            toolVersion: "1.21",
            command: ["samtools", "sort", "input.bam", "-o", "sorted.bam"],
            inputs: [FileRecord(path: "input.bam", sha256: "abc123", sizeBytes: 1000, format: .bam)],
            outputs: [FileRecord(path: "sorted.bam", sha256: "def456", sizeBytes: 900, format: .bam, role: .output)],
            exitCode: 0,
            wallTime: 15.0
        )

        await recorder.completeRun(runID, status: .completed)

        // Save to temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("provenance-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await recorder.save(runID: runID, to: tempDir)

        // Verify file exists
        let provenanceFile = tempDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        #expect(FileManager.default.fileExists(atPath: provenanceFile.path))

        // Load it back
        let loaded = ProvenanceRecorder.load(from: tempDir)
        #expect(loaded != nil)
        #expect(loaded?.name == "Persistence Test")
        #expect(loaded?.status == .completed)
        #expect(loaded?.steps.count == 1)
        #expect(loaded?.steps[0].toolName == "samtools")
        #expect(loaded?.steps[0].inputs[0].sha256 == "abc123")
    }
}

@Suite("Provenance Export")
struct ProvenanceExportTests {

    /// Creates a sample workflow run for testing exports.
    private func sampleRun() -> WorkflowRun {
        var run = WorkflowRun(
            name: "Variant Calling Pipeline",
            appVersion: "Lungfish 2.0.0 (100)",
            hostOS: "macOS 26.0.0 (arm64)"
        )

        let step1 = StepExecution(
            toolName: "fastp",
            toolVersion: "0.23.4",
            containerImage: "quay.io/biocontainers/fastp:0.23.4",
            command: ["fastp", "-i", "reads_R1.fq.gz", "-I", "reads_R2.fq.gz",
                      "-o", "trimmed_R1.fq.gz", "-O", "trimmed_R2.fq.gz",
                      "-q", "20", "-l", "50"],
            inputs: [
                FileRecord(path: "reads_R1.fq.gz", sha256: "aaa111", sizeBytes: 500_000, format: .fastq),
                FileRecord(path: "reads_R2.fq.gz", sha256: "bbb222", sizeBytes: 500_000, format: .fastq),
            ],
            outputs: [
                FileRecord(path: "trimmed_R1.fq.gz", format: .fastq, role: .output),
                FileRecord(path: "trimmed_R2.fq.gz", format: .fastq, role: .output),
            ],
            exitCode: 0,
            wallTime: 45.0
        )

        let step2 = StepExecution(
            toolName: "samtools",
            toolVersion: "1.21",
            command: ["samtools", "sort", "-@", "4", "aligned.bam", "-o", "sorted.bam"],
            inputs: [FileRecord(path: "aligned.bam", format: .bam)],
            outputs: [FileRecord(path: "sorted.bam", format: .bam, role: .output)],
            exitCode: 0,
            wallTime: 120.0,
            dependsOn: [step1.id]
        )

        run.steps = [step1, step2]
        run.endTime = run.startTime.addingTimeInterval(165)
        run.status = .completed
        return run
    }

    @Test("Export as shell script")
    func testShellExport() throws {
        let exporter = ProvenanceExporter()
        let script = exporter.exportShell(sampleRun())

        #expect(script.contains("#!/usr/bin/env bash"))
        #expect(script.contains("set -euo pipefail"))
        #expect(script.contains("fastp"))
        #expect(script.contains("samtools"))
        #expect(script.contains("Step 1: fastp 0.23.4"))
        #expect(script.contains("Step 2: samtools 1.21"))
        #expect(script.contains("Variant Calling Pipeline"))
    }

    @Test("Export as Python script")
    func testPythonExport() throws {
        let exporter = ProvenanceExporter()
        let script = exporter.exportPython(sampleRun())

        #expect(script.contains("#!/usr/bin/env python3"))
        #expect(script.contains("import subprocess"))
        #expect(script.contains("def step_1_fastp()"))
        #expect(script.contains("def step_2_samtools()"))
        #expect(script.contains("run_step"))
    }

    @Test("Export as Nextflow pipeline")
    func testNextflowExport() throws {
        let exporter = ProvenanceExporter()
        let script = exporter.exportNextflow(sampleRun())

        #expect(script.contains("#!/usr/bin/env nextflow"))
        #expect(script.contains("nextflow.enable.dsl = 2"))
        #expect(script.contains("process FASTP_1"))
        #expect(script.contains("process SAMTOOLS_2"))
        #expect(script.contains("container 'quay.io/biocontainers/fastp:0.23.4'"))
        #expect(script.contains("workflow {"))
    }

    @Test("Export as Snakemake workflow")
    func testSnakemakeExport() throws {
        let exporter = ProvenanceExporter()
        let script = exporter.exportSnakemake(sampleRun())

        #expect(script.contains("rule all:"))
        #expect(script.contains("rule fastp_1:"))
        #expect(script.contains("rule samtools_2:"))
        #expect(script.contains("snakemake --cores"))
    }

    @Test("Export methods section")
    func testMethodsExport() throws {
        let exporter = ProvenanceExporter()
        let methods = exporter.exportMethods(sampleRun())

        #expect(methods.contains("Methods"))
        #expect(methods.contains("fastp v0.23.4"))
        #expect(methods.contains("samtools v1.21"))
        #expect(methods.contains("minimum quality score of 20"))
        #expect(methods.contains("minimum length of 50 bp"))
        #expect(methods.contains("| Tool | Version | Container |"))
    }

    @Test("Export as JSON")
    func testJSONExport() throws {
        let exporter = ProvenanceExporter()
        let json = try exporter.exportJSON(sampleRun())

        #expect(json.contains("\"name\" : \"Variant Calling Pipeline\""))
        #expect(json.contains("\"toolName\" : \"fastp\""))
        #expect(json.contains("\"toolVersion\" : \"0.23.4\""))

        // Verify it's valid JSON that round-trips
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkflowRun.self, from: data)
        #expect(decoded.name == "Variant Calling Pipeline")
        #expect(decoded.steps.count == 2)
    }

    @Test("File format detection")
    func testFileFormatDetection() {
        let fasta = ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: "/data/genome.fa"))
        #expect(fasta.format == .fasta)

        let fastq = ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: "/data/reads.fastq.gz"))
        #expect(fastq.format == .fastq)

        let bam = ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: "/data/aligned.bam"))
        #expect(bam.format == .bam)

        let vcf = ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: "/data/variants.vcf.gz"))
        #expect(vcf.format == .vcf)

        let bed = ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: "/data/features.bed"))
        #expect(bed.format == .bed)
    }

    @Test("StepExecution commandString escapes special chars")
    func testCommandStringEscaping() {
        let step = StepExecution(
            toolName: "test",
            toolVersion: "1.0",
            command: ["samtools", "sort", "-o", "/path with spaces/output.bam", "input.bam"],
            inputs: [],
            exitCode: 0
        )

        let cmdStr = step.commandString
        #expect(cmdStr.contains("'/path with spaces/output.bam'"))
        #expect(cmdStr.contains("samtools"))
    }
}
