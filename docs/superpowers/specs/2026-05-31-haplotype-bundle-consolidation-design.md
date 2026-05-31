# Haplotype Definition Bundle Consolidation Design

**Date:** 2026-05-31
**Status:** Approved design (pending written-spec review), ready for implementation planning
**Branch target:** a fresh worktree off `main` (currently at `0.5.0-alpha9`, `e1b742ae`)

## Goal

Make every haplotype/genotype definition a self-contained `.lungfishmhcref` bundle that
includes its reference FASTA, remove built-in (app-shipped) and global (per-user) definition
scopes so each project explicitly stores the haplotyping/genotyping database it used, and
consolidate haplotype-definition management into a single home (the Tools menu window). This
makes it unambiguous, for any past or future analysis, which definition+reference were used.

## Motivation

- Today a haplotype definition can exist as a bare JSON (no reference FASTA) in built-in,
  global, or project scope, AND separately as a `.lungfishmhcref` bundle. The editor's "New
  haplotype definition" sheet has no reference-FASTA field, so a created definition has no
  recorded reference.
- Built-in definitions ship compiled into the app (`GenotypeHaplotypeDefinitionRegistry.builtIn`
  in `Sources/LungfishIO/Bundles/BuiltInGenotypeHaplotypeDefinitions.swift`) and are read-only;
  global definitions live in a per-user store. Neither is recorded per-project, so it is hard to
  know which version of a database produced a given analysis.
- Haplotype-definition management appears in three places (Tools menu, genotype analysis view,
  and the Inspector), duplicating CRUD controls.

## Design Decisions (approved)

1. **Bundle is the only form.** A haplotype definition IS a `.lungfishmhcref` bundle (manifest +
   `reference.fa` + `haplotypes/*.json`). The bare-JSON definition path is removed. Create/edit
   always requires a reference FASTA and writes/updates a bundle.
2. **Project-only scope.** Remove BOTH the `.builtIn` and `.global` scopes. Every `.lungfishmhcref`
   bundle lives in the project folder. No app-shipped live definitions, no per-user global store.
3. **Menu is the only manager.** Tools > Haplotype Definitions… is the sole create/edit/clone/
   delete surface. The genotype analysis view and the Inspector lose their definition-management
   controls; the Inspector keeps a one-line read-only "Definition: <name>" indicator.
4. **Provenance-only migration.** Nothing auto-converts. Existing genotype results keep their
   recorded provenance (which definition/version was used) and display that definition name
   read-only even if no live bundle matches. A project with no `.lungfishmhcref` bundle has no
   live definitions until the user creates or imports one.
5. **Thresholds stay analysis-level.** A definition bundle contains only the diagnostic-allele
   definitions (by locus) + the reference FASTA. The read-support thresholds (absolute reads,
   %-of-sample, %-of-locus, per-locus EQ) that decide whether a diagnostic allele is "supported"
   are an ANALYSIS-level lens, not part of the definition. Changing read filters (e.g. 1% → 5%)
   re-applies the same definition against the new thresholds and re-derives haplotype calls live.
6. **CLI builds bundles too.** `lungfish-cli fastq mhc-reference-bundle` (already present) must
   build a `.lungfishmhcref` from a FASTA + definition(s). The `haplotypes` command group's
   create/list/export become bundle-oriented (no bare-def output).
7. **Fold in concurrent capability/menu work.** The concurrent session's `WorkflowLibraryCapability`
   + `WorkflowFeatureAvailability` system (currently in `stash@{0}` + the working tree) — which
   shows the Haplotype Definitions / Workflow Operations menu items only when an enabled workflow
   declares that capability — is retained as the foundation for decision #3 (single home). Its one
   conflict with Task 7's enablement-notification change is resolved by unifying on one
   notification.

## Architecture

### Data model (LungfishIO / LungfishWorkflow)
- `HaplotypeDefinitionScope`: remove the `.builtIn` and `.global` cases, reducing the enum to a
  single `.project` case (least-churn path, since consumers reference `scope`; the plan may fully
  retire the enum if that proves cleaner, but the default is "reduce to `.project`"). Delete
  `builtInRecords()` and `globalRecords()` in `HaplotypeDefinitionLibrary.swift`; remove
  `GenotypeHaplotypeDefinitionRegistry.builtIn` as a live source (the compiled-in macaque sets).
  Also remove/neutralize the global store root and any `.global` UI affordances (e.g. the
  "Duplicate to global" action) in the manager window.
