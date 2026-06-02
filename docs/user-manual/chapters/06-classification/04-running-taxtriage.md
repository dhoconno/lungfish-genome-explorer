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

TaxTriage is a clinical-surveillance classification pipeline that classifies
reads, reconciles the evidence, and produces a single per-organism confidence
score for each sample. That score is the TASS score (the TaxTriage Aggregate
Scoring System). The pipeline is built around one question: when a clinical
reviewer sits down with a stack of cases, what should they look at first?
TaxTriage answers by ranking each detection by its TASS score so the reviewer
works from the strongest evidence down, rather than scanning a flat list of
taxa.

Lungfish runs TaxTriage through the same run wizard as Kraken2 and EsViritu,
but the result viewport is different. Instead of a sunburst or per-virus
coverage sparklines, you get a TASS confidence chart, a batch overview that
lays out a multi-sample run on one screen, and a batch exporter that writes a
cross-sample organism matrix.

TaxTriage is the right tool when the question is not just "is X present?"
but "is the evidence for X strong enough to act on?" That includes
public-health surveillance, hospital infection-control workflows, and any
multi-sample run where a downstream reviewer has to triage cases by hand. It
is heavier to set up and to run than a single Kraken2 pass (see the next
section), so for research-grade survey work where you want every candidate
organism on the table, prefer Kraken2.

So what should you do with this chapter? Read the setup section first,
because TaxTriage has a prerequisite the other classifiers do not, then read
the TASS-score section, then follow the worked walkthrough end to end on a
small batch before you trust the output on real clinical material.

## What you will learn

By the end of this chapter you will be able to verify the TaxTriage runtime
prerequisites, install its database, run the wizard with TaxTriage selected,
read the TASS confidence chart, compare samples in the batch overview, and
use the batch exporter to write a cross-sample matrix.

## The TASS score, in broad strokes

The TASS score (TaxTriage Aggregate Scoring System) is not a probability in
the strict statistical sense. It is a composite number on a 0 to 1 scale that
folds several lines of evidence (read support, how those reads distribute
across the organism's reference, and agreement between the pipeline's
classification steps) into a single value the reviewer can sort on. A
detection backed by many reads that tile the reference and that the pipeline's
steps agree on scores high; one backed by a few reads piled on one window, or
seen by only part of the pipeline, scores low.

Lungfish draws the score as a horizontal bar per organism and reads it in
three tiers: a TASS at or above 0.8 is a strong call, between 0.4 and 0.8 is a
call worth a closer look, and below 0.4 is weak evidence. The tiers are shown
by bar weight and the numeric value, not by color, so they remain legible
without relying on a red-amber-green scheme.

The point of the score is not to give you a calibrated probability that the
organism is really there. It is to give you a stable, repeatable sort order so
that reviewers triage the same way every time. Treat it as a triage ranking,
not a diagnostic.

## Set up the runtime first: Nextflow and a container

TaxTriage is not a single binary. It runs the `jhuapl-bio/taxtriage`
Nextflow pipeline inside a container, so before you install the database you
must have two things available: **Nextflow** and a **container runtime**
(Docker, or Apple Containerization on Apple Silicon). Installing the database
alone is not enough. The wizard checks for both and keeps the **Run** button
disabled until they are present, which is the most common reason a TaxTriage
run will not start.

Verify both at once with `lungfish taxtriage check-prerequisites`, which
reports whether Nextflow and a container runtime were found. Fix anything it
flags before you go further, because a missing runtime fails the run rather
than degrading it.

## Install the TaxTriage database

With the runtime in place, install the reference database, which is separate
from the Kraken2 and EsViritu databases and is not bundled with the
application. The first time you select TaxTriage in the wizard, its Tool step
shows a "Database not installed" warning instead of a database picker. Open
the **Plugin Manager** from `Tools > Plugin Manager…` (Cmd-Shift-B), find the
TaxTriage entry under Classification, and click **Install**. The Plugin
Manager downloads the database into the Lungfish conda root and writes a
manifest the wizard then picks up.

The default clinical-surveillance database is on the order of tens of
gigabytes, and the default run should be planned as a 16 GB or larger memory
operation before sample-size effects. Allow disk space and time accordingly.

You only install the database once per machine. Updates are handled through
the same Plugin Manager entry, which shows an install date, version string,
and update-available indicator. From the CLI, use
`lungfish conda db info "NCBI Taxonomy"` for the bundled taxonomy support
database and `lungfish conda db list` to inspect other classifier databases
registered on the machine.

