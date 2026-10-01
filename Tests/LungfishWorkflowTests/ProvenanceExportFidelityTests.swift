// ProvenanceExportFidelityTests.swift - Exports a scientist can read and run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The run below mirrors the bcftools variant-call record of the "Human
// Mapping and Variants (with results)" demo project as it shipped: internal
// staging steps that symlink the BAM and decompress the reference into a
// scratch workspace, a mpileup/call pair joined by a pipe pseudo-file, five
// bcftools invocations, managed-tool executables under a private conda
// prefix, and absolute paths of the machine that built the demo. The
// exports must describe each tool once, collapse the staging, join the
// pipe, and name no path or executable of that machine.

import Foundation
import Testing
@testable import LungfishWorkflow

struct ProvenanceExportFidelityTests {
    private static let exporter = ProvenanceExporter(signingProvider: nil)

    // MARK: - Version text

    @Test("Managed tool version text splits the version from its environment")
    func managedToolVersionText() {
        let identity = ProvenanceToolIdentityText.parse(
            toolName: "bcftools",
            toolVersion: "1.24 (managed conda environment bcftools; executable bcftools; package bioconda::bcftools=1.24=h6bd33b9_2)"
        )
        #expect(identity.version == "1.24")
        #expect(identity.displayVersion == "v1.24")
        #expect(identity.environment?.name == "bcftools")
        #expect(identity.environment?.executable == "bcftools")
        #expect(identity.environment?.packageSpec == "bioconda::bcftools=1.24=h6bd33b9_2")
    }

    @Test("A version that repeats the tool name is reduced to the version")
    func versionNeverRepeatsToolName() {
        let cli = ProvenanceToolIdentityText.parse(toolName: "lungfish-cli", toolVersion: "lungfish-cli 2026.9.52")
        #expect(cli.version == "2026.9.52")
        #expect(cli.displayVersion == "v2026.9.52")
        #expect(cli.environment == nil)

        let staging = ProvenanceToolIdentityText.parse(toolName: "lungfish alignment-staging", toolVersion: "Lungfish dev (0)")
        #expect(staging.isDevelopmentBuild)
        #expect(staging.version == "development build")
        #expect(staging.displayVersion == "(development build)")
        #expect(staging.displayLabel == "lungfish alignment-staging (development build)")

        let app = ProvenanceToolIdentityText.parse(toolName: "lungfish import fastq", toolVersion: "Lungfish 2026.9.72 (dev)")
        #expect(app.isDevelopmentBuild)
        #expect(app.version == "2026.9.72")
        #expect(app.displayVersion == "v2026.9.72 (development build)")

        let packaged = ProvenanceToolIdentityText.parse(toolName: "Lungfish", toolVersion: "Lungfish 2026.9.72 (1)")
        #expect(!packaged.isDevelopmentBuild)
        #expect(packaged.displayVersion == "v2026.9.72 (1)")
    }

    @Test("A stored probe error reads as an unknown version")
    func probeErrorReadsAsUnknown() {
        let identity = ProvenanceToolIdentityText.parse(
            toolName: "lofreq",
            toolVersion: "FATAL(lofreq_main.c|main:336): Unrecognized command '--version' (managed conda environment lofreq; executable lofreq; package lofreq)"
        )
        #expect(identity.version == "unknown")
        #expect(identity.displayLabel == "lofreq unknown")
        #expect(identity.environment?.name == "lofreq")
    }

    @Test("An app version written by a development build reads as one")
    func appVersionLabelNamesDevelopmentBuilds() {
        #expect(ProvenanceToolIdentityText.appVersionLabel("Lungfish dev (0)") == "Lungfish (development build)")
        #expect(ProvenanceToolIdentityText.appVersionLabel("Lungfish 2026.9.72 (dev)") == "Lungfish 2026.9.72 (development build)")
        #expect(ProvenanceToolIdentityText.appVersionLabel("Lungfish 2026.9.72 (1)") == "Lungfish 2026.9.72 (1)")
        #expect(ProvenanceToolIdentityText.appVersionLabel("lungfish-cli 2026.9.52") == "lungfish-cli 2026.9.52")
        #expect(ProvenanceToolIdentityText.appVersionLabel("2026.05") == "2026.05")
    }

