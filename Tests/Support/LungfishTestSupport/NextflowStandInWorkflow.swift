// NextflowStandInWorkflow.swift - One workflow's part of the shared stand-in Nextflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q9 M1, decision N11 (docs/plans/2026-10-12-phase-2-9.md). `NextflowStandInEngine`
// records each launch and prints the engine's own lines. A workflow brings what only it knows:
// its fixtures, the outputs it writes for each sample, the names of its tasks and the lines its
// own code prints. `.taxTriage` is the first, and Phase 2.10 lane Q33 adds `.viralRecon`.
//
// The task names of `.taxTriage` are the 46 tasks of Q15's real run R1 (Nextflow 26.04.6 with
// TaxTriage v3.3.8 at e10bfebda32a, two samples): 3 run-level tasks first, 17 for each sample and
// 9 run-level tasks last, so one sample gives the 29 tasks of R2.
//
// `.viralRecon` comes from the files of the release the lock pins, nf-core/viralrecon 3.0.0 (tag
// 3.0.0 of github.com/nf-core/viralrecon), since no real run of that release was on record when Q33
// wrote it. Its task names follow the calls of `workflows/viralrecon.nf` and the subworkflows it
// includes, its output paths the `publishDir` folders of `conf/modules_illumina.config`, and its
// banner is the logo `subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf` prints
// (`before_text`). The output bytes are the nf-core/test-datasets files of Tests/Fixtures/sarscov2.
// Q35's V1 then ran that release for real (Phase 2.10, Nextflow 26.04.6, two samples that have no iVar
// variant) and showed `CAT_FASTQ (<sample>)` as the first task of each sample, which the list had missed.
// V1b, a sample that has variants, then showed that `NEXTCLADE_RUN` never starts with the app's argv, which
// gives no Nextclade dataset, and confirmed the other nine tasks that follow `IVAR_VARIANTS`.
// V1 and V1b are also the source of the console `.viralRecon` prints by default, `OutputMode.consoleLog26`,
// and of the commit its `Launching` line names for tag 3.0.0, 395079f1d2. `.taxTriage` keeps the agent log
// of R1.

import Foundation

/// One workflow's fixtures, output tree, process names and banner, `.taxTriage` and `.viralRecon`.
public struct NextflowStandInWorkflow: Sendable {
    /// A file the outputs are made from, copied into `<root>/fixtures/<name>` when the engine is
    /// written and read there at each launch.
    public struct Fixture: Sendable, Equatable {
        public let name: String
        public let source: URL

        public init(name: String, source: URL) {
            self.name = name
            self.source = source
        }
    }

    /// The pipeline's manifest name, which `[PIPELINE]` and nf-core's completion line print.
    public let name: String
    /// The manifest version `[PIPELINE]` prints.
    public let version: String
    /// The first ten characters of the commit the release's tag names, which the console's
    /// `Launching` line prints beside the revision.
    public let pinnedCommit: String
    /// The process of each task one sample runs in the 26.04 modes, in order, with `@SAMPLE@`
    /// where the task's tag names the sample.
    public let processNames: [String]
    /// The run-level tasks the 26.04 modes run before the samples' own tasks.
    public let leadingProcessNames: [String]
    /// The run-level tasks the 26.04 modes run after the samples' own tasks.
    public let trailingProcessNames: [String]
    /// The entry of `processNames` where a sample of `.failsSamples` fails. A failing run stops
    /// every sample there.
    public let failingProcessName: String
    /// The entry of `processNames` that `.reportsErroredTasks` fails with 137 and ignores.
    public let ignoredFailureProcessName: String
    public let fixtures: [Fixture]
    /// The output mode an engine of this workflow prints when its caller names none.
    public let defaultOutputMode: NextflowStandInEngine.OutputMode
    /// The one task each sample runs in the progress-lines mode, the task that mode fails and
    /// ignores, and the repository its `Launching` line names. They keep the 2.8 lines.
    let progressLinesProcessName: String
    let progressLinesIgnoredProcessName: String
    let progressLinesRepository: String
    /// Shell functions the engine calls. `workflow_banner` prints the lines the workflow's own
    /// code prints before `[PIPELINE]` in the plain-log mode and before the first task in the
    /// console mode, `workflow_prepare_outputs` makes the output tree, and
    /// `workflow_sample_outputs <sample>` writes one sample's outputs. They may read `$fixtures`,
    /// `$outdir`, `$target`, `$revision` and `$engine_version`.
    let shellFunctions: String

