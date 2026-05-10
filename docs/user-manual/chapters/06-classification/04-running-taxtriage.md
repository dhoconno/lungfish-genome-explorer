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
  - "Tools > FASTQ/FASTA Operations > Classification > TaxTriage"
  - "CLI: lungfish taxtriage run"
shots: []
planned_shots:
  - id: taxtriage-wizard-tool-step
    caption: "The Classification wizard with TaxTriage selected and a multi-sample batch loaded."
  - id: taxtriage-confidence-list
    caption: "The TaxTriage confidence-ranked organism list with one detection flagged for manual review."
  - id: taxtriage-batch-overview
    caption: "The batch overview showing per-sample organism calls across a four-sample run."
  - id: taxtriage-batch-export-sheet
    caption: "The batch exporter sheet with the clinical reporting template selected."
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

TaxTriage is a clinical-surveillance classification pipeline that runs several
classifiers in sequence, reconciles their calls, and produces a single
per-organism confidence score for each sample. The pipeline is built around
one question: when a clinical reviewer sits down with a stack of cases, what
should they look at first? TaxTriage answers by ranking each detection by
confidence and surfacing low-confidence calls as flags for manual review,
rather than leaving the reviewer to scan a flat list of taxa.

Lungfish runs TaxTriage through the same Classification wizard as Kraken2 and
EsViritu, but the result viewport is different. Instead of a per-sample taxon
table or per-strain coverage sparklines, you get a confidence-ranked organism
list, a batch overview that lays out a multi-sample run on one screen, and a
batch exporter that produces a clinical reporting bundle.

TaxTriage is the right tool when the question is not just "is X present?"
but "is the evidence for X strong enough to act on?" That includes
public-health surveillance, hospital infection-control workflows, and any
multi-sample run where a downstream reviewer has to triage cases by hand. It
is over-engineered for research-grade survey work where you want every
candidate organism on the table; for that, prefer Kraken2.

So what should you do with this chapter? Read the confidence-scoring section
first if you have never run TaxTriage before, then follow the worked
walkthrough end to end on a small batch before you trust the output on real
clinical material.

## What you will learn

By the end of this chapter you will be able to install the TaxTriage database,
run the Classification wizard with TaxTriage selected, read the confidence
view, recognize when a detection is flagged for manual review, and use the
batch exporter to produce a multi-sample report.

## Confidence scoring, in broad strokes

The TaxTriage confidence score is not a probability in the strict statistical
sense. It is a composite number, conventionally on a 0 to 1 scale, that
combines several lines of evidence into a single value the reviewer can sort
on. The exact weighting is configurable inside the pipeline, but for the
default clinical profile shipped with Lungfish, the score reflects four
contributions, in roughly decreasing order of influence: how many reads
classify to that organism, how those reads distribute across the organism's
genome, how strongly competing classifiers agree, and how clean the read
quality looks at the assigned positions.

Read count alone is the weakest of these. A few thousand reads from a single
short, high-copy region of a viral genome can outweigh, by raw count, a few
hundred reads spread evenly across a bacterial chromosome, but the first is
much more often a contamination or index-hop artefact than the second. The
distribution term is what penalises the first case: TaxTriage looks at the
breadth of coverage across the organism's reference, and a detection
concentrated in one or two narrow windows is downweighted relative to one
that tiles the genome.

Cross-classifier agreement is the term that gives TaxTriage its name. The
pipeline runs more than one classifier internally, and when their calls
agree at the species (or strain, where applicable) level, the score goes up.
When they disagree, or when only one classifier sees the organism, the score
goes down and the detection often picks up a manual-review flag. This is the
mechanism by which a Kraken2-only or EsViritu-only call ends up surfaced for
review rather than buried.

The point of the score is not to give you a calibrated probability that the
organism is really there. It is to give you a stable, repeatable sort order
so that reviewers triage the same way every time. Treat it as a triage
ranking, not a diagnostic.

## Install the TaxTriage database first

TaxTriage needs its own reference database, which is separate from the
Kraken2 and EsViritu databases and is not bundled with the application. The
first time you select TaxTriage in the Classification wizard, the wizard's
Tool step will show a "Database not installed" warning instead of a database
picker. Open the **Plugin Manager** from the Tools menu, find the TaxTriage
entry under Classification, and click **Install**. The Plugin Manager
downloads the database into the Lungfish conda root and writes a manifest
the wizard then picks up.

The default clinical-surveillance database is on the order of tens of
gigabytes, and the default profile should be planned as a 16 to 32 GB RAM
operation before sample-size effects. Allow disk space and time
accordingly. If you are running on a laptop with a small SSD, the Plugin
Manager has a "Use external location" option that places the database
under a user-chosen folder and symlinks it into place; that is the
supported way to keep the database on an external drive without confusing
the runtime.

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
TaxTriage's confidence view is most informative when you can compare patient
calls against a same-batch negative control.