- `HaplotypeDefinitionLibrary.records(...)` returns only project `.lungfishmhcref` bundle records
  (via the existing `projectMHCReferenceBundleRecords()`); `HaplotypeDefinitionRecord`'s
  `referenceBundleURL`/`referenceFASTAURL` are always populated.
- No save path produces a bare definition. `HaplotypeDefinitionCommandService` keeps
  `createMHCReferenceBundle` / `saveDefinition(inMHCReferenceBundle:)` / `replaceReferenceFASTA`;
  remove (or repurpose) any bare-def write/list/export.
- `MHCAmpliconReferenceBundle` + `MHCAmpliconReferenceBundleBuilder` are unchanged (bundle format
  is already correct: `schemaVersion`+`kind`, FASTA + paired defs, validation).

### CLI (LungfishCLI)
- `fastq mhc-reference-bundle --reference-fasta <fa> --haplotype-definition <def.json> [...]
  --output <bundle.lungfishmhcref>`: confirmed working (used in alpha9 Phase-5 verification);
  remains the bundle builder. Verify it still builds correctly post-redesign.
- `haplotypes` subcommands: make create/list/export operate on `.lungfishmhcref` bundles; remove
  bare-def variants. Genotyping (`fastq genotype`/`ont-genotype`/`ont-barcode-genotype`) already
  consumes `.lungfishmhcref` (Task 6/6b) — now the only kind.

### UI (LungfishApp)
- **Menu (single home):** retain the folded-in capability gating — Tools > Haplotype Definitions…
  appears only when an enabled workflow declares `.haplotypeDefinitions`. The
  `HaplotypeDefinitionManagerWindowController` is the sole CRUD surface.
  - **Follow-up (capability assignment):** during the merge, the 12S item
    (`twelveSAmpliconMatchingItem`, the `id:`-based `WorkflowLibraryItem`) defaults to
    `capabilities: []` to preserve current behavior. When reworking this area, assign each
    optional workflow's capabilities correctly (e.g. 12S declares `.workflowOperations`; ONT
    genotyping declares `.workflowOperations` + `.haplotypeDefinitions`) so menu visibility is
    driven by real capability, not just `.ontGenotyping`. Consider also gating "show Haplotype
    Definitions…" on "the project contains a `.lungfishmhcref` bundle" once defs are project-scoped.
- **Editor gains a required Reference FASTA picker** (the visible fix): the "New haplotype
  definition" sheet adds a Reference FASTA row (reuse the `ReferenceSequencePickerView` idiom),
  required before Save. `newDraft` no longer sets `referenceFASTAURL: nil` as a permanent state.
- **Strip management from analysis view + Inspector:** remove the "Haplotype Definitions" CRUD
  sections (Clone/View/Use/Edit/Delete/"New empty definition…") from the genotype analysis view
  AND the Inspector. The Inspector keeps a one-line read-only "Definition: <name>" (from the
  result's active/recorded definition). Dropout/read-filter threshold controls STAY (they are
  analysis-level result tuning, not definition CRUD).
