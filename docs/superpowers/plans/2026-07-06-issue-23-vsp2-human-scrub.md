# Issue #23 — Human Read Removal Correctness in VSP2 Recipe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first**, especially §2.1 and the shared **VSP2 Recipe Reconciliation** (Task 0 of the #24 plan — do it before this plan if not already done).
> **This is a DIAGNOSIS-FIRST plan.** The symptom (2–5% of reads still classified as human after VSP2) has multiple plausible causes. Do the diagnosis task and let its finding select the fix. Do not pre-commit to a fix.

**Goal:** Determine why 2–5% of reads remain human-classified after VSP2 human-read removal, then either (a) fix the removal so residual human reads are minimized, or (b) if the residual is inherent to the method, document and surface it so users understand it — and measure the residual either way.

**Architecture:** VSP2 removes human reads with **Deacon** (`deacon filter`) against a bundled panhuman k-mer index (`deacon-panhuman`), in interleaved paired-end mode (split R1/R2 → filter → re-interleave). Candidate causes of residual human reads: (1) incomplete panhuman index coverage; (2) Deacon match threshold too permissive / not configurable; (3) the split→filter→re-interleave step dropping only some reads of a pair or reordering; (4) the "2–5% classified as human" being partly Kraken2 false positives rather than true human reads; (5) VSP2 as executed at runtime not actually running the scrub step (recipe-representation mismatch — see master spec §2.1). The diagnosis distinguishes these.

