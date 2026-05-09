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
  - "File > Import Center (Cmd-Shift-I) > FASTQ"
  - "Drag-drop into the sidebar"
  - "CLI: lungfish import-fastq"
shots: []
planned_shots:
  - id: import-center-fastq
    caption: "The Import Center FASTQ tab with paired files auto-detected."
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

Lungfish imports FASTQ files into a project so that every downstream step (QC, trimming, mapping, classification, assembly, variant calling) has a stable, named input to work from. An import is not a copy step alone. It is the moment Lungfish records where the file came from, computes a checksum, and creates a FASTQ bundle that the rest of the project can reference by name.

There are three ways to import. You can drag one or more FASTQ files (or a folder of them) onto the project sidebar. You can open the Import Center with `Cmd-Shift-I`, choose the FASTQ tab, pick files, and click Import. Or, from a script or terminal, you can run `lungfish import-fastq --project <path> --files ...`. All three paths produce the same on-disk result and write the same provenance record, so you can mix them freely across one project.

Lungfish recognizes paired-end Illumina data by filename. If two files share a sample stem and differ only in a `_1` / `_2` or `_R1` / `_R2` suffix, they are imported as one paired bundle. Single files (Nanopore reads, single-end Illumina, or one half of a pair whose mate is missing) are imported as single-end bundles. A folder containing many paired FASTQs is imported as one bundle per sample.

So what should you do with this? Treat import as the first deliberate, recorded step of your analysis. Every later command you run will name the bundle that import produced; if you bypass import and reference loose files, you lose checksums and provenance for the rest of the run.

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

1. Choose `File > Import Center` or press `Cmd-Shift-I`.
2. Click the FASTQ tab.
3. Click Add Files and select both `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`. The dialog detects the pair and shows them on one row with a "Paired" badge.
4. Optionally edit the sample name in the row before clicking Import.
5. Click Import. The dialog closes and the new bundle appears in the sidebar.

The Import Center is also where you would import a single-end FASTQ (a Nanopore barcode, for example) or import several single-end files at once.

## Procedure: batch import a folder of paired samples

For a sequencing run that produced ten or more samples, importing pair-by-pair is tedious. Drop the whole folder instead.

1. In the Finder, identify a folder that contains your FASTQs. The folder may be flat (`Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz`, `Sample02_R1.fastq.gz`, ...) or have one subfolder per sample. Lungfish handles both layouts.
2. Drag the folder onto `Imports/` in the sidebar.
3. The Import Center opens with one row per detected sample and a "Paired" or "Single" badge per row. Review the list. Any unpaired file appears with a yellow warning so you can spot a missing mate.
4. Click Import All.

Lungfish creates one bundle per sample. A folder with ten paired samples produces ten bundles, each named for its shared stem. The provenance record for each bundle names the source folder and the exact two source files that landed in that bundle, so you can always trace a sample back to the run directory it came from.

## Procedure: import from the command line

The CLI command takes the same paths and produces the same bundles as the GUI. Use it from scripts, from a remote shell, or when you want to log the exact import command in a lab notebook.

```sh
lungfish import-fastq \
  --project ~/Projects/SARS-CoV-2-WW.lungfish \
  --files SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz
```

For a folder of samples, point `--files` at the folder; the CLI detects pairs the same way the GUI does. Run `lungfish import-fastq --help` for the full option list, including how to override the proposed sample name.

## What gets recorded at import

An import is more than a copy. Lungfish does three things for every file you import.

1. It computes a SHA-256 checksum of the source file before any copying, and a second checksum of the file as it lands inside the project. The two must match; if they do not, the import fails and reports which file mismatched.
2. It writes a provenance record (file path, byte size, checksum, timestamp, host machine identity) into the bundle's `provenance/` subfolder. This is the import event itself, not a placeholder for QC.
3. It creates the bundle's manifest, which names the primary FASTQ files, the read pairing, and the bundle type.

Imports do **not** auto-run QC. The bundle exists, the files are in place, the metadata is recorded, but no per-base quality charts or adapter scans have happened yet. You invoke QC separately. See [Read QC](03-read-qc.md) for the procedure.

## Interpretation: the FASTQ viewport

Click a FASTQ bundle in the sidebar. The main viewport switches to the FASTQ viewport, and the Inspector switches to the FASTQ metadata pane.

<!-- planned: fastq-viewport-sparklines -->

The viewport shows one row per file in the bundle (one row for single-end, two rows for paired-end). Each row carries a small sparkline summarising read length and a second sparkline summarising mean per-base quality across the file. These sparklines are computed from a sample of reads at the time of import and are meant to give you a quick "does this look reasonable?" read; they are not a substitute for a full QC pass. A single-end Nanopore FASTQ will show a long-tailed length distribution; an Illumina FASTQ will show a near-vertical spike at the read length the run was configured for.

Below the sparklines, the metadata drawer shows the technical fields Lungfish read off the file: detected platform (Illumina vs Nanopore vs unknown, inferred from read header format), total read count, total base count, read length range, and the bundle's checksums.

If the sparklines look wrong (Q scores collapsing, length distribution unexpectedly wide), that is your prompt to run a full QC pass before going further. If they look reasonable, proceed to QC at your own pace.

## Interpretation: editing sample metadata

Technical fields (read count, length, checksum) are computed from the file and are not editable. Sample metadata (run accession, sample name, collection date, host or organism, free-text notes) is editable, because Lungfish has no way to infer it from the FASTQ alone.

<!-- planned: inspector-sample-metadata -->

Edit one bundle at a time in the Inspector. Click a field, type the value, press Tab or click out to commit. Changes are saved into the bundle's manifest immediately and recorded as a metadata-edit event in provenance.

For many samples at once, prepare a CSV with one row per sample and import it through `File > Import > Project Sample Metadata`. The CSV must have a `sample_name` column matching the bundle name; other columns map onto metadata fields by header name. Unrecognised columns are kept as free-text annotations rather than rejected, so you can carry through extra fields from your LIMS without restructuring the spreadsheet.

## Next

Continue to [Downloading from SRA](02-downloading-from-sra.md) to fetch reads from NCBI's Sequence Read Archive instead of importing from disk, or jump to [Read QC](03-read-qc.md) to run the first full quality pass on the bundle you just imported.