- Resolve the Task-7 vs stash@{0} notification conflict in `WorkflowLibrary.swift` by KEEPING BOTH
  notifications (per architect review): `.workflowLibraryEnablementDidChange` (Task 7's observers)
  AND `.workflowLibraryEnablementChanged` (stash@{0}'s menu-rebuild observer) are distinct with
  distinct subscribers, so both fire, under one `guard wasEnabled != enabled else { return }`
  no-op guard. (Already applied during the cleanup stream.)

### Example bundles (verification artifacts, NOT committed)
- Build two `.lungfishmhcref` bundles to `~/Downloads` (so the user can test importing them into a
  project), from the real definitions in `/Users/dho/Downloads/mhc_genotyper_for_github.ipynb`:
  - **MCM** (notebook `mcm` dict, PREFIX `Mafa`, 7 loci: MHC A/B/DPA/DPB/DQA/DQB/DRB) ←
    `/Users/dho/Downloads/MCM_MHC-all_mRNA-MiSeq_singles-RENAME_20Jun16.fasta`
  - **Indian rhesus** (notebook `indian_rhesus` dict, PREFIX `Mamu`, 7 loci) ←
    `/Users/dho/Downloads/26128_ipd-mhc-mamu-2021-07-09.miseq.RWv4.fasta`
- The notebook stores haplotypes as nested dicts: `MHC_<locus>_HAPLOTYPES = { '<haplotype>':
  [<diagnostic alleles>] }`, where a haplotype "requires" its listed diagnostic alleles (some
  tokens use `|`/`,` alternation). Convert each to a Lungfish `GenotypeHaplotypeDefinitionSet`
  (loci → haplotypes → required diagnostic alleles, using the existing K-of-N matching), then
  `mhc-reference-bundle` with the matching FASTA. A conversion script MAY live in the repo (e.g.
  `scripts/examples/`); the resulting bundle artifacts are written to `~/Downloads` and are NOT
  committed (derived data; used to manually verify import).

## Work streams & ordering

1. **Concurrent-work disposition + git hygiene (first).** Expert architect review of the 4 stashes
   + working tree against these goals: fold `stash@{0}` (capability/menu) in as the #4 foundation;
   evaluate `stash@{1}` (docs chapters — unrelated), `stash@{2}` (PluginPack status — unrelated),
   `stash@{3}` (945k-line JRE removal — likely superseded) and retain-by-merge or discard each per
   the goals; resolve the `WorkflowLibrary.swift` Task-7 conflict. Then `git worktree remove` the
   merged `.worktrees/12s-amplicon-matching`, delete the merged `codex/12s-amplicon-matching`
   branch, clear stashes per the review, and confirm clean local + remote `main`.
2. **Haplotype redesign (#3 then #4).** Data-model collapse (remove built-in/global, bundle-only)
   precedes the UI consolidation that reflects it. TDD throughout; CLI-backed.
3. **Remaining alpha9 follow-ups** (triaged after, since some overlap): sibling `lungfish-gui`
   argv normalization (already a spawned chip), the deferred P2 reuse refactors (separate batch
   decision), and a GUI-fidelity check of the new 12S pill controls + the new FASTA picker.

## Testing

- **Data model (unit):** `HaplotypeDefinitionLibrary` exposes only project bundle records (assert
  no built-in/global); the editor save always produces a `.lungfishmhcref` with a FASTA; a
  definition with no FASTA cannot be saved; `builtInRecords`/`globalRecords` and the compiled-in
  registry are gone (compile-time + behavioral assertions).
- **CLI:** `fastq mhc-reference-bundle` round-trips a bundle from FASTA + def; `haplotypes`
  create/list operate on bundles; genotyping consumes the project bundle (Task 6/6b coverage).
- **UI:** the folded-in `ImportCenterMenuTests` capability-gating retained + extended; the manager
  window is the only CRUD surface; the analysis/Inspector no longer expose definition CRUD; the
  Inspector shows a read-only active-definition label.
- **Provenance-only migration:** a genotype result whose recorded definition is now absent still
  renders its name read-only.
- **Real-data verification (Phase-5 style):** build the MCM + Indian-rhesus bundles to `~/Downloads`
  via the CLI from the notebook defs + the two FASTAs; confirm each bundle has the 7 loci and
  correct haplotype→diagnostic-allele structure; genotype a macaque dataset (e.g. the `32271`/
  `32307` assets) against an imported bundle and confirm calls + canonical provenance. GUI import
  of the `~/Downloads` bundles into a project is the user's manual check.

## Out of scope

- Auto-migrating existing built-in/global definitions into projects (provenance-only, per #4).
- Changing the `.lungfishmhcref` bundle format itself (already correct).
- The deferred P2 reuse refactors from the alpha9 effort (separate batch).
- Committing the example bundle artifacts (they go to `~/Downloads`).

## Success criteria

- A haplotype definition can only exist as a project `.lungfishmhcref` bundle (FASTA + defs); the
  editor requires a reference FASTA; built-in and global scopes are gone.
- Haplotype-definition management exists only in the Tools menu window (capability-gated);
  analysis/Inspector show the active definition read-only.
- `lungfish-cli` builds a `.lungfishmhcref`; the MCM + Indian-rhesus example bundles build to
  `~/Downloads` from the notebook + real FASTAs and import into a project.
- Existing analyses keep their recorded definition provenance.
- Full suite green; both products build; clean local + remote `main` with no leftover
  worktrees/branches/stashes.
