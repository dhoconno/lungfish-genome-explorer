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
shots: []
planned_shots:
  - id: sra-search-results
    caption: "The SRA search dialog showing search results with run accessions."
  - id: sra-operations-record
    caption: "The Operations Panel row for an SRA download, with the provenance disclosure expanded."
illustrations: []
glossary_refs: [SRA, ENA, FASTQ]
features_refs: [fetch.sra]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The NCBI Sequence Read Archive (SRA) is the public repository for raw
sequencing reads. If a paper reports new sequencing data, the reads are
almost always in SRA, identified by an accession that starts with `SRR`,
`ERR`, or `DRR` (the leading letter indicates which of the three
International Nucleotide Sequence Database Collaboration mirrors deposited
the data first; the data itself is mirrored across all three).

SRA uses four accession types that nest. A **run** (`SRR…`) is one
sequencing run on one library. An **experiment** (`SRX…`) groups runs that
share the same library and platform. A **sample** (`SRS…`) is the biological
material that was sequenced. A **project** (`SRP…`, sometimes written as a
BioProject `PRJNA…`) groups every experiment in one study. Lungfish
downloads at the run level, because runs are what produce FASTQ files.

Lungfish reaches the archive through `Tools > Search Online Databases >
Search SRA`. You can paste a run accession or search by free text (organism,
study, author). The dialog auto-detects whether the run is single-end or
paired-end from its metadata and writes the resulting FASTQs to the
project's `Downloads/` folder, alongside a provenance sidecar that records
which mirror served the data and how. **So what should you do with this?**
When you want to reproduce a published analysis, or pull a known sample for
testing a workflow, get its SRR accession and use this dialog rather than
downloading from a browser.

## What you will learn

By the end of this chapter you will be able to download a single SRA run by
accession, search SRA by free-text query, recognize when Lungfish has
fallen back from ENA to the SRA Toolkit by reading the Operations Panel
provenance disclosure, and locate the resulting FASTQs in the project's
`Downloads/` folder ready for the next step.

## Procedure

This chapter covers two tasks: searching the SRA for runs that match a query
and downloading a specific run by accession. Both run through the same
dialog.

### Search the SRA

1. Open the project you want the reads to land in. Downloads always go into
   the project's `Downloads/` folder, so the active project picks the
   destination.
2. Choose `Tools > Search Online Databases > Search SRA`. The search dialog
   opens with a single query field at the top.
3. Type a query and press Return. An accession (`SRR36291587`) returns one
   row. A free-text query (`SARS-CoV-2 wastewater Madison`) returns up to
   the first 200 matching runs, ordered by SRA's relevance score.
4. Read the results table. Each row shows the run accession, the parent
   study, the sample name, the library layout (single or paired), the
   library strategy (WGS, AMPLICON, RNA-Seq, and so on), the platform
   (Illumina, Oxford Nanopore, PacBio), and the size in bases.
5. Sort or filter to find the run you want. Click a column header to sort.
   Use the filter chips above the table to restrict by platform or layout
   when a query returns many candidates.

<!-- planned: sra-search-results -->

### Download a run

1. Select one or more rows in the results table. The Download button
   activates as soon as a row is selected.
2. Confirm the **Layout** dropdown reads **Auto-detect (recommended)**.
   Auto-detect uses the run's SRA metadata to choose between single-end and
   paired-end output. Override only if you know the metadata is wrong, which
   is rare but does happen for older deposits.
3. Click **Download**. The dialog closes and the Operations Panel
   ([Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md))
   opens a new row for the download.
4. Wait for the row to reach `Completed`. A 1 Gbase paired Illumina run is
   typically 1 to 5 minutes from ENA and 5 to 20 minutes from the SRA
   Toolkit fallback, network depending.
5. Open the project sidebar's `Downloads/` folder. Single-end runs land as
   `<accession>.fastq.gz`. Paired runs land as `<accession>_1.fastq.gz` and
   `<accession>_2.fastq.gz`, matching the convention every downstream tool
   in Lungfish expects.

<!-- planned: sra-operations-record -->

### Worked example: SRR36291587

The SARS-CoV-2 sample used in the variant-calling chapter has accession
`SRR36291587`. To pull it:

1. Open or create a project. The variant chapter assumes a project named
   `pilot-variants/`, so use that name if you plan to follow that chapter
   next.
