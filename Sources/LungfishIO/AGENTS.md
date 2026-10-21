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
| `ClampedSequenceProvider` (reference bases clamped to the sequence, for CDS translation and extraction) | Sources/LungfishIO/Bundles/ClampedSequenceProvider.swift line 16 |
| `AnalysisToolRegistry` and `AnalysisToolDescriptor`, the one table of analysis kinds (id, display name, imported-sample naming, sidebar symbol, batch badge and lock link) | Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift, AnalysisToolDescriptor.swift |
| `AnalysisToolID` and `ManagedToolID`, the two typed tool ids | Sources/LungfishIO/Analysis/ToolIdentity.swift |
| `BundleKindRegistry`, `BundleKindDescriptor` and `BundleKindID`, the one table of bundle kinds (folder extension, manifest, UTType id, sidebar symbol, package presentation, deletion and copy facts, app state, record names and producing analysis) | Sources/LungfishIO/Bundles/BundleKindRegistry.swift, BundleKind.swift |
| `VariantDatabase`, `AnnotationDatabase` | Sources/LungfishIO/Bundles/VariantDatabase.swift line 40, AnnotationDatabase.swift line 44 |
| `AlignmentDataProvider` | Sources/LungfishIO/Bundles/AlignmentDataProvider.swift line 87 |
| `ProjectTempDirectory` | Sources/LungfishIO/Bundles/ProjectTempDirectory.swift line 65 |
| Genotype results | Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift line 6 |
| IQ-TREE option rules shared by the CLI and the Build Tree dialog, `IQTreeOptionRules` (reserved flags at line 57) | Sources/LungfishIO/Bundles/IQTreeOptionRules.swift line 51 |
| IQ-TREE report parser, `IQTreeReportParser.parse` (best-fit model, criterion, model of substitution, log-likelihood, free parameters) | Sources/LungfishIO/Bundles/IQTreeReportParser.swift line 41 |
| Tree inference summary stored in the tree manifest, `PhylogeneticTreeInferenceSummary`, and `clearingOutgroup()` for rerooted copies | Sources/LungfishIO/Bundles/PhylogeneticTreeInferenceSummary.swift lines 7 and 86 |
| Support labels (`SH-aLRT`, `aBayes`, `UFBoot`) | `PhylogeneticTreeSupportLabel`, Sources/LungfishIO/Bundles/PhylogeneticTreeSupport.swift line 33 |

## Contracts this module owns

- An analysis folder from `AnalysesFolder.createAnalysisDirectory` (line 120) stays hidden until `markAnalysisComplete` (line 239). A failed run calls `discardFailedAnalysisDirectory` (line 457).
- `AnalysesFolder.knownTools` (line 26) and `displayName(for:)` (line 74) decide whether the sidebar recognises a tool folder, and both read `AnalysisToolRegistry`. The registry is static Swift data. IO never reads the managed tool lock, and a descriptor names its lock entry with a typed `ManagedToolID` that LungfishWorkflow checks against the lock. A descriptor also carries `runsTools`, the lock ids of the managed tools its kind's pipeline launches and names in its record. It defaults to the provisioned managed tool, and a kind that also records samtools or Bracken lists them in the registry. `AnalysisRunsToolsAgreementTests` in LungfishWorkflowTests holds each listed id to the lock and the version probe table. The order of `AnalysisToolRegistry.all` is the order name parsing tries each kind in, and a test fails when one id plus a hyphen starts another. `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` says how to add a kind. The `build-db` word and the classify output stem are the fields `buildDatabaseToken` and `outputStem` (S14). Display names are still saved as labels, so a new name for a kind needs an owner ruling first. The 23 ids, the names, the badges, the symbols, the tokens, the stems and the `runsTools` lists are each pinned by a test that holds a literal copy, so a change to the registry shows as a failing pin and is made in the same commit as its pin.
- Streaming readers pull per demand with `AsyncThrowingStream(unfolding:)` (FASTQReader.swift line 76). An unbounded producer task is a memory bomb (memory file known-issues.md). The viewer's samtools reads in `AlignmentDataProvider` and the gzip decompression of a VCF in `VariantDatabase+RegionExtraction.swift` run on `ToolProcess` in LungfishCore with `stdout: .stream`, so the reader gets raw bytes at its own pace and a cancel stops the whole tree. Neither creates a `Process()`, and a new tool run in this module uses the same primitive (docs/contracts/RUNNING-A-TOOL.md).
- Genotype workbook and matrix exports stay byte-identical across any refactor (REVIEW.md R6).
- A tree manifest's `supportLabels` name the tests behind "a/b[/c]" node labels in IQ-TREE's order, and normalisation splits the label against them. Without labels the old single-value guess is kept. Derived trees pass the inference summary explicitly. Reroot clears the outgroup, extract passes none and relabel keeps it. Line numbers for the IQ-TREE rows above were checked at commit 58370dd8e.

