---
title: Novel Virus Diagnostics
chapter_id: 06-classification/09-novel-virus-detection
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 7
task: Import Novel Virus Diagnostics (NVD) pipeline results and read the contig-keyed BLAST viewport.
tags: [classification, nvd, novel-virus, blast, import, wastewater]
tools: [nvd]
entry_points:
  - "Import Center: Classification Results > NVD Results"
  - "CLI: lungfish nvd import, lungfish nvd summary"
shots: []
planned_shots:
  - id: nvd-import-card
    caption: "The Import Center card for NVD Results under Classification Results."
  - id: nvd-result-viewport
    caption: "The NVD viewport: a contig row expanded to show its secondary BLAST hits, with the detail pane and full BAM viewer on the left."
illustrations: []
glossary_refs: [contig, BLAST, e-value, percent identity]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Novel Virus Diagnostics (NVD) reaches the same goal as a classifier by a
different road. Rather than assigning short reads to a database one at a time,
the NVD pipeline stitches reads into longer contigs and BLASTs each contig
against a nucleotide database. A contig is a long, assembled stretch of
sequence, so a single BLAST hit on a contig carries far more signal than a hit
on one 150-base read. That is what makes NVD a discovery tool: a contig that
only partly matches a known virus, or matches it at low identity, is exactly
the signature of something the read-level classifiers would have placed too
confidently or missed.

NVD is an external Snakemake pipeline built for wastewater viral surveillance,
and Lungfish does not run it. It imports the pipeline's output, the same way it
imports CZ-ID and NAO-MGS results. What Lungfish adds on top of the raw BLAST
table is a browsable viewport: each contig becomes a row showing its best BLAST
hit, and you can expand a row to see the secondary hits the pipeline ranked
below it. The pipeline's main output file is named `*_blast_concatenated.csv`
(or `.csv.gz`), and the importer reads it from the run's `05_labkey_bundling/`
folder.

The mental model is contigs first, taxa second. Where a Kraken2 sunburst is
keyed by taxon, the NVD viewport is keyed by contig. You are reading "this
assembled sequence best matches that virus, and here is how good the match is,"
the right framing when the interesting cases are the imperfect matches.

In practice, when an NVD run finishes, import its output into your project and
read the contigs whose best hit is partial or low identity first. Those are the
candidate novel or divergent viruses the pipeline exists to surface.

## What you will learn

You will come away able to import NVD results from the
Import Center or the command line, read the contig-keyed viewport and its
secondary hits, group results by sample or by taxon, and verify a contig with
BLAST.

## How NVD differs from the read classifiers

NVD answers a discovery question the read-level tools handle less directly. The
table below sets it beside the runnable classifiers and the other import-only
tools in this part.

| Tool | Unit of analysis | Best at | Runs in Lungfish? |
|---|---|---|---|
| Kraken2 | Per read (k-mer) | Broad survey of a sample | Yes |
| EsViritu | Per read (alignment) | Calling a known virus to strain level | Yes |
| NAO-MGS | Per taxon (imported) | Reviewing an external wastewater run | No, import only |
| NVD | Per contig (assembled, BLASTed) | Flagging novel or divergent viruses | No, import only |

The contig unit is the distinction that matters. Because NVD works on assembled
sequence, a near-miss against a known reference is signal rather than noise,
which is exactly what novel-virus surveillance needs.

## Procedure: import an NVD run

1. Choose **File > Import Center…**, open the **Classification Results** tab,
   and pick the **NVD Results** card. The standalone NVD import sheet reaches
   the same importer.
   <!-- planned: nvd-import-card -->

2. Click **Choose** and select the NVD results directory. The importer expects
   the run to hold a `05_labkey_bundling/` folder containing the
   `*_blast_concatenated.csv(.gz)` file, and it locates that file for you.

3. Click **Import**. Lungfish parses the BLAST hits, builds the per-contig
   rankings, copies the result into the project, and writes a provenance
   record. The result then appears in the sidebar.

4. Double-click the result to open the NVD viewport.

The same import runs headless, the form to script from a scheduled job:

```bash
lungfish nvd import /path/to/nvd-output/ --output-dir ./project/Imports/
```

The argument is the results directory. `--output-dir` (`-o`) chooses where the
imported bundle lands, and `--name` overrides the bundle name, which defaults
to `nvd-<experiment>`. The Import-command family also offers `lungfish import
nvd`, which behaves the same way.

