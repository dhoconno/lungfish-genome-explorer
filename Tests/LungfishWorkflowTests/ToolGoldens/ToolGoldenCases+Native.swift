// ToolGoldenCases+Native.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Cases for the tools NativeToolRunner serves today: run, runProcess,
// runWithFileOutput and runPipeline.

import Foundation
@testable import LungfishWorkflow

extension ToolGoldenCase {
    typealias F = ToolGoldenFixtures

    static let nativeCases: [ToolGoldenCase] = samtoolsCases + htslibCases + readToolCases
        + bbtoolsCases + variantCases + otherNativeCases + heavyNativeCases
        + nativeProcessCases + fileOutputCases + pipelineCases

    // MARK: samtools

    static let samtoolsCases: [ToolGoldenCase] = [
        .init("samtools-view-header", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["view", "-H", "--no-PG", F.inBAM], inputs: [F.bam, F.bai]),
        // 84 KB of SAM records, past the 64 KB pipe buffer.
        .init("samtools-view-records-large", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["view", "--no-PG", F.inBAM], inputs: [F.bam, F.bai]),
        // 556 KB of per-base depth over the whole contig.
        .init("samtools-depth-large", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["depth", "-a", F.inBAM], inputs: [F.bam, F.bai]),
        .init("samtools-flagstat", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["flagstat", F.inBAM], inputs: [F.bam, F.bai]),
        .init("samtools-idxstats", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["idxstats", F.inBAM], inputs: [F.bam, F.bai]),
        .init("samtools-sort-by-name", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["sort", "-n", "--no-PG", "-@", "1", "-o", "{work}/name-sorted.bam", F.inBAM],
              inputs: [F.bam, F.bai], outputs: [.bam("{work}/name-sorted.bam", name: "name-sorted.bam")]),
        .init("samtools-faidx", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["faidx", F.inGenome], inputs: [F.genome],
              outputs: [.file("{in}/genome.fasta.fai", name: "genome.fasta.fai")]),
        .init("samtools-view-missing-input", tool: "samtools", runner: .nativeTool(.samtools),
              argv: ["view", "{in}/missing.bam"], compareStderr: true),
    ]

    // MARK: bcftools, tabix, bgzip

    static let htslibCases: [ToolGoldenCase] = [
        .init("bcftools-view", tool: "bcftools", runner: .nativeTool(.bcftools),
              argv: ["view", "--no-version", "{in}/test.vcf.gz"], inputs: [F.vcfGz, F.vcfTbi]),
        .init("bcftools-stats", tool: "bcftools", runner: .nativeTool(.bcftools),
              argv: ["stats", "{in}/test.vcf.gz"], inputs: [F.vcfGz, F.vcfTbi]),
        .init("bcftools-view-missing-input", tool: "bcftools", runner: .nativeTool(.bcftools),
              argv: ["view", "--no-version", "{in}/missing.vcf.gz"], compareStderr: true),
        .init("tabix-index-vcf", tool: "tabix", runner: .nativeTool(.tabix),
              argv: ["-p", "vcf", "{in}/test.vcf.gz"], inputs: [F.vcfGz],
              outputs: [.file("{in}/test.vcf.gz.tbi", name: "test.vcf.gz.tbi")]),
        .init("tabix-region-query", tool: "tabix", runner: .nativeTool(.tabix),
              argv: ["{in}/test.vcf.gz", "MT192765.1:1-10000"], inputs: [F.vcfGz, F.vcfTbi]),
        .init("tabix-index-missing-input", tool: "tabix", runner: .nativeTool(.tabix),
              argv: ["-p", "vcf", "{in}/missing.vcf.gz"], compareStderr: true),
        .init("bgzip-decompress-stdout", tool: "bgzip", runner: .nativeTool(.bgzip),
              argv: ["-d", "-c", "{in}/test.vcf.gz"], inputs: [F.vcfGz]),
        .init("bgzip-missing-input", tool: "bgzip", runner: .nativeTool(.bgzip),
              argv: ["-c", "{in}/missing.vcf"], compareStderr: true),
    ]

    // MARK: Read tools