## Bundle kinds

`BundleKindRegistry.all` holds one `BundleKindDescriptor` for each of the 15 folder kinds a project can hold, from `.lungfish` to `.lungfishflowpkg`. A descriptor gives the id, the folder extension, the manifest file name, the UTType id that `Lungfish-Info.plist` declares, the sidebar symbol, whether the sidebar shows the folder as one package or walks it, how the deletion planner and the cross-project copier treat it, the file names that hold app state, the provenance record names and the analyses whose rows are that kind. Since lane B7 six callers read it. The deletion planner reads `deletion`, the cross-project copier reads `copy` for refusals, and `FileTypeUtility`, `DocumentType`, the MSA action runner and the open panel take folder extensions from it. The sidebar tables, the provenance coverage monitor, `FormatIdentifier` and `ProvenanceWriter.isBundleDirectory` keep their own, and the sidebar moves in 2.9 (S21).

`BundleKindID` is a string-backed struct, so an id from a newer build decodes and finds no descriptor. A lookup by extension reads no file. `descriptor(forExactExtension:)` keeps the answer of a site that compares case-sensitively and `descriptor(forLowercasedExtension:)` keeps the answer of a site that lowercases, so a converted site keeps its own case rule until a reviewed change says otherwise. `recognizedKind(at:)` is the only lookup that touches the file system, and it asks for the manifest only when the kind needs one. A package with no viewer, such as `.lungfish12sref`, `.lungfishflow`, `.lungfishflowpkg` and a `.lungfishtax` folder with no manifest, stays walked. `.lungfish12sref` is its own kind and not a genome reference.

A change to a kind's folder extensions, its `deletion` fact or a refused `copy` changes what those callers do, so review it like a parity diff. Any other fact changes nothing until a caller reads it. `BundleKindParityTests` in Tests/LungfishAppTests/SafetyNets fails when the answer of any older table moves, so convert one table at a time and review each diff of the files in Tests/Fixtures/bundle-kinds. `BundleKindRegistryTests` ties the descriptors to the typed constants, the Info.plist and those recorded answers. `BundleKindAgreementTests` in LungfishWorkflowTests ties them to the Workflow constants and to `AnalysisToolRegistry`.

## Tests

Target LungfishIOTests in Tests/LungfishIOTests. Run only it with `swift test --skip-update --filter LungfishIOTests`.

## Known traps

