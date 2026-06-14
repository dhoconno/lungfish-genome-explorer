# Scientific In-App Help Inventory

This inventory is the editing map for tooltips, hover help, accessibility hints, and longer Help topics in Lungfish Genome Explorer.

## Source Of Truth

The runtime catalog lives in `Sources/LungfishKit/LungfishHelpContent.swift`.

Each help item has:

- `id`: stable dotted identifier grouped by workflow and field.
- `summary`: macOS tooltip text, usually 8-18 words and one sentence.
- `detail`: longer accessibility/help text for screen readers and Help topic authors.
- `audience`: `benchScientist`, `analyst`, or `powerUser`.
- `provenanceRelevant`: `true` when the control creates, imports, transforms, exports, extracts, or wraps scientific data.

## Style Rules

- Tooltips should explain what is expected, not market the feature.
- Use concrete field language: format, range, default, or consequence.
- Keep scientific uncertainty explicit: use "candidate", "supports review", "may", and "usually" where appropriate.
- Do not describe BLAST, classifier results, AI output, or variant calls as final evidence unless the app has an explicit validation workflow.
- Provenance-relevant help must mention reproducibility evidence such as command, inputs, checksums, output paths, status, runtime, or resolved defaults.
- Longer biological interpretation belongs in Help topics, not in hover text.

## Implemented Coverage

| Area | Catalog Group | Primary Files |
| --- | --- | --- |
| Operation frame | `workflow.operation.*` | `DatasetOperationsDialog.swift` |
| FASTQ operation fields | `workflow.fastq.field.*` | `FASTQOperationToolPanes.swift` |
| FASTQ import | `workflow.fastq.import.*` | `FASTQImportConfigSheet.swift` |
| BAM primer trim | `workflow.bam.primerTrim.*` | `BAMPrimerTrimToolPanes.swift`, `BAMPrimerTrimDialogState.swift` |
| BAM variant calling | `workflow.bam.variantCalling.*` | `BAMVariantCallingToolPanes.swift`, `CLIVariantCallingRunner.swift` |
| Classification review | `workflow.classifier.*` | `ClassifierActionBar.swift`, `BlastConfigPopoverView.swift`, `ClassifierExtractionDialog.swift` |
| Metagenomics import sheets | `workflow.metagenomics.import.*` | `NvdImportSheet.swift`, `NaoMgsImportSheet.swift`, `CzIdImportSheet.swift` |
| Operations panel | `operations.panel.*` | `OperationsPanelController.swift` |
| Result export/provenance | `result.*` | classifier action bars and Help topics |

## Follow-Up Coverage Map

These surfaces should use the same catalog pattern when touched next:

- Mapping wizard: reference selection, preset, read groups, secondary/supplementary alignment, MAPQ, threads, output names, and extra arguments.
- Assembly wizard: assembler, read type/profile, threads, memory, minimum contig length, output directory, and extra arguments.
- Kraken2/classification wizard: database, confidence, minimum hit groups, threads, memory mapping, output paths, and extra arguments.
- EsViritu wizard: sample/database selection, quality filtering, minimum read length, threads, output paths, and extra arguments.
- TaxTriage wizard: sample role, database/profile, platform, assembly skip, confidence/top hits, memory/CPUs, Krona, and extra arguments.
- ViralRecon wizard: platform, reference/genome inputs, primers, executor/container runtime, caller options, CPUs/memory, and skip options.
- IQ-TREE dialog: output name, model, sequence type, bootstrap/aLRT, seed, threads, safe mode, identical-sequence handling, executable, and parameters.
- Provenance inspector: filters, copy/export, lineage, file table, options, runtime identity, warnings, and raw JSON.

## Review Notes

Expert review identified two non-copy issues fixed in this pass:

- BAM iVar GUI options now serialize into `lungfish-cli variants call` arguments.
- BAM primer trimming now shows the source BAM track, editable output track name, and the `ivar trim -e` consequence that reads without primer matches are retained.