    static let readToolCases: [ToolGoldenCase] = [
        .init("seqkit-stats", tool: "seqkit", runner: .nativeTool(.seqkit),
              argv: ["stats", "-a", "-T", "-j", "1", F.inR1, F.inR2], inputs: [F.r1, F.r2]),
        // 396 KB of 100-base windows, through a Go writer.
        .init("seqkit-sliding-large", tool: "seqkit", runner: .nativeTool(.seqkit),
              argv: ["sliding", "-s", "10", "-W", "100", "-j", "1", F.inGenome], inputs: [F.genome]),
        .init("seqkit-stats-missing-input", tool: "seqkit", runner: .nativeTool(.seqkit),
              argv: ["stats", "-T", "-j", "1", "{in}/missing.fq"], compareStderr: true),
        .init("fastp-paired", tool: "fastp", runner: .nativeTool(.fastp),
              argv: ["-i", F.inR1, "-I", F.inR2, "-o", "{work}/trimmed_1.fq.gz", "-O", "{work}/trimmed_2.fq.gz",
                     "-j", "{work}/fastp.json", "-h", "{work}/fastp.html", "-w", "1"],
              inputs: [F.r1, F.r2],
              outputs: [.file("{work}/trimmed_1.fq.gz", name: "trimmed_1.fq.gz"),
                        .file("{work}/trimmed_2.fq.gz", name: "trimmed_2.fq.gz"),
                        .file("{work}/fastp.json", name: "fastp.json")]),
        .init("fastp-missing-input", tool: "fastp", runner: .nativeTool(.fastp),
              argv: ["-i", "{in}/missing.fq", "-o", "{work}/out.fq", "-j", "{work}/fastp.json",
                     "-h", "{work}/fastp.html", "-w", "1"],
              compareStderr: true),
        .init("cutadapt-adapter-trim", tool: "cutadapt", runner: .nativeTool(.cutadapt),
              argv: ["-a", "AGATCGGAAGAGC", "-j", "1", "--report=minimal", "-o", "{work}/trimmed.fastq", F.inR1],
              inputs: [F.r1], outputs: [.file("{work}/trimmed.fastq", name: "trimmed.fastq")]),
        .init("cutadapt-missing-input", tool: "cutadapt", runner: .nativeTool(.cutadapt),
              argv: ["-a", "AGATCGGAAGAGC", "-j", "1", "--report=minimal", "-o", "{work}/trimmed.fastq",
                     "{in}/missing.fq"],
              compareStderr: true),
        .init("trim-galore-single", tool: "trim_galore", runner: .nativeTool(.trimGalore),
              argv: ["--dont_gzip", "--cores", "1", "-o", "{work}/trim-galore", F.inR1], inputs: [F.r1],
              outputs: [.file("{work}/trim-galore/test_1_trimmed.fq", name: "test_1_trimmed.fq")]),
        .init("trim-galore-missing-input", tool: "trim_galore", runner: .nativeTool(.trimGalore),
              argv: ["--dont_gzip", "--cores", "1", "-o", "{work}/trim-galore", "{in}/missing.fq"],
              compareStderr: true),
        .init("vsearch-fastx-uniques", tool: "vsearch", runner: .nativeTool(.vsearch),
              argv: ["--fastx_uniques", F.inR1, "--fastaout", "{work}/uniques.fasta", "--threads", "1", "--quiet"],
              inputs: [F.r1], outputs: [.file("{work}/uniques.fasta", name: "uniques.fasta")]),
        .init("vsearch-missing-input", tool: "vsearch", runner: .nativeTool(.vsearch),
              argv: ["--fastx_uniques", "{in}/missing.fq", "--fastaout", "{work}/uniques.fasta", "--threads", "1", "--quiet"],
              compareStderr: true),
        .init("deacon-index-build", tool: "deacon", runner: .nativeTool(.deacon),
              argv: ["index", "build", F.inGenome, "-o", "{work}/genome.idx"], inputs: [F.genome],
              outputs: [.file("{work}/genome.idx", name: "genome.idx")]),
        .init("deacon-filter", tool: "deacon", runner: .nativeTool(.deacon),
              argv: ["filter", "-d", "{work}/genome.idx", F.inR1], inputs: [F.genome, F.r1],
              setup: [.init(runner: .nativeTool(.deacon), argv: ["index", "build", F.inGenome, "-o", "{work}/genome.idx"])]),
        .init("deacon-filter-missing-index", tool: "deacon", runner: .nativeTool(.deacon),
              argv: ["filter", "-d", "{in}/missing.idx", F.inR1], inputs: [F.r1], compareStderr: true),
        .init("ribodetector-paired", tool: "ribodetector", runner: .nativeTool(.ribodetector),
              argv: ["-t", "1", "-l", "150", "-i", F.inR1, F.inR2, "-e", "rrna",
                     "-o", "{work}/nonrrna_1.fq", "{work}/nonrrna_2.fq"],
              inputs: [F.r1, F.r2],
              outputs: [.file("{work}/nonrrna_1.fq", name: "nonrrna_1.fq"),
                        .file("{work}/nonrrna_2.fq", name: "nonrrna_2.fq")]),
        // A missing input file reaches ribodetector's logger, which stamps each
        // line with the wall-clock time. The argument error stops before it.
        .init("ribodetector-missing-output-argument", tool: "ribodetector", runner: .nativeTool(.ribodetector),
              argv: ["-t", "1", "-l", "150", "-i", F.inR1, "-e", "rrna"], inputs: [F.r1],
              compareStderr: true),
    ]