    /// The number of tasks a launch of `sampleCount` samples runs in a 26.04 mode when none fails.
    public func taskCount(sampleCount: Int) -> Int {
        leadingProcessNames.count + sampleCount * processNames.count + trailingProcessNames.count
    }
}

extension NextflowStandInWorkflow {
    /// TaxTriage. `report/<sample>.odr.txt` is the TaxTriage 3.3.8 organism discovery report of
    /// Tests/Fixtures/taxtriage-odr-3.3.8 with its Specimen ID set to the sample,
    /// `combine/<sample>.combined.gcfmap.tsv` its accession map, and `top/<sample>.top_report.tsv`
    /// the Kraken top report of Tests/Fixtures/taxtriage-mini. It writes no BAM, so
    /// `build-db taxtriage` skips its samtools pass. The report is made from
    /// `<root>/fixtures/odr.txt` at each launch, so a test that cuts that file to its header gets
    /// reports with no organisms.
    public static let taxTriage: NextflowStandInWorkflow = {
        let fixtures = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
        let odr = "taxtriage-odr-3.3.8/SRR12486983"
        let prefix = "NFCORE_TAXTRIAGE:TAXTRIAGE:"
        return NextflowStandInWorkflow(
            name: "nf-core/taxtriage",
            version: "1.0dev",
            pinnedCommit: "e10bfebda3",
            processNames: [
                "PIGZ_COMPRESS (@SAMPLE@)",
                "COUNT_READS (@SAMPLE@)",
                "FASTP (@SAMPLE@)",
                "FASTQC (@SAMPLE@)",
                "CLASSIFIER:KRAKEN2_KRAKEN2 (@SAMPLE@)",
                "CLASSIFIER:REMOVETAXIDSCLASSIFICATION (@SAMPLE@)",
                "CLASSIFIER:KREPORT_TO_KRONATXT (@SAMPLE@)",
                "CLASSIFIER:TOP_HITS (@SAMPLE@)",
                "REFERENCE_PREP:DOWNLOAD_ASSEMBLY (@SAMPLE@)",
                "REFERENCE_PREP:COMBINE_MAPFILES (@SAMPLE@)",
                "REFERENCE_PREP:MAP_TAXID_ASSEMBLY (@SAMPLE@)",
                "ALIGNMENT:MINIMAP2_ALIGN (@SAMPLE@.@SAMPLE@.dwnld.references)",
                "ALIGNMENT:SAMTOOLS_INDEX (@SAMPLE@)",
                "ALIGNMENT:SAMTOOLS_HIST_COVERAGE (@SAMPLE@)",
                "ALIGNMENT:SAMTOOLS_COVERAGE (@SAMPLE@)",
                "REPORT:ALIGNMENT_PER_SAMPLE (@SAMPLE@)",
                "REPORT:SINGLE_REPORT (@SAMPLE@)",
            ].map { prefix + $0 },
            leadingProcessNames: [
                "DOWNLOAD_TAXDUMP",
                "INPUT_CHECK:SAMPLESHEET_CHECK (samplesheet.csv)",
                "GET_ASSEMBLIES",
            ].map { prefix + $0 },
            trailingProcessNames: [
                "CLASSIFIER:KRONA_KTIMPORTTEXT (combined_krona_kreports)",
                "CLASSIFIER:MERGEDSUBSPECIES (MergeTopSpeciesAllSamples)",
                "CLASSIFIER:MERGEDKRAKENREPORT (MergeKrakenReportsAllSamples)",
                "CLASSIFIER:FILTERKRAKEN",
                "CUSTOM_DUMPSOFTWAREVERSIONS (1)",
                "REPORT:COMBINE_SAMPLES_JSON (all_samples_combined)",
                "REPORT:ORGANISM_MERGE_REPORT (all)",
                "MULTIQC",
                "REPORT:CREATE_COMPARISON_REPORT (comparison_full_report)",
            ].map { prefix + $0 },
            failingProcessName: prefix + "CLASSIFIER:KRAKEN2_KRAKEN2 (@SAMPLE@)",
            ignoredFailureProcessName: prefix + "ALIGNMENT:MINIMAP2_ALIGN (@SAMPLE@.@SAMPLE@.dwnld.references)",
            fixtures: [
                Fixture(name: "odr.txt", source: fixtures.appendingPathComponent("\(odr)/report/SRR12486983.odr.txt")),
                Fixture(name: "gcfmap.tsv", source: fixtures.appendingPathComponent("\(odr)/combine/SRR12486983.combined.gcfmap.tsv")),
                Fixture(name: "top_report.tsv", source: fixtures.appendingPathComponent("taxtriage-mini/top/SRR35517702.top_report.tsv")),
            ],
            defaultOutputMode: .plainLog26,
            progressLinesProcessName: prefix + "KRAKEN2_KRAKEN2",
            progressLinesIgnoredProcessName: prefix + "ALIGNMENT:MINIMAP2_ALIGN",
            progressLinesRepository: "jhuapl-bio/taxtriage",
            shellFunctions: NextflowStandInWorkflow.taxTriageShellFunctions
        )
    }()

