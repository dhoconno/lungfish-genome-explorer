# 12S Reference Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build first-class `.lungfish12sref` bundles for complete 12S amplicon references and use them from CLI and GUI 12S matching.

**Architecture:** Add a small `LungfishIO` bundle model that stores the deduplicated FASTA, generated target metadata TSV, source metadata inputs, build metrics, and provenance. Add a `LungfishWorkflow` builder that reuses the existing 12S metadata builder, writes bundle-level provenance, and exposes the bundle to the existing matcher by resolving it to FASTA plus metadata. Add CLI creation support and GUI workflow-operation support for selecting and creating the bundle.

**Tech Stack:** Swift, ArgumentParser, AppKit/SwiftUI, existing Lungfish provenance APIs, existing `TwelveSReferenceMetadataBuilder`, existing `TwelveSAmpliconMatchingWorkflow`.

---

### Task 1: Bundle Model

**Files:**
- Create: `Sources/LungfishIO/Bundles/TwelveSReferenceBundle.swift`
- Modify: `Sources/LungfishIO/Registry/FormatIdentifier.swift`
- Modify: `Sources/LungfishIO/Registry/FileTypeUtility.swift`
- Test: `Tests/LungfishIOTests/TwelveSReferenceBundleTests.swift`

- [ ] Add `TwelveSReferenceBundleManifest` with `schemaVersion`, `kind`, `name`, `referenceFastaPath`, `targetMetadataPath`, `sourceFiles`, `metrics`, `provenancePath`, and `createdAt`.
- [ ] Add `TwelveSReferenceBundle` helpers for `directoryExtension`, manifest read/write, URL resolution, and `isBundleURL`.
- [ ] Register `.lungfish12sref` as a reference-bundle-like file type.
- [ ] Test manifest round trip and URL resolution.

### Task 2: Bundle Builder

**Files:**
- Create: `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceBundleBuilder.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`
- Test: `Tests/LungfishWorkflowTests/TwelveSReferenceBundleBuilderTests.swift`

- [ ] Add `TwelveSReferenceBundleBuildConfiguration` with deduplicated FASTA, MIDORI metadata TSV, optional display name, output URL, optional source files/directories, force flag, and argv.
- [ ] Build the bundle by copying the FASTA, generating `target-metadata.tsv`, copying optional source files, computing metrics from the generated metadata, writing manifest, and writing bundle-level provenance.
- [ ] Include exact input/output paths, checksums via `ProvenanceRunBuilder`, resolved defaults, argv, wall time, and exit status.
- [ ] Test that the generated bundle can enrich a 12S reference index with taxid, taxon group, taxonomy, and alternate matches.

### Task 3: CLI Support

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqTwelveSReferenceBundleSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqTwelveSMatchSubcommand.swift`
- Test: `Tests/LungfishCLITests/FastqTwelveSMatchSubcommandTests.swift`

- [ ] Add `fastq 12s-reference-bundle --dedup-fasta --midori-metadata --output [--name] [--source-file ...] [--source-directory ...] [--force]`.
- [ ] Keep `fastq 12s-match --reference` backward compatible with raw FASTA, but allow `.lungfish12sref` paths and resolve them to FASTA plus metadata.
- [ ] Preserve user argv in provenance so replay uses the bundle path when the user supplied the bundle path.
- [ ] Test command registration, parser behavior, and config resolution for `.lungfish12sref`.

### Task 4: GUI Workflow Support

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`

- [ ] Discover `.lungfish12sref` bundles under project `Reference Sequences`.
- [ ] Resolve `.lungfish12sref` into FASTA plus metadata for 12S matching launch requests.
- [ ] Add a small CLI-backed “Create 12S Reference…” sheet in the 12S workflow reference section. The sheet gathers deduplicated FASTA, MIDORI metadata TSV, output name/location, optional source directory, and calls `lungfish-cli fastq 12s-reference-bundle`.
- [ ] Refresh project reference candidates and select the created bundle after successful build.
- [ ] Test state-level discovery and launch request resolution.

### Task 5: End-to-End Verification

**Files:**
- No source files unless tests expose gaps.

- [ ] Build a `.lungfish12sref` from `/Users/dho/Downloads/32308/ref/amplicons_deduplicated.fa` and `/Users/dho/Downloads/32308/intermediate/12s_reference.tsv`.
- [ ] Run `fastq 12s-match` with the example FASTQ bundle/input and the new `.lungfish12sref`.
- [ ] Verify result `targets.tsv` has populated `taxid`, `taxon_group`, and `taxonomy` for common rows such as `Homo sapiens`.
- [ ] Run focused tests and build a debug app.