    // MARK: BBTools

    /// Every BBTools case passes -Xmx1g so the wrapper never sizes the JVM
    /// from the free memory of the moment, which it prints on stderr.
    static let bbtoolsCases: [ToolGoldenCase] = [
        .init("bbtools-reformat-stdout", tool: "BBTools reformat.sh", runner: .nativeTool(.reformat),
              argv: ["-Xmx1g", "in=\(F.inR1)", "out=stdout.fq"], inputs: [F.r1]),
        .init("bbtools-bbduk-ktrim", tool: "BBTools bbduk.sh", runner: .nativeTool(.bbduk),
              argv: ["-Xmx1g", "in=\(F.inR1)", "out={work}/bbduk.fq", "literal=AGATCGGAAGAGC",
                     "k=13", "ktrim=r", "mink=11", "t=1"],
              inputs: [F.r1], outputs: [.file("{work}/bbduk.fq", name: "bbduk.fq")]),
        .init("bbtools-bbmerge", tool: "BBTools bbmerge.sh", runner: .nativeTool(.bbmerge),
              argv: ["-Xmx1g", "in1=\(F.inR1)", "in2=\(F.inR2)", "out={work}/merged.fq",
                     "outu1={work}/unmerged_1.fq", "outu2={work}/unmerged_2.fq", "t=1"],
              inputs: [F.r1, F.r2],
              outputs: [.file("{work}/merged.fq", name: "merged.fq"),
                        .file("{work}/unmerged_1.fq", name: "unmerged_1.fq"),
                        .file("{work}/unmerged_2.fq", name: "unmerged_2.fq")]),
        .init("bbtools-reformat-missing-input", tool: "BBTools reformat.sh", runner: .nativeTool(.reformat),
              argv: ["-Xmx1g", "in={in}/missing.fq", "out=stdout.fq"], compareStderr: true),
    ]

    // MARK: Variant callers and primer trimming

    static let variantCases: [ToolGoldenCase] = [
        .init("lofreq-call", tool: "lofreq", runner: .nativeTool(.lofreq),
              argv: ["call", "-f", F.inGenome, "-o", "{work}/lofreq.vcf", F.inBAM],
              inputs: [F.genome, F.genomeFai, F.bam, F.bai],
              outputs: [.file("{work}/lofreq.vcf", name: "lofreq.vcf")], masks: [.lofreqFileDate]),
        // --no-default-filter keeps LoFreq's low-quality calls, so the VCF holds records.
        .init("lofreq-call-records", tool: "lofreq", runner: .nativeTool(.lofreq),
              argv: ["call", "--no-default-filter", "-f", F.inGenome, "-o", "{work}/lofreq.vcf", F.inBAM],
              inputs: [F.genome, F.genomeFai, F.bam, F.bai],
              outputs: [.file("{work}/lofreq.vcf", name: "lofreq.vcf")], masks: [.lofreqFileDate]),
        // The sequence ViralVariantCallingPipeline runs for `--call-indels`: indelqual, index, call.
        .init("lofreq-indelqual-index-call", tool: "lofreq", runner: .nativeTool(.lofreq),
              argv: ["call", "--call-indels", "-f", F.inGenome, "-o", "{work}/lofreq.vcf",
                     "{work}/lofreq.indelqual.bam"],
              inputs: [F.genome, F.genomeFai, F.bam, F.bai],
              setup: [
                  .init(runner: .nativeTool(.lofreq),
                        argv: ["indelqual", "--dindel", "-f", F.inGenome,
                               "-o", "{work}/lofreq.indelqual.bam", F.inBAM],
                        label: "indelqual"),
                  .init(runner: .nativeTool(.lofreq),
                        argv: ["index", "{work}/lofreq.indelqual.bam"], label: "index"),
              ],
              outputs: [.bam("{work}/lofreq.indelqual.bam", name: "lofreq.indelqual.bam"),
                        .file("{work}/lofreq.indelqual.bam.bai", name: "lofreq.indelqual.bam.bai"),
                        .file("{work}/lofreq.vcf", name: "lofreq.vcf")],
              masks: [.lofreqFileDate]),
        .init("lofreq-call-missing-input", tool: "lofreq", runner: .nativeTool(.lofreq),
              argv: ["call", "-f", F.inGenome, "-o", "{work}/lofreq.vcf", "{in}/missing.bam"],
              inputs: [F.genome, F.genomeFai], compareStderr: true),
        .init("ivar-trim", tool: "ivar", runner: .nativeTool(.ivar),
              argv: ["trim", "-i", F.inBAM, "-b", "{in}/test.bed", "-p", "{work}/trimmed", "-e"],
              inputs: [F.bam, F.bai, F.bed], outputs: [.bam("{work}/trimmed.bam", name: "trimmed.bam")]),
        .init("ivar-trim-missing-input", tool: "ivar", runner: .nativeTool(.ivar),
              argv: ["trim", "-i", "{in}/missing.bam", "-b", "{in}/test.bed", "-p", "{work}/trimmed"],
              inputs: [F.bed], compareStderr: true),
    ]

