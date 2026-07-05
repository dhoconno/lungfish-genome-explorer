---
title: Running TaxTriage
chapter_id: 06-classification/04-running-taxtriage
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 9
task: Classify reads with TaxTriage for clinical surveillance and read the confidence view.
tags: [classification, taxtriage, clinical, confidence]
tools: [taxtriage]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Classification…"
  - "CLI: lungfish taxtriage run"
shots: []
planned_shots:
  - id: taxtriage-wizard-tool-step
    caption: "The run wizard with TaxTriage selected and a multi-sample batch loaded."
  - id: taxtriage-confidence-list
    caption: "The TaxTriage TASS confidence chart, with organisms ranked by score."
  - id: taxtriage-batch-overview
    caption: "The batch overview showing per-sample organism calls across a four-sample run."
  - id: taxtriage-batch-export
    caption: "The cross-sample organism matrix written by the batch exporter."
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

TaxTriage is a clinical-surveillance classification pipeline. It classifies
reads, reconciles the evidence, and produces a single per-organism confidence
score for each sample. That score is the TASS score (the TaxTriage Aggregate
Scoring System). The pipeline is built around one question: when a clinical
reviewer sits down with a stack of cases, what should they look at first?
TaxTriage answers by ranking each detection by its TASS score, so the reviewer
works from the strongest evidence down instead of scanning a flat list of taxa.

Lungfish runs TaxTriage through the same run wizard as Kraken2 and EsViritu,
but the result viewport is a different animal. Instead of a sunburst or
per-virus coverage sparklines, you get a TASS confidence chart, a batch
overview that lays a multi-sample run out on one screen, and a batch exporter
that writes a cross-sample organism matrix.

TaxTriage is the right tool when the question is not just "is X present?"
but "is the evidence for X strong enough to act on?" That covers
public-health surveillance, hospital infection-control workflows, and any
multi-sample run where a downstream reviewer has to triage cases by hand. It
is heavier to set up and to run than a single Kraken2 pass (see the next
section), so for research-grade survey work where you want every candidate
organism on the table, prefer Kraken2.

Work through this chapter in order. Read the setup section first, because
TaxTriage carries a prerequisite the other classifiers do not, then the
TASS-score section, then follow the worked walkthrough end to end on a small
batch before you trust the output on real clinical material.

## What you will learn

Expect to come out of this chapter able to verify the TaxTriage runtime
prerequisites, point it at an installed Kraken2 database, run the wizard with TaxTriage selected,
read the TASS confidence chart, compare samples in the batch overview, and
use the batch exporter to write a cross-sample matrix.

## The TASS score, in broad strokes

The TASS score (TaxTriage Aggregate Scoring System) is not a probability in
the strict statistical sense. It is a composite number on a 0 to 1 scale that
folds several lines of evidence (read support, how those reads spread across
the organism's reference, and agreement between the pipeline's classification
steps) into one value the reviewer can sort on. A detection backed by many
reads that tile the reference, and that the pipeline's steps agree on, scores
high; one backed by a few reads piled on a single window, or seen by only part
of the pipeline, scores low.

Lungfish draws the score as one horizontal bar per organism and reads it in
three tiers: a TASS at or above 0.8 is a strong call, between 0.4 and 0.8 is a
call worth a closer look, and below 0.4 is weak evidence. Bar weight and the
numeric value mark the tiers, not color, so they stay legible without leaning
on a red-amber-green scheme.

The point of the score is not a calibrated probability that the organism is
really there. It is a stable, repeatable sort order, so reviewers triage the
same way every time. Treat it as a triage ranking, not a diagnostic.

## Set up the runtime first: Nextflow and a container

TaxTriage is not a single binary. It runs the `jhuapl-bio/taxtriage`
Nextflow pipeline inside a container, so before you install the database you
need two things in place: **Nextflow** and a **container runtime** (Docker,
or Apple Containerization on Apple Silicon). The database alone is not enough.
The wizard checks for both and keeps the **Run** button disabled until they
are present, the most common reason a TaxTriage run will not start.

Check both at once with `lungfish taxtriage check-prerequisites`, which
reports whether Nextflow and a container runtime were found. Fix anything it
flags before you go further, because a missing runtime fails the run outright
rather than degrading it.

## Install the TaxTriage database

With the runtime in place, give TaxTriage a classification database. Despite
the pipeline's name, it does not ship one of its own: it classifies with an
installed Kraken2 database, the same kind the Kraken2 tool uses. The wizard
labels its picker **Kraken2 Database** and lists the Kraken2 databases already
downloaded on this machine. The first time you select TaxTriage, if none are
installed the picker reads "No Kraken2 databases installed" and the **Run**
button stays disabled. Install one the same way you would for Kraken2, then
return.

Plan for the size of the database you choose. A clinical-surveillance Kraken2
database can run to tens of gigabytes on disk, and the wizard's default memory
ceiling is 16 GB (raise it in Advanced Settings for a large database or a big
batch). Budget disk space and time to match.

You install a Kraken2 database once per machine, and every Kraken2-based tool,
TaxTriage included, shares it. From the CLI, `lungfish db list` shows each
registered database with its status, size, recommended RAM, and whether an
update is available, `lungfish db info <name>` reports one database's installed
version, and `lungfish db download` fetches a new one.

## Procedure: run a clinical batch

The walkthrough below uses a hypothetical four-sample clinical batch:
`patient-A.fastq.gz`, `patient-B.fastq.gz`, `patient-C.fastq.gz`, and a
reagent blank `blank.fastq.gz`. The blank is there on purpose, because
TaxTriage's confidence chart tells you the most when you can weigh patient
calls against a same-batch negative control.

