# Shared Context Brief — Amplicon Genotyping + 12S Expert Review

Every review agent receives this identical brief. Read it fully before reviewing.

## Where you are working

- **Worktree (review THIS, use absolute paths):**
  `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching`
- **Branch:** `codex/12s-amplicon-matching`
- **App:** Lungfish Genome Explorer (LGE), a Swift 6.2 macOS app (macOS 26 Tahoe, Apple
  Silicon), SPM build. Modules: LungfishCore, LungfishIO, LungfishUI, LungfishPlugin,
  LungfishWorkflow, LungfishApp, LungfishCLI. `@Observable` + `@MainActor` + strict concurrency
  throughout.
- **Spec (the authority on scope and intent):**
  `docs/superpowers/specs/2026-05-30-amplicon-12s-review-and-improvement-design.md`. Read it.

## What this review is about (the central goal)

A **comprehensive** review of two niche analysis workflows recently built/changed in this
worktree, from two lenses:

1. **Swift/AppKit engineering** — correctness, concurrency safety, code reuse, portability,
   maintainability.
2. **End-user UX consistency** — the new functionality must reuse existing LGE idioms, and
   equivalent operations across workflows must use the same interface.

Depth and completeness matter more than speed. This is the heart of the effort, not a
formality.

### The two workflows

- **Amplicon Genotyping (MHC/KIR)** for nonhuman primates. NOT a new separately-enabled
  workflow; it enhances the existing ONT and prepared-Illumina genotyping workflows.
- **12S amplicon matching** for environmental samples (which 12S species are present). This IS
  its own Workflow-Manager opt-in entry.

## Review surface (review BOTH in their entirety; compare against the rest of LGE)

### 12S amplicon matching
- CLI: `FastqTwelveSMatchSubcommand.swift`, `FastqTwelveSReferenceBundleSubcommand.swift`,
  `FastqTwelveSReferenceMetadataSubcommand.swift`, `FastqTwelveSExportSubcommands.swift`,
  `FastqCommand.swift`, `LungfishCLI.swift`.
- Workflow: `Sources/LungfishWorkflow/TwelveS/*` (`TwelveSAmpliconMatchingWorkflow.swift`,
  `TwelveSAmpliconReadClassifier.swift`, `TwelveSReferenceIndex.swift`,
  `TwelveSReferenceMetadata.swift`, `TwelveSReferenceBundleBuilder.swift`,
  `TwelveSChimeraReview.swift`, `TwelveSFastqReader.swift`, `TwelveSResultExportWorkflow.swift`).
- IO/bundles: `TwelveSAmpliconResultBundle.swift` (1028 lines), `TwelveSReferenceBundle.swift`,
  `TwelveSTaxonGroupResolver.swift`.
- GUI: `Views/Results/TwelveS/*` (`TwelveSAmpliconResultViewController.swift` 846 lines,
  `TwelveSAmpliconResultExportService.swift`, `TwelveSResultDisplayState.swift`),
  `Views/Inspector/Sections/TwelveSResultDisplaySection.swift`,
  `Views/Viewer/ViewerViewController+TwelveS.swift`.