    private static let taxTriageShellFunctions = #"""
    # TaxTriage's part of the stand-in Nextflow (NextflowStandInWorkflow.taxTriage).
    workflow_banner() {
      # The four lines TaxTriage's own code prints before Nextflow's [PIPELINE] line, as in lines 66
      # to 69 of R1's stdout. The version is the stand-in's, never the lock's, and the date is R1's.
      printf 'Nextflow version: %s\n' "$engine_version"
      case "$target" in
        ''|/*)
          echo "Commit ID: local"
          echo "Repository URL: local"
          ;;
        *)
          printf 'Commit ID: %s\n' "${revision:-local}"
          printf 'Repository URL: https://github.com/%s\n' "$target"
          ;;
      esac
      echo "Date: Mon Oct 12 09:19:02 CDT 2026"
    }
    workflow_prepare_outputs() {
      mkdir -p "$outdir/report" "$outdir/combine" "$outdir/top"
    }
    workflow_sample_outputs() {
      awk -F '\t' -v OFS='\t' -v sample="$1" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "Specimen ID") column = i; print; next }
        { if (column) $column = sample; print }
      ' "$fixtures/odr.txt" > "$outdir/report/$1.odr.txt"
      cp "$fixtures/gcfmap.tsv" "$outdir/combine/$1.combined.gcfmap.tsv"
      cp "$fixtures/top_report.tsv" "$outdir/top/$1.top_report.tsv"
    }
    """#
}

extension NextflowStandInWorkflow {
    /// nf-core/viralrecon 3.0.0, the release the lock pins, on an Illumina amplicon run with the
    /// options a new run in the app starts with (iVar variants, a BCFtools consensus, no assembly,
    /// no Kraken 2 and no Freyja). Each sample runs 29 tasks of its reads, alignment, primer
    /// trimming, coverage, variants and consensus in the order `workflows/viralrecon.nf` calls
    /// them (a real run submits them in parallel), and the run ends with MultiQC. A sample with
    /// no iVar variant stops after `IVAR_VARIANTS` (Q35's V1), and `NEXTCLADE_RUN` never starts,
    /// since the app's argv gives no Nextclade dataset (Q35's V1b). That is a subset of what such a
    /// run starts. Genome preparation is left out, because its task tags name
    /// the genome's own files, and so are `VARIANTS_QC` (SnpEff), the low-coverage mask of the
    /// consensus (`MAKE_BED_MASK`, `BEDTOOLS_MERGE`, `BEDTOOLS_MASKFASTA`), `PLOT_BASE_DENSITY`,
    /// `QUAST`, `PANGOLIN_UPDATEDATA`, the Mosdepth plots and `VARIANTS_LONG_TABLE`. Each sample
    /// writes the files LGE reads back
    /// (`ViralReconResultInventory`): `variants/bowtie2/<sample>.sorted.bam` and
    /// `<sample>.ivar_trim.sorted.bam` with their indexes, `variants/ivar/<sample>.vcf.gz` with its
    /// index, and `variants/ivar/consensus/bcftools/<sample>.consensus.fa`, whose header the
    /// pipeline's RENAME_FASTA_HEADER prefixes with the sample. A sample of `.failsSamples` fails
    /// at its Bowtie 2 alignment. The pinned modules carry no `error_ignore` label, so no task of
    /// the real release ignores a failure, and `.reportsErroredTasks` fails Pangolin only so that
    /// the behaviour has a task to report.
    public static let viralRecon: NextflowStandInWorkflow = {
        let sarscov2 = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        let prefix = "NFCORE_VIRALRECON:VIRALRECON:"
        let samtools = ["SAMTOOLS_SORT", "SAMTOOLS_INDEX"].map { "BAM_SORT_STATS_SAMTOOLS:\($0) (@SAMPLE@)" }
            + ["SAMTOOLS_STATS", "SAMTOOLS_FLAGSTAT", "SAMTOOLS_IDXSTATS"].map { "BAM_SORT_STATS_SAMTOOLS:BAM_STATS_SAMTOOLS:\($0) (@SAMPLE@)" }
        let sampleTasks = [
            "CAT_FASTQ (@SAMPLE@)",
            "FASTQ_TRIM_FASTP_FASTQC:FASTQC_RAW (@SAMPLE@)",
            "FASTQ_TRIM_FASTP_FASTQC:FASTP (@SAMPLE@)",
            "FASTQ_TRIM_FASTP_FASTQC:FASTQC_TRIM (@SAMPLE@)",
            "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (@SAMPLE@)",
        ] + samtools.map { "FASTQ_ALIGN_BOWTIE2:" + $0 } + [
            "BAM_TRIM_PRIMERS_IVAR:IVAR_TRIM (@SAMPLE@)",
        ] + samtools.map { "BAM_TRIM_PRIMERS_IVAR:" + $0 } + [
            "PICARD_COLLECTMULTIPLEMETRICS (@SAMPLE@)",
            "MOSDEPTH_GENOME (@SAMPLE@)",
            "MOSDEPTH_AMPLICON (@SAMPLE@)",
            "VARIANTS_IVAR:IVAR_VARIANTS (@SAMPLE@)",
            "VARIANTS_IVAR:IVAR_VARIANTS_TO_VCF (@SAMPLE@)",
            "VARIANTS_IVAR:BCFTOOLS_SORT (@SAMPLE@)",
            "VARIANTS_IVAR:VCF_TABIX_STATS:TABIX_TABIX (@SAMPLE@)",
            "VARIANTS_IVAR:VCF_TABIX_STATS:BCFTOOLS_STATS (@SAMPLE@)",
            "CONSENSUS_BCFTOOLS:BCFTOOLS_FILTER (@SAMPLE@)",
            "CONSENSUS_BCFTOOLS:TABIX_TABIX (@SAMPLE@)",
            "CONSENSUS_BCFTOOLS:BCFTOOLS_CONSENSUS (@SAMPLE@)",
            "CONSENSUS_BCFTOOLS:RENAME_FASTA_HEADER (@SAMPLE@)",
            "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (@SAMPLE@)",
        ]
        return NextflowStandInWorkflow(
            name: "nf-core/viralrecon",
            version: "3.0.0",
            pinnedCommit: "395079f1d2",
            processNames: sampleTasks.map { prefix + $0 },
            leadingProcessNames: [],
            trailingProcessNames: [prefix + "MULTIQC"],
            failingProcessName: prefix + "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (@SAMPLE@)",
            ignoredFailureProcessName: prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (@SAMPLE@)",
            fixtures: [
                Fixture(name: "sorted.bam", source: sarscov2.appendingPathComponent("test.paired_end.sorted.bam")),
                Fixture(name: "sorted.bam.bai", source: sarscov2.appendingPathComponent("test.paired_end.sorted.bam.bai")),
                Fixture(name: "variants.vcf.gz", source: sarscov2.appendingPathComponent("test.vcf.gz")),
                Fixture(name: "variants.vcf.gz.tbi", source: sarscov2.appendingPathComponent("test.vcf.gz.tbi")),
                Fixture(name: "genome.fasta", source: sarscov2.appendingPathComponent("genome.fasta")),
            ],
            defaultOutputMode: .consoleLog26,
            progressLinesProcessName: prefix + "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN",
            progressLinesIgnoredProcessName: prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN",
            progressLinesRepository: "nf-core/viralrecon",
            shellFunctions: NextflowStandInWorkflow.viralReconShellFunctions
        )
    }()

    private static let viralReconShellFunctions = #"""
    # Viral Recon's part of the stand-in Nextflow (NextflowStandInWorkflow.viralRecon).
    workflow_banner() {
      # The logo Viral Recon 3.0.0 prints before its parameter summary (before_text of
      # subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf), with the manifest's name and
      # version. The summary itself is left out, as the TaxTriage stand-in leaves out R1's.
      echo ""
      printf '%s\n' "-${esc}[2m----------------------------------------------------${esc}[0m-"
      printf '%s\n' "                                        ${esc}[0;32m,--.${esc}[0;30m/${esc}[0;32m,-.${esc}[0m"
      printf '%s\n' "${esc}[0;34m        ___     __   __   __   ___     ${esc}[0;32m/,-._.--~'${esc}[0m"
      printf '%s\n' "${esc}[0;34m  |\\ | |__  __ /  \` /  \\ |__) |__         ${esc}[0;33m}  {${esc}[0m"
      printf '%s\n' "${esc}[0;34m  | \\| |       \\__, \\__/ |  \\ |___     ${esc}[0;32m\\\`-._,-\`-,${esc}[0m"
      printf '%s\n' "                                        ${esc}[0;32m\`._,._,'${esc}[0m"
      printf '%s\n' "${esc}[0;35m  $workflow_name $workflow_version${esc}[0m"
      printf '%s\n' "-${esc}[2m----------------------------------------------------${esc}[0m-"
    }
    workflow_prepare_outputs() {
      mkdir -p "$outdir/variants/bowtie2" "$outdir/variants/ivar/consensus/bcftools"
    }
    workflow_sample_outputs() {
      for kind in sorted ivar_trim.sorted; do
        cp "$fixtures/sorted.bam" "$outdir/variants/bowtie2/$1.$kind.bam"
        cp "$fixtures/sorted.bam.bai" "$outdir/variants/bowtie2/$1.$kind.bam.bai"
      done
      cp "$fixtures/variants.vcf.gz" "$outdir/variants/ivar/$1.vcf.gz"
      cp "$fixtures/variants.vcf.gz.tbi" "$outdir/variants/ivar/$1.vcf.gz.tbi"
      # RENAME_FASTA_HEADER runs sed "s/>/>${meta.id} /g" on the consensus.
      awk -v sample="$1" '{ gsub(/>/, ">" sample " "); print }' "$fixtures/genome.fasta" \
        > "$outdir/variants/ivar/consensus/bcftools/$1.consensus.fa"
    }
    """#
}
