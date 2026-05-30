# Amplicon Genotyping + 12S Review and Improvement Design

**Date:** 2026-05-30
**Worktree:** `.worktrees/12s-amplicon-matching` (branch `codex/12s-amplicon-matching`)
**Status:** Approved design, ready for implementation planning

## Goal

Review the entire uncommitted code surface of the `12s-amplicon-matching` worktree from
two lenses, then improve it before manual GUI testing. The review surface covers **both**
analysis capabilities equally:

- The **Amplicon Genotyping (MHC/KIR)** workflow and its improvements in this worktree
  (genotyping pipeline, haplotype-definition system, genotyping CLI, the new `.lungfishmhcref`
  bundle, and the genotype viewport/Inspector/sidebar changes).
- The **12S amplicon matching** workflow (matching engine, `.lungfish12s` / `.lungfish12sref`
  bundles, 12S viewport/Inspector, and CLI subcommands).

Both surfaces get equal footing under both lenses:

1. **Swift/AppKit engineering** lens: correctness, concurrency safety, code reuse,
   portability, maintainability.
2. **End-user UX consistency** lens: the new functionality must reuse existing LGE GUI
   idioms. No bespoke widget or object style that duplicates functionality already present
   elsewhere in the app with a different interface.

Every scientific action must be CLI-backed so the work can be end-to-end tested with real
and synthetic data before anything is called "done."

## Product Context

Two niche analysis capabilities (most users will not need them; users who do should be able to
enable them and immediately gain the functionality and bundle types):

- **Host-locus amplicon genotyping/haplotyping** (MHC/KIR) for nonhuman primates: interactive
  exploration and understanding of complex genotyping and haplotyping results. This is **not**
  a new separately-enabled workflow; it enhances the existing ONT and prepared-Illumina
  genotyping workflows already in the app.
- **12S amplicon matching** for complex environmental samples: determine which 12S species are
  present. This **is** its own Workflow-Manager opt-in entry, parallel to other specialized
  workflows.

## Cross-Workflow Consistency Requirement

The two workflows share substantial user intent even though they have different viewports and
results-exploration tools. Wherever they perform the **same kind of operation**, they must use
the **same interface idiom** rather than two parallel implementations that happen to do the
same thing differently. This applies not only to the two new/changed workflows against each
other, but to both against the **rest of the existing LGE app** (classifiers, assembly,
variant, alignment surfaces).

This is a **class of defect to eliminate across the entire code surface**, not a checklist of
named cases. The low-abundance/minimum-read filter (12S `minimumExactReads` vs the MHC fixed
~5K threshold) is **one illustrative example, not the scope.** Do not fix the named example and
declare the requirement met. The same divergence almost certainly exists in operations no one
has named yet; the job is to find them.

### How thoroughness is enforced (not anecdotal)

Coverage must be **provable by inventory, not by spot-checking.** The review produces a
complete operation inventory before judging consistency:

1. For each surface (12S viewport + Inspector + dialog + CLI; genotype viewport + Inspector +
   haplotype manager + CLI), enumerate **every** user-facing operation and control: filters,
   thresholds, searches, include-exclude toggles, sort/group controls, export/action
   affordances, selection-detail behaviors, empty/error states, and the CLI flags that back
   them.
