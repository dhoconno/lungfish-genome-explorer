# Batch Results Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multi-dataset tool runs write ONE `Analyses/<tool>-batch-<timestamp>/` folder containing per-sample results named by source bundle, on every fan-out surface (mapping, assembly, Savont), matching the existing classification-batch convention.

**Architecture:** A shared `AnalysesFolder` helper owns sample-subentry naming (sanitize + `-2`/`-3` dedup). Each fan-out orchestrator creates the batch directory once (`isBatch: true`), precomputes all child output paths in input order BEFORE dispatch, and hands each child its preassigned directory; per-child `createAnalysisDirectory` calls become single-run-only fallbacks. The sidebar's existing generic-batch rendering (`buildBatchAnalysisNode`) lights up unchanged except for flat-file child support verification.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftPM, XCTest. Spec: `docs/superpowers/specs/2026-08-09-batch-results-grouping-design.md` (READ IT FIRST — its numbered sections are cited below).

## Global Constraints

- Build/test from the worktree root; EXACTLY ONE swift invocation at a time; `--skip-update`; ALWAYS `--filter`, never the bare full suite.
- TDD: failing test first for every behavioral change. Zero new strict-concurrency warnings; no `@unchecked Sendable` in production code.
- Sample-name ordering invariant (spec §3): sample directory names are precomputed in original `inputURLs` order before any child dispatch, never inside concurrent child tasks.
- Single-dataset runs and combined/pooled runs must be byte-for-byte unchanged in behavior (regression tests pin this).
- Commits: `feat:`/`refactor:`/`fix:` + `(BG<n>)` task tag + trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task BG1: AnalysesFolder batch-sample helpers

**Files:**
- Modify: `Sources/LungfishIO/Bundles/AnalysesFolder.swift` (add two statics + private sanitizer)
- Test: `Tests/LungfishIOTests/AnalysesFolderTests.swift` (extend existing file if present, else create)

**Interfaces — Produces (later tasks compile against these exact signatures):**
```swift
public static func batchSampleDirectory(named sampleName: String, in batchDirectory: URL) throws -> URL
// Sanitizes, dedups against existing entries (-2, -3, …), CREATES the directory, returns it.

public static func batchSampleFileURL(named sampleName: String, extension ext: String, in batchDirectory: URL) -> URL
// Same sanitize+dedup policy for a flat FILE path; does NOT create the file.

// Sanitizer policy (private, replicating MetagenomicsSampleGrouper.sanitizeSampleId in
// Sources/LungfishApp/Views/Metagenomics/MetagenomicsSampleInput.swift:105-114 — read it and
// copy the exact character policy; add a comment cross-referencing it):
```

- [ ] **Step 1: Failing tests** — sanitization (spaces/punctuation → policy result; empty name → "Sample" fallback), directory dedup (`A`, `A` → `A`, `A-2`), file dedup (`A.fasta`, `A.fasta` → `A.fasta`, `A-2.fasta`), directory is actually created, file is not created.
- [ ] **Step 2: Run** `swift test --skip-update --filter AnalysesFolderTests` → new tests FAIL (missing symbols).
- [ ] **Step 3: Implement** the two statics + sanitizer in `AnalysesFolder.swift`, following the collision-loop idiom already in `createAnalysisDirectory` (:143-165).
- [ ] **Step 4: Run** same filter → PASS.
- [ ] **Step 5: Commit** `feat: batch sample naming helpers in AnalysesFolder (BG1)`.

### Task BG2: Adopt helper in classification/EsViritu batches (behavior-preserving)

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+Classification.swift:730-737` (kraken2 batch) and `:1102-1109` (esviritu batch)
- Test: existing classification/EsViritu batch tests (grep `kraken2-batch\|esviritu-batch` under Tests/) — they pin behavior; no new tests unless a gap is found.

**Interfaces — Consumes:** BG1's `batchSampleDirectory(named:in:)`.

- [ ] **Step 1:** Run the existing batch tests first (record green baseline): `swift test --skip-update --filter "Classification|EsViritu"` (note the exact passing set).
- [ ] **Step 2:** Replace the inline `appendingPathComponent(...lastPathComponent)` + `createDirectory` blocks with `AnalysesFolder.batchSampleDirectory(named: config.outputDirectory.lastPathComponent, in: batchDir)`. Names are already sanitized upstream, so output must be identical; the helper's dedup is a no-op for already-unique names.
- [ ] **Step 3:** Re-run the same filter → identical green set.
- [ ] **Step 4: Commit** `refactor: classification batches use shared batch-sample helper (BG2)`.

### Task BG3: Mapping fan-out batch grouping

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` — `runManagedMapping` (~:1015-1057) and the per-child dir creation (~:1094-1097)
- Test: `Tests/LungfishAppTests/MappingWizardSheetTests.swift` idiom or a new `MappingBatchOutputLayoutTests.swift` in `Tests/LungfishAppTests/`

**Interfaces — Consumes:** BG1 helpers. **Produces:** nothing new for later tasks.

Behavior: when `plan.requests.count > 1` — before the sequential loop, `try AnalysesFolder.createAnalysisDirectory(tool: plan.requests[0].tool.rawValue, in: projectURL, isBatch: true)`; precompute `let sampleDirs = try plan.requests.map { try AnalysesFolder.batchSampleDirectory(named: <bundle display name for that request — the same name already used for the op title>, in: batchDir) }` in request order; each child's `runSingleManagedMappingAwaitingCompletion` receives its precomputed directory and SKIPS its internal `createAnalysisDirectory` (thread an optional `preassignedAnalysisDirectory: URL?` parameter; nil = current single-run behavior). After the loop: if every child failed AND the batch dir contains no sample entries beyond `analysis-metadata.json`, remove it (spec §6).