| Trap | Evidence |
|---|---|
| `resolvePrimaryFASTQURL` returns preview.fastq for a virtual bundle, about 1,000 reads. Never pass it to a classifier | FASTQBundle.swift line 89 (memory file project_virtual_fastq_materialization.md) |
| A created analysis folder that is never tracked stays hidden, and 10 of 20 creation sites use `try?` | `createAnalysisDirectory` in AnalysesFolder.swift (R4) |
| Tool names are still bare strings in most tables. `AnalysesFolder.knownTools` and `displayName(for:)` (T1 and T2) and the sidebar badge and icon in `SidebarProjectScanner` (T5 and T7) now read `AnalysisToolRegistry`. The other tables wait for 2.6 and later, so `displayName` still says "Minimap2" where MappingTool says "minimap2". `scripts/ratchets/tool-identity.sh` counts the literals that remain, and a new one fails the push. An analysis id and a lock id are different spaces. `bbmap` is the analysis and `bbtools` its lock entry, so never pass one where the other belongs | Analysis/AnalysisToolRegistry.swift, Analysis/ToolIdentity.swift, scripts/ratchets/tool-identity.sh, Tests/LungfishIOTests/Analysis/AnalysisToolRegistryTests.swift (R2) |
| Static fault-injection switches guard VCF rollback | Bundles/VariantDatabase+CreateFromVCF.swift lines 18 and 19 (R10) |
| A notebook-compatible MHC-A special case is hard-coded | Bundles/GenotypeHaplotypeAnalyzer.swift lines 709 to 722 (R18) |
| `SequencingPlatform` is the canonical platform. FASTQ sidecars, barcode kits, demultiplex plans and the search index store its raw values (`illumina`, `oxfordNanopore`, `pacbio`, `element`, `ultima`, `mgi`, `unknown`), so renaming a case breaks every file already written. An unrecognised raw value decodes as `unknown`, so a case added later never makes an older reader drop a file. `lungfish-cli import fastq --platform` spells Oxford Nanopore `ont` (`SequencingPlatform.importCLIValue` in LungfishWorkflow), never a raw value | Formats/FASTQ/SequencingPlatform.swift line 12, Tests/LungfishIOTests/SequencingPlatformPinTests.swift (R15) |
| `PlatformInference` is the only platform detector. The import, the Import FASTQ sheet, mapping, assembly, Viral Recon, genotyping and the demultiplex scout call it, directly or through `SequencingPlatform.detect`. It names a platform only when the sampled read headers agree, and returns Unknown for mixed files, short-read headers on long reads and unrecognised headers. Read length alone never names a platform. A rule change alters labels written by future imports, so bump `detectorVersion` and get a scientific ruling | Formats/FASTQ/PlatformInference.swift, PlatformInference+Rules.swift, Tests/LungfishIOTests/PlatformInferenceTests.swift (R15, owner decision 3) |
| `FASTQReadLayoutClassifier` lets merge evidence only make a file more conservative, with two exceptions. A recorded count of only pairs outranks a merge in the lineage or the recipe when its file holds every read of the bundle (`holdsEveryRead`) and counts as many R1 reads as R2 reads (`countsOnlyPairs`). A layout scan that read the whole of such a file and found only pairs outranks that merge too. A recorded count of single reads, in a derived manifest, a read manifest or the file's own sidecar, R1 and R2 counts that differ included, keeps the file mixed, and a virtual bundle's preview or a chunked root's first chunk never counts for its bundle. The pure `classify(headers:scannedWholeFile:metadata:wholeFileScanOutranksTheMerge:)` takes the scan rule as a flag that defaults off, and `classify(inputURL:)` and `FASTQInputLayoutResolver.resolve(fastqURL:metadataFrom:)` apply it, so every layout consumer agrees. Before the scan, after only a layout the caller states and two files it binds, `FASTQInputLayoutResolver` reads the recorded platform through `FASTQLongReadRule`, the one long-read rule `ReadSetResolver` also reads, and gives Oxford Nanopore or PacBio reads as single reads. Changing the rule changes which tools run a file as pairs, so get a scientific ruling | Formats/FASTQ/FASTQReadLayoutClassifier.swift, Formats/FASTQ/FASTQInputLayout.swift, Formats/FASTQ/FASTQLongReadRule.swift, Tests/LungfishIOTests/FASTQReadLayoutClassifierTests.swift, Tests/LungfishIOTests/FASTQInputLayoutLongReadTests.swift, docs/contracts/READ-PAIRING.md (F6-N1, Phase 2.1 lane L3, ruling on S4 option 1, Phase 2.13 lane 13.42) |