1. From the project sidebar, select all four FASTQ bundles. Choose **Tools >
   FASTQ/FASTA Operations > Classification > TaxTriage**. The Classification
   wizard opens with the four samples already populated in the Inputs step.

2. In the Tool step, confirm that **TaxTriage** is selected and that the
   database picker shows the version you installed. If it shows
   "Database not installed", stop and install the database through the
   Plugin Manager as above, then return to the wizard.
   <!-- planned: taxtriage-wizard-tool-step -->

3. In the Profile step, choose **Clinical surveillance (default)**. The
   research and wastewater profiles change the score weighting and the
   manual-review thresholds, and they are not what you want for a clinical
   batch.

4. Leave the Output step at its defaults. The wizard will write per-sample
   results into a `Classifications/TaxTriage/<run-id>/` folder under the
   project, and a single batch result bundle alongside it.

5. Click **Run**. The wizard closes and a TaxTriage operation appears in the
   Operations panel. A four-sample batch on a typical clinical FASTQ takes a
   few minutes per sample on Apple Silicon; the operation row shows
   per-sample progress.

6. When the batch finishes, click the batch result in the sidebar to open
   the TaxTriage result viewport.

## Interpretation: read the confidence view

The result viewport opens on the **confidence-ranked organism list** for the
sample selected in the sidebar. Each row is one organism call, sorted by
confidence score, highest first. The columns are organism, score, supporting
read count, breadth of coverage, classifier agreement, and a flags column
that holds the manual-review markers described below.

Three things to do on first read.

1. Sort by score and skim the top of the list. For a clean clinical sample,
   the top one or two rows are usually the intended pathogen at high
   confidence. If nothing in the top of the list has a score above the
   default review threshold, the sample is probably either uninformative or
   below the depth needed for a confident call.

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

The mini-BAM preview at the bottom of the viewport shows the reads that
support the currently-selected organism, mapped against the organism's
reference. Treat the mini-BAM as a sanity check: if the supporting reads
pile up in one narrow region, the call is suspect even when the score is
high.

## Manual-review flags

TaxTriage attaches a flag to a detection when one or more of its internal
checks tripped during scoring. The flag is not a verdict; it is an
instruction to look. The default clinical profile fires four flag types,
described in the table below.

| Flag | What it means | What to do |
|---|---|---|
| `LOW_BREADTH` | Reads concentrate in a small fraction of the organism's reference, even though raw read count is high. | Open the mini-BAM and check whether the reads tile the genome or pile up on one window. Single-window pileups are usually contamination or index-hop. |
| `CLASSIFIER_DISAGREE` | The internal classifiers split on whether this organism is present. | Inspect the per-classifier breakdown in the Inspector. A single dissenting classifier on an otherwise clean call is often a database-level miss; a true disagreement is worth flagging in the report. |
| `BLANK_MATCH` | The same organism appears in this batch's reagent blank with a non-trivial score. | Compare the patient and blank scores in the batch overview. If they are close, treat the patient call as a contaminant unless other evidence outweighs that. |
| `LOW_QUALITY_SUPPORT` | The supporting reads have base-quality distributions noticeably worse than the sample average. | Re-run with stricter quality trimming or accept that the call is probably noise. |

The flags appear as small icons in the flags column. Hover for the long-form
text. The Inspector's TaxTriage section shows the same flags with the
underlying numerical thresholds, so a power-user can audit why a flag fired.

## Export a clinical report

When the review is complete, use the batch exporter to produce a reporting
bundle.

1. With the batch result open, choose **File > Export > TaxTriage Batch
   Report**. The exporter sheet opens.
   <!-- planned: taxtriage-batch-export-sheet -->

2. Choose the **Clinical reporting** template. The other templates
   (research summary, surveillance feed) reformat the same data for
   different downstream consumers.

3. Pick the destination folder and click **Export**. The exporter writes a
   PDF summary, a per-sample CSV of confidence-ranked calls, and a
   provenance sidecar that records the database version, profile, and
   per-sample input checksums.

The PDF summary is paginated one sample per page, with the confidence list
on top and the manual-review flags surfaced as a separate section below.
The CSV is the machine-readable equivalent and is the file to keep if you
are loading TaxTriage results into a downstream LIMS or surveillance
dashboard.

## Next

Continue to [Running NAO-MGS](05-running-nao-mgs.md) for wastewater
surveillance, or [BLAST Verification](06-blast-verification.md) to confirm a
TaxTriage hit.
