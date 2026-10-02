# LungfishWorkflow

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Every scientific computation and every external tool run lives here, with no UI. It owns tool execution (conda, native tools, containers, Nextflow and Snakemake), provenance, FASTQ materialization and the domain pipelines. The CLI and the app both call into it. It holds about 467 files and 215K lines (REVIEW.md R12).

## Allowed imports

LungfishCore, LungfishIO, Foundation and system frameworks, and the Containerization products declared in Package.swift. Never AppKit, SwiftUI, LungfishKit, a leaf UI module, LungfishApp or LungfishCLI.

## Authoritative implementation per computation

Add to these. Never write a second copy in the CLI or the app.

| Computation | Type | Path |
|---|---|---|
| Read mapping (minimap2, BWA-MEM2, Bowtie2, BBMap) | `ManagedMappingPipeline` | Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift line 78 |
| Kraken2 and Bracken classification | `ClassificationPipeline` | Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift line 133 |
| EsViritu viral detection | `EsVirituPipeline` | Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift line 338 |
| TaxTriage | `TaxTriagePipeline` | Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift line 144 |
| Provenance record format | `ProvenanceEnvelope` | Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift line 52 |
| Provenance policy per CLI command and native tool | `ScientificProvenancePolicy` | Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift line 60 |
| Provenance recording and writing | `ProvenanceRecorder`, `ProvenanceWriter` | Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift line 46, ProvenanceWriter.swift line 146 |
| Virtual FASTQ materialization | `FASTQCLIMaterializer` | Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift line 26 |
| Multiple sequence alignment | `MAFFTAlignmentPipeline` | Sources/LungfishWorkflow/MSA/MAFFTAlignmentPipeline.swift line 93 |
| Viral variant calling | `ViralVariantCallingPipeline` | Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift line 152 |
| Native tool runs | `NativeToolRunner` | Sources/LungfishWorkflow/Native/NativeToolRunner.swift line 648 |
| Conda environment tool runs | `CondaManager.runTool` | Sources/LungfishWorkflow/Conda/CondaManager.swift line 1112 |
| Nextflow launch environment | `WorkflowEngineLaunch.resolve` | Sources/LungfishWorkflow/WorkflowEngineLaunch.swift line 56 |
| CLI progress events | `CLIEvent` | Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift line 19 |

A new domain is a folder here until Phase 4d splits domains into their own targets (RNA-seq waits for its LungfishRNASeq target, see docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md). Domain subtrees, largest first, are ONTGenotyping (47.7K lines), Metagenomics (18.3K), PrimerDesign (10.1K), Mapping, Variants, Alignment, Assembly, TwelveS, TaxTriage, MSA and ViralRecon. Infrastructure subtrees are Provenance, Conda, Native, Engines, Containers, Ingestion, Extraction and Storage. Tool versions come only from Resources/ManagedTools/third-party-tools-lock.json.

## Where a Kraken2 run starts here

`ClassificationPipeline.classify` (ClassificationPipeline.swift line 201) runs kraken2 through `CondaManager.runTool` in the `kraken2` environment (line 624) and records provenance through `ProvenanceRecorder` (line 264). The CLI caller is ClassifyCommand.swift (see Sources/LungfishCLI/AGENTS.md). The GUI caller is AppDelegate+Classification.swift (see Sources/LungfishApp/AGENTS.md). The GUI builds the `lungfish-cli conda classify` command it records with `ClassificationCLIInvocationBuilder` (Metagenomics/ClassificationCLIInvocationBuilder.swift line 23), so an option added to ClassifyCommand must be added there too.

## Contracts this module owns

- Alignments are written as sorted, indexed BAM. Never leave SAM on disk (memory file reference_runtime_patterns.md).
- A virtual FASTQ bundle holds only preview.fastq, so classifiers and mappers receive materialized FASTQ (memory file project_virtual_fastq_materialization.md).
- Every run writes a provenance envelope with a non-nil command (REVIEW.md invariants).
- Viral Recon binds a .lungfishref manifest, never a loose BAM, and never swaps MN908947.3 for NC_045512.2 (memory file project_viral_recon_results_integration.md).
- Coverage ignores CIGAR deletions and N skips (REVIEW.md R13).

## Tests

Target LungfishWorkflowTests in Tests/LungfishWorkflowTests, with subfolders that mirror these subtrees. Run only it with `swift test --skip-update --filter LungfishWorkflowTests`. Real-tool suites such as ClassificationPipelineIntegrationTests sit in the conformance tier (see Tests/AGENTS.md).

## Known traps

