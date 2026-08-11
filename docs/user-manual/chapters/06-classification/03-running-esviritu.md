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
  - "Tools > FASTQ/FASTA Operations > Classification…"
  - "CLI: lungfish esviritu detect"
shots: []
planned_shots:
  - id: esviritu-wizard-tool-step
    caption: "The run wizard with EsViritu chosen as the tool."
  - id: esviritu-database-missing
    caption: "The wizard's inline notice when the EsViritu database has not yet been installed."
  - id: esviritu-result-viewport
    caption: "The EsViritu result viewport showing per-virus coverage sparklines for SRR36291587."
  - id: esviritu-bam-viewer
    caption: "The full BAM viewer that appears in the detail pane for a selected virus row."
illustrations: []
glossary_refs: [coverage, mapping, BAM, plugin pack]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

EsViritu is a viral-focused classifier that maps reads against a curated
database of viral reference genomes, then reports, for every genome that
drew reads, both its identity and how much of it the reads actually covered.
Where Kraken2 (Chapter 6.2) settles taxonomy by breaking each read into
k-mers and looking those k-mers up in a tree, EsViritu does the slower, more
direct thing: it aligns the read to a small set of viral references and lets
the alignment speak for itself.

That difference pays off in two practical ways. The first is **resolution.**
A Kraken2 hit at the species level tells you "SARS-CoV-2 reads are
present"; an EsViritu hit pins that to a specific reference accession in its
strain catalogue and to a coverage profile across that reference, so you can
tell "the genome is uniformly covered to 200x" from "two short windows
pulled in 95% of the reads and the rest is empty." The second is
**specificity for low-abundance viruses.** Because EsViritu aligns in full,
a handful of reads that truly match a viral reference stand out as a
coverage track, where the same reads scattered through a metagenomic Kraken2
report would blur into background.

So EsViritu is the right tool when you already know, or strongly suspect,
that the sample is viral, and you want strain-level resolution with explicit
coverage evidence. It is the wrong tool for "what is in this sample?" survey
work that sweeps across bacteria, archaea, eukaryotes, and viruses at once.
For that, run Kraken2 first and carry the suspicious viral hits to EsViritu
afterwards.

The takeaway: treat EsViritu as the second-pass classifier you reach for
once a virus is on the table, not as your first look at an unknown sample.

## What you will learn

Here you will learn to install the EsViritu database, run the wizard with
EsViritu selected, read the result viewport's coverage sparklines, and
inspect the underlying BAM in the full alignment viewer to verify a hit.

## EsViritu compared with Kraken2

Both tools answer "is virus X present," but they answer different follow-up
questions, and they fail in different ways. Use the table as a quick
decision aid before you run either.

| Question you have | Tool that answers it directly |
|---|---|
| What organisms are in this sample, across all kingdoms? | Kraken2 |
| Is virus X here, and which strain or lineage? | EsViritu |
| Did the reads cover the whole viral genome, or just a few hot spots? | EsViritu (coverage sparkline) |
| How many reads classify per minute on a laptop? | Kraken2 |
| Are the reads spread across the genome or piled on one window? | EsViritu (full BAM viewer) |

The two tools complement each other. A common workflow screens with
Kraken2, notes the viral species that surface, then reruns those samples
through EsViritu against its viral database. What EsViritu adds is coverage
evidence: because it aligns reads to each reference, you see the breadth of
coverage across the genome as a sparkline, a check a Kraken2 hit never gives
you.

## Installing the EsViritu database

The EsViritu tool itself ships inside the `classification` plugin pack. Its
strain database is a separate artefact: roughly 400 MB compressed, around
5 GB uncompressed, holding 19,925 curated viral assemblies across 63
families. Lungfish does not bundle it, because most users run only a subset
of classifiers and the database would balloon every install. Plan for at
least 8 GB of RAM for the default viral database. Larger custom slices scale
with the number and length of references you include.

