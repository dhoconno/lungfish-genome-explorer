---
title: Downloading Reads from the SRA
chapter_id: 03-reads/02-downloading-from-sra
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 8
task: Download sequencing reads from the NCBI SRA by run accession.
tags: [reads, sra, ena, download, fastq]
tools: []
entry_points:
  - "Tools > Search Online Databases > Search SRA"
  - "CLI: lungfish fetch sra search, lungfish fetch sra download"
  - "CLI: lungfish fetch ena reads, lungfish fetch ena fasta"
shots: []
planned_shots:
  - id: sra-search-results
    caption: "The SRA search dialog showing search results with run accessions."
  - id: sra-operations-record
    caption: "The Operations Panel row for an SRA download, with the provenance disclosure expanded."
illustrations: []
glossary_refs: [SRA, ENA, FASTQ]
features_refs: [fetch.sra, fetch.ena]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about fetching reads from a public archive by accession. To import FASTQ files you already have on disk, see [Importing FASTQ](01-importing-fastq.md).

The NCBI Sequence Read Archive (SRA) is the public warehouse for raw
sequencing reads. When a paper reports new sequencing data, the reads are
almost always in SRA, tagged with an accession that opens with `SRR`,
`ERR`, or `DRR`. That leading letter tells you which of the three
International Nucleotide Sequence Database Collaboration mirrors deposited
the data first. The data itself sits on all three.

SRA nests four accession types. A **run** (`SRR…`) is a single
sequencing run on one library. An **experiment** (`SRX…`) gathers runs that
share a library and platform. A **sample** (`SRS…`) is the biological
material that was sequenced. A **project** (`SRP…`, sometimes written as a
BioProject `PRJNA…`) gathers every experiment in one study. Lungfish
downloads at the run level, because runs are what produce FASTQ files.

Lungfish reaches the archive through `Tools > Search Online Databases >
Search SRA`. Paste a run accession, or search by free text: organism,
study, author. The dialog reads the run's metadata to tell single-end from
paired-end, then writes the FASTQs to the project's `Downloads/` folder next
to a provenance sidecar that records which source served the data and how.
Lungfish prefers ENA, the European Nucleotide Archive, EMBL-EBI's mirror of
the SRA, because ENA serves ready-made FASTQs. It falls back to NCBI's SRA
Toolkit when ENA is out of reach. So when you set out to reproduce a published
analysis, or to pull a known sample for testing a workflow, find its SRR
accession and use this dialog rather than a browser download: the dialog
records provenance a browser never will.

## What you will learn

This chapter shows you how to download a single SRA run by
accession, search SRA with a free-text query, recognise when Lungfish has
fallen back from ENA to the SRA Toolkit by reading the Operations Panel
provenance disclosure, and find the resulting FASTQs in the project's
`Downloads/` folder, ready for the next step.

## Procedure

There are two tasks here: searching the SRA for runs that match a query,
and downloading a specific run by accession. Both run through the same
dialog.

### Search the SRA

1. Open the project you want the reads to land in. Downloads always go into
   the project's `Downloads/` folder, so the active project picks the
   destination.
2. Choose `Tools > Search Online Databases > Search SRA`. The search dialog
   opens with a single query field at the top.
3. Type a query and press Return. An accession like `SRR36291587` returns a
   single row. A free-text query like `SARS-CoV-2 wastewater Madison` returns
   a page of matching runs, ordered by SRA's relevance score. The command-line
   search, `lungfish fetch sra search`, caps results at `--limit 20` by
   default; raise it when a broad query truncates.
4. Read the results table. Each row shows the run accession, the parent
   study, the sample name, the library layout of single or paired, the
   library strategy such as WGS, AMPLICON, or RNA-Seq, the platform of
   Illumina, Oxford Nanopore, or PacBio, and the size in bases.
5. Sort or filter to find the run you want. Click a column header to sort.
   Use the filter chips above the table to restrict by platform or layout
   when a query returns many candidates.

When you already hold a list of run IDs, skip the free-text search. The SRA
Runs pane's **Import Accessions** button loads a CSV or plain-text file of
accessions in one step: Lungfish runs the whole list as a single query and
fills the results table with those runs, so you can select and download the
batch at once.

