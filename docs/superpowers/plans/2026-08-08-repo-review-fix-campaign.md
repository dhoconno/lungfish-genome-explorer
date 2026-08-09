# Repo Review Fix Campaign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the ranked audit findings (user-visible correctness → responsiveness → multi-bundle consistency → structural), leaving `worktree-fable-repo-review` merge-ready at the Phase 0 green bar.

**Architecture:** Atomic commit per task referencing its finding ID. Findings' full descriptions and suggested fixes live in `docs/reports/2026-08-08-repo-audit-findings.md` (the implementer MUST read their finding's entry before starting). Multi-bundle work introduces one shared picker component + run-mode plumbing in `LungfishKit`, adopted per the arbitrated adoption set.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftPM, XCTest + swift-testing, AppKit/SwiftUI per existing file idiom.

## Global Constraints

- Build/test from the worktree root only: `swift build --skip-update`, `swift test --skip-update --filter <Target>`. EXACTLY ONE swift invocation at a time repo-wide (single `.build` lock).
- Green bar = failures ⊆ Phase 0 baseline record (9 environmental + KF015279); 0 swift-testing failures.
- Zero NEW strict-concurrency warnings. Never silence with `@unchecked Sendable`.
- Never `Task { @MainActor in }` from GCD background; use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } }` for UI callbacks. Never `%s` in `String(format:)`.
- Pipeline ops call BOTH `OperationCenter.shared.update()` AND `.log()`.
- TDD: failing test first for every behavioral fix; race fixes need a deterministic regression test (injected delay / controlled ordering / generation assertion).
- Commit message format: `fix: <summary> (F<id>)` / `feat: <summary> (MB-<n>)`, ending with the Claude Fable co-author trailer.
- Docs prose rules do not apply to this plan (spec/plan exempt).

---

## Phase 0 baseline record (2026-08-08, commit 71d015fa)

XCTest: 12,354 executed, 35 skipped, 2 failures — (1) `SRASearchIntegrationTests.testSingleAccessionViaENA` (network timeout, environmental flake), (2) `AppKitConcurrencyModalSafetyTests.testTargetedAppKitCallbacksAvoidUnsafeMainActorTaskHops` (real; fixed by Task A0). swift-testing: 560/560 pass. The formerly-9 external-path environmental failures now skip instead of fail. Green bar for this campaign: XCTest failures ⊆ {the SRA network flake}; 0 swift-testing failures.

## Phase A — User-visible correctness

### Task A0: Baseline guard-test violation (unsafe MainActor hop in ViewerViewController)
**Files:** Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` (the `Task { @MainActor` site(s) — grep the file); Test: existing `Tests/LungfishAppTests/AppKitConcurrencyModalSafetyTests.swift` (already failing = the failing test for TDD purposes).
Replace each `Task { @MainActor in … }` launched from a nonisolated/GCD context with `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } }` per house rule (or `performOnMainRunLoop` where the file already uses it). Behavior must be identical; do not restructure surrounding logic.
- [ ] `swift test --skip-update --filter AppKitConcurrencyModalSafetyTests` → pass.
- [ ] Commit `fix: remove unsafe Task {@MainActor} hop in ViewerViewController (A0/baseline)`.

### Task A1: F38 SQLite bind_text use-after-free
**Files:** Modify `Sources/LungfishIO/Bundles/AnnotationDatabase+Mutation.swift:40`; Test `Tests/LungfishIOTests/` (existing AnnotationDatabase test file if present, else new `AnnotationDatabaseMutationTests.swift`).
Read finding F38 in the findings report. Replace `SQLITE_STATIC`/nil destructor binds of temporary Swift string pointers with `SQLITE_TRANSIENT` (`unsafeBitCast(-1, to: sqlite3_destructor_type.self)` — reuse the shared constant if one exists in `LungfishIO`, see F53 for the 17 existing definitions; do NOT add an 18th, import the closest shared one).
- [ ] Failing test: insert an annotation whose string is a bridged `NSString` scoped to force deallocation before `sqlite3_step`, then read it back and assert content integrity.
- [ ] Fix all nil-destructor binds in the file; run `swift test --skip-update --filter LungfishIOTests` → pass.
- [ ] Commit `fix: use SQLITE_TRANSIENT for temporary string binds in AnnotationDatabase (F38)`.