## Procedure: run a clinical batch

The walkthrough below uses a hypothetical four-sample clinical batch:
`patient-A.fastq.gz`, `patient-B.fastq.gz`, `patient-C.fastq.gz`, and a
reagent blank `blank.fastq.gz`. The blank is included on purpose, because
TaxTriage's confidence chart is most informative when you can compare patient
calls against a same-batch negative control.

1. From the project sidebar, select all four FASTQ bundles. Open **Tools >
   FASTQ/FASTA Operations > Classification…** and choose **TaxTriage** in the
   wizard's tool picker. The four samples populate the Inputs step.

2. Confirm the database picker shows the version you installed. If it shows
   "Database not installed", or if the **Run** button is disabled, stop and
   resolve the runtime and database setup above before returning.
   <!-- planned: taxtriage-wizard-tool-step -->

3. Set the wizard's run options. **Sequencing Platform** (Illumina, Oxford
   Nanopore, or PacBio) tells the pipeline what data it is reading. The
   **Skip assembly** toggle is on by default, which is the faster path; the
   **Skip Krona** toggle controls whether the pipeline renders its own Krona
   chart. The Advanced section exposes the Kraken2 confidence (default 0.2),
   the number of top hits to keep (default 10), and the memory and CPU
   ceilings. There is no clinical-versus-research-versus-wastewater profile
   picker; leave the defaults for a first run.

4. Click **Run**. The wizard closes and a TaxTriage operation appears in the
   Operations Panel. A four-sample batch takes a few minutes per sample on
   Apple Silicon; the operation row shows per-sample progress.

5. When the batch finishes, click the batch result in the sidebar to open
   the TaxTriage result viewport.

The headless form is `lungfish taxtriage run`, with `--platform`,
`--samplesheet` for a multi-sample run, `--confidence` (default 0.2),
`--top-hits` (default 10), `--rank` (default S, for species), `--skip-assembly`
(on by default), `--skip-krona`, `--max-memory`, and `--nf-profile` (default
docker). The pipeline revision is pinned so a re-run reproduces the same
result.

## Interpretation: read the confidence chart

The result viewport opens on the **TASS confidence chart** for the sample
selected in the sidebar. Each bar is one organism call, sorted by TASS score,
highest first, with the numeric score read off the bar.

Three things to do on first read.

1. Skim the top of the chart. For a clean clinical sample, the top one or two
   bars are usually the intended pathogen in the strong tier (TASS at or
   above 0.8). If nothing reaches the 0.4 to 0.8 tier, the sample is probably
   either uninformative or below the depth needed for a confident call.

2. Switch to the **batch overview** tab. The batch overview lays out all
   samples in the run as columns and the union of called organisms as rows,
   with the score in each cell. This is where you compare the patient
   samples against the reagent blank.
   <!-- planned: taxtriage-batch-overview -->

3. Look at the blank column. Anything with a non-trivial score in the blank
   is, at minimum, a candidate contaminant for the whole batch. TaxTriage
   does not automatically subtract blank calls from patient calls. The
   reviewer does that, with the batch overview as the working surface.
   <!-- planned: taxtriage-confidence-list -->

The mini-BAM preview shows the reads that support the currently selected
organism, mapped against the organism's reference. Treat the mini-BAM as a
sanity check: if the supporting reads pile up in one narrow region, the call
is suspect even when the score is high. To get an independent second opinion
on a call, right-click its row on the batch table and choose
**Verify with BLAST…**, which runs the verification flow described in
[BLAST Verification](06-blast-verification.md).

## Compare and export across samples

Two viewport surfaces handle cross-sample work. The batch overview, above, is
the at-a-glance comparison. A second tab holds a **cross-sample SNP table**
that lays out, position by position, how the samples that share an organism
differ, which is the surface to reach for when two patients carry what looks
like the same pathogen and you want to know whether it is the same strain.

When the review is complete, export from the viewport's action bar, not from
the File menu. The exporter writes two files to a folder you choose: a
**cross-sample organism matrix** as a CSV (one row per organism, with columns
for the mean TASS score, how many samples detected it, a contamination-risk
indicator, and then the per-sample TASS score), and a plain-text summary
report. There is no PDF and there are no report templates; the matrix CSV is
the machine-readable file to keep if you
are loading TaxTriage results into a downstream LIMS or surveillance
dashboard.

<!-- planned: taxtriage-batch-export -->

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md) for
wastewater surveillance, or [BLAST Verification](06-blast-verification.md) to
confirm a TaxTriage hit.
