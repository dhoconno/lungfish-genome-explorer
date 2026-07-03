# Codebase-Quality Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggressive but confidence-gated, behavior-preserving Swift-best-practices refactor of the entire Lungfish codebase, applied in small batches across many phases, each independently expert-reviewed and green-bar-verified, with uncertain changes reverted into per-module defer docs.

**Architecture:** A repeatable per-batch protocol (audit → apply → scoped-test → independent adversarial review → revert-on-uncertainty) is applied module-by-module bottom-up the dependency graph. This is a *harness plan*: the specific edits are discovered at execution time by expert-agent audits, not pre-written here. The plan pins the process, the ordering, the gates, and the exact commands so an agent with zero context can run it autonomously.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 26 (Tahoe), Apple Silicon. `@Observable` + `@MainActor` + strict concurrency. XCTest + swift-testing.

## Global Constraints

Copied verbatim from the design spec; every task implicitly includes these.

- **Isolation:** all work in worktree `worktree-fable-codebase-quality` off `main`. Never touch `main`.
- **Behavior-preserving only.** No feature, behavior, API-surface, or user-visible changes.
- **swift invocations:** always `swift build --package-path <wt> --skip-update` / `swift test --package-path <wt> --skip-update`. `swift` has NO `-C` flag. Always `--skip-update` (offline; avoids `testSRASearch` NCBI flake).
- **Serialize ALL swift invocations.** Single `.build/.lock` per checkout. Never build while a subagent may be building; dispatch implementer subagents ONE AT A TIME. Check `ps aux | grep swift` + `.build/.lock` before treating a hang as a failure.
- **Green bar =** XCTest failures ⊆ the 9 known-environmental (6 `GenotypeRealBundleSmokeTests` in `LungfishGenotypeUITests`, 2 `ZhangArtifactCanaryTests`, 1 `VCFRobustnessTests.testAllRealVCFsFromDownloads`) AND swift-testing failures = 0.
- **Module layering:** a leaf or `LungfishKit` may NEVER reference a type defined in `LungfishApp`. `LungfishCLI` does NOT import `LungfishKit`. `LungfishApp` importing leaves is fine.
- **macOS 26 API rules:** no `NSSplitViewController` delegate methods, `lockFocus`, `wantsLayer`, `runModal`, `synchronize`.
- **Background→MainActor dispatch:** never `Task { @MainActor in }` from GCD background; never bare `DispatchQueue.main.async` to touch `@MainActor` state; never `await` `@MainActor` from `Task.detached`. Use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` or actor-based pipelines.
- **OperationCenter for every op:** call both `.update()` AND `.log()`.
- **Never save alignment as SAM:** always sorted+indexed BAM.
- **Docs prose rules** for `docs/user-manual/**` and `.claude/agents/*`: no em dashes, bullet cap 5/2. Defer docs also avoid em dashes.
- **String(format:):** never `%s` with Swift Strings (SIGSEGV) — use `%@` or interpolation.

---

### Task 0: Create and verify the worktree

**Files:**
- Create: worktree at `../lungfish-worktrees/codebase-quality`, branch `worktree-fable-codebase-quality`

- [ ] **Step 1: Create the worktree from clean main**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git worktree add -b worktree-fable-codebase-quality ../lungfish-worktrees/codebase-quality main
```

- [ ] **Step 2: Establish the green-bar baseline in the worktree**

Run (serialized, may take a long time):
```bash
swift test --package-path ../lungfish-worktrees/codebase-quality --skip-update 2>&1 | tail -40
```
Expected: build succeeds; XCTest failures ⊆ the 9 known-environmental; swift-testing = 0. Record the exact failing-test set as the baseline. If a NON-environmental test fails on untouched `main`, STOP and report — the baseline is not green and refactoring cannot be safely gated.

- [ ] **Step 3: Scaffold the defer-doc directory and results stub**

```bash
mkdir -p ../lungfish-worktrees/codebase-quality/docs/reports/2026-07-03-codebase-quality-defer
```
Create `docs/reports/2026-07-03-codebase-quality-results.md` with a header and an empty table (module | batches applied | LOC delta | deferrals | green-bar). Commit:
```bash
git -C ../lungfish-worktrees/codebase-quality add docs/reports
git -C ../lungfish-worktrees/codebase-quality commit -m "chore: scaffold codebase-quality defer docs + results stub"
```

---

### The per-batch protocol (applies inside every module task below)

For each batch (one large/tangled file, or a tight cluster of related files):

- [ ] **B1: Audit.** Dispatch an audit subagent (swift-expert lens) on the batch's files. It returns a structured findings list: for each finding — file:line, category (concurrency | redundancy | clarity | access-control | file-size | dead-code | rule-violation), severity, confidence (high/medium/low), and a concrete proposed change. It must flag any binding-constraint violations explicitly.
- [ ] **B2: Apply.** Dispatch ONE implementer subagent to apply the HIGH-confidence findings (and medium ones it independently judges safe), behavior-preserving. Aggressive structural changes (splitting files, extracting types) are allowed when confidence is high. Low-confidence findings are NOT applied — they go straight to the defer doc.
- [ ] **B3: Verify (scoped).** Serialized: `swift build --package-path <wt> --skip-update` then `swift test --package-path <wt> --skip-update --filter <ThisModule>Tests`. Must build clean and keep the module's scoped tests green.
- [ ] **B4: Independent review.** Dispatch a SEPARATE review subagent (code-reviewer lens, did NOT write the change) on the batch diff (`git diff`). It hunts for behavior changes, hidden regressions, and rule violations. Output: per-hunk verdict (keep / revise / revert) + reasons.
- [ ] **B5: Iterate or revert.** For `revise` verdicts, iterate (back to B2 for that hunk) then re-review. For anything that cannot be resolved confidently after one iteration, `git checkout` that hunk/file to revert it and append an entry to the module's defer doc (file:line, what, why-uncertain, suggestion).
- [ ] **B6: Commit the batch.** `git add` the batch files + defer-doc updates; commit with `refactor(<module>): <file> — <summary>`.

**Dispatch discipline:** audit and review subagents are read-heavy and MAY run in parallel across DIFFERENT batches, but only ONE implementer (B2) or swift build/test (B3) may run at a time because of the `.build` lock. In practice: run B2/B3 strictly serially; B1/B4 of the next batch may overlap B3 of the current one since they don't build.

---

### Task 1: Module — LungfishCore (~28K LOC, 71 files)

**Files:** all of `Sources/LungfishCore/**`. Batch order largest-first; first batches include `Services/NCBI/NCBIService.swift` (2,573 lines).

- [ ] **Step 1:** Enumerate files by size: `find ../lungfish-worktrees/codebase-quality/Sources/LungfishCore -name '*.swift' | xargs wc -l | sort -rn`. Group into batches (1 large file, or a cluster ≤ ~800 lines).
- [ ] **Step 2:** Run the per-batch protocol (B1–B6) for each batch in order.
- [ ] **Step 3: Module-boundary green bar.** Serialized full suite: `swift test --package-path <wt> --skip-update 2>&1 | tail -40`. Confirm failures ⊆ baseline. If a regression appears, bisect to the batch, revert-or-fix, re-run.
- [ ] **Step 4: Finalize defer doc** `docs/reports/2026-07-03-codebase-quality-defer/01-core.md` and update the results table row for LungfishCore. Commit.

---

### Task 2: Module — LungfishIO (~66K LOC, 139 files)

**Files:** all of `Sources/LungfishIO/**`. Early batches: `Formats/NaoMgs/NaoMgsDatabase.swift` (2,620), `Search/ProjectUniversalSearchIndex.swift` (2,483). Watch the bgzip readers (known infinite-loop fix must be preserved).

- [ ] Same structure as Task 1, Steps 1–4. Defer doc: `02-io.md`. Full green bar at module end.

---

### Task 3: Module — LungfishWorkflow (~124K LOC, 272 files)

**Files:** all of `Sources/LungfishWorkflow/**`. Early batches: `ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift` (5,749), `ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift` (3,802), `Demultiplex/DemultiplexingPipeline.swift` (3,569). CRITICAL: pipelines must keep `OperationCenter.update()` AND `.log()`; preserve materialization semantics; never save alignment as SAM.

- [ ] Same structure as Task 1, Steps 1–4. Defer doc: `03-workflow.md`. Full green bar at module end. This is the largest non-App module; if tokens run short, defer remaining batches rather than rush.

---

### Task 4: Module — LungfishKit (~11K LOC, 47 files)

**Files:** all of `Sources/LungfishKit/**`. Contains `OperationCenter`, BLAST drawer cluster, CLI runner, brand colors. CRITICAL: nothing here may reference a `LungfishApp` type.

- [ ] Same structure as Task 1, Steps 1–4. Defer doc: `04-kit.md`. Full green bar at module end.

---

### Task 5: Modules — 9 leaf UI modules

**Files:** `Sources/LungfishTwelveSUI`, `LungfishAlignmentUI`, `LungfishAssemblyUI`, `LungfishNvdUI`, `LungfishNaoMgsUI`, `LungfishTaxTriageUI`, `LungfishEsVirituUI`, `LungfishGenotypeUI`, `LungfishPhylogeneticsUI`. Process largest-first: GenotypeUI (`GenotypeResultViewController.swift` 5,756; `GenotypeComparisonMatrixView.swift` 2,499) then TaxTriageUI (`TaxTriageResultViewController.swift` 4,738), NaoMgsUI (2,809), EsVirituUI, then the rest. CRITICAL: no leaf may reference a `LungfishApp` type; each leaf exposes `on...` callbacks, glue stays in App.

- [ ] **Step 1–2:** Per-batch protocol across all 9 modules, largest-first. Each leaf's scoped tests: `--filter <Leaf>UITests`.
- [ ] **Step 3: Boundary green bar.** Since the 9 leaves are independent siblings, run ONE full green-bar suite after all leaf batches complete (per spec). Bisect any regression to its leaf.
- [ ] **Step 4:** Defer doc `05-leaves.md` (one section per leaf). Update results table. Commit.

---

### Task 6: Module — LungfishApp (~188K LOC, 409 files)

**Files:** all of `Sources/LungfishApp/**`. Largest/most-tangled first: `Views/Viewer/AnnotationTableDrawerView.swift` (5,224), `Views/Viewer/ViewerViewController.swift` (3,763), `Views/DatabaseBrowser/DatabaseBrowserViewController.swift` (3,565), `Views/Viewer/MultipleSequenceAlignmentViewController.swift` (3,521), `Views/Viewer/FASTQDatasetViewController.swift` (3,032), `App/AppDelegate+ImportCenter.swift` (2,843), `Views/Sidebar/SidebarViewController.swift` (2,697), `Views/Inspector/Sections/ReadStyleSection.swift` (2,482). CRITICAL: composition roots (`ViewerViewController`, `MainSplitViewController`, `InspectorViewController`, `SidebarViewController`) stay in App; do NOT extract them into leaves. Respect generation-counter patterns on async fetches.

- [ ] Same structure as Task 1, Steps 1–4. Defer doc: `06-app.md`. Full green bar at module end. Largest module: if tokens/time run short, complete whole batches and defer the untouched remainder explicitly in the defer doc (never leave a half-applied batch).

---

### Task 7: Module — LungfishCLI (~45K LOC, 90 files)

**Files:** all of `Sources/LungfishCLI/**`. Early batches: `Commands/FastqCommand.swift` (3,208), `Commands/MSACommand.swift` (2,922). CRITICAL: `LungfishCLI` does NOT import `LungfishKit`. Preserve CLI/GUI parity. `GlobalOptions.parse([])` not direct-init.

- [ ] Same structure as Task 1, Steps 1–4. Defer doc: `07-cli.md`. Full green bar at module end.

---

### Task 8: Finalize deliverable

- [ ] **Step 1: Final full green-bar** across the whole worktree. Confirm failures ⊆ baseline, swift-testing = 0.
- [ ] **Step 2: Complete the results report** `docs/reports/2026-07-03-codebase-quality-results.md`: per-module batches applied, LOC delta, deferral counts, final green-bar status, and a "how to review" note pointing the downstream LLM at the defer docs and the branch diff `git diff main...worktree-fable-codebase-quality`.
- [ ] **Step 3: Confirm clean tree** `git -C <wt> status` is clean; all batches committed.
- [ ] **Step 4: Report to user** the worktree path, branch name, module summary, deferral count, and that it is ready for the downstream LLM. This is the completion point.

## Self-Review

- **Spec coverage:** bottom-up ordering (Tasks 1–7 in dependency order ✓), small batches (per-batch protocol ✓), independent review (B4 separate agent ✓), full green-bar per module (each module Step 3 ✓), revert-on-uncertainty (B5 ✓), per-module defer docs (each module Step 4 ✓), isolated worktree (Task 0 ✓), final deliverable (Task 8 ✓). No spec section unmapped.
- **Placeholder scan:** the harness steps are deliberately protocol-driven (edits discovered at runtime by audits), which is correct for a 502K-line refactor and not a placeholder; every command and gate is concrete.
- **Consistency:** defer-doc filenames (`01-core.md`..`07-cli.md`), the green-bar definition, and the build/test commands are identical across all tasks.