<!-- planned: sra-search-results -->

### Download a run

1. Select one or more rows in the results table. The Download button
   activates as soon as a row is selected.
2. Confirm the **Layout** dropdown reads **Auto-detect (recommended)**.
   Auto-detect leans on the run's SRA metadata to choose single-end or
   paired-end output. Override it only when you know the metadata is wrong,
   which is rare but does happen with older deposits.
3. Click **Download**. The dialog closes and the Operations Panel
   ([Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md))
   opens a new row for the download.
4. Wait for the row to reach `Completed`. A 1 Gbase paired Illumina run
   typically takes 1 to 5 minutes from ENA and 5 to 20 minutes from the SRA
   Toolkit fallback, network depending.
5. Open the project sidebar's `Downloads/` folder. Single-end runs land as
   `<accession>.fastq.gz`. Paired runs land as `<accession>_1.fastq.gz` and
   `<accession>_2.fastq.gz`, matching the convention every downstream tool
   in Lungfish expects.

<!-- planned: sra-operations-record -->

### Worked example: SRR36291587

The SARS-CoV-2 sample used in the variant-calling chapter carries accession
`SRR36291587`. Pull it in four moves. First, open or create a project; the
variant chapter assumes one named `pilot-variants/`, so use that name
if you plan to follow it next. Then choose
`Tools > Search Online Databases > Search SRA`, paste `SRR36291587`, and
press Return. The single result row reports a paired-end Illumina run,
library strategy AMPLICON, roughly 0.5 Gbases; select it and click
**Download** with layout set to Auto-detect. When the Operations
Panel row turns green, the project's `Downloads/` folder holds
`SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`. These are the files
[Quality Control](03-quality-control.md) and the variant chapter both expect.

The same download from the CLI:

```sh
lungfish fetch sra download SRR36291587 --output-dir Downloads
```

The CLI writes the FASTQs and the provenance sidecar to the same folder the
GUI uses; the two paths are interchangeable. By default it pulls from ENA. Add
`--use-toolkit` to force the NCBI SRA Toolkit path, `prefetch` then
`fasterq-dump`, which is now and then the only way to fetch a run
ENA has not yet mirrored.

