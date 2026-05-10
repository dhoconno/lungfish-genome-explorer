---
title: Running EsViritu
chapter_id: 06-classification/03-running-esviritu
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 9
task: Classify reads with EsViritu for viral identification and read the result viewport.
tags: [classification, esviritu, viral, strain]
tools: [esviritu]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Classification > EsViritu"
  - "CLI: lungfish esviritu run"
shots: []
planned_shots:
  - id: esviritu-wizard-tool-step
    caption: "The Classification wizard with EsViritu chosen as the tool."
  - id: esviritu-database-missing
    caption: "The wizard's inline notice when the EsViritu database has not yet been installed."
  - id: esviritu-result-viewport
    caption: "The EsViritu result viewport showing per-strain coverage sparklines for SRR36291587."
  - id: esviritu-strain-comparison
    caption: "The strain comparison view with two SARS-CoV-2 lineages selected."
  - id: esviritu-mini-bam
    caption: "The mini-BAM preview docked under a selected strain row."
illustrations: []
glossary_refs: [coverage, mapping, BAM, plugin pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

EsViritu is a viral-focused classifier that maps reads against a curated
database of viral reference genomes and then reports, for each genome that
attracted reads, both the identity of the genome and how much of it the
reads actually covered. Where Kraken2 (Chapter 6.2) decides taxonomy by
breaking each read into k-mers and looking those k-mers up in a tree,
EsViritu does the slower, more direct thing: it aligns the read to a small
set of viral references and lets the alignment speak for itself.

That difference matters in two practical ways. The first is **resolution.**
A Kraken2 hit at the species level tells you "SARS-CoV-2 reads are
present"; an EsViritu hit attaches that to a specific reference accession
in its strain catalogue and to a coverage profile across that reference, so
you can distinguish "the genome is uniformly covered to 200x" from "two
short windows pulled in 95% of the reads and the rest is empty." The
second is **specificity for low-abundance viruses.** Because EsViritu
performs full alignment, a handful of reads that genuinely match a viral
reference are visible as a coverage track, where the same reads scattered
through a metagenomic Kraken2 report would be statistically indistinguishable
from background.

EsViritu is therefore the right tool when you already know, or strongly
suspect, that the sample is viral, and you want strain-level resolution
with explicit coverage evidence. It is the wrong tool for "what is in this
sample?" survey work that ranges across bacteria, archaea, eukaryotes, and
viruses simultaneously. For that, run Kraken2 first and bring suspicious
viral hits to EsViritu afterwards.

So what should you do with this? Treat EsViritu as the second-pass
classifier you reach for once a virus is on the table, not as your first
look at an unknown sample.

## What you will learn

By the end of this chapter you will be able to install the EsViritu
database, run the Classification wizard with EsViritu selected, read the
EsViritu result viewport's coverage sparklines, compare two suspected
strains in the strain comparison view, and inspect the underlying
mini-BAM to verify a hit.

## EsViritu compared with Kraken2

Both tools answer "is virus X present," but they answer different
follow-up questions, and they fail in different ways. Use the table as a
quick decision aid before running either.

| Question you have | Tool that answers it directly |
|---|---|
| What organisms are in this sample, across all kingdoms? | Kraken2 |
| Is virus X here, and which strain or lineage? | EsViritu |
| Did the reads cover the whole viral genome, or just a few hot spots? | EsViritu (coverage sparkline) |
| How many reads classify per minute on a laptop? | Kraken2 |
| Can I distinguish two co-circulating SARS-CoV-2 lineages? | EsViritu (strain comparison view) |

The two tools complement each other. A common workflow is to screen with
Kraken2, note the viral species that show up, then re-run those samples
through EsViritu against the matching genus or family slice of its
database. EsViritu calls a strain "supported" when both a minimum read
count and a minimum breadth-of-coverage threshold are met (defaults: 50
reads and 10% breadth at 1x, configurable in the wizard); a Kraken2 hit
has no analogous breadth check.

## Installing the EsViritu database

The EsViritu tool itself ships inside the `classification` plugin pack.
The strain database is a separate artefact: roughly 400 MB compressed,
around 5 GB uncompressed, holding 19,925 curated viral assemblies across
63 families. Lungfish does not bundle this database, because most users
will only ever run a subset of classifiers and the database would balloon
every install. Plan for at least 8 GB of RAM for the default viral
database. Larger custom slices scale with the number and length of
references included.

Install the database before your first EsViritu run.

1. Open **Lungfish > Settings > Plugin Manager**.
   <!-- planned: esviritu-database-missing -->
2. Find the **EsViritu** row under the Classification group.
3. Click **Install Database**. The download runs in the background and
   reports progress in the Operations Panel.
4. Wait until the row's status badge reads **Database ready**. On a
   typical broadband connection this is 5 to 15 minutes.
5. Confirm the row's install date and update status. From the CLI, the
   same tracking surface is `lungfish conda db info "EsViritu Viral DB"`,
   which reports the database version, install date, available update,
   disk path, disk size, and RAM requirement.

If you skip this step, the Classification wizard still lets you choose
EsViritu, but the **Run** button stays disabled and an inline notice
points you back to the Plugin Manager. Power users who prefer the
command line can install with `lungfish esviritu db install`; the result
is identical.

## Procedure

The walkthrough below classifies SRR36291587, a SARS-CoV-2 amplicon run,
and reads the result viewport. SRR36291587 is one of the public SRA
accessions used elsewhere in this manual, downloaded through **Search
NCBI/SRA** as in Chapter 3.4.

1. In the project sidebar, select the FASTQ pair for SRR36291587 under
   `Imports/`.
2. Choose **Tools > FASTQ/FASTA Operations > Classification > EsViritu**.
   The Classification wizard opens with EsViritu pre-selected.
   <!-- planned: esviritu-wizard-tool-step -->
3. Confirm that the **Inputs** step lists the two paired reads and that
   their total size matches what the sidebar shows. If only one of the
   pair is listed, click **Add second mate** and pick the partner file.
4. Move to the **Database** step. The picker should show
   **EsViritu (installed)** with a version string and an install date. If
   it shows **Not installed**, follow the database-install procedure
   above before continuing.
5. On the **Options** step, leave the defaults for a first run:
   minimum read length 100 nt, minimum breadth 10%, minimum read count
   50. Click **Run**.

The wizard closes and an EsViritu row appears in the Operations Panel.
For SRR36291587 on an M-series laptop the run takes roughly 4 to 8
minutes; the Panel reports each phase (database load, mapping, coverage
summarisation, report rendering) as it completes.

## Interpretation

When the run finishes, double-click the new classification result in the
sidebar to open the EsViritu viewport.

### The strain table and coverage sparklines

The viewport's left pane is a sortable strain table. Each row is one
reference genome from the EsViritu database that attracted enough reads
and coverage breadth to clear thresholds, with columns for accession,
organism, lineage label (when the database carries one), read count,
mean depth, and percent breadth at 1x. The rightmost column of the
table is a coverage sparkline: a small horizontal track, the width of
the column, that plots depth across the reference from left (5' end of
the genome) to right (3' end).

<!-- planned: esviritu-result-viewport -->

Read the sparkline before the numeric columns. A flat, evenly-shaded
sparkline means the reads tile the genome end to end; this is what a
real, abundant infection looks like. A sparkline with two or three tall
spikes and long flat valleys means the reads cluster on a few short
windows, which often signals one of three things: an off-target amplicon,
a conserved region shared with a related virus, or a host sequence that
happens to share homology with the reference. The numeric "percent
breadth at 1x" column quantifies the same intuition: 95% breadth on a
30 kb genome leaves only 1.5 kb uncovered, and is a strong call;
12% breadth across scattered windows is not.

For SRR36291587 the top row should report the SARS-CoV-2 reference
(NC_045512.2 or a close MT-prefixed accession, depending on database
build), with a mostly-flat sparkline, several thousand reads mapped, and
breadth in the high 90s. Rows below it usually carry a few low-confidence
hits to related betacoronaviruses, which the breadth column shows as
single-digit percentages and the sparkline shows as a single thin spike.

### The strain comparison view

Two co-circulating viral lineages, for example two SARS-CoV-2 sub-variants
in a wastewater sample, can produce overlapping strain-table rows whose
sparklines look superficially identical. The strain comparison view lets
you check whether the reads supporting each row are genuinely different
reads, or just the same reads claimed twice.

Select two rows in the strain table by Cmd-clicking, then click
**Compare** in the viewport toolbar. The comparison view stacks the two
coverage tracks against a shared genomic axis and shades, in Lungfish
Creamsicle, the regions where one strain's coverage exceeds the other's
by a configurable margin. Underneath the tracks, a small bar chart
breaks down how many reads aligned uniquely to one reference, how many
to the other, and how many were assigned ambiguously and split between
them by EsViritu's tie-breaker.

<!-- planned: esviritu-strain-comparison -->

A genuine co-infection produces non-trivial unique-read bars on both
sides and shaded windows where one lineage's defining mutations fall.
A spurious "second strain" produces near-zero unique reads on the second
side; almost every read is shared, and the second row is just the
database carrying two near-identical references for the same lineage.

### Mini-BAM preview

To audit a single sparkline directly, click any strain row and then
click **Show reads** in the inspector. A mini-BAM preview docks under
the strain table, showing the top of the mapped reads pile against
that reference. This is a real, indexed BAM saved alongside the
classification result; you can scroll the genomic axis, zoom into a
region, and see read sequences, CIGAR strings, and base qualities the
same way the alignment viewport does (Chapter 5).

<!-- planned: esviritu-mini-bam -->

The mini-BAM is the source of truth for everything in the viewport
above it. If the strain row claims 2,400 reads and the BAM viewer shows
a thick, evenly-spread pile, the call is real. If it claims 2,400 reads
and the BAM viewer shows a single tall stack at one position, you are
looking at PCR duplicates of one fragment, and the apparent depth is
inflated; flag the row as low-confidence regardless of what the
breadth column says.

## What to do next

Once you trust an EsViritu hit, the usual next steps are to confirm the
identification with a small BLAST query against NCBI nt
([Chapter 6.6](06-blast-verification.md)), or to map the same reads
against the matched reference and call variants if you want lineage-level
assignment beyond what the EsViritu strain label provides
([Chapter 4.1](../04-variants/01-reads-to-variants.md)).

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md) for
clinical-surveillance classification, or [BLAST Verification](06-blast-verification.md)
to confirm an EsViritu hit.