### Task A2: F36 samtools view pipe deadlock
**Files:** Modify `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:161`; Test alongside existing MappingSummaryBuilder tests.
Per F36: stdout is read to completion before stderr, so a process filling the stderr pipe buffer deadlocks. Drain both pipes concurrently (readabilityHandler or two child Tasks) before `waitUntilExit`.
- [ ] Failing test: run a stub executable that writes >64KB to stderr then data to stdout; assert `streamSAMView` completes within timeout.
- [ ] Implement concurrent drain; test passes; commit `fix: drain samtools stdout/stderr concurrently to avoid pipe deadlock (F36)`.

### Task A3: F39 swallowed COMMIT failures in VCF import
**Files:** Modify `Sources/LungfishIO/Bundles/VariantDatabase+CreateFromVCF.swift:441`; Test existing VariantDatabase test file.
Per F39: `commitImportTransaction()` ignores `sqlite3_exec` return codes for COMMIT/BEGIN; a failed COMMIT yields a truncated database that reports success. Make it throw on non-OK, propagate through the import path, and surface the error to the caller (GUI path reports via OperationCenter error; CLI exits non-zero).
- [ ] Failing test: force COMMIT failure (e.g. open a second connection holding a conflicting lock, or inject via the class's exec hook if present) and assert the import throws rather than returning success.
- [ ] Implement + pass; commit `fix: propagate COMMIT/BEGIN failures in VCF import (F39)`.

### Task A4: F37 PBAA nextflow cancellation
**Files:** Modify `Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift:594`.
Per F37: the spawned nextflow `Process` has no `withTaskCancellationHandler` wiring, so cancelling the operation leaks the run. Wrap launch/wait in `withTaskCancellationHandler { … } onCancel: { process.terminate() }`, matching the cancellation pattern used by other pipelines in `LungfishWorkflow` (grep `withTaskCancellationHandler` for the house idiom).
- [ ] Failing test: launch pipeline against a stub long-running executable, cancel the Task, assert the process terminates promptly.
- [ ] Implement + pass; commit `fix: wire Task cancellation to PBAA nextflow process (F37)`.

### Task A5: F41 NAO-MGS miniBAM stale-write race
**Files:** Modify `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1315`; Test `Tests/LungfishNaoMgsUITests/`.
Per F41: the on-demand materialization fallback writes results without a generation guard, so a slow older request can clobber a newer selection. Apply the established generation-counter pattern (see `ViewerViewController.fetchAnnotationsAsync` for the idiom).
- [ ] Deterministic failing test: two overlapping requests with injected delay on the first; assert the second's result wins.
- [ ] Implement + pass; commit `fix: generation-guard NAO-MGS miniBAM materialization (F41)`.

### Task A6: F34 greedy interval clustering over-merge
**Files:** Modify `Sources/LungfishWorkflow/Alignment/BestMappedReadsAnnotationService.swift:251`; Test its existing test file.
Per F34: clustering merges read B into a cluster whose span it doesn't overlap because the comparison uses the running cluster span, transitively chaining non-overlapping reads. Fix per the finding's suggestion (compare against actual overlap criterion, not accumulated span — read the report entry for the exact semantics the service documents).
- [ ] Failing test: three reads where A–B overlap, B–C do not; assert C lands in a separate cluster.
- [ ] Implement + pass; commit `fix: prevent transitive over-merge in read interval clustering (F34)`.

## Phase B — Responsiveness

Every Phase B task: the fix moves work off the main actor or eliminates redundant work; the test asserts behavior preservation (same results), and where feasible an isolation assertion (e.g. the API is callable from a background context / the parse helper is `nonisolated`). No UI snapshot tests.

### Task B1: F5 (+F7) sidebar synchronous recursive scan
**Files:** Modify `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:930` (scan) and `:1339` (per-node JSON probes — same call chain, fixed together).
This is the deferred "off-main sidebar scan" from `docs/reports/2026-07-02-gui-perf-opus-deferrals.md` — read that report section first; it sketches the intended design (background scan + main-actor apply, preserving the surgical-update contract). Move the recursive filesystem walk and per-bundle sidecar probes onto a background task (nonisolated scan producing a value snapshot; apply on MainActor), keeping the existing targeted insert/remove/reload behavior (do NOT introduce blanket `reloadData()`).
- [ ] Characterization test first: capture current tree-build output for a fixture project directory; assert identical structure after refactor.
- [ ] Refactor; verify zero new concurrency warnings; run sidebar-related tests → pass.
- [ ] Commit `perf: move sidebar tree scan off the main actor (F5, F7)`.

### Task B2: F17 NativeBundleBuilder sync I/O on main
**Files:** Modify `Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift:21` and its call sites (grep `NativeBundleBuilder.build`).
Per F17: drop `@MainActor` from the builder (pure file I/O), make `build()` `async` or nonisolated-blocking-on-background; callers hop back for UI updates.
- [ ] Test: builder produces identical bundle from a fixture when called off-main; concurrency-clean build.
- [ ] Commit `perf: take NativeBundleBuilder off the main actor (F17)`.

### Task B3: F14 annotation import parse/hash on main
**Files:** Modify `Sources/LungfishWorkflow/Bundles/ReferenceBundleAnnotationImportService.swift:139` + call sites.
Same pattern as B2: GFF/BED parse, SHA256, provenance I/O become nonisolated; only result application stays on MainActor.
- [ ] Characterization test on a fixture GFF3/BED (fixtures exist in `Tests/Fixtures/sarscov2/`); identical import result; commit `perf: move annotation import parsing off the main actor (F14)`.

### Task B4: F4 viewer interaction sync bundle I/O
**Files:** Modify `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift:1332`.
Per F4: `fetchAnnotationBases`/`selectedFASTAOperationInput` read bundle files synchronously during interaction handling. Route through the existing `AsyncFileReader` (LungfishKit) with a generation guard against re-entry.
- [ ] Test: result parity with fixture bundle; commit `perf: async bundle reads in viewer interaction paths (F4)`.

### Task B5: F1 (+F2) tooltip hit-test costs
**Files:** Modify `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Tooltips.swift:854` and `:43`.
Per F1: `readAtPoint` linearly scans `cachedPackedReads` per mouse-move — index reads by row (the packing already assigns rows; build a row→reads bucket on cache rebuild) so hit-testing is O(row bucket). Per F2: gate the chained hit-tests behind a single early bounds/row check per event.
- [ ] Test: hit-test parity on a synthetic packed-read set (same read returned as the linear scan for 100 random points); commit `perf: index packed reads for tooltip hit-testing (F1, F2)`.

### Task B6: F6 provenance inspector sync walk
**Files:** Modify `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:415`.
Move the sidecar lookup walk + JSON decode to a background task with generation guard; show a lightweight loading state.
- [ ] Test: same provenance model produced for a fixture bundle; commit `perf: async provenance sidecar lookup (F6)`.

### Task B7: F8 FASTQ dialog open scan
**Files:** Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:195`.
The recursive directory scan runs on the main actor each time the dialog opens. Make it async off-main with cached invalidation (re-scan only when the project folder's modification generation changes, if cheap; otherwise plain async).
- [ ] Test: scan result parity; commit `perf: async FASTQ operations dialog scan (F8)`.

### Task B8: F21 genotype matrix search debounce
**Files:** Modify `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:1830`.
Add the same debounce used by `BatchTableView`/`ViralDetectionTableView` (copy that exact idiom/interval).
- [ ] Test: rapid successive filter inputs coalesce to one recompute (inject a counting hook); commit `perf: debounce genotype matrix search filter (F21)`.

### Task B9: F15 plugin status serial checks
**Files:** Modify `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift:327`.
Replace the serial await-per-tool loop with `withTaskGroup` (bounded, order-preserving result assembly).
- [ ] Test: same statuses as serial for a stub set; commit `perf: check plugin pack tool requirements concurrently (F15)`.

### Task B10: F24 extractOverlappingReads swallowed errors
**Files:** Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift:259`.
Surface failures: report via OperationCenter (update + log) and user-visible alert per house pattern instead of silent `try?`.
- [ ] Test: injected failing extraction produces an error path invocation (hook or spy); commit `fix: surface extract-overlapping-reads failures (F24)`.

### Task B11 (stretch): F12 AI registry sync SQLite on main
**Files:** Modify `Sources/LungfishApp/Services/AI/AIToolRegistry.swift:376`.
Move region/gene queries off-main via the established DB-actor/AsyncFileReader idiom used elsewhere in Services (grep the 8 off-main conversions from the 2026-07-02 perf branch for the pattern).
- [ ] Test: query parity; commit `perf: async AI registry region/gene queries (F12)`.

## Phase C — Multi-bundle consistency

Read the spec's Phase 2 section verbatim before starting any C task. Adoption set (arbitrated): Mapping, short-read Assembly (SPAdes/MEGAHIT/SKESA), MAFFT (combine-locked), Workflow Builder disclosure, Savont/pbaa (per-bundle-locked), 12S + Workflow Operations (combine-locked, standardized summary), ONT/Illumina genotyping (per-bundle-locked with explicit cohort note). Documented exceptions (no picker): TaxTriage, Kraken2/EsViritu (already per-sample batch; retrofit = round 2), long-read assembly (Flye/Hifiasm), ViralRecon, BAM variant calling, Reassemble context action, IQ-TREE/primer-trim/BLAST drawer, import sheets (no bundle selection input).

### Task C1: MB-0 shared picker + run-mode model
**Files:** Create `Sources/LungfishKit/MultiBundleRunModePicker.swift`, `Sources/LungfishKit/MultiBundleRunPlanner.swift`; Test `Tests/LungfishKitTests/MultiBundleRunPlannerTests.swift`, `Tests/LungfishKitTests/MultiBundleRunModePickerTests.swift`.
**Produces (later tasks rely on these exact names):**
```swift
public enum MultiBundleRunMode: String, CaseIterable, Sendable, Codable {
    case perBundle   // N runs, N results
    case combined    // pool inputs, 1 run
}
public struct MultiBundleRunPolicy: Sendable {
    public var allowedModes: Set<MultiBundleRunMode> // lock by passing a single-element set
    public var defaultMode: MultiBundleRunMode
    public var lockReason: String?                   // shown when a mode is locked off
    public init(allowedModes: Set<MultiBundleRunMode>, defaultMode: MultiBundleRunMode, lockReason: String? = nil)
}
public struct MultiBundleRunModePicker: View { // match wizard idiom (SwiftUI sheets)
    public init(bundleCount: Int, policy: MultiBundleRunPolicy, selection: Binding<MultiBundleRunMode>)
    // Renders nothing when bundleCount < 2. Radio pair with counts:
    // "Run separately per bundle (N results)" / "Combine all inputs, run once (1 result)".
    // Locked mode renders disabled with lockReason caption. Accent = Lungfish Orange.
}
public struct MultiBundleRunPlanner {
    // Pure fan-out/pool planning. `materialize` is the App-injected closure (composes over MaterializationPipeline).
    public static func plan<I: Sendable>(
        inputs: [I], mode: MultiBundleRunMode,
        materialize: @Sendable ([I]) async throws -> [I],
        pool: @Sendable ([I]) async throws -> [I]
    ) async throws -> [[I]]  // perBundle → N single-element groups (each materialized); combined → 1 pooled group
}
```
- [ ] Failing planner tests: perBundle returns N groups preserving order; combined materializes THEN pools (assert call order via recorder); per-child cleanup semantics (a throwing materialize for input k does not leak others — assert cancellation propagates).
- [ ] Failing picker test: hidden when bundleCount < 2; locked mode disabled with reason.
- [ ] Implement; `swift test --skip-update --filter LungfishKitTests` → pass; commit `feat: shared multi-bundle run mode picker and planner (MB-0)`.

### Task C2: MB-1 Mapping per-bundle default
**Files:** Modify `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift:59-126`, `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:799` area, `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:157` area, `Sources/LungfishApp/Services/FASTQOperationPlanner.swift:319-332`.
Judge-verified route: the planner's `.map` perInput split already has the right shape but never fires because `captureMappingRequest` bypasses `pendingLaunchRequest`. Adopt the picker in MappingWizardSheet (default `.perBundle`); per-bundle mode routes through the planner split, producing one `MappingRunRequest` per bundle with @RG SM/ID/LB/PU derived from THAT bundle (fixes the silent @RG misattribution); combined mode keeps one request but derives an explicit pooled sample name ("pooled-<n>-bundles") and logs a warning line into the operation history.
- [ ] Failing test: 2-bundle selection in perBundle mode yields 2 requests with distinct correct SM tags; combined yields 1 request with pooled naming.
- [ ] Implement; commit `feat: per-bundle mapping with correct read groups via shared picker (MB-1)`.

### Task C3: MB-2 short-read assembly split guard
**Files:** Modify `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift:699-727`, `Sources/LungfishApp/Services/FASTQOperationPlanner.swift:334-355`.
Judge-verified: the `.assemble` split requires `!pairedEnd`, so real paired-end multi-bundle selections silently co-assemble. Adopt the picker (default `.perBundle` for short-read tools); the planner's `.assemble` case gains paired-end-aware grouping (pair R1/R2 within each bundle, then split by bundle) driven by the selected mode, not by `pairedEnd` inference. Long-read tools (Flye/Hifiasm): policy locks to `.combined`? NO — they are exceptions per adoption set; wizard passes no picker for them and keeps current behavior.
- [ ] Failing test: two paired-end bundles in perBundle mode produce two assembly requests each with its own R1/R2 pair; combined produces one pooled request.
- [ ] Implement; commit `feat: per-bundle short-read assembly via shared picker (MB-2)`.

### Task C4: MB-3 MAFFT combine-locked + naming
**Files:** Modify the `.mafft` FASTQOperationDialogState pane (grep `case .mafft` in `Sources/LungfishApp/Views/FASTQ/`).
Picker rendered with `MultiBundleRunPolicy(allowedModes: [.combined], defaultMode: .combined, lockReason: "Alignment requires all sequences in one run")`. Fix output bundle naming to reflect all N inputs (e.g. "<first>+<n-1> more aligned"), not just the first.
- [ ] Test: naming for 3 inputs; commit `feat: combine-locked picker and multi-input naming for MAFFT (MB-3)`.

### Task C5: MB-4 Workflow Builder + Savont/pbaa + 12S/Workflow-ops picker states
**Files:** Modify Workflow Builder preferred-sample pane, `.savont`/`.pbaa` panes, 12S workflow sheet, Workflow Operations sheet (locate via inventory rows' surface fields in the findings report).
Workflow Builder: end the silent first-only drop — show the picker or, where per-bundle execution is unsupported, an explicit "using <name>; N−1 selections ignored" disclosure line (inventory row documents which). Savont/pbaa: picker per-bundle-locked (makes existing `.perInput` iteration visible). 12S + Workflow Operations: combine-locked picker adopting their existing summary text ("They will run as one batch.") as the shared component's standardized summary.
- [ ] Test per surface: policy + copy rendered as specified; commit `feat: standardize multi-bundle disclosure across Workflow Builder, Savont, pbaa, 12S, Workflow Operations (MB-4)`.

### Task C6: MB-5 genotyping per-bundle lock + CLI parity + docs
**Files:** Modify `.ontGenotyping` pane (per-bundle-locked, lockReason "Genotyping is per-sample; use a cohort after per-sample calls"); Modify `Sources/LungfishCLI/Commands/MapCommand.swift` + assembly command help text; Test `Tests/LungfishCLITests/CLIRegressionTests` entry.
CLI parity (budget-scoped): update `lungfish map`/`assemble` help/abstract to state multi-input semantics explicitly ("multiple inputs are treated as one sample's reads; invoke once per sample for per-sample results") and add a CLIRegressionTests assertion pinning that text (beware: do not touch the version string sites).
- [ ] Tests pass; commit `feat: genotyping per-bundle lock and CLI multi-input disclosure (MB-5)`.

## Phase D — Structural (execute only while budget holds; skip in order D4→D1)

### Task D1: F44/F45/F46 formatter consolidation
Create `Sources/LungfishKit/Formatters.swift` with `formatBytes`, `formatCount`, `formatDuration` (adopt the most common existing output format per finding descriptions); replace the ~16 duplicates (finding entries list sites); keep byte-for-byte output of the majority format and update tests that pinned divergent formats.
- [ ] Commit `refactor: consolidate byte/count/duration formatters in LungfishKit (F44, F45, F46)`.

### Task D2: F54 OperationCenter cancel Task pattern
Replace `Task { @MainActor in }` from the GCD closure at `Sources/LungfishKit/OperationCenter.swift:709` with `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` per house rule.
- [ ] Commit `fix: use assumeIsolated hop in OperationCenter.cancel (F54)`.

### Task D3: F59 wrong deprecation pointer + F26/F27/F28/F29/F30/F31/F32 update-without-log sweep
Fix the `conda extract` deprecation message flag name; add `.log()` beside every bare `.update()` at the seven cited sites (message = the update's status text).
- [ ] Commit `fix: correct conda extract deprecation hint; log operation progress at bare update() sites (F59, F26-F32)`.

### Task D4: F51 SRAService API-key resolution
Route SRAService's eutils requests through the shared NCBIService client (or extract its API-key resolution into a shared helper in LungfishCore) per finding entry.
- [ ] Commit `refactor: share NCBI API-key resolution with SRAService (F51)`.

## Deferred (round-2 candidates, do NOT start in this campaign)
God-file splits F47/F48/F55; Kraken2/EsViritu picker retrofit; remaining D2-low (F2 handled, F3, F9, F10, F11, F13, F16, F18, F20, F22, F23, F25), F33, F42, F43, F49, F50, F52, F53 (shared SQLITE_TRANSIENT constant — partially addressed by A1 only if a shared constant already exists), F57, F58, F60.

## Verification (after each phase)
- `swift build --skip-update` clean (zero new warnings) → full `swift test --skip-update` at phase C and campaign end; failures ⊆ baseline record.
- Fable reviews every diff before commit is pushed to the branch history (implementers commit; orchestrator reviews and may revert).