    @Test("Exports never print dev (0) for a step a development build recorded")
    func exportsNameDevelopmentBuilds() {
        var run = Self.variantCallRun()
        run.steps.insert(
            StepExecution(
                toolName: "lungfish import fastq", toolVersion: "Lungfish dev (0)",
                command: ["lungfish-cli", "import", "fastq", "--project", "/build/Demo Project.lungfish", "/reads/r1.fastq.gz"],
                inputs: [FileRecord(path: "/reads/r1.fastq.gz", sha256: "a".padding(toLength: 64, withPad: "a", startingAt: 0), sizeBytes: 1, format: .fastq, role: .input)],
                outputs: [FileRecord(path: "/build/Demo Project.lungfish/Imports/reads.lungfishfastq/r1.fastq.gz", sha256: "a".padding(toLength: 64, withPad: "a", startingAt: 0), sizeBytes: 1, format: .fastq, role: .output)],
                exitCode: 0, wallTime: 0.1
            ),
            at: 0
        )
        run = WorkflowRun(
            id: run.id, name: run.name, startTime: run.startTime, endTime: run.endTime, status: run.status,
            appVersion: "Lungfish dev (0)", hostOS: run.hostOS, runtime: run.runtime, steps: run.steps, parameters: run.parameters
        )
        for script in [
            Self.exporter.exportSnakemake(run), Self.exporter.exportShell(run),
            Self.exporter.exportNextflow(run), Self.exporter.exportPython(run), Self.exporter.exportMethods(run),
        ] {
            #expect(!script.contains("dev (0)"), Comment(rawValue: script))
            #expect(!script.contains("vdev"), Comment(rawValue: script))
            #expect(script.contains("development build"), Comment(rawValue: script))
        }
        let snakefile = Self.exporter.exportSnakemake(run)
        #expect(snakefile.contains("# Step 1: lungfish import fastq (development build)"), Comment(rawValue: snakefile))
        #expect(snakefile.contains("Generated by Lungfish (development build)"), Comment(rawValue: snakefile))
        #expect(Self.exporter.exportMethods(run).contains("used Lungfish (development build) on macOS"))
    }

    // MARK: - Methods parameter prose

    @Test("Methods phrase recorded parameters as readable qualifiers")
    func methodsParameterProseReadsNaturally() {
        let methods = Self.exporter.exportMethods(Self.mappingRun())
        #expect(!methods.contains("with excluding flag"), Comment(rawValue: methods))
        #expect(methods.contains("secondary alignments (flag 256) excluded"), Comment(rawValue: methods))
        #expect(methods.contains("a minimum mapping quality of 20"), Comment(rawValue: methods))
        #expect(methods.contains("the sr preset"), Comment(rawValue: methods))
        #expect(methods.contains("Reads were mapped to the reference with minimap2 v2.31"), Comment(rawValue: methods))
        #expect(methods.contains("using samtools view, with secondary alignments (flag 256) excluded and a minimum mapping quality of 20."), Comment(rawValue: methods))

        let variants = Self.exporter.exportMethods(Self.variantCallRun())
        #expect(variants.contains("with a ploidy of 2, a minimum allele frequency of 0.05 and a minimum depth of 10."), Comment(rawValue: variants))
    }

    @Test("Excluded SAM flags are spelt out by name")
    func samFlagDescriptions() {
        #expect(ProvenanceMethodsPhrasing.excludedFlags("256") == "secondary alignments (flag 256) excluded")
        #expect(ProvenanceMethodsPhrasing.excludedFlags("4") == "unmapped reads (flag 4) excluded")
        #expect(ProvenanceMethodsPhrasing.excludedFlags("2308") == "unmapped reads, secondary alignments and supplementary alignments (flag 2308) excluded")
        #expect(ProvenanceMethodsPhrasing.excludedFlags("0x4") == "unmapped reads (flag 0x4) excluded")
        #expect(ProvenanceMethodsPhrasing.excludedFlags("abc") == "reads with flag abc excluded")
        #expect(ProvenanceMethodsPhrasing.requiredFlags("2") == "only properly paired reads (flag 2) kept")
    }