1. From the project sidebar, select all four FASTQ bundles. Open **Tools >
   FASTQ/FASTA Operations > Classification…** and choose **TaxTriage** in the
   wizard's tool picker. The four samples fill the Inputs step. Each sample
   carries a **Sample Role** picker (Clinical Sample, Negative Control,
   Positive Control, Environmental Control, or Extraction Blank), pre-filled
   from the FASTQ bundle's metadata when it records one. Set the reagent blank
   to **Extraction Blank** or **Negative Control**: those two roles are what
   mark a sample as a negative control and drive the contamination-risk column
   in the batch matrix.

2. Confirm the **Kraken2 Database** picker shows a database. If it reads
   "No Kraken2 databases installed", or the **Run** button is disabled, stop
   and resolve the runtime and database setup above before returning.
   <!-- planned: taxtriage-wizard-tool-step -->

3. Set the wizard's run options. **Sequencing Platform** (Illumina, Oxford
   Nanopore, or PacBio) tells the pipeline what data it is reading. The
   **Skip assembly** toggle is on by default, the faster path; the
   **Skip Krona** toggle decides whether the pipeline renders its own Krona
   chart. The Advanced section exposes the Kraken2 confidence (default 0.2),
   the number of top hits to keep (default 10), and the memory and CPU
   ceilings. There is no clinical-versus-research-versus-wastewater profile
   picker; keep the defaults for a first run.

4. Click **Run**. The wizard closes and a TaxTriage operation appears in the
   Operations Panel. A four-sample batch takes a few minutes per sample on
   Apple Silicon, and the operation row shows per-sample progress.

5. When the batch finishes, click the batch result in the sidebar to open
   the TaxTriage result viewport.

The headless form is `lungfish taxtriage run`, with `--platform`,
`--samplesheet` for a multi-sample run, `--confidence` (default 0.2),
`--top-hits` (default 10), `--rank` (default S, for species), `--skip-assembly`
(on by default), `--skip-krona`, `--max-memory`, and `--nf-profile` (default
docker). For a single sample, pass `--input` (add `--input2` for the R2 of a
pair) with `--sample` for the identifier; `--samplesheet` takes a CSV instead
and is mutually exclusive with `--input`. Either way `--output`/`-o` is
required, and `--db` points at the Kraken2 database to classify against.

```bash
lungfish taxtriage run --input patient-A.fastq.gz --sample patient-A \
  --db /path/to/kraken2-db --output results/
```

The pipeline revision is pinned, so a rerun reproduces the same result.

## Interpretation: read the confidence chart

The result viewport opens on the **TASS confidence chart** for the sample
selected in the sidebar. Each bar is one organism call, sorted by TASS score,
highest first, with the numeric score printed on the bar. On a multi-sample
run a segmented sample selector sits above the chart, with **All Samples** as
its first segment and one segment per sample after it, so you can pivot the
view to any single sample or the whole run. A **Filter organisms** field
beside it narrows the rows to names that match what you type.

Three things to do on first read.

1. Skim the top of the chart. For a clean clinical sample, the top one or two
   bars are usually the intended pathogen in the strong tier (TASS at or
   above 0.8). If nothing even reaches the 0.4 to 0.8 tier, the sample is
   probably uninformative or below the depth a confident call needs.

2. Switch to the **batch overview** tab. It lays out every sample in the run
   as columns and the union of called organisms as rows, with the score in
   each cell. This is where you weigh the patient samples against the reagent
   blank.
   <!-- planned: taxtriage-batch-overview -->

3. Look at the blank column. Anything with a non-trivial score in the blank
   is, at minimum, a candidate contaminant for the whole batch. TaxTriage
   does not subtract blank calls from patient calls on its own. The reviewer
   does that, with the batch overview as the working surface.
   <!-- planned: taxtriage-confidence-list -->

The mini-BAM preview shows the reads behind the selected organism, mapped
against that organism's reference. Treat it as a sanity check: if the
supporting reads bunch into one narrow region, the call is suspect even when
the score is high. For an independent second opinion, right-click the row in
the batch table and choose **Verify with BLAST…**, which runs the
verification flow described in [BLAST Verification](06-blast-verification.md).
The same row menu, and the action bar, also offer **Extract Reads…**, which
pulls the reads assigned to the selected organism into a fresh FASTQ dataset
for downstream mapping or assembly.

## Compare and export across samples

Two viewport surfaces handle cross-sample work. The batch overview, above, is
the at-a-glance comparison. A second tab holds a **cross-sample SNP table**
that lays out, position by position, how the samples sharing an organism
differ. Reach for it when two patients carry what looks like the same pathogen
and you want to know whether it is the same strain.

When the review is done, export from the viewport's action bar, not the File
menu. The **Export** button opens a menu: **Export as CSV** and **Export as
TSV** write the current organism table, and **Copy Summary** puts a text
summary on the clipboard. On a multi-sample run the menu adds two batch-only
items, **Export Organism Matrix (CSV)** and **Export Batch Report**. The
organism matrix is one row per organism, with columns for the mean TASS score,
how many samples detected it, a contamination-risk indicator, and then the
per-sample TASS score; the batch report is a plain-text summary. There is no
PDF and no report templates; the matrix CSV is the machine-readable file to
keep when you are loading TaxTriage results into a downstream LIMS or
surveillance dashboard.

<!-- planned: taxtriage-batch-export -->

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md) for
wastewater surveillance, or [BLAST Verification](06-blast-verification.md) to
confirm a TaxTriage hit.
