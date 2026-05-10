---
title: Running NAO-MGS
chapter_id: 06-classification/05-running-nao-mgs
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 9
task: Run NAO-MGS against wastewater metagenomics samples and read the surveillance result view.
tags: [classification, nao-mgs, wastewater, surveillance]
tools: [nao-mgs]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Classification > NAO-MGS"
  - "CLI: lungfish nao-mgs import, lungfish nao-mgs summary"
shots: []
planned_shots:
  - id: nao-mgs-wizard-page-1
    caption: "The NAO-MGS Classification wizard with database picker and sample-date field."
  - id: nao-mgs-import-dialog
    caption: "The Import NAO-MGS Results dialog accepting an existing run directory."
  - id: nao-mgs-result-viewport
    caption: "The longitudinal surveillance viewport with per-pathogen abundance over twelve weeks."
illustrations: []
glossary_refs: [NAO-MGS, sample date, surveillance series]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

NAO-MGS is a metagenomic surveillance pipeline tuned for wastewater pathogen monitoring. It classifies reads against a surveillance-targeted database, produces per-pathogen abundance estimates, and reports those estimates in a way that aligns with the Nucleic Acid Observatory's published surveillance outputs. Lungfish runs NAO-MGS through the Classification wizard for fresh data, or imports existing NAO-MGS output through `lungfish nao-mgs import` when a colleague has already produced results outside Lungfish.

The classifier itself works on one sample at a time. The thing that makes NAO-MGS distinct from Kraken2, EsViritu, or TaxTriage is what happens after classification: results from many samples are bound together along a time axis, and the result viewport draws each pathogen's relative abundance as a line over weeks or months. That line is the surveillance signal. A spike on it is a candidate event worth investigating.

NAO-MGS is the right tool when the workflow is longitudinal. Same wastewater site, sampled repeatedly, with the question being how the pathogen mix is changing over time. It is the wrong tool for single-sample diagnostics. If you have one swab from one patient and want to know what is in it, run Kraken2 or EsViritu instead.

So what should you do with this? If you are running a wastewater surveillance program, set up an NAO-MGS series in your project before you classify your first sample, and then add each new week's reads to the same series so the time axis builds correctly.

## What you will learn

By the end of this chapter you will be able to install the NAO-MGS database, run the Classification wizard with NAO-MGS selected, attach a sample date so the result enters the time series at the right point, import existing NAO-MGS results from a previous external run, and read the longitudinal surveillance charts the result viewport draws.

## How NAO-MGS compares to the other classifiers

Lungfish ships four classifiers, and the choice between them is mostly a question of what you are trying to answer. The table below is the short version. Chapters 02, 03, and 04 cover the others in detail.

| Classifier | Best for | Database | RAM to plan | Output unit | Time-series aware |
|---|---|---|---|---|---|
| Kraken2 | Broad survey of one sample | k-mer index, 8 to 64 GB | Database-sized; Viral fits in 16 GB, Standard/PlusPF need more | Per-taxon read count | No |
| EsViritu | Viral content of one sample | Curated viral genomes, ~5 GB installed | 8 GB for default viral runs | Per-virus coverage | No |
| TaxTriage | Clinical triage of one sample | Pathogen-focused | 16 to 32 GB for the default clinical profile | Ranked candidate hits | No |
| NAO-MGS | Wastewater surveillance over time | Surveillance-targeted | 16 to 32 GB for default wastewater runs | Per-pathogen relative abundance | Yes |

The "time-series aware" column is the load-bearing distinction. The other three classifiers do not know that today's sample is the next point in a sequence; NAO-MGS does, because Lungfish stores its outputs as a series keyed by sample date and site.

## Procedure: running NAO-MGS on a fresh sample

1. Choose **Tools > FASTQ/FASTA Operations > Classification > NAO-MGS**. The Classification wizard opens with NAO-MGS preselected.

   <!-- planned: nao-mgs-wizard-page-1 -->

2. On the first page, pick the FASTQ bundle for the sample you are classifying. Paired reads are supported. Single-end reads are supported. Mixed runs in the same series are not, so pick one read configuration when you set the series up and stay with it.

3. In the **Database** dropdown, choose your installed NAO-MGS database. If no database is listed, click **Install database** and pick the release you want from the bioconda-hosted index. The first install takes several minutes and writes to `~/.lungfish/conda/nao-mgs/`. The database row records the installed version, install date, and update status; use `lungfish conda db list` for the same inventory from the CLI. Plan for 16 to 32 GB of RAM for default wastewater runs, with larger site panels scaling upward.

4. In the **Sample date** field, enter the date the wastewater sample was collected, not the date you are running the analysis. This date is the x-axis position for the result. If you leave it blank, Lungfish uses the FASTQ file's modification date and warns you, which is almost never what you want for archived samples.

5. In the **Series** dropdown, choose an existing surveillance series to append this sample to, or click **New series** to start one. A series is identified by site name and matrix (for example, "Madison MMSD influent"). Two samples with the same series and the same date are flagged as a conflict; resolve by editing one date or merging the runs.

6. Click **Run**. Lungfish materializes the FASTQ if it is virtual (a subset, trimmed, or demultiplexed bundle has only a 1000-read preview on disk; see Chapter 05.02), runs the pipeline, and writes the per-pathogen abundance table into the series's storage area under `Imports/NAO-MGS/<series-name>/<sample-date>.parquet`.