2. Build a cross-surface matrix keyed by **operation intent** (e.g. "suppress low-abundance
   noise", "free-text search", "include-exclude by category", "export current view"). For each
   intent, record how every surface implements it (widget type, label, live vs apply, backing
   state/CLI flag) and whether an existing shared LGE idiom already covers it.
3. Flag **every** intent where two surfaces diverge in interface, plus every operation that
   reinvents something the app already provides. Absence of divergence must be an explicit
   statement ("intent X is consistent across surfaces"), not silence.

Reviewers must inspect the surfaces **in their entirety**. A report that only addresses the
abundance filter, or only lists a handful of obvious cases, is incomplete and will be sent
back. The matrix is a required Phase 2 artifact and feeds the synthesis directly.

## Current State (from exploration)

Three feature threads, each with its own committed design + plan under
`docs/superpowers/`:

- 12S amplicon matching (`2026-05-27-12s-amplicon-matching.md`)
- Canonical sample metadata (`2026-05-28-canonical-sample-metadata.md`)
- 12S reference bundle (`2026-05-30-12s-reference-bundle.md`)

Plus MHC amplicon reference bundle work (no standalone plan doc).

Surface size: ~3,700 lines of tracked changes across all 7 modules, plus ~12,000 lines of
new untracked files.

### 12S amplicon matching surface

New CLI subcommands (`12s-match`, `12s-reference-bundle`, `12s-reference-metadata`, 12S
exports), new bundle types (`.lungfish12s`, `.lungfish12sref`), a new AppKit viewport
(`TwelveSAmpliconResultViewController`, 846 lines), Inspector sections, and a sample-metadata
resolver in `LungfishCore`.

### Amplicon Genotyping (MHC/KIR) surface

The existing genotyping workflow received substantial changes in this worktree, all in scope
for review:

- Genotyping pipeline: `ONTBarcodeDemuxGenotypingPipeline.swift` (+43).
- Haplotype-definition system: `HaplotypeDefinitionCommandService.swift` (+452),
  `HaplotypeDefinitionLibrary.swift` (+82),
  `HaplotypeDefinitionManagerWindowController.swift` (+269).
- Genotyping CLI: `FastqGenotypingSubcommand.swift` (+22), `HaplotypeDefinitionsCommand.swift`
  (+149).
- New `.lungfishmhcref` bundle: `MHCAmpliconReferenceBundle.swift` (model),
  `MHCAmpliconReferenceBundleBuilder.swift` (builder),
  `FastqMHCReferenceBundleSubcommand.swift` (CLI).
- Genotype GUI: `GenotypeResultViewController.swift`, genotype Inspector changes in
  `InspectorViewController.swift`, `SidebarViewController.swift`,
  `WorkflowOperationsWindowController.swift`, `ViewerViewController+Genotype.swift`.

### Specific features/fixes in this worktree the review must cover

Beyond the two workflows in the abstract, the review must explicitly cover these concrete
changes:

- **Simultaneous multi-bundle MHC genotyping.** Illumina mode accepts multiple prepared
  per-sample bundles in one run; the pipeline has a batch path (`AmpliconGenotypingMode`,
  `IlluminaPreparation`/`IlluminaSampleInput`, `resolveMode`, `prepareIlluminaInputs`,
  `isBatch`) and a comparison/report label. Review correctness of mode inference, batch
  iteration, per-sample isolation, and provenance for batch runs.
- **New reference bundle formats.** `.lungfishmhcref` (FASTA + paired haplotype definitions)
  and `.lungfish12sref` (deduplicated FASTA + target metadata). Review whether they share a
  coherent reference-bundle pattern and integrate with the format registry
  (`FormatIdentifier`, `FileTypeUtility`) the way existing `.lungfishref` bundles do.
- **Haplotype manager functionality.** `HaplotypeDefinitionManagerWindowController` /
  `HaplotypeDefinitionManagerViewModel` gained new/edit/import/export/duplicate/delete,
  `replaceReferenceFASTA`, `revealReferenceFASTA`, and `createMHCReferenceBundle` (CLI-backed).
  Backed by `HaplotypeDefinitionCommandService` (+452) and `HaplotypeDefinitionLibrary` (+82).
  Review CLI-backing, scope handling (built-in/global/project), and idiom consistency of the
  manager window.

### Cross-cutting changes (connective tissue, also in scope)

Both workflows ride on shared infrastructure changed in this worktree:

- Workflow enablement: `WorkflowLibrary.swift` (+73), `WorkflowOperationDialogState.swift`
  (+312), `WorkflowOperationExecutionService.swift` (+300).
- CLI registration: `FastqCommand.swift`, `LungfishCLI.swift`.
- Format registry: `FormatIdentifier.swift` (+14), `FileTypeUtility.swift` (registering the
  new bundle extensions).
- Sample metadata: `SampleMetadataResolver.swift` (new, `LungfishCore`),
  `SampleMetadataStore.swift`, `FASTQSampleMetadata.swift`, and the Inspector metadata
  sections.
- Shared drawer: `BlastResultsDrawerTab.swift` changes (the bottom BLAST drawer both
  classifier-style surfaces reuse).

### Known gaps / candidate findings spotted during exploration

These are pre-identified inputs to the review, not a substitute for it:

1. **12S workflow is on by default.** `WorkflowLibraryEnablementStore.defaultEnabledWorkflowIDs`
   includes `WorkflowLibraryCatalog.twelveSAmpliconMatchingID`. The product intent is opt-in.
   Likely a P0/P1 fix.
2. **`.lungfishmhcref` bundle is created but not consumed for genotyping.** The bundle is
   *produced* from the haplotype manager (`HaplotypeDefinitionManagerWindowController.createMHCReferenceBundle`,
   CLI-backed via `FastqMHCReferenceBundleSubcommand`), and `MHCAmpliconReferenceBundle`
   (model) + `MHCAmpliconReferenceBundleBuilder` exist with tests. But **no genotyping consumer**
   reads it: the genotyping CLI (`FastqGenotypingSubcommand`) still takes a separate
   `--reference` FASTA and resolves haplotype definitions independently
   (`--haplotype-definition` / `--haplotype-assay` / `--haplotype-species`). The product intent
   is that MHC genotyping works *against* the new bundle, which pairs the genotyping FASTA with
   the haplotype definitions specific to that FASTA. Closing this consume-side wiring gap is
   almost certainly improvement-phase work, and it is a hard verification gate (Phase 5).
3. **Low-abundance-noise filtering uses two different interfaces.** Both workflows need to
   suppress or flag low-abundance reads that are noise (12S genotyping; MHC typing), but they
   express the same intent differently today. 12S exposes a user-editable Inspector control,
   "Minimum Exact Reads" (TextField + Stepper, `TwelveSResultDisplaySection` ->
   `displayState.minimumExactReads`), that live-filters target rows. MHC genotype uses a
   *fixed* absolute read threshold (~5K) hardcoded in `GenotypeCohortSummaryPanelView`
   (`belowThresholdValue`) that only flags below-threshold samples as unreliable, rather than
   an equivalent interactive Inspector filter on `GenotypeResultDisplayState`. This is a
   cross-workflow consistency defect: the same operation should use the same interface idiom.
   See the cross-workflow consistency requirement below.

## Approach: Five Phases with a Review/Improvement Gate

The governing principle: **review produces findings, the user sees them, then we plan and
improve.** Do not jump from review directly into edits.

### Phase 1: Baseline verification + commit

- Run `swift build` for both products (`Lungfish`, `lungfish-cli`).
- Run `swift test` with filters `TwelveS`, `SampleMetadata`, `Provenance`, plus the
  genotyping/haplotype filters (`Genotyp`, `Haplotype`, `ONTBarcodeDemux`) so the MHC surface
  is covered in the baseline too.
- If green: commit the entire current worktree state as a labeled baseline.
- If red: stop, report failures, ask before committing. (Do not commit a knowingly broken
  baseline without explicit user direction.)

### Phase 2: Parallel expert review (read-only, two teams)

Both teams run concurrently, dispatched in a single message. Each agent writes a structured
findings report to `docs/superpowers/reviews/2026-05-30-<agent>-findings.md` so raw reports
stay out of the orchestrator's context until synthesis.

Every agent receives the same context brief: worktree path, the three plan docs, the binding
memory rules (background to MainActor dispatch discipline, `%@` vs `String(format:)`,
`@Observable`/`@MainActor`/strict concurrency, GUI idioms, palette, accent color, viewport
interface classes, bundle/registry conventions), and the explicit instruction to compare new
code against existing app surfaces.

Each agent reviews **both** surfaces enumerated in Current State: the Amplicon Genotyping
(MHC/KIR) workflow changes **and** the 12S amplicon matching workflow. Neither is treated as
secondary; the genotyping/haplotype/`.lungfishmhcref` changes get the same scrutiny as the
12S code.

**Team A: Swift/AppKit engineering lens**

- `code-reviewer`: correctness bugs, concurrency hazards, error handling, force-unwraps,
  the `%@` / `String(format:)` traps, `Task`/MainActor dispatch rules. Covers both the 12S
  code and the genotyping/haplotype changes (`ONTBarcodeDemuxGenotypingPipeline`,
  `HaplotypeDefinitionCommandService`, `HaplotypeDefinitionLibrary`, the genotyping CLI).
- `architect-reviewer`: module boundaries, reuse vs duplication, portability, whether new
  bundles follow existing bundle/registry idioms. 12S suspects: the 846-line
  `TwelveSAmpliconResultViewController` and the 1028-line `TwelveSAmpliconResultBundle`. MHC
  suspects: the +452 `HaplotypeDefinitionCommandService`, the +269
  `HaplotypeDefinitionManagerWindowController`, and whether `.lungfishmhcref` /
  `.lungfish12sref` share a coherent reference-bundle pattern rather than two divergent ones.
- `swift-expert`: idiomatic Swift 6.2, `@Observable`/`@MainActor`/strict-concurrency
  conformance, `Sendable` correctness, API design of new types across both surfaces.

**Team B: End-user UX consistency lens**

- `frontend-developer` (AppKit): do the new/changed surfaces reuse existing LGE idioms
  (classifier-style information architecture, `ClassifierActionBar`, shared
  `BlastResultsDrawerTab`, `ReferenceSequencePickerView`, `SampleMetadataSection`)? Covers
  the 12S viewport/Inspector/dialog **and** the genotype surface
  (`GenotypeResultViewController`, genotype Inspector sections,
  `HaplotypeDefinitionManagerWindowController`). Flag any bespoke widget that duplicates
  existing functionality with a different interface, and any place where the 12S surface and
  the genotype surface solve the same problem two different ways. **Contribute the widget-level side of the
  operation-intent matrix** (see Cross-Workflow Consistency Requirement): for each operation
  intent the matrix lists, identify the concrete AppKit/SwiftUI control each surface uses and
  the existing shared LGE idiom it should converge on. Cover the full surface, not just the
  abundance filter (which is merely one row: 12S
  `TwelveSResultDisplaySection.minimumExactReads` vs MHC `GenotypeCohortSummaryPanelView`
  fixed threshold / `GenotypeResultDisplayState`). Propose the shared idiom for every divergent
  intent, and confirm the consistent ones.
- `ux-researcher`: end-to-end flow from a user's perspective for **both** workflows: for 12S,
  enable in Workflow Manager, import/merge, run, explore, export; for Amplicon Genotyping,
  select reference (including the `.lungfishmhcref` bundle), choose haplotype definitions, run,
  explore genotype/haplotype results. Flag friction, inconsistent terminology, the
  opt-in-default issue, and any cross-workflow inconsistency that would make the two feel like
  different apps. **Owns the operation-intent matrix** described in the Cross-Workflow
  Consistency Requirement: enumerate every user-facing operation across both surfaces (and
  compare against existing LGE surfaces), key them by intent, and flag every divergence. The
  abundance filter is one row, not the deliverable; the matrix must be exhaustive, and intents
  that are already consistent must be stated as such.

Synthesis: the orchestrator merges all five reports into one triaged findings doc at
`docs/superpowers/reviews/2026-05-30-synthesis.md`, and consolidates the operation-intent
matrix into `docs/superpowers/reviews/2026-05-30-operation-intent-matrix.md` as a standalone
artifact. Before accepting the reports, the orchestrator checks the matrix for completeness:
every surface enumerated, every intent either flagged as divergent or explicitly confirmed
consistent. An incomplete or spot-check-only matrix is sent back to the relevant agent.

### Phase 3: Triage + improvement plan

Triage each finding on severity x effort, grouped:

- **P0 correctness/concurrency/provenance**: bugs, MainActor dispatch hazards, `Sendable`
  gaps, provenance holes (executable name, tool versions, inputs), the opt-in-default fix,
  the `.lungfishmhcref` wiring gap.
- **P1 UX consistency**: bespoke widgets duplicating existing idioms with a different
  interface, terminology drift, missing shared-component reuse, and **cross-workflow
  divergence on equivalent operations** (the low-abundance filter and any others surfaced by
  the side-by-side map). Converging these on one shared Inspector idiom is a P1 deliverable.
- **P2 reuse refactors** (opted in by user): consolidate duplicated logic into shared
  components. The 846-line viewport and 1028-line bundle are prime suspects.

Present the triaged list with a proposed cut line. After the user confirms scope, invoke the
**writing-plans** skill to produce a task-by-task implementation plan. This spec defines the
*approach*; the plan defines the *steps*.

### Phase 4: Improvement implementation

Execute the plan with **test-driven-development**: failing test, implementation, green. Every
scientific action shells out to `lungfish-cli` and preserves CLI provenance. Each task is
verified before the next. Use parallel subagents for independent tasks where it is safe
(no shared state, no sequential dependency).

### Phase 5: End-to-end verification (real + synthetic)

Nothing is "done" until verified with both real and synthetic data, and results match
expectations.

**12S**
- Synthetic/deterministic: `swift test --filter TwelveS`.
- Real: build `.lungfish12sref` from `/Users/dho/Downloads/32308/ref/amplicons_deduplicated.fa`
  + `/Users/dho/Downloads/32308/intermediate/12s_reference.tsv`. The paired Hilo example
  (`/Users/dho/Downloads/HI_Hilo_WWTP_20260511__12S_F09_S69_L001_R{1,2}_001.fastq.gz`) is
  clumpified and merged into a single merged-FASTQ bundle by the amplicon import recipe on GUI
  import, which is how 12S receives its merged input; for a pure-CLI run, produce the merged
  FASTQ via that same recipe path first. Then run `fastq 12s-match`; confirm `targets.tsv` has
  populated `taxid` / `taxon_group` / `taxonomy` for known rows (e.g. `Homo sapiens`) and that
  `.lungfish-provenance.json` is canonical.

**MHC genotyping** (uses `/Users/dho/Desktop/sandbox/32271.lungfish` artifacts)
- Drive the existing ONT genotyping CLI against the barcode05-08 `.lungfishfastq` bundles,
  MHC/KIR `.lungfishref` references, and the Mauritian-cynomolgus haplotype definitions,
  materializing virtual FASTQ as needed (preview.fastq + chunks).
- **Multi-bundle gate:** run the genotyping CLI over multiple prepared sample bundles in a
  single invocation (the batch/Illumina-sample-bundle path) and confirm per-sample results,
  the comparison/report label, and batch provenance are correct.
- **Bundle-format gate:** MHC genotyping must also run against the new `.lungfishmhcref`
  bundle, which pairs the genotyping FASTA with the haplotype definitions specific to that
  FASTA. Verify the CLI resolves both the reference FASTA and the paired haplotype definitions
  from a single `.lungfishmhcref` input and produces the same genotype/haplotype result as the
  separate-inputs path.
- Compare against the project's existing `Analyses/Amplicon genotyping results` to confirm no
  regression.

**Sample metadata + provenance**
- `swift test --filter SampleMetadata` and `swift test --filter Provenance`.
- A CLI smoke run with a small metadata CSV.

**Cross-workflow consistency**
- Confirm the converged low-abundance/minimum-read filter behaves equivalently in both
  workflows: where the threshold is a CLI parameter, verify it changes results in a CLI run;
  where it is a display-state filter, verify via the display-state/view-controller tests
  (`TwelveSResultDisplaySection`/`GenotypeResultDisplayState`). Same control idiom, same
  semantics, two data bindings.

GUI testing is out of scope for this effort; it is the user's manual follow-up. The
deliverable is a verified, CLI-backed, idiomatically-consistent code surface.

## Out of Scope

- Manual GUI testing (user's follow-up).
- Unrelated refactoring not surfaced by the review.
- New MHC workflow enablement entry (MHC feeds existing ONT/Illumina genotyping).
- Paired-end read merging as a new feature. The amplicon import recipe already clumpifies and
  merges R1/R2 into a merged-FASTQ bundle on import; the 12S real-data run consumes that
  merged output.

## Verification Assets (confirmed present)

- 12S reference: `/Users/dho/Downloads/32308/ref/amplicons_deduplicated.fa`,
  `/Users/dho/Downloads/32308/intermediate/12s_reference.tsv`.
- 12S example reads: `/Users/dho/Downloads/HI_Hilo_WWTP_20260511__12S_F09_S69_L001_R{1,2}_001.fastq.gz`.
- MHC project: `/Users/dho/Desktop/sandbox/32271.lungfish` (barcode05-08 `.lungfishfastq`,
  `Reference Sequences/*.lungfishref`, `Haplotype Definitions/*.lungfishhaplotypedef.json`,
  existing `Analyses/Amplicon genotyping results`).
- Synthetic: inline fixtures in `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift`
  (12 test functions) and the other `TwelveS*`/`SampleMetadata*` test files.

## Success Criteria

- Baseline committed (Phase 1).
- Five findings reports + one synthesis (Phase 2).
- A complete operation-intent matrix (Phase 2): every surface enumerated, every operation
  intent either flagged divergent or explicitly confirmed consistent. Spot-check-only coverage
  does not satisfy this.
- User-approved triage and a written implementation plan (Phase 3). Every divergent intent from
  the matrix is either scheduled for convergence or explicitly accepted with a reason.
- Improvements implemented TDD-style, CLI-backed, each task verified (Phase 4).
- All Phase 5 verifications pass, including the `.lungfishmhcref` bundle-format gate for MHC
  genotyping, with outputs matching expectations.
