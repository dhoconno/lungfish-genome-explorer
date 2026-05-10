# FASTA Support for FASTQ Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the current FASTQ-oriented operation surface so multi-FASTA inputs can flow through mapping, assembly, classification, and derivative operations wherever the underlying tool can consume FASTA directly, while inserting a synthetic FASTQ bridge only for operations that still require FASTQ-like input semantics.

**Architecture:** Introduce a sequence-format-aware capability layer instead of treating read-class detection as synonymous with FASTQ. Let UI/catalog exposure, request validation, and workflow builders distinguish native FASTA-compatible tools from tools that need a synthetic FASTQ materialization step. Keep the bridge localized to execution paths that truly need it so existing FASTQ behavior and other sessions’ in-flight work stay isolated.

**Tech Stack:** Swift, AppKit/SwiftUI dialog state, LungfishIO bundle/materialization services, LungfishWorkflow mapping/assembly/metagenomics pipelines, XCTest, `swift test`.

---

## File Structure

### Capability Model and FASTA Tool Exposure

- Modify: `Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift`
- Modify: `Sources/LungfishIO/Formats/FASTQ/OperationChain.swift`
- Test: `Tests/LungfishAppTests/FASTAOperationCatalogTests.swift`
- Test: `Tests/LungfishIOTests/SequenceRecordTests.swift`

### Mapping, Assembly, and Classification FASTA Routing

- Modify: `Sources/LungfishWorkflow/Mapping/MappingInputInspection.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingTool.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingCompatibility.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/MapCommand.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyReadType.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/ClassifyCommand.swift`
- Test: `Tests/LungfishWorkflowTests/Mapping/MappingInputInspectionTests.swift`
- Test: `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`

### Synthetic FASTQ Bridge for FASTA Inputs

- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`
- Modify: `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/TaxTriageCommand.swift`
- Possibly modify: `Sources/LungfishCLI/Commands/FastqScrubHumanSubcommand.swift`
- Test: targeted workflow and routing tests covering adapter trim, demux, human scrub, EsViritu, and TaxTriage from FASTA-backed inputs

---

## Task 1: Lock the FASTA Capability Surface with Tests

**Files:**

- Modify: `Tests/LungfishAppTests/FASTAOperationCatalogTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Modify: `Tests/LungfishIOTests/SequenceRecordTests.swift`

- [ ] Add failing tests that mark these tools as FASTA-available in the catalog and dialog: `adapterRemoval`, `demultiplexBarcodes`, `removeHumanReads`, `minimap2`, `bwaMem2`, `bowtie2`, `bbmap`, `spades`, `megahit`, `skesa`, `flye`, `hifiasm`, `kraken2`, `esViritu`, `taxTriage`.
- [ ] Add failing tests that keep quality-dependent operations FASTQ-only, especially `qualityTrim`, `mergeOverlappingPairs`, `repairPairedEndFiles`, and `correctSequencingErrors`.
- [ ] Add failing tests that assert operation contracts accept FASTA for bridgeable operations without misclassifying them as native-quality-aware FASTQ tools.
- [ ] Run the focused test slice and confirm only the new FASTA expectations fail, plus the existing baseline raw-SAM cleanup failure.

## Task 2: Make Mapping, Assembly, and Classification Sequence-Format Aware

**Files:**

- Modify: `Sources/LungfishWorkflow/Mapping/MappingInputInspection.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingTool.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingCompatibility.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/MapCommand.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyReadType.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`
- Modify: `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/AssembleCommand.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/ClassifyCommand.swift`

- [ ] Add a format-aware inspection result for FASTA inputs so mapping validation can bypass FASTQ header-based read-class detection when the tool only needs sequences.
- [ ] Teach mapping compatibility to accept FASTA for all mappers and update request validation/error text to describe generic sequence input instead of only FASTQ.
- [ ] Update assembly compatibility and read-type selection so FASTA inputs can run on assemblers that accept sequence-only reads, with conservative bridging or fallback for unsupported ONT-specific cases.
- [ ] Update classification config and provenance labeling so Kraken2 and related generic classifiers can accept FASTA-backed inputs without pretending the input format is FASTQ.
- [ ] Refresh CLI help text and user-facing labels to describe sequence files rather than only FASTQ where the path now supports FASTA.

## Task 3: Localize the Synthetic FASTQ Bridge

**Files:**

- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`
- Modify: `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriageConfig.swift`
- Modify: `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/TaxTriageCommand.swift`
- Possibly modify: `Sources/LungfishCLI/Commands/FastqScrubHumanSubcommand.swift`

- [ ] Introduce a reusable FASTA-to-synthetic-FASTQ materialization path that assigns stable placeholder qualities and preserves record IDs.
- [ ] Route FASTA-backed `adapterRemoval`, `demultiplexBarcodes`, `removeHumanReads`, `esViritu`, and `taxTriage` requests through that bridge instead of rejecting them up front.
- [ ] Keep native FASTQ paths unchanged and ensure bridge outputs are staged in managed temp locations so existing bundle/import behavior still works.
- [ ] Add or update tests that prove FASTA inputs reach the bridge while FASTQ inputs continue to use the direct path.

## Task 4: Verify the End-to-End Surface

**Files:**

- Modify: targeted tests touched above

- [ ] Run focused tests for FASTA catalog exposure, dialog routing, mapping inspection/validation, and any bridge-specific workflow coverage.
- [ ] Run a broader targeted regression for mapping, assembly, and metagenomics entry points to catch help-text and request-shape regressions.
- [ ] Document any intentionally deferred cases, especially if `MEGAHIT` or ONT `hifiasm` still require a bridge or a conservative restriction after implementation.