## Procedure: importing existing NAO-MGS results

If your lab already runs NAO-MGS outside Lungfish (for example, on a shared cluster), you do not need to re-run anything. You import the existing output directory and Lungfish indexes it into a series.

1. Choose **File > Import > NAO-MGS Results**. The import dialog opens.

   <!-- planned: nao-mgs-import-dialog -->

2. Click **Choose** and navigate to the run directory. Lungfish expects the standard NAO-MGS output layout: a `samples/` subfolder with one file per sample, a `metadata.tsv` listing each sample's collection date and site, and a `manifest.json` listing the database version that produced the results. Missing fields are reported in red and the import is blocked until they are filled in.

3. In the **Series mapping** section, decide whether each distinct site in `metadata.tsv` becomes its own series, or whether sites are merged. The default is one series per site. For a single-site, multi-week run, leave the default.

4. Click **Import**. Lungfish copies (or, if you tick **Reference in place**, symlinks) the result files into the project, validates that every sample in `metadata.tsv` has a corresponding result, and writes a provenance record naming the importing user, the source directory, and the database version reported in `manifest.json`.

5. The same import is available from the command line as `lungfish nao-mgs import --run-dir <path> --project <path>`. The CLI form is what you would use from a scheduled job that drops new weekly results into a project automatically.

## How Lungfish stores time-series

A series is a folder under `Imports/NAO-MGS/` named after the series identifier. Inside it, each sample is one Parquet file named for its collection date in `YYYY-MM-DD` format. The series's `series.json` manifest lists the site, the matrix, the database version, and the schema version of the abundance table. Lungfish reads every file in the series at viewport open time and concatenates them on the date axis.

Sample dates come from one of three places, in priority order. First, an explicit date typed into the wizard or carried in `metadata.tsv` during import. Second, a date encoded in the FASTQ filename when the filename matches a recognised pattern (for example, `MMSD_influent_2026-01-15_R1.fastq.gz`). Third, the FASTQ file's modification date, which is a fallback Lungfish warns about because filesystem dates are easily lost in transit.

If you need to correct a date after the fact, right-click the sample in the result viewport and choose **Edit sample date**. The series rewrites its manifest, the sample's filename changes on disk, and the viewport redraws. The original date is preserved in the provenance record so the correction is auditable.

## Interpretation: reading the surveillance viewport

The result viewport opens with a stacked-line chart, one line per pathogen the database tracks, with weeks along the horizontal axis and relative abundance on the vertical. Lines are drawn in Deep Ink at varying weights; severity is encoded by weight and label, not by red-amber-green. Hovering a point shows the exact abundance value, the underlying read count, and a link to the provenance record for that sample.

<!-- planned: nao-mgs-result-viewport -->

A flat line near the floor means the pathogen is present at background level for every week in the series. That is the expected pattern for most tracked pathogens most of the time. A line that rises above its prior baseline for two or more consecutive weeks is the pattern NAO-MGS is built to surface; you would normally follow up by pulling the underlying reads for those weeks and confirming the hit (Chapter 06.06 covers BLAST verification of a candidate signal).

Three things are worth checking before treating a rise as real. First, the read count for the spike weeks: a small rise driven by ten reads in a low-yield sample is not the same as a large rise driven by ten thousand reads. Second, whether the database version changed mid-series; the result viewport draws a vertical guideline at any week where `manifest.json` reports a different database, because abundance values across a database change are not directly comparable. Third, whether the spike is confined to one site or appears across every site in the project; cross-site spikes that share an exact onset week are sometimes a reagent contamination event rather than a genuine community signal.

The provenance record for each sample is reachable from the right-hand Inspector and lists the database version, the exact `nao-mgs` command line, the input FASTQ checksums, and the output table checksum. That record is what you would cite in a methods section, and the standard methods export (Chapter 09) emits it as a paragraph of plain prose.

## About the Nucleic Acid Observatory

The Nucleic Acid Observatory (NAO) is a research effort that argues for routine, broad metagenomic sequencing of wastewater and other environmental matrices as an early-warning system for novel pathogens. Their public materials describe the analytical approach the NAO-MGS pipeline implements, including the reference set they curate and the abundance reporting conventions Lungfish's viewport follows.

You do not need to read the NAO's papers to use NAO-MGS in Lungfish, but if you are setting up a surveillance program from scratch, their site is the right starting point for design decisions about sampling cadence, matrix choice, and depth targets. See `https://naobservatory.org/` for the program overview and `https://github.com/naobservatory` for the open-source pipeline code Lungfish wraps.

## A worked example: twelve weeks of MMSD influent

Suppose you have twelve weeks of paired-end Illumina reads from the Madison MMSD influent site, one sample per week, and you want to see whether anything trended up across the quarter. You would run the wizard once for week 1, choosing **New series** and naming it "MMSD influent". For weeks 2 through 12, you would re-open the wizard, pick the existing series, and only the FASTQ bundle and sample date would change between runs. After week 12, the result viewport would show twelve points per pathogen line.

If the same twelve weeks had already been processed on a cluster, the equivalent path is one `lungfish nao-mgs import` call against the run directory. The resulting viewport is identical, and a provenance record at each point identifies which path produced it.

## Next

Continue to [BLAST Verification](06-blast-verification.md) to confirm specific organism hits against NCBI.
