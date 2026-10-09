// ToolGoldenCases+Conda.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Cases for the tools CondaManager.runTool serves today (micromamba run -n
// <env> <tool>), and for the workflow engines ProcessManager.runAndWait
// launches.

import Foundation
@testable import LungfishWorkflow

extension ToolGoldenCase {
    static let condaCases: [ToolGoldenCase] = condaProbeCases + condaMappingCases + condaClassifierCases
        + condaReadToolCases + condaHeavyCases

    static let allCases: [ToolGoldenCase] = nativeCases + condaCases + engineCases

    static func named(_ id: String) -> ToolGoldenCase? {
        allCases.first { $0.id == id }
    }

    private static let krakenDB = "{storage}/\(F.krakenViralDB)"

    /// The kraken2 argv ClassificationConfig.kraken2Arguments builds, with one
    /// thread and the per-read output left on stdout.
    private static func kraken2Arguments(report: String, reads: [String]) -> [String] {
        ["--db", krakenDB, "--threads", "1", "--confidence", "0.0", "--minimum-hit-groups", "2",
         "--report", report, "--paired", "--report-minimizer-data"] + reads
    }

    // MARK: Environment probe

    static let condaProbeCases: [ToolGoldenCase] = [
        // What `micromamba run` hands a tool: argv after the tool name, the
        // environment's variable names and the values the runner decides.
        .init("conda-environment-probe", tool: "python (pysam env)",
              runner: .conda(environment: "pysam", executable: "python"),
              argv: ["-c", F.condaEnvironmentProbe, "argument with spaces", "{in}/genome.fasta"],
              inputs: [F.genome]),
    ]

    // MARK: Mappers

    static let condaMappingCases: [ToolGoldenCase] = [
        // 83 KB of SAM on stdout through the conda pipe drain.
        .init("minimap2-sr-paired-stdout", tool: "minimap2",
              runner: .conda(environment: "minimap2", executable: "minimap2"),
              argv: ["-a", "-x", "sr", "-t", "1", F.inGenome, F.inR1, F.inR2],
              inputs: [F.genome, F.r1, F.r2]),
        // -v 1 keeps minimap2's [M::] progress lines, which carry CPU time
        // and load ratios, off stderr. Errors still print at level 1.
        .init("minimap2-missing-input", tool: "minimap2",
              runner: .conda(environment: "minimap2", executable: "minimap2"),
              argv: ["-v", "1", "-a", "-x", "sr", "-t", "1", F.inGenome, "{in}/missing.fq"],
              inputs: [F.genome], compareStderr: true),
        .init("bwa-mem2-index", tool: "bwa-mem2",
              runner: .conda(environment: "bwa-mem2", executable: "bwa-mem2"),
              argv: ["index", "-p", "{work}/genome", F.inGenome], inputs: [F.genome],
              outputs: ["0123", "amb", "ann", "bwt.2bit.64", "pac"].map {
                  .file("{work}/genome.\($0)", name: "genome.\($0)")
              }),
        .init("bwa-mem2-mem-paired", tool: "bwa-mem2",
              runner: .conda(environment: "bwa-mem2", executable: "bwa-mem2"),
              argv: ["mem", "-t", "1", "{work}/genome", F.inR1, F.inR2],
              inputs: [F.genome, F.r1, F.r2],
              setup: [.init(runner: .conda(environment: "bwa-mem2", executable: "bwa-mem2"),
                            argv: ["index", "-p", "{work}/genome", F.inGenome])]),
        .init("bowtie2-build", tool: "bowtie2",
              runner: .conda(environment: "bowtie2", executable: "bowtie2-build"),
              argv: ["-q", "--threads", "1", "--seed", "0", F.inGenome, "{work}/genome"], inputs: [F.genome],
              outputs: ["1.bt2", "2.bt2", "3.bt2", "4.bt2", "rev.1.bt2", "rev.2.bt2"].map {
                  .file("{work}/genome.\($0)", name: "genome.\($0)")
              }),
        .init("bowtie2-align-paired", tool: "bowtie2",
              runner: .conda(environment: "bowtie2", executable: "bowtie2"),
              argv: ["-p", "1", "--seed", "0", "-x", "{work}/genome", "-1", F.inR1, "-2", F.inR2],
              inputs: [F.genome, F.r1, F.r2],
              setup: [.init(runner: .conda(environment: "bowtie2", executable: "bowtie2-build"),
                            argv: ["-q", "--threads", "1", "--seed", "0", F.inGenome, "{work}/genome"])]),
        .init("mafft-auto", tool: "mafft",
              runner: .conda(environment: "mafft", executable: "mafft"),
              argv: ["--thread", "1", "--auto", "{in}/alignment.fasta"], inputs: [F.msaInput]),
    ]

