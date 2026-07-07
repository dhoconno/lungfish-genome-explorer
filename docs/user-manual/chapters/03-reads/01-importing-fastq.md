---
title: Importing FASTQ Reads
chapter_id: 03-reads/01-importing-fastq
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 8
task: Import FASTQ files into a Lungfish project, including paired-end pairing and batch import.
tags: [reads, fastq, import, paired-end, batch]
tools: []
entry_points:
  - "Import Center (Cmd-Shift-I) > Sequencing Reads > FASTQ Files"
  - "Drag-drop into the sidebar"
  - "CLI: lungfish import-fastq"
shots: []
planned_shots:
  - id: import-center-fastq
    caption: "The Import Center Sequencing Reads tab with the FASTQ Files tile and paired files auto-detected."
  - id: sidebar-after-import
    caption: "The sidebar after a paired-end import, showing the new bundle under Imports."
  - id: fastq-viewport-sparklines
    caption: "The FASTQ viewport showing per-file QC sparklines and the metadata drawer."
  - id: inspector-sample-metadata
    caption: "The Inspector with sample metadata fields editable for a selected FASTQ bundle."
illustrations: []
glossary_refs: [FASTQ, paired-end, single-end, project, sidebar, inspector, provenance]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter covers importing FASTQ files that already live on disk. To pull reads from a public archive instead, see [Downloading from SRA](02-downloading-from-sra.md); to import an Oxford Nanopore run directory, see [Oxford Nanopore Runs](07-ont-runs.md).

Lungfish imports FASTQ files into a project so that every downstream step (QC, trimming, mapping, classification, assembly, variant calling) has a stable, named input to work from. An import is not a copy step alone. It is the moment Lungfish records where the file came from, computes a checksum, and creates a FASTQ bundle that the rest of the project can reference by name.

There are three ways to import. You can drag one or more FASTQ files (or a folder of them) onto the project sidebar. You can open the Import Center with `Cmd-Shift-I`, choose the `Sequencing Reads` tab, click the `FASTQ Files` tile, pick files, and import. Or, from a script or terminal, you can run `lungfish import-fastq --project <path> ...`. All three paths produce the same on-disk result and write the same provenance record, so you can mix them freely across one project.

Lungfish recognizes paired-end Illumina data by filename. If two files share a sample stem and differ only in a `_1` / `_2` or `_R1` / `_R2` suffix, they are imported as one paired bundle. Single files (Nanopore reads, single-end Illumina, or one half of a pair whose mate is missing) are imported as single-end bundles. A folder containing many paired FASTQs is imported as one bundle per sample.

Import is the first deliberate, recorded step of your analysis. Every later command you run will name the bundle that import produced; if you bypass import and reference loose files, you lose checksums and provenance for the rest of the run. Treat it as the gate the whole project hangs off.

## What you will learn

By the end of this chapter you will be able to import a single FASTQ, import a paired-end pair and verify it was paired, import many FASTQs at once with batch import, find imported FASTQs in the sidebar, view per-file QC sparklines in the FASTQ viewport, and edit per-sample metadata in the Inspector.

## Pairing conventions Lungfish recognizes

Lungfish detects pairing from the filename alone. The table below lists the conventions it accepts. Anything outside this table is treated as single-end; if you have unusual filenames, rename before import.

| Pattern                       | Example                                | Treated as                       |
|-------------------------------|----------------------------------------|----------------------------------|
| `<stem>_1.fastq[.gz]` + `<stem>_2.fastq[.gz]` | `SRR36291587_1.fastq.gz`, `SRR36291587_2.fastq.gz` | Paired-end (Illumina, ENA style) |
| `<stem>_R1.fastq[.gz]` + `<stem>_R2.fastq[.gz]` | `Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz` | Paired-end (Illumina, vendor style) |
| `<stem>.fastq[.gz]` alone     | `barcode07.fastq.gz`                   | Single-end (Nanopore or single-end Illumina) |
| `<stem>_1.fastq.gz` alone (mate missing) | `SRR36291587_1.fastq.gz` only          | Single-end, with a warning       |
| Mixed case (`_r1`, `_R1`)     | `Sample_r1.fastq.gz`                   | Paired-end (case-insensitive match) |

The match is case-insensitive, so `_R1` and `_r1` both work. The compression suffix is optional; both `.fastq` and `.fastq.gz` are accepted, and Lungfish keeps the file in whichever form you imported it. If a file's mate is missing, the import dialog warns you before continuing so you can cancel and find the mate.

## Procedure: import a paired-end pair by drag-drop

The fastest path for one or two samples is drag-drop. The example below walks through importing the SARS-CoV-2 run `SRR36291587`, but the steps are the same for any pair.

1. Open or create a Lungfish project. The sidebar should show the five top-level folders (`Imports/`, `Downloads/`, `Reference Sequences/`, `Assemblies/`, `Primer Schemes/`).
2. In the Finder, locate `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`. Select both.
3. Drag the two files onto the `Imports/` row in the project sidebar. Release.

<!-- planned: import-center-fastq -->