    // MARK: - Methods

    @Test("Methods describe each tool once, in pipeline order, with the operation")
    func methodsDescribeEachToolOnce() {
        let methods = Self.exporter.exportMethods(Self.variantCallRun())

        #expect(!methods.contains("was performed using bcftools"), Comment(rawValue: methods))
        #expect(methods.components(separatedBy: "bcftools v1.24").count == 2, "bcftools is described once: \(methods)")
        #expect(methods.contains("bcftools mpileup"), Comment(rawValue: methods))
        #expect(methods.contains("bcftools call"), Comment(rawValue: methods))
        #expect(methods.contains("bioconda::bcftools=1.24=h6bd33b9_2"), Comment(rawValue: methods))
        #expect(methods.contains("a ploidy of 2"), Comment(rawValue: methods))
        #expect(!methods.contains("vLungfish"), Comment(rawValue: methods))
        #expect(!methods.contains("vlungfish-cli"), Comment(rawValue: methods))
        #expect(!methods.contains("alignment-staging"), Comment(rawValue: methods))
        #expect(!methods.contains("reference-staging"), Comment(rawValue: methods))

        let table = methods.components(separatedBy: "Tool Versions")[1].components(separatedBy: "Input Files")[0]
        #expect(table.components(separatedBy: "| bcftools |").count == 2, "one bcftools row: \(table)")
        #expect(table.components(separatedBy: "| samtools |").count == 2, Comment(rawValue: table))
        #expect(!table.contains("lungfish-internal"), Comment(rawValue: table))

        let inputs = methods.components(separatedBy: "Input Files")[1].components(separatedBy: "Reproducibility")[0]
        #expect(inputs.components(separatedBy: "aln_1.bam ").count == 2, "the BAM is listed once: \(inputs)")
        #expect(inputs.contains("sequence.fa.gz"), Comment(rawValue: inputs))
        #expect(!inputs.contains("bcftools.raw.vcf"), "an intermediate is not an input: \(inputs)")
        #expect(!inputs.contains("reference.fa "), "a staged copy is not an input: \(inputs)")
        #expect(!inputs.contains("pipe:stdout"), Comment(rawValue: inputs))
        #expect(methods.contains("lungfish-cli 2026.9.52 on macOS"), Comment(rawValue: methods))
    }

    // MARK: - Snakemake

    @Test("Snakemake collapses staging, joins the pipe and references real sources")
    func snakemakeCollapsesStagingAndJoinsPipe() {
        let script = Self.exporter.exportSnakemake(Self.variantCallRun())

        #expect(!script.contains("lungfish-internal stage-"), Comment(rawValue: script))
        #expect(!script.contains("pipe:stdout"), Comment(rawValue: script))
        #expect(!script.contains("rule lungfish_alignment_staging"), Comment(rawValue: script))
        let mpileup = script.components(separatedBy: "bcftools mpileup")
        #expect(mpileup.count == 2, "one mpileup rule: \(script)")
        #expect(mpileup[1].components(separatedBy: "\n")[0].contains(" | bcftools call "), "mpileup pipes into call: \(script)")
        #expect(script.contains("config[\"aln_1_bam\"]"), "the BAM is a parameter read through config: \(script)")
        #expect(script.contains("project(\"Analyses/minimap2-1/ref.lungfishref/variants/vc-1.vcf.gz\")"), Comment(rawValue: script))
        #expect(script.contains("gzip -dc"), "the decompression is a real command: \(script)")
    }

    @Test("Snakemake names no path or executable of the recording machine")
    func snakemakeIsPortable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-export-portable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = Self.variantCallRun()
        let envelope = ProvenanceEnvelope(
            workflowName: run.name,
            toolName: "lungfish-cli",
            files: run.steps.flatMap(\.inputs).map { ProvenanceFileDescriptor(fileRecord: $0) },
            steps: run.steps.map { ProvenanceStep(stepExecution: $0) },
            legacyWorkflowRun: run
        )
        _ = try Self.exporter.exportBundle(envelope, format: .snakemake, to: directory, sourceSidecarURL: nil)