    // MARK: Classifiers

    static let condaClassifierCases: [ToolGoldenCase] = [
        .init("kraken2-viral-paired", tool: "kraken2",
              runner: .conda(environment: "kraken2", executable: "kraken2"),
              argv: kraken2Arguments(report: "{work}/classification.kreport", reads: [F.inR1, F.inR2]),
              inputs: [F.r1, F.r2], outputs: [.file("{work}/classification.kreport", name: "classification.kreport")],
              databases: [F.krakenViralDB]),
        .init("kraken2-missing-database", tool: "kraken2",
              runner: .conda(environment: "kraken2", executable: "kraken2"),
              argv: ["--db", "{work}/no-database", "--threads", "1", F.inR1], inputs: [F.r1], compareStderr: true),
        .init("bracken-viral-species", tool: "bracken",
              runner: .conda(environment: "bracken", executable: "bracken"),
              argv: ["-d", krakenDB, "-i", "{work}/classification.kreport", "-o", "{work}/bracken.tsv",
                     "-w", "{work}/bracken.kreport", "-r", "150", "-l", "S", "-t", "0"],
              inputs: [F.r1, F.r2],
              setup: [.init(runner: .conda(environment: "kraken2", executable: "kraken2"),
                            argv: kraken2Arguments(report: "{work}/classification.kreport", reads: [F.inR1, F.inR2]))],
              outputs: [.file("{work}/bracken.tsv", name: "bracken.tsv"),
                        .file("{work}/bracken.kreport", name: "bracken.kreport")],
              masks: [.brackenProgramTime], databases: [F.krakenViralDB]),
        // The database holds no database125mers.kmer_distrib. Bracken says so on stdout and exits 0.
        .init("bracken-missing-kmer-distrib", tool: "bracken",
              runner: .conda(environment: "bracken", executable: "bracken"),
              argv: ["-d", krakenDB, "-i", "{work}/classification.kreport", "-o", "{work}/bracken.tsv",
                     "-w", "{work}/bracken.kreport", "-r", "125", "-l", "S", "-t", "0"],
              inputs: [F.r1, F.r2],
              setup: [.init(runner: .conda(environment: "kraken2", executable: "kraken2"),
                            argv: kraken2Arguments(report: "{work}/classification.kreport", reads: [F.inR1, F.inR2]))],
              outputs: [.file("{work}/bracken.tsv", name: "bracken.tsv")],
              compareStderr: true, databases: [F.krakenViralDB]),
        // Bracken reports a missing database on stdout and still exits 0.
        .init("bracken-missing-database", tool: "bracken",
              runner: .conda(environment: "bracken", executable: "bracken"),
              argv: ["-d", "{work}/no-database", "-i", "{work}/missing.kreport", "-o", "{work}/bracken.tsv"],
              compareStderr: true),
    ]

    // MARK: Read tools also served through conda

    static let condaReadToolCases: [ToolGoldenCase] = [
        // FastqDeaconRiboSubcommand runs deacon through runTool.
        .init("deacon-filter-conda", tool: "deacon",
              runner: .conda(environment: "deacon", executable: "deacon"),
              argv: ["filter", "-d", "{work}/genome.idx", F.inR1], inputs: [F.genome, F.r1],
              setup: [.init(runner: .conda(environment: "deacon", executable: "deacon"),
                            argv: ["index", "build", F.inGenome, "-o", "{work}/genome.idx"])]),
        // FastqRiboDetectorSubcommand runs ribodetector_cpu through runTool.
        .init("ribodetector-paired-conda", tool: "ribodetector",
              runner: .conda(environment: "ribodetector", executable: "ribodetector_cpu"),
              argv: ["-t", "1", "-l", "150", "-i", F.inR1, F.inR2, "-e", "rrna",
                     "-o", "{work}/nonrrna_1.fq", "{work}/nonrrna_2.fq"],
              inputs: [F.r1, F.r2],
              outputs: [.file("{work}/nonrrna_1.fq", name: "nonrrna_1.fq"),
                        .file("{work}/nonrrna_2.fq", name: "nonrrna_2.fq")]),
        // PluginPackStatusService smoke-tests BBTools with reformat.sh through runTool.
        .init("bbtools-reformat-stdout-conda", tool: "BBTools reformat.sh",
              runner: .conda(environment: "bbtools", executable: "reformat.sh"),
              argv: ["-Xmx1g", "in=\(F.inR1)", "out=stdout.fq"], inputs: [F.r1]),
    ]