Install the database before your first EsViritu run.

1. Open the Plugin Manager from `Tools > Plugin Manager…` (Cmd-Shift-B).
   <!-- planned: esviritu-database-missing -->
2. Find the **EsViritu** row under the Classification group.
3. Click **Install Database**. The download runs in the background and
   reports progress in the Operations Panel.
4. Wait until the row's status badge reads **Database ready**. On a
   typical broadband connection this is 5 to 15 minutes.
5. Confirm the row's version and status. From the CLI, the same status
   surface is `lungfish esviritu db-status`, which reports the database
   status, version, disk path, and disk size.

Skip this step and the wizard still lets you choose EsViritu, but the
**Run** button stays disabled and an inline notice points you back to the
Plugin Manager. The Plugin Manager is not the only route: the CLI installs
the database directly with `lungfish esviritu download-db`, which takes
`--force` to re-download over an existing copy. The tool binary itself
installs through conda (`lungfish conda install esviritu`).

## Procedure

The walkthrough below classifies SRR36291587, a SARS-CoV-2 amplicon run,
and reads the result viewport. SRR36291587 is one of the public SRA
accessions used elsewhere in this manual, downloaded through **Search
NCBI/SRA** as in Chapter 3.4.

1. In the project sidebar, select the FASTQ pair for SRR36291587 under
   `Imports/`.
2. Open **Tools > FASTQ/FASTA Operations > Classification…** and choose
   **EsViritu** in the wizard's tool picker.
   <!-- planned: esviritu-wizard-tool-step -->
3. Confirm the **Inputs** step lists both paired reads and that their
   combined size matches the sidebar. If only one mate shows, click
   **Add second mate** and pick the partner file.
4. Move to the **Database** step. The picker should read
   **EsViritu (installed)** with a version string and an install date. If
   it reads **Not installed**, follow the database-install procedure
   above before continuing.
