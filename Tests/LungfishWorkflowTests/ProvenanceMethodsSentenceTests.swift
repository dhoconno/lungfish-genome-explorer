// ProvenanceMethodsSentenceTests.swift - The methods text of classifier, alignment, tree and genotype records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each run below has the step shape the writer of that analysis records today: Kraken2 then Bracken as
// `ClassificationPipeline` records them, EsViritu as `EsVirituPipeline` records it, MAFFT and IQ-TREE as
// the MSA and tree writers record their external tool, and the samtools steps of an amplicon genotyping
// run, whose tool names carry the subcommand (`samtools sort`). The tests pin the sentence of each tool.

import Foundation
import Testing
@testable import LungfishWorkflow

struct ProvenanceMethodsSentenceTests {
    private static let exporter = ProvenanceExporter(signingProvider: nil)

    // MARK: - Text helpers

    /// The "Computational Analysis" paragraph of the methods text.
    static func analysis(_ run: WorkflowRun) -> String {
        let methods = exporter.exportMethods(run)
        return methods.components(separatedBy: "Computational Analysis\n----------------------\n\n")[1]
            .components(separatedBy: "\n\nTool Versions")[0]
    }

    /// The rows of the "Tool Versions" table, header and rule left out.
    static func toolRows(_ run: WorkflowRun) -> [String] {
        let methods = exporter.exportMethods(run)
        let table = methods.components(separatedBy: "Tool Versions\n-------------\n\n")[1]
            .components(separatedBy: "\n\nInput Files")[0]
        return Array(table.components(separatedBy: "\n").dropFirst(2))
    }

    // MARK: - Methods text today

