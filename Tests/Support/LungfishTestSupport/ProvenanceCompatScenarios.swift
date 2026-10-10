// ProvenanceCompatScenarios.swift - Writer runs behind the captured corpus cases, reusable outside the capture gate
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each scenario runs one of today's writers inside a temporary `.lungfish` project, so the
// bytes it produces are the bytes of the matching captured case. The capture tests call a
// scenario once to freeze its output. A later lane calls the same scenario again after it
// changes the writer, projects the new bytes with `ProvenanceCompatFacts`, and compares them
// with the frozen case's facts, so no lane copies a run and lets it drift.
//
// The cancelled single-step run needs LungfishCLI, so its scenario lives in the
// LungfishCLITests target (ProvenanceCompatCLIScenarios).

import Foundation
import LungfishCore
import LungfishWorkflow

public enum ProvenanceCompatScenarios {
    /// A temporary `.lungfish` project that one scenario run writes into.
    public struct Project: Sendable {
        /// The `provenance-compat-scenario-<UUID>` folder that holds everything. Remove it with `cleanup()`.
        public let temporaryRoot: URL
        /// `<temporaryRoot>/<uuid>/Fixture.lungfish`.
        public let root: URL

        public func cleanup() {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        /// A folder below the project, created when it is missing.
        public func folder(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    public static func makeProject() throws -> Project {
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-compat-scenario")
        let root = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Project(temporaryRoot: temporaryRoot, root: root)
    }

    /// Writes `text` to `url`, creating the folder, and returns the URL.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Kraken2 recorder run with a readSetPlan parameter (case s1-recorder-readsetplan)

    /// The folder, relative to the project, that the recorder scenario writes its sidecar into.
    public static let recorderAnalysisFolder = "Analyses/kraken2-classification"

    /// A `ProvenanceRecorder` run shaped like the Kraken2 pipeline's: parameters that include a
    /// `readSetPlan`, a kraken2 step and a bracken step, then a save that passes explicit options
    /// without the plan. The embedded run is the only place the plan survives. Returns the sidecar.
    public static func recorderRunWithReadSetPlan(in project: Project) async throws -> URL {
        let analysis = try project.folder(recorderAnalysisFolder)
        let reads1 = try write("@r1/1\nACGTACGT\n+\nIIIIIIII\n", to: project.root.appendingPathComponent("Inputs/sample_R1.fastq"))
        let reads2 = try write("@r1/2\nTGCATGCA\n+\nIIIIIIII\n", to: project.root.appendingPathComponent("Inputs/sample_R2.fastq"))
        let krakenOutput = try write("C\tr1\t10239\t8\t10239:1\n", to: analysis.appendingPathComponent("classification.kraken"))
        let krakenReport = try write("100.00\t1\t0\tR\t1\troot\n", to: analysis.appendingPathComponent("classification.kreport"))
        let brackenOutput = try write("name\ttaxonomy_id\n", to: analysis.appendingPathComponent("classification.bracken"))

        let managed = PortablePath.defaultManagedRoots
        let databasePath = managed.storageRoot.appendingPathComponent("databases/kraken2/viral", isDirectory: true)
        let krakenTool = managed.toolRoot.appendingPathComponent("envs/kraken2/bin/kraken2")
        let brackenTool = managed.toolRoot.appendingPathComponent("envs/bracken/bin/bracken")

        // The pairing plan the Kraken2 pipeline puts into the run's parameters
        // (ReadSetPlan.provenanceParameters). The save below passes options without it.
        let readSetPlan: ParameterValue = .dictionary([
            "capability": .string("pairsOrSinglesPerRun"),
            "sourceLayout": .string("pairsAndSingles"),
            "pairedFragments": .integer(1),
            "mergedReads": .null,
            "orphanReads": .integer(1),
            "singleEndReads": .null,
            "mergedOrOrphanReads": .null,
            "runs": .integer(2),
            "singleReadReason": .string("orphan reads run as single reads"),
        ])
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(
            name: "Kraken2 Classification",
            parameters: [
                "goal": .string("classify"),
                "database": .string("Viral"),
                "databasePath": .file(databasePath),
                "confidence": .number(0.1),
                "threads": .integer(4),
                "pairedEnd": .boolean(true),
                "readSetPlan": readSetPlan,
            ]
        )
        await recorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: "2.1.3",
            command: [
                krakenTool.path, "--db", databasePath.path, "--threads", "4", "--paired",
                reads1.path, reads2.path, "--output", krakenOutput.path, "--report", krakenReport.path,
            ],
            inputs: [
                ProvenanceRecorder.fileRecord(url: reads1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: reads2, format: .fastq, role: .input),
            ],
            outputs: [
                ProvenanceRecorder.fileRecord(url: krakenOutput, role: .output),
                ProvenanceRecorder.fileRecord(url: krakenReport, role: .output),
            ],
            exitCode: 0,
            wallTime: 12.5,
            peakMemoryBytes: 3_400_000_000,
            stderr: "Loading database information... done.\n1 sequences (0.00 Mbp) processed in 0.012s (0.1 Kseq/m, 0.0 Mbp/m).\n"
        )
        await recorder.recordStep(
            runID: runID,
            toolName: "bracken",
            toolVersion: "3.0",
            command: [
                brackenTool.path, "-d", databasePath.path, "-i", krakenReport.path,
                "-o", brackenOutput.path, "-r", "150", "-l", "S",
            ],
            inputs: [ProvenanceRecorder.fileRecord(url: krakenReport, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: brackenOutput, role: .output)],
            exitCode: 0,
            wallTime: 1.5,
            stderr: ""
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(
            runID: runID,
            to: analysis,
            options: ProvenanceOptions(
                explicit: [
                    "goal": .string("classify"),
                    "database": .string("Viral"),
                    "databasePath": .file(databasePath),
                    "confidence": .number(0.1),
                    "threads": .integer(4),
                    "pairedEnd": .boolean(true),
                ],
                defaults: ["minimumHitGroups": .integer(2)],
                resolvedDefaults: ["minimumHitGroups": .integer(2), "readFormat": .string("fastq")]
            )
        )
        return analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    // MARK: variants phase run (cases s1-canonical-envelope-run and s3-write-sidecar-bare-run)

    /// The folder, relative to the project, that the variants phase cases write their sidecar into.
    public static let variantsPhaseAnalysisFolder = "Analyses/variants-phase"

    /// A two-step run modeled on `variants phase`: typed parameters, a managed tool path,
    /// project paths, and a durable replay argv on the last step, which depends on the first. Fixed
    /// ids and dates make every writer see the very same run. Writing it with
    /// `WorkflowRun.writeSidecar` gives case s3-write-sidecar-bare-run, and writing
    /// `canonicalEnvelope()` through `ProvenanceWriter` gives case s1-canonical-envelope-run.
    public static func variantsPhaseRun(project: URL, analysis: URL) throws -> WorkflowRun {
        let bam = try write("BAM\u{1}bytes", to: project.appendingPathComponent("Alignments/sample.bam"))
        let reference = try write(">chr1\nACGTACGTAC\n", to: project.appendingPathComponent("Inputs/reference.fasta"))
        let rawVCF = try write("##fileformat=VCFv4.2\n", to: analysis.appendingPathComponent("raw.vcf"))
        let phasedVCF = try write("##fileformat=VCFv4.2\n##phased=true\n", to: analysis.appendingPathComponent("phased.vcf"))
        let toolRoot = PortablePath.defaultManagedRoots.toolRoot
        let gatk = toolRoot.appendingPathComponent("envs/gatk4/bin/gatk")
        let whatshap = toolRoot.appendingPathComponent("envs/whatshap/bin/whatshap")

        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let middle = started.addingTimeInterval(30)
        let finished = started.addingTimeInterval(41.5)
        let callStep = StepExecution(
            id: UUID(uuidString: "4B6D3F0C-8A57-4B0B-9C63-1E2D2F6B7A01")!,
            toolName: "gatk",
            toolVersion: "4.6.1.0",
            command: [
                gatk.path, "HaplotypeCaller", "-R", reference.path, "-I", bam.path, "-O", rawVCF.path,
                "--native-pair-hmm-threads", "2",
            ],
            inputs: [
                ProvenanceRecorder.fileRecord(url: reference, format: .fasta, role: .reference),
                ProvenanceRecorder.fileRecord(url: bam, format: .bam, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: rawVCF, format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 30,
            peakMemoryBytes: 2_100_000_000,
            stderr: "HaplotypeCaller done.",
            startTime: started,
            endTime: middle
        )
        let phaseStep = StepExecution(
            id: UUID(uuidString: "4B6D3F0C-8A57-4B0B-9C63-1E2D2F6B7A02")!,
            toolName: "whatshap",
            toolVersion: "2.3",
            command: [whatshap.path, "phase", "-o", phasedVCF.path, "--reference", reference.path, rawVCF.path, bam.path],
            durableReplayArgv: ["lungfish-cli", "variants", "phase", "--reference", reference.path, "--bam", bam.path],
            inputs: [
                ProvenanceRecorder.fileRecord(url: rawVCF, format: .vcf, role: .input),
                ProvenanceRecorder.fileRecord(url: bam, format: .bam, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: phasedVCF, format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 11.5,
            dependsOn: [callStep.id],
            startTime: middle,
            endTime: finished
        )
        return WorkflowRun(
            id: UUID(uuidString: "4B6D3F0C-8A57-4B0B-9C63-1E2D2F6B7A00")!,
            name: "variants phase",
            startTime: started,
            endTime: finished,
            status: .completed,
            steps: [callStep, phaseStep],
            parameters: [
                "reference": .file(reference),
                "bam": .file(bam),
                "outputVCF": .file(phasedVCF),
                "sample": .string("sample-1"),
                "threads": .integer(2),
                "dryRun": .boolean(false),
                "extraGATKArgs": .string(""),
            ]
        )
    }

    // MARK: GATK joint genotyping in a container (case s3-gatk-container-bare-run)

    /// The container image and digest the GATK scenario runs in. The digest is the SHA-256 of
    /// the image reference.
    public static let gatkContainerImage = "quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0"
    public static let gatkContainerDigest = "sha256:1ba4b39d599432543b3e8812d4c2e533d3431da57050a6e9cfa60a173a91803b"

    /// The folder, relative to the project, that the GATK scenario writes its sidecar into.
    public static let gatkContainerAnalysisFolder = "Analyses/gatk-joint-genotyping"

    /// Runs the real `GATKPipelineExecutor` on a joint genotyping request (CombineGVCFs, then
    /// GenotypeGVCFs) that carries a container image and digest, with an injected runner that writes
    /// the output files. The executor writes the record with `WorkflowRun.writeSidecar`: a bare
    /// run whose two steps each carry `containerImage` and `containerDigest` and no runtime
    /// identity of their own. Returns the sidecar.
    public static func gatkContainerRun(in project: Project) async throws -> URL {
        let analysis = try project.folder(gatkContainerAnalysisFolder)
        let inputs = project.root.appendingPathComponent("Inputs", isDirectory: true)
        let reference = try write(">chr1\nACGTACGTAC\n", to: inputs.appendingPathComponent("reference.fasta"))
        let sampleA = try write("##fileformat=VCFv4.2\n##sample=a\n", to: inputs.appendingPathComponent("sample-a.g.vcf"))
        let sampleB = try write("##fileformat=VCFv4.2\n##sample=b\n", to: inputs.appendingPathComponent("sample-b.g.vcf"))
        let combined = analysis.appendingPathComponent("combined.g.vcf")
        let joint = analysis.appendingPathComponent("joint.vcf")

        let configuration = GATKJointGenotypingConfiguration(
            referenceFASTAURL: reference,
            inputGVCFURLs: [sampleA, sampleB],
            outputVCFURL: joint,
            intermediateURL: combined,
            strategy: .combineGVCFs
        )
        let request = GATKPipelineExecutionRequest.jointGenotype(
            configuration: configuration,
            toolVersion: "4.6.1.0",
            runtimeIdentity: GATKRuntimeIdentity(
                condaEnvironment: nil,
                containerImage: gatkContainerImage,
                containerDigest: gatkContainerDigest
            ),
            packID: "gatk-core",
            packVersion: "1.0.0"
        )
        let runner = GATKScenarioRunner(combined: combined, joint: joint)
        let started = Date(timeIntervalSince1970: 1_790_100_000)
        let executor = GATKPipelineExecutor(runner: runner, dateProvider: { started })
        let result = try await executor.run(request)
        return result.provenanceURL
    }

    /// Stands in for GATK. It writes the file each command would write and returns canned results,
    /// so the executor records a real run without a GATK install.
    private struct GATKScenarioRunner: GATKCommandRunning {
        let combined: URL
        let joint: URL

        func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
            switch command.arguments.first {
            case "CombineGVCFs":
                try Data("##fileformat=VCFv4.2\n##combined=true\n".utf8).write(to: combined)
                return GATKCommandExecutionResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: "Using GATK jar /opt/gatk/gatk-package-4.6.1.0-local.jar",
                    wallTime: 21.5
                )
            default:
                try Data("##fileformat=VCFv4.2\n##joint=true\n".utf8).write(to: joint)
                return GATKCommandExecutionResult(exitCode: 0, stdout: "", stderr: "", wallTime: 40.75)
            }
        }
    }
}