**Tech Stack:** Swift 6.2, Deacon (native tool), Kraken2, seqkit, XCTest.

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- Any change to the scrub command must keep OperationCenter `update` + `log`.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. A written root-cause finding (`docs/reports/2026-07-06-vsp2-human-scrub-diagnosis.md`) that identifies, with evidence, why residual human reads remain.
2. The residual human-read fraction is **measured and surfaced** (scrub step's input/output counts visible in provenance, and a post-scrub residual metric available).
3. Either the removal is improved (fewer residual human reads, demonstrated on a test dataset) OR a documented rationale for the residual plus a user-facing note; whichever the diagnosis supports.
4. Regression test covering whatever behavior the fix touches.
5. Suite is GREEN.

## Key files

- `Sources/LungfishApp/Services/FASTQDerivativeService+HumanScrub.swift` (Deacon invocation; interleaved split/re-interleave ~lines 20–114)
- `Sources/LungfishApp/Services/FASTQDerivativeService+RecipePipeline.swift` (records scrub step input/output counts ~lines 205–233; `countFASTQReads` ~line 287)
- `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift` (`resolveHumanScrubberDatabasePath`, `deacon-panhuman` installer)
- `Sources/LungfishIO/Formats/FASTQ/ProcessingRecipe.swift:315` / `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json` (the scrub step definition)

---

### Task 1 (DIAGNOSIS — do this before any fix): Reproduce, measure, and localize the residual

**Files:** read-only + a new report + a new test fixture note. No production code change in this task.

**Prerequisite:** The #24 plan's Task 0 (VSP2 Recipe Reconciliation) must be done. Read `docs/reports/2026-07-06-vsp2-recipe-reconciliation.md`. **Critically: confirm the scrub step actually executes in the shipping VSP2 path.** If Task 0 found that the runtime VSP2 recipe is the JSON `deacon-scrub` step, good. If the runtime path somehow skips the scrub (e.g. a representation mismatch means the executed recipe has no scrub step), that IS the root cause — jump to Task 2 Option E.

- [ ] **Step 1: Build a controlled human-spiked dataset.** Create a small FASTQ containing a known number of human reads mixed with non-human reads. Two options:
  - Preferred: subsample a public human FASTQ (e.g. a small slice of a 1000-Genomes sample if available on the machine) and mix with the SARS-CoV-2 fixture reads (`Tests/Fixtures/sarscov2/`), recording the exact human/non-human counts.
  - If no human reads are available locally, extract reads from the human reference itself (GRCh38) as synthetic "reads" (e.g. `seqkit sliding`), so ground-truth human count is known exactly.
  Save under the scratchpad or a gitignored test-data dir; record counts in the report.

- [ ] **Step 2: Run the scrub step in isolation.** Using the debug CLI/app or by invoking `deacon filter` directly with the same arguments the app builds (read `FASTQDerivativeService+HumanScrub.swift` for the exact argument vector: `filter -d <dbPath> <R1> <R2> -o <outR1> -O <outR2> -t <threads>`), scrub the spiked dataset. Measure with `seqkit stats -T` before and after: how many human reads survived? This isolates Deacon's recall from downstream Kraken2 classification.

- [ ] **Step 3: Run the full VSP2 import, then Kraken2.** Import the spiked dataset with the VSP2 recipe in the app, then run Kraken2 (standard db). Record the human-classified fraction Kraken2 reports. Compare to Step 2's residual. If Step 2 shows Deacon removes ~all human reads but Kraken2 still reports 2–5% human, the "residual" is largely **Kraken2 false positives / near-human reads**, not a scrub bug (cause 4). If Step 2 already shows 2–5% human surviving Deacon, the scrub itself is under-removing (cause 1/2/3).

- [ ] **Step 4: Inspect the interleave handling.** Read `FASTQDerivativeService+HumanScrub.swift` lines ~50–96 (split → filter → re-interleave). Verify: after Deacon drops reads, does the re-interleave step correctly keep pairs synchronized, and does it drop BOTH mates when either mate is human? (VSP2's design intent per research: if either read in a pair aligns to human, both are removed.) Check for an off-by-one or a path where singleton survivors re-enter the stream. Confirm the downstream length filter (min 50 bp) is present to catch N-masked reads.

- [ ] **Step 5: Check the database.** Read `DatabaseRegistry.swift` around the `deacon-panhuman` installer. Confirm the installed index is the full panhuman index (not a truncated/sample index) and record its version/source. Verify `resolveHumanScrubberDatabasePath` resolves to a present, non-empty file at runtime (the app maps `"human-scrubber"` → `"deacon-panhuman"`).

- [ ] **Step 6: Write the diagnosis.** Create `docs/reports/2026-07-06-vsp2-human-scrub-diagnosis.md` stating: measured Deacon-only residual, measured post-Kraken2 residual, the interleave-handling assessment, the database assessment, and the single most-likely root cause with evidence. Recommend one of the Task 2 options (A–E). Commit: `docs: diagnose VSP2 human-read residual (issue #23)`.

---

### Task 2: Apply the fix the diagnosis selected

Pick exactly ONE option based on Task 1's finding. Each option is TDD where a unit test is feasible; where the change is a tool-argument or pipeline change, the "test" is a measured before/after on the spiked dataset recorded in the report plus a guard test where one exists.

**Option A — Tighten Deacon sensitivity (if Deacon under-removes and it exposes a threshold).**
- [ ] Read Deacon's `filter` options (run `deacon filter --help` via the managed env). If it supports a stricter matching parameter (minimum matching k-mers / abundance), add it to the argument vector in `FASTQDerivativeService+HumanScrub.swift`. Add a unit test asserting the built argument vector includes the new flag with the chosen value. Re-run the spiked dataset; record improved residual in the report. Commit `fix(vsp2): tighten Deacon human-scrub matching threshold`.

**Option B — Add a second-pass host filter (if Deacon's index inherently misses ~2–5%).**
- [ ] After the Deacon step, add a supplementary host-removal pass in the recipe (e.g. a minimap2 or bbduk pass against GRCh38) ONLY for VSP2. Model the new step on the existing recipe-step definitions (`FASTQDerivativeOperation` / JSON recipe step). Add the step to the VSP2 recipe representation that actually runs (per Task 0). Measure and record residual improvement. Add a test that the VSP2 recipe now contains the extra host-filter step. Commit `fix(vsp2): add second-pass host filter after Deacon scrub`.

**Option C — Fix interleave/pair handling (if Step 4 found a synchronization or singleton-survivor bug).**
- [ ] Write a focused unit test for the split→filter→re-interleave helper: given an interleaved input where one mate of a pair is "human," assert BOTH mates are absent from the output and remaining pairs stay synchronized (R1/R2 order preserved). Fix the helper minimally. This is the highest-value fix if it applies because it is a true correctness bug. Commit `fix(vsp2): drop both mates when either aligns to human in scrub`.

**Option D — Reclassify the residual as expected Kraken2 behavior (if Step 3 showed Deacon removes ~all human but Kraken2 still reports 2–5%).**
- [ ] No pipeline change. Instead: (1) add the residual measurement surface (Task 3) so users see that Deacon removed ~100% of *detectable* human reads; (2) document in `docs/user-manual/**` (obey docs prose rules: no em dashes, bullet caps) that a small Kraken2 "human" fraction can persist due to conserved/low-complexity regions and is not un-scrubbed raw human data. Commit `docs(vsp2): explain residual Kraken2 human fraction after scrub`.

**Option E — Fix the recipe so the scrub actually runs (if Task 0/Task 1 Step-prereq found the scrub step is not executed at runtime).**
- [ ] Correct whichever representation the runtime uses so the deacon-scrub step is present and ordered correctly. Add a test asserting the executed VSP2 recipe includes the human-scrub step. Re-run and confirm residual drops sharply. Commit `fix(vsp2): ensure human-scrub step runs in shipping VSP2 recipe`.

---

### Task 3: Measure and surface the residual (do this REGARDLESS of which option)

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService+RecipePipeline.swift` (scrub step already records input/output counts ~lines 205–233 — ensure that persists and is labeled)
- Reuse: the Inspector recipe-applied section from issue #24 Task 3 (`DocumentSection.swift`).

**Interfaces:**
- Consumes: `RecipeStepResult` for the scrub step (has `inputReadCount`/`outputReadCount`/`readsRemoved`).
- Produces: a visible "Human reads removed: N (X.X%)" surface in the Inspector and OperationCenter log, analogous to the dedup summary from #24.

- [ ] **Step 1: Write a failing test** for a `RecipeAppliedInfo.humanScrubSummary` accessor mirroring #24's `deduplicationSummary`, matching the scrub step (`stepName` contains "human" or "scrub"). Test in `Tests/LungfishIOTests/RecipeAppliedInfoTests.swift`.

```swift
    func testHumanScrubSummaryFromScrubStep() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2", recipeName: "VSP2", appliedDate: Date(),
            stepResults: [
                RecipeStepResult(stepName: "Human read scrub (remove, db: deacon-panhuman)", tool: "deacon",
                                 toolVersion: nil, commandLine: nil, commandArguments: nil,
                                 inputReadCount: 500_000, outputReadCount: 460_000, durationSeconds: 0)
            ]
        )
        let s = try XCTUnwrap(info.humanScrubSummary)
        XCTAssertEqual(s.readsRemoved, 40_000)
        XCTAssertEqual(s.percentRemoved, 8.0, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run — expect FAIL** (`humanScrubSummary` missing).

- [ ] **Step 3: Implement `humanScrubSummary`** in `FASTQMetadataStore.swift` reusing #24's `DeduplicationSummary` shape (rename generically or add a parallel `HumanScrubSummary` with identical fields; a shared `ReadDeltaSummary` struct is cleanest — if #24 already landed, refactor `DeduplicationSummary` into a shared `ReadDeltaSummary` and expose both `deduplicationSummary` and `humanScrubSummary` returning it). Add the Inspector row and OperationCenter log line mirroring #24 Tasks 2–3.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: GUI verification.** Launch `.build/debug/Lungfish`, VSP2-import the spiked dataset, confirm the Inspector shows "Human reads removed: N (X.X%)". Screenshot.

- [ ] **Step 6: Commit** `feat(vsp2): surface human-read removal count in provenance`.

---

### Final verification

- [ ] Diagnosis report committed and referenced in issue #23.
- [ ] `swift build/test --package-path <worktree> --skip-update` → clean + GREEN.
- [ ] Before/after residual numbers on the spiked dataset recorded in the report.
- [ ] Issue #23 updated with the root cause, the fix chosen, and the measured improvement.

## Self-review checklist

- Spec coverage: diagnosis (Task 1), fix (Task 2, one option), measurement/surface (Task 3) → all criteria mapped.
- No placeholders: each option has concrete first steps; the measurement accessor has a full test + implementation note.
- Type consistency: `humanScrubSummary` mirrors `deduplicationSummary`; if refactoring to `ReadDeltaSummary`, update #24's callers in the same commit.
- Diagnosis-first discipline preserved: no code fix precedes Task 1's finding.
