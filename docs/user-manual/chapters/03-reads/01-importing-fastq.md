---
title: Importing FASTQ Reads
chapter_id: 03-reads/01-importing-fastq
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 8
task: Import FASTQ files into a Lungfish project, including paired-end pairing and batch import.
tags: [reads, fastq, import, paired-end, batch, metadata, biosample]
tools: []
entry_points:
  - "Import Center (Cmd-Shift-I) > Sequencing Reads > FASTQ Files"
  - "Drag-drop into the sidebar"
  - "CLI: lungfish import-fastq"
  - "CLI: lungfish metadata import, lungfish metadata export-biosample"
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
features_refs: [import.sample-metadata]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about FASTQ files that already sit on your disk. To pull reads from a public archive instead, see [Downloading from SRA](02-downloading-from-sra.md); to import an Oxford Nanopore run directory, see [Oxford Nanopore Runs](07-ont-runs.md). If reads still need splitting into per-sample bins by barcode, the demultiplexing section of that same [Oxford Nanopore Runs](07-ont-runs.md) chapter covers it.

When Lungfish imports a FASTQ file into a project, it hands every downstream step a stable, named input to build on. That covers the whole road ahead: QC, trimming, mapping, classification, assembly, variant calling. But import is more than a copy. It is the moment Lungfish records where the file came from, computes a checksum, and creates a FASTQ bundle the rest of the project can call by name.

Three doors lead to the same room. Drag one or more FASTQ files onto the project sidebar, or a whole folder of them. Open the Import Center with `Cmd-Shift-I`, choose the `Sequencing Reads` tab, click the `FASTQ Files` tile, pick your files, and import. Or run `lungfish import-fastq --project <path> ...` from a script or terminal. All three produce the same result on disk and write the same provenance record, so you can mix them freely inside one project.

Lungfish spots paired-end Illumina data by filename. When two files share a sample stem and differ only in a `_1` / `_2` or `_R1` / `_R2` suffix, they come in as one paired bundle. A lone file becomes a single-end bundle, whether it holds Nanopore reads, single-end Illumina, or one orphaned half of a pair whose mate never arrived. A folder full of paired FASTQs becomes one bundle per sample.

Import is the first deliberate, recorded step of your analysis. Every later command names the bundle that import produced. Bypass it and point at loose files, and you forfeit checksums and provenance for the rest of the run. Treat it as the gate the whole project hangs on.

## What you will learn

Work through this chapter and you can import a single FASTQ, import a paired-end pair and confirm it was paired, batch-import many FASTQs at once, find imported FASTQs in the sidebar, read per-file QC sparklines in the FASTQ viewport, and edit per-sample metadata in the Inspector.

## Pairing conventions Lungfish recognizes

Lungfish reads pairing from the filename and nothing else. The table below lists the conventions it accepts. Anything outside it counts as single-end, so if your filenames are unusual, rename before you import.

| Pattern                       | Example                                | Treated as                       |
|-------------------------------|----------------------------------------|----------------------------------|
| `<stem>_1.fastq[.gz]` + `<stem>_2.fastq[.gz]` | `SRR36291587_1.fastq.gz`, `SRR36291587_2.fastq.gz` | Paired-end (Illumina, ENA style) |
| `<stem>_R1.fastq[.gz]` + `<stem>_R2.fastq[.gz]` | `Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz` | Paired-end (Illumina, vendor style) |
| `<stem>.fastq[.gz]` alone     | `barcode07.fastq.gz`                   | Single-end (Nanopore or single-end Illumina) |
| `<stem>_1.fastq.gz` alone (mate missing) | `SRR36291587_1.fastq.gz` only          | Single-end, with a warning       |
| Mixed case (`_r1`, `_R1`)     | `Sample_r1.fastq.gz`                   | Paired-end (case-insensitive match) |

The match ignores case, so `_R1` and `_r1` both work. The compression suffix is optional too: `.fastq` and `.fastq.gz` are both fine, and Lungfish keeps each file in whatever form you handed it. When a mate is missing, the import dialog warns you before it continues, so you can cancel and go find it.

## Procedure: import a paired-end pair by drag-drop

For one or two samples, drag-drop is the quickest path. The example below imports the SARS-CoV-2 run `SRR36291587`, but the steps hold for any pair.

1. Open or create a Lungfish project. The sidebar should show the five top-level folders (`Imports/`, `Downloads/`, `Reference Sequences/`, `Assemblies/`, `Primer Schemes/`).
2. In the Finder, locate `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`. Select both.
3. Drag the two files onto the `Imports/` row in the project sidebar. Release.

