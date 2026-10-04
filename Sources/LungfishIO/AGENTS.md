# LungfishIO

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

File formats and on-disk bundles. Readers and writers for FASTA, FASTQ, GenBank, GFF and GTF, BED, SAM and BAM access, VCF and the classifier outputs (Kraken, EsViritu, TaxTriage, NAO-MGS, NVD). It also owns the SQLite indexes behind annotation, variant and classifier tables, the Analyses folder layout, and the genotype result and workbook data types.

## Allowed imports

LungfishCore, SystemPackage, AsyncAlgorithms, SQLite3 and system frameworks. Never LungfishWorkflow, LungfishKit, a UI module, AppKit or SwiftUI.

## Entry points

| Type | Path |
|---|---|
| `FormatRegistry` | Sources/LungfishIO/Registry/FormatRegistry.swift line 37 |
| `FASTQBundle` and `resolvePrimaryFASTQURL` | Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift lines 12 and 89 |
| `FASTQReader` | Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift line 29 |
| `AnalysesFolder` (analysis folder lifecycle) | Sources/LungfishIO/Bundles/AnalysesFolder.swift line 17 |
| `VariantDatabase`, `AnnotationDatabase` | Sources/LungfishIO/Bundles/VariantDatabase.swift line 40, AnnotationDatabase.swift line 44 |
| `AlignmentDataProvider` | Sources/LungfishIO/Bundles/AlignmentDataProvider.swift line 87 |
| `ProjectTempDirectory` | Sources/LungfishIO/Bundles/ProjectTempDirectory.swift line 65 |
| Genotype results | Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift line 6 |

## Contracts this module owns

- An analysis folder from `AnalysesFolder.createAnalysisDirectory` (line 151) stays hidden until `markAnalysisComplete` (line 268). A failed run calls `discardFailedAnalysisDirectory` (line 486).
- `AnalysesFolder.knownTools` (line 26) and `displayName` (line 82) decide whether the sidebar recognises a tool folder.
- Streaming readers pull per demand with `AsyncThrowingStream(unfolding:)` (FASTQReader.swift line 76). An unbounded producer task is a memory bomb (memory file known-issues.md).
- Genotype workbook and matrix exports stay byte-identical across any refactor (REVIEW.md R6).

## Tests

Target LungfishIOTests in Tests/LungfishIOTests. Run only it with `swift test --skip-update --filter LungfishIOTests`.

## Known traps

| Trap | Evidence |
|---|---|
| `resolvePrimaryFASTQURL` returns preview.fastq for a virtual bundle, about 1,000 reads. Never pass it to a classifier | FASTQBundle.swift line 89 (memory file project_virtual_fastq_materialization.md) |
| A created analysis folder that is never tracked stays hidden, and 10 of 20 creation sites use `try?` | AnalysesFolder.swift lines 136 to 142 (R4) |
| Tool names are bare strings in many tables. `displayName` says "Minimap2" where MappingTool says "minimap2" | AnalysesFolder.swift lines 26 and 82 (R2) |
| Static fault-injection switches guard VCF rollback | Bundles/VariantDatabase+CreateFromVCF.swift lines 18 and 19 (R10) |
| A notebook-compatible MHC-A special case is hard-coded | Bundles/GenotypeHaplotypeAnalyzer.swift lines 709 to 722 (R18) |
| `SequencingPlatform` is the canonical platform. FASTQ sidecars, barcode kits, demultiplex plans and the search index store its raw values (`illumina`, `oxfordNanopore`, `pacbio`, `element`, `ultima`, `mgi`, `unknown`), so renaming a case breaks every file already written. An unrecognised raw value decodes as `unknown`, so a case added later never makes an older reader drop a file. `lungfish-cli import fastq --platform` spells Oxford Nanopore `ont` (`SequencingPlatform.importCLIValue` in LungfishWorkflow), never a raw value | Formats/FASTQ/SequencingPlatform.swift line 12, Tests/LungfishIOTests/SequencingPlatformPinTests.swift (R15) |
| `PlatformInference` is the only platform detector. The import, the Import FASTQ sheet, mapping, assembly, Viral Recon, genotyping and the demultiplex scout call it, directly or through `SequencingPlatform.detect`. It names a platform only when the sampled read headers agree, and returns Unknown for mixed files, short-read headers on long reads and unrecognised headers. Read length alone never names a platform. A rule change alters labels written by future imports, so bump `detectorVersion` and get a scientific ruling | Formats/FASTQ/PlatformInference.swift, PlatformInference+Rules.swift, Tests/LungfishIOTests/PlatformInferenceTests.swift (R15, owner decision 3) |