5. On the **Options** step, keep the defaults for a first run. EsViritu
   exposes two controls here: **Min Read Length** (default 100 nt), which
   drops reads below the threshold before alignment, and a quality-filter
   toggle, which runs the built-in read-quality screen. There is no
   minimum-breadth or minimum-read-count field. An **Advanced Settings**
   disclosure adds a **Threads** stepper (1 to the machine's core count)
   and an **Extra arguments** field that passes flags straight through to
   EsViritu. Click **Run**.

The wizard closes and an EsViritu row appears in the Operations Panel.
For SRR36291587 on an M-series laptop the run takes roughly 4 to 8
minutes, and the Panel reports each phase (database load, mapping, coverage
summarisation, report rendering) as it completes.

The same run is available headless as `lungfish esviritu detect --input
<fastq> --sample <name>`, with `--paired` for paired reads, `--db` to point
at a specific database, `--min-read-length` (default 100), `--no-qc` to skip
the quality screen, `--extra-args` to pass options straight through to
EsViritu, and `--output` (or `-o`) to set the result directory (it defaults
to `esviritu-<sample>` beside the input). The FASTQ goes behind `--input`
(or `-i`), never as a bare positional argument.

## Batch runs

Select FASTQ for more than one sample and the wizard switches to batch mode.
It replaces the sample-name field with a list of the grouped samples, each
tagged paired-end (PE) or single-end (SE), and runs EsViritu once per sample
against the same database and settings.

A batch finishes as a single aggregated result rather than one viewport per
sample. The detection table pools every sample's hits, and a sample picker
in the Inspector filters the rows down to the samples you want to compare.
Because unique read counts are tracked per sample, batch mode adds a
**Recompute Unique Reads** button to the action bar that recounts them from
each sample's BAM when a stored value is missing.

## Interpretation

When the run finishes, double-click the new classification result in the
sidebar to open the EsViritu viewport.

### The virus table and coverage sparklines

The viewport's main pane is a sortable virus table. Each row is one
reference genome from the EsViritu database that drew reads, with columns
for accession, organism, read count, unique read count, RPKMF (reads per
kilobase of reference per million reads, a length-normalised abundance
measure), and coverage, the percent breadth of the reference covered. A
coverage sparkline rides alongside each row: a small horizontal track
plotting depth across the reference from left (5' end of the genome) to
right (3' end). Segmented viruses also get a segment-completeness grid
showing how many of the expected segments turned up.

<!-- planned: esviritu-result-viewport -->

Read the sparkline before the numbers. A flat, evenly-shaded track means
the reads tile the genome end to end, the signature of a real, abundant
infection. A track with two or three tall spikes and long flat valleys
means the reads pile onto a few short windows, which often points to one of
three things: an off-target amplicon, a conserved region shared with a
related virus, or a host sequence that happens to share homology with the
reference. The numeric coverage column puts a figure to the same intuition:
95% breadth on a 30 kb genome leaves only 1.5 kb uncovered and is a strong
call; 12% breadth across scattered windows is not.

For SRR36291587 the top row should report the SARS-CoV-2 reference
(NC_045512.2 or a close MT-prefixed accession, depending on database
build), with a mostly-flat sparkline, several thousand reads mapped, and
breadth in the high 90s. The rows below usually carry a few low-confidence
hits to related betacoronaviruses, which the coverage column shows as
single-digit percentages and the sparkline as one thin spike.

### Looking up and verifying a row

Right-click a virus row to act on it. The context menu offers
**Extract Reads…** (writes the reads that aligned to that reference as a
new FASTQ bundle), **BLAST Verify…** (submits a sample of those reads to
NCBI BLAST for an independent second opinion, covered in
[BLAST Verification](06-blast-verification.md)), and a **Look Up on NCBI**
submenu that opens the matching GenBank accession, assembly record, PubMed
literature, or Taxonomy Browser page in your web browser. These are the
fastest routes from a coverage call to a confirmation.

### Full BAM evidence viewer

To audit a single sparkline directly, click a virus row that carries
alignment data. The full alignment viewer appears in the detail pane on its
own. There is no separate "Show reads" button; selecting the row is enough.
It opens the real, indexed BAM saved alongside the classification result,
using the same pileup renderer, ruler, pan and zoom controls, read packing,
MAPQ and flag filters, and selected-read details as the general BAM viewer.
EsViritu evidence is reference-free, so reference-dependent mismatch,
consensus, variant, and reference-export controls are unavailable and the
Inspector explains why.

<!-- planned: esviritu-bam-viewer -->

The BAM evidence is the source of truth for everything above it in the
viewport. If the row claims 2,400 reads and the BAM viewer shows a thick,
evenly-spread pile, the call is real. If it claims 2,400 reads and the BAM
viewer shows a single tall stack at one position, you are looking at PCR
duplicates of one fragment, and the apparent depth is inflated. Flag the
row as low-confidence whatever the coverage column says.

Use **Import Metadata…** in the Inspector to attach a CSV or TSV sample
sheet. Choose the sample-identity column during import. Every other valid
field becomes available immediately in the table's column chooser; fields
without a value for a row display an em dash. The same columns remain
available after you close and reopen the result.

### Exporting and provenance

The viewport's bottom action bar carries two more controls. **Export**
writes every detection to a CSV or TSV file through a save panel, one row
per contig with its accession, taxonomy, read count, RPKMF, coverage, and
identity columns. **Provenance** opens a popover recording the run's tool
version, runtime, and database, the audit trail behind the numbers above.

## What to do next

Once you trust an EsViritu hit, the usual next steps are to confirm the
identification with a small BLAST query against NCBI nt
([Chapter 6.6](06-blast-verification.md)), or to map the same reads
against the matched reference and call variants when you want lineage-level
assignment beyond the EsViritu strain label
([Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md)).

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md) for
clinical-surveillance classification, or [BLAST Verification](06-blast-verification.md)
to confirm an EsViritu hit.