<!-- planned: import-center-fastq -->

4. The Import Center opens with the two files listed and a green "Paired" badge linking them. Confirm the sample name (Lungfish proposes the shared stem, here `SRR36291587`) and click Import.
5. Wait for the progress chip in the footer to clear. For two SARS-CoV-2 FASTQs this takes a few seconds, and the time goes to checksumming, not copying.

<!-- planned: sidebar-after-import -->

When the operation finishes, a new bundle named `SRR36291587` appears under `Imports/` in the sidebar. Click it once to select it.

## Procedure: import the same pair with the Import Center

If you would rather work in a dialog than drag-drop, or your files sit behind a network share that drag-drop cannot reach, use the Import Center.

1. Press `Cmd-Shift-I` to open the Import Center.
2. Choose the `Sequencing Reads` tab and click the `FASTQ Files` tile.
3. Select both `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz` in the file picker. The dialog detects the pair and shows them on one row with a "Paired" badge.
4. Optionally edit the sample name in the row before importing.
5. Confirm the import. The dialog closes and the new bundle appears in the sidebar.

The Import Center is also the place to bring in a single-end FASTQ, say a Nanopore barcode, or several single-end files at once.

## Procedure: batch import a folder of paired samples

When a run turns out ten or more samples, importing pair by pair wears thin. Drop the whole folder instead.

1. In the Finder, identify a folder that contains your FASTQs. The folder may be flat (`Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz`, `Sample02_R1.fastq.gz`, ...) or have one subfolder per sample. Lungfish handles both layouts.
2. Drag the folder onto `Imports/` in the sidebar.
3. The Import Center opens with one row per detected sample and a "Paired" or "Single" badge per row. Review the list. Any unpaired file appears with a yellow warning so you can spot a missing mate.
4. Click Import All.

Lungfish makes one bundle per sample. Ten paired samples yield ten bundles, each named for its shared stem. Every bundle's provenance record names the source folder and the exact two files that landed in it, so you can always trace a sample back to the run directory it came from.

## Procedure: batch import with a sample sheet

When a paired Illumina run comes with explicit sample metadata, lean on a CSV sample sheet rather than filenames alone. The sheet must carry `sample`, `r1`, and `r2` columns. Any extra columns, such as `collection_date`, `batch_id`, `host`, or `operator`, ride along as bundle metadata for that sample.

```csv
sample,r1,r2,collection_date,batch_id
Alpha,Alpha_R1.fastq.gz,Alpha_R2.fastq.gz,2026-05-10,B42
Beta,/data/run/Beta_R1.fastq.gz,/data/run/Beta_R2.fastq.gz,2026-05-10,B42
```

Relative FASTQ paths resolve next to the CSV file. In the Import Center, choose **Sequencing Reads > FASTQ Sample Sheet** and select the CSV. From the CLI, hand it the sheet directly:

```sh
lungfish import fastq \
  --samplesheet samples.csv \
  --project ~/Projects/SARS-CoV-2-WW.lungfish \
  --platform illumina
```

The top-level alias `lungfish import-fastq --samplesheet samples.csv --project <project>` does the same thing, kept alive for scripts written against older documentation.

Each row becomes one `.lungfishfastq` bundle. Its provenance record captures the sample-sheet path, checksum, file size, resolved R1/R2 paths, the options and defaults you saw, exit status, and wall time.

## Procedure: import from the command line

The CLI command takes the same paths and builds the same bundles as the GUI. Reach for it from scripts, from a remote shell, or whenever you want the exact import command written into a lab notebook.

```sh
lungfish import fastq \
  SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
  --project ~/Projects/SARS-CoV-2-WW.lungfish \
  --platform illumina
```

For a folder of samples, pass the folder path; the CLI pairs files exactly as the GUI does. Run `lungfish import fastq --help` for the full option list.

Two CLI defaults change the bytes on disk, so record them in a methods note if bit-exact reproduction matters. `--quality-binning` defaults to `illumina4`, which re-quantises each base quality into one of four levels, the same trick NovaSeq applies in hardware. Pass `--quality-binning none` to keep the original per-base scores. Storage-optimized read reordering is on by default; pass `--no-optimize-storage` to keep the reads in their original order. `--recipe` applies a packaged processing pass at import and takes one of `vsp2`, `wgs`, `amplicon`, `hifi`, or `none`, defaulting to `none`. And `--dry-run` lists the pairs the CLI found without importing a thing.