    // MARK: Heavy tools behind runTool

    private static func heavyConda(
        _ id: String, tool: String, environment: String, executable: String,
        version: [String] = ["--version"], error: [String], inputs: [String] = []
    ) -> [ToolGoldenCase] {
        let runner = ToolGoldenRunner.conda(environment: environment, executable: executable)
        return [
            .init("\(id)-version", tool: tool, runner: runner, tier: .heavy, argv: version, compareStderr: true),
            .init("\(id)-error", tool: tool, runner: runner, tier: .heavy, argv: error, inputs: inputs,
                  compareStderr: true, timeout: 600),
        ]
    }

    static let condaHeavyCases: [ToolGoldenCase] =
        heavyConda("esviritu", tool: "EsViritu", environment: "esviritu", executable: "EsViritu",
                   error: ["-r", "{in}/missing.fq"])
        + heavyConda("spades", tool: "SPAdes", environment: "spades", executable: "spades.py",
                     error: ["-s", "{in}/missing.fq", "-o", "{work}/spades"])
        + heavyConda("megahit", tool: "MEGAHIT", environment: "megahit", executable: "megahit",
                     error: ["--no-such-option"])
        + heavyConda("skesa", tool: "SKESA", environment: "skesa", executable: "skesa",
                     error: ["--reads", "{in}/missing.fq"])
        + heavyConda("flye", tool: "Flye", environment: "flye", executable: "flye",
                     error: ["--nano-raw", "{in}/missing.fq"])
        + heavyConda("hifiasm", tool: "hifiasm", environment: "hifiasm", executable: "hifiasm",
                     error: ["-o", "{work}/hifiasm", "{in}/missing.fq"])
        + heavyConda("savont", tool: "savont", environment: "savont", executable: "savont",
                     error: ["asv", "-o", "{work}/savont", "{in}/missing.fq"])
        + heavyConda("gatk", tool: "GATK", environment: "gatk-core", executable: "gatk",
                     error: ["HaplotypeCaller", "-I", "{in}/missing.bam"])
        + heavyConda("freyja-conda", tool: "freyja", environment: "freyja", executable: "freyja",
                     error: ["variants", "{in}/missing.bam"])
        + heavyConda("whatshap-conda", tool: "whatshap", environment: "phasing", executable: "whatshap",
                     error: ["phase", "{in}/missing.vcf", "{in}/missing.bam"])

    // MARK: Workflow engines through ProcessManager

    /// NXF_HOME points into the scratch folder so a probe never writes the
    /// user's ~/.nextflow. Everything else is the shared launch environment.
    static let engineCases: [ToolGoldenCase] = [
        .init("nextflow-version", tool: "nextflow", runner: .processManager(engine: "nextflow"), tier: .heavy,
              argv: ["-version"], compareStderr: true, environment: ["NXF_HOME": "{work}/nxf-home"]),
        .init("nextflow-run-missing-script", tool: "nextflow", runner: .processManager(engine: "nextflow"),
              tier: .heavy, argv: ["run", "{in}/missing.nf"], compareStderr: true,
              environment: ["NXF_HOME": "{work}/nxf-home"]),
        .init("snakemake-version", tool: "snakemake", runner: .processManager(engine: "snakemake"), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("snakemake-missing-snakefile", tool: "snakemake", runner: .processManager(engine: "snakemake"),
              tier: .heavy, argv: ["-s", "{in}/missing.smk", "--cores", "1"], compareStderr: true),
    ]
}
