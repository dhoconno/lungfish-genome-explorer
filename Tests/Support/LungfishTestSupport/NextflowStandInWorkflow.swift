// NextflowStandInWorkflow.swift - One workflow's part of the shared stand-in Nextflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q9 M1, decision N11 (docs/plans/2026-10-12-phase-2-9.md). `NextflowStandInEngine`
// records each launch and prints the engine's own lines. A workflow brings what only it knows:
// its fixtures, the outputs it writes for each sample, the names of its tasks and the lines its
// own code prints. `.taxTriage` is the first, and Q9 M2 adds Viral Recon's.
//
// The task names of `.taxTriage` are the 46 tasks of Q15's real run R1 (Nextflow 26.04.6 with
// TaxTriage v3.3.8 at e10bfebda32a, two samples): 3 run-level tasks first, 17 for each sample and
// 9 run-level tasks last, so one sample gives the 29 tasks of R2.

import Foundation

/// One workflow's fixtures, output tree, process names and banner, `.taxTriage` in M1 and Viral
/// Recon's in Q9 M2.
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
    /// The process of each task one sample runs in the plain-log mode, in order, with `@SAMPLE@`
    /// where the task's tag names the sample.
    public let processNames: [String]
    /// The run-level tasks the plain-log mode runs before the samples' own tasks.
    public let leadingProcessNames: [String]
    /// The run-level tasks the plain-log mode runs after the samples' own tasks.
    public let trailingProcessNames: [String]
    /// The entry of `processNames` where a sample of `.failsSamples` fails. A failing run stops
    /// every sample there.
    public let failingProcessName: String
    /// The entry of `processNames` that `.reportsErroredTasks` fails with 137 and ignores.
    public let ignoredFailureProcessName: String
    public let fixtures: [Fixture]
    /// The one task each sample runs in the progress-lines mode, the task that mode fails and
    /// ignores, and the repository its `Launching` line names. They keep the 2.8 lines.
    let progressLinesProcessName: String
    let progressLinesIgnoredProcessName: String
    let progressLinesRepository: String
    /// Shell functions the engine calls. `workflow_banner` prints the lines the workflow's own
    /// code prints before `[PIPELINE]` in the plain-log mode, `workflow_prepare_outputs` makes the
    /// output tree, and `workflow_sample_outputs <sample>` writes one sample's outputs. They may
    /// read `$fixtures`, `$outdir`, `$target`, `$revision` and `$engine_version`.
    let shellFunctions: String

    /// The number of tasks a plain-log launch of `sampleCount` samples runs when none fails.
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
      # to 69 of R1's stdout. The version is the stand-in's, never the lock's.
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
      printf 'Date: %s\n' "$(LC_ALL=C date '+%a %b %d %H:%M:%S %Z %Y')"
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