## What gets recorded at import

An import is more than a copy. Lungfish does three things for every file you import.

1. It computes a checksum of the imported file, so corruption shows up later. When a recorded checksum and the file on disk still agree, a later step has proof the bytes never changed.
2. It writes a provenance record into the bundle's `provenance/` subfolder: file path, byte size, checksum, timestamp, and host machine identity. This is the import event itself, not a stand-in for QC.
3. It creates the bundle's manifest, which names the primary FASTQ files, the read pairing, and the bundle type.

Import does **not** run QC on its own. The bundle exists, the files are in place, the metadata is logged, but no per-base quality chart or adapter scan has run yet. QC is a separate call. See [Quality Control](03-quality-control.md) for the procedure.

## Interpretation: the FASTQ viewport

Click a FASTQ bundle in the sidebar. The main viewport flips to the FASTQ viewport, and the Inspector flips to the FASTQ metadata pane.

<!-- planned: fastq-viewport-sparklines -->

The viewport gives one row per file: one for single-end, two for paired-end. Each row carries a small sparkline for read length and a second for mean per-base quality across the file. Read them as a quick "does this look reasonable?" glance, not a stand-in for a full QC pass. A single-end Nanopore FASTQ draws a long-tailed length distribution; an Illumina FASTQ draws a near-vertical spike at the read length the run was set for.

Below the sparklines, the metadata drawer lists the technical fields Lungfish read straight off the file: the detected platform inferred from the read-header format, whether Illumina, Nanopore, or unknown, plus total read count, total base count, read-length range, and the bundle's checksums.

When the sparklines look wrong, with Q scores collapsing or the length distribution surprisingly wide, take it as your cue to run a full QC pass before going further. When they look reasonable, move on to QC at your own pace.

## Interpretation: editing sample metadata

The technical fields, read count, length, and checksum, are computed from the file and cannot be edited. The sample metadata can: run accession, sample name, collection date, host or organism, and free-text notes. Lungfish has no way to guess any of that from the FASTQ alone.

<!-- planned: inspector-sample-metadata -->

Edit one bundle at a time in the Inspector. Click a field, type the value, then press Tab or click away to commit. The change saves into the bundle's manifest at once and lands in provenance as a metadata-edit event.

For many samples at once, build a CSV with one row per sample and import it from the command line with `lungfish metadata import <folder> <csv>`. The CSV needs a `sample_name` column matching the bundle directory name; other columns map onto metadata fields by their header. Columns Lungfish does not recognise are kept as free-text annotations rather than thrown out, so you can carry extra fields straight from your LIMS without reshaping the spreadsheet. Add `--sync-bundles` to also write a per-bundle `metadata.csv` into each matched bundle.

```sh
lungfish metadata import ~/Projects/SARS-CoV-2-WW.lungfish/Imports samples.csv --sync-bundles
```

## Exporting sample metadata for NCBI submission

The same per-sample metadata you edit in the Inspector can be filled in for a
whole folder at once, then exported in the shape NCBI wants for a submission.
Two surfaces reach it. In the app, open a folder's metadata editor from the
sidebar for a `Sample Metadata` sheet with `Import CSV…` and `Export CSV…`
buttons; your changes save to a folder-level `samples.csv` and sync into each
bundle. From the command line, `lungfish metadata import` and `lungfish metadata
export` run the same round trip, and both CSV and TSV are accepted on import.

The fields follow PHA4GE and NCBI BioSample conventions, with snake_case
names such as `collection_date`, `sample_type`, and `host`, so a completed
sheet turns into a submission file directly. A BioSample is NCBI's
registered description of the physical material a sequence came from, and its
submission portal takes a tab-separated sheet. Export one with:

```sh
lungfish metadata export-biosample ~/Projects/SARS-CoV-2-WW.lungfish/Imports > biosample.tsv
```

The `--package` option picks the template: `clinical`, the default, for
patient-derived samples, or `environmental` for wastewater and other
environmental sources. The resulting TSV uploads to NCBI's BioSample submission
portal with no further reshaping. Fill the sheet in once per run, keep it as the
folder's `samples.csv`, and export the BioSample TSV when you are ready to
deposit.

## Next

Continue to [Downloading from SRA](02-downloading-from-sra.md) to pull reads from NCBI's Sequence Read Archive instead of loading them from disk, or jump to [Quality Control](03-quality-control.md) to run the first full quality pass on the bundle you just imported.