### Amplicon Genotyping (MHC/KIR)
- Pipeline: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`.
- Haplotype system: `HaplotypeDefinitionCommandService.swift`,
  `Sources/LungfishIO/Bundles/HaplotypeDefinitionLibrary.swift`,
  `Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift`.
- CLI: `FastqGenotypingSubcommand.swift`, `HaplotypeDefinitionsCommand.swift`.
- New `.lungfishmhcref` bundle: `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift`,
  `Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift`,
  `FastqMHCReferenceBundleSubcommand.swift`.
- GUI: `Views/Results/Genotype/*` (esp. `GenotypeResultViewController.swift`,
  `GenotypeResultDisplayState.swift`, `GenotypeCohortSummaryPanelView.swift`),
  genotype Inspector changes in `Views/Inspector/InspectorViewController.swift`,
  `Views/Sidebar/SidebarViewController.swift`, `Views/Viewer/ViewerViewController+Genotype.swift`.

### Cross-cutting (connective tissue, also in scope)
- Enablement: `Services/WorkflowLibrary.swift`,
  `Views/WorkflowOperations/WorkflowOperationDialogState.swift`,
  `Services/WorkflowOperationExecutionService.swift`,
  `Views/WorkflowOperations/WorkflowOperationsDialog.swift`,
  `Views/WorkflowOperations/WorkflowOperationsWindowController.swift`.
- Format registry: `Sources/LungfishIO/Registry/FormatIdentifier.swift`,
  `Sources/LungfishIO/Registry/FileTypeUtility.swift`.
- Sample metadata: `Sources/LungfishCore/Models/SampleMetadataResolver.swift`,
  `SampleMetadataStore.swift`, `Formats/FASTQ/FASTQSampleMetadata.swift`,
  `Views/Inspector/Sections/SampleMetadataSection.swift`,
  `Views/Inspector/Sections/FASTQMetadataSection.swift`.
- Shared BLAST drawer: `Views/Metagenomics/BlastResultsDrawerTab.swift`.

## Specific features/fixes to scrutinize
- **Simultaneous multi-bundle MHC genotyping** (Illumina sample-bundle batch path:
  `AmpliconGenotypingMode`, `IlluminaPreparation`, `resolveMode`, `prepareIlluminaInputs`,
  `isBatch`). Check mode inference, per-sample isolation, batch provenance.
- **New reference bundle formats** `.lungfishmhcref` and `.lungfish12sref`: do they share a
  coherent pattern and integrate with the format registry like existing `.lungfishref`?
- **Haplotype manager** (`HaplotypeDefinitionManagerWindowController` /
  `HaplotypeDefinitionManagerViewModel`): new/edit/import/export/duplicate/delete,
  `replaceReferenceFASTA`, `revealReferenceFASTA`, `createMHCReferenceBundle`. Check CLI-backing,
  scope handling (built-in/global/project), idiom consistency.

## Known candidate findings (inputs, not a substitute for your own review)
1. **12S workflow on by default** — `WorkflowLibraryEnablementStore.defaultEnabledWorkflowIDs`
   includes `WorkflowLibraryCatalog.twelveSAmpliconMatchingID`; intent is opt-in.
2. **`.lungfishmhcref` created but not consumed for genotyping** — produced by the haplotype
   manager (`createMHCReferenceBundle`, CLI-backed via `FastqMHCReferenceBundleSubcommand`), but
   `FastqGenotypingSubcommand` still takes a separate `--reference` FASTA + independent
   `--haplotype-definition`/`--haplotype-assay`/`--haplotype-species`. Intent: genotyping works
   *against* the bundle (FASTA + paired haplotype defs).
3. **Low-abundance-noise filtering uses two different interfaces** — 12S: editable
   "Minimum Exact Reads" TextField+Stepper (`TwelveSResultDisplaySection` ->
   `displayState.minimumExactReads`); MHC: fixed ~5K threshold hardcoded in
   `GenotypeCohortSummaryPanelView` (`belowThresholdValue`). Same intent, divergent interface.

## Binding rules to apply (from project memory)

- **Background -> MainActor dispatch:** NEVER `Task { @MainActor in }` from a GCD background
  context; NEVER bare `DispatchQueue.main.async` to touch `@MainActor` state; NEVER `await` a
  `@MainActor` member from `Task.detached`. Use
  `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` for UI
  callbacks, or drop `@MainActor` + use `@unchecked Sendable` + actors for long-running
  pipelines.
- **String formatting:** NEVER `%s` in `String(format:)` with Swift Strings (SIGSEGV) — use
  `%@` or interpolation. `ArgumentParser.GlobalOptions()` direct-init crashes; use
  `GlobalOptions.parse([])`. In `@Sendable` closures prefer free functions over instance methods.
- **Concurrency:** `@Observable` + `@MainActor` + strict concurrency; check `Sendable`
  correctness, generation counters on async fetches to reject stale results.
- **Provenance:** pipeline operations call BOTH `OperationCenter.shared.update()` AND `.log()`.
  Canonical `.lungfish-provenance.json` written by every data-writing pathway. CLI argv uses
  `lungfish-cli`. NEVER save alignment as SAM (sorted/indexed BAM only).
- **GUI idioms to reuse:** classifier-style information architecture; `ClassifierActionBar`;
  shared bottom BLAST drawer (`BlastResultsDrawerContainerView` / `BlastResultsDrawerTab`);
  `ReferenceSequencePickerView` for reference selection; `SampleMetadataSection` for metadata.
- **Accent color:** Lungfish Orange `#D47B3A` (dark `#E8A06A`). Classification tool colors:
  Kraken2=blue, EsViritu=green, TaxTriage=purple, NAO-MGS=amber.
- **Every scientific GUI action must shell out to `lungfish-cli`** and preserve CLI provenance.
- **Docs prose rules** (if you note doc issues): no em dashes; bullet caps.

## Your deliverable

- Read-only review. **Do NOT edit code.** Only write your own report file.
- Write to the exact path given in your dispatch prompt.
- Use this finding schema (one row per finding):
  `ID | Severity (P0/P1/P2) | Surface (12S / MHC / cross-cutting) | Location (file:line) |
  Problem | Evidence | Suggested fix | Effort (S/M/L)`
  - **P0** = correctness, concurrency hazard, provenance gap, data loss, crash.
  - **P1** = UX-idiom mismatch, cross-workflow divergence, missing shared-component reuse,
    terminology drift.
  - **P2** = reuse refactor / maintainability improvement.
- Cover BOTH workflows. If a surface is clean for your lens, say so explicitly rather than
  staying silent.