To read a run's metadata without downloading a byte, `lungfish fetch sra info
<accession>` prints one record:

```sh
lungfish fetch sra info SRR36291587
```

It reports the Experiment, Study, BioProject, and BioSample the run belongs to,
its Organism, Platform, Strategy, Source, and Layout, and the Reads, Bases, and
Size totals. Add `--api-key` to lift the NCBI rate ceiling, and `--format json`
to emit the same fields as structured output for a script.

## Fetching from ENA directly

The download path above resolves through ENA on its own, so most people never
call the archive by name. When you do want to reach the European Nucleotide
Archive directly, say to see the exact FASTQ URLs behind a run or to
pull a reference sequence ENA holds, `lungfish fetch ena` opens it up through
three subcommands: `search`, `reads`, and `fasta`.

`lungfish fetch ena search <query>` looks up sequences by free text and prints
a table of matching accessions with each record's title, organism, and length:

```sh
lungfish fetch ena search "Ebola virus" --organism "Zaire ebolavirus"
```

Narrow a broad query with `--organism` to filter by species, and raise
`--limit` when the default of 20 rows truncates the list. Pass `--format json`
for the same fields as structured output. The same `--limit` bounds
`fetch ena reads` below.

`lungfish fetch ena reads <accession>` looks up a run or study accession and
prints its metadata, platform, library strategy, layout, read count, and file
size, alongside the exact ENA FASTQ download URLs:

```sh
lungfish fetch ena reads SRR36291587
```

This resolves the URLs; it does not pull the bytes. To download and checksum the
reads with a provenance sidecar, use `lungfish fetch sra download`, covered
above, which prefers those same ENA URLs and falls back to the SRA Toolkit.
The `fetch ena` subcommands write no provenance sidecar of their own, so
treat them as a lookup and inspection tool, not the recorded download step.

`lungfish fetch ena fasta <accession> --save-to <path>` fetches a sequence
rather than reads, in FASTA form, handy on the odd occasion when ENA holds a
record NCBI has not mirrored. For reference sequences that need annotations,
prefer the NCBI path in
[Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md); the ENA
FASTA carries bases only. In short: use `fetch ena reads` to see what ENA
will serve for a run, and `fetch sra download` to pull the reads with
provenance.

## Interpretation

### What the Operations Panel row tells you

Every SRA download drops one row into the Operations Panel. The small triangle
on its left expands the provenance disclosure, the record Lungfish kept of the
download. Its most useful line is which source produced the bytes: an ENA
download records an EBI host, while the SRA Toolkit fallback records the
`prefetch` and `fasterq-dump` commands it ran. The record is there so a
co-author or reviewer can confirm later which path produced the bytes you
analysed. See
[Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md)
for the full sidecar schema and how to export a methods paragraph from it.

### Which path served your download

Lungfish prefers ENA and falls back to the NCBI SRA Toolkit when ENA refuses
or times out. The two paths produce equivalent FASTQs but differ in speed
and in the machinery underneath. The table below sums up when each one fires.

| Aspect | ENA (preferred) | NCBI SRA Toolkit (fallback) |
|---|---|---|
| What you get | Pre-converted FASTQ over HTTPS | `.sra` archive, then converted locally |
| Tools involved | Direct HTTPS fetch plus checksum verify | `prefetch` then `fasterq-dump` |
| Typical speed | Fast, often network-limited | Slower, conversion-limited |
| When it fires | First attempt for every accession | ENA refuses or times out, or `--use-toolkit` is set |
| How to force it | Default | `lungfish fetch sra download --use-toolkit` |

ENA hosts FASTQs directly because the European archives chose to keep the
converted form beside the deposit. NCBI holds the same data as `.sra`
archives and asks for a conversion step on download. A newly released run is
sometimes on NCBI alone for its first few hours; a very old run is sometimes
on ENA alone. The fallback exists so either case still ends in a file.

### Reading the Downloads folder

After a clean download of a paired run, you should see two
gzip-compressed FASTQs plus a provenance sidecar written beside them.
The command-line download names each sidecar
`<file>.lungfish-provenance.json`:

```text
Downloads/
  SRR36291587_1.fastq.gz
  SRR36291587_2.fastq.gz
  SRR36291587_1.fastq.gz.lungfish-provenance.json
```

The `_1` and `_2` suffixes are the convention every downstream Lungfish
operation expects. Rename them and pair detection breaks. The provenance
sidecar travels with the FASTQs, so copy or move it beside the reads whenever
you reorganise the folder.

### Troubleshooting

A download can fail or look wrong in three common ways.

**Rate limits.** ENA and NCBI both throttle anonymous requests when too many
arrive from one network. The symptom is a download that starts, crawls,
and ends in a partial file or an HTTP 429 in the operation log.
Wait a few minutes and click **Retry** on the Operations Panel row. For the
command-line search, an NCBI API key lifts your rate ceiling: pass it with
`lungfish fetch sra search --api-key <key>`, and grab a free key from your NCBI
account settings.

**Network failures mid-download.** A flaky connection leaves a partial
file. Lungfish marks the row `Failed`; retry from the same Operations Panel
row. When the failure survives several retries, the SRA Toolkit fallback,
`--use-toolkit`, often succeeds where direct ENA fails, because the Toolkit
moves the bytes over a different transport.

**"Metadata says single but the file has two reads."** A small share of
older SRA deposits were tagged single-end in metadata even though the
data underneath is paired. Auto-detect trusts the metadata, so you can end
up with one interleaved FASTQ where you expected two files. Interleaved means
read 1 and read 2 alternate inside a single file instead of living in two
separate ones. The fix is to re-run the download with the **Layout**
dropdown forced to **Paired**. When in doubt, the run page on NCBI's web SRA
viewer shows the actual spot layout under "Layout" and settles which is
right.

## Next

Continue to [Quality Control](03-quality-control.md) to inspect the QC
profile of the reads you just pulled down.
