# LungfishWorkflow — Deferred Items (Phase 3)

Module: `Sources/LungfishWorkflow/**` (272 files, ~124K LOC). Largest non-App module.
Protocol: audit -> apply (behavior-preserving only) -> build + scoped tests ->
independent adversarial review -> revert-on-uncertainty -> commit.

Workflow-specific binding invariants (never refactor away):
- Every pipeline op calls BOTH `OperationCenter.shared.update()` AND
  `OperationCenter.shared.log()` (without `.log()`, only materialization steps persist
  in the expanded row history).
- Materialization semantics: `materializeInputFilesIfNeeded()` reconstructs full FASTQ
  from root + read IDs; config structs have mutable `inputFiles`/`fastq1`/`fastq2`;
  clean up materialized temps via `defer`. Do not alter which reads are materialized.
- NEVER save alignment as SAM (always sorted + indexed BAM via `samtools sort + index`,
  delete the intermediate SAM).
- Background->MainActor dispatch rules (never `Task { @MainActor in }` from GCD; use
  `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` or actors).

Big pipeline files (audit solo, largest first): ONTBarcodeDemuxGenotypingPipeline (5749),
FullLengthONTMHCGenotypingPipeline (3802), DemultiplexingPipeline (3569),
FASTQBatchImporter (1820), NativeToolRunner (1789), TaxTriagePipeline (1598),
AIHaplotypingPatchValidator (1516), ProvenanceExporter (1379), NativeBundleBuilder (1377),
MetagenomicsImportService (1316), etc. Clusters: ONTGenotyping/, Demultiplex/, Native/,
Conda/, Metagenomics/, TaxTriage/, Provenance/, Alignment/, Mapping/, Variants/, Builder/,
Engines/, Databases/, Extraction/, TwelveS/, MSA/, SequenceAnnotation/, Ingestion/.

## Deferred items

_(none yet — populated per batch as uncertain changes are reverted)_