4. The Import Center opens with the two files listed and a green "Paired" badge linking them. Confirm the sample name (Lungfish proposes the shared stem, here `SRR36291587`) and click Import.
5. Wait for the progress chip in the footer to clear. For two SARS-CoV-2 FASTQs this takes a few seconds; the time is dominated by checksumming, not copying.

<!-- planned: sidebar-after-import -->

When the operation finishes, a new bundle named `SRR36291587` appears under `Imports/` in the sidebar. Click it once to select it.

## Procedure: import the same pair with the Import Center

If you prefer a dialog over drag-drop, or if your files live behind a network share that drag-drop does not handle, use the Import Center.

1. Press `Cmd-Shift-I` to open the Import Center.
2. Choose the `Sequencing Reads` tab and click the `FASTQ Files` tile.
3. Select both `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz` in the file picker. The dialog detects the pair and shows them on one row with a "Paired" badge.
4. Optionally edit the sample name in the row before importing.
5. Confirm the import. The dialog closes and the new bundle appears in the sidebar.

The Import Center is also where you would import a single-end FASTQ (a Nanopore barcode, for example) or import several single-end files at once.

## Procedure: batch import a folder of paired samples

For a sequencing run that produced ten or more samples, importing pair-by-pair is tedious. Drop the whole folder instead.

1. In the Finder, identify a folder that contains your FASTQs. The folder may be flat (`Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz`, `Sample02_R1.fastq.gz`, ...) or have one subfolder per sample. Lungfish handles both layouts.
2. Drag the folder onto `Imports/` in the sidebar.
3. The Import Center opens with one row per detected sample and a "Paired" or "Single" badge per row. Review the list. Any unpaired file appears with a yellow warning so you can spot a missing mate.
4. Click Import All.

Lungfish creates one bundle per sample. A folder with ten paired samples produces ten bundles, each named for its shared stem. The provenance record for each bundle names the source folder and the exact two source files that landed in that bundle, so you can always trace a sample back to the run directory it came from.

## Procedure: batch import with a sample sheet

For paired Illumina runs with explicit sample metadata, use a CSV sample sheet instead of relying on filenames alone. The sheet must contain `sample`, `r1`, and `r2` columns. Any additional columns, such as `collection_date`, `batch_id`, `host`, or `operator`, are stored as bundle metadata for that sample.

```csv
sample,r1,r2,collection_date,batch_id
Alpha,Alpha_R1.fastq.gz,Alpha_R2.fastq.gz,2026-05-10,B42
Beta,/data/run/Beta_R1.fastq.gz,/data/run/Beta_R2.fastq.gz,2026-05-10,B42
```

Relative FASTQ paths are resolved next to the CSV file. In the Import Center, choose **Sequencing Reads > FASTQ Sample Sheet** and select the CSV. From the CLI, pass the sheet directly:

```sh
lungfish import fastq \
  --samplesheet samples.csv \
  --project ~/Projects/SARS-CoV-2-WW.lungfish \
  --platform illumina
```

The top-level alias `lungfish import-fastq --samplesheet samples.csv --project <project>` is equivalent and is kept for scripts written against older documentation.

Each row becomes one `.lungfishfastq` bundle. The provenance record for each bundle includes the sample-sheet path, checksum, file size, resolved R1/R2 paths, user-visible options and defaults, exit status, and wall time.

## Procedure: import from the command line

The CLI command takes the same paths and produces the same bundles as the GUI. Use it from scripts, from a remote shell, or when you want to log the exact import command in a lab notebook.

```sh
lungfish import fastq \
  SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
  --project ~/Projects/SARS-CoV-2-WW.lungfish \
  --platform illumina
```

For a folder of samples, pass the folder path; the CLI detects pairs the same way the GUI does. Run `lungfish import fastq --help` for the full option list.

Two CLI defaults change the stored bytes, so name them in a methods
record if bit-exact reproduction matters. `--quality-binning` defaults
to `illumina4`, which re-quantises each base quality into one of four
levels (the same scheme NovaSeq applies in hardware); pass
`--quality-binning eightLevel` for the eight-level scheme or
`--quality-binning none` to keep the original per-base scores.
`--compression` sets how hard Lungfish squeezes the output and takes
`fast`, `balanced`, or `maximum`, defaulting to `balanced`.
Storage-optimized read reordering is on by default; pass
`--no-optimize-storage` to keep the original read order. `--recipe` (one
of `vsp2`, `wgs`, `hifi`, `none`; default `none`) applies a packaged
processing pass at import, and `--dry-run` lists the pairs the CLI
detected without importing anything.

Three more flags shape which files the CLI picks up and whether it
repeats work. `--recursive`, off by default, walks a directory's
subfolders so a nested run layout imports in one call rather than one
folder at a time. `--force`, also off by default, reimports a sample even
when a bundle of that name already sits in the project, replacing the
earlier import instead of skipping it. `--log-dir <dir>` writes a
per-sample log file into the directory you name, which is worth turning
on for an unattended batch so a single failed sample leaves a trail you
can read afterward.