    @Test("A Kraken2 run with a Bracken profile reads as Processing was performed")
    func krakenBrackenMethodsToday() {
        let run = Self.krakenBrackenRun()
        #expect(Self.analysis(run) == """
            Processing was performed with kraken2 v2.17.1 (bioconda::kraken2=2.17.1=pl5321h158e17b_0; conda environment kraken2). \
            Processing was performed with bracken v1.0.0 (bioconda::bracken=1.0.0=1; conda environment bracken), \
            with a minimum length of S bp.
            """)
        #expect(Self.toolRows(run) == [
            "| kraken2 | 2.17.1 | bioconda::kraken2=2.17.1=pl5321h158e17b_0 | conda environment kraken2 |",
            "| bracken | 1.0.0 | bioconda::bracken=1.0.0=1 | conda environment bracken |",
        ])
    }

    @Test("An EsViritu run reads as Processing was performed")
    func esVirituMethodsToday() {
        let run = Self.esVirituRun()
        #expect(Self.analysis(run) == """
            Processing was performed with EsViritu v1.3.3 (bioconda::esviritu=1.3.3=pyhdfd78af_0; conda environment esviritu), \
            with a minimum quality score of True.
            """)
        #expect(Self.toolRows(run) == [
            "| EsViritu | 1.3.3 | bioconda::esviritu=1.3.3=pyhdfd78af_0 | conda environment esviritu |",
        ])
    }

    @Test("MAFFT and IQ-TREE read as Processing was performed")
    func alignmentAndTreeMethodsToday() {
        let run = Self.alignmentAndTreeRun()
        #expect(Self.analysis(run) == """
            Processing was performed with mafft v7.526 (conda-forge::mafft=7.526=h99b78c6_0; conda environment mafft). \
            Processing was performed with iqtree3 v3.1.3 (bioconda::iqtree=3.1.3=h6cc7423_0; conda environment iqtree).
            """)
        #expect(Self.toolRows(run) == [
            "| mafft | 7.526 | conda-forge::mafft=7.526=h99b78c6_0 | conda environment mafft |",
            "| iqtree3 | 3.1.3 | bioconda::iqtree=3.1.3=h6cc7423_0 | conda environment iqtree |",
        ])
    }

    @Test("Steps named samtools sort, merge and index get a sentence each and repeat the subcommand")
    func genotypeMethodsToday() {
        let run = Self.genotypeMappingRun()
        #expect(Self.analysis(run) == """
            Processing was performed with samtools sort v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), \
            using samtools sort sort. \
            Processing was performed with samtools merge v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), \
            using samtools merge merge. \
            Processing was performed with samtools index v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), \
            using samtools index index.
            """)
        #expect(Self.toolRows(run) == [
            "| samtools sort | 1.24 | bioconda::samtools=1.24=h36b3a25_1 | conda environment samtools |",
            "| samtools merge | 1.24 | bioconda::samtools=1.24=h36b3a25_1 | conda environment samtools |",
            "| samtools index | 1.24 | bioconda::samtools=1.24=h36b3a25_1 | conda environment samtools |",
        ])
    }

    @Test("LoFreq and iVar read as Processing was performed")
    func variantCallersMethodsToday() {
        let run = Self.variantCallerRun()
        #expect(Self.analysis(run) == """
            Processing was performed with lofreq v2.1.5 (bioconda::lofreq=2.1.5=py310h9cf5bfa_16; conda environment lofreq), \
            using lofreq indelqual and lofreq call. \
            Processing was performed with ivar v1.4.4 (bioconda::ivar=1.4.4=hda5e58c_0; conda environment ivar), \
            using ivar variants, with a minimum quality score of 20.
            """)
    }

    // MARK: - Committed golden records today

    /// The methods text of a committed golden record, read as the CLI reads it after the placeholders are restored.
    private static func goldenMethods(_ path: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("methods-golden-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try GoldenProvenanceRecords.restoredCopies(in: directory)
        let url = try #require(restored[path])
        let reading = try #require(GoldenProvenanceRecords.cliReading(of: url))
        return analysis(reading.reading.envelope.legacyWorkflowRun(preferCanonicalSteps: true))
    }

    @Test("The Kraken2 golden reads as Processing was performed")
    func krakenGoldenMethodsToday() throws {
        let text = try Self.goldenMethods("classifiers/kraken2/lungfish-provenance.json")
        #expect(text.hasPrefix("Processing was performed with kraken2 v2.17.1 (conda environment kraken2). "), Comment(rawValue: text))
        #expect(!text.contains("confidence"), Comment(rawValue: text))
    }

    @Test("The EsViritu golden reads as Processing was performed and calls -q True a quality score")
    func esVirituGoldenMethodsToday() throws {
        let text = try Self.goldenMethods("classifiers/esviritu/lungfish-provenance.json")
        #expect(
            text.hasPrefix("Processing was performed with EsViritu v1.3.3, with a minimum quality score of True. "),
            Comment(rawValue: text)
        )
    }

    @Test("The genotype golden repeats the subcommand of its samtools steps")
    func genotypeGoldenMethodsToday() throws {
        let text = try Self.goldenMethods("genotype/bundle/lungfish-provenance.json")
        #expect(text.contains("with samtools sort unknown (conda environment samtools), using samtools sort sort. "), Comment(rawValue: text))
        #expect(text.contains("with samtools merge unknown (conda environment samtools), using samtools merge merge. "), Comment(rawValue: text))
        #expect(text.contains("with samtools index unknown (conda environment samtools), using samtools index index. "), Comment(rawValue: text))
        #expect(text.contains("Reads were mapped to the reference with minimap2 unknown (conda environment minimap2), with the sr preset. "), Comment(rawValue: text))
    }

    @Test("The mapping golden names samtools once, with its subcommands")
    func mappingGoldenMethodsToday() throws {
        let text = try Self.goldenMethods("mapping/lungfish-provenance.json")
        #expect(text.hasPrefix("Reads were mapped to the reference with minimap2 v2.31 ("), Comment(rawValue: text))
        #expect(text.contains("Alignments were filtered, sorted and indexed with samtools v1.24 ("), Comment(rawValue: text))
        #expect(
            text.hasSuffix("using samtools view, samtools sort, samtools index and samtools flagstat, with secondary alignments (flag 256) excluded."),
            Comment(rawValue: text)
        )
        #expect(text.components(separatedBy: "with samtools ").count == 2, Comment(rawValue: text))
    }

    // MARK: - Fixtures

    private static func run(_ name: String, _ steps: [StepExecution]) -> WorkflowRun {
        var run = WorkflowRun(
            name: name,
            startTime: Date(timeIntervalSince1970: 1_790_000_000),
            appVersion: "lungfish-cli 2026.10.14",
            hostOS: "macOS 26.6.2 (arm64)"
        )
        run.steps = steps
        run.endTime = run.startTime.addingTimeInterval(60)
        run.status = .completed
        return run
    }

    private static func step(
        _ toolName: String,
        version: String,
        _ argv: [String],
        inputs: [String] = [],
        outputs: [String] = [],
        exitCode: Int32 = 0
    ) -> StepExecution {
        StepExecution(
            toolName: toolName, toolVersion: version, command: argv,
            inputs: inputs.map { FileRecord(path: $0, role: .input) },
            outputs: outputs.map { FileRecord(path: $0, role: .output) },
            exitCode: exitCode, wallTime: 1
        )
    }

    /// The version text a managed tool records: the version, its environment and the pinned package.
    private static func managed(_ version: String, _ environment: String, _ executable: String, _ package: String) -> String {
        "\(version) (managed conda environment \(environment); executable \(executable); package \(package))"
    }

    static let krakenVersion = managed("2.17.1", "kraken2", "kraken2", "bioconda::kraken2=2.17.1=pl5321h158e17b_0")
    static let brackenVersion = managed("1.0.0", "bracken", "bracken", "bioconda::bracken=1.0.0=1")
    static let esVirituVersion = managed("1.3.3", "esviritu", "EsViritu", "bioconda::esviritu=1.3.3=pyhdfd78af_0")
    static let mafftVersion = managed("7.526", "mafft", "mafft", "conda-forge::mafft=7.526=h99b78c6_0")
    static let iqtreeVersion = managed("3.1.3", "iqtree", "iqtree3", "bioconda::iqtree=3.1.3=h6cc7423_0")
    static let samtoolsVersion = managed("1.24", "samtools", "samtools", "bioconda::samtools=1.24=h36b3a25_1")
    static let lofreqVersion = managed("2.1.5", "lofreq", "lofreq", "bioconda::lofreq=2.1.5=py310h9cf5bfa_16")
    static let ivarVersion = managed("1.4.4", "ivar", "ivar", "bioconda::ivar=1.4.4=hda5e58c_0")

    /// A paired Kraken2 run with its Bracken profile, as `ClassificationPipeline` records the two tools.
    static func krakenBrackenRun() -> WorkflowRun {
        let analysis = "/data/project.lungfish/Analyses/kraken2-1"
        return run("Classification", [
            step(
                "kraken2", version: krakenVersion,
                [
                    "kraken2", "--db", "/data/databases/kraken2/viral", "--threads", "2",
                    "--confidence", "0.2", "--minimum-hit-groups", "2",
                    "--output", "\(analysis)/classification.kraken", "--report", "\(analysis)/classification.kreport",
                    "--paired", "--report-minimizer-data", "/data/reads_R1.fastq", "/data/reads_R2.fastq",
                ],
                inputs: ["/data/reads_R1.fastq", "/data/reads_R2.fastq"],
                outputs: ["\(analysis)/classification.kraken", "\(analysis)/classification.kreport"]
            ),
            step(
                "bracken", version: brackenVersion,
                [
                    "bracken", "-d", "/data/databases/kraken2/viral", "-i", "\(analysis)/classification.kreport",
                    "-o", "\(analysis)/classification.bracken", "-w", "\(analysis)/classification.bracken.kreport",
                    "-r", "150", "-l", "S", "-t", "10",
                ],
                inputs: ["\(analysis)/classification.kreport"],
                outputs: ["\(analysis)/classification.bracken", "\(analysis)/classification.bracken.kreport"]
            ),
        ])
    }

    /// An EsViritu run as `EsVirituPipeline` records it: `EsViritu` run with its read layout and filtering.
    static func esVirituRun() -> WorkflowRun {
        let analysis = "/data/project.lungfish/Analyses/esviritu-1"
        return run("Viral Metagenomics Detection", [
            step(
                "EsViritu", version: esVirituVersion,
                [
                    "EsViritu", "-r", "/data/sample-R1.fastq", "/data/sample-R2.fastq", "-s", "sample", "-o", analysis,
                    "-p", "paired", "-t", "2", "-q", "True", "--db", "/data/databases/esviritu/v3.2.4", "--keep", "True",
                ],
                inputs: ["/data/sample-R1.fastq", "/data/sample-R2.fastq"],
                outputs: ["\(analysis)/sample.detected_virus.info.tsv"]
            ),
        ])
    }

    /// MAFFT then IQ-TREE, each the external tool of an alignment or tree bundle.
    static func alignmentAndTreeRun() -> WorkflowRun {
        let alignment = "/data/project.lungfish/Analyses/alignment.lungfishmsa"
        let tree = "/data/project.lungfish/Analyses/tree.lungfishtree"
        return run("Alignment and tree", [
            step(
                "mafft", version: mafftVersion,
                ["mafft", "--auto", "--thread", "4", "\(alignment)/alignment/input.unaligned.fasta"],
                inputs: ["\(alignment)/alignment/input.unaligned.fasta"],
                outputs: ["\(alignment)/alignment/primary.aligned.fasta"]
            ),
            step(
                "iqtree3", version: iqtreeVersion,
                [
                    "iqtree3", "-s", "\(alignment)/alignment/primary.aligned.fasta", "-m", "MFP", "--prefix", "\(tree)/run",
                    "-T", "4", "--seqtype", "DNA", "-B", "1000", "--alrt", "1000", "--seed", "1",
                ],
                inputs: ["\(alignment)/alignment/primary.aligned.fasta"],
                outputs: ["\(tree)/run.treefile"]
            ),
        ])
    }

    /// The samtools steps of an amplicon genotyping run, whose tool names carry the subcommand.
    static func genotypeMappingRun() -> WorkflowRun {
        let conda = "/Users/someone/.lungfish/conda/envs"
        let out = "/data/out/sample.lungfishgenotype"
        return run("Illumina Paired Amplicon Genotyping", [
            step(
                "samtools sort", version: samtoolsVersion,
                ["\(conda)/samtools/bin/samtools", "sort", "-@", "2", "-o", "\(out)/mapping/001.sorted.bam", "-"],
                outputs: ["\(out)/mapping/001.sorted.bam"]
            ),
            step(
                "samtools sort", version: samtoolsVersion,
                ["\(conda)/samtools/bin/samtools", "sort", "-@", "2", "-o", "\(out)/mapping/002.sorted.bam", "-"],
                outputs: ["\(out)/mapping/002.sorted.bam"]
            ),
            step(
                "samtools merge", version: samtoolsVersion,
                [
                    "\(conda)/samtools/bin/samtools", "merge", "-f", "\(out)/sample.md.sorted.bam",
                    "\(out)/mapping/001.sorted.bam", "\(out)/mapping/002.sorted.bam",
                ],
                inputs: ["\(out)/mapping/001.sorted.bam", "\(out)/mapping/002.sorted.bam"],
                outputs: ["\(out)/sample.md.sorted.bam"]
            ),
            step(
                "samtools index", version: samtoolsVersion,
                ["\(conda)/samtools/bin/samtools", "index", "\(out)/sample.md.sorted.bam"],
                inputs: ["\(out)/sample.md.sorted.bam"],
                outputs: ["\(out)/sample.md.sorted.bam.bai"]
            ),
        ])
    }

    /// LoFreq with its preparation steps, then iVar after samtools.
    static func variantCallerRun() -> WorkflowRun {
        let conda = "/Users/someone/.lungfish/conda/envs"
        let work = "/data/project.lungfish/Analyses/variants-1"
        return run("Viral variant calling", [
            step(
                "lofreq", version: lofreqVersion,
                ["\(conda)/lofreq/bin/lofreq", "indelqual", "--dindel", "-f", "/data/ref.fa", "-o", "\(work)/indelqual.bam", "/data/aln.bam"],
                inputs: ["/data/aln.bam"], outputs: ["\(work)/indelqual.bam"]
            ),
            step(
                "lofreq", version: lofreqVersion,
                ["\(conda)/lofreq/bin/lofreq", "call", "-f", "/data/ref.fa", "-o", "\(work)/raw.vcf", "\(work)/indelqual.bam"],
                inputs: ["\(work)/indelqual.bam"], outputs: ["\(work)/raw.vcf"]
            ),
            step(
                "ivar", version: ivarVersion,
                [
                    "\(conda)/ivar/bin/ivar", "variants", "-p", "\(work)/ivar.tsv-prefix", "-q", "20", "-t", "0.05",
                    "-m", "10", "-r", "/data/ref.fa",
                ],
                inputs: ["/data/ref.fa"], outputs: ["\(work)/ivar.tsv-prefix.tsv"]
            ),
        ])
    }
}