        let script = try String(contentsOf: directory.appendingPathComponent("Snakefile"), encoding: .utf8)
        for forbidden in ["/var/folders", "/Users/someone", "/build/Demo", "--use-singularity", "lungfish-internal stage-"] {
            #expect(!script.contains(forbidden), "Snakefile names \(forbidden): \(script)")
        }
        #expect(script.contains("--software-deployment-method conda"), Comment(rawValue: script))
        #expect(script.contains("conda:"), Comment(rawValue: script))
        #expect(script.contains("\"envs/bcftools.yaml\""), Comment(rawValue: script))
        #expect(script.contains("\\nsamtools faidx "), "bare executable: \(script)")
        #expect(script.contains("results/reference.fa"), "scratch outputs land under results: \(script)")

        let config = try String(contentsOf: directory.appendingPathComponent("config.yaml"), encoding: .utf8)
        #expect(config.contains("project:"), Comment(rawValue: config))
        #expect(config.contains("aln_1_bam: \"Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam\""), Comment(rawValue: config))
        #expect(!config.contains("/var/folders"), Comment(rawValue: config))
        #expect(!config.contains("/build/Demo"), Comment(rawValue: config))

        let env = try String(contentsOf: directory.appendingPathComponent("envs/bcftools.yaml"), encoding: .utf8)
        #expect(env.contains("bioconda::bcftools=1.24=h6bd33b9_2"), Comment(rawValue: env))
        #expect(env.contains("bioconda"), Comment(rawValue: env))
    }

    // MARK: - Shell and Nextflow

    @Test("Shell export uses bare executables, project paths and an environment note")
    func shellIsPortable() {
        let script = Self.exporter.exportShell(Self.variantCallRun())
        for forbidden in ["/var/folders", "/Users/someone", "/build/Demo", "lungfish-internal stage-", "pipe:stdout"] {
            #expect(!script.contains(forbidden), "run.sh names \(forbidden): \(script)")
        }
        #expect(script.contains("micromamba create"), Comment(rawValue: script))
        #expect(script.contains("bioconda::samtools=1.24=h36b3a25_1"), Comment(rawValue: script))
        #expect(script.contains("Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam"), Comment(rawValue: script))
        #expect(script.contains("| bcftools"), "the pipe survives: \(script)")
    }

    @Test("Nextflow stages inputs by name and declares each conda environment")
    func nextflowStagesByName() {
        let script = Self.exporter.exportNextflow(Self.variantCallRun())
        for forbidden in ["/var/folders", "/Users/someone", "/build/Demo", "lungfish-internal stage-", "pipe:stdout"] {
            #expect(!script.contains(forbidden), "main.nf names \(forbidden): \(script)")
        }
        #expect(script.contains("conda 'bioconda::bcftools=1.24=h6bd33b9_2'"), Comment(rawValue: script))
        #expect(script.contains("bcftools mpileup -Ou -A -d 0 -a FORMAT/AD,FORMAT/DP,INFO/AD -f reference.fa aln_1.bam | bcftools call"), Comment(rawValue: script))
    }

    // MARK: - Fixture

    /// The demo's variant-call record with short, stable paths. Staged copies
    /// share the checksum of their source; the decompressed reference does not.
    static func variantCallRun() -> WorkflowRun {
        let start = Date(timeIntervalSince1970: 1_790_000_100)
        let project = "/build/Demo Project.lungfish"
        let bundle = "\(project)/Analyses/minimap2-1/ref.lungfishref"
        let workspace = "/var/folders/xx/T/variants-1234/workspace"
        let conda = "/Users/someone/.lungfish/conda/envs"
        let cliVersion = "lungfish-cli 2026.9.52"
        func file(_ path: String, _ sha: String, _ role: FileRole = .input, _ format: FileFormat? = nil) -> FileRecord {
            FileRecord(path: path, sha256: sha, sizeBytes: 10, format: format, role: role)
        }
        func managed(_ tool: String, _ env: String, _ spec: String) -> String {
            "1.24 (managed conda environment \(env); executable \(tool); package \(spec))"
        }
        let bcftoolsVersion = managed("bcftools", "bcftools", "bioconda::bcftools=1.24=h6bd33b9_2")
        let samtoolsVersion = managed("samtools", "samtools", "bioconda::samtools=1.24=h36b3a25_1")
        let htslibVersion = managed("bgzip", "htslib", "bioconda::htslib=1.24=hd3c6ec9_0")
        let bamSHA = "b".padding(toLength: 64, withPad: "b", startingAt: 0)
        let baiSHA = "c".padding(toLength: 64, withPad: "c", startingAt: 0)
        let refGZSHA = "d".padding(toLength: 64, withPad: "d", startingAt: 0)
        let refSHA = "e".padding(toLength: 64, withPad: "e", startingAt: 0)
        let faiSHA = "f".padding(toLength: 64, withPad: "f", startingAt: 0)
        let rawSHA = "1".padding(toLength: 64, withPad: "1", startingAt: 0)
        let filteredSHA = "2".padding(toLength: 64, withPad: "2", startingAt: 0)
        let gzSHA = "3".padding(toLength: 64, withPad: "3", startingAt: 0)
        let tbiSHA = "4".padding(toLength: 64, withPad: "4", startingAt: 0)
        let dbSHA = "5".padding(toLength: 64, withPad: "5", startingAt: 0)
        let trackDBSHA = "6".padding(toLength: 64, withPad: "6", startingAt: 0)

        var run = WorkflowRun(
            name: "lungfish variants call",
            startTime: start,
            appVersion: cliVersion,
            hostOS: "macOS 26.6.2 (arm64)",
            runtime: WorkflowRuntime(appVersion: cliVersion, hostOS: "macOS 26.6.2 (arm64)", user: nil)
        )
        run.steps = [
            StepExecution(
                toolName: "lungfish alignment-staging", toolVersion: "Lungfish dev (0)",
                command: [
                    "lungfish-internal", "stage-alignment",
                    "--input-bam", "\(bundle)/alignments/mapped/aln_1.bam",
                    "--input-index", "\(bundle)/alignments/mapped/aln_1.bam.bai",
                    "--output-bam", "\(workspace)/inputs/aln_1.bam",
                    "--output-index", "\(workspace)/inputs/aln_1.bam.bai",
                    "--mode", "symlink",
                ],
                inputs: [
                    file("\(bundle)/alignments/mapped/aln_1.bam", bamSHA, .input, .bam),
                    file("\(bundle)/alignments/mapped/aln_1.bam.bai", baiSHA, .index),
                ],
                outputs: [
                    file("\(workspace)/inputs/aln_1.bam", bamSHA, .output, .bam),
                    file("\(workspace)/inputs/aln_1.bam.bai", baiSHA, .index),
                ],
                exitCode: 0, wallTime: 0.001
            ),
            StepExecution(
                toolName: "lungfish reference-staging", toolVersion: "Lungfish dev (0)",
                command: [
                    "lungfish-internal", "stage-reference",
                    "--input", "\(bundle)/genome/sequence.fa.gz",
                    "--output", "\(workspace)/inputs/reference.fa",
                    "--mode", "decompress-gzip",
                ],
                inputs: [file("\(bundle)/genome/sequence.fa.gz", refGZSHA, .reference, .fasta)],
                outputs: [file("\(workspace)/inputs/reference.fa", refSHA, .output, .fasta)],
                exitCode: 0, wallTime: 0.004
            ),
            StepExecution(
                toolName: "samtools", toolVersion: samtoolsVersion,
                command: ["\(conda)/samtools/bin/samtools", "faidx", "\(workspace)/inputs/reference.fa"],
                inputs: [file("\(workspace)/inputs/reference.fa", refSHA, .input, .fasta)],
                outputs: [file("\(workspace)/inputs/reference.fa.fai", faiSHA, .index)],
                exitCode: 0, wallTime: 0.007
            ),
            StepExecution(
                toolName: "bcftools", toolVersion: bcftoolsVersion,
                command: [
                    "\(conda)/bcftools/bin/bcftools", "mpileup", "-Ou", "-A", "-d", "0",
                    "-a", "FORMAT/AD,FORMAT/DP,INFO/AD",
                    "-f", "\(workspace)/inputs/reference.fa", "\(workspace)/inputs/aln_1.bam",
                ],
                inputs: [
                    file("\(workspace)/inputs/reference.fa", refSHA, .reference, .fasta),
                    file("\(workspace)/inputs/aln_1.bam", bamSHA, .input, .bam),
                    file("\(workspace)/inputs/aln_1.bam.bai", baiSHA, .index),
                ],
                outputs: [FileRecord(path: "pipe:stdout:bcftools-mpileup", format: .bcf, role: .output)],
                exitCode: 0, wallTime: 2.2
            ),
            StepExecution(
                toolName: "bcftools", toolVersion: bcftoolsVersion,
                command: [
                    "\(conda)/bcftools/bin/bcftools", "call", "--ploidy", "2", "-mv", "-Ov",
                    "-o", "\(workspace)/outputs/bcftools.raw.vcf",
                ],
                inputs: [
                    FileRecord(path: "pipe:stdout:bcftools-mpileup", format: .bcf, role: .input),
                    file("\(workspace)/inputs/reference.fa", refSHA, .reference, .fasta),
                ],
                outputs: [file("\(workspace)/outputs/bcftools.raw.vcf", rawSHA, .output, .vcf)],
                exitCode: 0, wallTime: 2.2
            ),
            StepExecution(
                toolName: "bcftools", toolVersion: bcftoolsVersion,
                command: [
                    "\(conda)/bcftools/bin/bcftools", "view",
                    "-i", "(FORMAT/AD[0:1])/(FORMAT/AD[0:0]+FORMAT/AD[0:1])>=0.05 && FORMAT/DP>=10",
                    "-o", "\(workspace)/outputs/threshold-filtered.vcf", "\(workspace)/outputs/bcftools.raw.vcf",
                ],
                inputs: [file("\(workspace)/outputs/bcftools.raw.vcf", rawSHA, .input, .vcf)],
                outputs: [file("\(workspace)/outputs/threshold-filtered.vcf", filteredSHA, .output, .vcf)],
                exitCode: 0, wallTime: 0.05
            ),
            StepExecution(
                toolName: "bcftools", toolVersion: bcftoolsVersion,
                command: [
                    "\(conda)/bcftools/bin/bcftools", "sort", "-O", "v",
                    "-o", "\(workspace)/outputs/variants.normalized.vcf", "\(workspace)/outputs/threshold-filtered.vcf",
                ],
                inputs: [file("\(workspace)/outputs/threshold-filtered.vcf", filteredSHA, .input, .vcf)],
                outputs: [file("\(workspace)/outputs/variants.normalized.vcf", filteredSHA, .output, .vcf)],
                exitCode: 0, wallTime: 0.05
            ),
            StepExecution(
                toolName: "bgzip", toolVersion: htslibVersion,
                command: ["\(conda)/htslib/bin/bgzip", "-f", "-k", "-@", "14", "\(workspace)/outputs/variants.normalized.vcf"],
                inputs: [file("\(workspace)/outputs/variants.normalized.vcf", filteredSHA, .input, .vcf)],
                outputs: [file("\(workspace)/outputs/variants.normalized.vcf.gz", gzSHA, .output, .vcf)],
                exitCode: 0, wallTime: 0.02
            ),
            StepExecution(
                toolName: "tabix", toolVersion: managed("tabix", "htslib", "bioconda::htslib=1.24=hd3c6ec9_0"),
                command: ["\(conda)/htslib/bin/tabix", "-f", "-p", "vcf", "\(workspace)/outputs/variants.normalized.vcf.gz"],
                inputs: [file("\(workspace)/outputs/variants.normalized.vcf.gz", gzSHA, .input, .vcf)],
                outputs: [file("\(workspace)/outputs/variants.normalized.vcf.gz.tbi", tbiSHA, .index)],
                exitCode: 0, wallTime: 0.01
            ),
            StepExecution(
                toolName: "lungfish variant-sqlite-import", toolVersion: cliVersion,
                command: [
                    "lungfish-internal", "variant-sqlite-import",
                    "--normalized-vcf", "\(workspace)/outputs/variants.normalized.vcf",
                    "--output-database", "\(workspace)/variants.sqlite.db",
                ],
                inputs: [file("\(workspace)/outputs/variants.normalized.vcf", filteredSHA, .input, .vcf)],
                outputs: [file("\(workspace)/variants.sqlite.db", dbSHA, .output)],
                exitCode: 0, wallTime: 0.1
            ),
            StepExecution(
                toolName: "lungfish-cli", toolVersion: cliVersion,
                command: [
                    "lungfish-cli", "variants", "call", "--bundle", bundle, "--alignment-track", "aln_1",
                    "--caller", "bcftools", "--name", "HG002 bcftools", "--threads", "14",
                    "--min-af", "0.05", "--min-depth", "10", "--ploidy", "2",
                ],
                inputs: [
                    file("\(workspace)/outputs/variants.normalized.vcf.gz", gzSHA, .input, .vcf),
                    file("\(workspace)/outputs/variants.normalized.vcf.gz.tbi", tbiSHA, .index),
                    file("\(workspace)/variants.sqlite.db", dbSHA, .input),
                ],
                outputs: [
                    file("\(bundle)/variants/vc-1.vcf.gz", gzSHA, .output, .vcf),
                    file("\(bundle)/variants/vc-1.vcf.gz.tbi", tbiSHA, .index),
                    file("\(bundle)/variants/vc-1.db", trackDBSHA, .output),
                ],
                exitCode: 0, wallTime: 3
            ),
        ]
        run.endTime = start.addingTimeInterval(3)
        run.status = .completed
        return run
    }

    /// A short mapping record: minimap2 with a preset, then a samtools view
    /// that drops secondary alignments and low-quality reads.
    static func mappingRun() -> WorkflowRun {
        let project = "/build/Demo Project.lungfish"
        let analysis = "\(project)/Analyses/minimap2-1"
        let sha = "9".padding(toLength: 64, withPad: "9", startingAt: 0)
        var run = WorkflowRun(name: "lungfish map", appVersion: "lungfish-cli 2026.9.52", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = [
            StepExecution(
                toolName: "minimap2", toolVersion: "2.31 (managed conda environment minimap2; executable minimap2; package bioconda::minimap2=2.31)",
                command: ["minimap2", "-a", "-x", "sr", "-t", "4", "-o", "\(analysis)/raw.sam", "\(project)/ref.fa.gz", "\(project)/reads.fastq.gz"],
                inputs: [
                    FileRecord(path: "\(project)/reads.fastq.gz", sha256: sha, sizeBytes: 1, format: .fastq, role: .input),
                    FileRecord(path: "\(project)/ref.fa.gz", sha256: sha, sizeBytes: 1, format: .fasta, role: .reference),
                ],
                outputs: [FileRecord(path: "\(analysis)/raw.sam", sha256: sha, sizeBytes: 1, format: .sam, role: .output)],
                exitCode: 0, wallTime: 1
            ),
            StepExecution(
                toolName: "samtools", toolVersion: "1.24 (managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1)",
                command: ["samtools", "view", "-b", "-F", "256", "-q", "20", "-o", "\(analysis)/filtered.bam", "\(analysis)/raw.sam"],
                inputs: [FileRecord(path: "\(analysis)/raw.sam", sha256: sha, sizeBytes: 1, format: .sam, role: .input)],
                outputs: [FileRecord(path: "\(analysis)/filtered.bam", sha256: sha, sizeBytes: 1, format: .bam, role: .output)],
                exitCode: 0, wallTime: 1
            ),
        ]
        run.status = .completed
        return run
    }
}