| Trap | Evidence |
|---|---|
| Every Nextflow start takes its executable and environment from `WorkflowEngineLaunch`. It puts the managed engine's bin first on PATH, sets JAVA_HOME to the engine's bundled JDK and sets NXF_HOME for the app channel. A start needs the managed engine (`resolveManaged`), so a Nextflow found on PATH never runs. A caller adds its own settings with `overridingEnvironment` and never builds a second environment, as TaxTriage does for its micromamba root and conda profile. Hand-built environments once left out JAVA_HOME, and Nextflow then fails on a Mac without a system JDK | WorkflowEngineLaunch.swift, `buildLaunchEnvironment` in TaxTriage/TaxTriagePipeline.swift, `nextflowLaunch` in PBAA/PBAAClusteringPipeline.swift and Engines/NextflowRunner.swift, `getEngineVersion` in WorkflowRunner.swift (R7) |
| `CondaManager.runTool` has a 3600 s default timeout and different PATH rules from `NativeToolRunner` | Conda/CondaManager.swift line 1118 (R2, R17) |
| Shelling out to a tool macOS does not ship | Bundles/ReferenceSourcePreparer.swift line 227 runs `zstd` (R7) |
| Mapper indexes are rebuilt per run inside the output folder | Mapping/ManagedMappingPipeline.swift lines 521 to 539 (R17) |
| Provenance still emits a legacy run inside the envelope | Provenance/ProvenanceEnvelope.swift lines 81, 82, 113 and 139 (R8) |
| `IngestionPlatform` (`illumina`, `ont`, `pacbio`, `ultima`) is the import subset of `LungfishIO.SequencingPlatform`. Its raw values are the `import fastq --platform` values that recipe files, import provenance and replay commands record, while the FASTQ sidecar records the LungfishIO spelling, so `ont` becomes `oxfordNanopore`. Map between them with `sequencingPlatform` and `init(importing:)`. Element, MGI and Unknown import as `illumina`, and the sidecar then says Illumina | Recipes/IngestionPlatform.swift lines 52, 146 and 161, `persistedSequencingPlatform` in Ingestion/FASTQBatchImporter.swift, Tests/LungfishWorkflowTests/Recipes/WorkflowPlatformPinTests.swift (R15) |
| Without `--platform`, `lungfish-cli import fastq` detects the platform with `IngestionPlatform.detect(fromFASTQHeader:)`, not the LungfishIO detector, and imports as Illumina when it finds nothing. It finds nothing for Revio CCS headers and dorado SAM-tag headers, so a PacBio or ONT bundle imported that way is recorded as Illumina short reads | Recipes/IngestionPlatform.swift line 114, `detectPlatformFromPairs` in Sources/LungfishCLI/Commands/ImportFastqCommand.swift (R15) |
| A new `NativeTool` case without a `nativeToolPolicies` entry makes every run of it throw `missingProvenancePolicy` | Provenance/ScientificProvenancePolicy.swift line 208, Native/NativeToolRunner.swift line 1145 |
| Install paths with spaces break samtools and ivar pipes, so conda lives under ~/.lungfish/conda | memory file project_conda_plugins.md |
| nf-core/viralrecon 3.0.0 accepts `--gff` only as `.gff` or `.gff.gz`, so a reference bundle's `genome/genes.gff3` fails parameter validation 20 s into a run. `lungfish-cli workflow run nf-core/viralrecon`, and no other workflow, copies the annotation to `inputs/reference/genes.gff` in the run bundle with its bytes unchanged and records `stagedAnnotation` in provenance. `additional_annotation` has the same rule and is not staged | ViralRecon/ViralReconAnnotationStaging.swift, `NFCoreLaunchStaging.stageAnnotation` in Sources/LungfishCLI/Commands/NFCoreLaunchStaging.swift |
| The Map Reads window, `lungfish-cli map`, the classifier launches, `lungfish-cli conda classify` and `lungfish-cli assemble` resolve a bundle to every file it holds through `ResolvedSequenceInputs` (`FASTQSourceResolver` underneath), while `fastq demultiplex` still resolves one primary file per input through `CLISequenceInputMaterialization.resolveExecutionInputs`. `lungfish-cli fastq materialize` writes every file of a multi-file root bundle, in `source-files.json` order, into its one output (`ResolvedSequenceInputs.concatenateMultiFileBundle`), as the app's one-file resolution of a bundle joins them, and `FASTQCLIMaterializer` alone still returns chunk 0 for such a bundle. The two are not interchangeable for a bundle with several files (an ONT multi-file import, a `fullPaired` or `fullMixed` derivative), so swapping one for the other changes which reads a tool maps. For a mapper or an assembler the several unpaired files of one bundle are concatenated into one execution file (`concatenateUnpairedFiles`, recorded as a `cat` step through the `<file>.sources.json` sidecar), the R1 and R2 of a mate pair stay apart (`MatePairFileNaming` is the window's grouper convention, pinned by a parity test in LungfishAppTests), and the classifier launches and `conda classify` leave concatenation off, so every file of a bundle is its own kraken2 input. A mapping request carries the lineage with `withInputLineage` so the pipeline records the bundle, its manifest, the root FASTQ, the payload and the materialization step | Mapping/ResolvedSequenceInputs.swift, Mapping/MatePairFileNaming.swift, Extraction/CLISequenceInputMaterialization.swift line 109, Mapping/ManagedMappingPipeline.swift `mappingInputRecords`, the LungfishCLI commands ClassifyCommand, AssembleCommand and FastqMaterializeSubcommand (R3, lanes 1m and 1n) |

Do not change pipeline, runner, provenance or materializer logic without reference outputs captured first (plan, "What must NOT be changed tonight").