- [ ] **Step 1: Failing test** — drive `runManagedMapping`'s plan-building + directory logic (extract a pure static if needed for testability, matching the house pattern of testable statics on AppDelegate): 2 requests → 1 `minimap2-batch-*` dir, children `SampleA/`, `SampleB/`, no sibling `minimap2-<ts>` dirs. Also: 1 request → unchanged flat layout (regression pin).
- [ ] **Step 2:** Run filter → FAIL. **Step 3:** Implement. **Step 4:** Run `--filter "MappingBatch|MappingWizardSheet|OperationRouting"` → PASS incl. existing tests. **Step 5: Commit** `feat: group per-bundle mapping results in one batch folder (BG3)`.

### Task BG4: Assembly fan-out batch grouping

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` — `independentAssembleLaunchRequests` (:79-121); `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift` — dispatch (:1046-1069) and dir-decision branch (:1073-1081)
- Test: `Tests/LungfishAppTests/AssemblyManagedInputMaterializationTests.swift` idiom or new `AssemblyBatchOutputLayoutTests.swift`

**Interfaces — Consumes:** BG1 helpers.

Behavior: the fan-out dispatcher creates ONE `spades-batch-*` (tool-named) dir and precomputes per-child `batchSampleDirectory` paths in the SAME input order `uniqueAssemblyProjectName` consumes (spec §3 invariant — both dedups see identical ordered names). Each child request carries `preferredOutputDirectory = <its sample dir>`. Fix `GenomicsDisplay:1073-1081` so a non-nil `preferredOutputDirectory` WINS over the `createAnalysisDirectory` fallback (fallback preserved for single runs / nil). Empty-batch cleanup after the sequential gate loop completes (spec §6).

- [ ] **Step 1: Failing test** — 2 paired bundles → 1 batch dir + 2 bundle-named children, no siblings; 1 bundle → unchanged; duplicate bundle names → child dirs `sample/`, `sample-2/` AND projectNames `sample`, `sample-2` (same suffixes — the invariant test).
- [ ] **Step 2-4:** red → implement → `--filter "AssemblyBatch|AssemblyManagedInput|FASTQOperationExecution|OperationRouting"` green.
- [ ] **Step 5: Commit** `feat: group per-bundle assembly results in one batch folder (BG4)`.

### Task BG5: Savont fan-out batch grouping + completion barrier

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift` (:991-1015 savont dispatch); `Sources/LungfishApp/Services/FASTQOperationPlanner.swift` (:432-448 `outputParentDirectory`, savont branch)
- Test: new `Tests/LungfishAppTests/SavontBatchOutputLayoutTests.swift`

**Interfaces — Consumes:** BG1 `batchSampleFileURL`.

Behavior: N>1 savont dispatch creates ONE `savont-batch-*` dir; per-input output filenames become `<source bundle display name>.fasta` (fall back to input-file stem for non-bundle inputs) via `batchSampleFileURL`, precomputed in input order BEFORE the concurrent dispatch loop. Add a completion barrier: collect the N child opIDs and, after ALL reach terminal state (reuse `awaitOperationTerminal(id:)` from `MainSplitViewController+GenomicsDisplay.swift:222-236` in a loop or TaskGroup), run the empty-batch cleanup check at the dispatch site. Keep the children themselves concurrent (do not serialize execution — the barrier only gates cleanup).

- [ ] **Step 1: Failing test** — 2 bundle inputs → 1 `savont-batch-*` dir containing `SampleA.fasta`, `SampleB.fasta`, none at Analyses root; single input → unchanged flat `Analyses/<stem>.fasta`; cleanup fires only after both children terminal (deterministic ordering via test hooks per the campaign's gated-fetch idiom).
- [ ] **Step 2-4:** red → implement → `--filter "SavontBatch|FASTQOperationPlanner|FASTQOperationExecution"` green.
- [ ] **Step 5: Commit** `feat: group savont per-input results in one batch folder with completion barrier (BG5)`.

### Task BG6: Sidebar batch rendering verification (flat-file children)

**Files:**
- Modify (only if the test exposes a gap): `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` — `appendBatchChildrenFromFilesystem` (near :679-691)
- Test: extend `Tests/LungfishAppTests/SidebarScanSnapshotParityTests.swift` or the scanner's own test file

Behavior: a `spades-batch-*` fixture dir with two subdirectories renders as an expandable batchGroup with two children named by sample; a `savont-batch-*` fixture dir with two `.fasta` FILES renders children for the files (fix `appendBatchChildrenFromFilesystem` if it only enumerates directories); a single-run `spades-<ts>` dir renders exactly as today (regression pin).

- [ ] **Step 1: Failing/characterization tests** as above. **Step 2-4:** red (if gap) → implement minimal fix → `--filter "Sidebar"` green. **Step 5: Commit** `feat: sidebar renders generic batch groups incl. flat-file children (BG6)`.

## Verification

After BG6: scoped cross-surface sweep (`--filter "Batch|Mapping|Assembly|Savont|Sidebar|Classification|EsViritu|AnalysesFolder"`), then ONE full `swift test --skip-update` — failures ⊆ campaign green-bar definition (SRA network flake only). Branch left merge-ready; final review by orchestrator per task + whole-branch review at the end.
