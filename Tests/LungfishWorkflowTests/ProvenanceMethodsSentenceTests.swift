// ProvenanceMethodsSentenceTests.swift - The methods text of classifier, alignment, tree and genotype records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each run below has the step shape the writer of that analysis records today: Kraken2 then Bracken as
// `ClassificationPipeline` records them, EsViritu as `EsVirituPipeline` records it, MAFFT and IQ-TREE as
// the MSA and tree writers record their external tool, and the samtools steps of an amplicon genotyping
// run, whose tool names carry the subcommand (`samtools sort`). The tests pin the sentence of each tool.

import Foundation
import LungfishTestSupport
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

    // MARK: - Sentences

    @Test("Kraken2 and Bracken each get their sentence and the parameters they ran with")
    func krakenBrackenMethods() {
        let run = Self.krakenBrackenRun()
        #expect(Self.analysis(run) == """
            Reads were classified taxonomically with kraken2 v2.17.1 (bioconda::kraken2=2.17.1=pl5321h158e17b_0; conda environment kraken2), \
            with a confidence threshold of 0.2, a minimum of 2 hit groups and paired-end mode. \
            Taxon abundances were re-estimated with bracken v1.0.0 (bioconda::bracken=1.0.0=1; conda environment bracken), \
            with a read length of 150 bp, the S (species) level and a minimum of 10 reads per taxon.
            """)
        #expect(Self.toolRows(run) == [
            "| kraken2 | 2.17.1 | bioconda::kraken2=2.17.1=pl5321h158e17b_0 | conda environment kraken2 |",
            "| bracken | 1.0.0 | bioconda::bracken=1.0.0=1 | conda environment bracken |",
        ])
    }

    @Test("EsViritu gets its sentence, its quality filtering and its read layout")
    func esVirituMethods() {
        let run = Self.esVirituRun()
        #expect(Self.analysis(run) == """
            Viral sequences were detected with EsViritu v1.3.3 (bioconda::esviritu=1.3.3=pyhdfd78af_0; conda environment esviritu), \
            with quality filtering and the paired read layout.
            """)
        #expect(Self.toolRows(run) == [
            "| EsViritu | 1.3.3 | bioconda::esviritu=1.3.3=pyhdfd78af_0 | conda environment esviritu |",
        ])
    }

    @Test("MAFFT and IQ-TREE get their sentences")
    func alignmentAndTreeMethods() {
        let run = Self.alignmentAndTreeRun()
        #expect(Self.analysis(run) == """
            Sequences were aligned with mafft v7.526 (conda-forge::mafft=7.526=h99b78c6_0; conda environment mafft). \
            A phylogeny was inferred with iqtree3 v3.1.3 (bioconda::iqtree=3.1.3=h6cc7423_0; conda environment iqtree).
            """)
        #expect(Self.toolRows(run) == [
            "| mafft | 7.526 | conda-forge::mafft=7.526=h99b78c6_0 | conda environment mafft |",
            "| iqtree3 | 3.1.3 | bioconda::iqtree=3.1.3=h6cc7423_0 | conda environment iqtree |",
        ])
    }

    @Test("LoFreq and iVar say that variants were called, and each tool of the iVar pipe reports only its own parameters")
    func variantCallerMethods() {
        let run = Self.variantCallerRun()
        let text = Self.analysis(run)
        let lofreq = "Variants were called with lofreq v2.1.5 (bioconda::lofreq=2.1.5=py310h9cf5bfa_16; conda environment lofreq), using lofreq indelqual and lofreq call."
        // The writer records samtools mpileup and ivar variants as two steps joined by a pipe. mpileup's -q 0 is a
        // mapping quality and ivar's -q 20 a base quality, and neither sentence reads the other's flag.
        let samtools = "Alignments were processed with samtools v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), using samtools mpileup, with a minimum mapping quality of 0."
        #expect(text.hasPrefix(lofreq + " " + samtools + " Variants were called with ivar "), Comment(rawValue: text))
        #expect(text.hasSuffix(", using ivar variants, with a minimum quality score of 20."), Comment(rawValue: text))
        let rows = Self.toolRows(run)
        #expect(rows.count == 3, Comment(rawValue: rows.joined(separator: "\n")))
        #expect(rows.first == "| lofreq | 2.1.5 | bioconda::lofreq=2.1.5=py310h9cf5bfa_16 | conda environment lofreq |")
        #expect(rows.dropFirst().first == "| samtools | 1.24 | bioconda::samtools=1.24=h36b3a25_1 | conda environment samtools |")
        // The plan joins the two steps into one named `samtools | ivar` and keeps the identity of each stage, so iVar is
        // stated with its own version, package and environment and not with samtools's (B8 review fix 5).
        #expect(
            text.hasSuffix("Variants were called with ivar v1.4.4 (bioconda::ivar=1.4.4=hda5e58c_0; conda environment ivar), using ivar variants, with a minimum quality score of 20."),
            Comment(rawValue: text)
        )
        #expect(rows.last == "| ivar | 1.4.4 | bioconda::ivar=1.4.4=hda5e58c_0 | conda environment ivar |", Comment(rawValue: rows.joined(separator: "\n")))
    }

    @Test("Three piped tools each state their own version, package and environment")
    func threeStagePipeStatesEachStagesIdentity() {
        let run = Self.trimMapSortRun()
        // The three records join into one step named `fastp | minimap2 | samtools`, and each tool states its own identity.
        #expect(Self.analysis(run) == """
            Reads were quality-filtered and trimmed with fastp v1.3.6 (bioconda::fastp=1.3.6=ha1d0559_0; conda environment fastp). \
            Reads were mapped to the reference with minimap2 v2.31 (bioconda::minimap2=2.31=h6bd33b9_0; conda environment minimap2), \
            with the sr preset. \
            Alignments were sorted with samtools v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), \
            using samtools sort.
            """)
        #expect(Self.toolRows(run) == [
            "| fastp | 1.3.6 | bioconda::fastp=1.3.6=ha1d0559_0 | conda environment fastp |",
            "| minimap2 | 2.31 | bioconda::minimap2=2.31=h6bd33b9_0 | conda environment minimap2 |",
            "| samtools | 1.24 | bioconda::samtools=1.24=h36b3a25_1 | conda environment samtools |",
        ])
    }

    @Test("A joined pipe keeps one identity for each stage, in pipe order")
    func joinedPipeKeepsOneIdentityForEachStage() throws {
        func plan(_ run: WorkflowRun) -> ProvenanceExportPlan {
            ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command })
        }
        let trimMapSort = plan(Self.trimMapSortRun())
        #expect(trimMapSort.steps.count == 1)
        let joined = try #require(trimMapSort.steps.first)
        #expect(joined.commands.count == 3)
        #expect(joined.stageIdentities.map(\.toolName) == ["fastp", "minimap2", "samtools"])
        #expect(joined.stageIdentities.map(\.version) == ["1.3.6", "2.31", "1.24"])
        // The step as a whole is labelled by its first stage, as the scripts and the pin gate read it.
        #expect(joined.identity == joined.stageIdentities[0])
        // The iVar run has a pipe too, and each of its steps has one identity for each command, which is how the methods
        // text pairs a tool with its stage.
        let variantCaller = plan(Self.variantCallerRun())
        let ivarPipe = try #require(variantCaller.steps.first { $0.commands.count == 2 })
        #expect(ivarPipe.stageIdentities.map(\.toolName) == ["samtools", "ivar"])
        #expect(ivarPipe.stageIdentities.map(\.version) == ["1.24", "1.4.4"])
        for step in variantCaller.steps {
            #expect(step.stageIdentities.count == step.commands.count, Comment(rawValue: step.toolName))
        }
    }

    @Test("Steps named samtools sort, merge and index share the samtools sentence and its version row")
    func samtoolsSubcommandNamesShareOneSentence() {
        let run = Self.genotypeMappingRun()
        // The record sorts, merges and indexes. Its filter is a separate pysam step, so "filtered" is not said.
        #expect(Self.analysis(run) == """
            Alignments were sorted, merged and indexed with samtools v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), \
            using samtools sort, samtools merge and samtools index.
            """)
        #expect(Self.toolRows(run) == [
            "| samtools | 1.24 | bioconda::samtools=1.24=h36b3a25_1 | conda environment samtools |",
        ])
    }

    @Test("A pipe of samtools view and samtools sort names samtools once")
    func pipedSubcommandNamesFold() {
        let run = Self.run("Filtering", [
            Self.step(
                "samtools view", version: Self.samtoolsVersion,
                ["samtools", "view", "-b", "-F", "256", "/data/raw.sam"],
                inputs: ["/data/raw.sam"], outputs: ["pipe:stdout:view-sort"]
            ),
            Self.step(
                "samtools sort", version: Self.samtoolsVersion,
                ["samtools", "sort", "-o", "/data/sorted.bam", "-"],
                inputs: ["pipe:stdout:view-sort"], outputs: ["/data/sorted.bam"]
            ),
        ])
        // No index step ran, so "indexed" is not said.
        #expect(Self.analysis(run) == """
            Alignments were filtered and sorted with samtools v1.24 (bioconda::samtools=1.24=h36b3a25_1; conda environment samtools), \
            using samtools view and samtools sort, with secondary alignments (flag 256) excluded.
            """)
        #expect(Self.toolRows(run).count == 1)
    }

    @Test("The samtools sentence names only the subcommands that ran, in pipeline order")
    func samtoolsSentenceNamesTheSubcommandsThatRan() {
        /// The subject of the sentence for a run that ran `verbs` in the order given.
        func subject(_ verbs: [String]) -> String {
            let steps = verbs.map { Self.step("samtools \($0)", version: "1.0", ["samtools", $0, "x.bam"]) }
            return Self.analysis(Self.run("Alignments", steps)).components(separatedBy: " with samtools ")[0]
        }
        #expect(subject(["view"]) == "Alignments were filtered")
        #expect(subject(["sort"]) == "Alignments were sorted")
        #expect(subject(["merge"]) == "Alignments were merged")
        #expect(subject(["index"]) == "Alignments were indexed")
        #expect(subject(["sort", "index"]) == "Alignments were sorted and indexed")
        #expect(subject(["view", "sort", "index", "flagstat"]) == "Alignments were filtered, sorted and indexed")
        #expect(subject(["sort", "merge", "index"]) == "Alignments were sorted, merged and indexed")
        // The order is the pipeline's, whatever order the steps were recorded in.
        #expect(subject(["index", "merge", "sort", "view"]) == "Alignments were filtered, sorted, merged and indexed")
        // A subcommand that neither filters, sorts, merges nor indexes alignments adds no verb.
        #expect(subject(["flagstat"]) == "Alignments were processed")
        #expect(subject(["faidx"]) == "The reference was indexed")
    }

    @Test("A descriptive tool name keeps its own sentence and version row")
    func descriptiveNamesStay() {
        let run = Self.run("Genotyping", [
            Self.step(
                "pysam retained-read demux filter", version: "unknown",
                ["/envs/pysam/bin/python", "/work/filter-demux-retained-bam.py", "--input-bam", "/work/sorted.bam"]
            ),
            Self.step("openpyxl ONT genotype workbook report", version: "3.1.5", ["/envs/openpyxl/bin/python", "/work/renderer.py"]),
        ])
        #expect(Self.analysis(run) == """
            Processing was performed with pysam retained-read demux filter unknown (conda environment pysam). \
            Processing was performed with openpyxl ONT genotype workbook report v3.1.5 (conda environment openpyxl).
            """)
        #expect(Self.toolRows(run).count == 2)
    }

    // MARK: - Parameters

    /// The sentence of a run of one step of `tool`, at version 1.0, that ran `argv`.
    private static func sentence(_ tool: String, _ argv: [String]) -> String {
        analysis(run("One step", [step(tool, version: "1.0", argv)]))
    }

    @Test("Kraken2 reports its confidence, hit groups and paired-end mode, and nothing it did not set")
    func krakenParameters() {
        #expect(Self.sentence("kraken2", ["kraken2", "--db", "/db", "--confidence", "0.5", "--minimum-hit-groups", "3"])
            == "Reads were classified taxonomically with kraken2 v1.0, with a confidence threshold of 0.5 and a minimum of 3 hit groups.")
        #expect(Self.sentence("kraken2", ["kraken2", "--confidence=0.05", "--minimum-hit-groups=1", "--paired", "a.fq", "b.fq"])
            == "Reads were classified taxonomically with kraken2 v1.0, with a confidence threshold of 0.05, a minimum of 1 hit group and paired-end mode.")
        #expect(Self.sentence("kraken2", ["kraken2", "--db", "/db", "--threads", "4", "--quick", "reads.fq"])
            == "Reads were classified taxonomically with kraken2 v1.0.")
        // A value that is no number, and a flag in place of a value, are not parameters.
        #expect(Self.sentence("kraken2", ["kraken2", "--confidence", "high", "--minimum-hit-groups", "--paired"])
            == "Reads were classified taxonomically with kraken2 v1.0, with paired-end mode.")
    }

    @Test("Bracken reports its read length, level and minimum reads, and its flags are no other tool's")
    func brackenParameters() {
        #expect(Self.sentence("bracken", ["bracken", "-d", "/db", "-i", "in.kreport", "-o", "out", "-r", "100", "-l", "G", "-t", "1"])
            == "Taxon abundances were re-estimated with bracken v1.0, with a read length of 100 bp, the G (genus) level and a minimum of 1 read per taxon.")
        // The inner script has no -r, and the name of its distribution file holds the read length.
        #expect(Self.sentence("bracken", ["bracken", "-i", "in.kreport", "-k", "/db/database75mers.kmer_distrib", "-l", "S", "-t", "10"])
            == "Taxon abundances were re-estimated with bracken v1.0, with a read length of 75 bp, the S (species) level and a minimum of 10 reads per taxon.")
        // A level code outside the table is reported as given, and -l is a level, never a length.
        #expect(Self.sentence("bracken", ["bracken", "-l", "S1"]) == "Taxon abundances were re-estimated with bracken v1.0, with the S1 level.")
        #expect(Self.sentence("bracken", ["bracken", "-l", "S", "-q", "20"]) == "Taxon abundances were re-estimated with bracken v1.0, with the S (species) level.")
    }

    @Test("EsViritu reports its quality filtering and read layout, and -q is a switch, never a score")
    func esVirituParameters() {
        #expect(Self.sentence("EsViritu", ["EsViritu", "-r", "r.fq", "-s", "s", "-o", "/out", "-p", "interleaved", "-t", "4", "-q", "False"])
            == "Viral sequences were detected with EsViritu v1.0, with no quality filtering and the interleaved read layout.")
        #expect(Self.sentence("EsViritu", ["EsViritu", "-r", "r.fq", "-p", "unpaired", "-q", "true"])
            == "Viral sequences were detected with EsViritu v1.0, with quality filtering and the unpaired read layout.")
        // A value outside the ones EsViritu takes is not reported.
        #expect(Self.sentence("EsViritu", ["EsViritu", "-p", "mixed", "-q", "20"]) == "Viral sequences were detected with EsViritu v1.0.")
    }

    @Test("A LoFreq or iVar step that calls no variants does not say it did")
    func variantSentenceFollowsTheSubcommand() {
        #expect(Self.sentence("lofreq", ["lofreq", "call-parallel", "--pp-threads", "4", "-f", "ref.fa", "in.bam"])
            .hasPrefix("Variants were called with lofreq v1.0"))
        #expect(Self.sentence("lofreq", ["lofreq", "indelqual", "--dindel", "-f", "ref.fa", "in.bam"])
            .hasPrefix("Processing was performed with lofreq v1.0"))
        #expect(Self.sentence("ivar", ["ivar", "variants", "-p", "out", "-t", "0.05"]).hasPrefix("Variants were called with ivar v1.0"))
        #expect(Self.sentence("ivar", ["ivar", "trim", "-b", "primers.bed", "-i", "in.bam", "-p", "out"])
            .hasPrefix("Processing was performed with ivar v1.0"))
        #expect(Self.sentence("ivar", ["ivar", "consensus", "-p", "out"]).hasPrefix("Processing was performed with ivar v1.0"))
    }

    // MARK: - Program token

    @Test("The program token is the first word of the tool name without its folder")
    func programToken() {
        #expect(ProvenanceExporter.methodsProgram(of: "samtools sort") == "samtools")
        #expect(ProvenanceExporter.methodsProgram(of: "/opt/conda/bin/Samtools") == "samtools")
        #expect(ProvenanceExporter.methodsProgram(of: "EsViritu") == "esviritu")
        #expect(ProvenanceExporter.methodsProgram(of: "iqtree3") == "iqtree3")
        #expect(ProvenanceExporter.methodsProgram(of: "") == "")
        #expect(ProvenanceExporter.methodsProgram(of: "   ") == "")
    }

    @Test("A name that is a program and the subcommand it ran stands for the program")
    func subcommandNamesFold() {
        let sort = ["/envs/samtools/bin/samtools", "sort", "-o", "out.bam", "in.bam"]
        #expect(ProvenanceExporter.methodsToolName("samtools sort", ranAs: sort) == "samtools")
        #expect(ProvenanceExporter.methodsToolName("Samtools sort", ranAs: ["samtools", "sort"]) == "Samtools")
        // The name must be the program and the subcommand the command ran. Any other name stays as recorded.
        #expect(ProvenanceExporter.methodsToolName("samtools merge", ranAs: sort) == "samtools merge")
        #expect(ProvenanceExporter.methodsToolName("samtools sort", ranAs: ["bcftools", "sort"]) == "samtools sort")
        #expect(ProvenanceExporter.methodsToolName("samtools sort", ranAs: ["samtools"]) == "samtools sort")
        #expect(ProvenanceExporter.methodsToolName("samtools sort", ranAs: []) == "samtools sort")
        #expect(ProvenanceExporter.methodsToolName("samtools", ranAs: sort) == "samtools")
        let python = ["/envs/pysam/bin/python", "filter.py"]
        #expect(ProvenanceExporter.methodsToolName("pysam retained-read demux filter", ranAs: python) == "pysam retained-read demux filter")
        #expect(ProvenanceExporter.methodsToolName("lungfish fastq quality-trim join", ranAs: ["/bin/cat", "a.fq"]) == "lungfish fastq quality-trim join")
    }

    // MARK: - Committed golden records

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

    @Test("The Kraken2 golden reports the confidence and hit groups it ran with")
    func krakenGoldenMethods() throws {
        let text = try Self.goldenMethods("classifiers/kraken2/lungfish-provenance.json")
        #expect(
            text.hasPrefix("Reads were classified taxonomically with kraken2 v2.17.1 (conda environment kraken2), with a confidence threshold of 0.2 and a minimum of 2 hit groups. "),
            Comment(rawValue: text)
        )
    }

    @Test("The EsViritu golden reports its quality filtering and read layout")
    func esVirituGoldenMethods() throws {
        let text = try Self.goldenMethods("classifiers/esviritu/lungfish-provenance.json")
        #expect(
            text.hasPrefix("Viral sequences were detected with EsViritu v1.3.3, with quality filtering and the unpaired read layout. "),
            Comment(rawValue: text)
        )
    }

    @Test("The genotype golden names samtools once and keeps its descriptive tool names")
    func genotypeGoldenMethods() throws {
        let text = try Self.goldenMethods("genotype/bundle/lungfish-provenance.json")
        #expect(
            text.contains("Alignments were sorted, merged and indexed with samtools v1.24 (conda environment samtools), using samtools sort, samtools merge and samtools index. "),
            Comment(rawValue: text)
        )
        #expect(text.contains("Processing was performed with pysam retained-read demux filter v0.24.0 (conda environment pysam). "), Comment(rawValue: text))
        #expect(!text.contains("sort sort"), Comment(rawValue: text))
        #expect(text.contains("Reads were mapped to the reference with minimap2 v2.31 (conda environment minimap2), with the sr preset. "), Comment(rawValue: text))
    }

    // MARK: - Records in the older shape

    @Test("The MAFFT alignment record of the compatibility corpus reaches the methods text")
    func mafftRecordReachesMethods() throws {
        let sidecar = ProvenanceCompatCorpus.root.appendingPathComponent(
            "cases/s4-msa-mafft-2026-05/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa/.lungfish-provenance.json"
        )
        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecar))
        let text = Self.analysis(envelope.legacyWorkflowRun(preferCanonicalSteps: true))
        #expect(text == "Sequences were aligned with mafft v7.526.", Comment(rawValue: text))
    }

    @Test("A tree record in the older shape reaches the methods text as IQ-TREE")
    func treeRecordReachesMethods() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "workflowName": "phylogenetic-tree-infer-iqtree",
          "toolName": "lungfish tree infer iqtree",
          "toolVersion": "0.5.0-alpha6",
          "argv": ["lungfish", "tree", "infer", "iqtree", "aligned.lungfishmsa"],
          "input": {"path": "/project/aligned.lungfishmsa", "sha256": "\(String(repeating: "e", count: 64))", "fileSizeBytes": 100},
          "output": {"path": "/project/tree.lungfishtree", "sha256": "\(String(repeating: "f", count: 64))", "fileSizeBytes": 200},
          "externalTool": {
            "toolName": "iqtree3",
            "toolVersion": "3.1.3",
            "argv": ["iqtree3", "-s", "input.aligned.fasta", "-m", "MFP", "-B", "1000", "--seed", "1"],
            "reproducibleCommand": "iqtree3 -s input.aligned.fasta -m MFP -B 1000 --seed 1",
            "exitStatus": 0,
            "wallTimeSeconds": 3.0
          },
          "exitStatus": 0,
          "wallTimeSeconds": 4.0
        }
        """.utf8)
        let envelope = try ProvenanceEnvelopeReader.decode(data)
        let text = Self.analysis(envelope.legacyWorkflowRun(preferCanonicalSteps: true))
        #expect(text == "A phylogeny was inferred with iqtree3 v3.1.3.", Comment(rawValue: text))
    }

    @Test("The mapping golden, whose steps are named by program alone, reads as it did")
    func mappingGoldenMethods() throws {
        let text = try Self.goldenMethods("mapping/lungfish-provenance.json")
        #expect(text.hasPrefix("Reads were mapped to the reference with minimap2 v2.31 ("), Comment(rawValue: text))
        #expect(text.contains("Alignments were filtered, sorted and indexed with samtools v1.24 ("), Comment(rawValue: text))
        #expect(
            text.hasSuffix("using samtools view, samtools sort, samtools index, samtools flagstat and samtools coverage, with secondary alignments (flag 256) excluded."),
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
    static let fastpVersion = managed("1.3.6", "fastp", "fastp", "bioconda::fastp=1.3.6=ha1d0559_0")
    static let minimap2Version = managed("2.31", "minimap2", "minimap2", "bioconda::minimap2=2.31=h6bd33b9_0")

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

    /// LoFreq with its preparation steps, then iVar after samtools, as `ViralVariantCallingPipeline` records the
    /// iVar path: a `samtools` step running `mpileup` that writes `pipe:stdout:samtools-mpileup`, and an `ivar`
    /// step running `variants` that reads it. The plan joins the two into one step named `samtools | ivar`.
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
                "samtools", version: samtoolsVersion,
                [
                    "\(conda)/samtools/bin/samtools", "mpileup", "-aa", "-A", "-d", "600000", "-B", "-Q", "20", "-q", "0",
                    "-f", "/data/ref.fa", "/data/aln.bam",
                ],
                inputs: ["/data/ref.fa", "/data/aln.bam"], outputs: ["pipe:stdout:samtools-mpileup"]
            ),
            step(
                "ivar", version: ivarVersion,
                [
                    "\(conda)/ivar/bin/ivar", "variants", "-p", "\(work)/ivar.tsv-prefix", "-q", "20", "-t", "0.05",
                    "-m", "10", "-r", "/data/ref.fa",
                ],
                inputs: ["pipe:stdout:samtools-mpileup", "/data/ref.fa"], outputs: ["\(work)/ivar.tsv-prefix.tsv"]
            ),
        ])
    }

    /// fastp, minimap2 and samtools joined by two pipes, each tool at its own version. Each is a record of its own that
    /// writes or reads a `pipe:stdout:` pseudo-file, and the plan joins the three into one step.
    static func trimMapSortRun() -> WorkflowRun {
        let conda = "/Users/someone/.lungfish/conda/envs"
        return run("Trim, map and sort", [
            step(
                "fastp", version: fastpVersion,
                ["\(conda)/fastp/bin/fastp", "--stdout", "-i", "/data/reads.fq", "-w", "2"],
                inputs: ["/data/reads.fq"], outputs: ["pipe:stdout:fastp-trim"]
            ),
            step(
                "minimap2", version: minimap2Version,
                ["\(conda)/minimap2/bin/minimap2", "-a", "-x", "sr", "-t", "2", "/data/ref.fa", "-"],
                inputs: ["pipe:stdout:fastp-trim", "/data/ref.fa"], outputs: ["pipe:stdout:minimap2-sam"]
            ),
            step(
                "samtools", version: samtoolsVersion,
                ["\(conda)/samtools/bin/samtools", "sort", "-o", "/data/out/sorted.bam", "-"],
                inputs: ["pipe:stdout:minimap2-sam"], outputs: ["/data/out/sorted.bam"]
            ),
        ])
    }
}