2. Choose `Tools > Search Online Databases > Search SRA`, paste
   `SRR36291587`, and press Return.
3. The single result row reports a paired-end Illumina run, library strategy
   AMPLICON, roughly 0.5 Gbases. Select it and click **Download** with
   layout set to Auto-detect.
4. When the Operations Panel row turns green, the project's `Downloads/`
   folder contains `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`.
   These are the files [Quality Control](03-quality-control.md) and the
   variant chapter both expect.

The same download from the CLI:

```sh
lungfish fetch sra download SRR36291587 --output-dir Downloads
```

The CLI writes the FASTQs and the provenance sidecar to the same folder the
GUI uses; the two paths are interchangeable.

## Interpretation

### What the Operations Panel row tells you

Every SRA download produces one row in the Operations Panel. The row's
provenance disclosure (the small triangle on the left) expands to show the
record Lungfish kept of the download. The most important field is the
**source URL**: it begins with `https://ftp.sra.ebi.ac.uk/` when ENA served
the data, and with `https://sra-download.ncbi.nlm.nih.gov/` (or shows the
`prefetch` and `fasterq-dump` invocations) when the SRA Toolkit fallback
fired. The field exists so a co-author or reviewer can confirm later which
mirror produced the bytes you analysed. See
[Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md)
for the full sidecar schema and how to export a methods paragraph from it.

### Which path served your download

Lungfish prefers ENA and falls back to the NCBI SRA Toolkit when ENA refuses
or times out. The two paths produce equivalent FASTQs but differ in speed
and machinery. The table below summarises when each fires.

| Aspect | ENA (preferred) | NCBI SRA Toolkit (fallback) |
|---|---|---|
| What you get | Pre-converted FASTQ over HTTPS | `.sra` archive, then converted locally |
| Tools involved | `curl` plus checksum verify | `prefetch` then `fasterq-dump` |
| Typical speed | Fast, often network-limited | Slower, conversion-limited |
| When it fires | First attempt for every accession | ENA returns 404, 403, or times out |
| Provenance field | `source: ena` | `source: sra-toolkit` |

ENA hosts FASTQs directly because European archives chose to keep the
converted form alongside the deposit. NCBI holds the same data as `.sra`
archives and requires a conversion step on download. Newly-released runs are
sometimes only on NCBI for the first few hours; very old runs are sometimes
only on ENA. The fallback exists so that either case still produces a file.

### Reading the Downloads folder

After a successful download you should see, for a paired run, two
gzip-compressed FASTQs and one provenance sidecar:

```text
Downloads/
  SRR36291587_1.fastq.gz
  SRR36291587_2.fastq.gz
  SRR36291587.provenance.json
```

The `_1` and `_2` suffixes are the convention every downstream Lungfish
operation expects. Renaming them breaks pair detection. The
`.provenance.json` sidecar travels with the FASTQs: copy or move it
alongside the reads if you reorganise the folder.

### Troubleshooting

A download can fail or look wrong in three common ways.

**Rate limits.** ENA and NCBI both throttle anonymous downloads when many
requests come from the same network. The symptom is a download that starts,
runs slowly, and ends with a partial file or an HTTP 429 in the operation
log. Wait a few minutes and click **Retry** on the Operations Panel row.
Lungfish resumes from the last byte received when the server supports range
requests, so a retry is usually fast.

**Network failures mid-download.** A flaky connection produces a partial
file. Lungfish detects the size mismatch, marks the row `Failed`, and
preserves the partial file under `Downloads/.partial/` so it can resume.
Retry from the same Operations Panel row. If the failure persists across
several retries, the SRA Toolkit fallback often succeeds where direct ENA
fails, because the Toolkit uses a different transport.

**"Metadata says single but the file has two reads."** A small fraction of
older SRA deposits were tagged as single-end in metadata even though the
underlying data is paired. Auto-detect trusts the metadata, so you may end
up with one interleaved FASTQ where you expected two files. The fix is to
re-run the download with the **Layout** dropdown forced to **Paired**. If in
doubt, the run page on NCBI's web SRA viewer shows the actual spot layout
under "Layout" and confirms which is correct.

## Next

Continue to [Quality Control](03-quality-control.md) to inspect the QC
profile of the reads you just downloaded.