    // MARK: BLAST, UCSC

    static let otherNativeCases: [ToolGoldenCase] = [
        .init("blastn-subject", tool: "blastn", runner: .nativeTool(.blastn),
              argv: ["-query", "{in}/query.fasta", "-subject", F.inGenome, "-outfmt", "6"],
              inputs: [F.genome], generated: [F.blastQuery]),
        .init("blastn-missing-query", tool: "blastn", runner: .nativeTool(.blastn),
              argv: ["-query", "{in}/missing.fasta", "-subject", F.inGenome, "-outfmt", "6"],
              inputs: [F.genome], compareStderr: true),
        .init("bedgraphtobigwig-convert", tool: "bedGraphToBigWig", runner: .nativeTool(.bedGraphToBigWig),
              argv: ["{in}/coverage.bedGraph", "{in}/chrom.sizes", "{work}/coverage.bw"],
              generated: [F.bedGraph, F.chromSizes],
              outputs: [.file("{work}/coverage.bw", name: "coverage.bw")]),
        .init("bedgraphtobigwig-usage-error", tool: "bedGraphToBigWig", runner: .nativeTool(.bedGraphToBigWig),
              argv: [], compareStderr: true),
    ]

    // MARK: Heavy tools behind NativeToolRunner

    static let heavyNativeCases: [ToolGoldenCase] = [
        .init("medaka-version", tool: "medaka", runner: .nativeTool(.medaka), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("medaka-invalid-subcommand", tool: "medaka", runner: .nativeTool(.medaka), tier: .heavy,
              argv: ["consensus", "{in}/missing.bam"], compareStderr: true),
        .init("medaka-variant-no-arguments", tool: "medaka_variant", runner: .nativeTool(.medakaVariant),
              tier: .heavy, argv: [], compareStderr: true),
        .init("clair3-version", tool: "clair3", runner: .nativeTool(.clair3), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("clair3-missing-input", tool: "clair3", runner: .nativeTool(.clair3), tier: .heavy,
              argv: ["--bam_fn={in}/missing.bam", "--ref_fn={in}/genome.fasta", "--threads=1",
                     "--platform=ont", "--model_path={in}/no-model", "--output={work}/clair3"],
              inputs: [F.genome, F.genomeFai], compareStderr: true),
        .init("fasterq-dump-version", tool: "fasterq-dump", runner: .nativeTool(.fasterqDump), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("fasterq-dump-unknown-option", tool: "fasterq-dump", runner: .nativeTool(.fasterqDump), tier: .heavy,
              argv: ["--no-such-option"], compareStderr: true, masks: [.sraLogTimestamp]),
        .init("prefetch-version", tool: "prefetch", runner: .nativeTool(.prefetch), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("prefetch-unknown-option", tool: "prefetch", runner: .nativeTool(.prefetch), tier: .heavy,
              argv: ["--no-such-option"], compareStderr: true, masks: [.sraLogTimestamp]),
        // Not installed on the capture Mac: these skip through ToolAvailability.
        .init("whatshap-version", tool: "whatshap", runner: .nativeTool(.whatshap), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("freyja-version", tool: "freyja", runner: .nativeTool(.freyja), tier: .heavy,
              argv: ["--version"], compareStderr: true),
    ]

    // MARK: runProcess

    static let nativeProcessCases: [ToolGoldenCase] = [
        .init("samtools-runprocess-view-count", tool: "samtools",
              runner: .nativeProcess(environment: "samtools", executable: "samtools"),
              argv: ["view", "-c", F.inBAM], inputs: [F.bam, F.bai]),
        .init("samtools-runprocess-missing-input", tool: "samtools",
              runner: .nativeProcess(environment: "samtools", executable: "samtools"),
              argv: ["view", "-c", "{in}/missing.bam"], compareStderr: true),
        // Primer design tools, not installed on the capture Mac.
        .init("primer3-about", tool: "primer3",
              runner: .nativeProcess(environment: "primer3", executable: "primer3_core"), tier: .heavy,
              argv: ["--about"], compareStderr: true),
        .init("primalscheme3-version", tool: "primalscheme3",
              runner: .nativeProcess(environment: "primalscheme3", executable: "primalscheme3"), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("olivar-version", tool: "olivar",
              runner: .nativeProcess(environment: "olivar", executable: "olivar"), tier: .heavy,
              argv: ["--version"], compareStderr: true),
        .init("varvamp-version", tool: "varvamp",
              runner: .nativeProcess(environment: "varvamp", executable: "varvamp"), tier: .heavy,
              argv: ["--version"], compareStderr: true),
    ]

    // MARK: runWithFileOutput

    static let fileOutputCases: [ToolGoldenCase] = [
        .init("bgzip-compress-to-file", tool: "bgzip",
              runner: .nativeFileOutput(.bgzip, outputFile: "{work}/test.vcf.gz"),
              argv: ["-c", "{in}/test.vcf"], inputs: [F.vcf],
              outputs: [.file("{work}/test.vcf.gz", name: "test.vcf.gz")]),
        .init("pigz-compress-to-file", tool: "pigz",
              runner: .nativeFileOutput(.pigz, outputFile: "{work}/reads.fastq.gz"),
              argv: ["-c", "-p", "2", "{in}/unmerged_R1.fastq"], inputs: [F.plainFastq],
              outputs: [.file("{work}/reads.fastq.gz", name: "reads.fastq.gz")]),
        .init("pigz-missing-input-to-file", tool: "pigz",
              runner: .nativeFileOutput(.pigz, outputFile: "{work}/reads.fastq.gz"),
              argv: ["-c", "-p", "2", "{in}/missing.fastq"],
              outputs: [.absent("{work}/reads.fastq.gz", name: "reads.fastq.gz")], compareStderr: true),
        .init("samtools-fastq-to-file", tool: "samtools",
              runner: .nativeFileOutput(.samtools, outputFile: "{work}/reads.fastq"),
              argv: ["fastq", "-n", F.inBAM], inputs: [F.bam, F.bai],
              outputs: [.file("{work}/reads.fastq", name: "reads.fastq")]),
    ]

    // MARK: runPipeline

    static let pipelineCases: [ToolGoldenCase] = [
        .init("pipeline-samtools-mpileup-ivar-variants", tool: "samtools | ivar",
              runner: .pipeline([.samtools, .ivar]),
              stages: [
                  ["mpileup", "-aa", "-A", "-d", "0", "-B", "-Q", "0", "--reference", F.inGenome, F.inBAM],
                  ["variants", "-p", "{work}/ivar", "-r", F.inGenome, "-t", "0.03"],
              ],
              inputs: [F.genome, F.genomeFai, F.bam, F.bai],
              outputs: [.file("{work}/ivar.tsv", name: "ivar.tsv")]),
        // A truncated BAM: samtools mpileup fails while ivar still runs on the partial stream.
        .init("pipeline-mpileup-ivar-truncated-bam", tool: "samtools | ivar",
              runner: .pipeline([.samtools, .ivar]),
              stages: [
                  ["mpileup", "-aa", "-A", "-d", "0", "-B", "-Q", "0", "--reference", F.inGenome,
                   "{in}/truncated.bam"],
                  ["variants", "-p", "{work}/ivar", "-r", F.inGenome, "-t", "0.03"],
              ],
              inputs: [F.genome, F.genomeFai], generated: [F.truncatedBAM],
              outputs: [.file("{work}/ivar.tsv", name: "ivar.tsv")], compareStderr: true),
        .init("pipeline-bcftools-mpileup-call", tool: "bcftools | bcftools",
              runner: .pipeline([.bcftools, .bcftools]),
              stages: [
                  ["mpileup", "--no-version", "-f", F.inGenome, "-Ou", F.inBAM],
                  ["call", "--no-version", "-mv"],
              ],
              inputs: [F.genome, F.genomeFai, F.bam, F.bai]),
        .init("pipeline-samtools-missing-input", tool: "samtools | samtools",
              runner: .pipeline([.samtools, .samtools]),
              stages: [["view", "-h", "{in}/missing.bam"], ["view", "-c", "-"]],
              compareStderr: true),
    ]
}