To inspect a run before importing, summarise the top contigs without writing
anything. The summary takes either the run directory or a single
`*_blast_concatenated.csv(.gz)` file:

```bash
lungfish nvd summary /path/to/100_blast_concatenated.csv.gz --top 20
```

`--top` sets how many contigs the table shows and defaults to 20. Add
`--format json` or `--format tsv` to emit the same summary as machine-readable
JSON or TSV for a downstream script.

## Interpretation: reading the contig viewport

The viewport is a contig-keyed BLAST browser. A summary bar across the top
reports the experiment, the sample count, and the total number of contigs.
Below it, a detail pane sits on the left and an outline list of contigs on the
right.

<!-- planned: nvd-result-viewport -->

Each top-level row is one contig, showing its best BLAST hit. The columns
include the **Sample** and **Contig** identifiers, the contig **Length**, the
hit's **Classification** and **Rank**, the subject **Accession** and its **Subject**
title, **Identity %**, **E-value**, **Bit Score**, **Aln Length**, the length of
the BLAST alignment, and read counts: **Mapped Reads**, **Unique Reads**, and
**RPB**, reads per billion, a depth-normalised abundance. Expand a contig row to see the
secondary BLAST hits the pipeline ranked below the best one. That is how you
judge whether a call is clean, one strong hit with a large gap to the next, or
ambiguous, several near-equal hits to different organisms.

A grouping control switches the outline between **By Sample**, a flat contig
list, and **By Taxon**, contigs gathered under the organism their best hit
names. By Sample is the view for walking one run's contigs. By Taxon is
the view when you want every contig that matched a given virus in one place.

Two more controls sit in the outline's filter bar. A sample-filter button,
labelled with the current sample count, opens a popover for narrowing the
outline to chosen samples, and a **Search contigs…** field filters the rows by
contig or hit text as you type.

Sort by **Identity %** ascending to float the partial and divergent matches
to the top. A contig whose best hit is a high-identity, full-length match to a
known virus is the routine case. A long contig whose best hit is only
70% identity, or covers only part of its length, is the candidate the pipeline
exists to find, and the row to verify next.

Selecting a contig fills the detail pane. For a contig with alignment data,
the pane includes the full BAM viewer showing the reads that built it. It uses
the same ruler, navigation, read packing, MAPQ and flag filters, coverage
statistics, and selected-read details as the general alignment viewport. When
the imported NVD reference record validates against the BAM, reference-aware
mismatch and consensus inspection is available; otherwise the Inspector
labels the evidence as reference-free. Use the pileup to check whether a deep,
even distribution supports the contig or a thin stack may be an assembly
artifact.

Use **Import Metadata…** in the Inspector to attach CSV or TSV sample
metadata. Every valid non-identity field becomes selectable in the result
table's column chooser immediately and remains available when the result is
reopened. Missing values display an em dash rather than removing the column.

To get an independent opinion on a contig, click **BLAST Verify** in the
viewport's action bar. The verification submits the contig sequence to NCBI
BLAST and returns a verdict, the same flow described in
[BLAST Verification](06-blast-verification.md). The action bar's **Export**
button writes the displayed results out for downstream use, and its
**Extract FASTQ** button pulls the reads behind the selected contigs into a
fresh FASTQ dataset through the shared extraction dialog.

Right-clicking a contig row opens a fuller set of per-contig actions.
**Extract Reads…** reaches the same extraction dialog, while
**Extract Sequence…**, **Verify with BLAST…**, **Copy FASTA**,
**Export FASTA…**, **Create Bundle…**, and **Run Operation…** act on the
contig's own sequence. The rest are lookups: **Copy Contig Name** and
**Copy Accession** place those identifiers on the clipboard, and
**View Accession on NCBI** and **Search PubMed** open the subject accession or
its organism name in a browser.

The provenance record for the import is reachable from the Inspector and names
the source directory, the importing command, and the input checksums, so a
methods export cites the external NVD run and the Lungfish import as two
auditable steps.

## Next

Return to [What Is Read Classification](01-what-is-classification.md) to choose
among the runnable classifiers, or to [Importing CZ-ID Results](08-importing-cz-id-results.md)
and [Importing NAO-MGS Results](05-running-nao-mgs.md) for the other import
paths.