## The import configuration sheet

Every GUI import, by drag-drop or through the Import Center, opens a
configuration sheet before the copy begins. It confirms what Lungfish
detected and lets you override it. The **Platform** selector offers
seven choices: Illumina, Oxford Nanopore, PacBio, Element Biosciences,
Ultima Genomics, MGI / DNBSEQ, and Unknown / Other. Choosing Oxford
Nanopore forces single-end and drops quality binning to None, since
neither pairing nor Illumina-style binning applies to Nanopore reads.

Three more controls shape the bundle on disk. **Quality Binning** takes
Illumina 4-level, 8-level, or None (preserve original), defaulting to
4-level for Illumina, Element, and MGI and to None for the long-read
platforms. **Pairing** takes Single-end, Paired-end, or Interleaved.
**Compression** takes Fast, Balanced (the default), or Maximum. The
**Optimize storage** checkbox, on by default, reorders reads for tighter
compression; clear it to keep them in their original order.

The **Apply processing recipe after import** checkbox, off by default,
runs a packaged workflow on the reads as they land. The ONT
demultiplexing recipes, one splitting by Fluidigm sample barcodes and
one by PacBio barcode pairs, need two extra inputs before they can run: a
barcode sheet, a CSV, TSV, or text file of sample names and barcodes, and
a name for the demux output folder.

A FASTQ bundle can be virtual. Rather than holding a copied FASTQ, it
stores a derived manifest that names a root file and the operation to
apply, whether a read-ID subset, trim positions, or a full-payload copy.
The viewport previews from that manifest while heavier operations run
against the full file. To write a virtual or derived bundle back out as a
plain FASTQ, materialize it:

```sh
lungfish fastq materialize SampleA.lungfishfastq -o SampleA.fastq
```

Add `--temp-dir <dir>` to place intermediate files on a specific volume,
`--force` to overwrite an existing output, and `--compress` to gzip the
result.

## What gets recorded at import

An import is more than a copy. Lungfish does three things for every file you import.

1. It computes a checksum of the imported file so corruption can be detected later. A mismatch between the recorded checksum and the file on disk is how a later step proves the bytes did not change.
2. It writes a provenance record (file path, byte size, checksum, timestamp, host machine identity) into the bundle's `provenance/` subfolder. This is the import event itself, not a placeholder for QC.
3. It creates the bundle's manifest, which names the primary FASTQ files, the read pairing, and the bundle type.

Imports do **not** auto-run QC. The bundle exists, the files are in place, the metadata is recorded, but no per-base quality charts or adapter scans have happened yet. You invoke QC separately. See [Quality Control](03-quality-control.md) for the procedure.

## Interpretation: the FASTQ viewport

Click a FASTQ bundle in the sidebar. The main viewport switches to the FASTQ viewport, and the Inspector switches to the FASTQ metadata pane.

<!-- planned: fastq-viewport-sparklines -->

The viewport shows one row per file in the bundle (one row for single-end, two rows for paired-end). Each row carries a small sparkline summarising read length and a second sparkline summarising mean per-base quality across the file. These sparklines are a quick "does this look reasonable?" read, not a substitute for a full QC pass. A single-end Nanopore FASTQ will show a long-tailed length distribution; an Illumina FASTQ will show a near-vertical spike at the read length the run was configured for.

Below the sparklines, the metadata drawer shows the technical fields Lungfish read off the file: detected platform (Illumina vs Nanopore vs unknown, inferred from read header format), total read count, total base count, read length range, and the bundle's checksums.

If the sparklines look wrong (Q scores collapsing, length distribution unexpectedly wide), that is your prompt to run a full QC pass before going further. If they look reasonable, proceed to QC at your own pace.

## Interpretation: editing sample metadata

Technical fields (read count, length, checksum) are computed from the file and are not editable. Sample metadata (run accession, sample name, collection date, host or organism, free-text notes) is editable, because Lungfish has no way to infer it from the FASTQ alone.

<!-- planned: inspector-sample-metadata -->

Edit one bundle at a time in the Inspector. Click a field, type the value, press Tab or click out to commit. Changes are saved into the bundle's manifest immediately and recorded as a metadata-edit event in provenance.

For many samples at once, prepare a CSV with one row per sample and import it from the command line with `lungfish metadata import <folder> <csv>`. The CSV must have a `sample_name` column matching the bundle directory name; other columns map onto metadata fields by header name. Unrecognised columns are kept as free-text annotations rather than rejected, so you can carry through extra fields from your LIMS without restructuring the spreadsheet. Add `--sync-bundles` to also write a per-bundle `metadata.csv` into each matched bundle.

```sh
lungfish metadata import ~/Projects/SARS-CoV-2-WW.lungfish/Imports samples.csv --sync-bundles
```

## Next

Continue to [Downloading from SRA](02-downloading-from-sra.md) to fetch reads from NCBI's Sequence Read Archive instead of importing from disk, or jump to [Quality Control](03-quality-control.md) to run the first full quality pass on the bundle you just imported.
