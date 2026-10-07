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
| IQ-TREE option rules shared by the CLI and the Build Tree dialog, `IQTreeOptionRules` (reserved flags at line 57) | Sources/LungfishIO/Bundles/IQTreeOptionRules.swift line 51 |
| IQ-TREE report parser, `IQTreeReportParser.parse` (best-fit model, criterion, model of substitution, log-likelihood, free parameters) | Sources/LungfishIO/Bundles/IQTreeReportParser.swift line 41 |
| Tree inference summary stored in the tree manifest, `PhylogeneticTreeInferenceSummary`, and `clearingOutgroup()` for rerooted copies | Sources/LungfishIO/Bundles/PhylogeneticTreeInferenceSummary.swift lines 7 and 86 |
| Support labels (`SH-aLRT`, `aBayes`, `UFBoot`) | `PhylogeneticTreeSupportLabel`, Sources/LungfishIO/Bundles/PhylogeneticTreeSupport.swift line 33 |

## Contracts this module owns

- An analysis folder from `AnalysesFolder.createAnalysisDirectory` (line 151) stays hidden until `markAnalysisComplete` (line 268). A failed run calls `discardFailedAnalysisDirectory` (line 486).
- `AnalysesFolder.knownTools` (line 26) and `displayName` (line 82) decide whether the sidebar recognises a tool folder.
- Streaming readers pull per demand with `AsyncThrowingStream(unfolding:)` (FASTQReader.swift line 76). An unbounded producer task is a memory bomb (memory file known-issues.md).
- Genotype workbook and matrix exports stay byte-identical across any refactor (REVIEW.md R6).
- A tree manifest's `supportLabels` name the tests behind "a/b[/c]" node labels in IQ-TREE's order, and normalisation splits the label against them. Without labels the old single-value guess is kept. Derived trees pass the inference summary explicitly. Reroot clears the outgroup, extract passes none and relabel keeps it. Line numbers for the IQ-TREE rows above were checked at commit 58370dd8e.

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
| `FASTQReadLayoutClassifier` lets merge evidence only make a file more conservative, with two exceptions. A recorded count of only pairs outranks a merge in the lineage or the recipe when its file holds every read of the bundle (`holdsEveryRead`) and counts as many R1 reads as R2 reads (`countsOnlyPairs`). A layout scan that read the whole of such a file and found only pairs outranks that merge too. A recorded count of single reads, in a derived manifest, a read manifest or the file's own sidecar, R1 and R2 counts that differ included, keeps the file mixed, and a virtual bundle's preview or a chunked root's first chunk never counts for its bundle. The pure `classify(headers:scannedWholeFile:metadata:wholeFileScanOutranksTheMerge:)` takes the scan rule as a flag that defaults off, and `classify(inputURL:)` and `FASTQInputLayoutResolver.resolve(fastqURL:metadataFrom:)` apply it, so every layout consumer agrees. Changing the rule changes which tools run a file as pairs, so get a scientific ruling | Formats/FASTQ/FASTQReadLayoutClassifier.swift, Formats/FASTQ/FASTQInputLayout.swift, Tests/LungfishIOTests/FASTQReadLayoutClassifierTests.swift, docs/contracts/READ-PAIRING.md (F6-N1, Phase 2.1 lane L3, ruling on S4 option 1) |
